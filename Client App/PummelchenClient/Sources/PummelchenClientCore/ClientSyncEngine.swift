import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PummelchenCore

public struct ClientSyncConfiguration: Sendable {
    public let serverURL: URL
    public let minecraftDirectory: URL
    public let pummelchenHome: URL
    public let databaseURL: URL
    public let allowWhileMinecraftRunning: Bool
    public let reportToServer: Bool
    public let clientID: String?
    public let clientAPIToken: String?

    public init(
        serverURL: URL = URL(string: "http://91.99.176.243:7788")!,
        minecraftDirectory: URL,
        pummelchenHome: URL,
        databaseURL: URL,
        allowWhileMinecraftRunning: Bool = false,
        reportToServer: Bool = true,
        clientID: String? = nil,
        clientAPIToken: String? = ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"]
    ) {
        self.serverURL = serverURL
        self.minecraftDirectory = minecraftDirectory
        self.pummelchenHome = pummelchenHome
        self.databaseURL = databaseURL
        self.allowWhileMinecraftRunning = allowWhileMinecraftRunning
        self.reportToServer = reportToServer
        self.clientID = clientID
        self.clientAPIToken = clientAPIToken
    }

    public static func productionDefault(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClientSyncConfiguration {
        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        let pummelchenHome = appSupport.appendingPathComponent("Pummelchen", isDirectory: true)
        return ClientSyncConfiguration(
            minecraftDirectory: appSupport.appendingPathComponent("minecraft", isDirectory: true),
            pummelchenHome: pummelchenHome,
            databaseURL: pummelchenHome.appendingPathComponent("client.duckdb")
        )
    }
}

public struct ClientSyncResult: Equatable, Sendable {
    public let runID: String
    public let startedAt: String
    public let finishedAt: String
    public let fromReleaseID: String?
    public let targetReleaseID: String
    public let result: String
    public let manifestEntries: Int
    public let filesVerified: Int
    public let filesDownloaded: Int
    public let filesQuarantined: Int
    public let message: String
}

public enum ClientSyncError: Error, CustomStringConvertible {
    case minecraftRunning
    case invalidSection(String)
    case downloadFailed(URL)
    case checksumMismatch(String)

    public var description: String {
        switch self {
        case .minecraftRunning:
            return "Minecraft appears to be running; close Minecraft before syncing"
        case .invalidSection(let section):
            return "invalid manifest section: \(section)"
        case .downloadFailed(let url):
            return "download failed: \(url.absoluteString)"
        case .checksumMismatch(let name):
            return "checksum mismatch: \(name)"
        }
    }
}

public struct ClientSyncEngine: Sendable {
    public let configuration: ClientSyncConfiguration
    public let store: ClientStatusStore

    public init(configuration: ClientSyncConfiguration) {
        self.configuration = configuration
        self.store = ClientStatusStore(databaseURL: configuration.databaseURL)
    }

    public func sync(force: Bool = false) async throws -> ClientSyncResult {
        let started = Date()
        let runID = UUID().uuidString
        let previousRelease = readInstalledRelease()
        do {
            if !configuration.allowWhileMinecraftRunning, Self.minecraftIsRunning() {
                throw ClientSyncError.minecraftRunning
            }

            let release = try await fetchCurrentRelease()
            let manifest = try await fetchManifest(for: release)
            try createManagedDirectories()

            let staleRemoved = try removeStaleManagedFiles(current: manifest)
            let unmanagedMoved = try quarantineUnmanagedFiles(current: manifest)
            let syncCounts = try await installFiles(manifest: manifest)
            try MinecraftClientDefaultWriter.apply(to: configuration.minecraftDirectory)
            try writeInstalledRelease(release.releaseID)
            try writeCurrentManifest(manifest)
            let inventory = try installedInventory(manifest: manifest)

            let finished = Date()
            let downloaded = syncCounts.downloaded
            let changed = downloaded + staleRemoved + unmanagedMoved
            let message = downloaded == 0
                ? "all synced, no downloads required"
                : "synced after \(downloaded) download(s)"
            let result = ClientSyncResult(
                runID: runID,
                startedAt: Self.iso(started),
                finishedAt: Self.iso(finished),
                fromReleaseID: previousRelease,
                targetReleaseID: release.releaseID,
                result: "ok",
                manifestEntries: manifest.entries.count,
                filesVerified: syncCounts.verified,
                filesDownloaded: downloaded,
                filesQuarantined: unmanagedMoved,
                message: message
            )
            try store.record(
                syncResult: result,
                defaultsHealth: ClientDefaultsInspector.inspect(minecraftDirectory: configuration.minecraftDirectory),
                installedFiles: inventory
            )
            if configuration.reportToServer {
                await report(result: result, changedFiles: changed)
            }
            return result
        } catch {
            let failed = ClientSyncResult(
                runID: runID,
                startedAt: Self.iso(started),
                finishedAt: Self.iso(Date()),
                fromReleaseID: previousRelease,
                targetReleaseID: previousRelease ?? "unknown",
                result: "error",
                manifestEntries: 0,
                filesVerified: 0,
                filesDownloaded: 0,
                filesQuarantined: 0,
                message: String(describing: error)
            )
            try? store.record(syncResult: failed, defaultsHealth: ClientDefaultsInspector.inspect(minecraftDirectory: configuration.minecraftDirectory))
            throw error
        }
    }

