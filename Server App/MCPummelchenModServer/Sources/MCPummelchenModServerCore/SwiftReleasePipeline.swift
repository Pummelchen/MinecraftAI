import Foundation
import MCPummelchenModShared

public enum SwiftReleasePipelineError: Error, CustomStringConvertible {
    case releaseExists(String)
    case missingRequiredPath(String)
    case invalidReleaseID(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .releaseExists(let path):
            return "release already exists: \(path)"
        case .missingRequiredPath(let path):
            return "missing required path: \(path)"
        case .invalidReleaseID(let value):
            return "invalid release id: \(value)"
        case .commandFailed(let message):
            return message
        }
    }
}

public struct SwiftReleasePipelineConfig: Sendable {
    public let projectRoot: URL
    public let serverDir: URL
    public let releaseRoot: URL
    public let publicDownloads: URL
    public let databaseURL: URL
    public let releaseID: String
    public let serverKey: String
    public let minecraftVersion: String
    public let loaderVersion: String
    public let status: String
    public let notes: String
    public let actor: String
    public let activate: Bool
    public let buildClientZipIfMissing: Bool
    public let restartCommand: String?
    public let healthCommand: String?

    public init(
        projectRoot: URL,
        serverDir: URL,
        releaseRoot: URL,
        publicDownloads: URL,
        databaseURL: URL,
        releaseID: String,
        serverKey: String = "minecraft_26_1_2",
        minecraftVersion: String = "26.1.2",
        loaderVersion: String = "26.1.2.76",
        status: String = "tested",
        notes: String = "",
        actor: String = "pummelchen-swift-release",
        activate: Bool = false,
        buildClientZipIfMissing: Bool = true,
        restartCommand: String? = nil,
        healthCommand: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.serverDir = serverDir
        self.releaseRoot = releaseRoot
        self.publicDownloads = publicDownloads
        self.databaseURL = databaseURL
        self.releaseID = releaseID
        self.serverKey = serverKey
        self.minecraftVersion = minecraftVersion
        self.loaderVersion = loaderVersion
        self.status = status
        self.notes = notes
        self.actor = actor
        self.activate = activate
        self.buildClientZipIfMissing = buildClientZipIfMissing
        self.restartCommand = restartCommand
        self.healthCommand = healthCommand
    }
}

public struct SwiftReleaseResult: Equatable, Sendable {
    public let releaseID: String
    public let releaseDir: String
    public let serverManifestSHA256: String
    public let clientManifestSHA256: String
    public let clientZipSHA256: String
    public let mrpackSHA256: String
    public let dmgSHA256: String?
    public let activated: Bool
}

public struct SwiftReleasePipeline: Sendable {
    public static let dmgName = "MCPummelchenModClient.dmg"
    public static let dmgHeadlessLiveSoakReportName = "MCPummelchenModClient.dmg.headless-live-soak.json"
    public static let requiredDMGLiveSoakSeconds: Double = 300

    public let config: SwiftReleasePipelineConfig
    private var fileManager: FileManager { FileManager.default }
    private var clientZipName: String { Self.clientZipName(minecraftVersion: config.minecraftVersion) }
    private var mrpackName: String { Self.mrpackName(minecraftVersion: config.minecraftVersion) }
    private var releaseArtifactNames: [String] {
        [
            clientZipName,
            "\(clientZipName).sha256",
            mrpackName,
            "\(mrpackName).sha256",
            Self.dmgName,
            "\(Self.dmgName).sha256",
            Self.dmgHeadlessLiveSoakReportName
        ]
    }

    public init(config: SwiftReleasePipelineConfig) {
        self.config = config
    }

    public static func clientZipName(minecraftVersion: String) -> String {
        "minecraft_\(artifactVersion(minecraftVersion))_client_macos_apple_silicon.zip"
    }

    public static func mrpackName(minecraftVersion: String) -> String {
        "pummelchen-server-\(artifactVersion(minecraftVersion)).mrpack"
    }

    private static func artifactVersion(_ minecraftVersion: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let scalars = minecraftVersion.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return value.isEmpty ? "unknown" : value
    }

