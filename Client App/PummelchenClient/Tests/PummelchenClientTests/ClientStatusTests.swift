import Foundation
import Testing
@testable import PummelchenClientCore

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
        try #"{"profiles":{"NeoForge":{"javaArgs":"-Xmx8G -XX:+UseG1GC"}}}"#
            .write(to: root.appendingPathComponent("launcher_profiles.json"), atomically: true, encoding: .utf8)
        try "Pummelchen 91.99.176.243:25565".write(to: root.appendingPathComponent("servers.dat"), atomically: true, encoding: .utf8)
        try "showLoadWarnings=false\n".write(to: root.appendingPathComponent("config/neoforge-client.toml"), atomically: true, encoding: .utf8)
        try "showLoadWarnings=false\n".write(to: root.appendingPathComponent("config/forge-client.toml"), atomically: true, encoding: .utf8)
        try "showCheckScreen=false\n".write(to: root.appendingPathComponent("config/yuushya-client.toml"), atomically: true, encoding: .utf8)
        try "duck_tamed_no_follow=true\ngoose_tamed_no_follow=true\n".write(to: root.appendingPathComponent("config/untitledduckmod-server.toml"), atomically: true, encoding: .utf8)

        let rows = ClientDefaultsInspector.inspect(minecraftDirectory: root)
        #expect(rows.allSatisfy { $0.status == .ok })
        #expect(rows.contains { $0.id == "shader" })
        #expect(rows.contains { $0.id == "memory" })
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
}
