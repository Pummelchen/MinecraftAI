import Foundation
import Testing
import PummelchenCore
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
}
