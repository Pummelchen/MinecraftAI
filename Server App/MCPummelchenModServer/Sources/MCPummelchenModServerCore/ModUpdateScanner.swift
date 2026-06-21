import Foundation
import MCPummelchenModShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModUpdateScannerError: Error, CustomStringConvertible {
    case invalidSourceURL(String)
    case network(String)

    public var description: String {
        switch self {
        case .invalidSourceURL(let value):
            return "invalid mod source URL: \(value)"
        case .network(let value):
            return "network error: \(value)"
        }
    }
}

public struct ModUpdateScannerConfig: Sendable {
    public let projectRoot: URL
    public let databaseURL: URL
    public let minecraftVersion: String
    public let loader: String
    public let loaderVersion: String?
    public let maxURLsPerWindow: Int
    public let windowSeconds: TimeInterval
    public let limit: Int?
    public let seedFromProjectData: Bool
    public let dryRun: Bool

    public init(
        projectRoot: URL,
        databaseURL: URL,
        minecraftVersion: String = "26.1.2",
        loader: String = "neoforge",
        loaderVersion: String? = "26.1.2.76",
        maxURLsPerWindow: Int = 5,
        windowSeconds: TimeInterval = 10,
        limit: Int? = nil,
        seedFromProjectData: Bool = false,
        dryRun: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.databaseURL = databaseURL
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.loaderVersion = loaderVersion
        self.maxURLsPerWindow = maxURLsPerWindow
        self.windowSeconds = windowSeconds
        self.limit = limit
        self.seedFromProjectData = seedFromProjectData
        self.dryRun = dryRun
    }
}

public struct ModUpdateScanSummary: Equatable, Sendable {
    public let scanID: String
    public let sourcesChecked: Int
    public let candidatesFound: Int
    public let unresolved: Int
    public let seededSources: Int
}

public struct ModSourceRecord: Equatable, Sendable {
    public let sourceID: String
    public let modKey: String
    public let displayName: String
    public let installedFile: String?
    public let installedVersion: String?
    public let provider: String
    public let sourceURL: String
}

public struct ModUpdateCheckResult: Equatable, Sendable {
    public let source: ModSourceRecord
    public let status: String
    public let latestVersion: String?
    public let latestURL: String?
    public let details: String
}

public struct ModUpdateScanner: Sendable {
    public let config: ModUpdateScannerConfig
    private var database: DuckDBDatabase { DuckDBDatabase(databaseURL: config.databaseURL) }
    private var fileManager: FileManager { FileManager.default }

    public init(config: ModUpdateScannerConfig) {
        self.config = config
    }

    public func run() throws -> ModUpdateScanSummary {
        try initializeDatabase()
        let seeded = config.seedFromProjectData ? try seedSourcesFromProjectData() : 0
        let scanID = "scan_\(Self.compactTimestamp())_\(UUID().uuidString.prefix(8))"
        let startedAt = Self.duckTimestamp(Date())
        if !config.dryRun {
            try execute("""
            INSERT INTO core.mod_update_scans(
              scan_id, started_at, status, urls_checked, candidates_found,
              unresolved, notes, minecraft_version, loader, loader_version
            )
            VALUES (
              \(Self.sqlLiteral(scanID)),
              TIMESTAMP '\(startedAt)',
              'running',
              0,
              0,
              0,
              'started',
              \(Self.sqlLiteral(config.minecraftVersion)),
              \(Self.sqlLiteral(config.loader)),
              \(Self.sqlLiteral(config.loaderVersion))
            );
            """)
        }

        let sources = try loadSources(limit: config.limit)
        var checked = 0
        var candidates = 0
        var unresolved = 0
        for source in sources {
            if checked > 0,
               config.maxURLsPerWindow > 0,
               checked % config.maxURLsPerWindow == 0,
               config.windowSeconds > 0 {
                Thread.sleep(forTimeInterval: config.windowSeconds)
            }
            let result = check(source: source)
            checked += 1
            if result.status == "update_available" {
                candidates += 1
            }
            if ["unresolved", "blocked", "error"].contains(result.status) {
                unresolved += 1
            }
            if !config.dryRun {
                try persist(result: result, scanID: scanID)
            }
        }

        if !config.dryRun {
            try execute("""
            UPDATE core.mod_update_scans
            SET finished_at = TIMESTAMP '\(Self.duckTimestamp(Date()))',
                status = 'completed',
                urls_checked = \(checked),
                candidates_found = \(candidates),
                unresolved = \(unresolved),
                notes = \(Self.sqlLiteral("seeded_sources=\(seeded) throttle=\(config.maxURLsPerWindow)/\(Int(config.windowSeconds))s"))
            WHERE scan_id = \(Self.sqlLiteral(scanID));
            """)
        }
        return ModUpdateScanSummary(scanID: scanID, sourcesChecked: checked, candidatesFound: candidates, unresolved: unresolved, seededSources: seeded)
    }

    public func check(source: ModSourceRecord) -> ModUpdateCheckResult {
        do {
            if source.provider == "manifest" || source.sourceURL.hasPrefix("manifest://") {
                return ModUpdateCheckResult(
                    source: source,
                    status: "missing_source_url",
                    latestVersion: nil,
                    latestURL: nil,
                    details: "current release manifest entry has no Modrinth or CurseForge source URL in DuckDB"
                )
            }
            guard let url = URL(string: source.sourceURL), let host = url.host?.lowercased() else {
                throw ModUpdateScannerError.invalidSourceURL(source.sourceURL)
            }
            if host.contains("neoforged.net") {
                return try checkNeoForge(source: source, sourceURL: url)
            }
            if host.contains("modrinth.com") {
                return try checkModrinth(source: source, sourceURL: url)
            }
            if host.contains("curseforge.com") {
                return try checkCurseForge(source: source, sourceURL: url)
            }
            let body = try fetchText(url)
            if Self.isCloudflareChallenge(body) {
                return ModUpdateCheckResult(
                    source: source,
                    status: "blocked",
                    latestVersion: nil,
                    latestURL: nil,
                    details: "curl received a Cloudflare challenge page; use official API metadata or a mirror URL for this source"
                )
            }
            let latest = Self.parseLatestVersion(fromHTML: body, provider: source.provider)
            let status = Self.classify(installedVersion: source.installedVersion, latestVersion: latest)
            return ModUpdateCheckResult(source: source, status: status, latestVersion: latest, latestURL: source.sourceURL, details: latest == nil ? "latest version could not be parsed from HTML" : "parsed from source HTML")
        } catch {
            return ModUpdateCheckResult(source: source, status: "error", latestVersion: nil, latestURL: nil, details: String(describing: error))
        }
    }

