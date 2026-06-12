import Foundation
import Testing
@testable import PummelchenCore

@Suite("Client sync manifest contract")
struct ClientSyncManifestTests {
    @Test("parses the frozen v1 TSV shape")
    func parsesFrozenManifest() throws {
        let url = try #require(Bundle.module.url(forResource: "client-sync-manifest", withExtension: "tsv", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)

        let manifest = try ClientSyncManifestParser.parse(text)

        #expect(manifest.entries.count == 3)
        #expect(manifest.entries[0].section == "mods")
        #expect(manifest.entries[0].name == "example-mod.jar")
        #expect(manifest.entries[0].sizeBytes == 12345)
        #expect(manifest.entries[0].urlPath == "downloads/releases/release_20260612_V6_modernarch-refresh/client-files/mods/example-mod.jar")
    }

    @Test("rejects duplicate section and file names")
    func rejectsDuplicateManifestEntries() throws {
        let duplicate = """
        # Pummelchen client sync manifest v1
        mods\texample.jar\t1\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tdownloads/releases/release_20260612_V1/client-files/mods/example.jar
        mods\texample.jar\t1\tsha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\tdownloads/releases/release_20260612_V1/client-files/mods/example.jar
        """

        #expect(throws: ContractValidationError.self) {
            _ = try ClientSyncManifestParser.parse(duplicate)
        }
    }

    @Test("rejects malformed hashes")
    func rejectsMalformedHash() throws {
        let invalid = """
        # Pummelchen client sync manifest v1
        mods\texample.jar\t1\tsha256:not-a-hash\tdownloads/releases/release_20260612_V1/client-files/mods/example.jar
        """

        #expect(throws: ContractValidationError.self) {
            _ = try ClientSyncManifestParser.parse(invalid)
        }
    }
}
