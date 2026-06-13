import Foundation
import PummelchenCore

public enum ClientDefaultStatus: String, Codable, Equatable, Sendable {
    case ok
    case missing
    case mismatch
    case unknown
}

public struct ClientDefaultHealthRow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let desiredValue: String
    public let observedValue: String
    public let status: ClientDefaultStatus
    public let source: String

    public init(
        id: String,
        label: String,
        desiredValue: String,
        observedValue: String,
        status: ClientDefaultStatus,
        source: String
    ) {
        self.id = id
        self.label = label
        self.desiredValue = desiredValue
        self.observedValue = observedValue
        self.status = status
        self.source = source
    }
}

public enum ClientDefaultsInspector {
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
        rows.append(serverEntryHealth(servers: servers))
        rows.append(contentsOf: configHealth(defaults: defaults, minecraftDirectory: minecraftDirectory))
        return rows
    }

    private static func shaderHealth(defaults: MinecraftClientDefaults, iris: String?, shaderOptions: String?) -> ClientDefaultHealthRow {
        let observed = firstProperty("shaderPack", in: iris) ?? firstProperty("shaderPack", in: shaderOptions)
        let enabled = firstProperty("enableShaders", in: iris)
        let ok = observed == defaults.shaderPack && (enabled == nil || enabled == "true")
        return ClientDefaultHealthRow(
            id: "shader",
            label: "Shader",
            desiredValue: "\(defaults.shaderPack) active",
            observedValue: observed ?? "missing",
            status: observed == nil ? .missing : (ok ? .ok : .mismatch),
            source: "config/iris.properties"
        )
    }

    private static func resourcePackHealth(defaults: MinecraftClientDefaults, options: String?) -> ClientDefaultHealthRow {
        guard let options else {
            return ClientDefaultHealthRow(
                id: "resource_packs",
                label: "Resource Packs",
                desiredValue: defaults.resourcePacks.joined(separator: " > "),
                observedValue: "missing",
                status: .missing,
                source: "options.txt"
            )
        }
        let resourceLine = firstColonValue("resourcePacks", in: options) ?? ""
        let incompatibleLine = firstColonValue("incompatibleResourcePacks", in: options) ?? ""
        let hasAllPacks = defaults.resourcePacks.allSatisfy { resourceLine.contains($0) }
        let ordered = isOrdered(defaults.resourcePacks, in: resourceLine)
        let incompatibleCleared = incompatibleLine.trimmingCharacters(in: .whitespacesAndNewlines) == "[]" || incompatibleLine.isEmpty
        return ClientDefaultHealthRow(
            id: "resource_packs",
            label: "Resource Packs",
            desiredValue: defaults.resourcePacks.joined(separator: " > "),
            observedValue: resourceLine.isEmpty ? "missing" : resourceLine,
            status: hasAllPacks && ordered && incompatibleCleared ? .ok : .mismatch,
            source: "options.txt"
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
                source: "launcher_profiles.json"
            )
        }
        let observedHeap = maxHeapArgument(in: launcherProfiles)
        let ok = observedHeap.flatMap(heapGB(from:)) == desiredGB
        return ClientDefaultHealthRow(
            id: "memory",
            label: "Memory",
            desiredValue: desiredHeap,
            observedValue: observedHeap.map { "\(heapGB(from: $0) ?? 0) GB configured" } ?? "\(desiredGB) GB not found",
            status: ok ? .ok : .mismatch,
            source: "launcher_profiles.json"
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
        guard let desired = defaults.javaExecutablePath, !desired.isEmpty else {
            return ClientDefaultHealthRow(
                id: "java_runtime",
                label: "Java Runtime",
                desiredValue: "Java 25.0.3 managed by Pummelchen",
                observedValue: "not managed in this check",
                status: .unknown,
                source: "launcher_profiles.json"
            )
        }
        guard let launcherProfiles, !launcherProfiles.isEmpty else {
            return ClientDefaultHealthRow(
                id: "java_runtime",
                label: "Java Runtime",
                desiredValue: desired,
                observedValue: "launcher profile missing",
                status: .missing,
                source: "launcher_profiles.json"
            )
        }
        let observed = launcherProfiles.contains(desired) ? desired : "managed Java path not found"
        return ClientDefaultHealthRow(
            id: "java_runtime",
            label: "Java Runtime",
            desiredValue: desired,
            observedValue: observed,
            status: observed == desired ? .ok : .mismatch,
            source: "launcher_profiles.json"
        )
    }

    private static func serverEntryHealth(servers: String?) -> ClientDefaultHealthRow {
        guard let servers, !servers.isEmpty else {
            return ClientDefaultHealthRow(
                id: "server_entry",
                label: "Server Entry",
                desiredValue: "91.99.176.243:25565",
                observedValue: "servers.dat missing",
                status: .missing,
                source: "servers.dat"
            )
        }
        let ok = servers.contains("91.99.176.243") || servers.localizedCaseInsensitiveContains("Pummelchen")
        return ClientDefaultHealthRow(
            id: "server_entry",
            label: "Server Entry",
            desiredValue: "91.99.176.243:25565",
            observedValue: ok ? "Pummelchen server found" : "Pummelchen server not found",
            status: ok ? .ok : .mismatch,
            source: "servers.dat"
        )
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
                    status: observed == nil ? .missing : (observed == value ? .ok : .mismatch),
                    source: relativePath
                )
            }
        }.sorted { $0.id < $1.id }
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

    private static func isOrdered(_ values: [String], in text: String) -> Bool {
        var searchStart = text.startIndex
        for value in values {
            guard let range = text.range(of: value, range: searchStart..<text.endIndex) else {
                return false
            }
            searchStart = range.upperBound
        }
        return true
    }
}
