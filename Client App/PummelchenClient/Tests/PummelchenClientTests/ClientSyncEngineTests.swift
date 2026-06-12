import Foundation
import Testing
@testable import PummelchenClientCore
@testable import PummelchenCore

@Suite("Swift client sync engine")
struct ClientSyncEngineTests {
    @Test("sync installs files atomically, quarantines unmanaged files, applies defaults, and records history")
    func syncInstallsAndRecordsHistory() async throws {
        #if os(Linux)
        return
        #else
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/duckdb")
            || FileManager.default.isExecutableFile(atPath: "/usr/bin/duckdb")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/duckdb")
        else {
            return
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-swift-sync-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseID = "release_20260612_V99_swift_sync_test"
        let releaseDir = site.appendingPathComponent("downloads/releases/\(releaseID)", isDirectory: true)
        let filesDir = releaseDir.appendingPathComponent("client-files", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filesDir.appendingPathComponent("tools"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minecraft.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minecraft.appendingPathComponent(".pummelchen"), withIntermediateDirectories: true)

        let mod = filesDir.appendingPathComponent("mods/example.jar")
        let tool = filesDir.appendingPathComponent("tools/helper.sh")
        try "mod-v1".write(to: mod, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try "old".write(to: minecraft.appendingPathComponent("mods/old.jar"), atomically: true, encoding: .utf8)
        try "custom".write(to: minecraft.appendingPathComponent("mods/custom.jar"), atomically: true, encoding: .utf8)
        try """
        mods\told.jar\t3\tsha256:\(try SHA256Hasher.hashFile(at: minecraft.appendingPathComponent("mods/old.jar")))\tdownloads/releases/\(releaseID)/client-files/mods/old.jar
        """.write(to: minecraft.appendingPathComponent(".pummelchen/client-sync-manifest.tsv"), atomically: true, encoding: .utf8)

        let modHash = try SHA256Hasher.hashFile(at: mod)
        let toolHash = try SHA256Hasher.hashFile(at: tool)
        let modSize = try FileManager.default.attributesOfItem(atPath: mod.path)[.size] as? NSNumber
        let toolSize = try FileManager.default.attributesOfItem(atPath: tool.path)[.size] as? NSNumber
        let manifest = """
        mods\texample.jar\t\(modSize?.intValue ?? 0)\tsha256:\(modHash)\tdownloads/releases/\(releaseID)/client-files/mods/example.jar
        tools\thelper.sh\t\(toolSize?.intValue ?? 0)\tsha256:\(toolHash)\tdownloads/releases/\(releaseID)/client-files/tools/helper.sh
        """
        try manifest.write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        try currentReleaseJSON(releaseID: releaseID, manifestURL: "/downloads/releases/\(releaseID)/client-sync-manifest.tsv")
            .write(to: site.appendingPathComponent("downloads/current-release.json"), atomically: true, encoding: .utf8)

        let server = try LocalHTTPServer(root: site)
        try server.start()
        defer { server.stop() }

        let engine = ClientSyncEngine(configuration: ClientSyncConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            minecraftDirectory: minecraft,
            pummelchenHome: home,
            databaseURL: home.appendingPathComponent("client.duckdb"),
            allowWhileMinecraftRunning: true,
            reportToServer: false,
            manageJavaRuntime: false
        ))

        let first = try await engine.sync(force: true)
        #expect(first.filesDownloaded == 2)
        #expect(first.filesVerified == 2)
        #expect(first.filesQuarantined == 1)
        #expect((try? String(contentsOf: minecraft.appendingPathComponent("mods/example.jar"), encoding: .utf8)) == "mod-v1")
        #expect(!FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("mods/old.jar").path))
        #expect(try FileManager.default.contentsOfDirectory(at: minecraft, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix("mods.before-pummelchen-swift-") })
        #expect((try? String(contentsOf: minecraft.appendingPathComponent(".pummelchen/installed-release.txt"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == releaseID)

        let second = try await engine.sync(force: true)
        #expect(second.filesDownloaded == 0)
        #expect(second.filesVerified == 2)
        #expect(second.message == "all synced, no downloads required")

        let defaults = ClientDefaultsInspector.inspect(minecraftDirectory: minecraft)
        #expect(defaults.allSatisfy { $0.status == .ok || $0.id == "java_runtime" && $0.status == .unknown })
        #endif
    }

    private func currentReleaseJSON(releaseID: String, manifestURL: String) -> String {
        """
        {
          "release_id": "\(releaseID)",
          "created_at": "2026-06-12T00:00:00+00:00",
          "activated_at": "2026-06-12T00:00:00+00:00",
          "status": "tested",
          "minecraft_version": "26.1.2",
          "loader_version": "26.1.2.75",
          "server_key": "minecraft_26_1_2",
          "manifest_url": "\(manifestURL)",
          "client_zip_url": "/downloads/releases/\(releaseID)/client.zip",
          "client_zip_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "mrpack_url": "/downloads/releases/\(releaseID)/pack.mrpack",
          "mrpack_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "notes": "test"
        }
        """
    }
}

final class LocalHTTPServer {
    let root: URL
    let port: Int
    private var process: Process?

    init(root: URL) throws {
        self.root = root
        self.port = Int.random(in: 18_000...28_000)
    }

    func start() throws {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
        Thread.sleep(forTimeInterval: 0.5)
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
    }
}
