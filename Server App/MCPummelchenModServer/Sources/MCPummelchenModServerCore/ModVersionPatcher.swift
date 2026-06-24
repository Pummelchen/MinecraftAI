import Foundation
import MCPummelchenModShared

public enum ModVersionPatcherError: Error, CustomStringConvertible {
    case invalidJar(String)
    case patchFailed(String)

    public var description: String {
        switch self {
        case .invalidJar(let m): return "invalid jar: \(m)"
        case .patchFailed(let m): return m
        }
    }
}

public struct ModVersionPatcher: Sendable {
    public static func patchIfNeeded(jar url: URL, minecraftVersion: String) throws -> Bool {
        guard ["jar", "zip"].contains(url.pathExtension.lowercased()) else {
            throw ModVersionPatcherError.invalidJar(url.path)
        }
        let newUpper = Self.deriveUpperBound(minecraftVersion: minecraftVersion)
        let targetMinor = Self.extractMinorVersion(minecraftVersion)
        let candidates = ["META-INF/neoforge.mods.toml", "META-INF/mods.toml"]
        let fm = FileManager.default

        for entry in candidates {
            let result = try Self.runProcess(executable: "/usr/bin/env", arguments: ["unzip", "-p", url.path, entry])
            guard result.exitCode == 0, !result.output.isEmpty else { continue }

            let original = result.output
            guard Self.isPatchSafe(original, targetMinor: targetMinor, minecraftVersion: minecraftVersion) else {
                continue
            }
            let patched = Self.applyTo(text: original, newUpper: newUpper)
            guard patched != original else { continue }

            let work = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pummelchen-patch-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: work) }

            let tomlDir = work.appendingPathComponent("META-INF", isDirectory: true)
            try fm.createDirectory(at: tomlDir, withIntermediateDirectories: true)
            try patched.write(to: tomlDir.appendingPathComponent(entry.components(separatedBy: "/").last!), atomically: true, encoding: .utf8)

            _ = try Self.runProcess(executable: "/usr/bin/env", arguments: ["zip", "-d", url.path, entry])
            _ = try Self.runProcess(executable: "/usr/bin/env", arguments: ["zip", "-g", url.path, entry], currentDirectory: work)

            let verify = try Self.runProcess(executable: "/usr/bin/env", arguments: ["unzip", "-p", url.path, entry])
            guard verify.output.contains(newUpper) else {
                throw ModVersionPatcherError.patchFailed("verification failed for \(entry) in \(url.lastPathComponent)")
            }
            return true
        }
        return false
    }

    static func deriveUpperBound(minecraftVersion: String) -> String {
        let parts = minecraftVersion.split(separator: ".").map(String.init)
        guard parts.count >= 2, let minor = Int(parts[1]) else {
            return "26.3"
        }
        let major = parts[0]
        return "\(major).\(minor + 1)"
    }

    static func extractMinorVersion(_ version: String) -> String? {
        let parts = version.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    static func isPatchSafe(_ toml: String, targetMinor: String?, minecraftVersion: String) -> Bool {
        guard let targetMinor else { return false }
        let rangePattern = #"versionRange\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: rangePattern),
              let match = regex.firstMatch(in: toml, range: NSRange(toml.startIndex..., in: toml)),
              let range = Range(match.range(at: 1), in: toml) else {
            return true
        }
        let declaredRange = String(toml[range])
        let bounds = Self.parseRangeBounds(declaredRange)
        guard let lowerMinor = bounds.lower.flatMap({ Self.extractMinorVersion($0) }),
              let upperMinor = bounds.upper.flatMap({ Self.extractMinorVersion($0) }) else {
            return true
        }
        if lowerMinor != targetMinor && upperMinor != targetMinor {
            return false
        }
        return true
    }

    static func parseRangeBounds(_ value: String) -> (lower: String?, upper: String?) {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard v.hasPrefix("[") else { return (nil, nil) }
        let body = String(v.dropFirst())
        guard let commaIdx = body.firstIndex(of: ",") else {
            let closing = body.firstIndex(of: "]") ?? body.firstIndex(of: ")") ?? body.endIndex
            let single = String(body[..<closing]).trimmingCharacters(in: .whitespaces)
            return (single.isEmpty ? nil : single, nil)
        }
        let lower = String(body[..<commaIdx]).trimmingCharacters(in: .whitespaces)
        let afterComma = String(body[body.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
        let closing = afterComma.firstIndex(of: "]") ?? afterComma.firstIndex(of: ")") ?? afterComma.endIndex
        let upper = String(afterComma[..<closing]).trimmingCharacters(in: .whitespaces)
        return (lower.isEmpty ? nil : lower, upper.isEmpty ? nil : upper)
    }

    static func applyTo(text: String, newUpper: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            guard line.contains("versionRange") || line.contains("loaderVersion") else { continue }
            guard let keyRange = line.range(of: #"versionRange\s*=\s*"#) ?? line.range(of: #"loaderVersion\s*=\s*"#) else { continue }
            let afterKey = String(line[keyRange.upperBound...])
            guard let innerEnd = afterKey.dropFirst().firstIndex(of: "\"") else { continue }
            let val = String(afterKey[afterKey.startIndex..<innerEnd])
            let fixed = Self.fixRange(val, newUpper: newUpper)
            if fixed != val {
                let beforeKey = String(line[..<keyRange.lowerBound])
                lines[i] = "\(beforeKey)versionRange = \"\(fixed)\""
            }
        }
        return lines.joined(separator: "\n")
    }

    static func fixRange(_ val: String, newUpper: String) -> String {
        let v = val.trimmingCharacters(in: .whitespaces)
        guard v != "*", !v.isEmpty, v.hasPrefix("[") else { return val }

        let body = String(v.dropFirst())
        guard let commaIdx = body.firstIndex(of: ",") else {
            let closing = body.firstIndex(of: "]") ?? body.firstIndex(of: ")") ?? body.endIndex
            let lower = String(body[..<closing])
            if lower.hasPrefix("26.") {
                return "[26.1,\(newUpper))"
            }
            return val
        }

        let lower = String(body[..<commaIdx]).trimmingCharacters(in: .whitespaces)
        let afterComma = String(body[body.index(after: commaIdx)...]).trimmingCharacters(in: .whitespaces)
        let closing = afterComma.firstIndex(of: "]") ?? afterComma.firstIndex(of: ")") ?? afterComma.endIndex
        let upper = String(afterComma[..<closing]).trimmingCharacters(in: .whitespaces)

        guard !upper.isEmpty else { return val }
        if upper.hasPrefix("26.") || upper.hasPrefix("1.") {
            return "[\(lower),\(newUpper))"
        }
        return val
    }

    @discardableResult
    private static func runProcess(executable: String, arguments: [String], currentDirectory: URL? = nil) throws -> (exitCode: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.currentDirectoryURL = currentDirectory
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (proc.terminationStatus, output)
    }
}
