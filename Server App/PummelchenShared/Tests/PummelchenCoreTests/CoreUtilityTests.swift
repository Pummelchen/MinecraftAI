import Foundation
import Testing
@testable import PummelchenCore

@Suite("Core utility contracts")
struct CoreUtilityTests {
    @Test("server defaults disable Physics Mod Pro collapse")
    func disablesPhysicsModProCollapse() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MCPummelchenModServer-defaults-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("config/physicsmod/physics_server_config.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {
          "collapse": true,
          "collapseSpeed": 10,
          "dropBlocks": true,
          "maxCollapseObjects": 100
        }
        """.write(to: config, atomically: true, encoding: .utf8)

        try MinecraftServerDefaultWriter.apply(to: root)

        let data = try Data(contentsOf: config)
        let rootObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(rootObject["collapse"] as? Bool == false)
        #expect(rootObject["dropBlocks"] as? Bool == true)
        #expect(rootObject["collapseSpeed"] as? Int == 10)
        #expect(rootObject["maxCollapseObjects"] as? Int == 100)
    }

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

    @Test("relative paths use symlink-resolved roots")
    func relativePathUsesResolvedSymlinkRoot() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-symlink-base-\(UUID().uuidString)", isDirectory: true)
        let realRoot = base.appendingPathComponent("real-root", isDirectory: true)
        let linkRoot = base.appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot.appendingPathComponent("mods", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkRoot, withDestinationURL: realRoot)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = realRoot.appendingPathComponent("mods/example.jar")
        try "abc".write(to: file, atomically: true, encoding: .utf8)

        let safePath = try SafePath(root: linkRoot)
        #expect(try safePath.relativePath(for: file) == "mods/example.jar")
    }

    @Test("validates production client identifiers")
    func validatesClientIdentifiers() throws {
        try ContractValidation.requireClientID("client-phase6-a")

        #expect(throws: ContractValidationError.self) {
            try ContractValidation.requireClientID("bad id with spaces")
        }
        #expect(throws: ContractValidationError.self) {
            try ContractValidation.requireClientID("short")
        }
    }

    @Test("current release URLs stay inside release downloads")
    func validatesCurrentReleaseRelativeURLs() throws {
        let release = CurrentRelease(
            releaseID: "release_20260613_V21_client-smart-sync-feed",
            createdAt: "2026-06-13T00:00:00+00:00",
            activatedAt: nil,
            status: "active",
            minecraftVersion: "26.1.2",
            loaderVersion: "26.1.2.76",
            serverKey: "minecraft_26_1_2",
            manifestURL: "/downloads/releases/release_20260613_V21_client-smart-sync-feed/client-sync-manifest.tsv",
            clientZipURL: "/downloads/releases/release_20260613_V21_client-smart-sync-feed/minecraft_26.1.2_client_macos_apple_silicon.zip",
            clientZipSHA256: "47aea4e438d1753575006f6b8b00667402bd4cbd291cc534aa9892ee6f0307a0",
            mrpackURL: "/downloads/releases/release_20260613_V21_client-smart-sync-feed/pummelchen-server-26.1.2.mrpack",
            mrpackSHA256: "47aea4e438d1753575006f6b8b00667402bd4cbd291cc534aa9892ee6f0307a0",
            notes: "test"
        )
        try CurrentReleaseValidator.validate(release)

        let external = CurrentRelease(
            releaseID: release.releaseID,
            createdAt: release.createdAt,
            activatedAt: release.activatedAt,
            status: release.status,
            minecraftVersion: release.minecraftVersion,
            loaderVersion: release.loaderVersion,
            serverKey: release.serverKey,
            manifestURL: "https://example.com/client-sync-manifest.tsv",
            clientZipURL: release.clientZipURL,
            clientZipSHA256: release.clientZipSHA256,
            mrpackURL: release.mrpackURL,
            mrpackSHA256: release.mrpackSHA256,
            notes: release.notes
        )
        #expect(throws: ContractValidationError.self) {
            try CurrentReleaseValidator.validate(external)
        }

        let traversal = CurrentRelease(
            releaseID: release.releaseID,
            createdAt: release.createdAt,
            activatedAt: release.activatedAt,
            status: release.status,
            minecraftVersion: release.minecraftVersion,
            loaderVersion: release.loaderVersion,
            serverKey: release.serverKey,
            manifestURL: release.manifestURL,
            clientZipURL: "/downloads/releases/\(release.releaseID)/../other.zip",
            clientZipSHA256: release.clientZipSHA256,
            mrpackURL: release.mrpackURL,
            mrpackSHA256: release.mrpackSHA256,
            notes: release.notes
        )
        #expect(throws: ContractValidationError.self) {
            try CurrentReleaseValidator.validate(traversal)
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
