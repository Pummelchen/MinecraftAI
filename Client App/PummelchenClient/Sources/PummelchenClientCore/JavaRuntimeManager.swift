import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PummelchenCore

public struct JavaRuntimeRequirement: Equatable, Sendable {
    public let version: String
    public let build: String
    public let vendor: String
    public let archiveName: String
    public let archiveSHA256: String
    public let downloadURL: URL

    public init(
        version: String = "25.0.3",
        build: String = "9",
        vendor: String = "Eclipse Temurin",
        archiveName: String = "OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.3_9.tar.gz",
        archiveSHA256: String = "7baab4d69a15554e119b86ff78d40e3fdc28819b5b322955c913cebfe3f6a37c",
        downloadURL: URL = URL(string: "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.3%2B9/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.3_9.tar.gz")!
    ) {
        self.version = version
        self.build = build
        self.vendor = vendor
        self.archiveName = archiveName
        self.archiveSHA256 = archiveSHA256
        self.downloadURL = downloadURL
    }

    public var managedDirectoryName: String {
        "temurin-\(version)+\(build)"
    }
}

public struct JavaRuntimeStatus: Equatable, Sendable {
    public let javaExecutableURL: URL
    public let versionOutput: String
    public let repaired: Bool
}

public enum JavaRuntimeError: Error, CustomStringConvertible {
    case downloadFailed(URL)
    case archiveChecksumMismatch(String)
    case extractionFailed(String)
    case javaVerificationFailed(String)

    public var description: String {
        switch self {
        case .downloadFailed(let url):
            return "Java runtime download failed: \(url.absoluteString)"
        case .archiveChecksumMismatch(let archive):
            return "Java runtime archive checksum mismatch: \(archive)"
        case .extractionFailed(let message):
            return "Java runtime extraction failed: \(message)"
        case .javaVerificationFailed(let message):
            return "Java runtime verification failed: \(message)"
        }
    }
}

public enum JavaRuntimeManager {
    public static func ensureInstalled(
        pummelchenHome: URL,
        requirement: JavaRuntimeRequirement = JavaRuntimeRequirement()
    ) async throws -> JavaRuntimeStatus {
        let javaRoot = pummelchenHome.appendingPathComponent("java", isDirectory: true)
        let target = javaRoot.appendingPathComponent(requirement.managedDirectoryName, isDirectory: true)
        let java = target.appendingPathComponent("Contents/Home/bin/java")
        var repaired = false

        if let output = try? verify(javaExecutable: java, requirement: requirement) {
            try removeStaleManagedJava(in: javaRoot, keeping: target.lastPathComponent)
            return JavaRuntimeStatus(javaExecutableURL: java, versionOutput: output, repaired: false)
        }

        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
            repaired = true
        }

        let archive = try await preparedArchive(pummelchenHome: pummelchenHome, requirement: requirement)
        try install(archive: archive, target: target, requirement: requirement)
        let output = try verify(javaExecutable: java, requirement: requirement)
        try removeStaleManagedJava(in: javaRoot, keeping: target.lastPathComponent)
        try writeCurrentRuntimeMarker(pummelchenHome: pummelchenHome, java: java, output: output, requirement: requirement)
        return JavaRuntimeStatus(javaExecutableURL: java, versionOutput: output, repaired: repaired)
    }

    public static func verify(javaExecutable: URL, requirement: JavaRuntimeRequirement = JavaRuntimeRequirement()) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: javaExecutable.path) else {
            throw JavaRuntimeError.javaVerificationFailed("\(javaExecutable.path) is not executable")
        }
        let process = Process()
        process.executableURL = javaExecutable
        process.arguments = ["-version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0, text.contains("\"\(requirement.version)\"") || text.contains("version \(requirement.version)") else {
            throw JavaRuntimeError.javaVerificationFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preparedArchive(pummelchenHome: URL, requirement: JavaRuntimeRequirement) async throws -> URL {
        let bundled = pummelchenHome.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(requirement.archiveName)
        if try archiveMatches(bundled, requirement: requirement) {
            return bundled
        }

        let cache = pummelchenHome.appendingPathComponent("cache/java", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cached = cache.appendingPathComponent(requirement.archiveName)
        if try archiveMatches(cached, requirement: requirement) {
            return cached
        }
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.removeItem(at: cached)
        }

        let (downloaded, response) = try await URLSession.shared.download(from: requirement.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JavaRuntimeError.downloadFailed(requirement.downloadURL)
        }
        try FileManager.default.moveItem(at: downloaded, to: cached)
        guard try archiveMatches(cached, requirement: requirement) else {
            try? FileManager.default.removeItem(at: cached)
            throw JavaRuntimeError.archiveChecksumMismatch(requirement.archiveName)
        }
        return cached
    }

    private static func archiveMatches(_ archive: URL, requirement: JavaRuntimeRequirement) throws -> Bool {
        guard FileManager.default.fileExists(atPath: archive.path) else {
            return false
        }
        return try SHA256Hasher.hashFile(at: archive) == requirement.archiveSHA256
    }

    private static func install(archive: URL, target: URL, requirement: JavaRuntimeRequirement) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pummelchen-java-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", work.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw JavaRuntimeError.extractionFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard let extractedBundle = try findExtractedBundle(in: work, requirement: requirement) else {
            throw JavaRuntimeError.extractionFailed("no macOS JDK bundle with Contents/Home/bin/java found")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: extractedBundle, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.appendingPathComponent("Contents/Home/bin/java").path)
    }

    private static func findExtractedBundle(in root: URL, requirement: JavaRuntimeRequirement) throws -> URL? {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return nil
        }
        for case let url as URL in enumerator {
            let java = url.appendingPathComponent("Contents/Home/bin/java")
            if FileManager.default.isExecutableFile(atPath: java.path),
               (try? verify(javaExecutable: java, requirement: requirement)) != nil {
                return url
            }
        }
        return nil
    }

    private static func removeStaleManagedJava(in javaRoot: URL, keeping keepName: String) throws {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: javaRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for entry in entries where entry.lastPathComponent != keepName && entry.lastPathComponent.hasPrefix("temurin-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private static func writeCurrentRuntimeMarker(
        pummelchenHome: URL,
        java: URL,
        output: String,
        requirement: JavaRuntimeRequirement
    ) throws {
        let marker = pummelchenHome.appendingPathComponent("java/current-runtime.txt")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        vendor=\(requirement.vendor)
        version=\(requirement.version)
        build=\(requirement.build)
        java=\(java.path)
        verified=\(output.replacingOccurrences(of: "\n", with: " | "))
        """.write(to: marker, atomically: true, encoding: .utf8)
    }
}
