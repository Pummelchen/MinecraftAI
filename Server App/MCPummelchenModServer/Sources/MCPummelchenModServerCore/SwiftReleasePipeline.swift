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
    public let serviceName: String
    public let releaseRetentionPerServer: Int
    public let tempCleanupRoot: URL

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
        serviceName: String = "",
        releaseRetentionPerServer: Int = 8,
        tempCleanupRoot: URL = FileManager.default.temporaryDirectory
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
        self.serviceName = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.releaseRetentionPerServer = max(1, releaseRetentionPerServer)
        self.tempCleanupRoot = tempCleanupRoot
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
    public static let legacyDMGName = "MCPummelchenModClient.dmg"
    public static let legacyDMGHeadlessLiveSoakReportName = "MCPummelchenModClient.dmg.headless-live-soak.json"
    public static let requiredDMGLiveSoakSeconds: Double = 60

    public let config: SwiftReleasePipelineConfig
    private var fileManager: FileManager { FileManager.default }
    private var clientZipName: String { Self.clientZipName(minecraftVersion: config.minecraftVersion) }
    private var mrpackName: String { Self.mrpackName(minecraftVersion: config.minecraftVersion) }
    private var dmgName: String { Self.dmgName(minecraftVersion: config.minecraftVersion) }
    private var dmgHeadlessLiveSoakReportName: String { Self.dmgHeadlessLiveSoakReportName(minecraftVersion: config.minecraftVersion) }
    private var releaseArtifactNames: [String] {
        [
            clientZipName,
            "\(clientZipName).sha256",
            mrpackName,
            "\(mrpackName).sha256",
            dmgName,
            "\(dmgName).sha256",
            dmgHeadlessLiveSoakReportName
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

    public static func dmgName(minecraftVersion: String) -> String {
        ClientDMGBuilder.dmgFileName(minecraftVersion: minecraftVersion)
    }

    public static func dmgHeadlessLiveSoakReportName(minecraftVersion: String) -> String {
        ClientDMGBuilder.dmgHeadlessLiveSoakReportName(minecraftVersion: minecraftVersion)
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
        let serverDatapacksSource = [
            config.serverDir,
            config.projectRoot.appendingPathComponent("Server App", isDirectory: true)
        ].map { $0.appendingPathComponent("server-datapacks", isDirectory: true) }
        .first { fileManager.fileExists(atPath: $0.path) }
        if let source = serverDatapacksSource {
            try copyTree(source, to: releaseDir.appendingPathComponent("server-files/server-datapacks", isDirectory: true))
        }
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
        let dmg = artifacts.appendingPathComponent(dmgName)
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
        let dmg = releaseDir.appendingPathComponent("artifacts/\(dmgName)")
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
        try publishCurrentDownloadLinks(publicRelease: publicRelease)
        if try shouldPublishGlobalCurrentRelease() {
            try data.write(to: config.publicDownloads.appendingPathComponent("current-release.json"), options: .atomic)
            try (config.releaseID + "\n").write(to: config.publicDownloads.appendingPathComponent("current-release.txt"), atomically: true, encoding: .utf8)
        }
        try executeDuckDB("""
        UPDATE release.pack_releases SET active = false WHERE server_key = \(Self.sqlLiteral(config.serverKey));
        UPDATE release.pack_releases
        SET active = true, activated_at = TIMESTAMP '\(Self.duckTimestamp(Date()))'
        WHERE release_id = \(Self.sqlLiteral(config.releaseID));
        INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
        VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'activate', 'ok', \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(config.notes)));
        """)
        try pruneReleaseStorage()
        cleanupDMGReleaseTempFilesIfNeeded(dmgSHA: dmgSHA)
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
        let dmg = releaseDir.appendingPathComponent("artifacts/\(dmgName)")
        let dmgSHA = fileManager.fileExists(atPath: dmg.path) ? try SHA256Hasher.hashFile(at: dmg) : nil
        let payload = currentReleasePayload(createdAt: createdAt, activatedAt: nil, clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA, dmgSHA: dmgSHA)
        try JSONEncoder.pummelchenSorted.encode(payload).write(to: publicDir.appendingPathComponent("current-release.json"), options: .atomic)
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
            dmgURL: dmgSHA == nil ? nil : "/downloads/\(dmgName)",
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
        guard !config.serviceName.isEmpty else {
            try executeDuckDB("""
            INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'skipped', \(Self.sqlLiteral(config.actor)), 'no service configured for native restart path');
            """)
            return
        }
        guard let status = try serviceStatus(config.serviceName), status.isActive || status.isEnabled else {
            try executeDuckDB("""
            INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'skipped', \(Self.sqlLiteral(config.actor)), 'service \(config.serviceName) not available for native restart');
            """)
            return
        }
        do {
            let output = try runServiceCommand("restart", serviceName: config.serviceName)
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
        do {
            try validateRelease(releaseDir: nil)
            try executeDuckDB("""
            INSERT INTO release.release_health_results(result_id, release_id, checked_at, status, details)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'ok', \(Self.sqlLiteral("release manifest validated by Swift release pipeline")));
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
        let reportURL = artifacts.appendingPathComponent(dmgHeadlessLiveSoakReportName)
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
        try ContractValidation.require(isLiveMinecraftServerAddress(report.serverAddress), "DMG headless live soak must target the live Minecraft server")
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
        """)
    }

    private func activeReleaseID() throws -> String? {
        let csv = try queryDuckDB("SELECT release_id FROM release.pack_releases WHERE server_key = \(Self.sqlLiteral(config.serverKey)) AND active = true ORDER BY activated_at DESC LIMIT 1;")
        return csv.split(separator: "\n").dropFirst().first.map(String.init)
    }

    private struct MCPServiceStatus {
        let isActive: Bool
        let isEnabled: Bool
    }

    private func serviceStatus(_ serviceName: String) throws -> MCPServiceStatus? {
        let normalized = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        guard let systemctl = resolvedSystemTool("systemctl") else {
            return nil
        }
        let enabledOutput = try runCommand(executable: systemctl, arguments: ["is-enabled", normalized]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let activeOutput = try runCommand(executable: systemctl, arguments: ["is-active", normalized]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let enabled = ["enabled", "static", "indirect", "preset"].contains(enabledOutput)
        let active = activeOutput == "active"
        return MCPServiceStatus(isActive: active, isEnabled: enabled)
    }

    private func runServiceCommand(_ action: String, serviceName: String) throws -> String {
        let normalized = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw SwiftReleasePipelineError.commandFailed("no service name configured")
        }
        guard let systemctl = resolvedSystemTool("systemctl") else {
            throw SwiftReleasePipelineError.commandFailed("systemctl binary not found; cannot run native service restart")
        }
        return try runCommand(executable: systemctl, arguments: [action, normalized])
    }

    private func resolvedSystemTool(_ name: String) -> String? {
        if let override = ProcessInfo.processInfo.environment["PUMMELCHEN_SYSTEMCTL_PATH"], !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let candidates: [String]
        if name == "systemctl" {
            candidates = ["/usr/bin/systemctl", "/bin/systemctl", "/usr/sbin/systemctl"]
        } else {
            candidates = ["/usr/bin/\(name)", "/bin/\(name)", "/sbin/\(name)", "/usr/sbin/\(name)"]
        }
        return candidates.first(where: fileManager.fileExists(atPath:))
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

    private func publishCurrentDownloadLinks(publicRelease: URL) throws {
        let names = [
            clientZipName,
            "\(clientZipName).sha256",
            mrpackName,
            "\(mrpackName).sha256",
            dmgName,
            "\(dmgName).sha256",
            dmgHeadlessLiveSoakReportName
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

    private func pruneReleaseStorage() throws {
        let keepIDs = try retainedReleaseIDs()
        let releaseRoots = [
            config.releaseRoot,
            config.publicDownloads.appendingPathComponent("releases", isDirectory: true)
        ]
        for root in releaseRoots where fileManager.fileExists(atPath: root.path) {
            let children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for child in children {
                let values = try child.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true,
                      child.lastPathComponent.hasPrefix("release_"),
                      !keepIDs.contains(child.lastPathComponent) else {
                    continue
                }
                try fileManager.removeItem(at: child)
            }
        }
    }

    private func retainedReleaseIDs() throws -> Set<String> {
        let csv = try queryDuckDB("""
        WITH ranked AS (
          SELECT
            release_id,
            server_key,
            COALESCE(active, false) AS active,
            row_number() OVER (
              PARTITION BY server_key
              ORDER BY COALESCE(activated_at, created_at) DESC, release_id DESC
            ) AS release_rank
          FROM release.pack_releases
        )
        SELECT release_id
        FROM ranked
        WHERE active = true OR release_rank <= \(config.releaseRetentionPerServer);
        """)
        var ids = Set(Self.parseCSVRows(csv).compactMap { $0["release_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        ids.insert(config.releaseID)
        return ids
    }

    private func cleanupDMGReleaseTempFilesIfNeeded(dmgSHA: String?) {
        guard dmgSHA != nil else {
            return
        }

        var summary = ReleaseTempCleanupSummary()
        let clientPackageBuild = config.serverDir
            .appendingPathComponent("client-package", isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
        removeIfSafe(clientPackageBuild, allowedRoot: config.serverDir, summary: &summary)

        let releaseBuildTemp = config.projectRoot
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("pummelchen-dmg", isDirectory: true)
        removeIfSafe(releaseBuildTemp, allowedRoot: config.projectRoot, summary: &summary)

        let binaryBackups = config.projectRoot.appendingPathComponent("bin/backups", isDirectory: true)
        removeIfSafe(binaryBackups, allowedRoot: config.projectRoot, summary: &summary)

        cleanupSparkTemp(summary: &summary)
        cleanupTemporaryRoot(summary: &summary)
        recordReleaseCleanup(summary)
    }

    private func cleanupSparkTemp(summary: inout ReleaseTempCleanupSummary) {
        let sparkTemp = config.serverDir.appendingPathComponent("config/spark/tmp", isDirectory: true)
        guard fileManager.fileExists(atPath: sparkTemp.path) else {
            return
        }
        do {
            let children = try fileManager.contentsOfDirectory(at: sparkTemp, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for child in children where child.lastPathComponent.hasSuffix(".tmp") || child.lastPathComponent.hasSuffix(".jfr.tmp") {
                removeIfSafe(child, allowedRoot: sparkTemp, summary: &summary)
            }
        } catch {
            summary.errors.append("spark tmp scan failed: \(error)")
        }
    }

    private func cleanupTemporaryRoot(summary: inout ReleaseTempCleanupSummary) {
        let tempRoot = config.tempCleanupRoot.standardizedFileURL
        guard fileManager.fileExists(atPath: tempRoot.path) else {
            return
        }
        do {
            let children = try fileManager.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles])
            for child in children where shouldRemoveTemporaryRootItem(child.lastPathComponent) {
                removeIfSafe(child, allowedRoot: tempRoot, summary: &summary)
            }
        } catch {
            summary.errors.append("temporary root scan failed: \(error)")
        }
    }

    private func shouldRemoveTemporaryRootItem(_ name: String) -> Bool {
        let exactNames: Set<String> = [
            "MCPummelchenModClient.dmg",
            "MCPummelchenModClient.dmg.sha256",
            "Pummelchen-Client-Installer.dmg",
            "PummelchenClient.dmg",
            "pummelchen-mrpack",
            "swift-generated-sources",
            "node-compile-cache"
        ]
        if exactNames.contains(name) {
            return true
        }
        if name.hasPrefix("pummelchen-headless-soak-") || name.hasPrefix("pummelchen-java-") || name.hasPrefix("TemporaryDirectory.") {
            return true
        }
        if name.hasPrefix("MCPummelchenModClient_") && (name.hasSuffix(".dmg") || name.hasSuffix(".dmg.sha256")) {
            return true
        }
        if name.hasPrefix("pummelchen") && name.hasSuffix(".log") {
            return true
        }
        if name.hasPrefix("daily_release_pipeline_") && name.hasSuffix(".log") {
            return true
        }
        return false
    }

    private func removeIfSafe(_ url: URL, allowedRoot: URL, summary: inout ReleaseTempCleanupSummary) {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        do {
            let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
            let resolvedRoot = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
            guard isPath(resolvedURL, inside: resolvedRoot) || resolvedURL.path == resolvedRoot.path else {
                summary.errors.append("refused cleanup outside allowed root: \(url.path)")
                return
            }
            let bytes = directorySize(resolvedURL)
            try fileManager.removeItem(at: resolvedURL)
            summary.removedItems += 1
            summary.removedBytes += bytes
            summary.removedPaths.append(url.path)
        } catch {
            summary.errors.append("cleanup failed for \(url.path): \(error)")
        }
    }

    private func directorySize(_ url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        if !isDirectory.boolValue {
            return (try? fileSize(url)) ?? 0
        }
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func isPath(_ path: URL, inside root: URL) -> Bool {
        let pathString = path.path
        let rootString = root.path
        return pathString.hasPrefix(rootString.hasSuffix("/") ? rootString : "\(rootString)/")
    }

    private func recordReleaseCleanup(_ summary: ReleaseTempCleanupSummary) {
        let status = summary.errors.isEmpty ? "ok" : "warning"
        let detail = "Automatic post-DMG cleanup removed \(summary.removedItems) item(s), freed \(summary.removedBytes) byte(s)."
        let pathSample = summary.removedPaths.prefix(8).joined(separator: ", ")
        let errorSample = summary.errors.prefix(4).joined(separator: " | ")
        let notes = [detail, pathSample.isEmpty ? nil : "paths: \(pathSample)", errorSample.isEmpty ? nil : "errors: \(errorSample)"]
            .compactMap { $0 }
            .joined(separator: " ")
        try? executeDuckDB("""
        INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
        VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'cleanup', \(Self.sqlLiteral(status)), 'MCPummelchenModServer release cleanup', \(Self.sqlLiteral(notes)));
        """)
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

    private static func parseCSVRows(_ csv: String) -> [[String: String]] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = parseCSVLine(headerLine)
        return lines.dropFirst().map { line in
            let values = parseCSVLine(line)
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                row[header] = index < values.count ? values[index] : ""
            }
            return row
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var values: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes = false
                        if next != "," {
                            current.append(next)
                        } else {
                            values.append(current)
                            current = ""
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == "," && !inQuotes {
                values.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        values.append(current)
        return values
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

    private func isLiveMinecraftServerAddress(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard lower.hasSuffix(":25565") else { return false }
        if let csv = try? queryDuckDB("SELECT server_address FROM core.minecraft_server_versions WHERE is_live = true AND lower(status) = 'live' LIMIT 1;"),
           let liveAddress = Self.parseCSVRows(csv).first?["server_address"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !liveAddress.isEmpty {
            let liveIP = liveAddress.split(separator: ":").first ?? ""
            if lower.contains(liveIP) || lower.contains("pummelchen") {
                return true
            }
        }
        return lower.contains("91.99.176.243") || lower.contains("pummelchen")
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

private struct ReleaseTempCleanupSummary {
    var removedItems = 0
    var removedBytes: Int64 = 0
    var removedPaths: [String] = []
    var errors: [String] = []
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
