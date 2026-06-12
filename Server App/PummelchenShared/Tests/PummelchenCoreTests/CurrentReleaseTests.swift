import Foundation
import Testing
@testable import PummelchenCore

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
}
