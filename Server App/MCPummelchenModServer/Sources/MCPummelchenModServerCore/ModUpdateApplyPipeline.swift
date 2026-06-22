import Foundation
import MCPummelchenModShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModUpdateApplyPipelineError: Error, CustomStringConvertible {
    case noSupportedVersions
    case noCompletedScan(String)
    case missingServerDirectory(String)
    case incompleteServerPackage(String)
    case downloadFailed(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .noSupportedVersions:
            return "no live or staging Minecraft versions found"
        case .noCompletedScan(let version):
            return "no completed mod update scan found for Minecraft \(version)"
        case .missingServerDirectory(let path):
            return "missing server directory: \(path)"
        case .incompleteServerPackage(let message):
            return message
        case .downloadFailed(let message):
            return message
        case .commandFailed(let message):
            return message
        }
    }
}

public struct ModUpdateApplyPipelineConfig: Sendable {
    public let projectRoot: URL
    public let releaseRoot: URL
    public let publicDownloads: URL
    public let databaseURL: URL
    public let minecraftVersion: String?
    public let allSupported: Bool
    public let releaseIDPrefix: String
    public let activateLiveVersions: Bool
    public let dryRun: Bool
    public let serverPackageDirectory: URL?
    public let serviceName: String?
    public let clientAPIToken: String?
    public let requireClientToken: Bool

    public init(
        projectRoot: URL,
        releaseRoot: URL,
        publicDownloads: URL,
        databaseURL: URL,
        minecraftVersion: String? = nil,
        allSupported: Bool = false,
        releaseIDPrefix: String,
        activateLiveVersions: Bool = true,
        dryRun: Bool = true,
        serverPackageDirectory: URL? = nil,
        serviceName: String? = nil,
        clientAPIToken: String? = nil,
        requireClientToken: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.releaseRoot = releaseRoot
        self.publicDownloads = publicDownloads
        self.databaseURL = databaseURL
        self.minecraftVersion = minecraftVersion
        self.allSupported = allSupported
        self.releaseIDPrefix = releaseIDPrefix
        self.activateLiveVersions = activateLiveVersions
        self.dryRun = dryRun
        self.serverPackageDirectory = serverPackageDirectory
        self.serviceName = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientAPIToken = clientAPIToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requireClientToken = requireClientToken
    }
}

public struct AppliedModUpdate: Equatable, Sendable {
    public let minecraftVersion: String
    public let oldFiles: [String]
    public let newFile: String
    public let latestVersion: String
    public let latestURL: String
    public let sha256: String
    public let copiedToServer: Bool
    public let copiedToClient: Bool
}

public struct ModUpdateApplyVersionResult: Equatable, Sendable {
    public let minecraftVersion: String
    public let loaderVersion: String
    public let status: String
    public let releaseID: String?
    public let appliedUpdates: [AppliedModUpdate]
    public let skippedReason: String?
}

public struct ModUpdateApplyPipelineResult: Equatable, Sendable {
    public let dryRun: Bool
    public let versions: [ModUpdateApplyVersionResult]
}

public struct ModUpdateApplyPipeline: Sendable {
    public let config: ModUpdateApplyPipelineConfig
    private var fileManager: FileManager { FileManager.default }

    public init(config: ModUpdateApplyPipelineConfig) {
        self.config = config
    }

    public func run() throws -> ModUpdateApplyPipelineResult {
        let versions = try loadVersionTargets()
        guard !versions.isEmpty else {
            throw ModUpdateApplyPipelineError.noSupportedVersions
        }
        var results: [ModUpdateApplyVersionResult] = []
        for version in versions {
            results.append(try apply(version: version))
        }
        return ModUpdateApplyPipelineResult(dryRun: config.dryRun, versions: results)
    }

