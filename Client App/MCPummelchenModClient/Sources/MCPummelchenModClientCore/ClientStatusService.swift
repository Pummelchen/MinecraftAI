import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import MCPummelchenModShared

public enum ClientSyncState: String, Codable, Equatable, Sendable {
    case synced
    case updateAvailable = "update_available"
    case offline
    case repairNeeded = "repair_needed"
}

public enum EndpointConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case degraded
    case cannotConnect = "cannot_connect"
}

public struct EndpointConnectionStatus: Codable, Equatable, Sendable {
    public let label: String
    public let state: EndpointConnectionState
    public let latencyMS: Int?
    public let message: String
    public let checkedAt: String

    enum CodingKeys: String, CodingKey {
        case label
        case state
        case latencyMS = "latency_ms"
        case message
        case checkedAt = "checked_at"
    }

    public init(label: String, state: EndpointConnectionState, latencyMS: Int?, message: String, checkedAt: String) {
        self.label = label
        self.state = state
        self.latencyMS = latencyMS
        self.message = message
        self.checkedAt = checkedAt
    }
}

public struct ClientStatusSnapshot: Codable, Equatable, Sendable {
    public let state: ClientSyncState
    public let serverURL: String
    public let nginx: EndpointConnectionStatus
    public let webTransport: EndpointConnectionStatus
    public let serverReleaseID: String?
    public let localReleaseID: String?
    public let checkedAt: String
    public let minecraftDirectory: String
    public let localDatabase: String
    public let clientIP: String?
    public let defaultsHealth: [ClientDefaultHealthRow]
    public let errorMessage: String?

    public var defaultsOK: Bool {
        defaultsHealth.allSatisfy { $0.status.isHealthy }
    }

    public init(
        state: ClientSyncState,
        serverURL: String,
        nginx: EndpointConnectionStatus,
        webTransport: EndpointConnectionStatus,
        serverReleaseID: String?,
        localReleaseID: String?,
        checkedAt: String,
        minecraftDirectory: String,
        localDatabase: String,
        clientIP: String?,
        defaultsHealth: [ClientDefaultHealthRow],
        errorMessage: String?
    ) {
        self.state = state
        self.serverURL = serverURL
        self.nginx = nginx
        self.webTransport = webTransport
        self.serverReleaseID = serverReleaseID
        self.localReleaseID = localReleaseID
        self.checkedAt = checkedAt
        self.minecraftDirectory = minecraftDirectory
        self.localDatabase = localDatabase
        self.clientIP = clientIP
        self.defaultsHealth = defaultsHealth
        self.errorMessage = errorMessage
    }
}

public struct ClientStatusConfiguration: Sendable {
    public let serverURL: URL
    public let minecraftDirectory: URL
    public let pummelchenHome: URL
    public let databaseURL: URL
    public let retryPolicy: ClientHTTPRetryPolicy
    public let clientID: String?
    public let clientAPIToken: String?

    public init(
        serverURL: URL = URL(string: "https://pummelchen.91.99.176.243.nip.io")!,
        minecraftDirectory: URL,
        pummelchenHome: URL,
        databaseURL: URL,
        retryPolicy: ClientHTTPRetryPolicy = ClientHTTPRetryPolicy(),
        clientID: String? = nil,
        clientAPIToken: String? = ClientCredentialProvider.defaultClientAPIToken()
    ) {
        self.serverURL = serverURL
        self.minecraftDirectory = minecraftDirectory
        self.pummelchenHome = pummelchenHome
        self.databaseURL = databaseURL
        self.retryPolicy = retryPolicy
        self.clientID = clientID
        self.clientAPIToken = clientAPIToken
    }

    public static func productionDefault(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClientStatusConfiguration {
        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        let pummelchenHome = appSupport.appendingPathComponent("Pummelchen", isDirectory: true)
        return ClientStatusConfiguration(
            minecraftDirectory: appSupport.appendingPathComponent("minecraft", isDirectory: true),
            pummelchenHome: pummelchenHome,
            databaseURL: pummelchenHome.appendingPathComponent("client.duckdb")
        )
    }
}

public struct ClientStatusService: Sendable {
    public let configuration: ClientStatusConfiguration
    public let store: ClientStatusStore
    private let http: ClientHTTPClient
    private let probeHTTP: ClientHTTPClient

