import Foundation
import Testing
@testable import PummelchenCore

@Suite("Minecraft client defaults")
struct MinecraftClientDefaultsTests {
    @Test("applies visual and config defaults idempotently")
    func appliesDefaultsIdempotently() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-minecraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let options = root.appendingPathComponent("options.txt")
        try """
        resourcePacks:["vanilla","file/Old Pack"]
        incompatibleResourcePacks:["file/Old Pack"]
        resourcePacks:["duplicate"]
        simulationDistance:5
        """.write(to: options, atomically: true, encoding: .utf8)

        let managedJava = "/tmp/pummelchen-test/java/temurin-25.0.3+9/Contents/Home/bin/java"
        let highMemoryJavaArguments = MinecraftClientDefaults.recommendedJavaArguments(physicalMemoryBytes: 16 * 1024 * 1024 * 1024)
        try MinecraftClientDefaultWriter.apply(defaults: MinecraftClientDefaults(javaArguments: highMemoryJavaArguments, javaExecutablePath: managedJava), to: root)
        try MinecraftClientDefaultWriter.apply(defaults: MinecraftClientDefaults(javaArguments: highMemoryJavaArguments, javaExecutablePath: managedJava), to: root)

        let optionsText = try String(contentsOf: options, encoding: .utf8)
        #expect(optionsText.contains(#"resourcePacks:["vanilla","mod_resources","file/ModernArch v2.8.2 [26.1] [128x].zip","file/ModernArch FA Extension v2.2.zip","file/ModernArch Denser Grass Addon.zip"]"#))
        #expect(optionsText.contains("incompatibleResourcePacks:[]"))
        #expect(optionsText.contains("simulationDistance:5"))
        #expect(optionsText.components(separatedBy: "resourcePacks:").count == 2)

        let iris = try String(contentsOf: root.appendingPathComponent("config/iris.properties"), encoding: .utf8)
        #expect(iris.contains("shaderPack=BSL_v10.1.3.zip"))
        #expect(iris.contains("enableShaders=true"))
        #expect(iris.contains("maxShadowRenderDistance=32"))

        let shaderOptions = try String(contentsOf: root.appendingPathComponent("optionsshaders.txt"), encoding: .utf8)
        #expect(shaderOptions.contains("shaderPack=BSL_v10.1.3.zip"))

        let ducks = try String(contentsOf: root.appendingPathComponent("config/untitledduckmod-server.toml"), encoding: .utf8)
        #expect(ducks.contains("duck_tamed_no_follow=true"))
        #expect(ducks.contains("goose_tamed_no_follow=true"))

        let physicsConfig = try Data(contentsOf: root.appendingPathComponent("config/physicsmod/physics_client_config.json"))
        let physicsRoot = try #require(JSONSerialization.jsonObject(with: physicsConfig) as? [String: Any])
        let mobSettings = try #require(physicsRoot["mobSettings"] as? [String: Any])
        #expect(mobSettings["Physics Type"] as? Int == 3)
        #expect(physicsRoot["jointBlood"] as? Double == 1.0)

        let profiles = try String(contentsOf: root.appendingPathComponent("launcher_profiles.json"), encoding: .utf8)
        #expect(profiles.contains("-Xmx8G"))
        #expect(profiles.contains("neoforge-26.1.2.76"))
        #expect(profiles.contains(managedJava) || profiles.contains(managedJava.replacingOccurrences(of: "/", with: "\\/")))

        let servers = try Data(contentsOf: root.appendingPathComponent("servers.dat"))
        #expect(servers.range(of: Data("91.99.176.243:25565".utf8)) != nil)
        #expect(servers.occurrences(of: Data("91.99.176.243:25565".utf8)) == 1)

        let otherDefaults = MinecraftClientDefaults(serverName: "Other Server", serverAddress: "example.org:25565")
        let otherRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-minecraft-servers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        try MinecraftClientDefaultWriter.apply(defaults: otherDefaults, to: otherRoot)
        try MinecraftClientDefaultWriter.apply(to: otherRoot)
        let mergedServers = try Data(contentsOf: otherRoot.appendingPathComponent("servers.dat"))
        #expect(mergedServers.range(of: Data("example.org:25565".utf8)) != nil)
        #expect(mergedServers.range(of: Data("91.99.176.243:25565".utf8)) != nil)

        let existingPummelchenRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-minecraft-existing-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existingPummelchenRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existingPummelchenRoot) }
        try MinecraftClientDefaultWriter.apply(
            defaults: MinecraftClientDefaults(serverName: "Already Added", serverAddress: "91.99.176.243:25565"),
            to: existingPummelchenRoot
        )
        try MinecraftClientDefaultWriter.apply(to: existingPummelchenRoot)
        let existingPummelchenServers = try Data(contentsOf: existingPummelchenRoot.appendingPathComponent("servers.dat"))
        #expect(existingPummelchenServers.occurrences(of: Data("91.99.176.243:25565".utf8)) == 1)

        let defaultPortRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-minecraft-default-port-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultPortRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: defaultPortRoot) }
        try MinecraftClientDefaultWriter.apply(
            defaults: MinecraftClientDefaults(serverName: "Pummelchen", serverAddress: "91.99.176.243"),
            to: defaultPortRoot
        )
        try MinecraftClientDefaultWriter.apply(to: defaultPortRoot)
        let defaultPortServers = try Data(contentsOf: defaultPortRoot.appendingPathComponent("servers.dat"))
        #expect(defaultPortServers.occurrences(of: Data("91.99.176.243".utf8)) == 1)
    }

    @Test("uses 6 GB heap on 8 GB Macs and 8 GB heap otherwise")
    func adaptsHeapToPhysicalMemory() throws {
        let eightGB = UInt64(8 * 1024 * 1024 * 1024)
        let sixteenGB = UInt64(16 * 1024 * 1024 * 1024)
        #expect(MinecraftClientDefaults.recommendedHeapGB(physicalMemoryBytes: eightGB) == 6)
        #expect(MinecraftClientDefaults.recommendedJavaArguments(physicalMemoryBytes: eightGB).contains("-Xmx6G"))
        #expect(MinecraftClientDefaults.recommendedHeapGB(physicalMemoryBytes: sixteenGB) == 8)
        #expect(MinecraftClientDefaults.recommendedJavaArguments(physicalMemoryBytes: sixteenGB).contains("-Xmx8G"))
    }
}

private extension Data {
    func occurrences(of needle: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while searchStart < endIndex, let range = self[searchStart..<endIndex].range(of: needle) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
