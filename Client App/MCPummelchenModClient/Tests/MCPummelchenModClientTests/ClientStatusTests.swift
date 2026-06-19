import Foundation
import Testing
@testable import MCPummelchenModClientCore
@testable import MCPummelchenModShared

@Suite("Client read-only status")
struct ClientStatusTests {
    @Test("client API token resolves from environment, app plist, or bundled resource")
    func clientAPITokenResolutionUsesBundledFallbacks() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-token-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tokenFile = root.appendingPathComponent("client-api-token")
        try " bundled-token \n".write(to: tokenFile, atomically: true, encoding: .utf8)

        #expect(ClientCredentialProvider.clientAPIToken(environmentToken: " env-token ", infoPlistToken: "plist-token", resourceURLs: [tokenFile]) == "env-token")
        #expect(ClientCredentialProvider.clientAPIToken(environmentToken: nil, infoPlistToken: " plist-token ", resourceURLs: [tokenFile]) == "plist-token")
        #expect(ClientCredentialProvider.clientAPIToken(environmentToken: nil, infoPlistToken: nil, resourceURLs: [tokenFile]) == "bundled-token")
        #expect(ClientCredentialProvider.clientAPIToken(environmentToken: nil, infoPlistToken: nil, resourceURLs: [nil]) == nil)
    }

    @Test("default inspector reports healthy configured Minecraft defaults")
    func defaultInspectorReportsHealthyDefaults() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        resourcePacks:["vanilla","mod_resources","file/ModernArch v2.8.2 [26.1] [128x].zip","file/ModernArch FA Extension v2.2.zip","file/ModernArch Denser Grass Addon.zip"]
        incompatibleResourcePacks:[]
        """.write(to: root.appendingPathComponent("options.txt"), atomically: true, encoding: .utf8)
        try """
        shaderPack=BSL_v10.1.3.zip
        enableShaders=true
        """.write(to: root.appendingPathComponent("config/iris.properties"), atomically: true, encoding: .utf8)
        let javaPath = "/tmp/pummelchen-test/java/temurin-25.0.3+9/Contents/Home/bin/java"
        let escapedJavaPath = javaPath.replacingOccurrences(of: "/", with: "\\/")
        try """
        {"profiles":{"NeoForge":{"javaArgs":"-Xmx8G -XX:+UseG1GC","javaDir":"\(escapedJavaPath)"}}}
        """
            .write(to: root.appendingPathComponent("launcher_profiles.json"), atomically: true, encoding: .utf8)
        try "Pummelchen Server 26.1.2 91.99.176.243:25565 Pummelchen Server 26.2 91.99.176.243:25566".write(to: root.appendingPathComponent("servers.dat"), atomically: true, encoding: .utf8)
        try "showLoadWarnings=false\n".write(to: root.appendingPathComponent("config/neoforge-client.toml"), atomically: true, encoding: .utf8)
        try "showLoadWarnings=false\n".write(to: root.appendingPathComponent("config/forge-client.toml"), atomically: true, encoding: .utf8)
        try "showCheckScreen=false\n".write(to: root.appendingPathComponent("config/yuushya-client.toml"), atomically: true, encoding: .utf8)
        try "duck_tamed_no_follow=true\ngoose_tamed_no_follow=true\n".write(to: root.appendingPathComponent("config/untitledduckmod-server.toml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config/physicsmod"), withIntermediateDirectories: true)
        try """
        {
          "mobSettings": {
            "Physics Type": 3
          },
          "jointBlood": 1.0
        }
        """.write(to: root.appendingPathComponent("config/physicsmod/physics_client_config.json"), atomically: true, encoding: .utf8)

        let rows = ClientDefaultsInspector.inspect(minecraftDirectory: root, defaults: MinecraftClientDefaults(javaExecutablePath: javaPath))
        #expect(rows.allSatisfy { $0.status.isHealthy })
        #expect(rows.contains { $0.id == "shader" })
        #expect(rows.contains { $0.id == "memory" })
        #expect(rows.contains { $0.id == "java_runtime" })
        #expect(rows.contains { $0.id == "server_entry" })
        #expect(rows.contains { $0.id == "physics_mob_fracturing" && $0.observedValue == "Mob Fracturing (with blood)" })
        let shader = try #require(rows.first { $0.id == "shader" })
        #expect(shader.label == "Shaders")
        #expect(shader.desiredValue == "BSL_v10.1.3.zip")
        #expect(shader.observedValue == "OK")

        let resourcePacks = try #require(rows.first { $0.id == "resource_packs" })
        #expect(resourcePacks.label == "Resource Packs")
        #expect(resourcePacks.desiredValue.contains("ModernArch v2.8.2 [26.1] [128x].zip"))
        #expect(resourcePacks.desiredValue.contains("ModernArch FA Extension v2.2.zip"))
        #expect(resourcePacks.desiredValue.contains("ModernArch Denser Grass Addon.zip"))
        #expect(resourcePacks.observedValue == "OK")

        let java = try #require(rows.first { $0.id == "java_runtime" })
        #expect(java.label == "Java Runtime")
        #expect(java.desiredValue == "25.0.3")
        #expect(java.observedValue == "25.0.3")
        #expect(java.status == .pass)

        let server = try #require(rows.first { $0.id == "server_entry" })
        #expect(server.label == "Server Entries")
        #expect(server.observedValue == "Pummelchen Servers Ready")
    }


    @Test("endpoint status reports live-update credentials state")
    func endpointStatusReportsLiveUpdateCredentialsState() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-endpoint-state-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseID = "release_20260619_V1_endpoint_state"
        let releaseDir = site.appendingPathComponent("downloads/releases/\(releaseID)", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)
        try "".write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        try currentReleaseJSON(releaseID: releaseID, manifestURL: "/downloads/releases/\(releaseID)/client-sync-manifest.tsv")
            .write(to: site.appendingPathComponent("downloads/current-release.json"), atomically: true, encoding: .utf8)

        let server = try LocalHTTPServer(root: site)
        try server.start()
        defer { server.stop() }

        let service = ClientStatusService(configuration: ClientStatusConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            minecraftDirectory: minecraft,
            pummelchenHome: home,
            databaseURL: home.appendingPathComponent("client.duckdb"),
            retryPolicy: ClientHTTPRetryPolicy(maxAttempts: 1, requestTimeoutSeconds: 2, baseDelayNanoseconds: 0),
            clientAPIToken: nil,
            manageRuntimeChecks: false,
            probeEndpointLatency: true
        ))

        let statuses = await service.endpointStatuses()
        #expect(statuses.downloadServer.state == .connected)
        #expect(statuses.updateServer.state == .degraded)
        #expect(statuses.updateServer.message == "client credentials unavailable")
    }

    @Test("endpoint status falls back to cannot-connect when servers are unreachable")
    func endpointStatusFallsBackWhenEndpointsUnavailable() async {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-endpoint-unreachable-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = ClientStatusService(configuration: ClientStatusConfiguration(
            serverURL: URL(string: "http://127.0.0.1:1")!,
            minecraftDirectory: minecraft,
            pummelchenHome: home,
            databaseURL: home.appendingPathComponent("client.duckdb"),
            retryPolicy: ClientHTTPRetryPolicy(maxAttempts: 1, requestTimeoutSeconds: 1, baseDelayNanoseconds: 0),
            clientAPIToken: "token",
            manageRuntimeChecks: false,
            probeEndpointLatency: true
        ))

        let statuses = await service.endpointStatuses()
        #expect(statuses.downloadServer.state == .cannotConnect)
        #expect(statuses.updateServer.state == .cannotConnect)
    }


    @Test("default inspector detects missing read-only defaults without mutating files")
    func defaultInspectorDetectsMissingDefaults() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-status-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = ClientDefaultsInspector.inspect(minecraftDirectory: root)
        #expect(rows.contains { $0.status == .missing })
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
    }

    @Test("default inspector returns player-visible rows in priority order")
    func defaultInspectorReturnsPriorityOrder() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-status-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = ClientDefaultsInspector.inspect(minecraftDirectory: root)
        #expect(rows.prefix(5).map(\.label) == [
            "Java Runtime",
            "Server Entries",
            "Memory",
            "Shaders",
            "Resource Packs"
        ])
    }

    @Test("status audit detects corrupt installed release files")
    func statusAuditDetectsCorruptManagedFiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-audit-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseID = "release_20260613_V99_status_audit"
        let releaseDir = site.appendingPathComponent("downloads/releases/\(releaseID)", isDirectory: true)
        let filesDir = releaseDir.appendingPathComponent("client-files/mods", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minecraft.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minecraft.appendingPathComponent(".pummelchen"), withIntermediateDirectories: true)

        let source = filesDir.appendingPathComponent("example.jar")
        let installed = minecraft.appendingPathComponent("mods/example.jar")
        try "mod-ok".write(to: source, atomically: true, encoding: .utf8)
        try "mod-ok".write(to: installed, atomically: true, encoding: .utf8)
        try MinecraftClientDefaultWriter.apply(defaults: MinecraftClientDefaults(), to: minecraft)
        try (releaseID + "\n").write(to: minecraft.appendingPathComponent(".pummelchen/installed-release.txt"), atomically: true, encoding: .utf8)

        let hash = try SHA256Hasher.hashFile(at: source)
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        try """
        mods\texample.jar\t\(size)\tsha256:\(hash)\tdownloads/releases/\(releaseID)/client-files/mods/example.jar
        """.write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        try currentReleaseJSON(releaseID: releaseID)
            .write(to: site.appendingPathComponent("downloads/current-release.json"), atomically: true, encoding: .utf8)

        let server = try LocalHTTPServer(root: site)
        try server.start()
        defer { server.stop() }

        let service = ClientStatusService(configuration: ClientStatusConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            minecraftDirectory: minecraft,
            pummelchenHome: home,
            databaseURL: home.appendingPathComponent("client.duckdb"),
            retryPolicy: ClientHTTPRetryPolicy(maxAttempts: 1, requestTimeoutSeconds: 2, baseDelayNanoseconds: 0),
            clientAPIToken: nil,
            manageRuntimeChecks: false,
            probeEndpointLatency: false
        ))

        let healthy = await service.check()
        #expect(healthy.state == .synced)
        #expect(healthy.errorMessage == nil)

        try "corrupt".write(to: installed, atomically: true, encoding: .utf8)
        let corrupt = await service.check()
        #expect(corrupt.state == .repairNeeded)
        #expect(corrupt.errorMessage?.contains("missing or corrupt") == true)
    }

    @Test("client DuckDB schema supports sync, endpoint, manifest, defaults, and inventory state")
    func clientDuckDBSchemaSupportsProductionState() throws {
        #if os(Linux)
        return
        #else
        guard duckDBAvailable() else {
            return
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-duckdb-\(UUID().uuidString)", isDirectory: true)
        let database = root.appendingPathComponent("client.duckdb")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ClientStatusStore(databaseURL: database)
        try store.initialize()
        let schemaVersion = try duckDBScalar(database: database, sql: "SELECT MAX(version) FROM client_schema_migrations;")
        #expect(schemaVersion == String(ClientStatusStore.schemaVersion))

        let snapshot = ClientStatusSnapshot(
            state: .synced,
            serverURL: "https://pummelchen.91.99.176.243.nip.io",
            downloadServer: EndpointConnectionStatus(label: "Mod Download Server", state: .connected, latencyMS: 42, message: "connected", checkedAt: "2026-06-13T10:00:00+00:00"),
            updateServer: EndpointConnectionStatus(label: "Live Update Server", state: .connected, latencyMS: 55, message: "connected", checkedAt: "2026-06-13T10:00:00+00:00"),
            serverReleaseID: "release_20260613_V99_client_duckdb",
            localReleaseID: "release_20260613_V99_client_duckdb",
            checkedAt: "2026-06-13T10:00:00+00:00",
            minecraftDirectory: root.appendingPathComponent("minecraft", isDirectory: true).path,
            localDatabase: database.path,
            clientIP: nil,
            defaultsHealth: [
                ClientDefaultHealthRow(
                    id: "memory",
                    label: "Memory",
                    desiredValue: "8G",
                    observedValue: "8G",
                    status: .pass,
                    source: "launcher_profiles.json",
                    recommendedAction: "Apply managed JVM arguments"
                )
            ],
            errorMessage: nil
        )
        try store.record(snapshot: snapshot)
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM endpoint_status;") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM client_defaults WHERE status IN ('pass', 'testing', 'fixed_ok');") == "1")

        let sync = ClientSyncResult(
            runID: "sync-run-client-duckdb",
            startedAt: "2026-06-13T10:00:01+00:00",
            finishedAt: "2026-06-13T10:00:02+00:00",
            fromReleaseID: nil,
            targetReleaseID: "release_20260613_V99_client_duckdb",
            result: "ok",
            manifestEntries: 1,
            filesVerified: 1,
            filesDownloaded: 1,
            filesQuarantined: 0,
            message: "synced",
            minecraftVersion: "26.1.2",
            loaderVersion: "26.1.2.76"
        )
        try store.record(
            syncResult: sync,
            defaultsHealth: snapshot.defaultsHealth,
            installedFiles: [
                FileInventoryEntry(
                    section: .mods,
                    name: "example.jar",
                    relativePath: "mods/example.jar",
                    sizeBytes: 7,
                    sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                )
            ]
        )
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM manifest_audits WHERE status = 'ok';") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM installed_files WHERE status = 'verified';") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM installed_files_by_version WHERE minecraft_version = '26.1.2' AND status = 'verified';") == "1")
        #expect(try duckDBScalar(database: database, sql: "SELECT COUNT(*) FROM client_supported_versions WHERE minecraft_version IN ('26.1.2', '26.2');") == "2")
        #expect(try duckDBScalar(database: database, sql: "SELECT value FROM client_state WHERE key = 'last_manifest_entries';") == "1")
        #endif
    }

    private func currentReleaseJSON(releaseID: String, manifestURL: String? = nil) -> String {
        let manifestPath = manifestURL ?? "/downloads/releases/\(releaseID)/client-sync-manifest.tsv"
        return """
        {
          "release_id": "\(releaseID)",
          "created_at": "2026-06-13T00:00:00+00:00",
          "activated_at": "2026-06-13T00:00:00+00:00",
          "status": "tested",
          "minecraft_version": "26.1.2",
          "loader_version": "26.1.2.76",
          "server_key": "minecraft_26_1_2",
          "manifest_url": "\(manifestPath)",
          "client_zip_url": "/downloads/releases/\(releaseID)/client.zip",
          "client_zip_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "mrpack_url": "/downloads/releases/\(releaseID)/pack.mrpack",
          "mrpack_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "notes": "test"
        }
        """
    }
}

private func duckDBAvailable() -> Bool {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pummelchen-duckdb-available-\(UUID().uuidString).duckdb")
    defer { try? FileManager.default.removeItem(at: url) }
    do {
        try DuckDBDatabase(databaseURL: url).execute("SELECT 1;")
        return true
    } catch {
        return false
    }
}

private func duckDBScalar(database: URL, sql: String) throws -> String {
    try DuckDBDatabase(databaseURL: database).queryScalar(sql)
}