    public init(configuration: ClientStatusConfiguration) {
        self.configuration = configuration
        self.store = ClientStatusStore(databaseURL: configuration.databaseURL)
        self.http = ClientHTTPClient(retryPolicy: configuration.retryPolicy)
        self.probeHTTP = ClientHTTPClient(
            retryPolicy: ClientHTTPRetryPolicy(maxAttempts: 1, requestTimeoutSeconds: 5)
        )
    }

    public func checkAndRecord(rowIDsToRepair: Set<String>? = nil, retryTracker: DefaultsRetryTracker? = nil) async -> ClientStatusSnapshot {
        let snapshot = await check(rowIDsToRepair: rowIDsToRepair, retryTracker: retryTracker)
        do {
            try store.record(snapshot: snapshot)
        } catch {
            return ClientStatusSnapshot(
                state: snapshot.state == .offline ? .offline : .repairNeeded,
                serverURL: snapshot.serverURL,
                nginx: snapshot.nginx,
                webTransport: snapshot.webTransport,
                serverReleaseID: snapshot.serverReleaseID,
                localReleaseID: snapshot.localReleaseID,
                checkedAt: snapshot.checkedAt,
                minecraftDirectory: snapshot.minecraftDirectory,
                localDatabase: snapshot.localDatabase,
                clientIP: snapshot.clientIP,
                defaultsHealth: snapshot.defaultsHealth,
                errorMessage: "local DuckDB write failed: \(error)"
            )
        }
        return snapshot
    }

    public func check() async -> ClientStatusSnapshot {
        return await check(rowIDsToRepair: nil)
    }

    public func check(rowIDsToRepair: Set<String>? = nil, retryTracker: DefaultsRetryTracker? = nil) async -> ClientStatusSnapshot {
        let checkedAt = Self.isoNow()
        let localRelease = readInstalledRelease()
        let clientIP = Self.currentLocalIPAddress()
        let defaults = await defaultsForStatus()
        let inspectedDefaults = ClientDefaultsInspector.inspect(minecraftDirectory: configuration.minecraftDirectory, defaults: defaults)

        let effectiveRowIDs: Set<String>?
        if let tracker = retryTracker, rowIDsToRepair == nil {
            var actionableIDs: [String] = []
            for row in inspectedDefaults where row.status.isActionable {
                if await tracker.shouldRetry(rowID: row.id) {
                    actionableIDs.append(row.id)
                }
            }
            effectiveRowIDs = Set(actionableIDs)
        } else {
            effectiveRowIDs = rowIDsToRepair
        }

        let repaired = await ClientDefaultsRepairCoordinator(maxAttempts: 2).repairDefaults(
            defaults: defaults,
            rows: inspectedDefaults,
            minecraftDirectory: configuration.minecraftDirectory,
            pummelchenHome: configuration.pummelchenHome,
            rowIDs: effectiveRowIDs
        )

        if let tracker = retryTracker {
            for attempt in repaired.attempts {
                if attempt.statusAfter == .fixedFailed {
                    await tracker.recordFailure(rowID: attempt.rowID)
                } else if attempt.statusAfter == .fixedOK {
                    await tracker.recordSuccess(rowID: attempt.rowID)
                }
            }
        }

        if !repaired.failedAttempts.isEmpty {
            await reportDefaultsRepairDiagnostics(failedAttempts: repaired.failedAttempts, clientIP: clientIP)
        }

        let defaultsHealth = repaired.rows
        let nginxTask = Task {
            await nginxStatus(checkedAt: checkedAt)
        }
        let webTransportTask = Task {
            await webTransportStatus(checkedAt: checkedAt)
        }

        do {
            let releaseProbe = try await measure {
                try await fetchCurrentRelease()
            }
            let serverRelease = releaseProbe.value
            var state: ClientSyncState = localRelease == serverRelease.releaseID ? .synced : .updateAvailable
            var errorMessage: String?
            if !defaultsHealth.allSatisfy({ $0.status.isHealthy }) {
                state = .repairNeeded
                errorMessage = "managed defaults need repair"
            } else if state == .synced {
                do {
                    let manifest = try await fetchManifest(for: serverRelease)
                    let audit = try auditInstalledFiles(manifest: manifest)
                    if audit.missingOrCorrupt > 0 {
                        state = .repairNeeded
                        errorMessage = "\(audit.missingOrCorrupt) managed file(s) are missing or corrupt; run Sync Now to repair."
                    }
                } catch {
                    state = .repairNeeded
                    errorMessage = "installed release audit failed: \(error)"
                }
            }

            return ClientStatusSnapshot(
                state: state,
                serverURL: configuration.serverURL.absoluteString,
                nginx: await nginxTask.value,
                webTransport: await webTransportTask.value,
                serverReleaseID: serverRelease.releaseID,
                localReleaseID: localRelease,
                checkedAt: checkedAt,
                minecraftDirectory: configuration.minecraftDirectory.path,
                localDatabase: configuration.databaseURL.path,
                clientIP: clientIP,
                defaultsHealth: defaultsHealth,
                errorMessage: errorMessage
            )
        } catch {
            return ClientStatusSnapshot(
                state: .offline,
                serverURL: configuration.serverURL.absoluteString,
                nginx: await nginxTask.value,
                webTransport: await webTransportTask.value,
                serverReleaseID: nil,
                localReleaseID: localRelease,
                checkedAt: checkedAt,
                minecraftDirectory: configuration.minecraftDirectory.path,
                localDatabase: configuration.databaseURL.path,
                clientIP: clientIP,
                defaultsHealth: defaultsHealth,
                errorMessage: String(describing: error)
            )
        }
    }

