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
    public let discoverSourceLinks: Bool
    public let discoveryLimit: Int?
    public let discoverySearchesPerSecond: Double
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
        discoverSourceLinks: Bool = false,
        discoveryLimit: Int? = nil,
        discoverySearchesPerSecond: Double = 2,
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
        self.discoverSourceLinks = discoverSourceLinks
        self.discoveryLimit = discoveryLimit
        self.discoverySearchesPerSecond = discoverySearchesPerSecond
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

public struct ModSourceDiscoverySummary: Equatable, Sendable {
    public let sourcesChecked: Int
    public let searchesRun: Int
    public let linksFound: Int
}

public struct ModUpdateScanner: Sendable {
    public let config: ModUpdateScannerConfig
    private var database: DuckDBDatabase { DuckDBDatabase(databaseURL: config.databaseURL) }
    private var fileManager: FileManager { FileManager.default }
    private static let progressInterval = 25
    private static let discoveryProgressInterval = 10

    public init(config: ModUpdateScannerConfig) {
        self.config = config
    }

    public func run() throws -> ModUpdateScanSummary {
        try initializeDatabase()
        let seeded = config.seedFromProjectData ? try seedSourcesFromProjectData() : 0
        let discovered = config.discoverSourceLinks ? try discoverMissingSourceLinks(limit: config.discoveryLimit) : ModSourceDiscoverySummary(sourcesChecked: 0, searchesRun: 0, linksFound: 0)
        let scanID = "scan_\(Self.compactTimestamp())_\(UUID().uuidString.prefix(8))"
        let startedAt = Self.duckTimestamp(Date())
        print("mod_update_scan_started scan_id=\(scanID) minecraft_version=\(config.minecraftVersion) seeded_sources=\(seeded) discovered_links=\(discovered.linksFound) discovery_searches=\(discovered.searchesRun) dry_run=\(config.dryRun)")
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
                if checked % Self.progressInterval == 0 || checked == sources.count {
                    try updateRunningScanProgress(
                        scanID: scanID,
                        checked: checked,
                        total: sources.count,
                        candidates: candidates,
                        unresolved: unresolved,
                        seeded: seeded,
                        discovered: discovered
                    )
                }
            } else if checked % Self.progressInterval == 0 || checked == sources.count {
                print("mod_update_scan_progress scan_id=\(scanID) minecraft_version=\(config.minecraftVersion) checked=\(checked)/\(sources.count) candidates=\(candidates) unresolved=\(unresolved) dry_run=true")
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
                notes = \(Self.sqlLiteral("seeded_sources=\(seeded) discovered_links=\(discovered.linksFound) discovery_searches=\(discovered.searchesRun) throttle=\(config.maxURLsPerWindow)/\(Int(config.windowSeconds))s discovery_throttle=\(config.discoverySearchesPerSecond)/s"))
            WHERE scan_id = \(Self.sqlLiteral(scanID));
            """)
        }
        print("mod_update_scan_completed scan_id=\(scanID) minecraft_version=\(config.minecraftVersion) checked=\(checked) candidates=\(candidates) unresolved=\(unresolved)")
        return ModUpdateScanSummary(scanID: scanID, sourcesChecked: checked, candidatesFound: candidates, unresolved: unresolved, seededSources: seeded)
    }

    private func updateRunningScanProgress(
        scanID: String,
        checked: Int,
        total: Int,
        candidates: Int,
        unresolved: Int,
        seeded: Int,
        discovered: ModSourceDiscoverySummary
    ) throws {
        let notes = "progress=\(checked)/\(total) seeded_sources=\(seeded) discovered_links=\(discovered.linksFound) discovery_searches=\(discovered.searchesRun) throttle=\(config.maxURLsPerWindow)/\(Int(config.windowSeconds))s discovery_throttle=\(config.discoverySearchesPerSecond)/s"
        try execute("""
        UPDATE core.mod_update_scans
        SET urls_checked = \(checked),
            candidates_found = \(candidates),
            unresolved = \(unresolved),
            notes = \(Self.sqlLiteral(notes))
        WHERE scan_id = \(Self.sqlLiteral(scanID));
        """)
        print("mod_update_scan_progress scan_id=\(scanID) minecraft_version=\(config.minecraftVersion) checked=\(checked)/\(total) candidates=\(candidates) unresolved=\(unresolved)")
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

    public static func sourceLinkRole(provider: String) -> String {
        switch provider.lowercased() {
        case "modrinth", "curseforge":
            return provider.lowercased()
        case "neoforge", "adoptium", "web":
            return "official"
        default:
            return "primary"
        }
    }

    private static func sqlLinkRoleExpression(providerColumn: String) -> String {
        """
        CASE
          WHEN lower(\(providerColumn)) IN ('modrinth', 'curseforge') THEN lower(\(providerColumn))
          WHEN lower(\(providerColumn)) IN ('neoforge', 'adoptium', 'web') THEN 'official'
          ELSE 'primary'
        END
        """
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
        CREATE TABLE IF NOT EXISTS core.mods (
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          category VARCHAR,
          active_status VARCHAR NOT NULL,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP,
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
        CREATE TABLE IF NOT EXISTS core.mod_source_links (
          link_id VARCHAR PRIMARY KEY,
          source_id VARCHAR NOT NULL,
          mod_key VARCHAR NOT NULL,
          display_name VARCHAR NOT NULL,
          provider VARCHAR NOT NULL,
          link_role VARCHAR NOT NULL,
          source_url VARCHAR NOT NULL,
          priority INTEGER NOT NULL DEFAULT 100,
          active BOOLEAN NOT NULL DEFAULT true,
          verified_at TIMESTAMP,
          created_at TIMESTAMP NOT NULL DEFAULT now(),
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR,
          notes VARCHAR
        );
        CREATE TABLE IF NOT EXISTS core.mod_source_discovery_results (
          discovery_id VARCHAR PRIMARY KEY,
          source_id VARCHAR NOT NULL,
          mod_key VARCHAR NOT NULL,
          display_name VARCHAR NOT NULL,
          missing_provider VARCHAR NOT NULL,
          search_method VARCHAR NOT NULL,
          search_url VARCHAR NOT NULL,
          found_url VARCHAR,
          status VARCHAR NOT NULL,
          details VARCHAR,
          checked_at TIMESTAMP NOT NULL DEFAULT now(),
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
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
        INSERT OR REPLACE INTO core.mod_source_links(
          link_id, source_id, mod_key, display_name, provider, link_role,
          source_url, priority, active, verified_at, created_at, updated_at,
          minecraft_version, loader, loader_version, notes
        )
        SELECT
          'link_' || md5(
            COALESCE(source_id, '') || '|' ||
            COALESCE(minecraft_version, '26.1.2') || '|' ||
            COALESCE(provider, '') || '|' ||
            COALESCE(source_url, '')
          ),
          source_id,
          mod_key,
          display_name,
          provider,
          \(Self.sqlLinkRoleExpression(providerColumn: "provider")),
          source_url,
          priority,
          active,
          CASE WHEN source_url LIKE 'http%' THEN updated_at ELSE NULL END,
          COALESCE(created_at, now()),
          COALESCE(updated_at, now()),
          COALESCE(minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))),
          COALESCE(loader, \(Self.sqlLiteral(config.loader))),
          COALESCE(loader_version, \(Self.sqlLiteral(config.loaderVersion))),
          'Backfilled from core.mod_sources during scanner initialization.'
        FROM core.mod_sources
        WHERE (COALESCE(source_url, '') LIKE 'http://%' OR COALESCE(source_url, '') LIKE 'https://%')
          AND NOT EXISTS (
            SELECT 1
            FROM core.mod_source_links existing
            WHERE existing.source_id = core.mod_sources.source_id
              AND existing.provider = core.mod_sources.provider
              AND existing.source_url = core.mod_sources.source_url
              AND COALESCE(existing.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = COALESCE(core.mod_sources.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion)))
          );
        """)
    }

    private func seedSourcesFromProjectData() throws -> Int {
        var seeded = 0
        seeded += try seedSourcesFromReleaseManifests()
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
        let targetStatus = Self.sqlLiteral("Needs \(targetVersion) compatibility test")
        let workingStatusSQL = "'active', 'ok', 'priority mod', 'admin locked'"
        let protectedStatusSQL = "'priority mod', 'admin locked'"

        let seededSourcesCSV = try query("""
        SELECT COUNT(*)
        FROM core.mod_sources s
        WHERE s.active = true
          AND COALESCE(s.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
          AND EXISTS (
            SELECT 1
            FROM core.mods m
            WHERE COALESCE(m.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
              AND lower(COALESCE(m.active_status, '')) IN (\(workingStatusSQL))
              AND (
                   lower(COALESCE(m.canonical_key, '')) = lower(COALESCE(s.mod_key, ''))
                OR lower(COALESCE(m.primary_url, '')) = lower(COALESCE(s.source_url, ''))
                OR lower(COALESCE(m.name, '')) = lower(COALESCE(s.display_name, ''))
              )
          )
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
        guard !config.dryRun else {
            return seededSources
        }

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
          CAST(NULL AS VARCHAR) AS installed_file,
          CAST(NULL AS VARCHAR) AS installed_version,
          s.provider,
          s.source_url,
          CASE
            WHEN EXISTS (
              SELECT 1
              FROM core.mods m
              WHERE COALESCE(m.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
                AND lower(COALESCE(m.active_status, '')) IN (\(protectedStatusSQL))
                AND (
                     lower(COALESCE(m.canonical_key, '')) = lower(COALESCE(s.mod_key, ''))
                  OR lower(COALESCE(m.primary_url, '')) = lower(COALESCE(s.source_url, ''))
                  OR lower(COALESCE(m.name, '')) = lower(COALESCE(s.display_name, ''))
                )
            ) THEN 1
            ELSE LEAST(COALESCE(s.priority, 100), 25)
          END AS priority,
          false,
          now(),
          now(),
          \(targetLiteral),
          \(loaderLiteral),
          \(loaderVersionLiteral)
        FROM core.mod_sources s
        WHERE s.active = true
          AND COALESCE(s.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
          AND EXISTS (
            SELECT 1
            FROM core.mods m
            WHERE COALESCE(m.minecraft_version, \(referenceLiteral)) = \(referenceLiteral)
              AND lower(COALESCE(m.active_status, '')) IN (\(workingStatusSQL))
              AND (
                   lower(COALESCE(m.canonical_key, '')) = lower(COALESCE(s.mod_key, ''))
                OR lower(COALESCE(m.primary_url, '')) = lower(COALESCE(s.source_url, ''))
                OR lower(COALESCE(m.name, '')) = lower(COALESCE(s.display_name, ''))
              )
          )
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
          AND lower(COALESCE(m.active_status, '')) IN (\(workingStatusSQL))
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
          CASE
            WHEN lower(COALESCE(active_status, '')) IN (\(protectedStatusSQL)) THEN active_status
            ELSE 'awaiting_compatible_release'
          END,
          CASE
            WHEN lower(COALESCE(active_status, '')) IN (\(protectedStatusSQL)) THEN concat_ws(' ', NULLIF(server_status, ''), \(targetNote))
            ELSE \(targetNote)
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
            WHEN lower(COALESCE(mf.status, '')) IN ('ok', 'runtime ok', 'installed', 'client-only: included', 'client dependency: included') THEN \(targetStatus)
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
          CASE
            WHEN lower(COALESCE(map.active_status, '')) IN (\(protectedStatusSQL)) THEN 'admin_forced_carry_forward_candidate'
            WHEN lower(COALESCE(msf.compatibility_status, '')) = 'ok' THEN 'carry_forward_candidate'
            ELSE msf.compatibility_status
          END,
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

    private struct SourceDiscoveryRow {
        let sourceID: String
        let modKey: String
        let displayName: String
        let installedFile: String?
        let installedVersion: String?
        let provider: String
        let sourceURL: String
        let missingProviders: [String]
    }

    private struct SourceLinkCandidate {
        let provider: String
        let url: String
        let title: String?
    }

    private struct SourceSearchAttempt {
        let method: String
        let searchURL: String
        let candidates: [SourceLinkCandidate]
        let details: String
    }

    private final class SourceDiscoveryRateLimiter {
        private let minimumInterval: TimeInterval
        private var lastSearch: Date?
        private(set) var searchesRun = 0

        init(searchesPerSecond: Double) {
            minimumInterval = searchesPerSecond > 0 ? 1.0 / searchesPerSecond : 0
        }

        func beforeSearch() {
            if let lastSearch, minimumInterval > 0 {
                let elapsed = Date().timeIntervalSince(lastSearch)
                if elapsed < minimumInterval {
                    Thread.sleep(forTimeInterval: minimumInterval - elapsed)
                }
            }
            lastSearch = Date()
            searchesRun += 1
        }
    }

    public func discoverMissingSourceLinks(limit: Int? = nil) throws -> ModSourceDiscoverySummary {
        try initializeDatabase()
        let rows = try loadSourceDiscoveryRows(limit: limit)
        let limiter = SourceDiscoveryRateLimiter(searchesPerSecond: min(max(config.discoverySearchesPerSecond, 0.1), 2.0))
        print("mod_source_discovery_started minecraft_version=\(config.minecraftVersion) rows=\(rows.count) dry_run=\(config.dryRun)")
        var linksFound = 0
        var rowsChecked = 0
        var providerChecks = 0
        for row in rows {
            for provider in row.missingProviders {
                guard ["modrinth", "curseforge"].contains(provider) else {
                    continue
                }
                providerChecks += 1
                var found: SourceLinkCandidate?
                for attempt in sourceDiscoveryAttempts(row: row, missingProvider: provider, limiter: limiter) {
                    let accepted = attempt.candidates.first { Self.sourceCandidateMatches($0, row: row, missingProvider: provider) }
                    if !config.dryRun {
                        try recordSourceDiscovery(
                            row: row,
                            missingProvider: provider,
                            method: attempt.method,
                            searchURL: attempt.searchURL,
                            foundURL: accepted?.url,
                            status: accepted == nil ? "not_found" : "found",
                            details: attempt.details
                        )
                    }
                    if let accepted {
                        found = accepted
                        break
                    }
                }
                if let found {
                    linksFound += 1
                    if !config.dryRun {
                        try insertDiscoveredSourceLink(row: row, candidate: found)
                    }
                }
            }
            rowsChecked += 1
            if rowsChecked % Self.discoveryProgressInterval == 0 || rowsChecked == rows.count {
                print("mod_source_discovery_progress minecraft_version=\(config.minecraftVersion) rows=\(rowsChecked)/\(rows.count) provider_checks=\(providerChecks) searches=\(limiter.searchesRun) links_found=\(linksFound)")
            }
        }
        print("mod_source_discovery_completed minecraft_version=\(config.minecraftVersion) rows=\(rowsChecked) provider_checks=\(providerChecks) searches=\(limiter.searchesRun) links_found=\(linksFound)")
        return ModSourceDiscoverySummary(sourcesChecked: rows.count, searchesRun: limiter.searchesRun, linksFound: linksFound)
    }

    private func loadSourceDiscoveryRows(limit: Int?) throws -> [SourceDiscoveryRow] {
        let sourceActiveClause = (try isStagingMinecraftVersion()) ? "" : "AND s.active = true"
        let limitClause = limit.map { "LIMIT \(max(0, $0))" } ?? ""
        let csv = try query("""
        WITH source_coverage AS (
          SELECT
            s.source_id,
            s.mod_key,
            s.display_name,
            COALESCE(s.installed_file, '') AS installed_file,
            COALESCE(s.installed_version, '') AS installed_version,
            s.provider,
            s.source_url,
            MAX(CASE WHEN l.provider = 'modrinth' AND l.active THEN 1 ELSE 0 END) AS has_modrinth,
            MAX(CASE WHEN l.provider = 'curseforge' AND l.active THEN 1 ELSE 0 END) AS has_curseforge
          FROM core.mod_sources s
          LEFT JOIN core.mod_source_links l
            ON l.source_id = s.source_id
           AND COALESCE(l.minecraft_version, COALESCE(s.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion)))) = COALESCE(s.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion)))
          WHERE COALESCE(s.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion))
            \(sourceActiveClause)
            AND (COALESCE(s.source_url, '') LIKE 'http://%' OR COALESCE(s.source_url, '') LIKE 'https://%')
            AND s.provider <> 'manifest'
            \(excludedByAdminStatusClause(sourceAlias: "s"))
          GROUP BY 1, 2, 3, 4, 5, 6, 7
        )
        SELECT source_id, mod_key, display_name, installed_file, installed_version, provider, source_url, has_modrinth, has_curseforge
        FROM source_coverage
        WHERE has_modrinth = 0 OR has_curseforge = 0
        ORDER BY display_name, source_url
        \(limitClause);
        """)
        return csvRows(csv).compactMap { row in
            guard row.count >= 9 else { return nil }
            var missing: [String] = []
            if row[7] != "1" { missing.append("modrinth") }
            if row[8] != "1" { missing.append("curseforge") }
            return SourceDiscoveryRow(
                sourceID: row[0],
                modKey: row[1],
                displayName: row[2],
                installedFile: row[3].isEmpty ? nil : row[3],
                installedVersion: row[4].isEmpty ? nil : row[4],
                provider: row[5],
                sourceURL: row[6],
                missingProviders: missing
            )
        }
    }

    private func sourceDiscoveryAttempts(row: SourceDiscoveryRow, missingProvider: String, limiter: SourceDiscoveryRateLimiter) -> [SourceSearchAttempt] {
        let builders: [() throws -> SourceSearchAttempt] = [
            { try self.searchProviderAPI(row: row, provider: missingProvider, limiter: limiter) },
            { try self.searchProviderSite(row: row, provider: missingProvider, limiter: limiter) },
            { try self.searchGoogleForProvider(row: row, provider: missingProvider, limiter: limiter) }
        ]
        return builders.compactMap { builder in
            do {
                return try builder()
            } catch {
                return SourceSearchAttempt(
                    method: "error",
                    searchURL: "",
                    candidates: [],
                    details: String(describing: error)
                )
            }
        }
    }

    private func searchProviderAPI(row: SourceDiscoveryRow, provider: String, limiter: SourceDiscoveryRateLimiter) throws -> SourceSearchAttempt {
        let queryText = Self.discoveryQuery(for: row)
        let endpoint: String
        if provider == "modrinth" {
            endpoint = "https://api.modrinth.com/v2/search?query=\(Self.urlQuery(queryText))&limit=10"
        } else {
            endpoint = "https://api.curse.tools/v1/cf/mods/search?gameId=432&searchFilter=\(Self.urlQuery(queryText))&pageSize=10"
        }
        guard let url = URL(string: endpoint) else {
            throw ModUpdateScannerError.invalidSourceURL(endpoint)
        }
        limiter.beforeSearch()
        let data = try fetchData(url)
        let candidates = provider == "modrinth"
            ? Self.modrinthCandidates(fromSearchData: data)
            : Self.curseForgeCandidates(fromSearchData: data)
        return SourceSearchAttempt(method: "api", searchURL: endpoint, candidates: candidates, details: "searched \(provider) API")
    }

    private func searchProviderSite(row: SourceDiscoveryRow, provider: String, limiter: SourceDiscoveryRateLimiter) throws -> SourceSearchAttempt {
        let queryText = Self.discoveryQuery(for: row)
        let endpoint: String
        if provider == "modrinth" {
            endpoint = "https://modrinth.com/mods?q=\(Self.urlQuery(queryText))"
        } else {
            endpoint = "https://www.curseforge.com/minecraft/search?page=1&pageSize=20&sortBy=relevancy&search=\(Self.urlQuery(queryText))"
        }
        guard let url = URL(string: endpoint) else {
            throw ModUpdateScannerError.invalidSourceURL(endpoint)
        }
        limiter.beforeSearch()
        let html = try fetchText(url)
        let candidates = Self.sourceLinkCandidates(fromHTML: html, provider: provider)
        return SourceSearchAttempt(method: "site_curl", searchURL: endpoint, candidates: candidates, details: "searched \(provider) website HTML")
    }

    private func searchGoogleForProvider(row: SourceDiscoveryRow, provider: String, limiter: SourceDiscoveryRateLimiter) throws -> SourceSearchAttempt {
        let queryText = Self.discoveryQuery(for: row)
        let siteClause: String
        if provider == "modrinth" {
            siteClause = "site:modrinth.com/mod OR site:modrinth.com/shader OR site:modrinth.com/resourcepack OR site:modrinth.com/datapack"
        } else {
            siteClause = "site:curseforge.com/minecraft/mc-mods OR site:curseforge.com/minecraft/shaders OR site:curseforge.com/minecraft/texture-packs OR site:curseforge.com/minecraft/data-packs"
        }
        let endpoint = "https://www.google.com/search?q=\(Self.urlQuery("\(siteClause) \(queryText)"))"
        guard let url = URL(string: endpoint) else {
            throw ModUpdateScannerError.invalidSourceURL(endpoint)
        }
        limiter.beforeSearch()
        let html = try fetchText(url)
        let candidates = Self.sourceLinkCandidates(fromGoogleHTML: html, provider: provider)
        return SourceSearchAttempt(method: "google_curl", searchURL: endpoint, candidates: candidates, details: "searched Google and accepted only \(provider) result URLs")
    }

    private func insertDiscoveredSourceLink(row: SourceDiscoveryRow, candidate: SourceLinkCandidate) throws {
        let linkID = Self.stableID("\(row.sourceID)|\(candidate.provider)|\(candidate.url)|\(config.minecraftVersion)")
        try execute("""
        INSERT OR REPLACE INTO core.mod_source_links(
          link_id, source_id, mod_key, display_name, provider, link_role,
          source_url, priority, active, verified_at, created_at, updated_at,
          minecraft_version, loader, loader_version, notes
        )
        VALUES (
          \(Self.sqlLiteral(linkID)),
          \(Self.sqlLiteral(row.sourceID)),
          \(Self.sqlLiteral(row.modKey)),
          \(Self.sqlLiteral(row.displayName)),
          \(Self.sqlLiteral(candidate.provider)),
          \(Self.sqlLiteral(Self.sourceLinkRole(provider: candidate.provider))),
          \(Self.sqlLiteral(candidate.url)),
          50,
          true,
          now(),
          now(),
          now(),
          \(Self.sqlLiteral(config.minecraftVersion)),
          \(Self.sqlLiteral(config.loader)),
          \(Self.sqlLiteral(config.loaderVersion)),
          \(Self.sqlLiteral("Discovered by source-link redundancy search\(candidate.title.map { ": \($0)" } ?? ".")"))
        );
        """)
    }

    private func recordSourceDiscovery(
        row: SourceDiscoveryRow,
        missingProvider: String,
        method: String,
        searchURL: String,
        foundURL: String?,
        status: String,
        details: String
    ) throws {
        let checkedAt = Self.duckTimestamp(Date())
        let discoveryID = Self.stableID("\(row.sourceID)|\(missingProvider)|\(method)|\(searchURL)|\(foundURL ?? "")|\(checkedAt)|\(UUID().uuidString)")
        try execute("""
        INSERT INTO core.mod_source_discovery_results(
          discovery_id, source_id, mod_key, display_name, missing_provider,
          search_method, search_url, found_url, status, details, checked_at,
          minecraft_version, loader, loader_version
        )
        VALUES (
          \(Self.sqlLiteral(discoveryID)),
          \(Self.sqlLiteral(row.sourceID)),
          \(Self.sqlLiteral(row.modKey)),
          \(Self.sqlLiteral(row.displayName)),
          \(Self.sqlLiteral(missingProvider)),
          \(Self.sqlLiteral(method)),
          \(Self.sqlLiteral(searchURL)),
          \(Self.sqlLiteral(foundURL)),
          \(Self.sqlLiteral(status)),
          \(Self.sqlLiteral(details)),
          TIMESTAMP '\(checkedAt)',
          \(Self.sqlLiteral(config.minecraftVersion)),
          \(Self.sqlLiteral(config.loader)),
          \(Self.sqlLiteral(config.loaderVersion))
        );
        """)
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

    private func loadSources(limit: Int?) throws -> [ModSourceRecord] {
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        let isStaging = try isStagingMinecraftVersion()
        let activeClause = isStaging ? "" : "AND active = true"
        let sourceActiveClause = isStaging ? "" : "AND s.active = true"
        let linkActiveClause = isStaging ? "" : "AND l.active = true"
        let sourceRowsSQL: String
        if try tableExists(schema: "core", table: "mod_source_links") {
            sourceRowsSQL = """
            SELECT
              s.source_id,
              s.mod_key,
              s.display_name,
              COALESCE(s.installed_file, '') AS installed_file,
              COALESCE(s.installed_version, '') AS installed_version,
              l.provider,
              l.source_url,
              l.priority
            FROM core.mod_sources s
            JOIN core.mod_source_links l
              ON l.source_id = s.source_id
             AND COALESCE(l.minecraft_version, COALESCE(s.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion)))) = COALESCE(s.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion)))
            WHERE COALESCE(s.minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion))
              \(sourceActiveClause)
              \(linkActiveClause)
              AND (COALESCE(l.source_url, '') LIKE 'http://%' OR COALESCE(l.source_url, '') LIKE 'https://%')
              \(excludedByAdminStatusClause(sourceAlias: "s", linkAlias: "l"))
            """
        } else {
            sourceRowsSQL = """
            SELECT source_id, mod_key, display_name, COALESCE(installed_file, ''), COALESCE(installed_version, ''), provider, source_url, priority
            FROM core.mod_sources
            WHERE COALESCE(minecraft_version, \(Self.sqlLiteral(config.minecraftVersion))) = \(Self.sqlLiteral(config.minecraftVersion))
              \(activeClause)
              AND (COALESCE(source_url, '') LIKE 'http://%' OR COALESCE(source_url, '') LIKE 'https://%')
              \(excludedByAdminStatusClause(sourceAlias: "core.mod_sources"))
            """
        }
        let csv = try query("""
        \(sourceRowsSQL)
        UNION ALL
        SELECT source_id, mod_key, display_name, COALESCE(installed_file, ''), COALESCE(installed_version, ''), provider, source_url, priority
        FROM (
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
        )
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

    private func excludedByAdminStatusClause(sourceAlias: String, linkAlias: String? = nil) -> String {
        let versionLiteral = Self.sqlLiteral(config.minecraftVersion)
        let sourceURLExpression: String
        if let linkAlias {
            sourceURLExpression = "COALESCE(\(linkAlias).source_url, \(sourceAlias).source_url, '')"
        } else {
            sourceURLExpression = "COALESCE(\(sourceAlias).source_url, '')"
        }
        return """
        AND NOT EXISTS (
          SELECT 1
          FROM core.mods banned
          WHERE COALESCE(banned.minecraft_version, \(versionLiteral)) = \(versionLiteral)
            AND lower(COALESCE(banned.active_status, '')) = 'banned by admin'
            AND (
                 lower(COALESCE(banned.canonical_key, '')) = lower(COALESCE(\(sourceAlias).mod_key, ''))
              OR lower(COALESCE(banned.primary_url, '')) = lower(\(sourceURLExpression))
              OR lower(COALESCE(banned.name, '')) = lower(COALESCE(\(sourceAlias).display_name, ''))
            )
        )
        """
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
        guard !config.dryRun else { return }
        let sourceActive = try isLiveMinecraftVersion()
        var statements: [String] = ["BEGIN TRANSACTION;"]
        for source in sources {
            let linkID = Self.stableID("\(source.sourceID)|\(source.provider)|\(source.sourceURL)|\(config.minecraftVersion)")
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
            INSERT OR REPLACE INTO core.mod_source_links(
              link_id, source_id, mod_key, display_name, provider, link_role,
              source_url, priority, active, verified_at, updated_at,
              minecraft_version, loader, loader_version, notes
            )
            VALUES (
              \(Self.sqlLiteral(linkID)),
              \(Self.sqlLiteral(source.sourceID)),
              \(Self.sqlLiteral(source.modKey)),
              \(Self.sqlLiteral(source.displayName)),
              \(Self.sqlLiteral(source.provider)),
              \(Self.sqlLiteral(Self.sourceLinkRole(provider: source.provider))),
              \(Self.sqlLiteral(source.sourceURL)),
              100,
              \(sourceActive ? "true" : "false"),
              CASE WHEN \(Self.sqlLiteral(source.sourceURL)) LIKE 'http%' THEN now() ELSE NULL END,
              now(),
              \(Self.sqlLiteral(config.minecraftVersion)),
              \(Self.sqlLiteral(config.loader)),
              \(Self.sqlLiteral(config.loaderVersion)),
              'Recorded by mod-update scanner source seeding.'
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
            UPDATE core.mod_source_links
            SET active = \(scanCompatible ? "true" : "false"),
                verified_at = TIMESTAMP '\(Self.duckTimestamp(Date()))',
                updated_at = now()
            WHERE source_id = \(Self.sqlLiteral(result.source.sourceID))
              AND provider = \(Self.sqlLiteral(result.source.provider))
              AND source_url = \(Self.sqlLiteral(result.source.sourceURL))
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

    private func tableExists(schema: String, table: String) throws -> Bool {
        let csv = try query("""
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = \(Self.sqlLiteral(schema))
          AND table_name = \(Self.sqlLiteral(table));
        """)
        return csvRows(csv).first?.first == "1"
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

    public static func sourceLinkURLs(fromHTML html: String, provider: String) -> [String] {
        sourceLinkCandidates(fromHTML: html, provider: provider).map(\.url)
    }

    public static func sourceLinkURLs(fromGoogleHTML html: String, provider: String) -> [String] {
        sourceLinkCandidates(fromGoogleHTML: html, provider: provider).map(\.url)
    }

    public static func modrinthSourceURLs(fromSearchData data: Data) -> [String] {
        modrinthCandidates(fromSearchData: data).map(\.url)
    }

    public static func curseForgeSourceURLs(fromSearchData data: Data) -> [String] {
        curseForgeCandidates(fromSearchData: data).map(\.url)
    }

    private static func discoveryQuery(for row: SourceDiscoveryRow) -> String {
        let installedName = row.installedFile.map(displayNameFromManifestFile)
        return [row.displayName, installedName, row.modKey]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? row.displayName
    }

    private static func modrinthCandidates(fromSearchData data: Data) -> [SourceLinkCandidate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = object["hits"] as? [[String: Any]] else {
            return []
        }
        return hits.compactMap { hit in
            let projectType = (hit["project_type"] as? String) ?? "mod"
            guard ["mod", "shader", "resourcepack", "datapack", "modpack", "plugin"].contains(projectType),
                  let slug = hit["slug"] as? String,
                  !slug.isEmpty else {
                return nil
            }
            return SourceLinkCandidate(
                provider: "modrinth",
                url: "https://modrinth.com/\(projectType)/\(slug)",
                title: hit["title"] as? String
            )
        }
    }

    private static func curseForgeCandidates(fromSearchData data: Data) -> [SourceLinkCandidate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = object["data"] as? [[String: Any]] else {
            return []
        }
        return hits.compactMap { hit in
            let links = hit["links"] as? [String: Any]
            let websiteURL = links?["websiteUrl"] as? String
            let slug = hit["slug"] as? String
            let url = websiteURL ?? slug.map { "https://www.curseforge.com/minecraft/mc-mods/\($0)" }
            guard let url else {
                return nil
            }
            let canonicalURL = canonicalSourceURL(url, provider: "curseforge")
            guard acceptedProviderURL(canonicalURL, provider: "curseforge") else {
                return nil
            }
            return SourceLinkCandidate(provider: "curseforge", url: canonicalURL, title: hit["name"] as? String)
        }
    }

    private static func sourceLinkCandidates(fromHTML html: String, provider: String) -> [SourceLinkCandidate] {
        let decoded = htmlDecoded(html)
        let patterns: [String]
        if provider == "modrinth" {
            patterns = [
                #"(https?://(?:www\.)?modrinth\.com/(?:mod|shader|resourcepack|datapack|modpack|plugin)/[A-Za-z0-9._+\-]+)"#,
                #"href="(/(?:mod|shader|resourcepack|datapack|modpack|plugin)/[A-Za-z0-9._+\-]+)""#
            ]
        } else {
            patterns = [
                #"(https?://(?:www\.)?curseforge\.com/minecraft/(?:mc-mods|shaders|texture-packs|data-packs|modpacks|bukkit-plugins)/[A-Za-z0-9._+\-]+)"#,
                #"href="(/minecraft/(?:mc-mods|shaders|texture-packs|data-packs|modpacks|bukkit-plugins)/[A-Za-z0-9._+\-]+)""#
            ]
        }
        var candidates: [SourceLinkCandidate] = []
        var seen = Set<String>()
        for pattern in patterns {
            for match in matches(pattern: pattern, in: decoded) {
                let raw = match.hasPrefix("/") ? (provider == "modrinth" ? "https://modrinth.com\(match)" : "https://www.curseforge.com\(match)") : match
                let url = canonicalSourceURL(raw, provider: provider)
                guard acceptedProviderURL(url, provider: provider), !seen.contains(url) else {
                    continue
                }
                seen.insert(url)
                candidates.append(SourceLinkCandidate(provider: provider, url: url, title: nil))
            }
        }
        return candidates
    }

    private static func sourceLinkCandidates(fromGoogleHTML html: String, provider: String) -> [SourceLinkCandidate] {
        let decoded = htmlDecoded(html)
        var rawURLs = matches(pattern: #"(https?://[^"'<>\s&]+(?:modrinth\.com|curseforge\.com)[^"'<>\s&]*)"#, in: decoded)
        rawURLs += matches(pattern: #"/url\?q=([^"&]+)"#, in: decoded).compactMap {
            $0.removingPercentEncoding
        }
        var seen = Set<String>()
        return rawURLs.compactMap { raw in
            let cleaned = raw
                .replacingOccurrences(of: "\\u003d", with: "=")
                .replacingOccurrences(of: "\\u0026", with: "&")
            let url = canonicalSourceURL(cleaned, provider: provider)
            guard acceptedProviderURL(url, provider: provider), !seen.contains(url) else {
                return nil
            }
            seen.insert(url)
            return SourceLinkCandidate(provider: provider, url: url, title: nil)
        }
    }

    private static func sourceCandidateMatches(_ candidate: SourceLinkCandidate, row: SourceDiscoveryRow, missingProvider: String) -> Bool {
        guard candidate.provider == missingProvider,
              acceptedProviderURL(candidate.url, provider: missingProvider),
              canonicalSourceURL(row.sourceURL, provider: row.provider) != candidate.url else {
            return false
        }
        let identityValues = [
            row.displayName,
            row.modKey,
            row.installedFile.map(displayNameFromManifestFile),
            slug(fromSourceURL: row.sourceURL)
        ].compactMap { $0 }
        let candidateValues = [
            candidate.title,
            slug(fromSourceURL: candidate.url)
        ].compactMap { $0 }
        for identity in identityValues {
            for candidateValue in candidateValues {
                if normalizedSearchIdentity(identity) == normalizedSearchIdentity(candidateValue) {
                    return true
                }
                if compactSearchIdentity(identity) == compactSearchIdentity(candidateValue) {
                    return true
                }
            }
        }
        return false
    }

    private static func acceptedProviderURL(_ value: String, provider: String) -> Bool {
        guard let url = URL(string: value),
              let host = url.host?.lowercased() else {
            return false
        }
        let path = url.path.lowercased()
        if provider == "modrinth" {
            return host == "modrinth.com" && path.range(of: #"^/(mod|shader|resourcepack|datapack|modpack|plugin)/[^/]+$"#, options: .regularExpression) != nil
        }
        if provider == "curseforge" {
            return (host == "www.curseforge.com" || host == "curseforge.com")
                && path.range(of: #"^/minecraft/(mc-mods|shaders|texture-packs|data-packs|modpacks|bukkit-plugins)/[^/]+$"#, options: .regularExpression) != nil
        }
        return false
    }

    private static func canonicalSourceURL(_ value: String, provider: String) -> String {
        guard let url = URL(string: value) else {
            return value
        }
        let parts = url.path.split(separator: "/").map(String.init)
        if provider == "modrinth",
           parts.count >= 2 {
            return "https://modrinth.com/\(parts[0])/\(parts[1])"
        }
        if provider == "curseforge",
           parts.count >= 3,
           parts[0] == "minecraft" {
            return "https://www.curseforge.com/minecraft/\(parts[1])/\(parts[2])"
        }
        return value
    }

    private static func slug(fromSourceURL value: String) -> String? {
        guard let url = URL(string: value) else {
            return nil
        }
        if url.host?.lowercased().contains("modrinth.com") == true {
            return modrinthSlug(from: url)
        }
        if url.host?.lowercased().contains("curseforge.com") == true {
            return curseForgeSlug(from: url)
        }
        return url.path.split(separator: "/").last.map(String.init)
    }

    private static func normalizedSearchIdentity(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"\.(jar|zip)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func compactSearchIdentity(_ value: String) -> String {
        normalizedSearchIdentity(value).replacingOccurrences(of: "-", with: "")
    }

    private static func htmlDecoded(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u0026", with: "&")
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
