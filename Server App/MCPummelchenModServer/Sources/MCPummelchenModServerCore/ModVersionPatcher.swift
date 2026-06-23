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
        let newUpper = "26.3"
        let candidates = ["META-INF/neoforge.mods.toml", "META-INF/mods.toml"]
        let fm = FileManager.default

        for entry in candidates {
            let result = try Self.runProcess(executable: "/usr/bin/env", arguments: ["unzip", "-p", url.path, entry])
            guard result.exitCode == 0, !result.output.isEmpty else { continue }

            let original = result.output
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

            // Verify patch took effect
            let verify = try Self.runProcess(executable: "/usr/bin/env", arguments: ["unzip", "-p", url.path, entry])
            guard verify.output.contains(newUpper) else {
                throw ModVersionPatcherError.patchFailed("verification failed for \(entry) in \(url.lastPathComponent)")
            }
            return true
        }
        return false
    }

    static func applyTo(text: String, newUpper: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() {
            guard line.contains("versionRange") || line.contains("loaderVersion") else { continue }
            guard let keyRange = line.range(of: #"versionRange\s*=\s*"#) ?? line.range(of: #"loaderVersion\s*=\s*"#) else { continue }
            let afterKey = String(line[keyRange.upperBound...])
            guard afterKey.hasPrefix("\"") else { continue }
            let innerStart = afterKey.index(after: afterKey.startIndex)
            guard let innerEnd = afterKey.dropFirst().firstIndex(of: "\"") else { continue }
            let val = String(afterKey[innerStart..<innerEnd])
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