    private func reportDefaultsRepairDiagnostics(
        failedAttempts: [ClientDefaultsRepairAttempt],
        clientIP: String?
    ) async {
        guard let token = configuration.clientAPIToken, !token.isEmpty else {
            return
        }

        do {
            let preflight = try await fetchWebTransportPreflight()
            guard preflight.ready else {
                return
            }
            let channel = ClientWebTransportControlChannel(
                preflight: preflight,
                clientID: Self.validClientID(configuration.clientID),
                clientAPIToken: token
            )

            let logFiles = collectDiagnosticLogFiles()
            let snippet = collectDiagnosticLogSnippet(logFiles: logFiles)
            let detail = failedAttempts.map {
                "\($0.rowLabel):\($0.rowID) -> \($0.statusAfter.rawValue) (from \($0.statusBefore.rawValue))\($0.detail.map { ", detail=\($0)" } ?? "")"
            }.joined(separator: "; ")

            let payload = ClientDiagnosticsUpload(
                clientID: Self.validClientID(configuration.clientID),
                reportedAt: Self.isoNow(),
                level: "error",
                summary: "client defaults repair failed",
                details: detail,
                clientIP: clientIP,
                logFiles: logFiles.map(\.lastPathComponent),
                logSnippet: snippet
            )
            _ = try await channel.uploadDiagnostics(payload)
            try? store.recordClientState(key: "last_defaults_repair_diagnostic", value: "sent")
        } catch {
            try? store.recordClientState(key: "last_defaults_repair_diagnostic", value: String(describing: error))
        }
    }

    private func collectDiagnosticLogFiles() -> [URL] {
        var candidates: Set<URL> = []

        if let selfUpdateLog = configuration.pummelchenHome
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("self-update.log") as URL?, FileManager.default.fileExists(atPath: selfUpdateLog.path) {
            candidates.insert(selfUpdateLog)
        }

        let possibleRoots = [
            configuration.pummelchenHome.appendingPathComponent("logs", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs", isDirectory: true)
                .appendingPathComponent("Pummelchen", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs", isDirectory: true)
                .appendingPathComponent("PummelchenModClient", isDirectory: true)
        ]

        for root in possibleRoots {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
                continue
            }
            for item in contents where item.pathExtension == "log" {
                candidates.insert(item)
            }
        }

        return Array(candidates)
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { lhs, rhs in
                let lhsTime = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsTime = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsTime > rhsTime
            }
            .prefix(4)
            .map { $0 }
    }

    private func collectDiagnosticLogSnippet(logFiles: [URL]) -> String {
        var snippets: [String] = []
        for file in logFiles.prefix(2) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                continue
            }
            let cleaned = text.replacingOccurrences(of: "\u{0000}", with: "")
            snippets.append("[\(file.lastPathComponent)] \(cleaned.suffix(1300))")
        }

