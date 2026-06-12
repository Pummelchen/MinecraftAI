import Foundation
import Testing
@testable import PummelchenServerCore

@Suite("Pummelchen read-only server API")
struct PummelchenServerCoreTests {
    @Test("serves current release identical to static JSON")
    func servesCurrentRelease() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = PummelchenReadOnlyAPI(config: PummelchenServerConfig(projectRoot: fixture.root))
        let response = api.response(for: HTTPRequest(method: "GET", path: "/api/v1/releases/current"))

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == fixture.currentReleaseJSON)
    }

    @Test("serves release manifest TSV")
    func servesManifest() throws {
        let fixture = try makeProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let api = PummelchenReadOnlyAPI(config: PummelchenServerConfig(projectRoot: fixture.root))
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

        let api = PummelchenReadOnlyAPI(config: PummelchenServerConfig(projectRoot: fixture.root))
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

        let api = PummelchenReadOnlyAPI(config: PummelchenServerConfig(projectRoot: fixture.root))
        let response = api.response(for: HTTPRequest(method: "POST", path: "/api/v1/releases/current"))

        #expect(response.statusCode == 405)
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
}
