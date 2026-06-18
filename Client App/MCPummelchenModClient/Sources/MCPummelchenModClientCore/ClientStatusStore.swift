import Foundation
import MCPummelchenModShared

public struct ClientStatusStore: Sendable {
    public static let schemaVersion = 3
    private static let maxSyncRuns = 500
    private static let maxEndpointChecks = 2_000
    private static let maxManifestAudits = 500

    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func initialize() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
        CREATE TABLE IF NOT EXISTS client_schema_migrations (
          version INTEGER PRIMARY KEY,
          name VARCHAR NOT NULL,
          applied_at TIMESTAMP NOT NULL
        );
        CREATE TABLE IF NOT EXISTS client_state (
          key VARCHAR PRIMARY KEY,
          value VARCHAR NOT NULL,
          updated_at TIMESTAMP NOT NULL
        );
        CREATE TABLE IF NOT EXISTS release_history (
          release_id VARCHAR PRIMARY KEY,
          first_seen_at TIMESTAMP NOT NULL,
          installed_at TIMESTAMP,
          status VARCHAR NOT NULL,
          manifest_sha256 VARCHAR,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS sync_runs (
          run_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP NOT NULL,
          finished_at TIMESTAMP,
          from_release_id VARCHAR,
          target_release_id VARCHAR,
          result VARCHAR NOT NULL,
          files_verified INTEGER,
          files_downloaded INTEGER,
          files_quarantined INTEGER,
          minecraft_version VARCHAR,
          loader_version VARCHAR,
          error_message VARCHAR
        );
        CREATE TABLE IF NOT EXISTS installed_files (
          section VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          path VARCHAR NOT NULL,
          size_bytes BIGINT,
          sha256 VARCHAR,
          release_id VARCHAR,
          minecraft_version VARCHAR,
          loader_version VARCHAR,
          verified_at TIMESTAMP,
          status VARCHAR NOT NULL,
          PRIMARY KEY(section, name)
        );
        CREATE TABLE IF NOT EXISTS installed_files_by_version (
          minecraft_version VARCHAR NOT NULL,
          loader_version VARCHAR,
          section VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          path VARCHAR NOT NULL,
          size_bytes BIGINT,
          sha256 VARCHAR,
          release_id VARCHAR,
          verified_at TIMESTAMP,
          status VARCHAR NOT NULL,
          PRIMARY KEY(minecraft_version, section, name)
        );
        CREATE TABLE IF NOT EXISTS sync_events (
          event_id VARCHAR PRIMARY KEY,
          run_id VARCHAR NOT NULL,
          timestamp TIMESTAMP NOT NULL,
          level VARCHAR NOT NULL,
          message VARCHAR NOT NULL,
          file_name VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client_defaults (
          key VARCHAR PRIMARY KEY,
          desired_value VARCHAR NOT NULL,
          applied_value VARCHAR,
          applied_at TIMESTAMP,
          status VARCHAR NOT NULL,
          source VARCHAR NOT NULL,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS endpoint_status (
          endpoint VARCHAR NOT NULL,
          checked_at TIMESTAMP NOT NULL,
          state VARCHAR NOT NULL,
          latency_ms INTEGER,
          message VARCHAR NOT NULL,
          PRIMARY KEY(endpoint, checked_at)
        );
        CREATE TABLE IF NOT EXISTS manifest_audits (
          audit_id VARCHAR PRIMARY KEY,
          release_id VARCHAR NOT NULL,
          checked_at TIMESTAMP NOT NULL,
          manifest_entries INTEGER NOT NULL,
          files_verified INTEGER NOT NULL,
          files_missing_or_corrupt INTEGER NOT NULL,
          status VARCHAR NOT NULL,
          source VARCHAR NOT NULL,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client_supported_versions (
          minecraft_version VARCHAR PRIMARY KEY,
          loader VARCHAR NOT NULL,
          loader_version VARCHAR NOT NULL,
          server_name VARCHAR NOT NULL,
          server_address VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          is_live BOOLEAN NOT NULL,
          updated_at TIMESTAMP NOT NULL
        );
        ALTER TABLE release_history ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE release_history ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE sync_runs ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE sync_runs ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE installed_files ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE installed_files ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE client_defaults ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE client_defaults ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE manifest_audits ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE manifest_audits ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        INSERT INTO client_schema_migrations(version, name, applied_at)
        VALUES (1, 'initial_client_state', now())
        ON CONFLICT(version) DO NOTHING;
        INSERT INTO client_schema_migrations(version, name, applied_at)
        VALUES (2, 'endpoint_and_manifest_audits', now())
        ON CONFLICT(version) DO NOTHING;
        INSERT INTO client_schema_migrations(version, name, applied_at)
        VALUES (3, 'minecraft_versioned_inventory', now())
        ON CONFLICT(version) DO NOTHING;
        CREATE INDEX IF NOT EXISTS idx_sync_runs_finished_at ON sync_runs(finished_at);
        CREATE INDEX IF NOT EXISTS idx_sync_runs_target_result ON sync_runs(target_release_id, result);
        CREATE INDEX IF NOT EXISTS idx_installed_files_release_status ON installed_files(release_id, status);
        CREATE INDEX IF NOT EXISTS idx_installed_files_by_version_release_status ON installed_files_by_version(minecraft_version, release_id, status);
        CREATE INDEX IF NOT EXISTS idx_release_history_status_time ON release_history(status, installed_at);
        CREATE INDEX IF NOT EXISTS idx_client_defaults_status ON client_defaults(status);
        CREATE INDEX IF NOT EXISTS idx_endpoint_status_endpoint_time ON endpoint_status(endpoint, checked_at);
        CREATE INDEX IF NOT EXISTS idx_manifest_audits_release_time ON manifest_audits(release_id, checked_at);
        """)
        try executeTransactional(supportedVersionStatements())
    }

    public func record(snapshot: ClientStatusSnapshot) throws {
        try initialize()
        let now = Self.duckTimestamp(Date())
        let runID = UUID().uuidString
        var statements: [String] = []
        statements.append(upsertState("server_url", snapshot.serverURL, now: now))
        statements.append(upsertState("sync_state", snapshot.state.rawValue, now: now))
        statements.append(upsertState("last_check", snapshot.checkedAt, now: now))
        statements.append(upsertState("minecraft_directory", snapshot.minecraftDirectory, now: now))
        statements.append(endpointStatement(snapshot.nginx))
        statements.append(endpointStatement(snapshot.webTransport))
        if let serverRelease = snapshot.serverReleaseID {
            statements.append(upsertState("server_release_id", serverRelease, now: now))
            statements.append("""
            INSERT INTO release_history(release_id, first_seen_at, installed_at, status, manifest_sha256, minecraft_version, loader_version)
            VALUES ('\(Self.sql(serverRelease))', TIMESTAMP '\(now)', NULL, 'server_seen', NULL, \(Self.sqlLiteral(Self.liveMinecraftVersion)), \(Self.sqlLiteral(Self.liveLoaderVersion)))
            ON CONFLICT(release_id) DO UPDATE SET status = excluded.status;
            """)
        }
        if let localRelease = snapshot.localReleaseID {
            statements.append(upsertState("local_release_id", localRelease, now: now))
        }
        statements.append("""
        INSERT INTO sync_runs(
          run_id, started_at, finished_at, from_release_id, target_release_id, result,
          files_verified, files_downloaded, files_quarantined, minecraft_version, loader_version, error_message
        )
        VALUES (
          '\(Self.sql(runID))',
          TIMESTAMP '\(now)',
          TIMESTAMP '\(now)',
          \(Self.sqlLiteral(snapshot.localReleaseID)),
          \(Self.sqlLiteral(snapshot.serverReleaseID)),
          '\(Self.sql(snapshot.state.rawValue))',
          0,
          0,
          0,
          \(Self.sqlLiteral(Self.liveMinecraftVersion)),
          \(Self.sqlLiteral(Self.liveLoaderVersion)),
          \(Self.sqlLiteral(snapshot.errorMessage))
        );
        """)
        for row in snapshot.defaultsHealth {
            statements.append("""
            INSERT INTO client_defaults(key, desired_value, applied_value, applied_at, status, source, minecraft_version, loader_version)
            VALUES (
              '\(Self.sql(row.id))',
              '\(Self.sql(row.desiredValue))',
              '\(Self.sql(row.observedValue))',
              TIMESTAMP '\(now)',
              '\(Self.sql(row.status.rawValue))',
              '\(Self.sql(row.source))',
              \(Self.sqlLiteral(Self.liveMinecraftVersion)),
              \(Self.sqlLiteral(Self.liveLoaderVersion))
            )
            ON CONFLICT(key) DO UPDATE SET
              desired_value = excluded.desired_value,
              applied_value = excluded.applied_value,
              applied_at = excluded.applied_at,
              status = excluded.status,
              source = excluded.source,
              minecraft_version = excluded.minecraft_version,
              loader_version = excluded.loader_version;
            """)
        }
        statements += retentionStatements()
        try executeTransactional(statements)
    }

    public func record(syncResult: ClientSyncResult, defaultsHealth: [ClientDefaultHealthRow], installedFiles: [FileInventoryEntry] = []) throws {
        try initialize()
        let now = Self.duckTimestamp(Date())
        let minecraftVersion = syncResult.minecraftVersion ?? Self.liveMinecraftVersion
        let loaderVersion = syncResult.loaderVersion ?? Self.liveLoaderVersion
        var statements: [String] = []
        statements.append(upsertState("sync_state", syncResult.result, now: now))
        statements.append(upsertState("last_sync", syncResult.finishedAt, now: now))
        statements.append(upsertState("local_release_id", syncResult.targetReleaseID, now: now))
        statements.append(upsertState("last_manifest_entries", String(syncResult.manifestEntries), now: now))
        statements.append(upsertState("last_files_verified", String(syncResult.filesVerified), now: now))
        statements.append(upsertState("last_files_downloaded", String(syncResult.filesDownloaded), now: now))
        statements.append(upsertState("last_files_quarantined", String(syncResult.filesQuarantined), now: now))
        statements.append("""
        INSERT INTO release_history(release_id, first_seen_at, installed_at, status, manifest_sha256, minecraft_version, loader_version)
        VALUES ('\(Self.sql(syncResult.targetReleaseID))', TIMESTAMP '\(now)', TIMESTAMP '\(now)', 'installed', NULL, \(Self.sqlLiteral(minecraftVersion)), \(Self.sqlLiteral(loaderVersion)))
        ON CONFLICT(release_id) DO UPDATE SET
          installed_at = excluded.installed_at,
          status = excluded.status,
          minecraft_version = excluded.minecraft_version,
          loader_version = excluded.loader_version;
        """)
        statements.append("""
        INSERT INTO sync_runs(
          run_id, started_at, finished_at, from_release_id, target_release_id, result,
          files_verified, files_downloaded, files_quarantined, minecraft_version, loader_version, error_message
        )
        VALUES (
          '\(Self.sql(syncResult.runID))',
          TIMESTAMP '\(Self.sqlTimestamp(syncResult.startedAt))',
          TIMESTAMP '\(Self.sqlTimestamp(syncResult.finishedAt))',
          \(Self.sqlLiteral(syncResult.fromReleaseID)),
          '\(Self.sql(syncResult.targetReleaseID))',
          '\(Self.sql(syncResult.result))',
          \(syncResult.filesVerified),
          \(syncResult.filesDownloaded),
          \(syncResult.filesQuarantined),
          \(Self.sqlLiteral(minecraftVersion)),
          \(Self.sqlLiteral(loaderVersion)),
          \(syncResult.result == "ok" ? "NULL" : Self.sqlLiteral(syncResult.message))
        );
        """)
        statements.append("""
        INSERT INTO sync_events(event_id, run_id, timestamp, level, message, file_name)
        VALUES (
          '\(Self.sql(UUID().uuidString))',
          '\(Self.sql(syncResult.runID))',
          TIMESTAMP '\(now)',
          '\(syncResult.result == "ok" ? "info" : "error")',
          '\(Self.sql(syncResult.message))',
          NULL
        );
        """)
        let missingOrCorrupt = syncResult.result == "ok" ? max(0, syncResult.manifestEntries - syncResult.filesVerified) : syncResult.manifestEntries
        statements.append("""
        INSERT INTO manifest_audits(
          audit_id, release_id, checked_at, manifest_entries, files_verified,
          files_missing_or_corrupt, status, source, minecraft_version, loader_version
        )
        VALUES (
          '\(Self.sql(syncResult.runID))',
          '\(Self.sql(syncResult.targetReleaseID))',
          TIMESTAMP '\(Self.sqlTimestamp(syncResult.finishedAt))',
          \(syncResult.manifestEntries),
          \(syncResult.filesVerified),
          \(missingOrCorrupt),
          '\(Self.sql(syncResult.result))',
          'sync',
          \(Self.sqlLiteral(minecraftVersion)),
          \(Self.sqlLiteral(loaderVersion))
        )
        ON CONFLICT(audit_id) DO UPDATE SET
          checked_at = excluded.checked_at,
          manifest_entries = excluded.manifest_entries,
          files_verified = excluded.files_verified,
          files_missing_or_corrupt = excluded.files_missing_or_corrupt,
          status = excluded.status,
          source = excluded.source,
          minecraft_version = excluded.minecraft_version,
          loader_version = excluded.loader_version;
        """)
        for file in installedFiles {
            statements.append("""
            INSERT INTO installed_files(section, name, path, size_bytes, sha256, release_id, minecraft_version, loader_version, verified_at, status)
            VALUES (
              '\(Self.sql(file.section.rawValue))',
              '\(Self.sql(file.name))',
              '\(Self.sql(file.relativePath))',
              \(file.sizeBytes),
              '\(Self.sql(file.sha256))',
              '\(Self.sql(syncResult.targetReleaseID))',
              \(Self.sqlLiteral(minecraftVersion)),
              \(Self.sqlLiteral(loaderVersion)),
              TIMESTAMP '\(now)',
              'verified'
            )
            ON CONFLICT(section, name) DO UPDATE SET
              path = excluded.path,
              size_bytes = excluded.size_bytes,
              sha256 = excluded.sha256,
              release_id = excluded.release_id,
              minecraft_version = excluded.minecraft_version,
              loader_version = excluded.loader_version,
              verified_at = excluded.verified_at,
              status = excluded.status;
            """)
            statements.append("""
            INSERT INTO installed_files_by_version(minecraft_version, loader_version, section, name, path, size_bytes, sha256, release_id, verified_at, status)
            VALUES (
              \(Self.sqlLiteral(minecraftVersion)),
              \(Self.sqlLiteral(loaderVersion)),
              '\(Self.sql(file.section.rawValue))',
              '\(Self.sql(file.name))',
              '\(Self.sql(file.relativePath))',
              \(file.sizeBytes),
              '\(Self.sql(file.sha256))',
              '\(Self.sql(syncResult.targetReleaseID))',
              TIMESTAMP '\(now)',
              'verified'
            )
            ON CONFLICT(minecraft_version, section, name) DO UPDATE SET
              loader_version = excluded.loader_version,
              path = excluded.path,
              size_bytes = excluded.size_bytes,
              sha256 = excluded.sha256,
              release_id = excluded.release_id,
              verified_at = excluded.verified_at,
              status = excluded.status;
            """)
        }
        for row in defaultsHealth {
            statements.append("""
            INSERT INTO client_defaults(key, desired_value, applied_value, applied_at, status, source, minecraft_version, loader_version)
            VALUES (
              '\(Self.sql(row.id))',
              '\(Self.sql(row.desiredValue))',
              '\(Self.sql(row.observedValue))',
              TIMESTAMP '\(now)',
              '\(Self.sql(row.status.rawValue))',
              '\(Self.sql(row.source))',
              \(Self.sqlLiteral(minecraftVersion)),
              \(Self.sqlLiteral(loaderVersion))
            )
            ON CONFLICT(key) DO UPDATE SET
              desired_value = excluded.desired_value,
              applied_value = excluded.applied_value,
              applied_at = excluded.applied_at,
              status = excluded.status,
              source = excluded.source,
              minecraft_version = excluded.minecraft_version,
              loader_version = excluded.loader_version;
            """)
        }
        statements += retentionStatements()
        try executeTransactional(statements)
    }

    public func recordClientState(key: String, value: String) throws {
        try initialize()
        try execute(upsertState(key, value, now: Self.duckTimestamp(Date())))
    }

    private func upsertState(_ key: String, _ value: String, now: String) -> String {
        """
        INSERT INTO client_state(key, value, updated_at)
        VALUES ('\(Self.sql(key))', '\(Self.sql(value))', TIMESTAMP '\(now)')
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at;
        """
    }

    private func endpointStatement(_ status: EndpointConnectionStatus) -> String {
        """
        INSERT INTO endpoint_status(endpoint, checked_at, state, latency_ms, message)
        VALUES (
          '\(Self.sql(status.label))',
          TIMESTAMP '\(Self.sqlTimestamp(status.checkedAt))',
          '\(Self.sql(status.state.rawValue))',
          \(status.latencyMS.map(String.init) ?? "NULL"),
          '\(Self.sql(String(status.message.prefix(1_000))))'
        )
        ON CONFLICT(endpoint, checked_at) DO UPDATE SET
          state = excluded.state,
          latency_ms = excluded.latency_ms,
          message = excluded.message;
        """
    }

    private func retentionStatements() -> [String] {
        [
            """
            DELETE FROM endpoint_status
            WHERE (endpoint, checked_at) NOT IN (
              SELECT endpoint, checked_at
              FROM endpoint_status
              ORDER BY checked_at DESC
              LIMIT \(Self.maxEndpointChecks)
            );
            """,
            """
            DELETE FROM manifest_audits
            WHERE audit_id NOT IN (
              SELECT audit_id
              FROM manifest_audits
              ORDER BY checked_at DESC
              LIMIT \(Self.maxManifestAudits)
            );
            """,
            """
            DELETE FROM sync_runs
            WHERE run_id NOT IN (
              SELECT run_id
              FROM sync_runs
              ORDER BY started_at DESC
              LIMIT \(Self.maxSyncRuns)
            );
            """,
            """
            DELETE FROM sync_events
            WHERE run_id NOT IN (SELECT run_id FROM sync_runs)
               OR timestamp < now() - INTERVAL 90 DAY;
            """
        ]
    }

    private func supportedVersionStatements() -> [String] {
        let now = Self.duckTimestamp(Date())
        return MinecraftClientDefaults.defaultSupportedServers.map { server in
            """
            INSERT INTO client_supported_versions(
              minecraft_version, loader, loader_version, server_name, server_address,
              status, is_live, updated_at
            )
            VALUES (
              \(Self.sqlLiteral(server.minecraftVersion)),
              'neoforge',
              \(Self.sqlLiteral(server.loaderVersion)),
              \(Self.sqlLiteral(server.serverName)),
              \(Self.sqlLiteral(server.serverAddress)),
              \(Self.sqlLiteral(server.status)),
              \(server.isLive ? "true" : "false"),
              TIMESTAMP '\(now)'
            )
            ON CONFLICT(minecraft_version) DO UPDATE SET
              loader = excluded.loader,
              loader_version = excluded.loader_version,
              server_name = excluded.server_name,
              server_address = excluded.server_address,
              status = excluded.status,
              is_live = excluded.is_live,
              updated_at = excluded.updated_at;
            """
        }
    }

    private func executeTransactional(_ statements: [String]) throws {
        try execute("BEGIN TRANSACTION;\n\(statements.joined(separator: "\n"))\nCOMMIT;")
    }

    private func execute(_ sql: String) throws {
        do {
            try DuckDBDatabase(databaseURL: databaseURL).execute(sql)
        } catch {
            throw ContractValidationError.invalid("duckdb write failed: \(error)")
        }
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(sql(value))'"
    }

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func sqlTimestamp(_ value: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: value) ?? Date()
        return duckTimestamp(parsed)
    }

    private static var liveMinecraftVersion: String {
        MinecraftClientDefaults.defaultSupportedServers.first(where: { $0.isLive })?.minecraftVersion ?? "26.1.2"
    }

    private static var liveLoaderVersion: String {
        MinecraftClientDefaults.defaultSupportedServers.first(where: { $0.isLive })?.loaderVersion ?? "26.1.2.76"
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
