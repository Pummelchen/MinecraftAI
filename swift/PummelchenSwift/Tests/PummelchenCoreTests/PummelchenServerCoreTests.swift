import Foundation
import Testing
import PummelchenCore
import PummelchenClientCore
@testable import PummelchenServerCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Pummelchen read-only server API")
struct PummelchenServerCoreTests {
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
        #expect(object?["transport_target"] as? String == "http3_quic")
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
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: serverDir.appendingPathComponent("server-datapacks"), withIntermediateDirectories: true)

        try "client mod".write(to: clientPackage.appendingPathComponent("mods/example-client.jar"), atomically: true, encoding: .utf8)
        try "AURORA=2\n".write(to: clientPackage.appendingPathComponent("shaderpacks/BSL_v10.1.3.zip.txt"), atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: clientPackage.appendingPathComponent("tools/pummelchen-auto-update.sh"), atomically: true, encoding: .utf8)
        try "server mod".write(to: serverDir.appendingPathComponent("mods/example-server.jar"), atomically: true, encoding: .utf8)
        try "datapack".write(to: serverDir.appendingPathComponent("server-datapacks/pummelchen-welcome.zip"), atomically: true, encoding: .utf8)

        try writeArtifact(name: SwiftReleasePipeline.clientZipName, content: "zip", serverDir: serverDir)
        try writeArtifact(name: SwiftReleasePipeline.mrpackName, content: "mrpack", serverDir: serverDir)
        try writeArtifact(name: SwiftReleasePipeline.dmgName, content: "dmg", serverDir: serverDir)

        let releaseID = "release_20260613_V77_swift_phase7_test"
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
            healthCommand: "echo release-health-ok"
        ))

        let result = try pipeline.createRelease()
        #expect(result.releaseID == releaseID)
        #expect(result.activated)
        try pipeline.validateRelease()

        let current = try CurrentReleaseValidator.decode(Data(contentsOf: publicDownloads.appendingPathComponent("current-release.json")))
        #expect(current.releaseID == releaseID)
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(SwiftReleasePipeline.dmgName)").path))
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/\(SwiftReleasePipeline.dmgName).sha256").path))
        #expect(FileManager.default.fileExists(atPath: publicDownloads.appendingPathComponent("releases/\(releaseID)/data/tested-updates.json").path))
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
            reportToServer: false
        ))
        let sync = try await engine.sync(force: true)
        #expect(sync.targetReleaseID == releaseID)
        #expect(sync.filesDownloaded == 3)
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("mods/example-client.jar").path))
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("shaderpacks/BSL_v10.1.3.zip.txt").path))

        let healthRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT COUNT(*) FROM release.release_health_results WHERE release_id = '\(releaseID)';")
        #expect(healthRows == "2")
        let restartRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT COUNT(*) FROM release.release_events WHERE release_id = '\(releaseID)' AND event_type = 'restart' AND status = 'skipped';")
        #expect(restartRows == "1")
        let activeRows = try duckDBScalar(database: root.appendingPathComponent("phase7.duckdb"), sql: "SELECT active FROM release.pack_releases WHERE release_id = '\(releaseID)';")
        #expect(activeRows == "true")
    }

    @Test("phase 8 control events use safe payloads and HTTP fallback")
    func phase8ControlEventsUseFallbackAndRejectDownloads() async throws {
        try requireDuckDB()
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = makeAPI(fixture: fixture, token: "phase8-token")
        let clientID = "client-phase8-a"
        let headers = authHeaders(token: "phase8-token", clientID: clientID)
        let encoder = JSONEncoder()

        let infoResponse = api.response(for: HTTPRequest(method: "GET", path: "/h3/v1/control"))
        let info = try JSONDecoder().decode(ControlChannelInfo.self, from: infoResponse.body)
        #expect(info.transportTarget == "bidirectional_http3_quic")
        #expect(info.bidirectional)
        #expect(!info.downloadsAllowed)
        #expect(info.supportedEvents.contains("release_available"))

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
        #expect(batch.transport == "http_polling_fallback")

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
            path: "/api/v1/control/events?client_id=\(clientID)",
            headers: headers
        ))
        let empty = try JSONDecoder().decode(ControlEventBatch.self, from: afterAck.body)
        #expect(empty.events.isEmpty)

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

    @Test("phase 8 client reconnect fetches missed events through polling fallback")
    func phase8ClientReconnectFetchesMissedEvents() async throws {
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
        let batch = try await client.reconnectWithFallback()
        #expect(batch.events.count == 1)
        #expect(batch.events[0].eventType == .serverRestartNotice)
        try await client.acknowledge(batch.events[0])
        let afterAck = try await client.fetchMissedEvents()
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

    @Test("phase 9 safe world reset requires explicit destructive confirmation")
    func phase9WorldResetRequiresConfirmation() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
            projectRoot: fixture.root,
            serverDir: fixture.serverDir,
            databaseURL: fixture.root.appendingPathComponent("phase9.duckdb"),
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

    @Test("phase 9 safe world reset replaces world, installs datapacks, records cleanup")
    func phase9WorldResetExecutesStagedFilesystemReset() throws {
        try requireDuckDB()
        let fixture = try makeWorldResetFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let database = fixture.root.appendingPathComponent("phase9.duckdb")
        let pipeline = SwiftWorldResetPipeline(config: SwiftWorldResetConfig(
            projectRoot: fixture.root,
            serverDir: fixture.serverDir,
            databaseURL: database,
            seed: "178127232016679900",
            radiusBlocks: 1000,
            dryRun: false,
            confirmDestructive: true,
            deleteBackupAfterSuccess: true,
            stopCommand: "true",
            startCommand: "true",
            gameruleCommand: "true",
            pregenerateCommand: "true",
            verifyForceloadsCommand: "true"
        ))
        let result = try pipeline.run()

        #expect(result.status == "completed")
        #expect(result.backupDeleted)
        #expect(result.forceloadsCleared)
        #expect(result.activeWorldExists)
        if let backupPath = result.backupPath {
            #expect(!FileManager.default.fileExists(atPath: backupPath))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/region/r.0.0.mca").path))
        #expect(FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/datapacks/pummelchen-welcome.zip").path))
        #expect(FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/datapacks/pummelchen-tropical-worldgen.zip").path))
        #expect(FileManager.default.fileExists(atPath: fixture.serverDir.appendingPathComponent("world/datapacks/pummelchen-rich-ores.zip").path))
        let properties = try String(contentsOf: fixture.serverDir.appendingPathComponent("server.properties"), encoding: .utf8)
        #expect(properties.contains("level-seed=178127232016679900"))
        #expect(properties.contains("bonus-chest=true"))
        let status = try duckDBScalar(database: database, sql: "SELECT status FROM world.reset_jobs WHERE job_id = '\(result.jobID)';")
        #expect(status == "completed")
        let cleanup = try duckDBScalar(database: database, sql: "SELECT json_extract_string(result_json, '$.backupDeleted') FROM world.reset_jobs WHERE job_id = '\(result.jobID)';")
        #expect(cleanup == "true")
    }

    private func makeProjectFixture() throws -> (root: URL, currentReleaseJSON: String, manifestTSV: String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-server-\(UUID().uuidString)", isDirectory: true)
        let releaseID = "release_20260612_V6_modernarch-refresh"
        let downloads = root.appendingPathComponent("site/public/downloads", isDirectory: true)
        let releaseDir = downloads.appendingPathComponent("releases/\(releaseID)", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)

        let currentURL = try #require(Bundle.module.url(forResource: "current-release", withExtension: "json", subdirectory: "Fixtures"))
        let manifestURL = try #require(Bundle.module.url(forResource: "client-sync-manifest", withExtension: "tsv", subdirectory: "Fixtures"))
        let current = try String(contentsOf: currentURL, encoding: .utf8)
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        try current.write(to: downloads.appendingPathComponent("current-release.json"), atomically: true, encoding: .utf8)
        try manifest.write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        return (root, current, manifest)
    }

    private func makeAPI(
        fixture: (root: URL, currentReleaseJSON: String, manifestTSV: String),
        token: String? = nil,
        maxWritePayloadBytes: Int = 256 * 1024
    ) -> PummelchenServerAPI {
        PummelchenServerAPI(config: PummelchenServerConfig(
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
        try "level-name=world\nlevel-seed=old\nbonus-chest=false\n".write(to: serverDir.appendingPathComponent("server.properties"), atomically: true, encoding: .utf8)
        try copyRequiredDatapacks(to: root.appendingPathComponent("server-datapacks", isDirectory: true))
        return (root, serverDir)
    }

    private func copyRequiredDatapacks(to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let source = repositoryRoot().appendingPathComponent("server-datapacks", isDirectory: true)
        for name in ["pummelchen-welcome.zip", "pummelchen-tropical-worldgen.zip", "pummelchen-rich-ores.zip"] {
            let destination = target.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: destination)
        }
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private func authHeaders(token: String, clientID: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "X-Pummelchen-Client-ID": clientID,
            "Content-Type": "application/json"
        ]
    }

    private func requireDuckDB() throws {
        let candidates = ["/opt/homebrew/bin/duckdb", "/usr/bin/duckdb", "/usr/local/bin/duckdb", "/bin/duckdb"]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return
        }
        throw CancellationError()
    }

    private func writeArtifact(name: String, content: String, serverDir: URL) throws {
        let file = serverDir.appendingPathComponent(name)
        try content.write(to: file, atomically: true, encoding: .utf8)
        let hash = try SHA256Hasher.hashFile(at: file)
        try "\(hash)  \(name)\n".write(to: serverDir.appendingPathComponent("\(name).sha256"), atomically: true, encoding: .utf8)
    }

    private func duckDBScalar(database: URL, sql: String) throws -> String {
        let candidates = ["/opt/homebrew/bin/duckdb", "/usr/bin/duckdb", "/usr/local/bin/duckdb", "/bin/duckdb"]
        let executable = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0) })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [database.path, "-csv", "-c", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        return output.split(separator: "\n").last.map(String.init) ?? ""
    }
}

final class APIRouterHTTPServer: @unchecked Sendable {
    let api: PummelchenServerAPI
    let port: Int
    private var socketFD: Int32 = -1
    private var thread: Thread?
    private var running = false

    init(api: PummelchenServerAPI) {
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
