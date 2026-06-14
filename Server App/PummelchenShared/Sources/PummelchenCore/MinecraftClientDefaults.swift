import Foundation

public struct MinecraftClientDefaults: Equatable, Sendable {
    public let shaderPack: String
    public let resourcePacks: [String]
    public let javaArguments: String
    public let javaExecutablePath: String?
    public let loaderVersion: String
    public let serverName: String
    public let serverAddress: String
    public let irisProperties: [String: String]
    public let configProperties: [String: [String: String]]
    public let physicsMobType: Int

    public static func recommendedHeapGB(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let gib = UInt64(1024 * 1024 * 1024)
        let eightGBClassMac = physicalMemoryBytes <= (9 * gib)
        return eightGBClassMac ? 6 : 8
    }

    public static func recommendedJavaArguments(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        "-Xmx\(recommendedHeapGB(physicalMemoryBytes: physicalMemoryBytes))G -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1NewSizePercent=20 -XX:G1ReservePercent=20 -XX:MaxGCPauseMillis=50 -XX:G1HeapRegionSize=32M"
    }

    public init(
        shaderPack: String = "BSL_v10.1.3.zip",
        resourcePacks: [String] = [
            "vanilla",
            "mod_resources",
            "file/ModernArch v2.8.2 [26.1] [128x].zip",
            "file/ModernArch FA Extension v2.2.zip",
            "file/ModernArch Denser Grass Addon.zip"
        ],
        javaArguments: String = MinecraftClientDefaults.recommendedJavaArguments(),
        javaExecutablePath: String? = nil,
        loaderVersion: String = "26.1.2.76",
        serverName: String = "Pummelchen Server",
        serverAddress: String = "91.99.176.243:25565",
        irisProperties: [String: String] = [
            "shaderPack": "BSL_v10.1.3.zip",
            "enableShaders": "true",
            "allowUnknownShaders": "false",
            "colorSpace": "SRGB",
            "disableUpdateMessage": "false",
            "enableDebugOptions": "false",
            "maxShadowRenderDistance": "32"
        ],
        configProperties: [String: [String: String]] = [
            "config/neoforge-client.toml": ["showLoadWarnings": "false"],
            "config/forge-client.toml": ["showLoadWarnings": "false"],
            "config/yuushya-client.toml": ["showCheckScreen": "false"],
            "config/untitledduckmod-server.toml": [
                "duck_tamed_no_follow": "true",
                "goose_tamed_no_follow": "true"
            ]
        ],
        physicsMobType: Int = 3
    ) {
        self.shaderPack = shaderPack
        self.resourcePacks = resourcePacks
        self.javaArguments = javaArguments
        self.javaExecutablePath = javaExecutablePath
        self.loaderVersion = loaderVersion
        self.serverName = serverName
        self.serverAddress = serverAddress
        self.irisProperties = irisProperties
        self.configProperties = configProperties
        self.physicsMobType = physicsMobType
    }
}

public enum MinecraftClientDefaultWriter {
    public static func apply(defaults: MinecraftClientDefaults = MinecraftClientDefaults(), to minecraftDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: minecraftDirectory.appendingPathComponent("config"),
            withIntermediateDirectories: true
        )

