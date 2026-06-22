import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCPummelchenModShared

public struct NeoForgeClientRequirement: Equatable, Sendable {
    public let minecraftVersion: String
    public let loaderVersion: String
    public let installerName: String
    public let installerSHA256: String
    public let downloadURL: URL

    public init(
        minecraftVersion: String = "26.1.2",
        loaderVersion: String = "26.1.2.76",
        installerName: String = "neoforge-26.1.2.76-installer.jar",
        installerSHA256: String = "f67bf87ddf8f3095ddbae4c78dbbbf5615e08b6982f4e84159eab951235974ec",
        downloadURL: URL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.1.2.76/neoforge-26.1.2.76-installer.jar")!
    ) {
        self.minecraftVersion = minecraftVersion
        self.loaderVersion = loaderVersion
        self.installerName = installerName
        self.installerSHA256 = installerSHA256
        self.downloadURL = downloadURL
    }

    public var launcherVersionID: String {
        "neoforge-\(loaderVersion)"
    }

    public static let live = NeoForgeClientRequirement()

    public static let supported: [NeoForgeClientRequirement] = [
        .live,
        NeoForgeClientRequirement(
            minecraftVersion: "26.2",
            loaderVersion: "26.2.0.3-beta",
            installerName: "neoforge-26.2.0.3-beta-installer.jar",
            installerSHA256: "90fad51778895f921182d6685719cba8a6d8caff69974d721bbdef750fe34c24",
            downloadURL: URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/26.2.0.3-beta/neoforge-26.2.0.3-beta-installer.jar")!
        )
    ]

    public static func requirements(from servers: [MinecraftSupportedServer]) -> [NeoForgeClientRequirement] {
        let fallbackByLoaderVersion = Dictionary(uniqueKeysWithValues: supported.map { ($0.loaderVersion, $0) })
        var seen = Set<String>()
        return servers.compactMap { server in
            guard server.loader.lowercased() == "neoforge",
                  !server.minecraftVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !server.loaderVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(server.loaderVersion).inserted else {
                return nil
            }
            if let installerName = server.installerName?.trimmingCharacters(in: .whitespacesAndNewlines),
               let installerSHA256 = server.installerSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               let installerURL = server.installerURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               !installerName.isEmpty,
               installerSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
               let downloadURL = URL(string: installerURL) {
                return NeoForgeClientRequirement(
                    minecraftVersion: server.minecraftVersion,
                    loaderVersion: server.loaderVersion,
                    installerName: installerName,
                    installerSHA256: installerSHA256,
                    downloadURL: downloadURL
                )
            }
            return fallbackByLoaderVersion[server.loaderVersion]
        }
    }
}

public enum NeoForgeClientInstallerError: Error, CustomStringConvertible {
    case installerDownloadFailed(URL)
    case installerChecksumMismatch(String)
    case installFailed(String)

    public var description: String {
        switch self {
        case .installerDownloadFailed(let url):
            return "NeoForge installer download failed: \(url.absoluteString)"
        case .installerChecksumMismatch(let name):
            return "NeoForge installer checksum mismatch: \(name)"
        case .installFailed(let message):
            return "NeoForge client install failed: \(message)"
        }
    }
}

public enum NeoForgeClientInstaller {
    public static func ensureSupportedInstalled(
        minecraftDirectory: URL,
        pummelchenHome: URL,
        javaExecutable: URL,
        requirements: [NeoForgeClientRequirement] = NeoForgeClientRequirement.supported
    ) async throws {
        for requirement in requirements {
            try await ensureInstalled(
                minecraftDirectory: minecraftDirectory,
                pummelchenHome: pummelchenHome,
                javaExecutable: javaExecutable,
                requirement: requirement
            )
        }
    }

    public static func ensureInstalled(
        minecraftDirectory: URL,
        pummelchenHome: URL,
        javaExecutable: URL,
        requirement: NeoForgeClientRequirement = NeoForgeClientRequirement()
    ) async throws {
        if isInstalled(minecraftDirectory: minecraftDirectory, requirement: requirement) {
            return
        }
        let installer = try await preparedInstaller(pummelchenHome: pummelchenHome, requirement: requirement)
        try runInstaller(installer: installer, javaExecutable: javaExecutable, minecraftDirectory: minecraftDirectory)
        guard isInstalled(minecraftDirectory: minecraftDirectory, requirement: requirement) else {
            throw NeoForgeClientInstallerError.installFailed("installer completed but \(requirement.launcherVersionID) was not found in the Minecraft launcher versions folder")
        }
    }

    public static func isInstalled(minecraftDirectory: URL, requirement: NeoForgeClientRequirement = NeoForgeClientRequirement()) -> Bool {
        let versionDir = minecraftDirectory.appendingPathComponent("versions/\(requirement.launcherVersionID)", isDirectory: true)
        let versionJSON = versionDir.appendingPathComponent("\(requirement.launcherVersionID).json")
        let libraries = minecraftDirectory.appendingPathComponent("libraries/net/neoforged/neoforge/\(requirement.loaderVersion)", isDirectory: true)
        return FileManager.default.fileExists(atPath: versionJSON.path) || FileManager.default.fileExists(atPath: libraries.path)
    }

    private static func preparedInstaller(pummelchenHome: URL, requirement: NeoForgeClientRequirement) async throws -> URL {
        let bundled = pummelchenHome.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(requirement.installerName)
        if try installerMatches(bundled, requirement: requirement) {
            return bundled
        }
        let cache = pummelchenHome.appendingPathComponent("cache/neoforge", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cached = cache.appendingPathComponent(requirement.installerName)
        if try installerMatches(cached, requirement: requirement) {
            return cached
        }
        if FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.removeItem(at: cached)
        }

        let (downloaded, response) = try await URLSession.shared.download(from: requirement.downloadURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NeoForgeClientInstallerError.installerDownloadFailed(requirement.downloadURL)
        }
        try FileManager.default.moveItem(at: downloaded, to: cached)
        guard try installerMatches(cached, requirement: requirement) else {
            try? FileManager.default.removeItem(at: cached)
            throw NeoForgeClientInstallerError.installerChecksumMismatch(requirement.installerName)
        }
        return cached
    }

    private static func installerMatches(_ installer: URL, requirement: NeoForgeClientRequirement) throws -> Bool {
        guard FileManager.default.fileExists(atPath: installer.path) else {
            return false
        }
        return try SHA256Hasher.hashFile(at: installer) == requirement.installerSHA256
    }

    private static func runInstaller(installer: URL, javaExecutable: URL, minecraftDirectory: URL) throws {
        try FileManager.default.createDirectory(at: minecraftDirectory, withIntermediateDirectories: true)
        try ensureLauncherProfiles(minecraftDirectory: minecraftDirectory)
        let process = Process()
        process.executableURL = javaExecutable
        process.arguments = ["-jar", installer.path, "--install-client", minecraftDirectory.path]
        process.currentDirectoryURL = minecraftDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NeoForgeClientInstallerError.installFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func ensureLauncherProfiles(minecraftDirectory: URL) throws {
        let profiles = minecraftDirectory.appendingPathComponent("launcher_profiles.json")
        guard !FileManager.default.fileExists(atPath: profiles.path) else {
            return
        }
        let payload = """
        {
          "profiles": {},
          "settings": {},
          "version": 3
        }

        """
        try payload.write(to: profiles, atomically: true, encoding: .utf8)
    }
}
