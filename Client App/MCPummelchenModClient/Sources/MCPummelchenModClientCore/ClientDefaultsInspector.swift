import Foundation
import MCPummelchenModShared

public enum ClientDefaultStatus: String, Codable, Equatable, Sendable {
    case pass
    case fail
    case missing
    case fixedOK = "fixed_ok"
    case fixedFailed = "fixed_failed"
    case repairing
    case testing

    public var isHealthy: Bool {
        switch self {
        case .pass, .fixedOK, .testing:
            return true
        case .missing, .fail, .fixedFailed, .repairing:
            return false
        }
    }

    public var needsRepair: Bool {
        switch self {
        case .fail, .missing, .fixedFailed:
            return true
        case .pass, .fixedOK, .repairing, .testing:
            return false
        }
    }

    public var recommendedAction: String {
        switch self {
        case .pass:
            return "No action"
        case .testing:
            return "Verify file access"
        case .repairing:
            return "Repairing"
        case .fixedOK:
            return "Auto repair succeeded"
        case .fixedFailed:
            return "Auto repair failed"
        case .missing:
            return "Create missing value"
        case .fail:
            return "Align value to managed default"
        }
    }

    public var isActionable: Bool {
        return needsRepair
    }

    public var displayValue: String {
        switch self {
        case .fixedOK:
            return "FIXED OK"
        case .fixedFailed:
            return "FIXED FAILED"
        case .testing:
            return "TESTING"
        default:
            return rawValue.uppercased().replacingOccurrences(of: "_", with: " ")
        }
    }
}

public struct ClientDefaultHealthRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let desiredValue: String
    public let observedValue: String
    public let status: ClientDefaultStatus
    public let source: String
    public let recommendedAction: String

    public init(
        id: String,
        label: String,
        desiredValue: String,
        observedValue: String,
        status: ClientDefaultStatus,
        source: String,
        recommendedAction: String
    ) {
        self.id = id
        self.label = label
        self.desiredValue = desiredValue
        self.observedValue = observedValue
        self.status = status
        self.source = source
        self.recommendedAction = recommendedAction
    }
}

public enum ClientDefaultsInspector {

    private static let defaultJavaVersion = "25.0.3"

    public static func inspect(minecraftDirectory: URL, defaults: MinecraftClientDefaults = MinecraftClientDefaults()) -> [ClientDefaultHealthRow] {
        let options = readText(minecraftDirectory.appendingPathComponent("options.txt"))
        let iris = readText(minecraftDirectory.appendingPathComponent("config/iris.properties"))
        let shaderOptions = readText(minecraftDirectory.appendingPathComponent("optionsshaders.txt"))
        let launcherProfiles = readText(minecraftDirectory.appendingPathComponent("launcher_profiles.json"))
        let servers = readServerList(minecraftDirectory.appendingPathComponent("servers.dat"))

        var rows: [ClientDefaultHealthRow] = []
        rows.append(shaderHealth(defaults: defaults, iris: iris, shaderOptions: shaderOptions))
        rows.append(resourcePackHealth(defaults: defaults, options: options))
        rows.append(memoryHealth(defaults: defaults, launcherProfiles: launcherProfiles))
        rows.append(javaHealth(defaults: defaults, launcherProfiles: launcherProfiles))
        rows.append(serverEntryHealth(defaults: defaults, servers: servers))
        rows.append(physicsMobFracturingHealth(defaults: defaults, minecraftDirectory: minecraftDirectory))
        rows.append(contentsOf: configHealth(defaults: defaults, minecraftDirectory: minecraftDirectory))
        return rows
    }