        return snippets.joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func defaultsForStatus() async -> MinecraftClientDefaults {
        do {
            let java = try await JavaRuntimeManager.ensureInstalled(pummelchenHome: configuration.pummelchenHome)
            let loader = NeoForgeClientRequirement.live
            try await NeoForgeClientInstaller.ensureSupportedInstalled(
                minecraftDirectory: configuration.minecraftDirectory,
                pummelchenHome: configuration.pummelchenHome,
                javaExecutable: java.javaExecutableURL
            )
            return MinecraftClientDefaults(javaExecutablePath: java.javaExecutableURL.path, loaderVersion: loader.loaderVersion)
        } catch {
            return MinecraftClientDefaults()
        }
    }

    private func fetchCurrentRelease() async throws -> CurrentRelease {
        return try await fetchCurrentReleaseFromNginx()
    }

    private func nginxStatus(checkedAt: String) async -> EndpointConnectionStatus {
        do {
            let probe = try await measure {
                _ = try await fetchCurrentReleaseFromNginx()
            }
            return endpointStatus(label: "Mod Download Server", latencyMS: probe.latencyMS, checkedAt: checkedAt)
        } catch {
            return EndpointConnectionStatus(
                label: "Mod Download Server",
                state: .cannotConnect,
                latencyMS: nil,
                message: String(describing: error),
                checkedAt: checkedAt
            )
        }
    }

    private func fetchCurrentReleaseFromNginx() async throws -> CurrentRelease {
        let url = configuration.serverURL.appendingPathComponent("downloads/current-release.json")
        let data: Data
        do {
            data = try await probeHTTP.data(from: url)
        } catch {
            let apiURL = configuration.serverURL.appendingPathComponent("api/v1/releases/current")
            data = try await probeHTTP.data(from: apiURL)
        }
        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)
        return release
    }

    private func webTransportStatus(checkedAt: String) async -> EndpointConnectionStatus {
        do {
            let preflightProbe = try await measure {
                try await fetchWebTransportPreflight()
            }
            guard preflightProbe.value.ready else {
                return EndpointConnectionStatus(
                    label: "Live Update Server",
                    state: .cannotConnect,
                    latencyMS: preflightProbe.latencyMS,
                    message: preflightProbe.value.unsupportedReason ?? "live update connection is not ready",
                    checkedAt: checkedAt
                )
            }
            guard let token = configuration.clientAPIToken, !token.isEmpty else {
                return EndpointConnectionStatus(
                    label: "Live Update Server",
                    state: .degraded,
                    latencyMS: preflightProbe.latencyMS,
                    message: "ready, client credentials unavailable",
                    checkedAt: checkedAt
                )
            }
            let sessionProbe = try await measure {
                _ = try await ClientWebTransportControlChannel(
                    preflight: preflightProbe.value,
                    clientID: Self.validClientID(configuration.clientID),
                    clientAPIToken: token
                ).fetchEvents(limit: 1)
            }
            return endpointStatus(label: "Live Update Server", latencyMS: sessionProbe.latencyMS, checkedAt: checkedAt)
        } catch {
            return EndpointConnectionStatus(
                label: "Live Update Server",
                state: .cannotConnect,
                latencyMS: nil,
                message: String(describing: error),
                checkedAt: checkedAt
            )
        }
    }

    private func fetchWebTransportPreflight() async throws -> WebTransportPreflightPayload {
        let url = configuration.serverURL.appendingPathComponent("api/v1/transport/webtransport/preflight")
        let data = try await probeHTTP.data(from: url)
        return try JSONDecoder().decode(WebTransportPreflightPayload.self, from: data)
    }