    public func createRelease() throws -> SwiftReleaseResult {
        try validateReleaseID(config.releaseID)
        try requireDirectory(config.serverDir.appendingPathComponent("client-package"))
        try fileManager.createDirectory(at: config.releaseRoot, withIntermediateDirectories: true)
        let releaseDir = config.releaseRoot.appendingPathComponent(config.releaseID, isDirectory: true)
        if fileManager.fileExists(atPath: releaseDir.path) {
            throw SwiftReleasePipelineError.releaseExists(releaseDir.path)
        }
        try fileManager.createDirectory(at: releaseDir, withIntermediateDirectories: true)

        try writeChangelog(releaseDir: releaseDir)
        try copyIfExists(config.serverDir.appendingPathComponent("mods"), to: releaseDir.appendingPathComponent("server-files/mods", isDirectory: true))
        try copyIfExists(config.serverDir.appendingPathComponent("server-datapacks"), to: releaseDir.appendingPathComponent("server-files/server-datapacks", isDirectory: true))
        try copyTree(config.serverDir.appendingPathComponent("client-package"), to: releaseDir.appendingPathComponent("client-package", isDirectory: true))

        let serverManifestSHA = try writeReleaseManifest(
            rows: releaseManifestRows(
                roots: [
                    ("server_mod", releaseDir.appendingPathComponent("server-files/mods", isDirectory: true), ["jar", "zip"]),
                    ("server_datapack", releaseDir.appendingPathComponent("server-files/server-datapacks", isDirectory: true), ["jar", "zip"])
                ]
            ),
            to: releaseDir.appendingPathComponent("manifests/server-files.tsv")
        )
        let clientManifestSHA = try writeReleaseManifest(
            rows: releaseManifestRows(
                roots: [
                    ("client_mods", releaseDir.appendingPathComponent("client-package/mods", isDirectory: true), ["jar", "zip"]),
                    ("client_resourcepacks", releaseDir.appendingPathComponent("client-package/resourcepacks", isDirectory: true), ["jar", "zip"]),
                    ("client_shaderpacks", releaseDir.appendingPathComponent("client-package/shaderpacks", isDirectory: true), []),
                    ("client_tools", releaseDir.appendingPathComponent("client-package/tools", isDirectory: true), [])
                ]
            ),
            to: releaseDir.appendingPathComponent("manifests/client-package.tsv")
        )

        let artifacts = releaseDir.appendingPathComponent("artifacts", isDirectory: true)
        try fileManager.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try rebuildClientDistributionArtifacts(sourcePackage: releaseDir.appendingPathComponent("client-package", isDirectory: true))
        for name in releaseArtifactNames {
            try copyIfExists(config.serverDir.appendingPathComponent(name), to: artifacts.appendingPathComponent(name))
        }
        let clientZip = artifacts.appendingPathComponent(clientZipName)
        let mrpack = artifacts.appendingPathComponent(mrpackName)
        try requireFile(clientZip)
        try requireFile(mrpack)
        let clientZipSHA = try SHA256Hasher.hashFile(at: clientZip)
        let mrpackSHA = try SHA256Hasher.hashFile(at: mrpack)
        let dmg = artifacts.appendingPathComponent(Self.dmgName)
        let dmgSHA = fileManager.fileExists(atPath: dmg.path) ? try SHA256Hasher.hashFile(at: dmg) : nil
        let dmgSoakReport = try validateDMGHeadlessLiveSoakReportIfNeeded(artifacts: artifacts, dmgSHA: dmgSHA)
        try writeSHA256Sidecar(for: clientZip, hash: clientZipSHA)
        try writeSHA256Sidecar(for: mrpack, hash: mrpackSHA)
        if let dmgSHA {
            try writeSHA256Sidecar(for: dmg, hash: dmgSHA)
        }

        let createdAt = Self.isoNow()
        try writeMetadata(
            releaseDir: releaseDir,
            createdAt: createdAt,
            serverManifestSHA: serverManifestSHA,
            clientManifestSHA: clientManifestSHA,
            clientZipSHA: clientZipSHA,
            mrpackSHA: mrpackSHA,
            dmgSHA: dmgSHA
        )
        try buildPublicRelease(releaseDir: releaseDir, createdAt: createdAt)
        try persistRelease(
            releaseDir: releaseDir,
            createdAt: createdAt,
            serverManifestSHA: serverManifestSHA,
            clientManifestSHA: clientManifestSHA,
            clientZipSHA: clientZipSHA,
            mrpackSHA: mrpackSHA,
            dmgSHA: dmgSHA,
            dmgSoakReport: dmgSoakReport
        )
        if config.activate {
            try activateRelease(releaseDir: releaseDir, createdAt: createdAt, clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA, dmgSHA: dmgSHA)
        }
        try validateRelease(releaseDir: releaseDir)
        try runReleaseHealthMonitorIfConfigured()
        return SwiftReleaseResult(
            releaseID: config.releaseID,
            releaseDir: releaseDir.path,
            serverManifestSHA256: serverManifestSHA,
            clientManifestSHA256: clientManifestSHA,
            clientZipSHA256: clientZipSHA,
            mrpackSHA256: mrpackSHA,
            dmgSHA256: dmgSHA,
            activated: config.activate
        )
    }

    public func validateRelease(releaseDir: URL? = nil) throws {
        let releaseDir = releaseDir ?? config.releaseRoot.appendingPathComponent(config.releaseID, isDirectory: true)
        try requireFile(releaseDir.appendingPathComponent("CHANGELOG.md"))
        try requireFile(releaseDir.appendingPathComponent("metadata.json"))
        try requireFile(releaseDir.appendingPathComponent("manifests/server-files.tsv"))
        try requireFile(releaseDir.appendingPathComponent("manifests/client-package.tsv"))
        try requireFile(releaseDir.appendingPathComponent("artifacts/\(clientZipName)"))
        try requireFile(releaseDir.appendingPathComponent("artifacts/\(mrpackName)"))
        let publicManifest = releaseDir.appendingPathComponent("public/client-sync-manifest.tsv")
        let manifest = try ClientSyncManifestParser.parse(String(contentsOf: publicManifest, encoding: .utf8))
        try ContractValidation.require(!manifest.entries.isEmpty, "release public manifest must contain client entries")
        let current = releaseDir.appendingPathComponent("public/current-release.json")
        let currentRelease = try CurrentReleaseValidator.decode(try Data(contentsOf: current))
        try CurrentReleaseValidator.validate(currentRelease)
        try ContractValidation.require(currentRelease.releaseID == config.releaseID, "current release payload points at wrong release")
        let dmg = releaseDir.appendingPathComponent("artifacts/\(Self.dmgName)")
        if fileManager.fileExists(atPath: dmg.path) {
            let dmgSHA = try SHA256Hasher.hashFile(at: dmg)
            _ = try validateDMGHeadlessLiveSoakReportIfNeeded(
                artifacts: releaseDir.appendingPathComponent("artifacts", isDirectory: true),
                dmgSHA: dmgSHA
            )
        }
    }