    private static func shaderHealth(defaults: MinecraftClientDefaults, iris: String?, shaderOptions: String?) -> ClientDefaultHealthRow {
        let observed = firstProperty("shaderPack", in: iris) ?? firstProperty("shaderPack", in: shaderOptions)
        let enabled = firstProperty("enableShaders", in: iris)
        let observedPack = normalizeShaderName(observed)
        let desiredPack = normalizeShaderName(defaults.shaderPack)
        let ok = observedPack == desiredPack && (enabled == nil || enabled == "true")
        return ClientDefaultHealthRow(
            id: "shader",
            label: "Shaders",
            desiredValue: desiredPack ?? defaults.shaderPack,
            observedValue: ok ? "OK" : (observedPack ?? "missing"),
            status: observed == nil ? .missing : (ok ? .pass : .fail),
            source: "config/iris.properties",
            recommendedAction: "Apply managed shader defaults"
        )
    }

    private static func resourcePackHealth(defaults: MinecraftClientDefaults, options: String?) -> ClientDefaultHealthRow {
        guard let options else {
            return ClientDefaultHealthRow(
                id: "resource_packs",
                label: "Resource Packs",
                desiredValue: defaults.resourcePacks.map(humanResourcePackName).joined(separator: " > "),
                observedValue: "missing",
                status: .missing,
                source: "options.txt",
                recommendedAction: "Rewrite managed resource pack list"
            )
        }
        let resourceLine = firstColonValue("resourcePacks", in: options) ?? ""
        let observedPacks = parseArray(resourceLine)
        let normalizedObserved = observedPacks.map(humanResourcePackName)
        let normalizedDefaults = defaults.resourcePacks.map(humanResourcePackName)
        let incompatibleLine = firstColonValue("incompatibleResourcePacks", in: options) ?? ""
        let hasAllPacks = normalizedDefaults.allSatisfy { normalizedObserved.contains($0) }
        let ordered = isOrdered(normalizedDefaults, valuesIn: normalizedObserved)
        let incompatibleCleared = incompatibleLine.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" || incompatibleLine.isEmpty
        return ClientDefaultHealthRow(
            id: "resource_packs",
            label: "Resource Packs",
            desiredValue: normalizedDefaults.joined(separator: " > "),
            observedValue: (hasAllPacks && ordered && incompatibleCleared) ? "OK" : normalizedObserved.joined(separator: " > "),
            status: hasAllPacks && ordered && incompatibleCleared ? .pass : (resourceLine.isEmpty ? .missing : .fail),
            source: "options.txt",
            recommendedAction: "Rewrite managed resource pack list"
        )
    }

    private static func memoryHealth(defaults: MinecraftClientDefaults, launcherProfiles: String?) -> ClientDefaultHealthRow {
        let desiredHeap = maxHeapArgument(in: defaults.javaArguments) ?? "-Xmx8G"
        let desiredGB = heapGB(from: desiredHeap) ?? 8
        guard let launcherProfiles, !launcherProfiles.isEmpty else {
        return ClientDefaultHealthRow(
            id: "memory",
            label: "Memory",
            desiredValue: desiredHeap,
            observedValue: "launcher profile missing",
            status: .missing,
            source: "launcher_profiles.json",
            recommendedAction: "Apply managed JVM arguments"
        )
    }
        let observedHeap = maxHeapArgument(in: launcherProfiles)
        let ok = observedHeap.flatMap(heapGB(from:)) == desiredGB
        return ClientDefaultHealthRow(
            id: "memory",
            label: "Memory",
            desiredValue: desiredHeap,
            observedValue: observedHeap.map { "\(heapGB(from: $0) ?? 0) GB configured" } ?? "\(desiredGB) GB not found",
            status: ok ? .pass : .fail,
            source: "launcher_profiles.json",
            recommendedAction: "Apply managed JVM arguments"
        )
    }

