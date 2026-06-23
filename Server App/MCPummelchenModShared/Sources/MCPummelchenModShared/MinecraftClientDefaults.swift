import Foundation

public struct MinecraftSupportedServer: Codable, Equatable, Sendable {
    public let minecraftVersion: String
    public let loader: String
    public let loaderVersion: String
    public let serverName: String
    public let serverAddress: String
    public let isLive: Bool
    public let status: String
    public let installerName: String?
    public let installerSHA256: String?
    public let installerURL: String?

    enum CodingKeys: String, CodingKey {
        case minecraftVersion = "minecraft_version"
        case loader
        case loaderVersion = "loader_version"
        case serverName = "server_name"
        case serverAddress = "server_address"
        case isLive = "is_live"
        case status
        case installerName = "installer_name"
        case installerSHA256 = "installer_sha256"
        case installerURL = "installer_url"
    }

    public init(
        minecraftVersion: String,
        loader: String = "neoforge",
        loaderVersion: String,
        serverName: String? = nil,
        serverAddress: String,
        isLive: Bool = false,
        status: String? = nil,
        installerName: String? = nil,
        installerSHA256: String? = nil,
        installerURL: String? = nil
    ) {
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.loaderVersion = loaderVersion
        self.serverName = serverName ?? "Pummelchen Server \(minecraftVersion)"
        self.serverAddress = serverAddress
        self.isLive = isLive
        self.status = status ?? (isLive ? "live" : "staging")
        self.installerName = installerName
        self.installerSHA256 = installerSHA256
        self.installerURL = installerURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minecraftVersion = try container.decode(String.self, forKey: .minecraftVersion)
        let loader = try container.decodeIfPresent(String.self, forKey: .loader) ?? "neoforge"
        let loaderVersion = try container.decode(String.self, forKey: .loaderVersion)
        let serverName = try container.decodeIfPresent(String.self, forKey: .serverName)
        let serverAddress = try container.decode(String.self, forKey: .serverAddress)
        let isLive = try container.decodeIfPresent(Bool.self, forKey: .isLive) ?? false
        let status = try container.decodeIfPresent(String.self, forKey: .status)
        self.init(
            minecraftVersion: minecraftVersion,
            loader: loader,
            loaderVersion: loaderVersion,
            serverName: serverName,
            serverAddress: serverAddress,
            isLive: isLive,
            status: status,
            installerName: try container.decodeIfPresent(String.self, forKey: .installerName),
            installerSHA256: try container.decodeIfPresent(String.self, forKey: .installerSHA256),
            installerURL: try container.decodeIfPresent(String.self, forKey: .installerURL)
        )
    }
}

public struct MinecraftSupportedServersResponse: Codable, Equatable, Sendable {
    public let apiVersion: String?
    public let generatedAt: String?
    public let versions: [MinecraftSupportedServer]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case generatedAt = "generated_at"
        case versions
    }

    public init(apiVersion: String? = nil, generatedAt: String? = nil, versions: [MinecraftSupportedServer]) {
        self.apiVersion = apiVersion
        self.generatedAt = generatedAt
        self.versions = versions
    }
}

public struct MinecraftClientDefaults: Equatable, Sendable {
    public let shaderPack: String
    public let resourcePacks: [String]
    public let javaArguments: String
    public let javaExecutablePath: String?
    public let loaderVersion: String
    public let serverName: String
    public let serverAddress: String
    public let supportedServers: [MinecraftSupportedServer]
    public let irisProperties: [String: String]
    public let configProperties: [String: [String: String]]
    public let physicsMobType: Int