    private func activateRelease(releaseDir: URL, createdAt: String, clientZipSHA: String, mrpackSHA: String, dmgSHA: String?) throws {
        let publicRelease = config.publicDownloads.appendingPathComponent("releases/\(config.releaseID)", isDirectory: true)
        try fileManager.createDirectory(at: publicRelease.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: publicRelease.path) {
            try fileManager.removeItem(at: publicRelease)
        }
        try copyTree(releaseDir.appendingPathComponent("public", isDirectory: true), to: publicRelease)

        let payload = currentReleasePayload(createdAt: createdAt, activatedAt: Self.isoNow(), clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA, dmgSHA: dmgSHA)
        let data = try JSONEncoder.pummelchenSorted.encode(payload)
        try fileManager.createDirectory(at: config.publicDownloads, withIntermediateDirectories: true)
        try writeVersionScopedCurrentRelease(data)
        if try shouldPublishGlobalCurrentRelease() {
            try data.write(to: config.publicDownloads.appendingPathComponent("current-release.json"), options: .atomic)
            try (config.releaseID + "\n").write(to: config.publicDownloads.appendingPathComponent("current-release.txt"), atomically: true, encoding: .utf8)
            try publishCurrentDownloadLinks(publicRelease: publicRelease)
        }
        try publishSiteJSON(from: publicRelease.appendingPathComponent("data/tested-updates.json"), named: "tested-updates.json")
        try executeDuckDB("""
        UPDATE release.pack_releases SET active = false WHERE server_key = \(Self.sqlLiteral(config.serverKey));
        UPDATE release.pack_releases
        SET active = true, activated_at = TIMESTAMP '\(Self.duckTimestamp(Date()))'
        WHERE release_id = \(Self.sqlLiteral(config.releaseID));
        INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
        VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'activate', 'ok', \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(config.notes)));
        """)
        try runRestartIfConfigured()
    }

    private func writeVersionScopedCurrentRelease(_ data: Data) throws {
        let versionName = "current-release-\(Self.artifactVersion(config.minecraftVersion)).json"
        let serverKeyName = "current-release-\(Self.artifactVersion(config.serverKey)).json"
        try data.write(to: config.publicDownloads.appendingPathComponent(versionName), options: .atomic)
        if serverKeyName != versionName {
            try data.write(to: config.publicDownloads.appendingPathComponent(serverKeyName), options: .atomic)
        }
    }

    private func shouldPublishGlobalCurrentRelease() throws -> Bool {
        if let csv = try? queryDuckDB("""
        SELECT is_live
        FROM core.minecraft_server_versions
        WHERE minecraft_version = \(Self.sqlLiteral(config.minecraftVersion))
        LIMIT 1;
        """) {
            let value = csv.split(separator: "\n").dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let value, !value.isEmpty {
                return ["true", "1", "t"].contains(value)
            }
        }
        return config.serverKey == "minecraft_26_1_2" && config.minecraftVersion == "26.1.2"
    }

