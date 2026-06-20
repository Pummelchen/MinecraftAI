import Foundation
import Testing
@testable import MCPummelchenModShared

@Suite("Current release JSON contract")
struct CurrentReleaseTests {
    @Test("decodes and validates the frozen current-release shape")
    func validatesCurrentReleaseFixture() throws {
        let url = try #require(Bundle.module.url(forResource: "current-release", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)

        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)

        #expect(release.releaseID == "release_20260612_V6_modernarch-refresh")
        #expect(release.manifestURL.hasSuffix("/client-sync-manifest.tsv"))
    }

    @Test("accepts optional DMG metadata only when URL and SHA are paired")
    func validatesOptionalDMGMetadata() throws {
        let valid = """
        {
          "release_id": "release_20260612_V6_modernarch-refresh",
          "created_at": "2026-06-12T00:00:00+00:00",
          "activated_at": "2026-06-12T00:05:00+00:00",
          "status": "tested",
          "minecraft_version": "26.1.2",
          "loader_version": "26.1.2.75",
          "server_key": "minecraft_26_1_2",
          "manifest_url": "/downloads/releases/release_20260612_V6_modernarch-refresh/client-sync-manifest.tsv",
          "client_zip_url": "/downloads/releases/release_20260612_V6_modernarch-refresh/Pummelchen-Client.zip",
          "client_zip_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
          "mrpack_url": "/downloads/releases/release_20260612_V6_modernarch-refresh/Pummelchen.mrpack",
          "mrpack_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
          "dmg_url": "/downloads/MCPummelchenModClient.dmg",
          "dmg_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          "notes": "fixture"
        }
        """

        let release = try CurrentReleaseValidator.decode(Data(valid.utf8))
        try CurrentReleaseValidator.validate(release)
        #expect(release.dmgURL?.hasSuffix(".dmg") == true)

        let missingHash = valid
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("\"dmg_sha256\"") }
            .joined(separator: "\n")
        let invalid = try CurrentReleaseValidator.decode(Data(missingHash.utf8))
        #expect(throws: ContractValidationError.self) {
            try CurrentReleaseValidator.validate(invalid)
        }
    }
}