        let resourcePackValue = minecraftStringArray(defaults.resourcePacks)
        try setColonValue(
            path: minecraftDirectory.appendingPathComponent("options.txt"),
            key: "resourcePacks",
            value: resourcePackValue
        )
        try setColonValue(
            path: minecraftDirectory.appendingPathComponent("options.txt"),
            key: "incompatibleResourcePacks",
            value: "[]"
        )
        try setEqualsValue(
            path: minecraftDirectory.appendingPathComponent("optionsshaders.txt"),
            key: "shaderPack",
            value: defaults.shaderPack
        )
        for (key, value) in defaults.irisProperties {
            try setEqualsValue(
                path: minecraftDirectory.appendingPathComponent("config/iris.properties"),
                key: key,
                value: value
            )
        }
        for (relativePath, values) in defaults.configProperties {
            for (key, value) in values {
                try setEqualsValue(
                    path: minecraftDirectory.appendingPathComponent(relativePath),
                    key: key,
                    value: value
                )
            }
        }
        try setPhysicsMobType(defaults.physicsMobType, minecraftDirectory: minecraftDirectory)
        try setLauncherProfile(defaults: defaults, minecraftDirectory: minecraftDirectory)
        try ensureServerEntry(defaults: defaults, minecraftDirectory: minecraftDirectory)
    }

    private static func setPhysicsMobType(_ mobType: Int, minecraftDirectory: URL) throws {
        let path = minecraftDirectory.appendingPathComponent("config/physicsmod/physics_client_config.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var mobSettings = root["mobSettings"] as? [String: Any] ?? [:]
        mobSettings["Physics Type"] = mobType
        root["mobSettings"] = mobSettings

        if root["jointBlood"] == nil {
            root["jointBlood"] = 1.0
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    private static func setColonValue(path: URL, key: String, value: String) throws {
        try setLine(path: path, key: key, separator: ":", value: value)
    }

    private static func setEqualsValue(path: URL, key: String, value: String) throws {
        try setLine(path: path, key: key, separator: "=", value: value)
    }

    private static func minecraftStringArray(_ values: [String]) -> String {
        "[\(values.map { "\"\(escapeMinecraftString($0))\"" }.joined(separator: ","))]"
    }

    private static func escapeMinecraftString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func setLine(path: URL, key: String, separator: String, value: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        let prefix = key + separator
        var replaced = false
        var output: [String] = []

        for line in existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) {
                if !replaced {
                    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
                    output.append("\(indent)\(key)\(separator)\(value)")
                    replaced = true
                }
            } else {
                output.append(line)
            }
        }
        if !replaced {
            output.append("\(key)\(separator)\(value)")
        }
        try output.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private static func setLauncherProfile(defaults: MinecraftClientDefaults, minecraftDirectory: URL) throws {
        let path = minecraftDirectory.appendingPathComponent("launcher_profiles.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var profiles = root["profiles"] as? [String: Any] ?? [:]
        var profile = profiles["NeoForge"] as? [String: Any] ?? [:]
        profile["name"] = "NeoForge"
        profile["type"] = "custom"
        profile["lastVersionId"] = "neoforge-\(defaults.loaderVersion)"
        profile["javaArgs"] = defaults.javaArguments
        if let javaExecutablePath = defaults.javaExecutablePath, !javaExecutablePath.isEmpty {
            profile["javaDir"] = javaExecutablePath
        }
        profiles["NeoForge"] = profile
        root["profiles"] = profiles
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    private static func ensureServerEntry(defaults: MinecraftClientDefaults, minecraftDirectory: URL) throws {
        let path = minecraftDirectory.appendingPathComponent("servers.dat")
        if let existing = try? Data(contentsOf: path), (try? existing.hasServerAddress(defaults.serverAddress)) == true {
            return
        }
        if FileManager.default.fileExists(atPath: path.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try FileManager.default.copyItem(
                at: path,
                to: path.deletingLastPathComponent().appendingPathComponent("servers.dat.pummelchen-backup-\(stamp)")
            )
        }
        if let existing = try? Data(contentsOf: path),
           let updated = try? existing.appendingServerEntry(name: defaults.serverName, address: defaults.serverAddress) {
            try updated.write(to: path, options: .atomic)
        } else {
            try Self.singleServerFile(name: defaults.serverName, address: defaults.serverAddress).write(to: path, options: .atomic)
        }
    }

    private static func singleServerFile(name: String, address: String) -> Data {
        var data = Data()
        data.append(10)
        data.appendUTF("")
        data.append(9)
        data.appendUTF("servers")
        data.append(10)
        data.appendInt32(1)
        data.appendServerCompound(name: name, address: address)
        data.append(0)
        return data
    }
}

private extension Data {
    mutating func appendUTF(_ value: String) {
        let bytes = Array(value.utf8)
        append(UInt8((bytes.count >> 8) & 0xff))
        append(UInt8(bytes.count & 0xff))
        append(contentsOf: bytes)
    }

    mutating func appendInt32(_ value: Int32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendServerCompound(name: String, address: String) {
        append(8)
        appendUTF("name")
        appendUTF(name)
        append(8)
        appendUTF("ip")
        appendUTF(address)
        append(1)
        appendUTF("acceptTextures")
        append(1)
        append(1)
        appendUTF("hideAddress")
        append(0)
        append(0)
    }

    func appendingServerEntry(name: String, address: String) throws -> Data {
        let (countOffset, serverCount, afterCountOffset) = try serversListHeader()
        var cursor = afterCountOffset
        for _ in 0..<serverCount {
            try skipCompoundPayload(cursor: &cursor)
        }
        var updated = self
        var entry = Data()
        entry.appendServerCompound(name: name, address: address)
        updated.replaceSubrange(cursor..<cursor, with: entry)
        updated.writeInt32(serverCount + 1, at: countOffset)
        return updated
    }

    func hasServerAddress(_ address: String) throws -> Bool {
        let normalizedTarget = Self.normalizedServerAddress(address)
        let (_, serverCount, afterCountOffset) = try serversListHeader()
        var cursor = afterCountOffset
        for _ in 0..<serverCount {
            let entry = try readServerEntry(cursor: &cursor)
            if let ip = entry["ip"], Self.normalizedServerAddress(ip) == normalizedTarget {
                return true
            }
        }
        return false
    }

    private func serversListHeader() throws -> (countOffset: Int, serverCount: Int32, afterCountOffset: Int) {
        let marker = Data([9, 0, 7]) + Data("servers".utf8) + Data([10])
        guard let markerRange = range(of: marker) else {
            throw ContractValidationError.invalid("servers.dat does not contain a servers list")
        }
        let countOffset = markerRange.upperBound
        guard countOffset + 4 <= count else {
            throw ContractValidationError.invalid("servers.dat has truncated servers count")
        }
        let serverCount = readInt32(at: countOffset)
        guard serverCount >= 0 else {
            throw ContractValidationError.invalid("servers.dat has negative servers count")
        }
        return (countOffset, serverCount, countOffset + 4)
    }

    private static func normalizedServerAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains(":") ? trimmed : "\(trimmed):25565"
    }

    private func readServerEntry(cursor: inout Int) throws -> [String: String] {
        var values: [String: String] = [:]
        while cursor < count {
            let type = self[cursor]
            cursor += 1
            if type == 0 {
                return values
            }
            let name = try readUTF(cursor: &cursor)
            if type == 8 {
                values[name] = try readUTF(cursor: &cursor)
            } else {
                try skipPayload(type: type, cursor: &cursor)
            }
        }
        throw ContractValidationError.invalid("unterminated server entry in servers.dat")
    }

    private func readInt32(at offset: Int) -> Int32 {
        let raw = UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
        return Int32(bitPattern: raw)
    }

    private mutating func writeInt32(_ value: Int32, at offset: Int) {
        self[offset] = UInt8((value >> 24) & 0xff)
        self[offset + 1] = UInt8((value >> 16) & 0xff)
        self[offset + 2] = UInt8((value >> 8) & 0xff)
        self[offset + 3] = UInt8(value & 0xff)
    }

    private func readUTF(cursor: inout Int) throws -> String {
        guard cursor + 2 <= count else {
            throw ContractValidationError.invalid("truncated UTF length in servers.dat")
        }
        let length = Int(self[cursor]) << 8 | Int(self[cursor + 1])
        cursor += 2
        guard cursor + length <= count else {
            throw ContractValidationError.invalid("truncated UTF value in servers.dat")
        }
        defer { cursor += length }
        return String(decoding: self[cursor..<(cursor + length)], as: UTF8.self)
    }

    private func skip(_ bytes: Int, cursor: inout Int) throws {
        guard bytes >= 0, cursor + bytes <= count else {
            throw ContractValidationError.invalid("truncated payload in servers.dat")
        }
        cursor += bytes
    }

    private func skipCompoundPayload(cursor: inout Int) throws {
        while cursor < count {
            let type = self[cursor]
            cursor += 1
            if type == 0 {
                return
            }
            _ = try readUTF(cursor: &cursor)
            try skipPayload(type: type, cursor: &cursor)
        }
        throw ContractValidationError.invalid("unterminated compound in servers.dat")
    }

    private func skipPayload(type: UInt8, cursor: inout Int) throws {
        switch type {
        case 1:
            try skip(1, cursor: &cursor)
        case 2:
            try skip(2, cursor: &cursor)
        case 3, 5:
            try skip(4, cursor: &cursor)
        case 4, 6:
            try skip(8, cursor: &cursor)
        case 7:
            guard cursor + 4 <= count else {
                throw ContractValidationError.invalid("truncated byte array length in servers.dat")
            }
            let length = Int(readInt32(at: cursor))
            cursor += 4
            guard length >= 0 else {
                throw ContractValidationError.invalid("negative byte array size in servers.dat")
            }
            try skip(length, cursor: &cursor)
        case 8:
            _ = try readUTF(cursor: &cursor)
        case 9:
            guard cursor + 5 <= count else {
                throw ContractValidationError.invalid("truncated list in servers.dat")
            }
            let child = self[cursor]
            cursor += 1
            let itemCount = readInt32(at: cursor)
            cursor += 4
            guard itemCount >= 0 else {
                throw ContractValidationError.invalid("negative list size in servers.dat")
            }
            for _ in 0..<itemCount {
                try skipPayload(type: child, cursor: &cursor)
            }
        case 10:
            try skipCompoundPayload(cursor: &cursor)
        case 11:
            guard cursor + 4 <= count else {
                throw ContractValidationError.invalid("truncated int array length in servers.dat")
            }
            let length = Int(readInt32(at: cursor))
            cursor += 4
            guard length >= 0 else {
                throw ContractValidationError.invalid("negative int array size in servers.dat")
            }
            try skip(length * 4, cursor: &cursor)
        case 12:
            guard cursor + 4 <= count else {
                throw ContractValidationError.invalid("truncated long array length in servers.dat")
            }
            let length = Int(readInt32(at: cursor))
            cursor += 4
            guard length >= 0 else {
                throw ContractValidationError.invalid("negative long array size in servers.dat")
            }
            try skip(length * 8, cursor: &cursor)
        default:
            throw ContractValidationError.invalid("unknown NBT tag in servers.dat: \(type)")
        }
    }
}