    private func buildPublicRelease(releaseDir: URL, createdAt: String) throws {
        let publicDir = releaseDir.appendingPathComponent("public", isDirectory: true)
        if fileManager.fileExists(atPath: publicDir.path) {
            try fileManager.removeItem(at: publicDir)
        }
        try fileManager.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let clientFiles = publicDir.appendingPathComponent("client-files", isDirectory: true)
        var rows = [
            "# Pummelchen release client sync manifest v1",
            "# section\tname\tsize\tsha256\turl_path"
        ]
        let clientPackage = releaseDir.appendingPathComponent("client-package", isDirectory: true)
        for section in ManagedClientSection.allCases {
            let sourceDir = clientPackage.appendingPathComponent(section.rawValue, isDirectory: true)
            for file in try listedFiles(sourceDir) where shouldPublishClientFile(section: section, file: file) {
                let target = clientFiles.appendingPathComponent(section.rawValue, isDirectory: true).appendingPathComponent(file.lastPathComponent)
                try copyFile(file, to: target)
                let size = try fileSize(file)
                let hash = try SHA256Hasher.hashFile(at: file)
                rows.append("\(section.rawValue)\t\(file.lastPathComponent)\t\(size)\tsha256:\(hash)\tdownloads/releases/\(config.releaseID)/client-files/\(section.rawValue)/\(file.lastPathComponent)")
            }
        }
        try (rows.joined(separator: "\n") + "\n").write(to: publicDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        for name in releaseArtifactNames {
            try copyIfExists(releaseDir.appendingPathComponent("artifacts/\(name)"), to: publicDir.appendingPathComponent(name))
        }
        let clientZipSHA = try SHA256Hasher.hashFile(at: releaseDir.appendingPathComponent("artifacts/\(clientZipName)"))
        let mrpackSHA = try SHA256Hasher.hashFile(at: releaseDir.appendingPathComponent("artifacts/\(mrpackName)"))
        let dmg = releaseDir.appendingPathComponent("artifacts/\(Self.dmgName)")
        let dmgSHA = fileManager.fileExists(atPath: dmg.path) ? try SHA256Hasher.hashFile(at: dmg) : nil
        let payload = currentReleasePayload(createdAt: createdAt, activatedAt: nil, clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA, dmgSHA: dmgSHA)
        try JSONEncoder.pummelchenSorted.encode(payload).write(to: publicDir.appendingPathComponent("current-release.json"), options: .atomic)
        try writeTestedUpdatesCompatibilityFeed(to: publicDir, createdAt: createdAt)
    }

    private func currentReleasePayload(createdAt: String, activatedAt: String?, clientZipSHA: String, mrpackSHA: String, dmgSHA: String?) -> CurrentRelease {
        CurrentRelease(
            releaseID: config.releaseID,
            createdAt: createdAt,
            activatedAt: activatedAt,
            status: config.status,
            minecraftVersion: config.minecraftVersion,
            loaderVersion: config.loaderVersion,
            serverKey: config.serverKey,
            manifestURL: "/downloads/releases/\(config.releaseID)/client-sync-manifest.tsv",
            clientZipURL: "/downloads/releases/\(config.releaseID)/\(clientZipName)",
            clientZipSHA256: clientZipSHA,
            mrpackURL: "/downloads/releases/\(config.releaseID)/\(mrpackName)",
            mrpackSHA256: mrpackSHA,
            dmgURL: dmgSHA == nil ? nil : "/downloads/releases/\(config.releaseID)/\(Self.dmgName)",
            dmgSHA256: dmgSHA,
            notes: config.notes
        )
    }

    private func persistRelease(
        releaseDir: URL,
        createdAt: String,
        serverManifestSHA: String,
        clientManifestSHA: String,
        clientZipSHA: String,
        mrpackSHA: String,
        dmgSHA: String?,
        dmgSoakReport: DMGHeadlessLiveSoakReport?
    ) throws {
        try initializeReleaseDB()
        let previous = try activeReleaseID()
        try executeDuckDB("""
        INSERT INTO release.pack_releases(
          release_id, created_at, activated_at, server_key, minecraft_version, loader_version,
          server_dir, release_dir, status, active, previous_release_id, git_commit,
          server_manifest_sha256, client_manifest_sha256, db_snapshot_sha256,
          client_zip_sha256, mrpack_sha256, dmg_sha256, changelog_path, notes
        )
        VALUES (
          \(Self.sqlLiteral(config.releaseID)),
          TIMESTAMP '\(Self.sqlTimestamp(createdAt))',
          NULL,
          \(Self.sqlLiteral(config.serverKey)),
          \(Self.sqlLiteral(config.minecraftVersion)),
          \(Self.sqlLiteral(config.loaderVersion)),
          \(Self.sqlLiteral(config.serverDir.path)),
          \(Self.sqlLiteral(releaseDir.path)),
          \(Self.sqlLiteral(config.status)),
          false,
          \(Self.sqlLiteral(previous)),
          \(Self.sqlLiteral(Self.gitCommit(projectRoot: config.projectRoot))),
          \(Self.sqlLiteral(serverManifestSHA)),
          \(Self.sqlLiteral(clientManifestSHA)),
          '',
          \(Self.sqlLiteral(clientZipSHA)),
          \(Self.sqlLiteral(mrpackSHA)),
          \(Self.sqlLiteral(dmgSHA)),
          \(Self.sqlLiteral(releaseDir.appendingPathComponent("CHANGELOG.md").path)),
          \(Self.sqlLiteral(config.notes))
        );
        INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
        VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'create', \(Self.sqlLiteral(config.status)), \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(config.notes)));
        INSERT INTO release.release_health_results(result_id, release_id, checked_at, status, details)
        VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'not_run', 'Swift Phase 7 compatibility pipeline created release; external release health monitor remains the transition hook.');
        """)
        if let dmgSoakReport {
            try persistDMGHeadlessLiveSoakReport(dmgSoakReport)
        }
    }

    private func runRestartIfConfigured() throws {
        guard let restartCommand = config.restartCommand, !restartCommand.isEmpty else {
            try executeDuckDB("""
            INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'skipped', \(Self.sqlLiteral(config.actor)), 'no restart command configured for Swift Phase 7 compatibility run');
            """)
            return
        }
        do {
            let output = try runCommand(executable: "/bin/sh", arguments: ["-lc", restartCommand], currentDirectory: config.projectRoot)
            try executeDuckDB("""
            INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'ok', \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(Self.redactSecrets(output).prefix(1000).description)));
            """)
        } catch {
            try executeDuckDB("""
            INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'error', \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(Self.redactSecrets(String(describing: error)).prefix(1000).description)));
            """)
            throw error
        }
    }

    private func runReleaseHealthMonitorIfConfigured() throws {
        guard let healthCommand = config.healthCommand, !healthCommand.isEmpty else {
            return
        }
        do {
            let output = try runCommand(executable: "/bin/sh", arguments: ["-lc", healthCommand], currentDirectory: config.projectRoot)
            try executeDuckDB("""
            INSERT INTO release.release_health_results(result_id, release_id, checked_at, status, details)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'ok', \(Self.sqlLiteral(Self.redactSecrets(output).prefix(2000).description)));
            """)
        } catch {
            try executeDuckDB("""
            INSERT INTO release.release_health_results(result_id, release_id, checked_at, status, details)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'error', \(Self.sqlLiteral(Self.redactSecrets(String(describing: error)).prefix(2000).description)));
            """)
            throw error
        }
    }

    private func validateDMGHeadlessLiveSoakReportIfNeeded(artifacts: URL, dmgSHA: String?) throws -> DMGHeadlessLiveSoakReport? {
        guard let dmgSHA else {
            return nil
        }
        let reportURL = artifacts.appendingPathComponent(Self.dmgHeadlessLiveSoakReportName)
        try requireFile(reportURL)
        let report = try JSONDecoder().decode(DMGHeadlessLiveSoakReport.self, from: Data(contentsOf: reportURL))
        let normalizedReportSHA = report.dmgSHA256
            .lowercased()
            .replacingOccurrences(of: "sha256:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try ContractValidation.require(report.releaseID == config.releaseID, "DMG headless live soak report release_id must match \(config.releaseID)")
        try ContractValidation.require(normalizedReportSHA == dmgSHA.lowercased(), "DMG headless live soak report must match current DMG SHA256")
        try ContractValidation.require(report.status.lowercased() == "passed", "DMG headless live soak report status must be passed")
        try ContractValidation.require(report.installedFromDMG, "DMG headless live soak must install from the generated DMG")
        try ContractValidation.require(report.javaOK, "DMG headless live soak must verify Java installation")
        try ContractValidation.require(report.neoforgeOK, "DMG headless live soak must verify NeoForge installation")
        try ContractValidation.require(report.syncOK, "DMG headless live soak must verify client sync")
        try ContractValidation.require(report.loginOK, "DMG headless live soak must log into the live Pummelchen server")
        try ContractValidation.require(report.stayedConnected, "DMG headless live soak must stay connected to the live server")
        try ContractValidation.require(report.durationSeconds >= Self.requiredDMGLiveSoakSeconds, "DMG headless live soak must run for at least \(Int(Self.requiredDMGLiveSoakSeconds)) seconds")
        try ContractValidation.require(report.crashReportCount == 0, "DMG headless live soak must not create crash reports")
        try ContractValidation.require(report.fatalLogCount == 0, "DMG headless live soak must not contain fatal log entries")
        try ContractValidation.require(Self.isLiveMinecraftServerAddress(report.serverAddress), "DMG headless live soak must target the live Minecraft server")
        try ContractValidation.require(report.newPlayerSetup?.status.lowercased() == "passed", "DMG headless live soak must include passed new-player setup acceptance")
        try ContractValidation.require(report.newPlayerSetup?.defaultsOK == true, "DMG new-player setup must verify client defaults")
        try ContractValidation.require((report.newPlayerSetup?.manifestEntries ?? 0) > 0, "DMG new-player setup must verify a non-empty client manifest")
        try ContractValidation.require(report.newPlayerSetup?.verifiedManagedFiles == report.newPlayerSetup?.manifestEntries, "DMG new-player setup must verify every managed file")
        try ContractValidation.require(report.newPlayerSetup?.serverEntryCount == 1, "DMG new-player setup must add exactly one Pummelchen server entry")
        try ContractValidation.require(ISO8601DateFormatter().date(from: report.startedAt) != nil, "DMG headless live soak started_at must be ISO-8601")
        try ContractValidation.require(ISO8601DateFormatter().date(from: report.completedAt) != nil, "DMG headless live soak completed_at must be ISO-8601")
        return report
    }

    private func persistDMGHeadlessLiveSoakReport(_ report: DMGHeadlessLiveSoakReport) throws {
        let notes = [
            "DMG live soak passed for \(Int(report.durationSeconds))s",
            "server=\(report.serverAddress)",
            "java_ok=\(report.javaOK)",
            "neoforge_ok=\(report.neoforgeOK)",
            "sync_ok=\(report.syncOK)",
            "new_player_setup=\(report.newPlayerSetup?.status ?? "missing")",
            report.notes
        ].compactMap { $0 }.joined(separator: "; ")
        try executeDuckDB("""
        INSERT INTO core.headless_client_runs(
          id, release_id, started_at, status, renderer_summary,
          duration_seconds, crash_report_count, fatal_log_count, notes
        )
        VALUES (
          (SELECT COALESCE(MAX(id), 0) + 1 FROM core.headless_client_runs),
          \(Self.sqlLiteral(report.releaseID)),
          TIMESTAMP '\(Self.sqlTimestamp(report.startedAt))',
          'passed',
          \(Self.sqlLiteral(report.rendererSummary)),
          \(report.durationSeconds),
          \(report.crashReportCount),
          \(report.fatalLogCount),
          \(Self.sqlLiteral(notes))
        );
        INSERT INTO release.release_health_results(result_id, release_id, checked_at, status, details)
        VALUES (
          \(Self.sqlLiteral(UUID().uuidString)),
          \(Self.sqlLiteral(report.releaseID)),
          TIMESTAMP '\(Self.sqlTimestamp(report.completedAt))',
          'ok',
          \(Self.sqlLiteral("DMG headless live soak passed: installed from DMG, Java OK, NeoForge OK, sync OK, live login OK, connected \(Int(report.durationSeconds)) seconds."))
        );
        """)
    }

    private func initializeReleaseDB() throws {
        try fileManager.createDirectory(at: config.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executeDuckDB("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE SCHEMA IF NOT EXISTS release;
        CREATE TABLE IF NOT EXISTS core.headless_client_runs (
          id BIGINT PRIMARY KEY,
          release_id VARCHAR,
          started_at TIMESTAMP,
          status VARCHAR,
          renderer_summary VARCHAR,
          duration_seconds DOUBLE,
          crash_report_count INTEGER,
          fatal_log_count INTEGER,
          notes VARCHAR
        );
        CREATE TABLE IF NOT EXISTS release.pack_releases (
          release_id VARCHAR PRIMARY KEY,
          created_at TIMESTAMP NOT NULL,
          activated_at TIMESTAMP,
          server_key VARCHAR NOT NULL,
          minecraft_version VARCHAR,
          loader_version VARCHAR,
          server_dir VARCHAR NOT NULL,
          release_dir VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          active BOOLEAN NOT NULL DEFAULT false,
          previous_release_id VARCHAR,
          git_commit VARCHAR,
          server_manifest_sha256 VARCHAR,
          client_manifest_sha256 VARCHAR,
          db_snapshot_sha256 VARCHAR,
          client_zip_sha256 VARCHAR,
          mrpack_sha256 VARCHAR,
          dmg_sha256 VARCHAR,
          changelog_path VARCHAR,
          notes VARCHAR
        );
        CREATE TABLE IF NOT EXISTS release.release_events (
          event_id VARCHAR PRIMARY KEY,
          release_id VARCHAR,
          event_at TIMESTAMP NOT NULL,
          event_type VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          actor VARCHAR,
          notes VARCHAR
        );
        CREATE TABLE IF NOT EXISTS release.release_health_results (
          result_id VARCHAR PRIMARY KEY,
          release_id VARCHAR NOT NULL,
          checked_at TIMESTAMP NOT NULL,
          status VARCHAR NOT NULL,
          details VARCHAR
        );
        CREATE TABLE IF NOT EXISTS release.tested_updates_feed (
          update_id VARCHAR PRIMARY KEY,
          release_id VARCHAR,
          tested_at TIMESTAMP,
          title VARCHAR,
          status VARCHAR,
          details VARCHAR
        );
        """)
    }

    private func activeReleaseID() throws -> String? {
        let csv = try queryDuckDB("SELECT release_id FROM release.pack_releases WHERE server_key = \(Self.sqlLiteral(config.serverKey)) AND active = true ORDER BY activated_at DESC LIMIT 1;")
        return csv.split(separator: "\n").dropFirst().first.map(String.init)
    }

    private func rebuildClientDistributionArtifacts(sourcePackage: URL) throws {
        guard config.buildClientZipIfMissing else {
            return
        }

        let zipTarget = config.serverDir.appendingPathComponent(clientZipName)
        let zipSHATarget = config.serverDir.appendingPathComponent("\(clientZipName).sha256")
        try removeIfExists(zipTarget)
        try removeIfExists(zipSHATarget)
        try runCommand(
            executable: "/usr/bin/env",
            arguments: ["zip", "-qry", zipTarget.path, "client-package"],
            currentDirectory: sourcePackage.deletingLastPathComponent()
        )
        let zipHash = try SHA256Hasher.hashFile(at: zipTarget)
        try "\(zipHash)  \(clientZipName)\n".write(to: zipSHATarget, atomically: true, encoding: .utf8)

        let mrpackTarget = config.serverDir.appendingPathComponent(mrpackName)
        let mrpackSHATarget = config.serverDir.appendingPathComponent("\(mrpackName).sha256")
        try removeIfExists(mrpackTarget)
        try removeIfExists(mrpackSHATarget)

        let stage = config.serverDir.appendingPathComponent(".mrpack-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stage) }
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        try copyTree(sourcePackage, to: stage.appendingPathComponent("minecraft", isDirectory: true))
        try runCommand(
            executable: "/usr/bin/env",
            arguments: ["zip", "-qry", mrpackTarget.path, "minecraft"],
            currentDirectory: stage
        )
        let mrpackHash = try SHA256Hasher.hashFile(at: mrpackTarget)
        try "\(mrpackHash)  \(mrpackName)\n".write(to: mrpackSHATarget, atomically: true, encoding: .utf8)
    }

    private func removeIfExists(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func writeChangelog(releaseDir: URL) throws {
        let body = """
        # \(config.releaseID)

        Status: \(config.status)

        \(config.notes.isEmpty ? "No changelog notes provided." : config.notes)
        """
        try (body + "\n").write(to: releaseDir.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
    }

    private func writeMetadata(
        releaseDir: URL,
        createdAt: String,
        serverManifestSHA: String,
        clientManifestSHA: String,
        clientZipSHA: String,
        mrpackSHA: String,
        dmgSHA: String?
    ) throws {
        let object: [String: String] = [
            "release_id": config.releaseID,
            "created_at": createdAt,
            "server_key": config.serverKey,
            "minecraft_version": config.minecraftVersion,
            "loader_version": config.loaderVersion,
            "status": config.status,
            "server_manifest_sha256": serverManifestSHA,
            "client_manifest_sha256": clientManifestSHA,
            "client_zip_sha256": clientZipSHA,
            "mrpack_sha256": mrpackSHA,
            "dmg_sha256": dmgSHA ?? "",
            "notes": config.notes
        ]
        try JSONEncoder.pummelchenSorted.encode(object).write(to: releaseDir.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func writeTestedUpdatesCompatibilityFeed(to publicDir: URL, createdAt: String) throws {
        let dataDir = publicDir.appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let target = dataDir.appendingPathComponent("tested-updates.json")
        let existingCandidates = [
            config.projectRoot.appendingPathComponent("site/public/data/tested-updates.json"),
            config.projectRoot.appendingPathComponent("site/public/tested-updates.json")
        ]
        for candidate in existingCandidates where fileManager.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            let object = try updatedTestedUpdatesFeed(from: data, createdAt: createdAt)
            let next = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try next.write(to: target, options: .atomic)
            return
        }
        let object = try updatedTestedUpdatesFeed(from: Data(#"{"updates":[]}"#.utf8), createdAt: createdAt)
        let next = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try next.write(to: target, options: .atomic)
    }

    private func updatedTestedUpdatesFeed(from data: Data, createdAt: String) throws -> [String: Any] {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ContractValidationError.invalid("tested updates feed must be a JSON object")
        }
        var updates = object["updates"] as? [[String: Any]] ?? object["rows"] as? [[String: Any]] ?? []
        let releaseRowID = "pr_\(config.releaseID)"
        updates.removeAll { ($0["id"] as? String) == releaseRowID }
        updates.insert([
            "id": releaseRowID,
            "source": "pack_releases",
            "title": "Release promoted: \(config.releaseID)",
            "event_type": "release_promotion",
            "status": config.activate ? "active" : config.status,
            "tested_at": createdAt,
            "tested_at_display": Self.displayTimestamp(createdAt),
            "old_file": NSNull(),
            "new_file": NSNull(),
            "source_url": "/release.html?release=\(config.releaseID)",
            "test_label": config.releaseID,
            "notes": config.notes,
            "mod_id": NSNull()
        ], at: 0)
        object["generated_by"] = "pummelchen-swift-release-pipeline"
        object["generated_at"] = Self.isoNow()
        object["total_entries"] = updates.count
        object["updates"] = updates
        object.removeValue(forKey: "rows")
        return object
    }

    private func publishSiteJSON(from source: URL, named name: String) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            return
        }
        let sitePublic = config.projectRoot.appendingPathComponent("site/public", isDirectory: true)
        try copyFile(source, to: sitePublic.appendingPathComponent(name))
        try copyFile(source, to: sitePublic.appendingPathComponent("data/\(name)"))
    }

    private func publishCurrentDownloadLinks(publicRelease: URL) throws {
        let names = [
            clientZipName,
            "\(clientZipName).sha256",
            mrpackName,
            "\(mrpackName).sha256",
            Self.dmgName,
            "\(Self.dmgName).sha256",
            Self.dmgHeadlessLiveSoakReportName
        ]
        for name in names where fileManager.fileExists(atPath: publicRelease.appendingPathComponent(name).path) {
            let target = config.publicDownloads.appendingPathComponent(name)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.createSymbolicLink(
                atPath: target.path,
                withDestinationPath: "releases/\(config.releaseID)/\(name)"
            )
        }
    }

    private func writeSHA256Sidecar(for file: URL, hash: String) throws {
        let body = "\(hash)  \(file.lastPathComponent)\n"
        try body.write(to: file.deletingLastPathComponent().appendingPathComponent("\(file.lastPathComponent).sha256"), atomically: true, encoding: .utf8)
    }

    private func releaseManifestRows(roots: [(String, URL, [String])]) throws -> [(role: String, root: URL, file: URL)] {
        var rows: [(String, URL, URL)] = []
        for (role, root, extensions) in roots {
            for file in try listedFiles(root) {
                guard extensions.isEmpty || extensions.contains(file.pathExtension.lowercased()) else {
                    continue
                }
                rows.append((role, root, file))
            }
        }
        return rows.sorted(by: { left, right in
            if left.0 == right.0 {
                return left.2.lastPathComponent.localizedCaseInsensitiveCompare(right.2.lastPathComponent) == .orderedAscending
            }
            return left.0 < right.0
        })
    }

    private func writeReleaseManifest(rows: [(role: String, root: URL, file: URL)], to output: URL) throws -> String {
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = "role\trelative_path\tsize_bytes\tsha256\n"
        for row in rows {
            text += "\(row.role)\t\(try relativePath(file: row.file, root: row.root))\t\(try fileSize(row.file))\tsha256:\(try SHA256Hasher.hashFile(at: row.file))\n"
        }
        try text.write(to: output, atomically: true, encoding: .utf8)
        return try SHA256Hasher.hashFile(at: output)
    }

    private func shouldPublishClientFile(section: ManagedClientSection, file: URL) -> Bool {
        guard !file.lastPathComponent.hasPrefix("."), file.lastPathComponent != "upload-token.txt" else {
            return false
        }
        if section == .tools {
            if file.pathExtension.isEmpty {
                return fileManager.isExecutableFile(atPath: file.path)
            }
            return ["sh", "java", "txt", "md", "json", "jar", "gz"].contains(file.pathExtension.lowercased())
        }
        if section == .shaderpacks {
            return !file.pathExtension.isEmpty
        }
        return ["jar", "zip"].contains(file.pathExtension.lowercased())
    }

    private func listedFiles(_ directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func copyIfExists(_ source: URL, to target: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            return
        }
        if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try copyTree(source, to: target)
        } else {
            try copyFile(source, to: target)
        }
    }

    private func copyTree(_ source: URL, to target: URL) throws {
        try requireDirectory(source)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: target)
    }

    private func copyFile(_ source: URL, to target: URL) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SwiftReleasePipelineError.missingRequiredPath(url.path)
        }
    }

    private func requireFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SwiftReleasePipelineError.missingRequiredPath(url.path)
        }
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func relativePath(file: URL, root: URL) throws -> String {
        let filePath = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw ContractValidationError.invalid("file is outside root: \(file.path)")
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private func validateReleaseID(_ value: String) throws {
        do {
            _ = try ReleaseIdentifier(value)
        } catch {
            throw SwiftReleasePipelineError.invalidReleaseID(value)
        }
    }

    private func executeDuckDB(_ sql: String) throws {
        try DuckDBDatabase(databaseURL: config.databaseURL).execute(sql)
    }

    private func queryDuckDB(_ sql: String) throws -> String {
        try DuckDBDatabase(databaseURL: config.databaseURL).queryCSV(sql)
    }

    @discardableResult
    private func runCommand(executable: String, arguments: [String], currentDirectory: URL? = nil) throws -> String {
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
            throw SwiftReleasePipelineError.commandFailed(Self.redactSecrets(([executable] + arguments).joined(separator: " ") + "\n" + output))
        }
        return output
    }

    private static func gitCommit(projectRoot: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", projectRoot.path, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func displayTimestamp(_ iso: String) -> String {
        let compact = iso.replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
            .replacingOccurrences(of: "+00:00", with: "")
        return "\(compact.prefix(16)) UTC"
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlTimestamp(_ value: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: value) ?? Date()
        return duckTimestamp(parsed)
    }

    private static func redactSecrets(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(--rcon-password\s+)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(rcon\.password\s*=\s*)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #""client_secret"\s*:\s*"[^"]+""#, with: #""client_secret":"[REDACTED]""#, options: .regularExpression)
    }

    private static func isLiveMinecraftServerAddress(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasSuffix(":25565")
            && (lower.contains("91.99.176.243") || lower.contains("pummelchen"))
    }

    private static func duckTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct DMGHeadlessLiveSoakReport: Decodable {
    let releaseID: String
    let dmgSHA256: String
    let serverAddress: String
    let startedAt: String
    let completedAt: String
    let durationSeconds: Double
    let status: String
    let installedFromDMG: Bool
    let javaOK: Bool
    let neoforgeOK: Bool
    let syncOK: Bool
    let loginOK: Bool
    let stayedConnected: Bool
    let crashReportCount: Int
    let fatalLogCount: Int
    let rendererSummary: String?
    let notes: String?
    let newPlayerSetup: DMGNewPlayerSetupReport?

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case dmgSHA256 = "dmg_sha256"
        case serverAddress = "server_address"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationSeconds = "duration_seconds"
        case status
        case installedFromDMG = "installed_from_dmg"
        case javaOK = "java_ok"
        case neoforgeOK = "neoforge_ok"
        case syncOK = "sync_ok"
        case loginOK = "login_ok"
        case stayedConnected = "stayed_connected"
        case crashReportCount = "crash_report_count"
        case fatalLogCount = "fatal_log_count"
        case rendererSummary = "renderer_summary"
        case notes
        case newPlayerSetup = "new_player_setup"
    }
}

private struct DMGNewPlayerSetupReport: Decodable {
    let status: String
    let manifestEntries: Int
    let verifiedManagedFiles: Int
    let defaultsOK: Bool
    let serverEntryCount: Int

    enum CodingKeys: String, CodingKey {
        case status
        case manifestEntries = "manifest_entries"
        case verifiedManagedFiles = "verified_managed_files"
        case defaultsOK = "defaults_ok"
        case serverEntryCount = "server_entry_count"
    }
}

private extension JSONEncoder {
    static var pummelchenSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
