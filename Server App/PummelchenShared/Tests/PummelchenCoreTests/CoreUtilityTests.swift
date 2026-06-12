import Foundation
import Testing
@testable import PummelchenCore

@Suite("Core utility contracts")
struct CoreUtilityTests {
    @Test("formats website timestamps in UTC table shape")
    func formatsWebsiteTimestamp() throws {
        let display = try PummelchenTimestamp.displayUTC(fromISO8601: "2026-06-12T15:59:23+00:00")
        #expect(display == "2026-06-12 15:59:23")
    }

    @Test("hashes and verifies inventory files")
    func hashesInventoryFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let mods = root.appendingPathComponent("mods", isDirectory: true)
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        let file = mods.appendingPathComponent("example.jar")
        try "abc".write(to: file, atomically: true, encoding: .utf8)

        let entry = try FileInventory.entry(for: file, section: .mods, root: root)
        #expect(entry.name == "example.jar")
        #expect(entry.relativePath == "mods/example.jar")
        #expect(entry.sizeBytes == 3)
        #expect(entry.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try FileInventory.verify(fileURL: file, expectedSize: entry.sizeBytes, expectedSHA256: entry.sha256))
    }

    @Test("rejects paths outside configured root")
    func rejectsEscapingPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-root-\(UUID().uuidString)", isDirectory: true)
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }

        let safePath = try SafePath(root: root)
        #expect(throws: ContractValidationError.self) {
            _ = try safePath.validateChild(other.appendingPathComponent("escape.jar"))
        }
    }

    @Test("encodes API envelope with snake case contract fields")
    func encodesAPIEnvelope() throws {
        let report = ClientStatusReport(
            clientID: "client-a",
            reportedAt: "2026-06-12T15:59:23+00:00",
            installedReleaseID: "release_20260612_V16_example",
            targetReleaseID: "release_20260612_V16_example",
            status: "synced",
            manifestEntries: 254,
            changedFiles: 0,
            lastError: nil,
            message: "all synced",
            osSummary: "macOS",
            arch: "arm64"
        )
        let envelope = APIEnvelope(ok: true, generatedAt: "2026-06-12T16:00:00+00:00", payload: report)
        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(object?["generated_at"] as? String == "2026-06-12T16:00:00+00:00")
        let payload = object?["payload"] as? [String: Any]
        #expect(payload?["client_id"] as? String == "client-a")
        #expect(payload?["changed_files"] as? Int == 0)
    }
}