    private static func maxHeapArgument(in text: String) -> String? {
        let pattern = #"-Xmx([0-9]+)([GgMm])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let argumentRange = Range(match.range(at: 0), in: text) else {
            return nil
        }
        return String(text[argumentRange])
    }

    private static func heapGB(from argument: String) -> Int? {
        let value = argument.replacingOccurrences(of: "-Xmx", with: "")
        let uppercased = value.uppercased()
        if uppercased.hasSuffix("G") {
            return Int(value.dropLast())
        }
        if uppercased.hasSuffix("M"),
           let megabytes = Int(value.dropLast()) {
            return megabytes / 1024
        }
        return nil
    }

    private static func javaHealth(defaults: MinecraftClientDefaults, launcherProfiles: String?) -> ClientDefaultHealthRow {
        let requiredVersion = defaults.javaExecutablePath.flatMap(javaVersionFromPath) ?? defaultJavaVersion

        guard defaults.javaExecutablePath != nil else {
        return ClientDefaultHealthRow(
            id: "java_runtime",
            label: "Java Runtime",
            desiredValue: requiredVersion,
            observedValue: "not managed in this check",
            status: .testing,
            source: "launcher_profiles.json",
            recommendedAction: "Manage Java runtime via installer"
        )
    }
        guard let launcherProfiles, !launcherProfiles.isEmpty else {
        return ClientDefaultHealthRow(
            id: "java_runtime",
            label: "Java Runtime",
            desiredValue: requiredVersion,
            observedValue: "launcher profile missing",
            status: .missing,
            source: "launcher_profiles.json",
            recommendedAction: "Create managed launcher profile"
        )
    }

        let observedPath = extractJavaPath(from: launcherProfiles)
        let observedVersion = observedPath.flatMap(javaVersionFromPath) ?? "unknown"
        let observedVersionMatch = observedVersion == requiredVersion
        let ok = observedPath != nil && observedVersionMatch
        return ClientDefaultHealthRow(
            id: "java_runtime",
            label: "Java Runtime",
            desiredValue: requiredVersion,
            observedValue: observedVersion,
            status: ok ? .pass : (observedPath == nil ? .missing : .fail),
            source: "launcher_profiles.json",
            recommendedAction: "Repair Java runtime path and version"
        )
    }

    private static func serverEntryHealth(defaults: MinecraftClientDefaults, servers: String?) -> ClientDefaultHealthRow {
        let desiredServers = defaults.supportedServers
        let desiredValue = desiredServers
            .map { "\($0.serverName) (\($0.serverAddress))" }
            .joined(separator: " | ")

        guard let servers, !servers.isEmpty else {
        return ClientDefaultHealthRow(
            id: "server_entry",
            label: "Server Entries",
            desiredValue: desiredValue,
            observedValue: "servers.dat missing",
            status: .missing,
            source: "servers.dat",
            recommendedAction: "Add managed server entries"
        )
    }
        let missing = desiredServers.filter { server in
            !servers.contains(server.serverAddress) && !servers.localizedCaseInsensitiveContains(server.serverName)
        }
        let ok = missing.isEmpty
        return ClientDefaultHealthRow(
            id: "server_entry",
            label: "Server Entries",
            desiredValue: desiredValue,
            observedValue: ok ? "Pummelchen Servers Ready" : "Missing: \(missing.map(\.serverName).joined(separator: ", "))",
            status: ok ? .pass : .fail,
            source: "servers.dat",
            recommendedAction: "Add managed server entries"
        )
    }

    private static func physicsMobFracturingHealth(defaults: MinecraftClientDefaults, minecraftDirectory: URL) -> ClientDefaultHealthRow {
        let relativePath = "config/physicsmod/physics_client_config.json"
        let path = minecraftDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mobSettings = root["mobSettings"] as? [String: Any] else {
            return ClientDefaultHealthRow(
                id: "physics_mob_fracturing",
                label: "Physics Mob Fracturing",
                desiredValue: "Mob Fracturing (with blood)",
                observedValue: "missing",
                status: .missing,
                source: relativePath,
                recommendedAction: "Apply managed Physics mob settings"
            )
        }

        let observedType = mobSettings["Physics Type"] as? Int
            ?? (mobSettings["Physics Type"] as? NSNumber)?.intValue
        return ClientDefaultHealthRow(
            id: "physics_mob_fracturing",
            label: "Physics Mob Fracturing",
            desiredValue: "Mob Fracturing (with blood)",
            observedValue: observedType.map(physicsMobTypeDescription) ?? "missing",
            status: observedType == defaults.physicsMobType ? .pass : .fail,
            source: relativePath,
            recommendedAction: "Apply managed Physics mob settings"
        )
    }

    private static func physicsMobTypeDescription(_ value: Int) -> String {
        switch value {
        case 0:
            return "Ragdoll"
        case 1:
            return "Blocky"
        case 2:
            return "Mob Fracturing"
        case 3:
            return "Mob Fracturing (with blood)"
        case 4:
            return "Off"
        case 5:
            return "Main Rule"
        case 6:
            return "Ragdoll Breaking"
        case 7:
            return "Ragdoll Breaking (with blood)"
        default:
            return "unknown (\(value))"
        }
    }

    private static func configHealth(defaults: MinecraftClientDefaults, minecraftDirectory: URL) -> [ClientDefaultHealthRow] {
        defaults.configProperties.flatMap { relativePath, values in
            let text = readText(minecraftDirectory.appendingPathComponent(relativePath))
            return values.map { key, value in
                let observed = firstProperty(key, in: text)
                return ClientDefaultHealthRow(
                    id: "\(relativePath):\(key)",
                    label: key,
                    desiredValue: value,
                    observedValue: observed ?? "missing",
                    status: observed == nil ? .missing : (observed == value ? .pass : .fail),
                    source: relativePath,
                    recommendedAction: "Apply managed config key"
                )
            }
        }.sorted { $0.id < $1.id }
    }

    private static func extractJavaPath(from launcherProfiles: String) -> String? {
        let data = Data(launcherProfiles.utf8)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [String: Any] else {
            return nil
        }

        if let neoForge = profiles["NeoForge"] as? [String: Any],
           let value = neoForge["javaDir"] as? String,
           !value.isEmpty {
            return value
        }

        for (_, rawProfile) in profiles {
            if let profile = rawProfile as? [String: Any],
               let value = profile["javaDir"] as? String,
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func javaVersionFromPath(_ path: String) -> String? {
        if let match = extractJavaVersion(from: path) {
            let components = match.split(separator: "+")
            return String(components.first ?? "")
        }
        return nil
    }

    private static func extractJavaVersion(from text: String) -> String? {
        let pattern = #"\d+\.\d+\.\d+(?:\+\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchedRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchedRange])
    }

    private static func parseArray(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return trimmed
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                .filter { !$0.isEmpty }
        }
        return parsed
    }

    private static func readText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func readServerList(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func firstProperty(_ key: String, in text: String?) -> String? {
        guard let text else { return nil }
        let prefix = key + "="
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(prefix) else { return nil }
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            .first
    }

    private static func firstColonValue(_ key: String, in text: String) -> String? {
        let prefix = key + ":"
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(prefix) else { return nil }
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            .first
    }

    private static func isOrdered(_ values: [String], valuesIn observed: [String]) -> Bool {
        var searchStart = 0
        for value in values {
            guard let index = observed.indices(of: value, startingAt: searchStart).first else {
                return false
            }
            searchStart = index + 1
        }
        return true
    }

    private static func normalizeShaderName(_ shader: String?) -> String? {
        guard let shader else { return nil }
        return stripMinecraftPath(shader)
    }

    private static func humanResourcePackName(_ pack: String) -> String {
        stripMinecraftPath(pack)
    }

    private static func stripMinecraftPath(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        if unwrapped.hasPrefix("file/") {
            return String(unwrapped.dropFirst("file/".count))
        }
        return unwrapped
    }

}

private extension Array where Element == String {
    func indices(of target: String, startingAt: Int) -> [Int] {
        return enumerated().compactMap { index, item in
            index >= startingAt && item == target ? index : nil
        }
    }
}