    private func endpointStatus(label: String, latencyMS: Int, checkedAt: String) -> EndpointConnectionStatus {
        let state: EndpointConnectionState
        let message: String
        if latencyMS < 2_000 {
            state = .connected
            message = "connected"
        } else if latencyMS < 5_000 {
            state = .degraded
            message = "slow response"
        } else {
            state = .degraded
            message = "very slow response"
        }
        return EndpointConnectionStatus(label: label, state: state, latencyMS: latencyMS, message: message, checkedAt: checkedAt)
    }

    private func measure<T: Sendable>(_ operation: () async throws -> T) async throws -> (value: T, latencyMS: Int) {
        let start = Date()
        let value = try await operation()
        let elapsed = Date().timeIntervalSince(start)
        return (value, max(0, Int((elapsed * 1_000).rounded())))
    }

    private func fetchManifest(for release: CurrentRelease) async throws -> ClientSyncManifest {
        let url = absoluteURL(from: release.manifestURL)
        let data = try await http.data(from: url)
        return try ClientSyncManifestParser.parse(String(decoding: data, as: UTF8.self))
    }

    private func auditInstalledFiles(manifest: ClientSyncManifest) throws -> (verified: Int, missingOrCorrupt: Int) {
        var verified = 0
        var missingOrCorrupt = 0
        for entry in manifest.entries {
            let destination = try destinationURL(for: entry)
            if (try? FileInventory.verify(fileURL: destination, expectedSize: entry.sizeBytes, expectedSHA256: entry.sha256)) == true {
                verified += 1
            } else {
                missingOrCorrupt += 1
            }
        }
        return (verified, missingOrCorrupt)
    }

    private func destinationURL(for entry: ClientSyncManifestEntry) throws -> URL {
        let root = try directory(for: entry.section)
        return try SafePath(root: root).validateChild(root.appendingPathComponent(entry.name))
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
            throw ContractValidationError.invalid("invalid client section: \(section)")
        }
    }

    private func absoluteURL(from value: String) -> URL {
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return configuration.serverURL.appendingPathComponent(value.hasPrefix("/") ? String(value.dropFirst()) : value)
    }

    private func readInstalledRelease() -> String? {
        let url = configuration.minecraftDirectory
            .appendingPathComponent(".pummelchen/installed-release.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let filtered = raw.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
        return filtered.isEmpty ? nil : String(filtered.prefix(120))
    }

    private static func currentLocalIPAddress() -> String? {
        var addresses: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        defer {
            if ifaddr != nil {
                freeifaddrs(ifaddr)
            }
        }

        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return nil
        }

        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let currentPointer = current {
            let interface = currentPointer.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("lo") {
                    current = interface.ifa_next
                    if current == nil { break }
                    continue
                }

                var hostName = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let flags: Int32 = NI_NUMERICHOST
                let sockFamily = sa_family_t(interface.ifa_addr.pointee.sa_family)
                let addrLen: socklen_t = (sockFamily == AF_INET) ? socklen_t(INET_ADDRSTRLEN) : socklen_t(INET6_ADDRSTRLEN)
                let rv = getnameinfo(interface.ifa_addr, addrLen, &hostName, socklen_t(hostName.count), nil, 0, flags)
                if rv == 0 {
                    let terminator = hostName.firstIndex(of: 0) ?? hostName.count
                    let bytes = hostName[0..<terminator].map { UInt8($0) }
                    let ip = String(decoding: bytes, as: UTF8.self)
                    if !ip.isEmpty {
                        addresses.append(ip)
                    }
                }
            }

            let next = interface.ifa_next
            if let pointer = next {
                current = pointer
            } else {
                break
            }
        }

        let ipv4 = addresses.first(where: { $0.contains(".") })
        return ipv4 ?? addresses.first
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func validClientID(_ proposed: String?) -> String {
        let candidate = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allowed = candidate.filter { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        }
        return allowed.isEmpty ? "pummelchen-client" : String(allowed.prefix(128))
    }
}
