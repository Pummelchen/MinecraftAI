import Foundation
import Testing
@testable import PummelchenClientCore
@testable import PummelchenCore

@Suite("Client read-only status")
struct ClientStatusTests {
    @Test("default inspector reports healthy configured Minecraft defaults")
    func defaultInspectorReportsHealthyDefaults() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("config"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        resourcePacks:["vanilla","mod_resources","file/ModernArch v2.8.2 [26.1] [128x].zip","file/ModernArch FA Extension v2.2.zip","file/ModernArch Denser Grass Addon.zip"]
        incompatibleResourcePacks:[]
        """.write(to: root.appendingPathComponent("options.txt"), atomically: true, encoding: .utf8)
        try """
        shaderPack=BSL_v10.1.3.zip
        enableShaders=true
        """.write(to: root.appendingPathComponent("config/iris.properties"), atomically: true, encoding: .utf8)
        let javaPath = "/tmp/pummelchen-test/java/temurin-25.0.3+9/Contents/Home/bin/java"
        try """
        {"profiles":{"NeoForge":{"javaArgs":"-Xmx8G -XX:+UseG1GC","javaDir":"\(javaPath)"}}}
        """
            .write(to: root.appendingPathComponent("launcher_profiles.json"), atomically: true, encoding: .utf8)
        try "Pummelchen 91.99.176.243:25565".write(to: root.appendingPathComponent("servers.dat"), atomically: true, encoding: .utf8)
        try "showLoadWarnings=false\n".write(to: root.appendingPathComponent("config/neoforge-client.toml"), atomically: true, encoding: .utf8)
        try "showLoadWarnings=false\n".write(to: root.appendingPathComponent("config/forge-client.toml"), atomically: true, encoding: .utf8)
        try "showCheckScreen=false\n".write(to: root.appendingPathComponent("config/yuushya-client.toml"), atomically: true, encoding: .utf8)
        try "duck_tamed_no_follow=true\ngoose_tamed_no_follow=true\n".write(to: root.appendingPathComponent("config/untitledduckmod-server.toml"), atomically: true, encoding: .utf8)

        let rows = ClientDefaultsInspector.inspect(minecraftDirectory: root, defaults: MinecraftClientDefaults(javaExecutablePath: javaPath))
        #expect(rows.allSatisfy { $0.status == .ok })
        #expect(rows.contains { $0.id == "shader" })
        #expect(rows.contains { $0.id == "memory" })
        #expect(rows.contains { $0.id == "java_runtime" })
        #expect(rows.contains { $0.id == "server_entry" })
    }

    @Test("default inspector detects missing read-only defaults without mutating files")
    func defaultInspectorDetectsMissingDefaults() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-status-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rows = ClientDefaultsInspector.inspect(minecraftDirectory: root)
        #expect(rows.contains { $0.status == .missing })
        #expect((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true)
    }

    @Test("status audit detects corrupt installed release files")
    func statusAuditDetectsCorruptManagedFiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-client-audit-\(UUID().uuidString)", isDirectory: true)
        let site = root.appendingPathComponent("site", isDirectory: true)
        let minecraft = root.appendingPathComponent("minecraft", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let releaseID = "release_20260613_V99_status_audit"
        let releaseDir = site.appendingPathComponent("downloads/releases/\(releaseID)", isDirectory: true)
        let filesDir = releaseDir.appendingPathComponent("client-files/mods", isDirectory: true)
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minecraft.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: minecraft.appendingPathComponent(".pummelchen"), withIntermediateDirectories: true)

        let source = filesDir.appendingPathComponent("example.jar")
        let installed = minecraft.appendingPathComponent("mods/example.jar")
        try "mod-ok".write(to: source, atomically: true, encoding: .utf8)
        try "mod-ok".write(to: installed, atomically: true, encoding: .utf8)
        try (releaseID + "\n").write(to: minecraft.appendingPathComponent(".pummelchen/installed-release.txt"), atomically: true, encoding: .utf8)

        let hash = try SHA256Hasher.hashFile(at: source)
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        try """
        mods\texample.jar\t\(size)\tsha256:\(hash)\tdownloads/releases/\(releaseID)/client-files/mods/example.jar
        """.write(to: releaseDir.appendingPathComponent("client-sync-manifest.tsv"), atomically: true, encoding: .utf8)
        try currentReleaseJSON(releaseID: releaseID)
            .write(to: site.appendingPathComponent("downloads/current-release.json"), atomically: true, encoding: .utf8)

        let server = try LocalHTTPServer(root: site)
        try server.start()
        defer { server.stop() }

        let service = ClientStatusService(configuration: ClientStatusConfiguration(
            serverURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            minecraftDirectory: minecraft,
            pummelchenHome: home,
            databaseURL: home.appendingPathComponent("client.duckdb")
        ))

        let healthy = await service.check()
        #expect(healthy.state == .synced)
        #expect(healthy.errorMessage == nil)

        try "corrupt".write(to: installed, atomically: true, encoding: .utf8)
        let corrupt = await service.check()
        #expect(corrupt.state == .repairNeeded)
        #expect(corrupt.errorMessage?.contains("missing or corrupt") == true)
    }

    private func currentReleaseJSON(releaseID: String) -> String {
        """
        {
          "release_id": "\(releaseID)",
          "created_at": "2026-06-13T00:00:00+00:00",
          "activated_at": "2026-06-13T00:00:00+00:00",
          "status": "tested",
          "minecraft_version": "26.1.2",
          "loader_version": "26.1.2.76",
          "server_key": "minecraft_26_1_2",
          "manifest_url": "/downloads/releases/\(releaseID)/client-sync-manifest.tsv",
          "client_zip_url": "/downloads/releases/\(releaseID)/client.zip",
          "client_zip_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "mrpack_url": "/downloads/releases/\(releaseID)/pack.mrpack",
          "mrpack_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "notes": "test"
        }
        """
    }
}