    public static func parseLatestVersion(fromHTML html: String, provider: String) -> String? {
        let patterns = [
            #""version_number"\s*:\s*"([^"]+)""#,
            #""versionNumber"\s*:\s*"([^"]+)""#,
            #""latestVersion"\s*:\s*"([^"]+)""#,
            #""fileName"\s*:\s*"([^"]+\.(?:jar|zip))""#
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern: pattern, in: html) {
                if value.hasSuffix(".jar") || value.hasSuffix(".zip") {
                    return versionFromFilename(value)
                }
                return cleanVersionCandidate(value, provider: provider)
            }
        }
        return nil
    }

    public static func isCloudflareChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("<title>just a moment...</title>")
            || lower.contains("cf-mitigated")
            || lower.contains("challenges.cloudflare.com")
    }

    public static func provider(for sourceURL: String) -> String {
        let lower = sourceURL.lowercased()
        if lower.contains("neoforged.net") { return "neoforge" }
        if lower.contains("modrinth.com") { return "modrinth" }
        if lower.contains("curseforge.com") { return "curseforge" }
        return "web"
    }

    private func initializeDatabase() throws {
        try fileManager.createDirectory(at: config.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE IF NOT EXISTS core.mod_sources (
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR NOT NULL,
          display_name VARCHAR NOT NULL,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR NOT NULL,
          source_url VARCHAR NOT NULL,
          priority INTEGER NOT NULL DEFAULT 100,
          active BOOLEAN NOT NULL DEFAULT true,
          created_at TIMESTAMP NOT NULL DEFAULT now(),
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS core.mod_update_scans (
          scan_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP NOT NULL,
          finished_at TIMESTAMP,
          status VARCHAR NOT NULL,
          urls_checked INTEGER NOT NULL DEFAULT 0,
          candidates_found INTEGER NOT NULL DEFAULT 0,
          unresolved INTEGER NOT NULL DEFAULT 0,
          notes VARCHAR,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS core.mod_update_scan_results (
          result_id VARCHAR PRIMARY KEY,
          scan_id VARCHAR NOT NULL,
          source_id VARCHAR NOT NULL,
          checked_at TIMESTAMP NOT NULL,
          provider VARCHAR NOT NULL,
          source_url VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          installed_file VARCHAR,
          installed_version VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          details VARCHAR,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
        ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
        ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
        ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE core.mod_update_scans ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
        ALTER TABLE core.mod_update_scans ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
        ALTER TABLE core.mod_update_scans ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE core.mod_update_scan_results ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
        ALTER TABLE core.mod_update_scan_results ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
        ALTER TABLE core.mod_update_scan_results ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        CREATE TABLE IF NOT EXISTS core.failed_mod_update_status (
          failed_mod_id VARCHAR PRIMARY KEY,
          title VARCHAR NOT NULL,
          source_url VARCHAR,
          filename VARCHAR,
          installed_version VARCHAR,
          failure_reason VARCHAR NOT NULL,
          details VARCHAR,
          failed_at TIMESTAMP,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR,
          latest_status VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          last_check_details VARCHAR,
          last_checked_at TIMESTAMP,
          active_status VARCHAR NOT NULL DEFAULT 'failed',
          updated_at TIMESTAMP NOT NULL DEFAULT now()
        );
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS filename VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS installed_version VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS latest_status VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS latest_version VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS latest_url VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS last_check_details VARCHAR;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS last_checked_at TIMESTAMP;
        ALTER TABLE core.failed_mod_update_status ADD COLUMN IF NOT EXISTS active_status VARCHAR DEFAULT 'failed';
        """)
    }

    private func seedSourcesFromProjectData() throws -> Int {
        var seeded = 0
        seeded += try seedSourcesFromSiteInventory()
        seeded += try seedSourcesFromReleaseManifests()
        seeded += try seedFailedModsFromStaticPage()
        seeded += try seedTargetVersionCandidatesFromLiveBaseline()
        return seeded
    }

    private func seedTargetVersionCandidatesFromLiveBaseline() throws -> Int {
        guard let referenceVersion = try liveReferenceMinecraftVersion(),
              referenceVersion != config.minecraftVersion else {
            return 0
        }

        let targetVersion = config.minecraftVersion
        let referenceLiteral = Self.sqlLiteral(referenceVersion)
        let targetLiteral = Self.sqlLiteral(targetVersion)
        let loaderLiteral = Self.sqlLiteral(config.loader)
        let loaderVersionLiteral = Self.sqlLiteral(config.loaderVersion)
        let targetNote = Self.sqlLiteral("Copied from \(referenceVersion) as a \(targetVersion) update-tracking candidate; requires compatibility scan and validation before deployment.")

        let seededSourcesCSV = try query("""
        SELECT COUNT(*)
        FROM core.mod_sources s
        WHERE s.active = true
          AND COALESCE(s.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
          AND NOT EXISTS (
            SELECT 1
            FROM core.mod_sources t
            WHERE COALESCE(t.minecraft_version, \(targetLiteral)) = \(targetLiteral)
              AND t.mod_key = s.mod_key
              AND COALESCE(t.source_url, '') = COALESCE(s.source_url, '')
              AND COALESCE(t.installed_file, '') = COALESCE(s.installed_file, '')
          );
        """)
        let seededSources = Int(csvRows(seededSourcesCSV).first?.first ?? "0") ?? 0

        try execute("""
        BEGIN TRANSACTION;

        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, created_at, updated_at,
          minecraft_version, loader, loader_version
        )
        SELECT
          'src_' || md5(s.mod_key || '|' || COALESCE(s.source_url, '') || '|' || COALESCE(s.installed_file, '') || '|' || \(targetLiteral)) AS source_id,
          s.mod_key,
          s.display_name,
          s.installed_file,
          s.installed_version,
          s.provider,
          s.source_url,
          s.priority,
          false,
          now(),
          now(),
          \(targetLiteral),
          \(loaderLiteral),
          \(loaderVersionLiteral)
        FROM core.mod_sources s
        WHERE s.active = true
          AND COALESCE(s.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
          AND NOT EXISTS (
            SELECT 1
            FROM core.mod_sources t
            WHERE COALESCE(t.minecraft_version, \(targetLiteral)) = \(targetLiteral)
              AND t.mod_key = s.mod_key
              AND COALESCE(t.source_url, '') = COALESCE(s.source_url, '')
              AND COALESCE(t.installed_file, '') = COALESCE(s.installed_file, '')
          );

        CREATE OR REPLACE TEMP TABLE pummelchen_target_mod_copy_map AS
        SELECT
          m.id AS source_mod_id,
          (SELECT COALESCE(MAX(id), 0) FROM core.mods)
            + row_number() OVER (ORDER BY m.id) AS target_mod_id,
          m.canonical_key,
          m.name,
          m.category,
          m.active_status,
          m.server_status,
          m.client_package,
          m.primary_url,
          m.loader AS source_loader,
          m.loader_version AS source_loader_version
        FROM core.mods m
        WHERE COALESCE(m.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
          AND NOT EXISTS (
            SELECT 1
            FROM core.mods t
            WHERE COALESCE(t.minecraft_version, \(targetLiteral)) = \(targetLiteral)
              AND t.canonical_key = m.canonical_key
          );

        INSERT INTO core.mods(
          id, canonical_key, name, category, active_status, server_status,
          client_package, primary_url, updated_at, minecraft_version, loader, loader_version
        )
        SELECT
          target_mod_id,
          canonical_key,
          name,
          category,
          CASE WHEN lower(active_status) = 'ok' THEN 'awaiting_compatible_release' ELSE active_status END,
          CASE
            WHEN lower(active_status) = 'ok' THEN \(targetNote)
            ELSE server_status
          END,
          client_package,
          primary_url,
          now(),
          \(targetLiteral),
          \(loaderLiteral),
          \(loaderVersionLiteral)
        FROM pummelchen_target_mod_copy_map;

        INSERT INTO core.mod_files(
          id, mod_id, role, file_name, path_hint, installed_on_server,
          included_in_client, status, minecraft_version, loader, loader_version
        )
        SELECT
          (SELECT COALESCE(MAX(id), 0) FROM core.mod_files)
            + row_number() OVER (ORDER BY mf.id),
          map.target_mod_id,
          mf.role,
          mf.file_name,
          mf.path_hint,
          false,
          false,
          CASE
            WHEN lower(COALESCE(mf.status, '')) IN ('ok', 'runtime ok', 'installed', 'client-only: included', 'client dependency: included') THEN 'Needs 26.2 compatibility test'
            ELSE mf.status
          END,
          \(targetLiteral),
          \(loaderLiteral),
          \(loaderVersionLiteral)
        FROM core.mod_files mf
        JOIN pummelchen_target_mod_copy_map map ON map.source_mod_id = mf.mod_id
        WHERE NOT EXISTS (
          SELECT 1
          FROM core.mod_files existing
          WHERE existing.mod_id = map.target_mod_id
            AND existing.file_name = mf.file_name
            AND COALESCE(existing.minecraft_version, \(targetLiteral)) = \(targetLiteral)
        );

        INSERT INTO core.mod_server_files(
          id, mod_id, file_name, role, source_url, compatibility_status,
          installed_on_server, included_in_client, selected, file_sha256,
          file_size_bytes, last_synced, notes, minecraft_version, loader, loader_version
        )
        SELECT
          (SELECT COALESCE(MAX(id), 0) FROM core.mod_server_files)
            + row_number() OVER (ORDER BY msf.id),
          map.target_mod_id,
          msf.file_name,
          msf.role,
          msf.source_url,
          CASE WHEN lower(msf.compatibility_status) = 'ok' THEN 'awaiting_compatible_release' ELSE msf.compatibility_status END,
          false,
          false,
          false,
          msf.file_sha256,
          msf.file_size_bytes,
          now(),
          concat_ws(' ', NULLIF(msf.notes, ''), \(targetNote)),
          \(targetLiteral),
          \(loaderLiteral),
          \(loaderVersionLiteral)
        FROM core.mod_server_files msf
        JOIN pummelchen_target_mod_copy_map map ON map.source_mod_id = msf.mod_id
        WHERE NOT EXISTS (
          SELECT 1
          FROM core.mod_server_files existing
          WHERE existing.mod_id = map.target_mod_id
            AND existing.file_name = msf.file_name
            AND COALESCE(existing.minecraft_version, \(targetLiteral)) = \(targetLiteral)
        );

        DROP TABLE IF EXISTS pummelchen_target_mod_copy_map;
        COMMIT;
        """)

        return seededSources
    }

    private func liveReferenceMinecraftVersion() throws -> String? {
        let csv: String
        do {
            csv = try query("""
            SELECT minecraft_version
            FROM core.minecraft_server_versions
            WHERE is_live = true
            ORDER BY sort_order, minecraft_version
            LIMIT 1;
            """)
        } catch {
            return nil
        }
        if let value = csvRows(csv).first?.first, !value.isEmpty {
            return value
        }
        return config.minecraftVersion == "26.1.2" ? nil : "26.1.2"
    }

    private func isLiveMinecraftVersion() throws -> Bool {
        guard let referenceVersion = try liveReferenceMinecraftVersion() else {
            return config.minecraftVersion == "26.1.2"
        }
        return referenceVersion == config.minecraftVersion
    }

    private func isStagingMinecraftVersion() throws -> Bool {
        guard let referenceVersion = try liveReferenceMinecraftVersion() else {
            return false
        }
        return referenceVersion != config.minecraftVersion
    }


    private func seedSourcesFromSiteInventory() throws -> Int {
        let indexCandidates = [
            config.projectRoot.appendingPathComponent("site/public/index.html"),
            config.projectRoot.appendingPathComponent("Server App/nginx/site/public/index.html")
        ]
        guard let indexURL = indexCandidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return 0
        }
        let html = try String(contentsOf: indexURL, encoding: .utf8)
        var seededSourceIDs = Set<String>()
        var sources: [ModSourceRecord] = []
        for scriptID in ["serverModsData", "clientModsData"] {
            for row in Self.embeddedJSONRows(scriptID: scriptID, html: html) {
                guard let sourceURL = row["sourceUrl"] as? String,
                      sourceURL.hasPrefix("http://") || sourceURL.hasPrefix("https://") else {
                    continue
                }
                let displayName = ((row["name"] as? String) ?? "Unknown Mod").trimmingCharacters(in: .whitespacesAndNewlines)
                let files = Self.splitFileList((row["files"] as? String) ?? (row["versionFile"] as? String) ?? "")
                let fileList = files.count == 1 ? files.map(Optional.some) : [nil]
                for installedFile in fileList {
                    let modKey = Self.modKey(displayName: displayName, installedFile: installedFile, sourceURL: sourceURL)
                    let source = ModSourceRecord(
                        sourceID: Self.versionedSourceID(Self.stableID("\(modKey)|\(sourceURL)|\(installedFile ?? "")"), minecraftVersion: config.minecraftVersion),
                        modKey: modKey,
                        displayName: displayName,
                        installedFile: installedFile,
                        installedVersion: installedFile.flatMap(Self.versionFromFilename),
                        provider: Self.provider(for: sourceURL),
                        sourceURL: sourceURL
                    )
                    sources.append(source)
                    seededSourceIDs.insert(source.sourceID)
                }
            }
        }
        try upsert(sources: sources)
        return seededSourceIDs.count
    }

    private func seedSourcesFromReleaseManifests() throws -> Int {
        guard let releaseID = try currentReleaseID() else {
            return 0
        }
        var existingFiles = try existingInstalledFiles()
        var sources: [ModSourceRecord] = []
        var seeded = 0
        for manifestName in ["server-files.tsv", "client-package.tsv"] {
            guard let manifestURL = releaseManifestURL(releaseID: releaseID, manifestName: manifestName),
                  let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                continue
            }
            for entry in Self.releaseManifestEntries(text) {
                guard Self.scannableManifestRoles.contains(entry.role),
                      !existingFiles.contains(entry.fileName.lowercased()) else {
                    continue
                }
                let displayName = Self.displayNameFromManifestFile(entry.fileName)
                let sourceURL = "manifest://\(releaseID)/\(entry.role)/\(entry.fileName)"
                let source = ModSourceRecord(
                    sourceID: Self.versionedSourceID(Self.stableID("\(entry.role)|\(entry.fileName)|\(releaseID)"), minecraftVersion: config.minecraftVersion),
                    modKey: Self.modKey(displayName: displayName, installedFile: entry.fileName, sourceURL: sourceURL),
                    displayName: displayName,
                    installedFile: entry.fileName,
                    installedVersion: Self.versionFromFilename(entry.fileName),
                    provider: "manifest",
                    sourceURL: sourceURL
                )
                sources.append(source)
                existingFiles.insert(entry.fileName.lowercased())
                seeded += 1
            }
        }
        try upsert(sources: sources)
        return seeded
    }

    private func seedFailedModsFromStaticPage() throws -> Int {
        let candidates = [
            config.projectRoot.appendingPathComponent("site/public/failed-mods.html"),
            config.projectRoot.appendingPathComponent("Server App/nginx/site/public/failed-mods.html")
        ]
        guard let page = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }),
              let html = try? String(contentsOf: page, encoding: .utf8) else {
            return 0
        }
        let rows = Self.failedModRows(fromHTML: html)
        var statements: [String] = ["BEGIN TRANSACTION;"]
        for row in rows {
            let failedModID = Self.versionedSourceID(row.id, minecraftVersion: config.minecraftVersion)
            let failedAtSQL = row.failedAt.isEmpty ? "NULL" : "TIMESTAMP \(Self.sqlLiteral(Self.duckTimestamp(fromDisplay: row.failedAt)))"
            statements.append("DELETE FROM core.failed_mod_update_status WHERE failed_mod_id = \(Self.sqlLiteral(row.id));")
            statements.append("""
            INSERT OR REPLACE INTO core.failed_mod_update_status(
              failed_mod_id, title, source_url, filename, installed_version,
              failure_reason, details, failed_at, minecraft_version, loader,
              loader_version, active_status, updated_at
            )
            VALUES (
              \(Self.sqlLiteral(failedModID)),
              \(Self.sqlLiteral(row.title)),
              \(Self.sqlLiteral(row.sourceURL)),
              \(Self.sqlLiteral(row.filename)),
              \(Self.sqlLiteral(row.version)),
              \(Self.sqlLiteral(row.failureReason)),
              \(Self.sqlLiteral(row.details)),
              \(failedAtSQL),
              \(Self.sqlLiteral(config.minecraftVersion)),
              \(Self.sqlLiteral(config.loader)),
              \(Self.sqlLiteral(config.loaderVersion)),
              'failed',
              now()
            );
            """)
        }
        statements.append("COMMIT;")
        if !rows.isEmpty {
            try execute(statements.joined(separator: "\n"))
        }
        return rows.count
    }

    private func loadSources(limit: Int?) throws -> [ModSourceRecord] {
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        let activeClause = try isStagingMinecraftVersion() ? "" : "AND active = true"
        let csv = try query("""
        SELECT source_id, mod_key, display_name, COALESCE(installed_file, ''), COALESCE(installed_version, ''), provider, source_url, priority
        FROM core.mod_sources
        WHERE COALESCE(minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion))
          \(activeClause)
        UNION ALL
        SELECT
          'failed_' || failed_mod_id AS source_id,
          regexp_replace(lower(title), '[^a-z0-9]+', '-', 'g') AS mod_key,
          title AS display_name,
          COALESCE(filename, '') AS installed_file,
          COALESCE(installed_version, '') AS installed_version,
          CASE
            WHEN lower(COALESCE(source_url, '')) LIKE '%modrinth.com%' THEN 'modrinth'
            WHEN lower(COALESCE(source_url, '')) LIKE '%curseforge.com%' THEN 'curseforge'
            ELSE 'web'
          END AS provider,
          COALESCE(source_url, '') AS source_url,
          500 AS priority
        FROM core.failed_mod_update_status
        WHERE active_status = 'failed'
          AND COALESCE(minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion))
          AND (COALESCE(source_url, '') LIKE 'http://%' OR COALESCE(source_url, '') LIKE 'https://%')
        ORDER BY priority ASC, display_name ASC, source_url ASC
        \(limitClause);
        """)
        return csvRows(csv).compactMap { row in
            guard row.count >= 7 else { return nil }
            return ModSourceRecord(
                sourceID: row[0],
                modKey: row[1],
                displayName: row[2],
                installedFile: row[3].isEmpty ? nil : row[3],
                installedVersion: row[4].isEmpty ? nil : row[4],
                provider: row[5],
                sourceURL: row[6]
            )
        }
    }

    private func checkNeoForge(source: ModSourceRecord, sourceURL: URL) throws -> ModUpdateCheckResult {
        let metadataURL = Self.neoForgeMetadataURL(from: sourceURL)
        let metadata = try fetchText(metadataURL)
        guard let latestVersion = Self.latestNeoForgeVersion(fromMetadata: metadata, minecraftVersion: config.minecraftVersion) else {
            return ModUpdateCheckResult(
                source: source,
                status: "unresolved",
                latestVersion: nil,
                latestURL: metadataURL.absoluteString,
                details: "official NeoForged Maven metadata returned no NeoForge build for Minecraft \(config.minecraftVersion)"
            )
        }
        return ModUpdateCheckResult(
            source: source,
            status: Self.classify(installedVersion: source.installedVersion, latestVersion: latestVersion),
            latestVersion: latestVersion,
            latestURL: Self.neoForgeInstallerURL(version: latestVersion),
            details: "checked official NeoForged download metadata for Minecraft \(config.minecraftVersion)"
        )
    }

    private func checkModrinth(source: ModSourceRecord, sourceURL: URL) throws -> ModUpdateCheckResult {
        guard let slug = Self.modrinthSlug(from: sourceURL) else {
            let body = try fetchText(sourceURL)
            let latest = Self.parseLatestVersion(fromHTML: body, provider: source.provider)
            return ModUpdateCheckResult(source: source, status: Self.classify(installedVersion: source.installedVersion, latestVersion: latest), latestVersion: latest, latestURL: source.sourceURL, details: latest == nil ? "modrinth slug not found and HTML parse failed" : "parsed from Modrinth HTML")
        }
        let category = Self.modrinthCategory(from: sourceURL)
        let loaderQuery: String
        if category == "mod" {
            loaderQuery = "&loaders=%5B%22\(config.loader)%22%5D"
        } else {
            loaderQuery = ""
        }
        let endpoint = "https://api.modrinth.com/v2/project/\(slug)/version?game_versions=%5B%22\(config.minecraftVersion)%22%5D\(loaderQuery)"
        guard let endpointURL = URL(string: endpoint) else {
            return ModUpdateCheckResult(
                source: source,
                status: "unresolved",
                latestVersion: nil,
                latestURL: source.sourceURL,
                details: "invalid Modrinth endpoint URL"
            )
        }
        let data = try fetchData(endpointURL)
        guard let versions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let latest = versions.first else {
            return ModUpdateCheckResult(source: source, status: "unresolved", latestVersion: nil, latestURL: endpoint, details: "Modrinth API returned no compatible versions")
        }
        let latestVersion = latest["version_number"] as? String
        let latestURL = ((latest["files"] as? [[String: Any]])?.first(where: { ($0["primary"] as? Bool) == true }) ?? (latest["files"] as? [[String: Any]])?.first)?["url"] as? String
        return ModUpdateCheckResult(
            source: source,
            status: Self.classify(installedVersion: source.installedVersion, latestVersion: latestVersion),
            latestVersion: latestVersion,
            latestURL: latestURL ?? endpoint,
            details: "checked Modrinth project API for \(config.loader) \(config.minecraftVersion)"
        )
    }

    private func checkCurseForge(source: ModSourceRecord, sourceURL: URL) throws -> ModUpdateCheckResult {
        let projectID: Int?
        if let value = Self.curseForgeProjectID(fromSourceID: source.sourceID) {
            projectID = value
        } else if let slug = Self.curseForgeSlug(from: sourceURL) {
            projectID = try resolveCurseForgeProjectID(slug: slug)
        } else {
            projectID = nil
        }

        guard let projectID else {
            let body = try fetchText(sourceURL)
            let latest = Self.parseLatestVersion(fromHTML: body, provider: source.provider)
            return ModUpdateCheckResult(
                source: source,
                status: Self.classify(installedVersion: source.installedVersion, latestVersion: latest),
                latestVersion: latest,
                latestURL: source.sourceURL,
                details: latest == nil ? "curseforge project id not found and HTML parse failed" : "parsed from CurseForge HTML"
            )
        }

        let requiresLoader = Self.curseForgeCategory(from: sourceURL) == "mc-mods"
        let loaderQuery = requiresLoader ? "&modLoaderType=\(Self.curseForgeLoaderType(config.loader))" : ""
        let endpoint = "https://www.curseforge.com/api/v1/mods/\(projectID)/files?pageIndex=0&pageSize=50&gameVersion=\(Self.urlQuery(config.minecraftVersion))\(loaderQuery)"
        guard let endpointURL = URL(string: endpoint) else {
            return ModUpdateCheckResult(
                source: source,
                status: "unresolved",
                latestVersion: nil,
                latestURL: source.sourceURL,
                details: "invalid CurseForge files endpoint URL"
            )
        }
        let data = try fetchData(endpointURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["data"] as? [[String: Any]],
              let latest = Self.bestCurseForgeFile(from: files, loader: requiresLoader ? config.loader : nil, minecraftVersion: config.minecraftVersion) else {
            return ModUpdateCheckResult(
                source: source,
                status: "unresolved",
                latestVersion: nil,
                latestURL: endpoint,
                details: "CurseForge API returned no compatible \(config.loader) \(config.minecraftVersion) files"
            )
        }

        let fileName = (latest["fileName"] as? String) ?? (latest["displayName"] as? String)
        let latestVersion = Self.curseForgeVersion(
            fileName: fileName,
            installedFile: source.installedFile,
            installedVersion: source.installedVersion
        )
        let fileID = latest["id"].map { String(describing: $0) }
        let latestURL = fileID.map { "https://www.curseforge.com/api/v1/mods/\(projectID)/files/\($0)/download" } ?? endpoint
        return ModUpdateCheckResult(
            source: source,
            status: Self.classify(installedVersion: source.installedVersion, latestVersion: latestVersion),
            latestVersion: latestVersion,
            latestURL: latestURL,
            details: "checked CurseForge project API for \(config.loader) \(config.minecraftVersion)"
        )
    }

    private func resolveCurseForgeProjectID(slug: String) throws -> Int? {
        let endpoint = "https://api.curse.tools/v1/cf/mods/search?gameId=432&slug=\(Self.urlQuery(slug))&pageSize=5"
        guard let url = URL(string: endpoint) else { return nil }
        let data = try fetchData(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mods = object["data"] as? [[String: Any]] else {
            return nil
        }
        return mods.first(where: { ($0["slug"] as? String) == slug })?["id"] as? Int
            ?? mods.first?["id"] as? Int
    }

    private func upsert(sources: [ModSourceRecord]) throws {
        guard !sources.isEmpty else { return }
        let sourceActive = try isLiveMinecraftVersion()
        var statements: [String] = ["BEGIN TRANSACTION;"]
        for source in sources {
            statements.append("""
            DELETE FROM core.mod_sources WHERE source_id = \(Self.sqlLiteral(source.sourceID));
            INSERT INTO core.mod_sources(
              source_id, mod_key, display_name, installed_file, installed_version,
              provider, source_url, priority, active, updated_at,
              minecraft_version, loader, loader_version
            )
            VALUES (
              \(Self.sqlLiteral(source.sourceID)),
              \(Self.sqlLiteral(source.modKey)),
              \(Self.sqlLiteral(source.displayName)),
              \(Self.sqlLiteral(source.installedFile)),
              \(Self.sqlLiteral(source.installedVersion)),
              \(Self.sqlLiteral(source.provider)),
              \(Self.sqlLiteral(source.sourceURL)),
              100,
              \(sourceActive ? "true" : "false"),
              now(),
              \(Self.sqlLiteral(config.minecraftVersion)),
              \(Self.sqlLiteral(config.loader)),
              \(Self.sqlLiteral(config.loaderVersion))
            );
            """)
        }
        statements.append("COMMIT;")
        try execute(statements.joined(separator: "\n"))
    }

    private func persist(result: ModUpdateCheckResult, scanID: String) throws {
        try execute("""
        INSERT INTO core.mod_update_scan_results(
          result_id, scan_id, source_id, checked_at, provider, source_url, status,
          installed_file, installed_version, latest_version, latest_url, details,
          minecraft_version, loader, loader_version
        )
        VALUES (
          \(Self.sqlLiteral(UUID().uuidString)),
          \(Self.sqlLiteral(scanID)),
          \(Self.sqlLiteral(result.source.sourceID)),
          TIMESTAMP '\(Self.duckTimestamp(Date()))',
          \(Self.sqlLiteral(result.source.provider)),
          \(Self.sqlLiteral(result.source.sourceURL)),
          \(Self.sqlLiteral(result.status)),
          \(Self.sqlLiteral(result.source.installedFile)),
          \(Self.sqlLiteral(result.source.installedVersion)),
          \(Self.sqlLiteral(result.latestVersion)),
          \(Self.sqlLiteral(result.latestURL)),
          \(Self.sqlLiteral(result.details)),
          \(Self.sqlLiteral(config.minecraftVersion)),
          \(Self.sqlLiteral(config.loader)),
          \(Self.sqlLiteral(config.loaderVersion))
        );
        """)
        if result.source.sourceID.hasPrefix("failed_") {
            try execute("""
            UPDATE core.failed_mod_update_status
            SET latest_status = \(Self.sqlLiteral(result.status)),
                latest_version = \(Self.sqlLiteral(result.latestVersion)),
                latest_url = \(Self.sqlLiteral(result.latestURL)),
                last_check_details = \(Self.sqlLiteral(result.details)),
                last_checked_at = TIMESTAMP '\(Self.duckTimestamp(Date()))',
                loader = \(Self.sqlLiteral(config.loader)),
                loader_version = \(Self.sqlLiteral(config.loaderVersion)),
                updated_at = now()
            WHERE failed_mod_id = \(Self.sqlLiteral(String(result.source.sourceID.dropFirst("failed_".count))));
            """)
        } else if try isStagingMinecraftVersion() {
            let scanCompatible = ["current", "update_available", "unknown_installed_version"].contains(result.status)
            try execute("""
            UPDATE core.mod_sources
            SET active = \(scanCompatible ? "true" : "false"),
                updated_at = now()
            WHERE source_id = \(Self.sqlLiteral(result.source.sourceID))
              AND COALESCE(minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion));
            """)
        }
    }

    private func fetchText(_ url: URL) throws -> String {
        String(decoding: try fetchData(url), as: UTF8.self)
    }

    private func fetchData(_ url: URL) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("PummelchenModUpdateScanner/1.0", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        let output = URLFetchResultBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                output.store(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if let data,
                   String(decoding: data, as: UTF8.self).lowercased().contains("challenges.cloudflare.com") {
                    output.store(.success(data))
                    return
                }
                output.store(.failure(ModUpdateScannerError.network("HTTP \(http.statusCode) for \(url.absoluteString)")))
                return
            }
            output.store(.success(data ?? Data()))
        }.resume()
        semaphore.wait()
        guard let result = output.result() else {
            throw ModUpdateScannerError.network("request produced no response for \(url.absoluteString)")
        }
        return try result.get()
    }

    private func execute(_ sql: String) throws {
        try database.execute(sql)
    }

    private func query(_ sql: String) throws -> String {
        try database.queryCSV(sql)
    }

    private func existingInstalledFiles() throws -> Set<String> {
        let csv = try query("""
        SELECT DISTINCT lower(COALESCE(installed_file, '')) AS installed_file
        FROM core.mod_sources
        WHERE COALESCE(minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion))
          AND COALESCE(installed_file, '') <> '';
        """)
        return Set(csvRows(csv).compactMap { row in
            guard let value = row.first, !value.isEmpty else { return nil }
            return value
        })
    }

    private func currentReleaseID() throws -> String? {
        let serverKey = "minecraft_\(config.minecraftVersion.replacingOccurrences(of: ".", with: "_"))"
        let candidates = [
            config.projectRoot.appendingPathComponent("site/public/downloads/current-release-\(config.minecraftVersion).json"),
            config.projectRoot.appendingPathComponent("site/public/downloads/current-release-\(serverKey).json"),
            config.projectRoot.appendingPathComponent("site/public/downloads/current-release.json"),
            config.projectRoot.appendingPathComponent("downloads/current-release.json")
        ]
        for currentURL in candidates where fileManager.fileExists(atPath: currentURL.path) {
            let data = try Data(contentsOf: currentURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let releaseMinecraftVersion = (object["minecraft_version"] as? String) ?? (object["minecraftVersion"] as? String)
            let isVersionScoped = currentURL.lastPathComponent != "current-release.json"
            guard isVersionScoped || releaseMinecraftVersion == nil || releaseMinecraftVersion == config.minecraftVersion else {
                continue
            }
            if let releaseID = object["release_id"] as? String ?? object["releaseID"] as? String {
                return releaseID
            }
        }
        return nil
    }

    private func releaseManifestURL(releaseID: String, manifestName: String) -> URL? {
        [
            config.projectRoot.appendingPathComponent("releases/\(releaseID)/manifests/\(manifestName)"),
            config.projectRoot.appendingPathComponent("site/public/downloads/releases/\(releaseID)/manifests/\(manifestName)")
        ].first(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private static func classify(installedVersion: String?, latestVersion: String?) -> String {
        guard let latestVersion, !latestVersion.isEmpty else { return "unresolved" }
        guard let installedVersion, !installedVersion.isEmpty else { return "unknown_installed_version" }
        return normalizedVersion(installedVersion) == normalizedVersion(latestVersion) ? "current" : "update_available"
    }

    public static let neoForgeOfficialDownloadPageURL = "https://neoforged.net/"
    public static let neoForgeOfficialMetadataURL = "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml"

    public static func neoForgeMetadataURL(from sourceURL: URL) -> URL {
        if sourceURL.lastPathComponent == "maven-metadata.xml" {
            return sourceURL
        }
        return URL(string: neoForgeOfficialMetadataURL)!
    }

    public static func neoForgeInstallerURL(version: String) -> String {
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(version)/neoforge-\(version)-installer.jar"
    }

    public static func latestNeoForgeVersion(fromMetadata metadata: String, minecraftVersion: String) -> String? {
        let prefix = "\(minecraftVersion)."
        return matches(pattern: #"<version>\s*([^<]+)\s*</version>"#, in: metadata)
            .filter { $0.hasPrefix(prefix) }
            .last
    }

    public static func modrinthCategory(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        return parts.first { ["mod", "shader", "datapack", "resourcepack", "plugin", "modpack"].contains($0) }
    }

    public static func modrinthSlug(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let category = modrinthCategory(from: url),
              let index = parts.firstIndex(of: category),
              parts.indices.contains(index + 1) else { return nil }
        return parts[index + 1]
    }

    public static func curseForgeCategory(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let minecraftIndex = parts.firstIndex(of: "minecraft"),
              parts.indices.contains(minecraftIndex + 1) else { return nil }
        return parts[minecraftIndex + 1]
    }

    public static func curseForgeSlug(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let category = curseForgeCategory(from: url),
              let index = parts.firstIndex(of: category),
              parts.indices.contains(index + 1) else { return nil }
        return parts[index + 1]
    }

    public static func curseForgeProjectID(fromSourceID sourceID: String) -> Int? {
        let pattern = #"^curseforge_(\d+)(?:_|$)"#
        guard let value = firstMatch(pattern: pattern, in: sourceID) else {
            return nil
        }
        return Int(value)
    }

    public static func bestCurseForgeFile(from files: [[String: Any]], loader: String?, minecraftVersion: String) -> [String: Any]? {
        let loaderName = loader?.lowercased() == "neoforge" ? "neoforge" : loader?.lowercased()
        return files.first { file in
            guard let versions = file["gameVersions"] as? [String] else { return false }
            let normalized = versions.map { $0.lowercased() }
            guard normalized.contains(minecraftVersion.lowercased()) else { return false }
            guard let loaderName else { return true }
            return normalized.contains(loaderName)
        }
    }

    public static func curseForgeVersion(fileName: String?, installedFile: String?, installedVersion: String?) -> String? {
        if let fileName,
           let installedFile,
           fileName.caseInsensitiveCompare(installedFile) == .orderedSame {
            return installedVersion ?? versionFromFilename(fileName)
        }
        return fileName.flatMap(versionFromFilename)
    }

    private static func curseForgeLoaderType(_ loader: String) -> Int {
        switch loader.lowercased() {
        case "forge": return 1
        case "fabric": return 4
        case "quilt": return 5
        case "neoforge": return 6
        default: return 0
        }
    }

    private static func urlQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func files(from value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.hasSuffix(".jar") || $0.hasSuffix(".zip")) }
    }

    private static func splitFileList(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: " + ", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.hasSuffix(".jar") || $0.hasSuffix(".zip")) }
    }

    private static var scannableManifestRoles: Set<String> {
        ["server_mod", "client_mods", "client_resourcepacks", "client_shaderpacks", "client_tools"]
    }

    private static func embeddedJSONRows(scriptID: String, html: String) -> [[String: Any]] {
        let marker = "<script type=\"application/json\" id=\"\(scriptID)\">"
        guard let start = html.range(of: marker) else { return [] }
        let afterStart = html[start.upperBound...]
        guard let end = afterStart.range(of: "</script>") else { return [] }
        let jsonText = String(afterStart[..<end.lowerBound])
        guard let data = jsonText.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rows
    }

    private static func releaseManifestEntries(_ text: String) -> [(role: String, fileName: String)] {
        text.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return nil }
            let fileName = URL(fileURLWithPath: fields[1]).lastPathComponent
            return fileName.isEmpty ? nil : (fields[0], fileName)
        }
    }

    private static func displayNameFromManifestFile(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: #"\.(jar|zip|json|toml|properties|txt|sh)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct FailedModSeedRow {
        let id: String
        let failedAt: String
        let title: String
        let sourceURL: String?
        let filename: String?
        let version: String?
        let failureReason: String
        let details: String
    }

    private static func failedModRows(fromHTML html: String) -> [FailedModSeedRow] {
        let pattern = #"<tr>\s*<td[^>]*>(.*?)</td>\s*<td[^>]*>(.*?)</td>\s*<td[^>]*>(.*?)</td>\s*<td[^>]*>(.*?)</td>\s*</tr>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: nsRange).compactMap { match in
            guard match.numberOfRanges >= 5,
                  let timestampRange = Range(match.range(at: 1), in: html),
                  let modRange = Range(match.range(at: 2), in: html),
                  let reasonRange = Range(match.range(at: 3), in: html),
                  let detailsRange = Range(match.range(at: 4), in: html) else {
                return nil
            }
            let modHTML = String(html[modRange])
            let title = htmlText(modHTML)
            guard !title.isEmpty else { return nil }
            let sourceURL = firstMatch(pattern: #"href="([^"]+)""#, in: modHTML)?.replacingOccurrences(of: "&amp;", with: "&")
            let details = htmlText(String(html[detailsRange]))
            let filename = firstMatch(pattern: #"([A-Za-z0-9._+\-()\[\] ]+\.(?:jar|zip))"#, in: details)
            let version = filename.flatMap(versionFromFilename)
            let id = stableID("\(title)|\(sourceURL ?? "")|\(String(html[timestampRange]))")
            return FailedModSeedRow(
                id: id,
                failedAt: htmlText(String(html[timestampRange])),
                title: title,
                sourceURL: sourceURL,
                filename: filename,
                version: version,
                failureReason: htmlText(String(html[reasonRange])),
                details: details
            )
        }
    }

    private static func htmlText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func duckTimestamp(fromDisplay value: String) -> String {
        if value.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            return value
        }
        return "1970-01-01 00:00:00"
    }

    private static func modKey(displayName: String, installedFile: String?, sourceURL: String) -> String {
        let raw = installedFile ?? displayName
        let value = raw
            .lowercased()
            .replacingOccurrences(of: #"\.(jar|zip)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? stableID(sourceURL) : value
    }

    private static func versionFromFilename(_ filename: String) -> String? {
        let base = filename.replacingOccurrences(of: #"\.(jar|zip)$"#, with: "", options: .regularExpression)
        let patterns = [
            #"(?i)(?:mc|neoforge|forge)?-?(\d+(?:\.\d+){1,4}(?:[+._-][A-Za-z0-9.]+)*)$"#,
            #"(?i)(v?\d+(?:\.\d+){1,4}(?:[+._-][A-Za-z0-9.]+)*)"#
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern: pattern, in: base) {
                return value
            }
        }
        return nil
    }

    private static func cleanVersionCandidate(_ value: String, provider: String) -> String {
        var result = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "modrinth", result.contains(" - ") {
            result = String(result.split(separator: " - ").first ?? Substring(result))
        }
        if result.lowercased().contains("minecraft mod") {
            result = result.replacingOccurrences(of: " - Minecraft Mod", with: "")
        }
        return result
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"^(v|mc)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[+_ ]"#, with: "-", options: .regularExpression)
    }

    private static func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }

    private static func matches(pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let nsRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return String(value[range])
        }
    }

    private func csvRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").dropFirst().map { line in
            parseCSVLine(String(line))
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
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
                } else {
                    quoted.toggle()
                }
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

    private static func stableID(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return "src_\(String(hash, radix: 16))"
    }

    private static func versionedSourceID(_ sourceID: String, minecraftVersion: String) -> String {
        "\(sourceID)_mc_\(versionIDComponent(minecraftVersion))"
    }

    private static func versionIDComponent(_ minecraftVersion: String) -> String {
        minecraftVersion.replacingOccurrences(of: ".", with: "_")
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func duckTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func displayTimestamp(_ date: Date) -> String {
        duckTimestamp(date)
    }
}

private final class URLFetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, Error>?

    func store(_ result: Result<Data, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func result() -> Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