    private func fetchCurrentRelease() async throws -> CurrentRelease {
        let url = configuration.serverURL.appendingPathComponent("downloads/current-release.json")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            try ContractValidation.require((200..<300).contains(http.statusCode), "current release fetch failed with HTTP \(http.statusCode)")
        }
        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)
        return release
    }

    private func fetchManifest(for release: CurrentRelease) async throws -> ClientSyncManifest {
        let manifestURL = absoluteURL(from: release.manifestURL)
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        if let http = response as? HTTPURLResponse {
            try ContractValidation.require((200..<300).contains(http.statusCode), "manifest fetch failed with HTTP \(http.statusCode)")
        }
        return try ClientSyncManifestParser.parse(String(decoding: data, as: UTF8.self))
    }

    private func installFiles(manifest: ClientSyncManifest) async throws -> (verified: Int, downloaded: Int) {
        let work = configuration.pummelchenHome
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var verified = 0
        var downloaded = 0
        for entry in manifest.entries {
            let destination = try destinationURL(for: entry)
            if (try? FileInventory.verify(fileURL: destination, expectedSize: entry.sizeBytes, expectedSHA256: entry.sha256)) == true {
                verified += 1
                continue
            }

            let tmp = work
                .appendingPathComponent(entry.section, isDirectory: true)
                .appendingPathComponent(entry.name)
            try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = absoluteURL(from: entry.urlPath)
            let (downloadedURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ClientSyncError.downloadFailed(url)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tmp)
            guard (try? FileInventory.verify(fileURL: tmp, expectedSize: entry.sizeBytes, expectedSHA256: entry.sha256)) == true else {
                throw ClientSyncError.checksumMismatch("\(entry.section)/\(entry.name)")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let replacement = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).pummelchen-new")
            try? FileManager.default.removeItem(at: replacement)
            try FileManager.default.moveItem(at: tmp, to: replacement)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: replacement)
            } else {
                try FileManager.default.moveItem(at: replacement, to: destination)
            }
            if entry.section == ManagedClientSection.tools.rawValue {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
            downloaded += 1
            verified += 1
        }
        return (verified, downloaded)
    }

    private func removeStaleManagedFiles(current manifest: ClientSyncManifest) throws -> Int {
        let previous = try readPreviousManifest()
        let currentKeys = Set(manifest.entries.map { "\($0.section)\t\($0.name)" })
        var removed = 0
        for entry in previous.entries {
            guard !currentKeys.contains("\(entry.section)\t\(entry.name)") else {
                continue
            }
            let destination = try destinationURL(for: entry)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
                removed += 1
            }
        }
        return removed
    }

    private func installedInventory(manifest: ClientSyncManifest) throws -> [FileInventoryEntry] {
        try manifest.entries.compactMap { entry in
            guard let section = ManagedClientSection(rawValue: entry.section) else {
                return nil
            }
            return try FileInventory.entry(for: try destinationURL(for: entry), section: section, root: try directory(for: entry.section))
        }
    }

    private func quarantineUnmanagedFiles(current manifest: ClientSyncManifest) throws -> Int {
        let wantedBySection = Dictionary(grouping: manifest.entries, by: \.section)
            .mapValues { Set($0.map(\.name)) }
        var moved = 0
        for section in ManagedClientSection.allCases {
            let directory = try directory(for: section.rawValue)
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                continue
            }
            let wanted = wantedBySection[section.rawValue] ?? []
            let quarantine = quarantineDirectory(section: section.rawValue)
            for file in files where file.lastPathComponent != ".DS_Store" {
                if section == .mods, !["jar", "zip"].contains(file.pathExtension.lowercased()) {
                    continue
                }
                guard !wanted.contains(file.lastPathComponent) else {
                    continue
                }
                try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
                let target = quarantine.appendingPathComponent(file.lastPathComponent)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: file, to: target)
                moved += 1
            }
        }
        return moved
    }

    private func readPreviousManifest() throws -> ClientSyncManifest {
        let path = stateDirectory().appendingPathComponent("client-sync-manifest.tsv")
        guard let text = try? String(contentsOf: path, encoding: .utf8), !text.isEmpty else {
            return ClientSyncManifest(entries: [])
        }
        return try ClientSyncManifestParser.parse(text)
    }

    private func writeCurrentManifest(_ manifest: ClientSyncManifest) throws {
        let path = stateDirectory().appendingPathComponent("client-sync-manifest.tsv")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = manifest.entries.map {
            "\($0.section)\t\($0.name)\t\($0.sizeBytes)\tsha256:\($0.sha256)\t\($0.urlPath)"
        }.joined(separator: "\n") + "\n"
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    private func writeInstalledRelease(_ releaseID: String) throws {
        let path = stateDirectory().appendingPathComponent("installed-release.txt")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (releaseID + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func readInstalledRelease() -> String? {
        let path = stateDirectory().appendingPathComponent("installed-release.txt")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func createManagedDirectories() throws {
        for section in ManagedClientSection.allCases {
            try FileManager.default.createDirectory(at: try directory(for: section.rawValue), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: stateDirectory(), withIntermediateDirectories: true)
    }

    private func destinationURL(for entry: ClientSyncManifestEntry) throws -> URL {
        try destinationURL(section: entry.section, name: entry.name)
    }

    private func destinationURL(section: String, name: String) throws -> URL {
        try SafePath(root: try directory(for: section)).validateChild(try directory(for: section).appendingPathComponent(name))
    }

    private func directory(for section: String) throws -> URL {
        switch section {
        case ManagedClientSection.mods.rawValue,
             ManagedClientSection.resourcepacks.rawValue,
             ManagedClientSection.shaderpacks.rawValue:
            return configuration.minecraftDirectory.appendingPathComponent(section, isDirectory: true)
        case ManagedClientSection.tools.rawValue:
            return configuration.pummelchenHome.appendingPathComponent("bin", isDirectory: true)
        default:
            throw ClientSyncError.invalidSection(section)
        }
    }

    private func quarantineDirectory(section: String) -> URL {
        let stamp = Self.fileStamp(Date())
        if section == ManagedClientSection.tools.rawValue {
            return configuration.pummelchenHome.appendingPathComponent("bin.before-pummelchen-swift-\(stamp)", isDirectory: true)
        }
        return configuration.minecraftDirectory.appendingPathComponent("\(section).before-pummelchen-swift-\(stamp)", isDirectory: true)
    }

    private func stateDirectory() -> URL {
        configuration.minecraftDirectory.appendingPathComponent(".pummelchen", isDirectory: true)
    }

    private func absoluteURL(from value: String) -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return configuration.serverURL.appendingPathComponent(value.hasPrefix("/") ? String(value.dropFirst()) : value)
    }

    private func report(result: ClientSyncResult, changedFiles: Int) async {
        guard let token = configuration.clientAPIToken, !token.isEmpty else {
            await reportLegacy(result: result, changedFiles: changedFiles)
            return
        }
        let clientID = configuration.clientID ?? Host.current().localizedName ?? "swift-client"
        let status = result.result == "ok"
            ? (changedFiles == 0 ? "synced" : "synced")
            : (result.message.lowercased().contains("checksum") ? "failed_checksum" : "error")
        let payload = ClientStatusReport(
            clientID: clientID,
            reportedAt: result.finishedAt,
            installedReleaseID: result.targetReleaseID,
            targetReleaseID: result.targetReleaseID,
            status: status,
            manifestEntries: result.manifestEntries,
            changedFiles: changedFiles,
            lastError: result.result == "ok" ? nil : result.message,
            message: result.message,
            osSummary: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: Self.machineArchitecture()
        )
        guard let body = try? JSONEncoder().encode(payload) else {
            return
        }
        var request = URLRequest(url: configuration.serverURL.appendingPathComponent("api/v1/clients/sync-runs"))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "X-Pummelchen-Client-ID")
        request.setValue("PummelchenSwiftSync/0.6", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    private func reportLegacy(result: ClientSyncResult, changedFiles: Int) async {
        var components = URLComponents(url: configuration.serverURL.appendingPathComponent("client-logs/update-status"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: Host.current().localizedName ?? "swift-client"),
            URLQueryItem(name: "installed_release_id", value: result.targetReleaseID),
            URLQueryItem(name: "target_release_id", value: result.targetReleaseID),
            URLQueryItem(name: "status", value: result.result),
            URLQueryItem(name: "manifest_entries", value: String(result.manifestEntries)),
            URLQueryItem(name: "changed_files", value: String(changedFiles)),
            URLQueryItem(name: "message", value: result.message)
        ]
        guard let body = components?.percentEncodedQuery?.data(using: .utf8) else {
            return
        }
        var request = URLRequest(url: configuration.serverURL.appendingPathComponent("client-logs/update-status"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("PummelchenSwiftSync/0.6", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func minecraftIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-lc", "pgrep -f 'net\\.minecraft\\.client|com\\.mojang|Minecraft Launcher|Minecraft\\.app|minecraft\\.launcher' >/dev/null 2>&1"]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func machineArchitecture() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["uname", "-m"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? "unknown" : output
        } catch {
            return "unknown"
        }
    }
}
