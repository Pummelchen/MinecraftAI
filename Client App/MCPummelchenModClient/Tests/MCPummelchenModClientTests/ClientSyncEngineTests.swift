import Foundation
import Testing
@testable import MCPummelchenModClientCore
@testable import MCPummelchenModShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@Suite("Swift client sync engine")
struct ClientSyncEngineTests {
    @Test("control watcher syncs only release, sync, defaults, and explicit client sync events")
    func controlWatcherSyncEventClassification() {
        let syncEvents: [ControlEventType] = [
            .releaseAvailable,
            .syncRequired,
            .defaultsChanged,
            .clientSyncRequested
        ]
        let passiveEvents: [ControlEventType] = [
            .serverMessage,
            .serverRestartNotice,
            .healthUpdate
        ]

        for eventType in syncEvents {
            #expect(ClientControlWatcher.requiresImmediateSync(event(type: eventType)))
        }
        for eventType in passiveEvents {
            #expect(!ClientControlWatcher.requiresImmediateSync(event(type: eventType)))
        }
    }

    @Test("sync installs files atomically, quarantines unmanaged files, applies defaults, and records history")
    func syncInstallsAndRecordsHistory() async throws {
        #if os(Linux)
        return
        #else
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

        try "corrupt".write(to: minecraft.appendingPathComponent("mods/example.jar"), atomically: true, encoding: .utf8)
        let repaired = try await engine.sync(force: true)
        #expect(repaired.filesDownloaded == 1)
        #expect(repaired.filesVerified == 2)
        #expect((try? String(contentsOf: minecraft.appendingPathComponent("mods/example.jar"), encoding: .utf8)) == "mod-v1")

        let defaults = ClientDefaultsInspector.inspect(minecraftDirectory: minecraft)
        #expect(defaults.allSatisfy { $0.status.isHealthy || $0.id == "java_runtime" && $0.status == .testing })
        #endif
    }

    @Test("sync falls back to Swift current release API when nginx pointer is missing")
    func syncFallsBackToSwiftCurrentReleaseAPI() async throws {
        #if os(Linux)
        return
        #else
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-swift-sync-api-fallback-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseID = "release_20260613_V99_api_fallback"
        let releaseDir = site.appendingPathComponent("downloads/releases/\(releaseID)", isDirectory: true)
        let filesDir = releaseDir.appendingPathComponent("client-files/mods", isDirectory: true)
        let apiCurrent = site.appendingPathComponent("api/v1/releases/current")
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: apiCurrent.deletingLastPathComponent(), withIntermediateDirectories: true)

        let mod = filesDir.appendingPathComponent("fallback.jar")
        try "fallback-mod".write(to: mod, atomically: true, encoding: .utf8)
        let hash = try SHA256Hasher.hashFile(at: mod)
        let size = (try FileManager.default.attributesOfItem(atPath: mod.path)[.size] as? NSNumber)?.intValue ?? 0
        try """
        mods\tfallback.jar\t\(size)\tsha256:\(hash)\tdownloads/releases/\(releaseID)/client-files/mods/fallback.jar
        """.write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        try currentReleaseJSON(releaseID: releaseID, manifestURL: "/downloads/releases/\(releaseID)/client-sync-manifest.tsv")
            .write(to: apiCurrent, atomically: true, encoding: .utf8)

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

        let result = try await engine.sync(force: true)
        #expect(result.targetReleaseID == releaseID)
        #expect(result.filesDownloaded == 1)
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("mods/fallback.jar").path))
        #endif
    }

    @Test("sync creates required managed directories on first launch")
    func createsManagedDirectoriesOnFirstLaunch() async throws {
        #if os(Linux)
        return
        #else
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-swift-sync-empty-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseID = "release_20260619_V1_empty_sync"
        let releaseDir = site.appendingPathComponent("downloads/releases/\(releaseID)", isDirectory: true)
        try FileManager.default.createDirectory(at: releaseDir, withIntermediateDirectories: true)
        try "".write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
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

        let result = try await engine.sync(force: true)
        #expect(result.result == "ok")
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("mods").path))
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("resourcepacks").path))
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("shaderpacks").path))
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent("config").path))
        #expect(FileManager.default.fileExists(atPath: minecraft.appendingPathComponent(".pummelchen").path))
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

    private func event(type: ControlEventType) -> ControlEvent {
        ControlEvent(
            eventID: UUID().uuidString,
            eventType: type,
            createdAt: "2026-06-13T00:00:00+00:00",
            targetClientID: nil,
            releaseID: nil,
            priority: "normal",
            title: "Test event",
            message: "Test event"
        )
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if !process.isRunning {
                throw NSError(
                    domain: "LocalHTTPServer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "python http.server exited before binding 127.0.0.1:\(port)"]
                )
            }
            if Self.isTCPPortOpen(port: port) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        throw NSError(
            domain: "LocalHTTPServer",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "python http.server did not bind 127.0.0.1:\(port) before timeout"]
        )
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                let killer = Process()
                killer.executableURL = URL(fileURLWithPath: "/bin/kill")
                killer.arguments = ["-9", String(process.processIdentifier)]
                try? killer.run()
                killer.waitUntilExit()
            }
        }
        self.process = nil
    }

    private static func isTCPPortOpen(port: Int) -> Bool {
        #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = Int32(SOCK_STREAM)
        #endif
        let fd = socket(AF_INET, stream, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
