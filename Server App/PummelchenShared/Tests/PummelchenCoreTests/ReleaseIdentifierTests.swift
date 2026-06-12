import Testing
@testable import PummelchenCore

@Suite("Release identifier parsing")
struct ReleaseIdentifierTests {
    @Test("parses current release ID shape")
    func parsesReleaseID() throws {
        let id = try ReleaseIdentifier("release_20260612_V16_duck-goose-no-follow-defaults-v2")

        #expect(id.date == "20260612")
        #expect(id.version == 16)
        #expect(id.suffix == "_duck-goose-no-follow-defaults-v2")
    }

    @Test("rejects non-release IDs")
    func rejectsInvalidIDs() throws {
        #expect(throws: ContractValidationError.self) {
            _ = try ReleaseIdentifier("qa_release_1")
        }
    }
}