    private func apply(version: VersionTarget) throws -> ModUpdateApplyVersionResult {
        let scannedCandidates = try loadLatestCandidates(for: version)
        let priorityCandidates = scannedCandidates.filter(\.isPriority)
        let candidates = priorityCandidates.isEmpty ? scannedCandidates : priorityCandidates
        guard !candidates.isEmpty else {
            return ModUpdateApplyVersionResult(
                minecraftVersion: version.minecraftVersion,
                loaderVersion: version.loaderVersion,
                status: "current",
                releaseID: nil,
                appliedUpdates: [],
                skippedReason: "latest completed scan found no update candidates"
            )
        }
        if let packageProblem = packageReadinessProblem(serverDir: version.serverDir) {
            try recordUpdateActivity(
                version: version,
                status: "blocked",
                message: "Minecraft \(version.minecraftVersion) has \(candidates.count) \(priorityCandidates.isEmpty ? "" : "priority ")update candidate(s), but the package is not releasable: \(packageProblem)"
            )
            return ModUpdateApplyVersionResult(
                minecraftVersion: version.minecraftVersion,
                loaderVersion: version.loaderVersion,
                status: "blocked",
                releaseID: nil,
                appliedUpdates: [],
                skippedReason: packageProblem
            )
        }

        let grouped = Dictionary(grouping: candidates, by: \.latestURL)
        var applied: [AppliedModUpdate] = []
        for group in grouped.values.sorted(by: { $0[0].installedFile < $1[0].installedFile }) {
            applied.append(try apply(group: group, version: version))
        }

        let releaseID = releaseID(for: version)
        if !config.dryRun {
            try runServerSmokeCheck()
            if version.isLive {
                _ = try buildDMGIfNeeded(releaseID: releaseID, version: version)
            }
            let release = try SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
                projectRoot: config.projectRoot,
                serverDir: version.serverDir,
                releaseRoot: config.releaseRoot,
                publicDownloads: config.publicDownloads,
                databaseURL: config.databaseURL,
                releaseID: releaseID,
                serverKey: Self.serverKey(minecraftVersion: version.minecraftVersion),
                minecraftVersion: version.minecraftVersion,
                loaderVersion: version.loaderVersion,
                notes: releaseNotes(applied: applied),
                actor: "MCPummelchenModServer mod-update-apply",
                activate: version.isLive && config.activateLiveVersions,
                serviceName: version.isLive ? (config.serviceName ?? "") : ""
            )).createRelease()
            try recordUpdateActivity(
                version: version,
                status: release.activated ? "active" : "staged",
                message: "Applied \(applied.count) \(priorityCandidates.isEmpty ? "" : "priority ")mod update(s) for Minecraft \(version.minecraftVersion) and created \(release.releaseID)."
            )
        }

        return ModUpdateApplyVersionResult(
            minecraftVersion: version.minecraftVersion,
            loaderVersion: version.loaderVersion,
            status: config.dryRun ? "dry_run" : (version.isLive && config.activateLiveVersions ? "active" : "staged"),
            releaseID: releaseID,
            appliedUpdates: applied,
            skippedReason: nil
        )
    }

    private func buildDMGIfNeeded(releaseID: String, version: VersionTarget) throws -> Bool {
        #if os(macOS)
        guard version.isLive else {
            return false
        }

        guard !config.dryRun else {
            return false
        }

        let env = ProcessInfo.processInfo.environment
        let clientPackageRoot = version.serverDir.appendingPathComponent("client-package", isDirectory: true)
        guard FileManager.default.fileExists(atPath: clientPackageRoot.appendingPathComponent("Package.swift").path) else {
            return false
        }
        let serverPackage = config.serverPackageDirectory
            ?? URL(fileURLWithPath: env["PUMMELCHEN_SERVER_PACKAGE_DIR"] ?? config.projectRoot.appendingPathComponent("Server App/MCPummelchenModServer").path)
        let clientToken = config.clientAPIToken ?? env["PUMMELCHEN_CLIENT_API_TOKEN"]
        let skipNginxTest = BoolValue.parse(env["PUMMELCHEN_SKIP_NGINX_CONTROL_LIVE_TEST"])
        let runNginxControlLiveTest = !skipNginxTest && !(clientToken?.isEmpty ?? true)
        let builderConfig = ClientDMGBuilderConfig(
            projectRoot: config.projectRoot,
            clientPackageRoot: clientPackageRoot,
            serverPackageRoot: serverPackage,
            releaseID: releaseID,
            clientVersion: env["PUMMELCHEN_CLIENT_VERSION"] ?? "0.8.4",
            serverURL: env["PUMMELCHEN_SERVER_URL"] ?? "https://pummelchen.91.99.176.243.nip.io",
            serverAddress: env["PUMMELCHEN_SERVER_ADDRESS"] ?? "91.99.176.243:25565",
            duckdbDylibPath: env["PUMMELCHEN_DUCKDB_DYLIB"] ?? "/opt/homebrew/lib/libduckdb.dylib",
            macOSDeploymentTarget: env["MACOSX_DEPLOYMENT_TARGET"] ?? "26.0",
            runNginxControlLiveTest: runNginxControlLiveTest,
            runHeadlessSoak: BoolValue.parse(env["PUMMELCHEN_REQUIRE_HEADLESS_SOAK"]),
            headlessSoakSeconds: Int(env["PUMMELCHEN_HEADLESS_SOAK_SECONDS"] ?? "60") ?? 60,
            clientAPIToken: clientToken,
            requireClientToken: config.requireClientToken
        )

        let dmgResult = try ClientDMGBuilder(config: builderConfig).build()
        let dmgDir = dmgResult.dmgPath.deletingLastPathComponent()
        for artifactName in [SwiftReleasePipeline.dmgName, "\(SwiftReleasePipeline.dmgName).sha256", SwiftReleasePipeline.dmgHeadlessLiveSoakReportName] {
            let source = dmgDir.appendingPathComponent(artifactName)
            if FileManager.default.fileExists(atPath: source.path) {
                let target = version.serverDir.appendingPathComponent(artifactName)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: source, to: target)
            }
        }
        return true
        #else
        return false
        #endif
    }

    private func runServerSmokeCheck() throws {
        let currentReleasePath = config.projectRoot.appendingPathComponent("site/public/downloads/current-release.json")
        guard FileManager.default.fileExists(atPath: currentReleasePath.path) else {
            return
        }
        let api = MCPummelchenModServerAPI(
            config: MCPummelchenModServerConfig(
                projectRoot: config.projectRoot,
                duckDBURL: config.databaseURL
            )
        )
        try api.smokeCheck()
    }

    private func apply(group: [UpdateCandidate], version: VersionTarget) throws -> AppliedModUpdate {
        guard let first = group.first else {
            throw ModUpdateApplyPipelineError.downloadFailed("empty update candidate group")
        }
        let downloaded = try downloadArtifact(URL(string: first.latestURL), preferredVersion: first.latestVersion)
        defer { try? fileManager.removeItem(at: downloaded.directory) }
        let metadata = try inspectJar(downloaded.file)
        let scope = effectiveScope(side: metadata.side)
        let oldFiles = Array(Set(group.map(\.installedFile).filter { !$0.isEmpty })).sorted()
        if !config.dryRun {
            for oldFile in oldFiles where oldFile != downloaded.file.lastPathComponent {
                if scope.copiedToServer {
                    try removeIfExists(version.serverDir.appendingPathComponent("mods/\(oldFile)"))
                }
                if scope.copiedToClient {
                    try removeIfExists(version.serverDir.appendingPathComponent("client-package/mods/\(oldFile)"))
                }
            }
            if scope.copiedToServer {
                try copyFile(downloaded.file, to: version.serverDir.appendingPathComponent("mods/\(downloaded.file.lastPathComponent)"))
            }
            if scope.copiedToClient {
                try copyFile(downloaded.file, to: version.serverDir.appendingPathComponent("client-package/mods/\(downloaded.file.lastPathComponent)"))
            }
            try updateModSources(group: group, newFile: downloaded.file.lastPathComponent, version: version)
        }
        return AppliedModUpdate(
            minecraftVersion: version.minecraftVersion,
            oldFiles: oldFiles,
            newFile: downloaded.file.lastPathComponent,
            latestVersion: first.latestVersion,
            latestURL: first.latestURL,
            sha256: try SHA256Hasher.hashFile(at: downloaded.file),
            copiedToServer: scope.copiedToServer,
            copiedToClient: scope.copiedToClient
        )
    }

    private func loadVersionTargets() throws -> [VersionTarget] {
        let filter: String
        if config.allSupported {
            filter = "lower(status) IN ('live', 'staging')"
        } else if let minecraftVersion = config.minecraftVersion, !minecraftVersion.isEmpty {
            filter = "minecraft_version = \(Self.sqlLiteral(minecraftVersion))"
        } else {
            filter = "is_live = true"
        }
        let csv = try DuckDBDatabase(databaseURL: config.databaseURL, readOnly: true).queryCSV("""
        SELECT minecraft_version, loader, loader_version, server_dir, status, is_live
        FROM core.minecraft_server_versions
        WHERE \(filter)
        ORDER BY sort_order, minecraft_version;
        """)
        return Self.parseCSV(csv).map { row in
            VersionTarget(
                minecraftVersion: row["minecraft_version"] ?? "",
                loader: row["loader"] ?? "neoforge",
                loaderVersion: row["loader_version"] ?? "",
                serverDir: URL(fileURLWithPath: row["server_dir"] ?? "", isDirectory: true).standardizedFileURL,
                status: row["status"] ?? "unknown",
                isLive: Self.duckBool(row["is_live"] ?? "")
            )
        }.filter { !$0.minecraftVersion.isEmpty && !$0.serverDir.path.isEmpty }
    }

    private func loadLatestCandidates(for version: VersionTarget) throws -> [UpdateCandidate] {
        let csv = try DuckDBDatabase(databaseURL: config.databaseURL, readOnly: true).queryCSV("""
        WITH latest_scan AS (
          SELECT scan_id
          FROM core.mod_update_scans
          WHERE minecraft_version = \(Self.sqlLiteral(version.minecraftVersion))
            AND lower(status) = 'completed'
          ORDER BY started_at DESC
          LIMIT 1
        )
        SELECT
          r.source_id,
          r.provider,
          r.source_url,
          COALESCE(r.installed_file, '') AS installed_file,
          COALESCE(r.installed_version, '') AS installed_version,
          COALESCE(r.latest_version, '') AS latest_version,
          COALESCE(r.latest_url, '') AS latest_url,
          CASE
            WHEN EXISTS (
              SELECT 1
              FROM core.mod_sources s
              JOIN core.mods m
                ON COALESCE(m.minecraft_version, \(Self.sqlLiteral(version.minecraftVersion))) = \(Self.sqlLiteral(version.minecraftVersion))
               AND (
                    lower(COALESCE(m.canonical_key, '')) = lower(COALESCE(s.mod_key, ''))
                 OR lower(COALESCE(m.primary_url, '')) = lower(COALESCE(s.source_url, ''))
                 OR lower(COALESCE(m.name, '')) = lower(COALESCE(s.display_name, ''))
               )
              WHERE s.source_id = r.source_id
                AND COALESCE(s.minecraft_version, \(Self.sqlLiteral(version.minecraftVersion))) = \(Self.sqlLiteral(version.minecraftVersion))
                AND lower(COALESCE(m.active_status, '')) IN ('priority mod', 'admin locked')
            ) THEN 1
            ELSE 0
          END AS is_priority
        FROM core.mod_update_scan_results r
        JOIN latest_scan s ON s.scan_id = r.scan_id
        WHERE r.status = 'update_available'
          AND COALESCE(r.latest_url, '') <> ''
        ORDER BY is_priority DESC, r.installed_file, r.latest_url;
        """)
        return Self.parseCSV(csv).compactMap { row in
            guard let latestURL = row["latest_url"], !latestURL.isEmpty else { return nil }
            return UpdateCandidate(
                sourceID: row["source_id"] ?? "",
                provider: row["provider"] ?? "",
                sourceURL: row["source_url"] ?? "",
                installedFile: row["installed_file"] ?? "",
                installedVersion: row["installed_version"] ?? "",
                latestVersion: row["latest_version"] ?? "",
                latestURL: latestURL,
                isPriority: Self.duckBool(row["is_priority"] ?? "")
            )
        }
    }

    private func packageReadinessProblem(serverDir: URL) -> String? {
        guard fileManager.fileExists(atPath: serverDir.path) else {
            return "server directory is missing: \(serverDir.path)"
        }
        let mods = serverDir.appendingPathComponent("mods", isDirectory: true)
        guard let serverModCount = try? listedFiles(mods).count, serverModCount > 0 else {
            return "server mods directory is missing or empty: \(mods.path)"
        }
        let clientPackage = serverDir.appendingPathComponent("client-package", isDirectory: true)
        guard fileManager.fileExists(atPath: clientPackage.path) else {
            return "client-package directory is missing: \(clientPackage.path)"
        }
        let clientMods = clientPackage.appendingPathComponent("mods", isDirectory: true)
        guard let clientModCount = try? listedFiles(clientMods).count, clientModCount > 0 else {
            return "client-package mods directory is missing or empty: \(clientMods.path)"
        }
        return nil
    }

    private func updateModSources(group: [UpdateCandidate], newFile: String, version: VersionTarget) throws {
        let database = DuckDBDatabase(databaseURL: config.databaseURL)
        for candidate in group {
            try database.execute("""
            UPDATE core.mod_sources
            SET installed_file = \(Self.sqlLiteral(newFile)),
                installed_version = \(Self.sqlLiteral(candidate.latestVersion)),
                updated_at = now(),
                loader = \(Self.sqlLiteral(version.loader)),
                loader_version = \(Self.sqlLiteral(version.loaderVersion))
            WHERE source_id = \(Self.sqlLiteral(candidate.sourceID))
              AND minecraft_version = \(Self.sqlLiteral(version.minecraftVersion));
            """)
        }
    }

    private func recordUpdateActivity(version: VersionTarget, status: String, message: String) throws {
        let database = DuckDBDatabase(databaseURL: config.databaseURL)
        try database.execute("""
        CREATE SCHEMA IF NOT EXISTS release;
        CREATE TABLE IF NOT EXISTS release.release_events (
          event_id VARCHAR PRIMARY KEY,
          release_id VARCHAR,
          event_at TIMESTAMP NOT NULL,
          event_type VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          actor VARCHAR,
          notes VARCHAR
        );
        """)
        try database.execute("""
        INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
        VALUES (
          \(Self.sqlLiteral(UUID().uuidString)),
          NULL,
          TIMESTAMP '\(Self.displayTimestamp(Date()))',
          'mod_update_apply',
          \(Self.sqlLiteral(status)),
          'MCPummelchenModServer mod-update-apply',
          \(Self.sqlLiteral("Minecraft \(version.minecraftVersion): \(message)"))
        );
        """)
    }

    private func releaseID(for version: VersionTarget) -> String {
        let suffix = version.minecraftVersion.replacingOccurrences(of: ".", with: "_")
        return "\(config.releaseIDPrefix)_mc_\(suffix)"
    }

    private func releaseNotes(applied: [AppliedModUpdate]) -> String {
        let lines = applied.map { update in
            "- \(update.oldFiles.joined(separator: ", ")) -> \(update.newFile) (\(update.latestVersion))"
        }
        return (["Daily mod update apply: \(applied.count) update(s)."] + lines).joined(separator: "\n")
    }

    private func downloadArtifact(_ url: URL?, preferredVersion: String) throws -> (file: URL, directory: URL) {
        guard let url else {
            throw ModUpdateApplyPipelineError.downloadFailed("invalid update download URL")
        }
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pummelchen-mod-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("MCPummelchenModServer/1.0 mod-update-apply", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        let box = DownloadResultBox()
        URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { semaphore.signal() }
            if let error {
                box.store(.failure(error))
                return
            }
            guard let location else {
                box.store(.failure(ModUpdateApplyPipelineError.downloadFailed("download returned no file for \(url.absoluteString)")))
                return
            }
            let fileName = Self.artifactFileName(response: response, fallbackURL: url, preferredVersion: preferredVersion)
            let target = work.appendingPathComponent(fileName)
            do {
                try FileManager.default.moveItem(at: location, to: target)
                box.store(.success(target))
            } catch {
                box.store(.failure(error))
            }
        }.resume()
        semaphore.wait()
        guard let result = box.result() else {
            throw ModUpdateApplyPipelineError.downloadFailed("download produced no response for \(url.absoluteString)")
        }
        return (try result.get(), work)
    }

    private func inspectJar(_ file: URL) throws -> JarMetadata {
        guard ["jar", "zip"].contains(file.pathExtension.lowercased()) else {
            return JarMetadata(side: "both")
        }
        for path in ["META-INF/neoforge.mods.toml", "META-INF/mods.toml", "fabric.mod.json", "quilt.mod.json"] {
            if let text = try? runProcess(executable: "/usr/bin/env", arguments: ["unzip", "-p", file.path, path], currentDirectory: config.projectRoot) {
                let side = Self.firstMatch(pattern: #"(?m)^\s*side\s*=\s*"([^"]+)""#, in: text)?.lowercased()
                let clientOnly = text.localizedCaseInsensitiveContains("clientSideOnly")
                    || text.localizedCaseInsensitiveContains("clientOnly")
                return JarMetadata(side: (side == "client" || clientOnly) ? "client" : "both")
            }
        }
        return JarMetadata(side: "both")
    }

    private func effectiveScope(side: String) -> (copiedToServer: Bool, copiedToClient: Bool) {
        side.lowercased() == "client" ? (false, true) : (true, true)
    }

    private func copyFile(_ source: URL, to target: URL) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try removeIfExists(target)
        try fileManager.copyItem(at: source, to: target)
    }

    private func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func listedFiles(_ directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { url in
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
    }

    @discardableResult
    private func runProcess(executable: String, arguments: [String], currentDirectory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ModUpdateApplyPipelineError.commandFailed(Self.redactSecrets(([executable] + arguments).joined(separator: " ") + "\n" + output))
        }
        return output
    }

    private static func artifactFileName(response: URLResponse?, fallbackURL: URL, preferredVersion: String) -> String {
        let suggested = response?.suggestedFilename
        let redirected = response?.url?.lastPathComponent.removingPercentEncoding
        let fallback = fallbackURL.lastPathComponent.removingPercentEncoding
        let raw = [suggested, redirected, fallback]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { value in
                !value.isEmpty && value != "download" && (value.hasSuffix(".jar") || value.hasSuffix(".zip"))
            } ?? "mod-update-\(preferredVersion.isEmpty ? UUID().uuidString : preferredVersion).jar"
        return raw.replacingOccurrences(of: #"[/:]"#, with: "-", options: .regularExpression)
    }

    private static func parseCSV(_ csv: String) -> [[String: String]] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return [] }
        let headers = parseCSVLine(header)
        return lines.dropFirst().filter { !$0.isEmpty }.map { line in
            let fields = parseCSVLine(line)
            var row: [String: String] = [:]
            for (index, name) in headers.enumerated() {
                row[name] = fields.indices.contains(index) ? fields[index] : ""
            }
            return row
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    current.append("\"")
                    index += 2
                    continue
                }
                quoted.toggle()
            } else if char == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }

    private static func duckBool(_ value: String) -> Bool {
        ["true", "t", "1"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func serverKey(minecraftVersion: String) -> String {
        "minecraft_\(minecraftVersion.replacingOccurrences(of: ".", with: "_"))"
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let nsRange = match.range(at: 1)
        guard let stringRange = Range(nsRange, in: text) else {
            return nil
        }
        return String(text[stringRange])
    }

    private static func redactSecrets(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(PUMMELCHEN_CLIENT_API_TOKEN=)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(--rcon-password\s+)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
    }
}

private struct VersionTarget {
    let minecraftVersion: String
    let loader: String
    let loaderVersion: String
    let serverDir: URL
    let status: String
    let isLive: Bool
}

private struct UpdateCandidate {
    let sourceID: String
    let provider: String
    let sourceURL: String
    let installedFile: String
    let installedVersion: String
    let latestVersion: String
    let latestURL: String
    let isPriority: Bool
}

private struct JarMetadata {
    let side: String
}

private final class DownloadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<URL, Error>?

    func store(_ result: Result<URL, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func result() -> Result<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
