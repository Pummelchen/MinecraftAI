import Foundation
import PummelchenCore

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
        loaderVersion: String = "26.1.2.75",
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
    public static let clientZipName = "minecraft_26.1.2_client_macos_apple_silicon.zip"
    public static let mrpackName = "pummelchen-server-26.1.2.mrpack"
    public static let dmgName = "Pummelchen-Client-Installer.dmg"

    public let config: SwiftReleasePipelineConfig
    private var fileManager: FileManager { FileManager.default }

    public init(config: SwiftReleasePipelineConfig) {
        self.config = config
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
        try ensureClientZipAvailable(sourcePackage: releaseDir.appendingPathComponent("client-package", isDirectory: true))
        for name in [Self.clientZipName, "\(Self.clientZipName).sha256", Self.mrpackName, Self.dmgName, "\(Self.dmgName).sha256"] {
            try copyIfExists(config.serverDir.appendingPathComponent(name), to: artifacts.appendingPathComponent(name))
        }
        let clientZip = artifacts.appendingPathComponent(Self.clientZipName)
        let mrpack = artifacts.appendingPathComponent(Self.mrpackName)
        try requireFile(clientZip)
        try requireFile(mrpack)
        let clientZipSHA = try SHA256Hasher.hashFile(at: clientZip)
        let mrpackSHA = try SHA256Hasher.hashFile(at: mrpack)
        let dmg = artifacts.appendingPathComponent(Self.dmgName)
        let dmgSHA = fileManager.fileExists(atPath: dmg.path) ? try SHA256Hasher.hashFile(at: dmg) : nil
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
            dmgSHA: dmgSHA
        )
        if config.activate {
            try activateRelease(releaseDir: releaseDir, createdAt: createdAt, clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA)
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
        try requireFile(releaseDir.appendingPathComponent("artifacts/\(Self.clientZipName)"))
        try requireFile(releaseDir.appendingPathComponent("artifacts/\(Self.mrpackName)"))
        let publicManifest = releaseDir.appendingPathComponent("public/client-sync-manifest.tsv")
        let manifest = try ClientSyncManifestParser.parse(String(contentsOf: publicManifest, encoding: .utf8))
        try ContractValidation.require(!manifest.entries.isEmpty, "release public manifest must contain client entries")
        let current = releaseDir.appendingPathComponent("public/current-release.json")
        let currentRelease = try CurrentReleaseValidator.decode(try Data(contentsOf: current))
        try CurrentReleaseValidator.validate(currentRelease)
        try ContractValidation.require(currentRelease.releaseID == config.releaseID, "current release payload points at wrong release")
    }

    private func activateRelease(releaseDir: URL, createdAt: String, clientZipSHA: String, mrpackSHA: String) throws {
        let publicRelease = config.publicDownloads.appendingPathComponent("releases/\(config.releaseID)", isDirectory: true)
        try fileManager.createDirectory(at: publicRelease.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: publicRelease.path) {
            try fileManager.removeItem(at: publicRelease)
        }
        try copyTree(releaseDir.appendingPathComponent("public", isDirectory: true), to: publicRelease)

        let payload = currentReleasePayload(createdAt: createdAt, activatedAt: Self.isoNow(), clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA)
        let data = try JSONEncoder.pummelchenSorted.encode(payload)
        try fileManager.createDirectory(at: config.publicDownloads, withIntermediateDirectories: true)
        try data.write(to: config.publicDownloads.appendingPathComponent("current-release.json"), options: .atomic)
        try (config.releaseID + "\n").write(to: config.publicDownloads.appendingPathComponent("current-release.txt"), atomically: true, encoding: .utf8)
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
        for name in [Self.clientZipName, "\(Self.clientZipName).sha256", Self.mrpackName, Self.dmgName, "\(Self.dmgName).sha256"] {
            try copyIfExists(releaseDir.appendingPathComponent("artifacts/\(name)"), to: publicDir.appendingPathComponent(name))
        }
        let clientZipSHA = try SHA256Hasher.hashFile(at: releaseDir.appendingPathComponent("artifacts/\(Self.clientZipName)"))
        let mrpackSHA = try SHA256Hasher.hashFile(at: releaseDir.appendingPathComponent("artifacts/\(Self.mrpackName)"))
        let payload = currentReleasePayload(createdAt: createdAt, activatedAt: nil, clientZipSHA: clientZipSHA, mrpackSHA: mrpackSHA)
        try JSONEncoder.pummelchenSorted.encode(payload).write(to: publicDir.appendingPathComponent("current-release.json"), options: .atomic)
        try writeTestedUpdatesCompatibilityFeed(to: publicDir)
    }

    private func currentReleasePayload(createdAt: String, activatedAt: String?, clientZipSHA: String, mrpackSHA: String) -> CurrentRelease {
        CurrentRelease(
            releaseID: config.releaseID,
            createdAt: createdAt,
            activatedAt: activatedAt,
            status: config.status,
            minecraftVersion: config.minecraftVersion,
            loaderVersion: config.loaderVersion,
            serverKey: config.serverKey,
            manifestURL: "/downloads/releases/\(config.releaseID)/client-sync-manifest.tsv",
            clientZipURL: "/downloads/releases/\(config.releaseID)/\(Self.clientZipName)",
            clientZipSHA256: clientZipSHA,
            mrpackURL: "/downloads/releases/\(config.releaseID)/\(Self.mrpackName)",
            mrpackSHA256: mrpackSHA,
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
        dmgSHA: String?
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
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'ok', \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(output.prefix(1000).description)));
            """)
        } catch {
            try executeDuckDB("""
            INSERT INTO release.release_events(event_id, release_id, event_at, event_type, status, actor, notes)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'restart', 'error', \(Self.sqlLiteral(config.actor)), \(Self.sqlLiteral(String(describing: error).prefix(1000).description)));
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
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'ok', \(Self.sqlLiteral(output.prefix(2000).description)));
            """)
        } catch {
            try executeDuckDB("""
            INSERT INTO release.release_health_results(result_id, release_id, checked_at, status, details)
            VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(config.releaseID)), TIMESTAMP '\(Self.duckTimestamp(Date()))', 'error', \(Self.sqlLiteral(String(describing: error).prefix(2000).description)));
            """)
            throw error
        }
    }

    private func initializeReleaseDB() throws {
        try fileManager.createDirectory(at: config.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executeDuckDB("""
        CREATE SCHEMA IF NOT EXISTS release;
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

    private func ensureClientZipAvailable(sourcePackage: URL) throws {
        let target = config.serverDir.appendingPathComponent(Self.clientZipName)
        let shaTarget = config.serverDir.appendingPathComponent("\(Self.clientZipName).sha256")
        guard !fileManager.fileExists(atPath: target.path), config.buildClientZipIfMissing else {
            return
        }
        try runCommand(executable: "/usr/bin/env", arguments: ["zip", "-qry", target.path, "client-package"], currentDirectory: sourcePackage.deletingLastPathComponent())
        let hash = try SHA256Hasher.hashFile(at: target)
        try "\(hash)  \(Self.clientZipName)\n".write(to: shaTarget, atomically: true, encoding: .utf8)
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

    private func writeTestedUpdatesCompatibilityFeed(to publicDir: URL) throws {
        let dataDir = publicDir.appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let target = dataDir.appendingPathComponent("tested-updates.json")
        let existingCandidates = [
            config.projectRoot.appendingPathComponent("site/public/data/tested-updates.json"),
            config.projectRoot.appendingPathComponent("site/public/tested-updates.json")
        ]
        for candidate in existingCandidates where fileManager.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            _ = try JSONSerialization.jsonObject(with: data)
            try data.write(to: target, options: .atomic)
            return
        }
        let feed = """
        {
          "generated_by": "pummelchen-swift-release-phase7",
          "release_id": "\(config.releaseID)",
          "generated_at": "\(Self.isoNow())",
          "rows": []
        }
        """
        try feed.write(to: target, atomically: true, encoding: .utf8)
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
            return ["sh", "java", "txt", "md", "json"].contains(file.pathExtension.lowercased())
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
        _ = try runCommand(executable: try Self.duckDBExecutablePath(), arguments: [config.databaseURL.path, "-c", sql])
    }

    private func queryDuckDB(_ sql: String) throws -> String {
        try runCommand(executable: try Self.duckDBExecutablePath(), arguments: [config.databaseURL.path, "-csv", "-c", sql])
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
            throw SwiftReleasePipelineError.commandFailed(([executable] + arguments).joined(separator: " ") + "\n" + output)
        }
        return output
    }

    private static func duckDBExecutablePath() throws -> String {
        for candidate in ["/opt/homebrew/bin/duckdb", "/usr/local/bin/duckdb", "/usr/bin/duckdb", "/bin/duckdb"] where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ContractValidationError.invalid("duckdb executable not found")
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

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlTimestamp(_ value: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: value) ?? Date()
        return duckTimestamp(parsed)
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

private extension JSONEncoder {
    static var pummelchenSorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