    public static let defaultSupportedServers: [MinecraftSupportedServer] = [
        MinecraftSupportedServer(
            minecraftVersion: "26.1.2",
            loaderVersion: "26.1.2.76",
            serverAddress: "91.99.176.243:25565",
            isLive: true,
            installerName: "neoforge-26.1.2.76-installer.jar",
            installerSHA256: "f67bf87ddf8f3095ddbae4c78dbbbf5615e08b6982f4e84159eab951235974ec",
            installerURL: "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.2.76/neoforge-26.1.2.76-installer.jar"
        ),
        MinecraftSupportedServer(
            minecraftVersion: "26.2",
            loaderVersion: "26.2.0.3-beta",
            serverAddress: "91.99.176.243:25566",
            isLive: false,
            installerName: "neoforge-26.2.0.3-beta-installer.jar",
            installerSHA256: "90fad51778895f921182d6685719cba8a6d8caff69974d721bbdef750fe34c24",
            installerURL: "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.2.0.3-beta/neoforge-26.2.0.3-beta-installer.jar"
        )
    ]

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
        serverName: String = "Pummelchen Server 26.1.2",
        serverAddress: String = "91.99.176.243:25565",
        supportedServers: [MinecraftSupportedServer] = MinecraftClientDefaults.defaultSupportedServers,
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
        self.supportedServers = Self.effectiveSupportedServers(
            supplied: supportedServers,
            serverName: serverName,
            serverAddress: serverAddress,
            loaderVersion: loaderVersion
        )
        self.irisProperties = irisProperties
        self.configProperties = configProperties
        self.physicsMobType = physicsMobType
    }

    private static func effectiveSupportedServers(
        supplied: [MinecraftSupportedServer],
        serverName: String,
        serverAddress: String,
        loaderVersion: String
    ) -> [MinecraftSupportedServer] {
        let customServerWasRequested = serverName != "Pummelchen Server 26.1.2" || serverAddress != "91.99.176.243:25565"
        guard customServerWasRequested else {
            return supplied
        }

        let custom = MinecraftSupportedServer(
            minecraftVersion: minecraftVersion(fromLoaderVersion: loaderVersion),
            loaderVersion: loaderVersion,
            serverName: serverName,
            serverAddress: serverAddress,
            isLive: true
        )
        return [custom] + supplied.filter { normalizedServerAddress($0.serverAddress) != normalizedServerAddress(serverAddress) }
    }

    private static func minecraftVersion(fromLoaderVersion loaderVersion: String) -> String {
        let parts = loaderVersion.split(separator: ".")
        guard parts.count >= 2 else { return loaderVersion }
        if parts.count >= 3, parts[0] == "26", parts[1] == "1" {
            return "26.1.2"
        }
        return "\(parts[0]).\(parts[1])"
    }

    private static func normalizedServerAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains(":") ? trimmed : "\(trimmed):25565"
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
        try setLauncherProfiles(defaults: defaults, minecraftDirectory: minecraftDirectory)
        try ensureServerEntries(defaults: defaults, minecraftDirectory: minecraftDirectory)
    }

    public static func applyServerEntries(defaults: MinecraftClientDefaults = MinecraftClientDefaults(), to minecraftDirectory: URL) throws {
        try setLauncherProfiles(defaults: defaults, minecraftDirectory: minecraftDirectory)
        try ensureServerEntries(defaults: defaults, minecraftDirectory: minecraftDirectory)
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

    private static func setLauncherProfiles(defaults: MinecraftClientDefaults, minecraftDirectory: URL) throws {
        let path = minecraftDirectory.appendingPathComponent("launcher_profiles.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var profiles = root["profiles"] as? [String: Any] ?? [:]

        for server in defaults.supportedServers {
            profiles[launcherProfileID(for: server)] = launcherProfile(defaults: defaults, server: server, existing: profiles[launcherProfileID(for: server)] as? [String: Any])
        }

        if let liveServer = defaults.supportedServers.first(where: { $0.isLive }) ?? defaults.supportedServers.first {
            profiles["NeoForge"] = launcherProfile(defaults: defaults, server: liveServer, existing: profiles["NeoForge"] as? [String: Any], name: "NeoForge")
        }

        root["profiles"] = profiles
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path, options: .atomic)
    }

    private static func launcherProfileID(for server: MinecraftSupportedServer) -> String {
        "Pummelchen-\(server.minecraftVersion)"
    }

    private static func launcherProfile(
        defaults: MinecraftClientDefaults,
        server: MinecraftSupportedServer,
        existing: [String: Any]?,
        name: String? = nil
    ) -> [String: Any] {
        var profile = existing ?? [:]
        profile["name"] = name ?? server.serverName
        profile["type"] = "custom"
        profile["lastVersionId"] = "neoforge-\(server.loaderVersion)"
        profile["javaArgs"] = defaults.javaArguments
        if let javaExecutablePath = defaults.javaExecutablePath, !javaExecutablePath.isEmpty {
            profile["javaDir"] = javaExecutablePath
        }
        return profile
    }

    private static func ensureServerEntries(defaults: MinecraftClientDefaults, minecraftDirectory: URL) throws {
        let path = minecraftDirectory.appendingPathComponent("servers.dat")
        let existing = try? Data(contentsOf: path)
        let normalizedExisting = try existing?.renamingServers(defaults.supportedServers)
        let source = normalizedExisting ?? existing
        let missingServers = defaults.supportedServers.filter { server in
            guard let source else { return true }
            return (try? source.hasServerAddress(server.serverAddress)) != true
        }
        guard normalizedExisting != existing || !missingServers.isEmpty else { return }

        if FileManager.default.fileExists(atPath: path.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            try FileManager.default.copyItem(
                at: path,
                to: path.deletingLastPathComponent().appendingPathComponent("servers.dat.pummelchen-backup-\(stamp)")
            )
        }

        if let source {
            var updated = source
            for server in missingServers {
                updated = try updated.appendingServerEntry(name: server.serverName, address: server.serverAddress)
            }
            try updated.write(to: path, options: .atomic)
        } else {
            try Self.singleServerFile(servers: defaults.supportedServers).write(to: path, options: .atomic)
        }
    }

    private static func singleServerFile(servers: [MinecraftSupportedServer]) -> Data {
        var data = Data()
        data.append(10)
        data.appendUTF("")
        data.append(9)
        data.appendUTF("servers")
        data.append(10)
        data.appendInt32(Int32(servers.count))
        for server in servers {
            data.appendServerCompound(name: server.serverName, address: server.serverAddress)
        }
        data.append(0)
        return data
    }
}

