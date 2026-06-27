import Foundation
import Testing
import MCPummelchenModShared
import MCPummelchenModClientCore
@testable import MCPummelchenModServerCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("MCPummelchenModServer API")
struct MCPummelchenModServerCoreTests {
    private static let environmentMutationLock = NSLock()

    @Test("serves current release identical to static JSON")
    func servesCurrentRelease() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/releases/current"))

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == fixture.currentReleaseJSON)
    }

    @Test("serves release manifest TSV")
    func servesManifest() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture)
        let response = api.response(
            for: HTTPRequest(method: "GET", path: "/api/v1/releases/release_20260612_V6_modernarch-refresh/manifest")
        )

        #expect(response.statusCode == 200)
        #expect(response.contentType.hasPrefix("text/tab-separated-values"))
        #expect(String(decoding: response.body, as: UTF8.self) == fixture.manifestTSV)
    }

    @Test("serves status with transport target metadata")
    func servesStatus() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/status"))
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]

        #expect(response.statusCode == 200)
        #expect(object?["api_version"] as? String == "v1")
        #expect(object?["mode"] as? String == "read_only")
        #expect(object?["current_release_id"] as? String == "release_20260612_V6_modernarch-refresh")
        #expect(object?["transport_target"] as? String == "nginx_https_api")
    }

    @Test("Minecraft autostart config is explicit and environment driven")
    func minecraftAutostartConfigFromEnvironment() throws {
        #expect(MinecraftLiveServerSupervisorConfig.fromEnvironment([:]) == nil)
        #expect(MinecraftLiveServerSupervisorConfig.fromEnvironment(["PUMMELCHEN_MINECRAFT_AUTOSTART": "true"]) == nil)

        let config = try #require(MinecraftLiveServerSupervisorConfig.fromEnvironment([
            "PUMMELCHEN_MINECRAFT_AUTOSTART": "true",
            "PUMMELCHEN_MINECRAFT_DIR": "/opt/pummelchen-swift/runtime/minecraft",
            "PUMMELCHEN_MINECRAFT_START_COMMAND": "./run.sh nogui",
            "PUMMELCHEN_MINECRAFT_HOST": "127.0.0.1",
            "PUMMELCHEN_MINECRAFT_PORT": "25566",
            "PUMMELCHEN_MINECRAFT_LOG": "/opt/pummelchen-swift/runtime/logs/minecraft-live.log",
            "PUMMELCHEN_MINECRAFT_WATCHDOG": "true",
            "PUMMELCHEN_MINECRAFT_WATCHDOG_STARTUP_GRACE_SECONDS": "180",
            "PUMMELCHEN_MINECRAFT_WATCHDOG_INTERVAL_SECONDS": "30",
            "PUMMELCHEN_MINECRAFT_WATCHDOG_FAILURE_THRESHOLD": "2",
            "PUMMELCHEN_MINECRAFT_WATCHDOG_COMMAND_TIMEOUT_SECONDS": "4",
            "PUMMELCHEN_MINECRAFT_WATCHDOG_COMMAND": "list",
            "PUMMELCHEN_MINECRAFT_GRACEFUL_STOP_TIMEOUT_SECONDS": "45",
            "PUMMELCHEN_MINECRAFT_RCON_HOST": "127.0.0.1",
            "PUMMELCHEN_MINECRAFT_RCON_PORT": "25575",
            "PUMMELCHEN_MINECRAFT_RCON_PASSWORD": "test-password",
            "PUMMELCHEN_MINECRAFT_RCON_FIREWALL": "true"
        ]))

        #expect(config.enabled)
        #expect(config.serverDirectory.path == "/opt/pummelchen-swift/runtime/minecraft")
        #expect(config.startCommand == "./run.sh nogui")
        #expect(config.host == "127.0.0.1")
        #expect(config.port == 25566)
        #expect(config.logFile.path == "/opt/pummelchen-swift/runtime/logs/minecraft-live.log")
        #expect(config.watchdogEnabled)
        #expect(config.watchdogStartupGraceSeconds == 180)
        #expect(config.watchdogIntervalSeconds == 30)
        #expect(config.watchdogFailureThreshold == 2)
        #expect(config.watchdogCommandTimeoutSeconds == 4)
        #expect(config.watchdogCommand == "list")
        #expect(config.gracefulStopTimeoutSeconds == 45)
        #expect(config.rconHost == "127.0.0.1")
        #expect(config.rconPort == 25575)
        #expect(config.rconPassword == "test-password")
        #expect(config.rconFirewallEnabled)
    }

    @Test("serves live site stats from Swift API")
    func servesLiveSiteStats() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/live-stats"))
        let payload = try JSONDecoder().decode(LiveStatsPayload.self, from: response.body)

        #expect(response.statusCode == 200)
        #expect(response.headers["Cache-Control"] == "no-store, max-age=0")
        #expect(payload.intervalSeconds == 5)
        #expect(payload.stats["Last Mod Version"] == "20260612 V6 modernarch-refresh")
        #expect(payload.stats["Mac Installer Latest Version"] == "Latest version: 2026-06-12_V6")
        #expect(payload.stats["Mac Installer Release URL"] == "/downloads/MCPummelchenModClient.dmg")
        #expect(payload.stats["Server Address"] == "91.99.176.243:25565")
        #expect(payload.stats["Web Address"] == "https://pummelchen.91.99.176.243.nip.io")
        #expect(payload.stats["Client Mods"] == "1 Client Mods · 2 Shaders · 1 Resource Packs · 1 Config Files")
        #expect(payload.stats["Failed Mods"] == "0 Failed Mods")
        #expect(payload.stats["Mac Installer DMG URL"] == "/downloads/MCPummelchenModClient.dmg")
        #expect(payload.history.count == 1)
        #expect(payload.metrics.cpuPercent >= 0)
        #expect(payload.metrics.ramUsedPercent >= 0)
        #expect(payload.metrics.ramUsedGB >= 0)
        #expect(payload.metrics.ramTotalGB >= payload.metrics.ramUsedGB)
        #expect(payload.metrics.diskUsedPercent >= 0)
        #expect(payload.metrics.diskUsedGB >= 0)
        #expect(payload.metrics.diskTotalGB >= payload.metrics.diskUsedGB)

        let cachedResponse = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/live-stats"))
        let cachedPayload = try JSONDecoder().decode(LiveStatsPayload.self, from: cachedResponse.body)
        #expect(cachedPayload.generatedAt == payload.generatedAt)
        #expect(cachedPayload.history.count == payload.history.count)
    }

    @Test("publishes live site stats JSON for nginx")
    func publishesLiveSiteStatsForNginx() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let output = fixture.root.appendingPathComponent("site/public/live-stats.json")
        try? FileManager.default.removeItem(at: output)

        let publisher = LiveStatsPublisher(projectRoot: fixture.root, intervalSeconds: 5)
        try publisher.publishOnce()

        let data = try Data(contentsOf: output)
        let payload = try JSONDecoder().decode(LiveStatsPayload.self, from: data)

        #expect(payload.intervalSeconds == 5)
        #expect(payload.stats["Last Mod Version"] == "20260612 V6 modernarch-refresh")
        #expect(payload.stats["Client Mods"] == "1 Client Mods · 2 Shaders · 1 Resource Packs · 1 Config Files")
        #expect(payload.history.count == 1)
    }

    @Test("serves site JSON feeds through Swift API")
    func servesSiteJSONFeeds() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try seedLiveSiteAPIDatabase(at: fixture.root.appendingPathComponent("data/test-phase6.duckdb"))

        let api = makeAPI(fixture: fixture)
        let updateActivity = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/update-activity"))
        let neoForgeVersion = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/neoforge-version"))

        #expect(updateActivity.statusCode == 200)
        #expect(neoForgeVersion.statusCode == 200)
        #expect(updateActivity.headers["Cache-Control"] == "no-store, max-age=0")
        #expect(neoForgeVersion.headers["Cache-Control"] == "no-store, max-age=0")

        let activityObject = try JSONSerialization.jsonObject(with: updateActivity.body) as? [String: Any]
        let neoForgeObject = try JSONSerialization.jsonObject(with: neoForgeVersion.body) as? [String: Any]
        #expect(activityObject?["source"] as? String == "server-records.release_events_mod_scans_release_health")
        #expect((activityObject?["entries"] as? [[String: Any]])?.isEmpty == false)
        #expect(neoForgeObject?["official_url"] as? String == "https://neoforged.net/")
        #expect(neoForgeObject?["official_download_url"] as? String == "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.2.76/neoforge-26.1.2.76-installer.jar")
        #expect(neoForgeObject?["latest_neoforge_version"] as? String == "26.1.2.76")
        #expect(neoForgeObject?["generated_by"] as? String == "MCPummelchenModServer-server-records-neoforge-version")
    }

    @Test("serves failed mods with DuckDB scan status")
    func servesFailedModsWithDuckDBScanStatus() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let database = fixture.root.appendingPathComponent("data/test-phase6.duckdb")
        let summary = try ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: fixture.root,
            databaseURL: database,
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            limit: 0,
            seedFromProjectData: true
        )).run()
        #expect(summary.seededSources == 2)
        try DuckDBDatabase(databaseURL: database).execute("""
        INSERT OR REPLACE INTO core.failed_mod_update_status(
          failed_mod_id, title, source_url, filename, installed_version,
          failure_reason, details, failed_at, minecraft_version, loader,
          loader_version, active_status, latest_status, latest_version,
          latest_url, last_check_details, last_checked_at, updated_at
        )
        VALUES (
          'failed_giraffemob_26_1_2',
          'GiraffeMob',
          'https://www.curseforge.com/minecraft/mc-mods/giraffemob',
          'giraffemob-26.1.2-1.0.0.jar',
          '1.0.0',
          'Rejected: incompatible jar metadata',
          'Selected file giraffemob-26.1.2-1.0.0.jar failed validation.',
          TIMESTAMP '2026-06-12 00:00:00',
          '26.1.2',
          'neoforge',
          '26.1.2.76',
          'failed',
          'unresolved',
          '1.1.0',
          'https://www.curseforge.com/minecraft/mc-mods/giraffemob',
          'CurseForge API returned no compatible neoforge 26.1.2 files',
          TIMESTAMP '2026-06-19 12:00:00',
          now()
        );
        """)

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/failed-mods"))
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let rows = try #require(object?["rows"] as? [[String: Any]])
        let row = try #require(rows.first)

        #expect(response.statusCode == 200)
        #expect(response.headers["Cache-Control"] == "no-store, max-age=0")
        #expect(object?["generated_by"] as? String == "MCPummelchenModServer-server-records-failed-mods")
        #expect(row["title"] as? String == "GiraffeMob")
        #expect(row["latest_status"] as? String == "unresolved")
        #expect(row["latest_version"] as? String == "1.1.0")
        #expect(row["last_checked_at"] as? String == "2026-06-19T12:00:00Z")
        #expect(row["failure_reason"] as? String == "Rejected: incompatible jar metadata")
    }

    @Test("mod update scanner seeds staging version candidates from live inventory")
    func modUpdateScannerSeedsStagingVersionCandidatesFromLiveInventory() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = fixture.root.appendingPathComponent("data/test-version-seed.duckdb")
        let duckDB = DuckDBDatabase(databaseURL: database)
        try duckDB.execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions (
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR NOT NULL DEFAULT 'neoforge',
          loader_version VARCHAR NOT NULL,
          server_name VARCHAR NOT NULL,
          server_address VARCHAR NOT NULL,
          server_dir VARCHAR,
          status VARCHAR NOT NULL,
          is_live BOOLEAN NOT NULL DEFAULT false,
          sort_order INTEGER NOT NULL DEFAULT 100,
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions(
          minecraft_version, loader, loader_version, server_name, server_address,
          server_dir, status, is_live, sort_order, updated_at, notes
        )
        VALUES
          ('26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2', '127.0.0.1:25565', '/srv/minecraft-26.1.2', 'live', true, 10, now(), 'live'),
          ('26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2', '127.0.0.1:25566', '/srv/minecraft-26.2', 'staging', false, 20, now(), 'staging');
        CREATE TABLE core.mods (
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
        CREATE TABLE core.mod_files (
          id BIGINT PRIMARY KEY,
          mod_id BIGINT NOT NULL,
          role VARCHAR NOT NULL,
          file_name VARCHAR NOT NULL,
          path_hint VARCHAR,
          installed_on_server BOOLEAN NOT NULL DEFAULT false,
          included_in_client BOOLEAN NOT NULL DEFAULT false,
          status VARCHAR,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
        CREATE TABLE core.mod_server_files (
          id BIGINT PRIMARY KEY,
          mod_id BIGINT NOT NULL,
          file_name VARCHAR NOT NULL,
          role VARCHAR NOT NULL,
          source_url VARCHAR,
          compatibility_status VARCHAR NOT NULL,
          installed_on_server BOOLEAN NOT NULL DEFAULT false,
          included_in_client BOOLEAN NOT NULL DEFAULT false,
          selected BOOLEAN NOT NULL DEFAULT true,
          file_sha256 VARCHAR,
          file_size_bytes BIGINT,
          last_synced TIMESTAMP,
          notes VARCHAR,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
        CREATE TABLE core.mod_sources (
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
        INSERT INTO core.mods(
          id, canonical_key, name, category, active_status, server_status,
          client_package, primary_url, updated_at, minecraft_version, loader, loader_version
        )
        VALUES (
          1, 'chunky', 'Chunky', 'Utility and World Generation', 'ok', 'Installed on 26.1.2',
          'Server-only', 'https://www.curseforge.com/minecraft/mc-mods/chunky-pregenerator-forge',
          now(), '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          2, 'locked-plane', 'Locked Plane', 'Player Transport', 'Admin Locked', 'Admin forced inclusion',
          'Server & Client', 'https://www.curseforge.com/minecraft/mc-mods/locked-plane',
          now(), '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          3, 'banned-islands', 'Banned Islands', 'Worldgen', 'Banned by Admin', 'Removed by admin',
          'Server-only', 'https://www.curseforge.com/minecraft/mc-mods/banned-islands',
          now(), '26.1.2', 'neoforge', '26.1.2.76'
        );
        INSERT INTO core.mod_files(
          id, mod_id, role, file_name, path_hint, installed_on_server,
          included_in_client, status, minecraft_version, loader, loader_version
        )
        VALUES (
          1, 1, 'server_file', 'Chunky-NeoForge-1.5.3.jar', 'mods/Chunky-NeoForge-1.5.3.jar',
          true, false, 'OK', '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          2, 2, 'mod_file', 'locked-plane-1.0.0.jar', 'mods/locked-plane-1.0.0.jar',
          true, true, 'OK', '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          3, 3, 'server_file', 'banned-islands-1.0.0.jar', 'mods/banned-islands-1.0.0.jar',
          true, false, 'Banned by Admin', '26.1.2', 'neoforge', '26.1.2.76'
        );
        INSERT INTO core.mod_server_files(
          id, mod_id, file_name, role, source_url, compatibility_status,
          installed_on_server, included_in_client, selected, file_sha256,
          file_size_bytes, last_synced, notes, minecraft_version, loader, loader_version
        )
        VALUES (
          1, 1, 'Chunky-NeoForge-1.5.3.jar', 'server_file',
          'https://www.curseforge.com/minecraft/mc-mods/chunky-pregenerator-forge',
          'ok', true, false, true, 'abc', 123, now(), 'live file',
          '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          2, 2, 'locked-plane-1.0.0.jar', 'mod_file',
          'https://www.curseforge.com/minecraft/mc-mods/locked-plane',
          'ok', true, true, true, 'def', 456, now(), 'required file',
          '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          3, 3, 'banned-islands-1.0.0.jar', 'server_file',
          'https://www.curseforge.com/minecraft/mc-mods/banned-islands',
          'Banned by Admin', true, false, false, 'ghi', 789, now(), 'banned file',
          '26.1.2', 'neoforge', '26.1.2.76'
        );
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, minecraft_version, loader, loader_version
        )
        VALUES
        (
          'src_chunky_mc_26_1_2', 'chunky', 'Chunky', 'Chunky-NeoForge-1.5.3.jar', '1.5.3',
          'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/chunky-pregenerator-forge',
          100, true, '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          'src_locked_plane_mc_26_1_2', 'locked-plane', 'Locked Plane', 'locked-plane-1.0.0.jar', '1.0.0',
          'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/locked-plane',
          100, true, '26.1.2', 'neoforge', '26.1.2.76'
        ),
        (
          'src_banned_islands_mc_26_1_2', 'banned-islands', 'Banned Islands', 'banned-islands-1.0.0.jar', '1.0.0',
          'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/banned-islands',
          100, true, '26.1.2', 'neoforge', '26.1.2.76'
        );
        """)

        let summary = try ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: fixture.root,
            databaseURL: database,
            minecraftVersion: "26.2",
            loader: "neoforge",
            loaderVersion: "26.2.0.3-beta",
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            limit: 0,
            seedFromProjectData: true
        )).run()

        #expect(summary.seededSources == 2)
        let csv = try duckDB.queryCSV("""
        SELECT
          (SELECT COUNT(*) FROM core.mod_sources WHERE minecraft_version = '26.2' AND mod_key = 'chunky') AS source_count,
          (SELECT active_status FROM core.mods WHERE minecraft_version = '26.2' AND canonical_key = 'chunky') AS active_status,
          (SELECT installed_on_server FROM core.mod_files WHERE minecraft_version = '26.2' AND file_name = 'Chunky-NeoForge-1.5.3.jar') AS file_installed,
          (SELECT compatibility_status FROM core.mod_server_files WHERE minecraft_version = '26.2' AND file_name = 'Chunky-NeoForge-1.5.3.jar') AS compatibility_status,
          (SELECT selected FROM core.mod_server_files WHERE minecraft_version = '26.2' AND file_name = 'Chunky-NeoForge-1.5.3.jar') AS selected,
          (SELECT active_status FROM core.mods WHERE minecraft_version = '26.2' AND canonical_key = 'locked-plane') AS locked_status,
          (SELECT compatibility_status FROM core.mod_server_files WHERE minecraft_version = '26.2' AND file_name = 'locked-plane-1.0.0.jar') AS locked_compatibility,
          (SELECT priority FROM core.mod_sources WHERE minecraft_version = '26.2' AND mod_key = 'locked-plane') AS locked_priority,
          (SELECT COUNT(*) FROM core.mod_sources WHERE minecraft_version = '26.2' AND mod_key = 'banned-islands') AS banned_source_count;
        """)
        let row = try #require(parseTestCSVRows(csv).first)
        #expect(row[0] == "1")
        #expect(row[1] == "awaiting_compatible_release")
        #expect(row[2] == "false")
        #expect(row[3] == "carry_forward_candidate")
        #expect(row[4] == "false")
        #expect(row[5] == "Admin Locked")
        #expect(row[6] == "admin_forced_carry_forward_candidate")
        #expect(row[7] == "1")
        #expect(row[8] == "0")
    }

    @Test("server version bootstrap copies working baseline files and skips banned mods")
    func serverVersionBootstrapCopiesWorkingBaselineFiles() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-version-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let referenceServer = root.appendingPathComponent("minecraft-26.1.2", isDirectory: true)
        let targetServer = root.appendingPathComponent("minecraft-26.2", isDirectory: true)
        for directory in [
            referenceServer.appendingPathComponent("mods"),
            referenceServer.appendingPathComponent("client-package/mods"),
            targetServer.appendingPathComponent("mods"),
            targetServer.appendingPathComponent("client-package/mods")
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let utilityJar = try writeNeoForgeJar(root: root, fileName: "utility-1.0.0.jar", displayName: "Utility", version: "1.0.0", side: "BOTH")
        let lockedJar = try writeNeoForgeJar(root: root, fileName: "locked-plane-1.0.0.jar", displayName: "Locked Plane", version: "1.0.0", side: "BOTH")
        let bannedJar = try writeNeoForgeJar(root: root, fileName: "banned-islands-1.0.0.jar", displayName: "Banned Islands", version: "1.0.0", side: "BOTH")
        try FileManager.default.copyItem(at: utilityJar, to: referenceServer.appendingPathComponent("mods/utility-1.0.0.jar"))
        try FileManager.default.copyItem(at: utilityJar, to: referenceServer.appendingPathComponent("client-package/mods/utility-1.0.0.jar"))
        try FileManager.default.copyItem(at: lockedJar, to: referenceServer.appendingPathComponent("mods/locked-plane-1.0.0.jar"))
        try FileManager.default.copyItem(at: lockedJar, to: referenceServer.appendingPathComponent("client-package/mods/locked-plane-1.0.0.jar"))
        try FileManager.default.copyItem(at: bannedJar, to: referenceServer.appendingPathComponent("mods/banned-islands-1.0.0.jar"))

        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        try #"{"version_number":"1.0.0","game_versions":["26.1.2"],"loaders":["neoforge"]}"#
            .write(to: webRoot.appendingPathComponent("utility.html"), atomically: true, encoding: .utf8)
        try #"{"version_number":"1.0.0","game_versions":["26.1.2"],"loaders":["neoforge"]}"#
            .write(to: webRoot.appendingPathComponent("locked.html"), atomically: true, encoding: .utf8)
        try #"{"version_number":"1.0.0","game_versions":["26.1.2"],"loaders":["neoforge"]}"#
            .write(to: webRoot.appendingPathComponent("banned.html"), atomically: true, encoding: .utf8)
        let http = try LocalHTTPServer(root: webRoot)
        try http.start()
        defer { http.stop() }

        let database = root.appendingPathComponent("bootstrap.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions(
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR,
          loader_version VARCHAR,
          server_name VARCHAR,
          server_address VARCHAR,
          server_dir VARCHAR,
          status VARCHAR,
          is_live BOOLEAN,
          sort_order INTEGER,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions VALUES
          ('26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2', '127.0.0.1:25565', \(sqlLiteral(referenceServer.path)), 'live', true, 10, now(), now(), 'live'),
          ('26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2', '127.0.0.1:25566', \(sqlLiteral(targetServer.path)), 'staging', false, 20, now(), now(), 'staging');
        CREATE TABLE core.mods(
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR,
          name VARCHAR,
          category VARCHAR,
          active_status VARCHAR,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mods VALUES
          (1, 'utility', 'Utility', 'Utility', 'ok', 'Installed', 'Server & Client', 'http://127.0.0.1:\(http.port)/utility.html', now(), '26.1.2', 'neoforge', '26.1.2.76'),
          (2, 'locked-plane', 'Locked Plane', 'Transport', 'Admin Locked', 'Admin forced', 'Server & Client', 'http://127.0.0.1:\(http.port)/locked.html', now(), '26.1.2', 'neoforge', '26.1.2.76'),
          (3, 'banned-islands', 'Banned Islands', 'Worldgen', 'Banned by Admin', 'Removed', 'Server-only', 'http://127.0.0.1:\(http.port)/banned.html', now(), '26.1.2', 'neoforge', '26.1.2.76');
        CREATE TABLE core.mod_files(
          id BIGINT PRIMARY KEY,
          mod_id BIGINT,
          role VARCHAR,
          file_name VARCHAR,
          path_hint VARCHAR,
          installed_on_server BOOLEAN,
          included_in_client BOOLEAN,
          status VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_files VALUES
          (1, 1, 'mod_file', 'utility-1.0.0.jar', 'mods/utility-1.0.0.jar', true, true, 'OK', '26.1.2', 'neoforge', '26.1.2.76'),
          (2, 2, 'mod_file', 'locked-plane-1.0.0.jar', 'mods/locked-plane-1.0.0.jar', true, true, 'OK', '26.1.2', 'neoforge', '26.1.2.76'),
          (3, 3, 'server_file', 'banned-islands-1.0.0.jar', 'mods/banned-islands-1.0.0.jar', true, false, 'Banned by Admin', '26.1.2', 'neoforge', '26.1.2.76');
        CREATE TABLE core.mod_server_files(
          id BIGINT PRIMARY KEY,
          mod_id BIGINT,
          file_name VARCHAR,
          role VARCHAR,
          source_url VARCHAR,
          compatibility_status VARCHAR,
          installed_on_server BOOLEAN,
          included_in_client BOOLEAN,
          selected BOOLEAN,
          file_sha256 VARCHAR,
          file_size_bytes BIGINT,
          last_synced TIMESTAMP,
          notes VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_server_files VALUES
          (1, 1, 'utility-1.0.0.jar', 'mod_file', 'http://127.0.0.1:\(http.port)/utility.html', 'ok', true, true, true, 'a', 10, now(), 'ok', '26.1.2', 'neoforge', '26.1.2.76'),
          (2, 2, 'locked-plane-1.0.0.jar', 'mod_file', 'http://127.0.0.1:\(http.port)/locked.html', 'ok', true, true, true, 'b', 20, now(), 'ok', '26.1.2', 'neoforge', '26.1.2.76'),
          (3, 3, 'banned-islands-1.0.0.jar', 'server_file', 'http://127.0.0.1:\(http.port)/banned.html', 'Banned by Admin', true, false, false, 'c', 30, now(), 'banned', '26.1.2', 'neoforge', '26.1.2.76');
        CREATE TABLE core.mod_sources(
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR,
          display_name VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR,
          source_url VARCHAR,
          priority INTEGER,
          active BOOLEAN,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_sources VALUES
          ('src_utility', 'utility', 'Utility', 'utility-1.0.0.jar', '1.0.0', 'curseforge', 'http://127.0.0.1:\(http.port)/utility.html', 100, true, now(), now(), '26.1.2', 'neoforge', '26.1.2.76'),
          ('src_locked', 'locked-plane', 'Locked Plane', 'locked-plane-1.0.0.jar', '1.0.0', 'curseforge', 'http://127.0.0.1:\(http.port)/locked.html', 100, true, now(), now(), '26.1.2', 'neoforge', '26.1.2.76'),
          ('src_banned', 'banned-islands', 'Banned Islands', 'banned-islands-1.0.0.jar', '1.0.0', 'curseforge', 'http://127.0.0.1:\(http.port)/banned.html', 100, true, now(), now(), '26.1.2', 'neoforge', '26.1.2.76');
        """)

        let dryRun = try ServerVersionBootstrapPipeline(config: ServerVersionBootstrapPipelineConfig(
            projectRoot: root,
            databaseURL: database,
            targetMinecraftVersion: "26.2",
            referenceMinecraftVersion: "26.1.2",
            discoverSourceLinks: false,
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            dryRun: true,
            applyUpdates: false
        )).run()

        #expect(dryRun.seededSources == 2)
        #expect(dryRun.copiedFiles.map(\.fileName).sorted() == ["locked-plane-1.0.0.jar", "utility-1.0.0.jar"])
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mods WHERE minecraft_version = '26.2';") == "0")
        #expect(!FileManager.default.fileExists(atPath: targetServer.appendingPathComponent("mods/utility-1.0.0.jar").path))

        let result = try ServerVersionBootstrapPipeline(config: ServerVersionBootstrapPipelineConfig(
            projectRoot: root,
            databaseURL: database,
            targetMinecraftVersion: "26.2",
            referenceMinecraftVersion: "26.1.2",
            discoverSourceLinks: false,
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            dryRun: false,
            applyUpdates: false
        )).run()

        #expect(result.seededSources == 2)
        #expect(result.copiedFiles.map(\.fileName).sorted() == ["locked-plane-1.0.0.jar", "utility-1.0.0.jar"])
        #expect(result.protectedMods == 1)
        #expect(FileManager.default.fileExists(atPath: targetServer.appendingPathComponent("mods/utility-1.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: targetServer.appendingPathComponent("client-package/mods/locked-plane-1.0.0.jar").path))
        #expect(!FileManager.default.fileExists(atPath: targetServer.appendingPathComponent("mods/banned-islands-1.0.0.jar").path))
        #expect(try duckDBScalar(database: database, sql: "SELECT compatibility_status FROM core.mod_server_files WHERE minecraft_version = '26.2' AND file_name = 'locked-plane-1.0.0.jar';") == "admin_forced_carry_forward_candidate")
        #expect(try duckDBScalar(database: database, sql: "SELECT compatibility_status FROM core.mod_server_files WHERE minecraft_version = '26.2' AND file_name = 'utility-1.0.0.jar';") == "carry_forward_candidate")
    }

    @Test("mod update scanner skips inactive live rows but scans staging candidates")
    func modUpdateScannerSkipsInactiveLiveRowsButScansStagingCandidates() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-mod-scan-active-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let webRoot = root.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: webRoot, withIntermediateDirectories: true)
        try #"{"latestVersion":"1.0.0"}"#.write(to: webRoot.appendingPathComponent("active.html"), atomically: true, encoding: .utf8)
        try #"{"latestVersion":"2.0.0"}"#.write(to: webRoot.appendingPathComponent("staging.html"), atomically: true, encoding: .utf8)
        let http = try LocalHTTPServer(root: webRoot)
        try http.start()
        defer { http.stop() }

        let database = root.appendingPathComponent("scan-active.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions (
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR NOT NULL,
          loader_version VARCHAR NOT NULL,
          server_name VARCHAR NOT NULL,
          server_address VARCHAR NOT NULL,
          server_dir VARCHAR,
          status VARCHAR NOT NULL,
          is_live BOOLEAN NOT NULL,
          sort_order INTEGER NOT NULL,
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions VALUES
          ('26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2', '127.0.0.1:25565', '/srv/live', 'live', true, 10, now(), 'live'),
          ('26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2', '127.0.0.1:25566', '/srv/staging', 'staging', false, 20, now(), 'staging');
        CREATE TABLE core.mod_sources(
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR,
          display_name VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR,
          source_url VARCHAR,
          priority INTEGER,
          active BOOLEAN,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE core.mods(
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR,
          name VARCHAR,
          category VARCHAR,
          active_status VARCHAR,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mods VALUES
          (
            1, 'example-mod', 'Example Mod', 'Gameplay', 'ok', 'Installed',
            'Server & Client', 'https://www.curseforge.com/minecraft/mc-mods/example-mod',
            now(), '26.1.2', 'neoforge', '26.1.2.76'
          ),
          (
            2, 'banned-mod', 'Banned Mod', 'Gameplay', 'Banned by Admin', 'removed',
            'removed', 'http://127.0.0.1:\(http.port)/banned.html',
            now(), '26.1.2', 'neoforge', '26.1.2.76'
          ),
          (
            3, 'banned-mod', 'Banned Mod', 'Gameplay', 'Banned by Admin', 'removed',
            'removed', 'http://127.0.0.1:\(http.port)/banned.html',
            now(), '26.2', 'neoforge', '26.2.0.3-beta'
          );
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, minecraft_version, loader, loader_version
        ) VALUES
          ('live_active', 'active-mod', 'Active Mod', 'active.jar', '1.0.0', 'web', 'http://127.0.0.1:\(http.port)/active.html', 100, true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('live_inactive', 'inactive-mod', 'Inactive Mod', 'inactive.jar', '1.0.0', 'web', 'http://127.0.0.1:1/inactive.html', 100, false, '26.1.2', 'neoforge', '26.1.2.76'),
          ('live_banned', 'banned-mod', 'Banned Mod', 'banned.jar', '1.0.0', 'web', 'http://127.0.0.1:\(http.port)/banned.html', 100, true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('staging_inactive', 'staging-mod', 'Staging Mod', 'staging.jar', '1.0.0', 'web', 'http://127.0.0.1:\(http.port)/staging.html', 100, false, '26.2', 'neoforge', '26.2.0.3-beta'),
          ('staging_banned', 'banned-mod', 'Banned Mod', 'banned.jar', '1.0.0', 'web', 'http://127.0.0.1:\(http.port)/banned.html', 100, true, '26.2', 'neoforge', '26.2.0.3-beta');
        """)

        let liveSummary = try ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: root,
            databaseURL: database,
            minecraftVersion: "26.1.2",
            loader: "neoforge",
            loaderVersion: "26.1.2.76",
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            seedFromProjectData: false,
            dryRun: true
        )).run()
        #expect(liveSummary.sourcesChecked == 1)
        #expect(liveSummary.unresolved == 0)

        let stagingSummary = try ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: root,
            databaseURL: database,
            minecraftVersion: "26.2",
            loader: "neoforge",
            loaderVersion: "26.2.0.3-beta",
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            seedFromProjectData: false,
            dryRun: true
        )).run()
        #expect(stagingSummary.sourcesChecked == 1)
        #expect(stagingSummary.candidatesFound == 1)
    }

    @Test("serves version-tagged mod inventory tables through Swift API")
    func servesVersionTaggedModInventoryTables() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let database = fixture.root.appendingPathComponent("data/test-phase6.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions (
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR NOT NULL DEFAULT 'neoforge',
          loader_version VARCHAR NOT NULL,
          server_name VARCHAR NOT NULL,
          server_address VARCHAR NOT NULL,
          server_dir VARCHAR,
          status VARCHAR NOT NULL,
          is_live BOOLEAN NOT NULL DEFAULT false,
          sort_order INTEGER NOT NULL DEFAULT 100,
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions(
          minecraft_version, loader, loader_version, server_name, server_address,
          server_dir, status, is_live, sort_order, updated_at, notes
        )
        VALUES
          ('26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2', '91.99.176.243:25565', '/srv/minecraft-26.1.2', 'live', true, 10, TIMESTAMP '2026-06-18 17:37:43', 'Current live play target.'),
          ('26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2', '91.99.176.243:25566', '/srv/minecraft-26.2', 'staging', false, 20, TIMESTAMP '2026-06-18 17:37:43', 'Staged for compatibility testing.');
        CREATE SCHEMA IF NOT EXISTS reporting;
        CREATE OR REPLACE VIEW reporting.v_minecraft_server_versions AS
        SELECT * FROM core.minecraft_server_versions;
        CREATE TABLE core.mod_sources (
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
        CREATE TABLE core.mod_source_links (
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
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, active, minecraft_version, loader, loader_version
        )
        VALUES
          ('fixture-server-26-1-2', 'fixture-server-mod', 'Fixture Server Mod', 'server-26.1.2.jar', '1.0.0', 'fixture', 'https://fixture.local/server', true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('fixture-server-26-2', 'fixture-server-mod', 'Fixture Server Mod', 'server-26.2.jar', '2.0.0', 'fixture', 'https://fixture.local/server', true, '26.2', 'neoforge', '26.2.0.3-beta'),
          ('fixture-client-26-1-2', 'fixture-client-mod', 'Fixture Client Mod', 'example-mod.jar', '1.0.0', 'fixture', 'https://fixture.local/client', true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('fixture-shared-26-1-2', 'fixture-shared-mod', 'Fixture Shared Mod', 'shared.jar', '1.0.0', 'fixture', 'https://fixture.local/shared', true, '26.1.2', 'neoforge', '26.1.2.76');
        INSERT INTO core.mod_source_links(
          link_id, source_id, mod_key, display_name, provider, link_role,
          source_url, priority, active, verified_at, minecraft_version, loader, loader_version, notes
        )
        VALUES
          ('fixture-client-cf', 'fixture-client-26-1-2', 'fixture-client-mod', 'Fixture Client Mod', 'curseforge', 'curseforge',
           'https://fixture.local/client', 25, true, now(), '26.1.2', 'neoforge', '26.1.2.76', 'fixture primary'),
          ('fixture-client-mr', 'fixture-client-26-1-2', 'fixture-client-mod', 'Fixture Client Mod', 'modrinth', 'modrinth',
           'https://modrinth.com/mod/fixture-client', 30, true, now(), '26.1.2', 'neoforge', '26.1.2.76', 'fixture alternate');
        """)
        let manifestDir = fixture.root.appendingPathComponent(
            "site/public/downloads/releases/release_20260612_V6_modernarch-refresh/manifests",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: manifestDir, withIntermediateDirectories: true)
        try """
        role	relative_path
        client_mods	client-files/mods/example-mod.jar
        client_mods	client-files/mods/shared.jar
        client_resourcepacks	client-files/resourcepacks/ModernArch v2.8.2 [26.1] [128x].zip
        client_shaderpacks	client-files/shaderpacks/BSL_v10.0.zip
        client_shaderpacks	client-files/shaderpacks/BSL_v10.0.zip.txt
        """.write(to: manifestDir.appendingPathComponent("client-package.tsv"), atomically: true, encoding: .utf8)

        let api = makeAPI(fixture: fixture)
        let serverMods = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/mod-inventory/server"))
        let clientMods = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/mod-inventory/client"))
        let mergedMods = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/mod-inventory/mods"))

        #expect(serverMods.statusCode == 200)
        #expect(clientMods.statusCode == 200)
        #expect(mergedMods.statusCode == 200)
        #expect(serverMods.headers["Cache-Control"] == "no-store, max-age=0")
        #expect(clientMods.headers["X-Pummelchen-Stats-Source"] == "swift-server-site-inventory")
        #expect(mergedMods.headers["X-Pummelchen-Stats-Source"] == "swift-server-site-inventory")

        let serverObject = try JSONSerialization.jsonObject(with: serverMods.body) as? [String: Any]
        let clientObject = try JSONSerialization.jsonObject(with: clientMods.body) as? [String: Any]
        let mergedObject = try JSONSerialization.jsonObject(with: mergedMods.body) as? [String: Any]
        let serverRows = try #require(serverObject?["rows"] as? [[String: Any]])
        let clientRows = try #require(clientObject?["rows"] as? [[String: Any]])
        let mergedRows = try #require(mergedObject?["rows"] as? [[String: Any]])
        let supportedVersions = try #require(serverObject?["supported_versions"] as? [[String: Any]])
        let serverCompatibility = try #require(serverRows.first?["compatibility"] as? [String: String])
        let fixtureClientRow = try #require(clientRows.first { $0["name"] as? String == "Fixture Client Mod" })
        let clientCompatibility = try #require(fixtureClientRow["compatibility"] as? [String: String])
        let mergedPlacements = Dictionary(uniqueKeysWithValues: mergedRows.compactMap { row -> (String, String)? in
            guard let name = row["name"] as? String, let placement = row["placement"] as? String else {
                return nil
            }
            return (name, placement)
        })

        #expect(serverObject?["minecraft_version"] as? String == "26.1.2")
        #expect(serverObject?["server_key"] as? String == "minecraft_26_1_2")
        #expect(serverObject?["release_id"] as? String == "release_20260612_V6_modernarch-refresh")
        #expect(serverObject?["scope"] as? String == "server")
        #expect(supportedVersions.count == 2)
        #expect(serverRows.first?["name"] as? String == "Fixture Server Mod")
        #expect(serverCompatibility["26.1.2"] == "Active")
        #expect(serverCompatibility["26.2"] == "Needs test")
        #expect(serverRows.first?["files"] as? String == "server-26.1.2.jar")
        #expect(serverRows.allSatisfy { (($0["type"] as? String) ?? "").localizedCaseInsensitiveContains("source") == false })
        #expect(clientObject?["scope"] as? String == "client")
        #expect(fixtureClientRow["sourceUrl"] as? String == "https://fixture.local/client")
        #expect(fixtureClientRow["sourceHost"] as? String == "fixture.local")
        let clientSourceLinks = try #require(fixtureClientRow["sourceLinks"] as? [[String: String]])
        #expect(clientSourceLinks.contains { $0["url"] == "https://fixture.local/client" })
        #expect(clientSourceLinks.contains { $0["provider"] == "modrinth" && $0["url"] == "https://modrinth.com/mod/fixture-client" })
        #expect(clientCompatibility["26.1.2"] == "Active")
        #expect(clientCompatibility["26.2"] == "Needs test")
        #expect(mergedObject?["scope"] as? String == "mods")
        #expect(mergedPlacements["Fixture Server Mod"] == "Server Mod")
        #expect(mergedPlacements["Fixture Client Mod"] == "Client Mod")
        #expect(mergedPlacements["Fixture Shared Mod"] == "Server & Client Mod")
        let clientTypes = Set(clientRows.compactMap { $0["type"] as? String })
        let mergedTypes = Set(mergedRows.compactMap { $0["type"] as? String })
        #expect(!clientTypes.contains("Client Mod"))
        #expect(!mergedTypes.contains("Server Mod"))
        #expect(clientTypes.contains("Gameplay"))
        #expect(clientTypes.contains("Textures Resource Pack"))
        #expect(clientTypes.contains("Shader Pack"))
        #expect(clientTypes.contains("Shader Configuration"))
        #expect(mergedTypes.allSatisfy { $0.split(separator: " ").count <= 5 })
    }

    @Test("serves supported Minecraft server versions from DuckDB")
    func servesSupportedMinecraftServerVersionsFromDuckDB() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let database = fixture.root.appendingPathComponent("data/test-phase6.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions (
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR NOT NULL DEFAULT 'neoforge',
          loader_version VARCHAR NOT NULL,
          server_name VARCHAR NOT NULL,
          server_address VARCHAR NOT NULL,
          server_dir VARCHAR,
          status VARCHAR NOT NULL,
          is_live BOOLEAN NOT NULL DEFAULT false,
          sort_order INTEGER NOT NULL DEFAULT 100,
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions(
          minecraft_version, loader, loader_version, server_name, server_address,
          server_dir, status, is_live, sort_order, updated_at, notes
        )
        VALUES
          ('26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2', '91.99.176.243:25565', '/srv/minecraft-26.1.2', 'live', true, 10, TIMESTAMP '2026-06-18 17:37:43', 'Current live play target.'),
          ('26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2', '91.99.176.243:25566', '/srv/minecraft-26.2', 'staging', false, 20, TIMESTAMP '2026-06-18 17:37:43', 'Staged for compatibility testing.');
        CREATE SCHEMA IF NOT EXISTS reporting;
        CREATE OR REPLACE VIEW reporting.v_minecraft_server_versions AS
        SELECT * FROM core.minecraft_server_versions;
        CREATE TABLE core.mod_sources (
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
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, active, minecraft_version, loader, loader_version
        )
        VALUES
          ('fixture-server-26-1-2', 'fixture-server-mod', 'Fixture Server Mod', 'server-26.1.2.jar', '1.0.0', 'fixture', 'https://fixture.local/server', true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('fixture-server-26-2', 'fixture-server-mod', 'Fixture Server Mod', 'server-26.2.jar', '2.0.0', 'fixture', 'https://fixture.local/server', true, '26.2', 'neoforge', '26.2.0.3-beta'),
          ('fixture-client-26-1-2', 'fixture-client-mod', 'Fixture Client Mod', 'client.jar', '1.0.0', 'fixture', 'https://fixture.local/client', true, '26.1.2', 'neoforge', '26.1.2.76');
        """)

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/minecraft/server-versions"))
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let versions = try #require(object?["versions"] as? [[String: Any]])

        #expect(response.statusCode == 200)
        #expect(response.headers["X-Pummelchen-Stats-Source"] == "swift-server-records")
        #expect(versions.count == 2)
        #expect(versions.first?["minecraft_version"] as? String == "26.1.2")
        #expect(versions.first?["is_live"] as? Bool == true)
        #expect(versions.first?["page_url"] as? String == "server-26.1.2.html")
        #expect(versions.first?["installer_name"] as? String == "neoforge-26.1.2.76-installer.jar")
        #expect(versions.first?["installer_url"] as? String == "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.2.76/neoforge-26.1.2.76-installer.jar")
        #expect(versions.first?["server_mod_count"] as? Int == 2)
        #expect(versions.first?["client_mod_count"] as? Int == 3)
        #expect(versions.last?["minecraft_version"] as? String == "26.2")
        #expect(versions.last?["status"] as? String == "staging")
        #expect(versions.last?["page_url"] as? String == "server-26.2.html")
        #expect(versions.last?["installer_name"] as? String == "neoforge-26.2.0.3-beta-installer.jar")
        #expect(versions.last?["installer_url"] as? String == "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.2.0.3-beta/neoforge-26.2.0.3-beta-installer.jar")
        #expect(versions.last?["server_mod_count"] as? Int == 0)
        #expect(versions.last?["client_mod_count"] as? Int == 0)
    }

    @Test("release history API includes live DuckDB releases")
    func releaseHistoryAPIIncludesLiveDuckDBReleases() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let database = fixture.root.appendingPathComponent("data/test-phase6.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
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
        INSERT INTO release.pack_releases(
          release_id, created_at, activated_at, server_key, server_dir, release_dir, status, active, notes
        )
        VALUES (
          'release_20260613_V23_update_check',
          TIMESTAMP '2026-06-13 18:25:41',
          TIMESTAMP '2026-06-13 18:26:12',
          'minecraft_26_1_2',
          '/srv/minecraft',
          '/srv/releases/release_20260613_V23_update_check',
          'active',
          true,
          'DMG release promoted'
        );
        """)

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/site/release-history"))
        let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let updates = try #require(object?["updates"] as? [[String: Any]])

        #expect(response.statusCode == 200)
        #expect(response.headers["X-Pummelchen-Stats-Source"] == "swift-server-records")
        #expect(updates.contains { ($0["id"] as? String) == "pr_release_20260613_V23_update_check" })
        #expect(updates.first?["test_label"] as? String == "release_20260613_V23_update_check")
        #expect(updates.first?["source_url"] as? String == "/release.html?release=release_20260613_V23_update_check")
    }

    @Test("rejects writes")
    func rejectsWrites() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture)
        let response = api.response(for: HTTPRequest(method: "POST", path: "/api/v1/releases/current"))

        #expect(response.statusCode == 405)
    }

    @Test("phase 6 write APIs require tokens and store client reports")
    func phase6WritesStoreClientReports() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase6-token")
        let encoder = JSONEncoder()
        let clientID = "client-phase6-a"
        let headers = authHeaders(token: "phase6-token", clientID: clientID)

        let register = ClientRegistrationRequest(clientID: clientID, displayName: "Andre Mac", osSummary: "macOS 15", arch: "arm64")
        let registerResponse = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/register",
            headers: headers,
            body: try encoder.encode(register)
        ))
        #expect(registerResponse.statusCode == 201)

        let report = ClientStatusReport(
            clientID: clientID,
            reportedAt: "2026-06-12T17:20:00+00:00",
            installedReleaseID: "release_20260612_V17_bsl-shader-config",
            targetReleaseID: "release_20260612_V17_bsl-shader-config",
            status: "synced",
            manifestEntries: 312,
            changedFiles: 0,
            lastError: nil,
            message: "all synced, no downloads required",
            osSummary: "macOS 15",
            arch: "arm64"
        )
        let reportResponse = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/sync-runs",
            headers: headers,
            body: try encoder.encode(report)
        ))
        #expect(reportResponse.statusCode == 200)

        let health = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/clients/health"))
        let summary = try JSONDecoder().decode(ClientHealthSummary.self, from: health.body)
        #expect(summary.totalClients == 1)
        #expect(summary.synced == 1)
    }

    @Test("phase 6 rejects bad tokens, oversized payloads, and client id mismatch")
    func phase6RejectsUnsafeWrites() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase6-token", maxWritePayloadBytes: 32)
        let body = try JSONEncoder().encode(ClientRegistrationRequest(clientID: "client-phase6-b", displayName: nil, osSummary: nil, arch: nil))

        let badToken = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/register",
            headers: authHeaders(token: "wrong", clientID: "client-phase6-b"),
            body: body
        ))
        #expect(badToken.statusCode == 401)

        let mismatch = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/register",
            headers: authHeaders(token: "phase6-token", clientID: "other-client"),
            body: body
        ))
        #expect(mismatch.statusCode == 401)

        let oversized = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/register",
            headers: authHeaders(token: "phase6-token", clientID: "client-phase6-b"),
            body: Data(repeating: 65, count: 64)
        ))
        #expect(oversized.statusCode == 413)
    }

    @Test("server errors redact bearer tokens")
    func redactsBearerTokensFromErrors() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase6-token")
        let clientID = "client-redact-a"
        let response = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/diagnostics",
            headers: authHeaders(token: "phase6-token", clientID: clientID),
            body: Data(#"{"client_id":"client-redact-a","reported_at":"not a date","level":"warning","summary":"Authorization: Bearer should-not-leak","details":null}"#.utf8)
        ))
        let body = String(decoding: response.body, as: UTF8.self)

        #expect(!body.contains("should-not-leak"))
    }

    @Test("phase 6 stores inventory diagnostics and defaults repair state")
    func phase6StoresInventoryDiagnosticsAndDefaults() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase6-token")
        let encoder = JSONEncoder()
        let clientID = "client-phase6-c"
        let headers = authHeaders(token: "phase6-token", clientID: clientID)
        _ = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/clients/register",
            headers: headers,
            body: try encoder.encode(ClientRegistrationRequest(clientID: clientID, displayName: nil, osSummary: "macOS", arch: "arm64"))
        ))

        let inventory = ClientInventoryUpload(
            clientID: clientID,
            reportedAt: "2026-06-12T17:21:00+00:00",
            files: [
                ClientInventoryFile(
                    section: "mods",
                    name: "example.jar",
                    sizeBytes: 12,
                    sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    status: "verified"
                )
            ]
        )
        #expect(api.response(for: HTTPRequest(method: "POST", path: "/api/v1/clients/inventory", headers: headers, body: try encoder.encode(inventory))).statusCode == 200)

        let diagnostics = ClientDiagnosticsUpload(
            clientID: clientID,
            reportedAt: "2026-06-12T17:22:00+00:00",
            level: "warning",
            summary: "checksum failed",
            details: "Authorization: Bearer secret-token"
        )
        #expect(api.response(for: HTTPRequest(method: "POST", path: "/api/v1/clients/diagnostics", headers: headers, body: try encoder.encode(diagnostics))).statusCode == 200)

        let defaults = ClientDefaultsEventUpload(
            clientID: clientID,
            reportedAt: "2026-06-12T17:23:00+00:00",
            defaultsOK: false,
            events: [
                ClientDefaultsEvent(key: "shaderPack", status: "missing", desiredValue: "BSL_v10.1.3.zip", observedValue: nil)
            ]
        )
        #expect(api.response(for: HTTPRequest(method: "POST", path: "/api/v1/clients/defaults-events", headers: headers, body: try encoder.encode(defaults))).statusCode == 200)

        let health = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/clients/health"))
        let summary = try JSONDecoder().decode(ClientHealthSummary.self, from: health.body)
        #expect(summary.needsDefaultsRepair == 1)
    }

    @Test("phase 7 creates an immutable release that the Swift client can sync")
    func phase7CreatesClientSyncableRelease() async throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-phase7-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        let releaseRoot = root.appendingPathComponent("releases", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let publicDownloads = site.appendingPathComponent("downloads", isDirectory: true)
        let clientPackage = serverDir.appendingPathComponent("client-package", isDirectory: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("shaderpacks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("site/public/data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("server-datapacks"), withIntermediateDirectories: true)

        try "client mod".write(to: clientPackage.appendingPathComponent("mods/example-client.jar"), atomically: true, encoding: .utf8)
        try "AURORA=2\n".write(to: clientPackage.appendingPathComponent("shaderpacks/BSL_v10.1.3.zip.txt"), atomically: true, encoding: .utf8)
        let syncHelper = clientPackage.appendingPathComponent("tools/pummelchen-client-sync")
        try "#!/bin/sh\nexit 0\n".write(to: syncHelper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: syncHelper.path)
        try "server mod".write(to: serverDir.appendingPathComponent("mods/example-server.jar"), atomically: true, encoding: .utf8)
        try "datapack".write(to: serverDir.appendingPathComponent("server-datapacks/pummelchen-welcome.zip"), atomically: true, encoding: .utf8)

        let liveClientZipName = SwiftReleasePipeline.clientZipName(minecraftVersion: "26.1.2")
        let liveMrpackName = SwiftReleasePipeline.mrpackName(minecraftVersion: "26.1.2")
        try writeArtifact(name: liveClientZipName, content: "zip", serverDir: serverDir)
        try writeArtifact(name: liveMrpackName, content: "mrpack", serverDir: serverDir)
        let dmgSHA = try writeArtifact(name: SwiftReleasePipeline.dmgName, content: "dmg", serverDir: serverDir)

        let releaseID = "release_20260613_V77_swift_phase7_test"
        try writeDMGHeadlessLiveSoakReport(releaseID: releaseID, dmgSHA: dmgSHA, serverDir: serverDir)
        let tempCleanupRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let clientBuildTemp = clientPackage.appendingPathComponent(".build/pummelchen-dmg/stage", isDirectory: true)
        let projectBuildTemp = root.appendingPathComponent(".build/pummelchen-dmg/nginx-control-live-test", isDirectory: true)
        let binaryBackups = root.appendingPathComponent("bin/backups", isDirectory: true)
        let sparkTmp = serverDir.appendingPathComponent("config/spark/tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: clientBuildTemp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectBuildTemp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaryBackups, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sparkTmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempCleanupRoot.appendingPathComponent("pummelchen-headless-soak-test", isDirectory: true), withIntermediateDirectories: true)
        try "build temp".write(to: clientBuildTemp.appendingPathComponent("old.app"), atomically: true, encoding: .utf8)
        try "control temp".write(to: projectBuildTemp.appendingPathComponent("client.duckdb"), atomically: true, encoding: .utf8)
        try "old backup".write(to: binaryBackups.appendingPathComponent("MCPummelchenModServer.old"), atomically: true, encoding: .utf8)
        try "spark temp".write(to: sparkTmp.appendingPathComponent("spark-test-profile-data.jfr.tmp"), atomically: true, encoding: .utf8)
        try "old dmg".write(to: tempCleanupRoot.appendingPathComponent(SwiftReleasePipeline.dmgName), atomically: true, encoding: .utf8)
        try "pipeline log".write(to: tempCleanupRoot.appendingPathComponent("daily_release_pipeline_test.log"), atomically: true, encoding: .utf8)
        let pipeline = SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: releaseRoot,
            publicDownloads: publicDownloads,
            databaseURL: root.appendingPathComponent("phase7.duckdb"),
            releaseID: releaseID,
            notes: "phase 7 test release",
            activate: true,
            buildClientZipIfMissing: false,
            serviceName: "",
            tempCleanupRoot: tempCleanupRoot
        ))

        let result = try pipeline.createRelease()
        #expect(result.releaseID == releaseID)
        #expect(result.activated)
        try pipeline.validateRelease()

        let current = try CurrentReleaseValidator.decode(Data(contentsOf: publicDownloads.appendingPathComponent("current-release.json")))
        #expect(current.releaseID == releaseID)
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(SwiftReleasePipeline.dmgName)").path))
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(SwiftReleasePipeline.dmgName).sha256").path))
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName)").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: publicDownloads.appendingPathComponent(SwiftReleasePipeline.dmgName).path)) == "releases/\(releaseID)/\(SwiftReleasePipeline.dmgName)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: publicDownloads.appendingPathComponent(liveClientZipName).path)) == "releases/\(releaseID)/\(liveClientZipName)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: publicDownloads.appendingPathComponent(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName).path)) == "releases/\(releaseID)/\(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName)")
        #expect(!FileManager.default.fileExists(atPath: clientPackage.appendingPathComponent(".build").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".build/pummelchen-dmg").path))
        #expect(!FileManager.default.fileExists(atPath: binaryBackups.path))
        #expect(!FileManager.default.fileExists(atPath: sparkTmp.appendingPathComponent("spark-test-profile-data.jfr.tmp").path))
        #expect(!FileManager.default.fileExists(atPath: tempCleanupRoot.appendingPathComponent(SwiftReleasePipeline.dmgName).path))
        #expect(!FileManager.default.fileExists(atPath: tempCleanupRoot.appendingPathComponent("daily_release_pipeline_test.log").path))
        let cleanupEventCount = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT count(*) FROM release.release_events WHERE release_id = '\(releaseID)' AND event_type = 'cleanup' AND status = 'ok';")
        #expect(cleanupEventCount == "1")
        #expect(!FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/data/tested-updates.json").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("site/public/tested-updates.json").path))
        let publicManifest = try String(contentsOf: publicDownloads.appendingPathComponent("releases/\(releaseID)/client-sync-manifest.tsv"), encoding: .utf8)
        let manifest = try ClientSyncManifestParser.parse(publicManifest)
        #expect(manifest.entries.contains { $0.section == "shaderpacks" && $0.name == "BSL_v10.1.3.zip.txt" })

        let http = try LocalHTTPServer(root: site)
        try http.start()
        defer { http.stop() }

        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let engine = ClientSyncEngine(configuration: ClientSyncConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(http.port)")!,
            minecraftDirectory: minecraft,
            pummelchenHome: home,
            databaseURL: home.appendingPathComponent("client.duckdb"),
            allowWhileMinecraftRunning: true,
            reportToServer: false,
            manageJavaRuntime: false
        ))
        let sync = try await engine.sync(force: true)
        #expect(sync.targetReleaseID == releaseID)
        #expect(sync.filesDownloaded == 3)
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("mods/example-client.jar").path))
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("shaderpacks/BSL_v10.1.3.zip.txt").path))

        let healthRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT COUNT(*) FROM release.release_health_results WHERE release_id = '\(releaseID)';")
        #expect(healthRows == "3")
        let headlessRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT COUNT(*) FROM core.headless_client_runs WHERE release_id = '\(releaseID)' AND status = 'passed' AND duration_seconds >= 60;")
        #expect(headlessRows == "1")
        let restartRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT COUNT(*) FROM release.release_events WHERE release_id = '\(releaseID)' AND event_type = 'restart' AND status = 'skipped';")
        #expect(restartRows == "1")
        let activeRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT active FROM release.pack_releases WHERE release_id = '\(releaseID)';")
        #expect(activeRows == "true")
    }

    @Test("phase 7 rejects DMG releases without a headless live server soak")
    func phase7RejectsDMGWithoutHeadlessLiveSoak() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-phase7-dmg-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        let releaseRoot = root.appendingPathComponent("releases", isDirectory: true)
        let publicDownloads = root.appendingPathComponent("site/downloads", isDirectory: true)
        let clientPackage = serverDir.appendingPathComponent("client-package", isDirectory: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try "client mod".write(to: clientPackage.appendingPathComponent("mods/example-client.jar"), atomically: true, encoding: .utf8)
        try writeArtifact(name: SwiftReleasePipeline.clientZipName(minecraftVersion: "26.1.2"), content: "zip", serverDir: serverDir)
        try writeArtifact(name: SwiftReleasePipeline.mrpackName(minecraftVersion: "26.1.2"), content: "mrpack", serverDir: serverDir)
        try writeArtifact(name: SwiftReleasePipeline.dmgName, content: "dmg", serverDir: serverDir)

        let pipeline = SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: releaseRoot,
            publicDownloads: publicDownloads,
            databaseURL: root.appendingPathComponent("phase7.duckdb"),
            releaseID: "release_20260613_V78_missing_dmg_soak",
            buildClientZipIfMissing: false
        ))

        do {
            _ = try pipeline.createRelease()
            Issue.record("DMG release should require \(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName)")
        } catch SwiftReleasePipelineError.missingRequiredPath(let path) {
            #expect(path.hasSuffix(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName))
        }
    }

    @Test("phase 7 prunes old release storage after activation")
    func phase7PrunesOldReleaseStorageAfterActivation() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-phase7-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        let releaseRoot = root.appendingPathComponent("releases", isDirectory: true)
        let publicDownloads = root.appendingPathComponent("site/downloads", isDirectory: true)
        let clientPackage = serverDir.appendingPathComponent("client-package", isDirectory: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try "client mod".write(to: clientPackage.appendingPathComponent("mods/example-client.jar"), atomically: true, encoding: .utf8)
        try "server mod".write(to: serverDir.appendingPathComponent("mods/example-server.jar"), atomically: true, encoding: .utf8)
        try writeArtifact(name: SwiftReleasePipeline.clientZipName(minecraftVersion: "26.1.2"), content: "zip", serverDir: serverDir)
        try writeArtifact(name: SwiftReleasePipeline.mrpackName(minecraftVersion: "26.1.2"), content: "mrpack", serverDir: serverDir)

        let database = root.appendingPathComponent("phase7-retention.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS release;
        CREATE TABLE release.pack_releases (
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
        """)
        for index in 1...3 {
            let releaseID = "release_20260610_V\(index)_old_retention"
            try FileManager.default.createDirectory(at: releaseRoot.appendingPathComponent(releaseID), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: publicDownloads.appendingPathComponent("releases/\(releaseID)"), withIntermediateDirectories: true)
            try DuckDBDatabase(databaseURL: database).execute("""
            INSERT INTO release.pack_releases(
              release_id, created_at, activated_at, server_key, minecraft_version, loader_version, server_dir, release_dir, status, active
            )
            VALUES (
              '\(releaseID)',
              TIMESTAMP '2026-06-10 00:0\(index):00',
              TIMESTAMP '2026-06-10 00:0\(index):30',
              'minecraft_26_1_2',
              '26.1.2',
              '26.1.2.76',
              '\(serverDir.path)',
              '\(releaseRoot.appendingPathComponent(releaseID).path)',
              'active',
              false
            );
            """)
        }

        let releaseID = "release_20260613_V79_retention_test"
        let pipeline = SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: releaseRoot,
            publicDownloads: publicDownloads,
            databaseURL: database,
            releaseID: releaseID,
            activate: true,
            buildClientZipIfMissing: false,
            releaseRetentionPerServer: 2
        ))

        _ = try pipeline.createRelease()

        #expect(FileManager.default.fileExists(atPath: releaseRoot.appendingPathComponent(releaseID).path))
        #expect(FileManager.default.fileExists(atPath: releaseRoot.appendingPathComponent("release_20260610_V3_old_retention").path))
        #expect(!FileManager.default.fileExists(atPath: releaseRoot.appendingPathComponent("release_20260610_V1_old_retention").path))
        #expect(!FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/release_20260610_V1_old_retention").path))
    }

    @Test("phase 7 staging releases use version scoped pack artifacts")
    func phase7StagingReleaseUsesVersionScopedPackArtifacts() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-phase7-versioned-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server-26.2", isDirectory: true)
        let releaseRoot = root.appendingPathComponent("releases", isDirectory: true)
        let publicDownloads = root.appendingPathComponent("site/downloads", isDirectory: true)
        let clientPackage = serverDir.appendingPathComponent("client-package", isDirectory: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try "client mod 26.2".write(to: clientPackage.appendingPathComponent("mods/example-client-26.2.jar"), atomically: true, encoding: .utf8)
        try "server mod 26.2".write(to: serverDir.appendingPathComponent("mods/example-server-26.2.jar"), atomically: true, encoding: .utf8)

        let clientZip = SwiftReleasePipeline.clientZipName(minecraftVersion: "26.2")
        let mrpack = SwiftReleasePipeline.mrpackName(minecraftVersion: "26.2")
        try writeArtifact(name: clientZip, content: "zip 26.2", serverDir: serverDir)
        try writeArtifact(name: mrpack, content: "mrpack 26.2", serverDir: serverDir)

        let releaseID = "release_20260619_V99_mc_26_2_staging"
        let pipeline = SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: releaseRoot,
            publicDownloads: publicDownloads,
            databaseURL: root.appendingPathComponent("phase7-versioned.duckdb"),
            releaseID: releaseID,
            serverKey: "minecraft_26_2",
            minecraftVersion: "26.2",
            loaderVersion: "26.2.0.3-beta",
            status: "staging",
            activate: true,
            buildClientZipIfMissing: false
        ))

        _ = try pipeline.createRelease()
        let current = try CurrentReleaseValidator.decode(Data(contentsOf: publicDownloads.appendingPathComponent("current-release-26.2.json")))
        #expect(current.serverKey == "minecraft_26_2")
        #expect(current.minecraftVersion == "26.2")
        #expect(current.loaderVersion == "26.2.0.3-beta")
        #expect(current.clientZipURL == "/downloads/releases/\(releaseID)/\(clientZip)")
        #expect(current.mrpackURL == "/downloads/releases/\(releaseID)/\(mrpack)")
        #expect(!current.clientZipURL.contains("26.1.2"))
        #expect(!current.mrpackURL.contains("26.1.2"))
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(clientZip)").path))
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(mrpack)").path))
        #expect(!FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("current-release.json").path))
        let activeServerKey = try duckDBScalar(database: root.appendingPathComponent("phase7-versioned.duckdb"), sql: "SELECT server_key FROM release.pack_releases WHERE release_id = '\(releaseID)' AND active = true;")
        #expect(activeServerKey == "minecraft_26_2")
    }

    @Test("phase 7 rejects old DMG soak reports without new-player setup acceptance")
    func phase7RejectsDMGSoakWithoutNewPlayerSetupAcceptance() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-phase7-dmg-new-player-gate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        let releaseRoot = root.appendingPathComponent("releases", isDirectory: true)
        let publicDownloads = root.appendingPathComponent("site/downloads", isDirectory: true)
        let clientPackage = serverDir.appendingPathComponent("client-package", isDirectory: true)
        try FileManager.default.createDirectory(at: clientPackage.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        try "client mod".write(to: clientPackage.appendingPathComponent("mods/example-client.jar"), atomically: true, encoding: .utf8)
        try writeArtifact(name: SwiftReleasePipeline.clientZipName(minecraftVersion: "26.1.2"), content: "zip", serverDir: serverDir)
        try writeArtifact(name: SwiftReleasePipeline.mrpackName(minecraftVersion: "26.1.2"), content: "mrpack", serverDir: serverDir)
        let dmgSHA = try writeArtifact(name: SwiftReleasePipeline.dmgName, content: "dmg", serverDir: serverDir)
        let releaseID = "release_20260613_V79_missing_new_player_setup"
        try writeLegacyDMGHeadlessLiveSoakReport(releaseID: releaseID, dmgSHA: dmgSHA, serverDir: serverDir)

        let pipeline = SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: releaseRoot,
            publicDownloads: publicDownloads,
            databaseURL: root.appendingPathComponent("phase7.duckdb"),
            releaseID: releaseID,
            buildClientZipIfMissing: false
        ))

        do {
            _ = try pipeline.createRelease()
            Issue.record("DMG release should require new-player setup acceptance evidence")
        } catch ContractValidationError.invalid(let message) {
            #expect(message.contains("new-player setup acceptance"))
        }
    }

    @Test("add-mod dry run resolves local NeoForge metadata without changing package dirs")
    func addModDryRunResolvesLocalNeoForgeMetadata() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-add-mod-dry-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        let artifact = try writeNeoForgeJar(
            root: root,
            fileName: "pummelchen-example-1.2.3.jar",
            displayName: "Pummelchen Example",
            version: "1.2.3",
            side: "BOTH"
        )
        let result = try ModAddPipeline(config: ModAddPipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: root.appendingPathComponent("releases", isDirectory: true),
            publicDownloads: root.appendingPathComponent("site/public/downloads", isDirectory: true),
            databaseURL: root.appendingPathComponent("add-mod.duckdb"),
            sourceURL: "https://www.curseforge.com/minecraft/mc-mods/pummelchen-example",
            localArtifact: artifact,
            releaseID: "release_20260614_V99_add_mod_dry_run",
            dryRun: true
        )).run()

        #expect(result.dryRun)
        #expect(!result.releaseCreated)
        #expect(result.artifacts.first?.displayName == "Pummelchen Example")
        #expect(result.artifacts.first?.version == "1.2.3")
        #expect(result.artifacts.first?.copiedToServer == true)
        #expect(result.artifacts.first?.copiedToClient == true)
        #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/pummelchen-example-1.2.3.jar").path))
    }

    @Test("add-mod installs a local NeoForge jar and creates a release")
    func addModInstallsLocalNeoForgeJarAndCreatesRelease() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-add-mod-release-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("client-package/mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        let artifact = try writeNeoForgeJar(
            root: root,
            fileName: "pummelchen-release-example-2.0.0.jar",
            displayName: "Pummelchen Release Example",
            version: "2.0.0",
            side: "BOTH"
        )

        let releaseID = "release_20260614_V100_add_mod_release"
        let result = try ModAddPipeline(config: ModAddPipelineConfig(
            projectRoot: root,
            serverDir: serverDir,
            releaseRoot: root.appendingPathComponent("releases", isDirectory: true),
            publicDownloads: root.appendingPathComponent("site/public/downloads", isDirectory: true),
            databaseURL: root.appendingPathComponent("add-mod.duckdb"),
            sourceURL: "https://www.curseforge.com/minecraft/mc-mods/pummelchen-release-example",
            localArtifact: artifact,
            releaseID: releaseID,
            serviceName: nil,
            activate: true,
            dryRun: false,
            clientAPIToken: "test-token",
            requireClientToken: false
        )).run()

        #expect(result.releaseCreated)
        #expect(result.releaseActivated)
        #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/pummelchen-release-example-2.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("client-package/mods/pummelchen-release-example-2.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("site/public/downloads/current-release.json").path))
        let current = try CurrentReleaseValidator.decode(Data(contentsOf: root.appendingPathComponent("site/public/downloads/current-release.json")))
        #expect(current.releaseID == releaseID)
        let sourceRows = try duckDBScalar(database: root.appendingPathComponent("add-mod.duckdb"), sql: "SELECT COUNT(*) FROM core.mod_sources WHERE installed_file = 'pummelchen-release-example-2.0.0.jar';")
        #expect(sourceRows == "1")
    }

    @Test("ban-mod removes matching jars from all supported server and client packages")
    func banModRemovesMatchingJarsFromAllSupportedPackages() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-ban-mod-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let server261 = root.appendingPathComponent("minecraft-26.1.2", isDirectory: true)
        let server262 = root.appendingPathComponent("minecraft-26.2", isDirectory: true)
        for serverDir in [server261, server262] {
            try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("client-package/mods"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("config/cristellib/ocean_lily_pad_village"), withIntermediateDirectories: true)
            try "bad".write(to: serverDir.appendingPathComponent("mods/ocean_lily_pad_village-1.0.0 Neoforge 26.1.2.jar"), atomically: true, encoding: .utf8)
            try "bad-client".write(to: serverDir.appendingPathComponent("client-package/mods/ocean_lily_pad_village-1.0.0 Neoforge 26.1.2.jar"), atomically: true, encoding: .utf8)
            try "config".write(to: serverDir.appendingPathComponent("config/cristellib/ocean_lily_pad_village/settings.json"), atomically: true, encoding: .utf8)
            try "keep".write(to: serverDir.appendingPathComponent("mods/other-structure.jar"), atomically: true, encoding: .utf8)
        }

        let database = root.appendingPathComponent("ban.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions(
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR,
          loader_version VARCHAR,
          server_name VARCHAR,
          server_address VARCHAR,
          server_dir VARCHAR,
          status VARCHAR,
          is_live BOOLEAN,
          sort_order INTEGER,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions VALUES
          ('26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2', '127.0.0.1:25565', \(sqlLiteral(server261.path)), 'live', true, 10, now(), now(), 'test'),
          ('26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2', '127.0.0.1:25566', \(sqlLiteral(server262.path)), 'staging', false, 20, now(), now(), 'test');
        CREATE TABLE core.mod_sources(
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR,
          display_name VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR,
          source_url VARCHAR,
          priority INTEGER,
          active BOOLEAN,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, minecraft_version, loader, loader_version
        ) VALUES
          ('ocean_lily_261', 'ocean-lily-pad-village', 'Ocean Lily Pad Village', 'ocean_lily_pad_village-1.0.0 Neoforge 26.1.2.jar', '1.0.0', 'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/ocean-lily-pad-village', 100, true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('ocean_lily_262', 'ocean-lily-pad-village', 'Ocean Lily Pad Village', 'ocean_lily_pad_village-1.0.0 Neoforge 26.1.2.jar', '1.0.0', 'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/ocean-lily-pad-village', 100, true, '26.2', 'neoforge', '26.2.0.3-beta');
        """)

        let result = try ModBanPipeline(config: ModBanPipelineConfig(
            projectRoot: root,
            databaseURL: database,
            displayName: "Ocean Lily Pad Village",
            filePatterns: ["ocean_lily_pad_village"],
            sourceURL: "https://www.curseforge.com/minecraft/mc-mods/ocean-lily-pad-village",
            dryRun: false
        )).run()

        #expect(result.removals.count == 6)
        #expect(result.removals.allSatisfy { $0.removed })
        for serverDir in [server261, server262] {
            #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/ocean_lily_pad_village-1.0.0 Neoforge 26.1.2.jar").path))
            #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("client-package/mods/ocean_lily_pad_village-1.0.0 Neoforge 26.1.2.jar").path))
            #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("config/cristellib/ocean_lily_pad_village").path))
            #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/other-structure.jar").path))
        }
        #expect(try duckDBScalar(database: database, sql: "SELECT active_status FROM core.mods WHERE canonical_key = 'ocean-lily-pad-village';") == "Banned by Admin")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources WHERE active = false;") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.failed_mod_update_status WHERE failure_reason = 'Banned by Admin' AND active_status = 'Banned by Admin';") == "2")
    }

    @Test("mod update apply replaces old jars and creates a live release")
    func modUpdateApplyReplacesOldJarsAndCreatesLiveRelease() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-mod-update-apply-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("client-package/mods"), withIntermediateDirectories: true)
        let oldJar = try writeNeoForgeJar(root: root, fileName: "example-mod-1.0.0.jar", displayName: "Example Mod", version: "1.0.0", side: "BOTH")
        try FileManager.default.copyItem(at: oldJar, to: serverDir.appendingPathComponent("mods/example-mod-1.0.0.jar"))
        try FileManager.default.copyItem(at: oldJar, to: serverDir.appendingPathComponent("client-package/mods/example-mod-1.0.0.jar"))

        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        _ = try writeNeoForgeJar(root: downloads, fileName: "example-mod-2.0.0.jar", displayName: "Example Mod", version: "2.0.0", side: "BOTH")
        let http = try LocalHTTPServer(root: downloads)
        try http.start()
        defer { http.stop() }

        let database = root.appendingPathComponent("updates.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions(
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR,
          loader_version VARCHAR,
          server_name VARCHAR,
          server_address VARCHAR,
          server_dir VARCHAR,
          status VARCHAR,
          is_live BOOLEAN,
          sort_order INTEGER,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions(
          minecraft_version, loader, loader_version, server_name, server_address,
          server_dir, status, is_live, sort_order
        ) VALUES (
          '26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2',
          '127.0.0.1:25565', \(sqlLiteral(serverDir.path)), 'live', true, 10
        );
        CREATE TABLE core.mods(
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR,
          name VARCHAR,
          category VARCHAR,
          active_status VARCHAR,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mods VALUES (
          1, 'example-mod', 'Example Mod', 'Gameplay', 'ok', 'Installed',
          'Server & Client', 'https://www.curseforge.com/minecraft/mc-mods/example-mod',
          now(), '26.1.2', 'neoforge', '26.1.2.76'
        );
        CREATE TABLE core.mod_sources(
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR,
          display_name VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR,
          source_url VARCHAR,
          priority INTEGER,
          active BOOLEAN,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, minecraft_version, loader, loader_version
        ) VALUES (
          'curseforge_1_10_mc_26_1_2', 'example-mod', 'Example Mod',
          'example-mod-1.0.0.jar', '1.0.0', 'curseforge',
          'https://www.curseforge.com/minecraft/mc-mods/example-mod', 100,
          true, '26.1.2', 'neoforge', '26.1.2.76'
        );
        CREATE TABLE core.mod_update_scans(
          scan_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP,
          finished_at TIMESTAMP,
          status VARCHAR,
          urls_checked INTEGER,
          candidates_found INTEGER,
          unresolved INTEGER,
          notes VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_update_scans VALUES (
          'scan_test', TIMESTAMP '2026-06-19 12:00:00', TIMESTAMP '2026-06-19 12:00:10',
          'completed', 1, 1, 0, 'test', '26.1.2', 'neoforge', '26.1.2.76'
        );
        CREATE TABLE core.mod_update_scan_results(
          result_id VARCHAR PRIMARY KEY,
          scan_id VARCHAR,
          source_id VARCHAR,
          checked_at TIMESTAMP,
          provider VARCHAR,
          source_url VARCHAR,
          status VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          details VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_update_scan_results VALUES (
          'result_test', 'scan_test', 'curseforge_1_10_mc_26_1_2',
          TIMESTAMP '2026-06-19 12:00:01', 'curseforge',
          'https://www.curseforge.com/minecraft/mc-mods/example-mod',
          'update_available', 'example-mod-1.0.0.jar', '1.0.0',
          '2.0.0', 'http://127.0.0.1:\(http.port)/example-mod-2.0.0.jar',
          'test candidate', '26.1.2', 'neoforge', '26.1.2.76'
        );
        """)

        let result = try ModUpdateApplyPipeline(config: ModUpdateApplyPipelineConfig(
            projectRoot: root,
            releaseRoot: root.appendingPathComponent("releases", isDirectory: true),
            publicDownloads: root.appendingPathComponent("site/public/downloads", isDirectory: true),
            databaseURL: database,
            minecraftVersion: "26.1.2",
            releaseIDPrefix: "release_20260619_V101_mod_updates",
            activateLiveVersions: true,
            dryRun: false
        )).run()

        #expect(result.versions.first?.status == "active")
        #expect(result.versions.first?.appliedUpdates.first?.newFile == "example-mod-2.0.0.jar")
        #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/example-mod-1.0.0.jar").path))
        #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("client-package/mods/example-mod-1.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/example-mod-2.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("client-package/mods/example-mod-2.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("site/public/downloads/current-release.json").path))
        #expect(try duckDBScalar(database: database, sql: "SELECT installed_file FROM core.mod_sources WHERE source_id = 'curseforge_1_10_mc_26_1_2';") == "example-mod-2.0.0.jar")
    }

    @Test("mod update apply isolates admin-forced candidates from non-priority failures")
    func modUpdateApplyIsolatesPriorityCandidatesFromNonPriorityFailures() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-priority-mod-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("client-package/mods"), withIntermediateDirectories: true)
        let priorityOld = try writeNeoForgeJar(root: root, fileName: "priority-plane-1.0.0.jar", displayName: "Priority Plane", version: "1.0.0", side: "BOTH")
        let regularOld = try writeNeoForgeJar(root: root, fileName: "regular-mod-1.0.0.jar", displayName: "Regular Mod", version: "1.0.0", side: "BOTH")
        try FileManager.default.copyItem(at: priorityOld, to: serverDir.appendingPathComponent("mods/priority-plane-1.0.0.jar"))
        try FileManager.default.copyItem(at: priorityOld, to: serverDir.appendingPathComponent("client-package/mods/priority-plane-1.0.0.jar"))
        try FileManager.default.copyItem(at: regularOld, to: serverDir.appendingPathComponent("mods/regular-mod-1.0.0.jar"))
        try FileManager.default.copyItem(at: regularOld, to: serverDir.appendingPathComponent("client-package/mods/regular-mod-1.0.0.jar"))

        let downloads = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        _ = try writeNeoForgeJar(root: downloads, fileName: "priority-plane-2.0.0.jar", displayName: "Priority Plane", version: "2.0.0", side: "BOTH")
        let http = try LocalHTTPServer(root: downloads)
        try http.start()
        defer { http.stop() }

        let database = root.appendingPathComponent("priority-updates.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions(
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR,
          loader_version VARCHAR,
          server_name VARCHAR,
          server_address VARCHAR,
          server_dir VARCHAR,
          status VARCHAR,
          is_live BOOLEAN,
          sort_order INTEGER,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions(
          minecraft_version, loader, loader_version, server_name, server_address,
          server_dir, status, is_live, sort_order
        ) VALUES (
          '26.1.2', 'neoforge', '26.1.2.76', 'Pummelchen Server 26.1.2',
          '127.0.0.1:25565', \(sqlLiteral(serverDir.path)), 'live', true, 10
        );
        CREATE TABLE core.mods(
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR,
          name VARCHAR,
          category VARCHAR,
          active_status VARCHAR,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mods VALUES
          (1, 'priority-plane', 'Priority Plane', 'Player Transport', 'Admin Locked', 'Priority release target', 'Server & Client', 'https://example.test/priority-plane', now(), '26.1.2', 'neoforge', '26.1.2.76'),
          (2, 'regular-mod', 'Regular Mod', 'Gameplay', 'ok', 'Installed', 'Server & Client', 'https://example.test/regular-mod', now(), '26.1.2', 'neoforge', '26.1.2.76');
        CREATE TABLE core.mod_sources(
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR,
          display_name VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR,
          source_url VARCHAR,
          priority INTEGER,
          active BOOLEAN,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, minecraft_version, loader, loader_version
        ) VALUES
          ('priority_source', 'priority-plane', 'Priority Plane', 'priority-plane-1.0.0.jar', '1.0.0', 'curseforge', 'https://example.test/priority-plane', 1, true, '26.1.2', 'neoforge', '26.1.2.76'),
          ('regular_source', 'regular-mod', 'Regular Mod', 'regular-mod-1.0.0.jar', '1.0.0', 'curseforge', 'https://example.test/regular-mod', 100, true, '26.1.2', 'neoforge', '26.1.2.76');
        CREATE TABLE core.mod_update_scans(
          scan_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP,
          finished_at TIMESTAMP,
          status VARCHAR,
          urls_checked INTEGER,
          candidates_found INTEGER,
          unresolved INTEGER,
          notes VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_update_scans VALUES (
          'scan_priority', TIMESTAMP '2026-06-19 12:00:00', TIMESTAMP '2026-06-19 12:00:10',
          'completed', 2, 2, 0, 'test', '26.1.2', 'neoforge', '26.1.2.76'
        );
        CREATE TABLE core.mod_update_scan_results(
          result_id VARCHAR PRIMARY KEY,
          scan_id VARCHAR,
          source_id VARCHAR,
          checked_at TIMESTAMP,
          provider VARCHAR,
          source_url VARCHAR,
          status VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          details VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_update_scan_results VALUES
          ('priority_result', 'scan_priority', 'priority_source', now(), 'curseforge', 'https://example.test/priority-plane', 'update_available', 'priority-plane-1.0.0.jar', '1.0.0', '2.0.0', 'http://127.0.0.1:\(http.port)/priority-plane-2.0.0.jar', 'priority candidate', '26.1.2', 'neoforge', '26.1.2.76'),
          ('regular_result', 'scan_priority', 'regular_source', now(), 'curseforge', 'https://example.test/regular-mod', 'update_available', 'regular-mod-1.0.0.jar', '1.0.0', '2.0.0', 'http://127.0.0.1:1/regular-mod-2.0.0.jar', 'non-priority candidate with broken URL', '26.1.2', 'neoforge', '26.1.2.76');
        """)

        let result = try ModUpdateApplyPipeline(config: ModUpdateApplyPipelineConfig(
            projectRoot: root,
            releaseRoot: root.appendingPathComponent("releases", isDirectory: true),
            publicDownloads: root.appendingPathComponent("site/public/downloads", isDirectory: true),
            databaseURL: database,
            minecraftVersion: "26.1.2",
            releaseIDPrefix: "release_20260619_V103_priority_mod_updates",
            activateLiveVersions: true,
            dryRun: false
        )).run()

        #expect(result.versions.first?.status == "active")
        #expect(result.versions.first?.appliedUpdates.map(\.newFile) == ["priority-plane-2.0.0.jar"])
        #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/priority-plane-2.0.0.jar").path))
        #expect(FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/regular-mod-1.0.0.jar").path))
        #expect(!FileManager.default.fileExists(atPath: serverDir.appendingPathComponent("mods/regular-mod-2.0.0.jar").path))
    }

    @Test("mod update apply blocks incomplete staging packages")
    func modUpdateApplyBlocksIncompleteStagingPackage() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-mod-update-block-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let serverDir = root.appendingPathComponent("minecraft-26.2", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDir, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("updates.duckdb")
        try DuckDBDatabase(databaseURL: database).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE core.minecraft_server_versions(
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR,
          loader_version VARCHAR,
          server_name VARCHAR,
          server_address VARCHAR,
          server_dir VARCHAR,
          status VARCHAR,
          is_live BOOLEAN,
          sort_order INTEGER,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          notes VARCHAR
        );
        INSERT INTO core.minecraft_server_versions VALUES (
          '26.2', 'neoforge', '26.2.0.3-beta', 'Pummelchen Server 26.2',
          '127.0.0.1:25566', \(sqlLiteral(serverDir.path)), 'staging',
          false, 20, now(), now(), 'test'
        );
        CREATE TABLE core.mods(
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR,
          name VARCHAR,
          category VARCHAR,
          active_status VARCHAR,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mods VALUES (
          1, 'dependency', 'Dependency', 'Dependency', 'ok', 'Installed',
          'Server & Client', 'https://www.curseforge.com/minecraft/mc-mods/dependency',
          now(), '26.2', 'neoforge', '26.2.0.3-beta'
        );
        CREATE TABLE core.mod_sources(
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR,
          display_name VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR,
          source_url VARCHAR,
          priority INTEGER,
          active BOOLEAN,
          created_at TIMESTAMP DEFAULT now(),
          updated_at TIMESTAMP DEFAULT now(),
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_sources(
          source_id, mod_key, display_name, installed_file, installed_version,
          provider, source_url, priority, active, minecraft_version, loader, loader_version
        ) VALUES (
          'curseforge_dep_mc_26_2', 'dependency', 'Dependency', 'dependency-old.jar',
          '1.0.0', 'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/dependency',
          100, true, '26.2', 'neoforge', '26.2.0.3-beta'
        );
        CREATE TABLE core.mod_update_scans(
          scan_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP,
          finished_at TIMESTAMP,
          status VARCHAR,
          urls_checked INTEGER,
          candidates_found INTEGER,
          unresolved INTEGER,
          notes VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_update_scans VALUES (
          'scan_262', now(), now(), 'completed', 1, 1, 0, 'test',
          '26.2', 'neoforge', '26.2.0.3-beta'
        );
        CREATE TABLE core.mod_update_scan_results(
          result_id VARCHAR PRIMARY KEY,
          scan_id VARCHAR,
          source_id VARCHAR,
          checked_at TIMESTAMP,
          provider VARCHAR,
          source_url VARCHAR,
          status VARCHAR,
          installed_file VARCHAR,
          installed_version VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          details VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT INTO core.mod_update_scan_results VALUES (
          'result_262', 'scan_262', 'curseforge_dep_mc_26_2', now(),
          'curseforge', 'https://www.curseforge.com/minecraft/mc-mods/dependency',
          'update_available', 'dependency-old.jar', '1.0.0', '2.0.0',
          'http://127.0.0.1:1/dependency.jar', 'test', '26.2',
          'neoforge', '26.2.0.3-beta'
        );
        """)

        let result = try ModUpdateApplyPipeline(config: ModUpdateApplyPipelineConfig(
            projectRoot: root,
            releaseRoot: root.appendingPathComponent("releases", isDirectory: true),
            publicDownloads: root.appendingPathComponent("site/public/downloads", isDirectory: true),
            databaseURL: database,
            minecraftVersion: "26.2",
            releaseIDPrefix: "release_20260619_V102_mod_updates",
            dryRun: false
        )).run()

        #expect(result.versions.first?.status == "blocked")
        #expect(result.versions.first?.releaseID == nil)
        #expect(result.versions.first?.skippedReason?.contains("mods directory") == true)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("releases").path))
    }

    @Test("mod update scanner detects provider pages and Cloudflare blocks")
    func modUpdateScannerParsesSources() throws {
        let modrinthHTML = #"""
        <html><head><title>BetterF3 - Minecraft Mod</title></head>
        <script>{"version_number":"18.0.3","loaders":["neoforge"]}</script></html>
        """#
        let cloudflareHTML = #"<html><head><title>Just a moment...</title></head><script src="https://challenges.cloudflare.com/x"></script></html>"#
        let neoForgeMetadata = #"""
        <metadata><versioning><versions>
          <version>26.2.0.1-beta</version>
          <version>26.2.0.3-beta</version>
          <version>26.2.0.6-beta</version>
          <version>26.1.2.76</version>
        </versions></versioning></metadata>
        """#

        #expect(ModUpdateScanner.provider(for: "https://modrinth.com/mod/betterf3") == "modrinth")
        #expect(ModUpdateScanner.provider(for: "https://www.curseforge.com/minecraft/mc-mods/betterf3") == "curseforge")
        #expect(ModUpdateScanner.provider(for: "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml") == "neoforge")
        #expect(ModUpdateScanner.latestNeoForgeVersion(fromMetadata: neoForgeMetadata, minecraftVersion: "26.2") == "26.2.0.6-beta")
        #expect(ModUpdateScanner.neoForgeInstallerURL(version: "26.2.0.6-beta") == "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.2.0.6-beta/neoforge-26.2.0.6-beta-installer.jar")
        #expect(ModUpdateScanner.modrinthSlug(from: URL(string: "https://modrinth.com/shader/bsl-shaders")!) == "bsl-shaders")
        #expect(ModUpdateScanner.modrinthSlug(from: URL(string: "https://modrinth.com/datapack/ketkets-furnicraft/changelog?l=neoforge")!) == "ketkets-furnicraft")
        #expect(ModUpdateScanner.curseForgeSlug(from: URL(string: "https://www.curseforge.com/minecraft/mc-mods/betterf3")!) == "betterf3")
        #expect(ModUpdateScanner.curseForgeSlug(from: URL(string: "https://www.curseforge.com/minecraft/texture-packs/modernarch/files/all")!) == "modernarch")
        #expect(ModUpdateScanner.curseForgeSlug(from: URL(string: "https://www.curseforge.com/minecraft/data-packs/ruined-brick-cities/files/all?page=1&pageSize=20")!) == "ruined-brick-cities")
        #expect(ModUpdateScanner.curseForgeProjectID(fromSourceID: "curseforge_1573986_8241269") == 1573986)
        #expect(ModUpdateScanner.bestCurseForgeFile(
            from: [
                ["fileName": "maplespigcollection-fabric-26.1.2-1.0.jar", "gameVersions": ["Fabric", "26.1.2"]],
                ["fileName": "maplespigcollection-neoforge-26.1.2-1.0.jar", "gameVersions": ["NeoForge", "26.1.2"]]
            ],
            loader: "neoforge",
            minecraftVersion: "26.1.2"
        )?["fileName"] as? String == "maplespigcollection-neoforge-26.1.2-1.0.jar")
        #expect(ModUpdateScanner.bestCurseForgeFile(
            from: [
                ["fileName": "old-neoforge-26.1.2.jar", "gameVersions": ["NeoForge", "26.1.2"]],
                ["fileName": "fabric-26.2.jar", "gameVersions": ["Fabric", "26.2"]]
            ],
            loader: "neoforge",
            minecraftVersion: "26.2"
        ) == nil)
        #expect(ModUpdateScanner.bestCurseForgeFile(
            from: [
                ["fileName": "resourcepack-26.2.zip", "gameVersions": ["26.2"]],
                ["fileName": "resourcepack-26.1.2.zip", "gameVersions": ["26.1.2"]]
            ],
            loader: nil,
            minecraftVersion: "26.2"
        )?["fileName"] as? String == "resourcepack-26.2.zip")
        #expect(ModUpdateScanner.curseForgeVersion(
            fileName: "low_latency-neoforge-26.1.2-1.0.5.jar",
            installedFile: "low_latency-neoforge-26.1.2-1.0.5.jar",
            installedVersion: "1.0.5"
        ) == "1.0.5")
        #expect(ModUpdateScanner.parseLatestVersion(fromHTML: modrinthHTML, provider: "modrinth") == "18.0.3")
        #expect(ModUpdateScanner.parseLatestVersion(fromHTML: "<title>BetterF3 - Minecraft Mods - CurseForge</title>", provider: "curseforge") == nil)
        #expect(ModUpdateScanner.isCloudflareChallenge(cloudflareHTML))

        let modrinthSearch = Data(#"{"hits":[{"title":"BetterF3","slug":"betterf3","project_type":"mod"},{"title":"BSL Shaders","slug":"bsl-shaders","project_type":"shader"}]}"#.utf8)
        #expect(ModUpdateScanner.modrinthSourceURLs(fromSearchData: modrinthSearch) == [
            "https://modrinth.com/mod/betterf3",
            "https://modrinth.com/shader/bsl-shaders"
        ])

        let curseForgeSearch = Data(#"{"data":[{"name":"BetterF3","slug":"betterf3","links":{"websiteUrl":"https://www.curseforge.com/minecraft/mc-mods/betterf3/files"}},{"name":"Noise","slug":"not-minecraft","links":{"websiteUrl":"https://example.com/not-allowed"}}]}"#.utf8)
        #expect(ModUpdateScanner.curseForgeSourceURLs(fromSearchData: curseForgeSearch) == [
            "https://www.curseforge.com/minecraft/mc-mods/betterf3"
        ])

        let modrinthSiteHTML = #"<a href="/mod/betterf3">BetterF3</a><a href="https://modrinth.com/shader/bsl-shaders?x=1">BSL</a>"#
        #expect(Set(ModUpdateScanner.sourceLinkURLs(fromHTML: modrinthSiteHTML, provider: "modrinth")) == Set([
            "https://modrinth.com/mod/betterf3",
            "https://modrinth.com/shader/bsl-shaders"
        ]))

        let googleHTML = #"""
        <a href="/url?q=https%3A%2F%2Fmodrinth.com%2Fmod%2Fbetterf3&amp;sa=U">BetterF3</a>
        <a href="/url?q=https%3A%2F%2Fexample.com%2Fnot-a-mod&amp;sa=U">Bad</a>
        <a href="https://www.curseforge.com/minecraft/mc-mods/betterf3">CurseForge BetterF3</a>
        """#
        #expect(ModUpdateScanner.sourceLinkURLs(fromGoogleHTML: googleHTML, provider: "modrinth") == [
            "https://modrinth.com/mod/betterf3"
        ])
        #expect(ModUpdateScanner.sourceLinkURLs(fromGoogleHTML: googleHTML, provider: "curseforge") == [
            "https://www.curseforge.com/minecraft/mc-mods/betterf3"
        ])
    }

    @Test("mod update scanner seeds release manifest rows into DuckDB")
    func modUpdateScannerSeedsReleaseManifestRows() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-mod-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("site/public/downloads", isDirectory: true)
        let manifests = downloads.appendingPathComponent("releases/release_manifest_seed/manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        try """
        {"release_id":"release_manifest_seed","minecraft_version":"26.1.2"}
        """.write(to: downloads.appendingPathComponent("current-release.json"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        server_mod\tmods/BetterF3-18.0.2-NeoForge-26.1.jar\t10\tsha256:1111111111111111111111111111111111111111111111111111111111111111
        """.write(to: manifests.appendingPathComponent("server-files.tsv"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        client_mods\tmods/Iris-1.10.9.jar\t10\tsha256:2222222222222222222222222222222222222222222222222222222222222222
        """.write(to: manifests.appendingPathComponent("client-package.tsv"), atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("scanner.duckdb")
        let scanner = ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: root,
            databaseURL: database,
            maxURLsPerWindow: 5,
            windowSeconds: 0,
            limit: 0,
            seedFromProjectData: true
        ))
        let summary = try scanner.run()

        #expect(summary.seededSources == 2)
        #expect(summary.sourcesChecked == 0)
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources;") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_source_links;") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources WHERE provider = 'manifest';") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_source_links WHERE provider = 'manifest';") == "2")
    }

    @Test("mod update scanner keeps source rows separate by Minecraft version")
    func modUpdateScannerKeepsSourceRowsSeparateByMinecraftVersion() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-mod-scan-versions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("site/public/downloads", isDirectory: true)
        let manifests = downloads.appendingPathComponent("releases/release_manifest_versions/manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        try """
        {"release_id":"release_manifest_versions"}
        """.write(to: downloads.appendingPathComponent("current-release.json"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        server_mod\tmods/BetterF3-18.0.2-NeoForge-26.1.jar\t10\tsha256:1111111111111111111111111111111111111111111111111111111111111111
        """.write(to: manifests.appendingPathComponent("server-files.tsv"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        """.write(to: manifests.appendingPathComponent("client-package.tsv"), atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("scanner.duckdb")
        _ = try ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: root,
            databaseURL: database,
            minecraftVersion: "26.1.2",
            loaderVersion: "26.1.2.76",
            windowSeconds: 0,
            limit: 0,
            seedFromProjectData: true
        )).run()
        _ = try ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: root,
            databaseURL: database,
            minecraftVersion: "26.2",
            loaderVersion: "26.2.0.3-beta",
            windowSeconds: 0,
            limit: 0,
            seedFromProjectData: true
        )).run()

        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources;") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_source_links;") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources WHERE minecraft_version = '26.1.2';") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources WHERE minecraft_version = '26.2';") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources WHERE source_id LIKE '%_mc_26_2';") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_source_links WHERE minecraft_version = '26.2';") == "1")
    }

    @Test("mod update scanner does not duplicate release manifest entries")
    func modUpdateScannerDoesNotDuplicateReleaseManifestEntries() throws {
        try requireDuckDB()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-mod-scan-batch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("site/public/downloads", isDirectory: true)
        let manifests = downloads.appendingPathComponent("releases/release_manifest_duplicates/manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        try """
        {"release_id":"release_manifest_duplicates","minecraft_version":"26.1.2"}
        """.write(to: downloads.appendingPathComponent("current-release.json"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        server_mod\tmods/adchimneys-26.1.0.0.jar\t10\tsha256:1111111111111111111111111111111111111111111111111111111111111111
        server_mod\tmods/adchimneys-26.1.0.0.jar\t10\tsha256:1111111111111111111111111111111111111111111111111111111111111111
        """.write(to: manifests.appendingPathComponent("server-files.tsv"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        """.write(to: manifests.appendingPathComponent("client-package.tsv"), atomically: true, encoding: .utf8)

        let database = root.appendingPathComponent("scanner.duckdb")
        let scanner = ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: root,
            databaseURL: database,
            windowSeconds: 0,
            limit: 0,
            seedFromProjectData: true
        ))
        let summary = try scanner.run()

        #expect(summary.seededSources == 1)
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM core.mod_sources;") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COALESCE(installed_file, '') FROM core.mod_sources;") == "adchimneys-26.1.0.0.jar")
    }

    @Test("phase 8 control events use safe payloads over nginx HTTPS")
    func phase8ControlEventsUseNginxHTTPSAndRejectDownloads() async throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase8-token")
        let clientID = "client-phase8-a"
        let headers = authHeaders(token: "phase8-token", clientID: clientID)
        let encoder = JSONEncoder()

        let infoResponse = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/control/info"))
        let info = try JSONDecoder().decode(ControlChannelInfo.self, from: infoResponse.body)
        #expect(info.transportTarget == "nginx_https_poll")
        #expect(info.endpoint == "/api/v1/control/events")
        #expect(info.bidirectional)
        #expect(!info.downloadsAllowed)
        #expect(info.fallbackEndpoint.isEmpty)
        #expect(info.supportedEvents.contains("release_available"))
        #expect(info.supportedEvents.contains("sync_required"))
        #expect(info.supportedEvents.contains("defaults_changed"))

        let eventRequest = ControlEventCreateRequest(
            eventType: .releaseAvailable,
            targetClientID: clientID,
            releaseID: "release_20260613_V88_phase8",
            priority: "high",
            title: "Release available",
            message: "A new Pummelchen release is ready.",
            payload: ["action": "sync"]
        )
        let create = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/control/events",
            headers: headers,
            body: try encoder.encode(eventRequest)
        ))
        #expect(create.statusCode == 201)
        let event = try JSONDecoder().decode(ControlEvent.self, from: create.body)

        let fetch = api.response(for: HTTPRequest(
            method: "GET",
            path: "/api/v1/control/events?client_id=\(clientID)",
            headers: headers
        ))
        let batch = try JSONDecoder().decode(ControlEventBatch.self, from: fetch.body)
        #expect(batch.events.map(\.eventID) == [event.eventID])
        #expect(batch.transport == "authenticated_https_operator_poll")

        let secondCreate = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/control/events",
            headers: headers,
            body: try encoder.encode(ControlEventCreateRequest(
                eventType: .healthUpdate,
                targetClientID: clientID,
                releaseID: nil,
                priority: "normal",
                title: "Health update",
                message: "Server health changed.",
                payload: ["status": "watch"]
            ))
        ))
        let secondEvent = try JSONDecoder().decode(ControlEvent.self, from: secondCreate.body)
        let afterFirst = api.response(for: HTTPRequest(
            method: "GET",
            path: "/api/v1/control/events?client_id=\(clientID)&after_event_id=\(event.eventID)",
            headers: headers
        ))
        let afterFirstBatch = try JSONDecoder().decode(ControlEventBatch.self, from: afterFirst.body)
        #expect(afterFirstBatch.events.map(\.eventID).contains(secondEvent.eventID))

        let ack = ControlEventAck(clientID: clientID, eventID: event.eventID, receivedAt: "2026-06-13T00:00:00+00:00")
        #expect(api.response(for: HTTPRequest(method: "POST", path: "/api/v1/control/acks", headers: headers, body: try encoder.encode(ack))).statusCode == 200)
        let secondAck = ControlEventAck(clientID: clientID, eventID: secondEvent.eventID, receivedAt: "2026-06-13T00:00:01+00:00")
        #expect(api.response(for: HTTPRequest(method: "POST", path: "/api/v1/control/acks", headers: headers, body: try encoder.encode(secondAck))).statusCode == 200)
        let afterAck = api.response(for: HTTPRequest(
            method: "GET",
            path: "/api/v1/control/events?client_id=\(clientID)&wait_seconds=1",
            headers: headers
        ))
        let empty = try JSONDecoder().decode(ControlEventBatch.self, from: afterAck.body)
        #expect(empty.events.isEmpty)
        #expect(empty.transport == "authenticated_https_operator_poll")

        let downloadPayload = ControlEventCreateRequest(
            eventType: .clientSyncRequested,
            targetClientID: clientID,
            releaseID: nil,
            priority: "normal",
            title: "Bad payload",
            message: "This should be rejected.",
            payload: ["download_url": "/downloads/releases/x/client.zip"]
        )
        #expect(api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/control/events",
            headers: headers,
            body: try encoder.encode(downloadPayload)
        )).statusCode == 400)
    }

    @Test("phase 8 compatibility event API can deliver update events fast")
    func phase8CompatibilityEventAPIDeliversUpdateEventsFast() async throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase8-token")
        let clientID = "client-phase8-latency"
        let headers = authHeaders(token: "phase8-token", clientID: clientID)

        let server = APIRouterHTTPServer(api: api)
        try server.start()
        defer { server.stop() }

        let client = ClientControlChannel(configuration: ClientControlChannelConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            clientID: clientID,
            clientAPIToken: "phase8-token"
        ))

        let create = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/control/events",
            headers: headers,
            body: try JSONEncoder().encode(ControlEventCreateRequest(
                eventType: .syncRequired,
                targetClientID: clientID,
                releaseID: "release_20260613_V99_latency",
                priority: "high",
                title: "Sync required",
                message: "Client should sync now.",
                payload: ["reason": "latency_test"]
            ))
        ))
        #expect(create.statusCode == 201)

        let started = Date()
        let batch = try await client.fetchEvents(limit: 10, waitSeconds: 5)
        let elapsed = Date().timeIntervalSince(started)
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.eventType == .syncRequired)
        #expect(batch.transport == "authenticated_https_operator_poll")
        #expect(elapsed < 4.5)
    }

    @Test("phase 8 broadcast release events remain pending per client")
    func phase8BroadcastReleaseEventsRemainPendingPerClient() throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase8-token")
        let clientA = "client-broadcast-a"
        let clientB = "client-broadcast-b"
        let headersA = authHeaders(token: "phase8-token", clientID: clientA)
        let headersB = authHeaders(token: "phase8-token", clientID: clientB)
        let eventRequest = ControlEventCreateRequest(
            eventType: .releaseAvailable,
            targetClientID: nil,
            releaseID: "release_20260619_V41_mod_updates_mc_26_1_2",
            priority: "critical",
            title: "Client app update required",
            message: "Sync now and self-update if needed.",
            payload: ["action": "sync", "reason": "test_broadcast"]
        )
        let create = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/control/events",
            headers: headersA,
            body: try JSONEncoder().encode(eventRequest)
        ))
        #expect(create.statusCode == 201)
        let event = try JSONDecoder().decode(ControlEvent.self, from: create.body)
        #expect(event.targetClientID == nil)

        let fetchA = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/control/events?client_id=\(clientA)", headers: headersA))
        let batchA = try JSONDecoder().decode(ControlEventBatch.self, from: fetchA.body)
        #expect(batchA.events.map(\.eventID) == [event.eventID])

        let ackA = ControlEventAck(clientID: clientA, eventID: event.eventID, receivedAt: "2026-06-19T00:00:00+00:00")
        #expect(api.response(for: HTTPRequest(method: "POST", path: "/api/v1/control/acks", headers: headersA, body: try JSONEncoder().encode(ackA))).statusCode == 200)

        let afterAckA = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/control/events?client_id=\(clientA)", headers: headersA))
        #expect(try JSONDecoder().decode(ControlEventBatch.self, from: afterAckA.body).events.isEmpty)

        let fetchB = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/control/events?client_id=\(clientB)", headers: headersB))
        let batchB = try JSONDecoder().decode(ControlEventBatch.self, from: fetchB.body)
        #expect(batchB.events.map(\.eventID) == [event.eventID])
    }

    @Test("phase 8 client fetches and acknowledges control events over nginx HTTPS")
    func phase8ClientUsesNginxHTTPSControlChannel() async throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase8-token")
        let clientID = "client-phase8-b"
        let headers = authHeaders(token: "phase8-token", clientID: clientID)
        let eventRequest = ControlEventCreateRequest(
            eventType: .serverRestartNotice,
            targetClientID: clientID,
            releaseID: nil,
            priority: "critical",
            title: "Restart notice",
            message: "Server restart soon.",
            payload: ["seconds": "120"]
        )
        _ = api.response(for: HTTPRequest(
            method: "POST",
            path: "/api/v1/control/events",
            headers: headers,
            body: try JSONEncoder().encode(eventRequest)
        ))

        let server = APIRouterHTTPServer(api: api)
        try server.start()
        defer { server.stop() }

        let client = ClientControlChannel(configuration: ClientControlChannelConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            clientID: clientID,
            clientAPIToken: "phase8-token"
        ))
        let batch = try await client.fetchEvents(limit: 10)
        #expect(batch.events.count == 1)
        #expect(batch.events.first?.eventType == .serverRestartNotice)
        #expect(batch.transport == "authenticated_https_operator_poll")

        let event = try #require(batch.events.first)
        try await client.acknowledge(event)
        let afterAck = try await client.fetchEvents(limit: 10)
        #expect(afterAck.events.isEmpty)
    }

    @Test("phase 9 safe world reset dry run records plan without deleting active world")
    func phase9WorldResetDryRunRecordsPlan() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
            projectRoot: fixture.root,
            serverDir: fixture.serverDir,
            databaseURL: fixture.root.appendingPathComponent("phase9.duckdb"),
            seed: "123456789",
            radiusBlocks: 1000,
            dryRun: true
        ))
        let result = try pipeline.run()

        #expect(result.status == "dry_run")
        #expect(result.pregenerationChunks > 12_000)
        #expect(result.requiredDatapacksVerified.sorted() == [
            "pummelchen-rich-ores.zip",
            "pummelchen-tropical-worldgen.zip",
            "pummelchen-welcome.zip"
        ])
        #expect(FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/region/r.0.0.mca").path))
        let status = try duckDBScalar(database: fixture.root.appendingPathComponent("phase9.duckdb"), sql: "SELECT status FROM world.reset_jobs WHERE job_id = '\(result.jobID)';")
        #expect(status == "dry_run")
    }

    @Test("rich ores datapack sets every managed vanilla ore vein size to 64")
    func richOresDatapackSetsEveryManagedVanillaOreVeinSizeTo64() throws {
        let datapack = actualServerDatapackURL(named: "pummelchen-rich-ores.zip")
        let expectedEntries = datapackFixturePaths(for: "pummelchen-rich-ores.zip")
        #expect(expectedEntries.count == 20)

        for entry in expectedEntries {
            let data = try unzipEntry(entry, from: datapack)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let config = try #require(object["config"] as? [String: Any])
            let size = try #require(config["size"] as? Int)
            #expect(size == 64, "Expected \(entry) to use max ore vein size 64")
        }
    }

    @Test("phase 9 safe world reset requires explicit destructive confirmation")
    func phase9WorldResetRequiresConfirmation() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
            projectRoot: fixture.root,
            serverDir: fixture.serverDir,
            databaseURL: fixture.root.appendingPathComponent("phase9.duckdb"),
            serviceName: "pummelchen-minecraft.service",
            seed: "987654321",
            radiusBlocks: 1000,
            dryRun: false,
            confirmDestructive: false
        ))
        #expect(throws: SwiftWorldResetError.self) {
            _ = try pipeline.run()
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("phase9.duckdb").path))
    }

    @Test("phase 9 safe world reset requires RCON for destructive execution")
    func phase9WorldResetRequiresRCONBeforeDestructiveWork() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try withMockSystemctl(root: fixture.root) {
            let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
                projectRoot: fixture.root,
                serverDir: fixture.serverDir,
                databaseURL: fixture.root.appendingPathComponent("phase9.duckdb"),
                serviceName: "pummelchen-minecraft.service",
                seed: "987654321",
                radiusBlocks: 1000,
                dryRun: false,
                confirmDestructive: true,
            ))
            #expect(throws: SwiftWorldResetError.self) {
                _ = try pipeline.run()
            }
            #expect(FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/region/r.0.0.mca").path))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("phase9.duckdb").path))
        }
    }

    @Test("phase 9 safe world reset rejects unsafe world names before planning")
    func phase9WorldResetRejectsUnsafeWorldNames() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try "level-name=..\\\\outside\n".write(to: fixture.serverDir.appendingPathComponent("server.properties"), atomically: true, encoding: .utf8)
        let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
            projectRoot: fixture.root,
            serverDir: fixture.serverDir,
            databaseURL: fixture.root.appendingPathComponent("phase9.duckdb"),
            seed: "987654321",
            radiusBlocks: 1000,
            dryRun: true
        ))

        #expect(throws: SwiftWorldResetError.self) {
            _ = try pipeline.run()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/region/r.0.0.mca").path))
    }

    @Test("phase 9 safe world reset requires operational RCON endpoint")
    func phase9WorldResetExecutesStagedFilesystemReset() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try withMockSystemctl(root: fixture.root) {
            let database = fixture.root.appendingPathComponent("phase9.duckdb")
            let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
                projectRoot: fixture.root,
                serverDir: fixture.serverDir,
                databaseURL: database,
                serviceName: "pummelchen-minecraft.service",
                seed: "178127232016679900",
                radiusBlocks: 1000,
                dryRun: false,
                confirmDestructive: true,
                deleteBackupAfterSuccess: true,
                rconPassword: "test-rcon-password",
                rconReadyTimeoutSeconds: 1
            ))
            #expect(throws: SwiftWorldResetError.self) {
                _ = try pipeline.run()
            }
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("phase9.duckdb").path))
        }
    }

    private func makeProjectFixture() throws -> (root: URL, currentReleaseJSON: String, manifestTSV: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPummelchenModServer-\(UUID().uuidString)", isDirectory: true)
        let releaseID = "release_20260612_V6_modernarch-refresh"
        let downloads = root.appendingPathComponent("site/public/downloads", isDirectory: true)
        let releaseDir = downloads.appendingPathComponent("releases/\(releaseID)", isDirectory: true)
        let manifestsDir = releaseDir.appendingPathComponent("manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestsDir, withIntermediateDirectories: true)

        let currentURL = try #require(Bundle.module.url(forResource: "current-release", withExtension: "json", subdirectory: "Fixtures"))
        let manifestURL = try #require(Bundle.module.url(forResource: "client-sync-manifest", withExtension: "tsv", subdirectory: "Fixtures"))
        let current = try String(contentsOf: currentURL, encoding: .utf8)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        try current.write(to: downloads.appendingPathComponent("current-release.json"), atomically: true, encoding: .utf8)
        try manifest.write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        server_mod\tmods/server-26.1.2.jar\t10\tsha256:1111111111111111111111111111111111111111111111111111111111111111
        server_mod\tmods/shared.jar\t10\tsha256:2222222222222222222222222222222222222222222222222222222222222222
        """.write(to: manifestsDir.appendingPathComponent("server-files.tsv"), atomically: true, encoding: .utf8)
        try """
        # role\trelative_path\tsize\tsha256
        client_mod\tmods/example-mod.jar\t10\tsha256:3333333333333333333333333333333333333333333333333333333333333333
        resourcepack\tresourcepacks/ModernArch v2.8.2 [26.1] [128x].zip\t10\tsha256:4444444444444444444444444444444444444444444444444444444444444444
        shaderpack\tshaderpacks/BSL_v10.0.zip\t10\tsha256:5555555555555555555555555555555555555555555555555555555555555555
        """.write(to: manifestsDir.appendingPathComponent("client-package.tsv"), atomically: true, encoding: .utf8)
        try Data().write(to: downloads.appendingPathComponent("MCPummelchenModClient.dmg"))
        return (root, current, manifest)
    }

    private func withMockSystemctl<T>(root: URL, _ operation: () throws -> T) throws -> T {
        Self.environmentMutationLock.lock()
        defer { Self.environmentMutationLock.unlock() }

        let mock = root.appendingPathComponent(".mock-systemctl")
        let script = "#!/bin/sh\n" +
            "case \"$1\" in\n" +
            "  is-enabled)\n" +
            "    echo enabled\n" +
            "    ;;\n" +
            "  is-active)\n" +
            "    echo active\n" +
            "    ;;\n" +
            "  *)\n" +
            "    ;;\n" +
            "esac\n"
        try script.data(using: .utf8)!.write(to: mock)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mock.path)

        let previous: String? = {
            guard let env = getenv("PUMMELCHEN_SYSTEMCTL_PATH") else { return nil }
            return String(cString: env)
        }()
        setenv("PUMMELCHEN_SYSTEMCTL_PATH", mock.path, 1)
        defer {
            if let previous {
                setenv("PUMMELCHEN_SYSTEMCTL_PATH", previous, 1)
            } else {
                unsetenv("PUMMELCHEN_SYSTEMCTL_PATH")
            }
        }

        return try operation()
    }

    private func seedLiveSiteAPIDatabase(at databaseURL: URL) throws {
        let database = DuckDBDatabase(databaseURL: databaseURL)
        try database.execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE SCHEMA IF NOT EXISTS release;
        CREATE SCHEMA IF NOT EXISTS reporting;

        CREATE TABLE IF NOT EXISTS core.minecraft_server_versions (
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR NOT NULL,
          loader_version VARCHAR NOT NULL,
          server_name VARCHAR NOT NULL,
          server_address VARCHAR NOT NULL,
          server_dir VARCHAR,
          status VARCHAR NOT NULL,
          is_live BOOLEAN NOT NULL,
          sort_order INTEGER NOT NULL,
          updated_at TIMESTAMP NOT NULL,
          notes VARCHAR
        );
        INSERT OR REPLACE INTO core.minecraft_server_versions VALUES (
          '26.1.2',
          'neoforge',
          '26.1.2.76',
          'Pummelchen Server 26.1.2',
          '91.99.176.243:25565',
          '/tmp/minecraft',
          'live',
          true,
          10,
          TIMESTAMP '2026-06-12 17:04:13',
          'fixture'
        );
        CREATE OR REPLACE VIEW reporting.v_minecraft_server_versions AS
        SELECT
          minecraft_version, loader, loader_version, server_name, server_address,
          server_dir, status, is_live, sort_order, updated_at, notes
        FROM core.minecraft_server_versions;

        CREATE TABLE IF NOT EXISTS release.release_events (
          event_id VARCHAR PRIMARY KEY,
          release_id VARCHAR,
          event_at TIMESTAMP NOT NULL,
          event_type VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          actor VARCHAR,
          notes VARCHAR
        );
        INSERT OR REPLACE INTO release.release_events VALUES (
          'fixture-event-1',
          'release_20260612_V6_modernarch-refresh',
          TIMESTAMP '2026-06-12 17:04:13',
          'health',
          'ok',
          'test',
          'Fixture update check passed'
        );

        CREATE TABLE IF NOT EXISTS core.mod_update_scans (
          scan_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP NOT NULL,
          finished_at TIMESTAMP,
          status VARCHAR NOT NULL,
          urls_checked INTEGER NOT NULL,
          candidates_found INTEGER NOT NULL,
          unresolved INTEGER NOT NULL,
          notes VARCHAR,
          minecraft_version VARCHAR,
          loader VARCHAR,
          loader_version VARCHAR
        );
        INSERT OR REPLACE INTO core.mod_update_scans VALUES (
          'fixture-scan-1',
          TIMESTAMP '2026-06-12 17:02:00',
          TIMESTAMP '2026-06-12 17:03:00',
          'completed',
          2,
          1,
          0,
          'fixture',
          '26.1.2',
          'neoforge',
          '26.1.2.76'
        );

        CREATE TABLE IF NOT EXISTS release.release_health_results (
          result_id VARCHAR PRIMARY KEY,
          release_id VARCHAR NOT NULL,
          checked_at TIMESTAMP NOT NULL,
          status VARCHAR NOT NULL,
          details VARCHAR
        );
        INSERT OR REPLACE INTO release.release_health_results VALUES (
          'fixture-health-1',
          'release_20260612_V6_modernarch-refresh',
          TIMESTAMP '2026-06-12 17:04:30',
          'ok',
          'fixture health passed'
        );
        """)
    }

    private func makeAPI(
        fixture: (root: URL, currentReleaseJSON: String, manifestTSV: String),
        token: String? = nil,
        maxWritePayloadBytes: Int = 256 * 1024
    ) -> MCPummelchenModServerAPI {
        MCPummelchenModServerAPI(config: MCPummelchenModServerConfig(
            projectRoot: fixture.root,
            duckDBURL: fixture.root.appendingPathComponent("data/test-phase6.duckdb"),
            clientAPIToken: token,
            maxWritePayloadBytes: maxWritePayloadBytes
        ))
    }

    private func makeWorldResetFixture() throws -> (root: URL, serverDir: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-world-reset-\(UUID().uuidString)", isDirectory: true)
        let serverDir = root.appendingPathComponent("server", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("world/region", isDirectory: true), withIntermediateDirectories: true)
        try "old region".write(to: serverDir.appendingPathComponent("world/region/r.0.0.mca"), atomically: true, encoding: .utf8)
        try "level-name=world\nlevel-seed=old\nbonus-chest=false\nwhite-list=true\nenforce-whitelist=true\n".write(to: serverDir.appendingPathComponent("server.properties"), atomically: true, encoding: .utf8)
        try copyRequiredDatapacks(to: root.appendingPathComponent("server-datapacks", isDirectory: true))
        return (root, serverDir)
    }

    private func copyRequiredDatapacks(to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for name in ["pummelchen-welcome.zip", "pummelchen-tropical-worldgen.zip", "pummelchen-rich-ores.zip"] {
            let destination = target.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try makeDatapackFixture(named: name, at: destination)
        }
    }

    private func makeDatapackFixture(named name: String, at destination: URL) throws {
        let workDir = destination.deletingLastPathComponent()
            .appendingPathComponent("datapack-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let pack = """
        {
          "pack": {
            "pack_format": 82,
            "description": "\(name) test fixture"
          }
        }
        """
        try pack.write(to: workDir.appendingPathComponent("pack.mcmeta"), atomically: true, encoding: .utf8)
        for relativePath in datapackFixturePaths(for: name) {
            let fileURL = workDir.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{}\n".write(to: fileURL, atomically: true, encoding: .utf8)
        }
        try runZip(arguments: ["-q", "-r", destination.path, "pack.mcmeta"], currentDirectory: workDir)
        if FileManager.default.fileExists(atPath: workDir.appendingPathComponent("TROPICAL_WORLDGEN.md").path) {
            try runZip(arguments: ["-q", "-r", destination.path, "TROPICAL_WORLDGEN.md"], currentDirectory: workDir)
        }
        try runZip(arguments: ["-q", "-r", destination.path, "data"], currentDirectory: workDir)
    }

    private func datapackFixturePaths(for name: String) -> [String] {
        switch name {
        case "pummelchen-welcome.zip":
            [
                "data/pummelchen/function/load.mcfunction",
                "data/pummelchen/function/tick.mcfunction",
                "data/minecraft/loot_table/chests/spawn_bonus_chest.json"
            ]
        case "pummelchen-tropical-worldgen.zip":
            [
                "TROPICAL_WORLDGEN.md",
                "data/pummelchen/worldgen/structure_set/village_cluster_01.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_02.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_03.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_04.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_05.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_06.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_07.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_08.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_09.json",
                "data/pummelchen/worldgen/structure_set/village_cluster_10.json",
                "data/minecraft/worldgen/multi_noise_biome_source_parameter_list/overworld.json"
            ]
        case "pummelchen-rich-ores.zip":
            [
                "data/minecraft/worldgen/configured_feature/ore_ancient_debris_large.json",
                "data/minecraft/worldgen/configured_feature/ore_ancient_debris_small.json",
                "data/minecraft/worldgen/configured_feature/ore_coal.json",
                "data/minecraft/worldgen/configured_feature/ore_coal_buried.json",
                "data/minecraft/worldgen/configured_feature/ore_copper_large.json",
                "data/minecraft/worldgen/configured_feature/ore_copper_small.json",
                "data/minecraft/worldgen/configured_feature/ore_diamond_buried.json",
                "data/minecraft/worldgen/configured_feature/ore_diamond_large.json",
                "data/minecraft/worldgen/configured_feature/ore_diamond_medium.json",
                "data/minecraft/worldgen/configured_feature/ore_diamond_small.json",
                "data/minecraft/worldgen/configured_feature/ore_emerald.json",
                "data/minecraft/worldgen/configured_feature/ore_gold.json",
                "data/minecraft/worldgen/configured_feature/ore_gold_buried.json",
                "data/minecraft/worldgen/configured_feature/ore_iron.json",
                "data/minecraft/worldgen/configured_feature/ore_iron_small.json",
                "data/minecraft/worldgen/configured_feature/ore_lapis.json",
                "data/minecraft/worldgen/configured_feature/ore_lapis_buried.json",
                "data/minecraft/worldgen/configured_feature/ore_nether_gold.json",
                "data/minecraft/worldgen/configured_feature/ore_quartz.json",
                "data/minecraft/worldgen/configured_feature/ore_redstone.json"
            ]
        default:
            []
        }
    }

    private func runZip(arguments: [String], currentDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["zip"] + arguments
        process.currentDirectoryURL = currentDirectory

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "MCPummelchenModServerCoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
    }

    private func unzipEntry(_ entry: String, from archive: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["unzip", "-p", archive.path, entry]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(
                domain: "MCPummelchenModServerCoreTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
        return data
    }

    private func actualServerDatapackURL(named name: String) -> URL {
        let testFile = URL(fileURLWithPath: #filePath)
        let serverApp = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return serverApp.appendingPathComponent("server-datapacks/\(name)")
    }

    private func writeNeoForgeJar(root: URL, fileName: String, displayName: String, version: String, side: String) throws -> URL {
        let work = root.appendingPathComponent("jar-fixture-\(UUID().uuidString)", isDirectory: true)
        let metaInf = work.appendingPathComponent("META-INF", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try """
        modLoader="javafml"
        loaderVersion="[1,)"
        license="All Rights Reserved"
        [[mods]]
        modId="\(displayName.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression))"
        version="\(version)"
        displayName="\(displayName)"
        side="\(side)"
        """.write(to: metaInf.appendingPathComponent("neoforge.mods.toml"), atomically: true, encoding: .utf8)
        let jar = root.appendingPathComponent(fileName)
        try runZip(arguments: ["-q", "-r", jar.path, "META-INF"], currentDirectory: work)
        return jar
    }

    private func authHeaders(token: String, clientID: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "X-Pummelchen-Client-ID": clientID,
            "Content-Type": "application/json"
        ]
    }

    private func requireDuckDB() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-duckdb-required-\(UUID().uuidString).duckdb")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try DuckDBDatabase(databaseURL: url).execute("SELECT 1;")
        } catch {
            throw CancellationError()
        }
    }

    @discardableResult
    private func writeArtifact(name: String, content: String, serverDir: URL) throws -> String {
        let file = serverDir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let hash = try SHA256Hasher.hashFile(at: file)
        try "\(hash)  \(name)\n".write(to: serverDir.appendingPathComponent("\(name).sha256"), atomically: true, encoding: .utf8)
        return hash
    }

    private func writeDMGHeadlessLiveSoakReport(releaseID: String, dmgSHA: String, serverDir: URL) throws {
        try """
        {
          "release_id": "\(releaseID)",
          "dmg_sha256": "\(dmgSHA)",
          "server_address": "91.99.176.243:25565",
          "started_at": "2026-06-13T12:00:00Z",
          "completed_at": "2026-06-13T12:01:05Z",
          "duration_seconds": 65,
          "status": "passed",
          "installed_from_dmg": true,
          "java_ok": true,
          "neoforge_ok": true,
          "sync_ok": true,
          "login_ok": true,
          "stayed_connected": true,
          "crash_report_count": 0,
          "fatal_log_count": 0,
          "renderer_summary": "headless",
          "notes": "test fixture",
          "new_player_setup": {
            "status": "passed",
            "app_bundle_path": "/tmp/MCPummelchenModClient.app",
            "minecraft_directory": "/tmp/minecraft",
            "pummelchen_home": "/tmp/pummelchen",
            "checks": [
              {
                "name": "client_defaults_healthy",
                "status": "passed",
                "details": "fixture"
              }
            ],
            "manifest_entries": 3,
            "verified_managed_files": 3,
            "downloaded_files": 3,
            "defaults_ok": true,
            "server_entry_count": 1,
            "java_executable": "/tmp/pummelchen/java/temurin-25.0.3+9/Contents/Home/bin/java",
            "java_version": "openjdk version \\"25.0.3\\"",
            "neoforge_version": "26.1.2.76",
            "installed_release_id": "\(releaseID)"
          }
        }
        """.write(
            to: serverDir.appendingPathComponent(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeLegacyDMGHeadlessLiveSoakReport(releaseID: String, dmgSHA: String, serverDir: URL) throws {
        try """
        {
          "release_id": "\(releaseID)",
          "dmg_sha256": "\(dmgSHA)",
          "server_address": "91.99.176.243:25565",
          "started_at": "2026-06-13T12:00:00Z",
          "completed_at": "2026-06-13T12:01:05Z",
          "duration_seconds": 65,
          "status": "passed",
          "installed_from_dmg": true,
          "java_ok": true,
          "neoforge_ok": true,
          "sync_ok": true,
          "login_ok": true,
          "stayed_connected": true,
          "crash_report_count": 0,
          "fatal_log_count": 0,
          "renderer_summary": "headless",
          "notes": "legacy fixture"
        }
        """.write(
            to: serverDir.appendingPathComponent(SwiftReleasePipeline.dmgHeadlessLiveSoakReportName),
            atomically: true,
            encoding: .utf8
        )
    }

    private func duckDBScalar(database: URL, sql: String) throws -> String {
        try DuckDBDatabase(databaseURL: database).queryScalar(sql)
    }

    private func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

private func parseTestCSVRows(_ csv: String) -> [[String]] {
    csv.split(separator: "\n").dropFirst().map { line in
        String(line).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}

final class LocalHTTPServer {
    let root: URL
    let port: Int
    private var process: Process?

    init(root: URL) throws {
        self.root = root
        self.port = Int.random(in: 18_000...28_000)
    }

    func start() throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if !process.isRunning {
                throw NSError(
                    domain: "LocalHTTPServer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "python http.server exited before binding 127.0.0.1:\(port)"]
                )
            }
            if Self.isTCPPortOpen(port: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        throw NSError(
            domain: "LocalHTTPServer",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "python http.server did not bind 127.0.0.1:\(port) before timeout"]
        )
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                let killer = Process()
                killer.executableURL = URL(fileURLWithPath: "/bin/kill")
                killer.arguments = ["-9", String(process.processIdentifier)]
                try? killer.run()
                killer.waitUntilExit()
            }
        }
        self.process = nil
    }

    private static func isTCPPortOpen(port: Int) -> Bool {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = Int32(SOCK_STREAM)
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

final class APIRouterHTTPServer: @unchecked Sendable {
    let api: MCPummelchenModServerAPI
    let port: Int
    private var socketFD: Int32 = -1
    private var thread: Thread?
    private var running = false

    init(api: MCPummelchenModServerAPI) {
        self.api = api
        self.port = Int.random(in: 29_000...39_000)
    }

    func start() throws {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = Int32(SOCK_STREAM)
        #endif
        socketFD = socket(AF_INET, stream, 0)
        var enabled: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)
        #expect(listen(socketFD, 16) == 0)
        running = true
        thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread?.start()
        Thread.sleep(forTimeInterval: 0.2)
    }

    func stop() {
        running = false
        if socketFD >= 0 {
            close(socketFD)
        }
    }

    private func acceptLoop() {
        while running {
            let client = accept(socketFD, nil, nil)
            if client < 0 {
                continue
            }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 {
                break
            }
            data.append(contentsOf: buffer.prefix(count))
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }
            let header = String(decoding: data.prefix(upTo: headerEnd.lowerBound), as: UTF8.self)
            let contentLength = header
                .split(separator: "\r\n")
                .dropFirst()
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            if data.count >= headerEnd.upperBound + contentLength {
                break
            }
        }
        let request = parse(data) ?? HTTPRequest(method: "GET", path: "/bad-request")
        let response = api.response(for: request)
        write(response: response, client: client)
    }

    private func parse(_ data: Data) -> HTTPRequest? {
        let text = String(decoding: data, as: UTF8.self)
        let headerText = text.components(separatedBy: "\r\n\r\n").first ?? text
        let lines = headerText.split(separator: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            headers[String(pieces[0])] = String(pieces[1]).trimmingCharacters(in: .whitespaces)
        }
        let marker = Data("\r\n\r\n".utf8)
        let body: Data
        if let range = data.range(of: marker) {
            body = data.subdata(in: range.upperBound..<data.endIndex)
        } else {
            body = Data()
        }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    private func write(response: HTTPResponse, client: Int32) {
        let head = [
            "HTTP/1.1 \(response.statusCode) \(response.statusCode == 200 ? "OK" : "Status")",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        writeAll(Data(head.utf8), client: client)
        writeAll(response.body, client: client)
    }

    private func writeAll(_ data: Data, client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                #if os(Linux)
                let result = Glibc.write(client, base.advanced(by: sent), data.count - sent)
                #else
                let result = Darwin.write(client, base.advanced(by: sent), data.count - sent)
                #endif
                if result <= 0 { break }
                sent += result
            }
        }
    }
}
