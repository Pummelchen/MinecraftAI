import Foundation
import Testing
import PummelchenCore
import PummelchenClientCore
@testable import PummelchenServerCore

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