public struct MinecraftServerDefaults: Equatable, Sendable {
    public let physicsCollapseEnabled: Bool
    public let gameMode: String
    public let difficulty: String
    public let forceGameMode: Bool
    public let hardcore: Bool

    public init(
        physicsCollapseEnabled: Bool = false,
        gameMode: String = "creative",
        difficulty: String = "hard",
        forceGameMode: Bool = false,
        hardcore: Bool = false
    ) {
        self.physicsCollapseEnabled = physicsCollapseEnabled
        self.gameMode = gameMode
        self.difficulty = difficulty
        self.forceGameMode = forceGameMode
        self.hardcore = hardcore
    }
}

public enum MinecraftServerDefaultWriter {
    public static func apply(defaults: MinecraftServerDefaults = MinecraftServerDefaults(), to serverDirectory: URL) throws {
        try setServerPropertiesDefaults(defaults, serverDirectory: serverDirectory)
        try setPhysicsServerDefaults(defaults, serverDirectory: serverDirectory)
    }

    private static func setServerPropertiesDefaults(_ defaults: MinecraftServerDefaults, serverDirectory: URL) throws {
        let path = serverDirectory.appendingPathComponent("server.properties")
        var values = readProperties(path)
        values["gamemode"] = defaults.gameMode
        values["difficulty"] = defaults.difficulty
        values["force-gamemode"] = defaults.forceGameMode ? "true" : "false"
        values["hardcore"] = defaults.hardcore ? "true" : "false"
        try writeProperties(values, to: path)
    }

    private static func setPhysicsServerDefaults(_ defaults: MinecraftServerDefaults, serverDirectory: URL) throws {
        let path = serverDirectory.appendingPathComponent("config/physicsmod/physics_server_config.json")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        root["collapse"] = defaults.physicsCollapseEnabled
        if root["collapseSpeed"] == nil {
            root["collapseSpeed"] = 10
        }
        if root["dropBlocks"] == nil {
            root["dropBlocks"] = true
        }
        if root["maxCollapseObjects"] == nil {
            root["maxCollapseObjects"] = 100
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    private static func readProperties(_ path: URL) -> [String: String] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return [:]
        }
        var values: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else {
                continue
            }
            let key = String(line[..<equal]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }

    private static func writeProperties(_ values: [String: String], to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preferredOrder = ["gamemode", "difficulty", "force-gamemode", "hardcore"]
        var lines: [String] = []
        for key in preferredOrder {
            if let value = values[key] {
                lines.append("\(key)=\(value)")
            }
        }
        for key in values.keys.sorted() where !preferredOrder.contains(key) {
            lines.append("\(key)=\(values[key] ?? "")")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
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

    func renamingServers(_ servers: [MinecraftSupportedServer]) throws -> Data {
        var updated = self
        for server in servers {
            updated = try updated.renamingServer(address: server.serverAddress, to: server.serverName)
        }
        return updated
    }

    private func renamingServer(address: String, to desiredName: String) throws -> Data {
        let normalizedTarget = Self.normalizedServerAddress(address)
        let (_, serverCount, afterCountOffset) = try serversListHeader()
        var cursor = afterCountOffset
        for _ in 0..<serverCount {
            let entry = try readServerEntryMetadata(cursor: &cursor)
            guard let ip = entry.ip, Self.normalizedServerAddress(ip) == normalizedTarget else {
                continue
            }
            guard let nameRange = entry.nameRange, entry.name != desiredName else {
                return self
            }
            var replacement = Data()
            replacement.appendUTF(desiredName)
            var updated = self
            updated.replaceSubrange(nameRange, with: replacement)
            return updated
        }
        return self
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

    private func readServerEntryMetadata(cursor: inout Int) throws -> (name: String?, ip: String?, nameRange: Range<Int>?) {
        var nameValue: String?
        var ipValue: String?
        var nameRange: Range<Int>?
        while cursor < count {
            let type = self[cursor]
            cursor += 1
            if type == 0 {
                return (nameValue, ipValue, nameRange)
            }
            let tagName = try readUTF(cursor: &cursor)
            if type == 8 {
                let valueStart = cursor
                let value = try readUTF(cursor: &cursor)
                if tagName == "name" {
                    nameValue = value
                    nameRange = valueStart..<cursor
                } else if tagName == "ip" {
                    ipValue = value
                }
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
