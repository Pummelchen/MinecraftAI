import Foundation
import MCPummelchenModShared

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModAddPipelineError: Error, CustomStringConvertible {
    case invalidURL(String)
    case unsupportedProvider(String)
    case missingArtifact(String)
    case noCompatibleFile(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .invalidURL(let value):
            return "invalid mod URL: \(value)"
        case .unsupportedProvider(let value):
            return "unsupported mod provider: \(value)"
        case .missingArtifact(let value):
            return "missing artifact: \(value)"
        case .noCompatibleFile(let value):
            return "no compatible file found: \(value)"
        case .commandFailed(let value):
            return value
        }
    }
}

public struct ModAddPipelineConfig: Sendable {
    public let projectRoot: URL
    public let serverDir: URL
    public let releaseRoot: URL
    public let publicDownloads: URL
    public let databaseURL: URL
    public let sourceURL: String
    public let localArtifact: URL?
    public let releaseID: String
    public let serverPackageDirectory: URL?
    public let serviceName: String?
    public let minecraftVersion: String
    public let loader: String
    public let loaderVersion: String
    public let installScope: String
    public let activate: Bool
    public let dryRun: Bool
    public let clientAPIToken: String?
    public let requireClientToken: Bool

    public init(
        projectRoot: URL,
        serverDir: URL,
        releaseRoot: URL,
        publicDownloads: URL,
        databaseURL: URL,
        sourceURL: String,
        localArtifact: URL? = nil,
        releaseID: String,
        serverPackageDirectory: URL? = nil,
        serviceName: String? = nil,
        minecraftVersion: String = "26.1.2",
        loader: String = "neoforge",
        loaderVersion: String = "26.1.2.76",
        installScope: String = "auto",
        activate: Bool = false,
        dryRun: Bool = true,
        clientAPIToken: String? = nil,
        requireClientToken: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.serverDir = serverDir
        self.releaseRoot = releaseRoot
        self.publicDownloads = publicDownloads
        self.databaseURL = databaseURL
        self.sourceURL = sourceURL
        self.localArtifact = localArtifact
        self.releaseID = releaseID
        self.serverPackageDirectory = serverPackageDirectory
        self.serviceName = serviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.loaderVersion = loaderVersion
        self.installScope = installScope
        self.activate = activate
        self.dryRun = dryRun
        self.clientAPIToken = clientAPIToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requireClientToken = requireClientToken
    }
}

public struct AddedModArtifact: Equatable, Sendable {
    public let sourceURL: String
    public let provider: String
    public let projectID: String?
    public let fileID: String?
    public let displayName: String
    public let fileName: String
    public let version: String?
    public let sha256: String
    public let side: String
    public let copiedToServer: Bool
    public let copiedToClient: Bool
}

public struct ModAddPipelineResult: Equatable, Sendable {
    public let releaseID: String
    public let dryRun: Bool
    public let artifacts: [AddedModArtifact]
    public let releaseCreated: Bool
    public let releaseActivated: Bool
    public let steps: [String]
}

public struct ModAddPipeline: Sendable {
    public let config: ModAddPipelineConfig
    private var fileManager: FileManager { FileManager.default }

    public init(config: ModAddPipelineConfig) {
        self.config = config
    }

    public func run() throws -> ModAddPipelineResult {
        _ = try ReleaseIdentifier(config.releaseID)
        let resolved = try resolveArtifactGraph()
        defer { cleanupDownloadedArtifacts(resolved) }
        let artifacts = try install(artifacts: resolved)
        var steps = [
            "resolved \(resolved.count) artifact(s) from provider metadata",
            "classified scope for \(artifacts.count) artifact(s)",
            config.dryRun ? "dry run: no files copied and no release created" : "installed artifact into managed package directories"
        ]

        guard !config.dryRun else {
            return ModAddPipelineResult(
                releaseID: config.releaseID,
                dryRun: true,
                artifacts: artifacts,
                releaseCreated: false,
                releaseActivated: false,
                steps: steps
            )
        }

        try recordSources(artifacts)
        steps.append("recorded source rows in DuckDB")
        try runServerSmokeCheckIfNeeded(steps: &steps)
        if try buildDMGIfNeeded() {
            steps.append("native Swift client DMG build passed")
        } else {
            steps.append("native Swift client DMG build skipped (platform unsupported)")
        }

        let release = try SwiftReleasePipeline(config: SwiftReleasePipelineConfig(
            projectRoot: config.projectRoot,
            serverDir: config.serverDir,
            releaseRoot: config.releaseRoot,
            publicDownloads: config.publicDownloads,
            databaseURL: config.databaseURL,
            releaseID: config.releaseID,
            serverKey: Self.serverKey(minecraftVersion: config.minecraftVersion),
            minecraftVersion: config.minecraftVersion,
            loaderVersion: config.loaderVersion,
            notes: "Add mod: \(artifacts.map(\.displayName).joined(separator: ", "))",
            actor: "MCPummelchenModServer add-mod",
            activate: config.activate,
            serviceName: config.serviceName ?? ""
        )).createRelease()
        steps.append("release pipeline created \(release.releaseID)")
        if release.activated {
            steps.append("release activated and public downloads updated")
        }
        return ModAddPipelineResult(
            releaseID: release.releaseID,
            dryRun: false,
            artifacts: artifacts,
            releaseCreated: true,
            releaseActivated: release.activated,
            steps: steps
        )
    }

    private func runServerSmokeCheckIfNeeded(steps: inout [String]) throws {
        let currentReleaseFile = config.projectRoot.appendingPathComponent("site/public/downloads/current-release.json")
        guard FileManager.default.fileExists(atPath: currentReleaseFile.path) else {
            steps.append("server compatibility smoke check skipped (current release manifest missing)")
            return
        }
        let api = MCPummelchenModServerAPI(
            config: MCPummelchenModServerConfig(
                projectRoot: config.projectRoot,
                duckDBURL: config.databaseURL
            )
        )
        try api.smokeCheck()
        steps.append("native server compatibility smoke check passed")
    }

    private func buildDMGIfNeeded() throws -> Bool {
        #if os(macOS)
        let env = ProcessInfo.processInfo.environment
        let clientPackageRoot = config.projectRoot.appendingPathComponent("Client App/MCPummelchenModClient", isDirectory: true)
        guard FileManager.default.fileExists(atPath: clientPackageRoot.appendingPathComponent("Package.swift").path) else {
            return false
        }
        let serverPackageRoot = config.serverPackageDirectory
            ?? URL(fileURLWithPath: env["PUMMELCHEN_SERVER_PACKAGE_DIR"] ?? config.projectRoot.appendingPathComponent("Server App/MCPummelchenModServer").path)
        let clientToken = config.clientAPIToken ?? env["PUMMELCHEN_CLIENT_API_TOKEN"]
        let runNginxControlLiveTest = env["PUMMELCHEN_SKIP_NGINX_CONTROL_LIVE_TEST"]?.lowercased() != "true" && !(clientToken?.isEmpty ?? true)
        let builderConfig = ClientDMGBuilderConfig(
            projectRoot: config.projectRoot,
            clientPackageRoot: clientPackageRoot,
            serverPackageRoot: serverPackageRoot,
            releaseID: config.releaseID,
            clientVersion: env["PUMMELCHEN_CLIENT_VERSION"] ?? "0.8.2",
            serverURL: env["PUMMELCHEN_SERVER_URL"] ?? "https://pummelchen.91.99.176.243.nip.io",
            serverAddress: env["PUMMELCHEN_SERVER_ADDRESS"] ?? "91.99.176.243:25565",
            duckdbDylibPath: env["PUMMELCHEN_DUCKDB_DYLIB"] ?? "/opt/homebrew/lib/libduckdb.dylib",
            macOSDeploymentTarget: env["MACOSX_DEPLOYMENT_TARGET"] ?? "26.0",
            runNginxControlLiveTest: runNginxControlLiveTest,
            runHeadlessSoak: env["PUMMELCHEN_REQUIRE_HEADLESS_SOAK"]?.lowercased() == "true",
            headlessSoakSeconds: Int(env["PUMMELCHEN_HEADLESS_SOAK_SECONDS"] ?? "60") ?? 60,
            headlessCommand: env["PUMMELCHEN_HEADLESS_COMMAND"],
            expectedInstalledReleaseID: env["PUMMELCHEN_HEADLESS_EXPECTED_INSTALLED_RELEASE_ID"],
            clientAPIToken: clientToken,
            requireClientToken: config.requireClientToken
        )
        _ = try ClientDMGBuilder(config: builderConfig).build()
        return true
        #else
        return false
        #endif
    }

    private func resolvePrimaryArtifact() throws -> ResolvedArtifact {
        guard let url = URL(string: config.sourceURL), let host = url.host?.lowercased() else {
            throw ModAddPipelineError.invalidURL(config.sourceURL)
        }
        if let localArtifact = config.localArtifact {
            return try resolvedLocalArtifact(localArtifact, sourceURL: config.sourceURL, provider: provider(for: host))
        }
        if host.contains("curseforge.com") {
            return try resolveCurseForge(sourceURL: url)
        }
        if host.contains("modrinth.com") {
            return try resolveModrinth(sourceURL: url)
        }
        throw ModAddPipelineError.unsupportedProvider(host)
    }

    private func resolveArtifactGraph() throws -> [ResolvedArtifact] {
        var resolved: [ResolvedArtifact] = []
        var seen = Set<String>()
        var queue = [try resolvePrimaryArtifact()]
        while let artifact = queue.first {
            queue.removeFirst()
            let key = artifact.identityKey
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            resolved.append(artifact)
            guard resolved.count <= 16 else {
                throw ModAddPipelineError.commandFailed("dependency graph exceeded 16 artifacts")
            }
            for dependency in artifact.requiredDependencies where !seen.contains(dependency.key) {
                queue.append(try resolve(dependency: dependency))
            }
        }
        return resolved
    }

    private func resolve(dependency: RequiredModDependency) throws -> ResolvedArtifact {
        switch dependency.provider {
        case "curseforge":
            guard let projectID = Int(dependency.projectID) else {
                throw ModAddPipelineError.noCompatibleFile("invalid CurseForge dependency id \(dependency.projectID)")
            }
            return try resolveCurseForge(projectID: projectID, sourceURL: "https://www.curseforge.com/projects/\(projectID)")
        case "modrinth":
            return try resolveModrinth(projectID: dependency.projectID)
        default:
            throw ModAddPipelineError.unsupportedProvider(dependency.provider)
        }
    }

    private func resolvedLocalArtifact(_ artifact: URL, sourceURL: String, provider: String) throws -> ResolvedArtifact {
        guard fileManager.fileExists(atPath: artifact.path) else {
            throw ModAddPipelineError.missingArtifact(artifact.path)
        }
        let metadata = try inspectJar(artifact)
        return ResolvedArtifact(
            sourceURL: sourceURL,
            provider: provider,
            projectID: nil,
            fileID: nil,
            displayName: metadata.displayName ?? artifact.deletingPathExtension().lastPathComponent,
            fileName: artifact.lastPathComponent,
            version: metadata.version ?? Self.versionFromFilename(artifact.lastPathComponent),
            downloadURL: artifact,
            localFile: artifact,
            side: metadata.side,
            requiredDependencies: [],
            cleanupDirectory: nil
        )
    }

    private func resolveCurseForge(sourceURL: URL) throws -> ResolvedArtifact {
        guard let slug = ModUpdateScanner.curseForgeSlug(from: sourceURL) else {
            throw ModAddPipelineError.invalidURL(sourceURL.absoluteString)
        }
        let projectID = try resolveCurseForgeProjectID(slug: slug)
        return try resolveCurseForge(projectID: projectID, sourceURL: sourceURL.absoluteString)
    }

    private func resolveCurseForge(projectID: Int, sourceURL: String) throws -> ResolvedArtifact {
        let endpoint = "https://www.curseforge.com/api/v1/mods/\(projectID)/files?pageIndex=0&pageSize=50&gameVersion=\(Self.urlQuery(config.minecraftVersion))&modLoaderType=\(Self.curseForgeLoaderType(config.loader))"
        guard let endpointURL = URL(string: endpoint) else {
            throw ModAddPipelineError.invalidURL(endpoint)
        }
        let data = try fetchData(endpointURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["data"] as? [[String: Any]],
              let file = ModUpdateScanner.bestCurseForgeFile(from: files, loader: config.loader, minecraftVersion: config.minecraftVersion) else {
            throw ModAddPipelineError.noCompatibleFile(sourceURL)
        }
        let fileID = file["id"].map { String(describing: $0) }
        let fileName = (file["fileName"] as? String) ?? (file["displayName"] as? String) ?? "\(projectID).jar"
        let download = "https://www.curseforge.com/api/v1/mods/\(projectID)/files/\(fileID ?? "")/download"
        guard let downloadURL = URL(string: download) else {
            throw ModAddPipelineError.invalidURL(download)
        }
        let downloaded = try downloadArtifact(downloadURL, preferredName: fileName)
        let metadata = try inspectJar(downloaded.file)
        return ResolvedArtifact(
            sourceURL: sourceURL,
            provider: "curseforge",
            projectID: String(projectID),
            fileID: fileID,
            displayName: metadata.displayName ?? Self.title(fromSlug: sourceURL.split(separator: "/").last.map(String.init) ?? String(projectID)),
            fileName: fileName,
            version: metadata.version ?? Self.versionFromFilename(fileName),
            downloadURL: downloadURL,
            localFile: downloaded.file,
            side: metadata.side,
            requiredDependencies: Self.curseForgeRequiredDependencies(from: file),
            cleanupDirectory: downloaded.directory
        )
    }

    private func resolveModrinth(sourceURL: URL) throws -> ResolvedArtifact {
        guard let slug = Self.modrinthSlug(from: sourceURL) else {
            throw ModAddPipelineError.invalidURL(sourceURL.absoluteString)
        }
        let endpoint = "https://api.modrinth.com/v2/project/\(slug)/version?loaders=%5B%22\(Self.urlQuery(config.loader))%22%5D&game_versions=%5B%22\(Self.urlQuery(config.minecraftVersion))%22%5D"
        guard let endpointURL = URL(string: endpoint) else {
            throw ModAddPipelineError.invalidURL(endpoint)
        }
        let data = try fetchData(endpointURL)
        guard let versions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let version = versions.first,
              let files = version["files"] as? [[String: Any]],
              let file = files.first(where: { ($0["primary"] as? Bool) == true }) ?? files.first,
              let urlText = file["url"] as? String,
              let downloadURL = URL(string: urlText) else {
            throw ModAddPipelineError.noCompatibleFile(sourceURL.absoluteString)
        }
        let fileName = (file["filename"] as? String) ?? downloadURL.lastPathComponent
        let downloaded = try downloadArtifact(downloadURL, preferredName: fileName)
        let metadata = try inspectJar(downloaded.file)
        return ResolvedArtifact(
            sourceURL: sourceURL.absoluteString,
            provider: "modrinth",
            projectID: version["project_id"] as? String,
            fileID: version["id"] as? String,
            displayName: metadata.displayName ?? Self.title(fromSlug: slug),
            fileName: fileName,
            version: metadata.version ?? version["version_number"] as? String ?? Self.versionFromFilename(fileName),
            downloadURL: downloadURL,
            localFile: downloaded.file,
            side: metadata.side,
            requiredDependencies: Self.modrinthRequiredDependencies(from: version),
            cleanupDirectory: downloaded.directory
        )
    }

    private func resolveModrinth(projectID: String) throws -> ResolvedArtifact {
        let projectEndpoint = "https://api.modrinth.com/v2/project/\(Self.urlQuery(projectID))"
        guard let projectURL = URL(string: projectEndpoint) else {
            throw ModAddPipelineError.invalidURL(projectEndpoint)
        }
        let data = try fetchData(projectURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModAddPipelineError.noCompatibleFile(projectID)
        }
        let slug = (object["slug"] as? String) ?? projectID
        guard let sourceURL = URL(string: "https://modrinth.com/mod/\(slug)") else {
            throw ModAddPipelineError.invalidURL(slug)
        }
        return try resolveModrinth(sourceURL: sourceURL)
    }

    private func install(artifacts resolved: [ResolvedArtifact]) throws -> [AddedModArtifact] {
        try fileManager.createDirectory(at: config.serverDir.appendingPathComponent("mods", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: config.serverDir.appendingPathComponent("client-package/mods", isDirectory: true), withIntermediateDirectories: true)
        return try resolved.map { artifact in
            let scope = effectiveScope(side: artifact.side)
            let serverTarget = config.serverDir.appendingPathComponent("mods/\(artifact.fileName)")
            let clientTarget = config.serverDir.appendingPathComponent("client-package/mods/\(artifact.fileName)")
            if !config.dryRun {
                if scope.copiedToServer {
                    try copyFile(artifact.localFile, to: serverTarget)
                }
                if scope.copiedToClient {
                    try copyFile(artifact.localFile, to: clientTarget)
                }
            }
            return AddedModArtifact(
                sourceURL: artifact.sourceURL,
                provider: artifact.provider,
                projectID: artifact.projectID,
                fileID: artifact.fileID,
                displayName: artifact.displayName,
                fileName: artifact.fileName,
                version: artifact.version,
                sha256: try SHA256Hasher.hashFile(at: artifact.localFile),
                side: artifact.side,
                copiedToServer: scope.copiedToServer,
                copiedToClient: scope.copiedToClient
            )
        }
    }

    private func recordSources(_ artifacts: [AddedModArtifact]) throws {
        try DuckDBDatabase(databaseURL: config.databaseURL).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE IF NOT EXISTS core.mod_sources (
          source_id VARCHAR PRIMARY KEY,
          mod_key VARCHAR NOT NULL,
          display_name VARCHAR NOT NULL,
          installed_file VARCHAR,
          installed_version VARCHAR,
          provider VARCHAR NOT NULL,
          source_url VARCHAR NOT NULL,
          priority INTEGER NOT NULL DEFAULT 100,
          active BOOLEAN NOT NULL DEFAULT true,
          created_at TIMESTAMP NOT NULL DEFAULT now(),
          updated_at TIMESTAMP NOT NULL DEFAULT now(),
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR
        );
        ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
        ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS loader VARCHAR DEFAULT 'neoforge';
        ALTER TABLE core.mod_sources ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        """)
        for artifact in artifacts {
            let sourceID = [Optional(artifact.provider), artifact.projectID, artifact.fileID]
                .compactMap { value -> String? in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .joined(separator: "_")
            let baseStableID = sourceID.isEmpty ? Self.stableID("\(artifact.sourceURL)|\(artifact.fileName)") : sourceID
            let stableID = Self.versionedSourceID(baseStableID, minecraftVersion: config.minecraftVersion)
            try DuckDBDatabase(databaseURL: config.databaseURL).execute("""
            DELETE FROM core.mod_sources WHERE source_id = \(Self.sqlLiteral(stableID));
            INSERT INTO core.mod_sources(
              source_id, mod_key, display_name, installed_file, installed_version,
              provider, source_url, priority, active, updated_at,
              minecraft_version, loader, loader_version
            )
            VALUES (
              \(Self.sqlLiteral(stableID)),
              \(Self.sqlLiteral(Self.modKey(artifact.displayName))),
              \(Self.sqlLiteral(artifact.displayName)),
              \(Self.sqlLiteral(artifact.fileName)),
              \(Self.sqlLiteral(artifact.version)),
              \(Self.sqlLiteral(artifact.provider)),
              \(Self.sqlLiteral(artifact.sourceURL)),
              25,
              true,
              now(),
              \(Self.sqlLiteral(config.minecraftVersion)),
              \(Self.sqlLiteral(config.loader)),
              \(Self.sqlLiteral(config.loaderVersion))
            );
            """)
        }
    }

    private func inspectJar(_ file: URL) throws -> JarMetadata {
        guard ["jar", "zip"].contains(file.pathExtension.lowercased()) else {
            return JarMetadata(displayName: file.deletingPathExtension().lastPathComponent, version: Self.versionFromFilename(file.lastPathComponent), side: "both")
        }
        let candidates = [
            "META-INF/neoforge.mods.toml",
            "META-INF/mods.toml",
            "fabric.mod.json",
            "quilt.mod.json"
        ]
        for path in candidates {
            if let text = try? runProcess(executable: "/usr/bin/env", arguments: ["unzip", "-p", file.path, path]) {
                let metadata = Self.parseMetadata(text)
                if metadata.displayName != nil || metadata.version != nil || metadata.side != "both" {
                    return metadata
                }
            }
        }
        return JarMetadata(displayName: file.deletingPathExtension().lastPathComponent, version: Self.versionFromFilename(file.lastPathComponent), side: "both")
    }

    private func effectiveScope(side: String) -> (copiedToServer: Bool, copiedToClient: Bool) {
        switch config.installScope.lowercased() {
        case "server": return (true, false)
        case "client": return (false, true)
        case "both": return (true, true)
        default:
            return side.lowercased() == "client" ? (false, true) : (true, true)
        }
    }

    private func resolveCurseForgeProjectID(slug: String) throws -> Int {
        let endpoint = "https://api.curse.tools/v1/cf/mods/search?gameId=432&slug=\(Self.urlQuery(slug))&pageSize=5"
        guard let url = URL(string: endpoint) else {
            throw ModAddPipelineError.invalidURL(endpoint)
        }
        let data = try fetchData(url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mods = object["data"] as? [[String: Any]],
              let id = mods.first(where: { ($0["slug"] as? String) == slug })?["id"] as? Int ?? mods.first?["id"] as? Int else {
            throw ModAddPipelineError.noCompatibleFile(slug)
        }
        return id
    }

    private func downloadArtifact(_ url: URL, preferredName: String) throws -> (file: URL, directory: URL) {
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pummelchen-add-mod-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        let target = work.appendingPathComponent(preferredName)
        try fetchData(url).write(to: target, options: .atomic)
        return (target, work)
    }

    private func cleanupDownloadedArtifacts(_ artifacts: [ResolvedArtifact]) {
        var cleaned = Set<String>()
        for artifact in artifacts {
            guard let directory = artifact.cleanupDirectory,
                  directory.path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).path),
                  !cleaned.contains(directory.path) else {
                continue
            }
            try? fileManager.removeItem(at: directory)
            cleaned.insert(directory.path)
        }
    }

    private func fetchData(_ url: URL) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("MCPummelchenModServer/1.0 add-mod", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        let box = AddModURLFetchResultBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                box.store(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                box.store(.failure(ModAddPipelineError.commandFailed("HTTP \(http.statusCode) for \(url.absoluteString)")))
                return
            }
            box.store(.success(data ?? Data()))
        }.resume()
        semaphore.wait()
        guard let result = box.result() else {
            throw ModAddPipelineError.commandFailed("request produced no response for \(url.absoluteString)")
        }
        return try result.get()
    }

    private func copyFile(_ source: URL, to target: URL) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    @discardableResult
    private func runProcess(executable: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = config.projectRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ModAddPipelineError.commandFailed(Self.redactSecrets(([executable] + arguments).joined(separator: " ") + "\n" + output))
        }
        return output
    }

    private func provider(for host: String) -> String {
        if host.contains("curseforge.com") { return "curseforge" }
        if host.contains("modrinth.com") { return "modrinth" }
        return "web"
    }

    private static func parseMetadata(_ text: String) -> JarMetadata {
        let displayName = firstMatch(pattern: #"(?m)^\s*displayName\s*=\s*"([^"]+)""#, in: text)
            ?? firstMatch(pattern: #""name"\s*:\s*"([^"]+)""#, in: text)
        let version = firstMatch(pattern: #"(?m)^\s*version\s*=\s*"([^"]+)""#, in: text)
            ?? firstMatch(pattern: #""version"\s*:\s*"([^"]+)""#, in: text)
        let side = firstMatch(pattern: #"(?m)^\s*side\s*=\s*"([^"]+)""#, in: text)?.lowercased()
        let clientOnly = text.localizedCaseInsensitiveContains("clientSideOnly")
            || text.localizedCaseInsensitiveContains("clientOnly")
        let normalizedSide = (side == "client" || clientOnly) ? "client" : "both"
        return JarMetadata(displayName: displayName, version: version, side: normalizedSide)
    }

    private static func modrinthSlug(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "mod"), parts.indices.contains(index + 1) else {
            return nil
        }
        return parts[index + 1]
    }

    private static func curseForgeRequiredDependencies(from file: [String: Any]) -> [RequiredModDependency] {
        guard let dependencies = file["dependencies"] as? [[String: Any]] else {
            return []
        }
        return dependencies.compactMap { dependency in
            let relation = dependency["relationType"].map { String(describing: $0) }
            guard relation == "3" || relation == "6",
                  let projectID = dependency["modId"].map({ String(describing: $0) }),
                  !projectID.isEmpty else {
                return nil
            }
            return RequiredModDependency(provider: "curseforge", projectID: projectID)
        }
    }

    private static func modrinthRequiredDependencies(from version: [String: Any]) -> [RequiredModDependency] {
        guard let dependencies = version["dependencies"] as? [[String: Any]] else {
            return []
        }
        return dependencies.compactMap { dependency in
            guard (dependency["dependency_type"] as? String) == "required",
                  let projectID = dependency["project_id"] as? String,
                  !projectID.isEmpty else {
                return nil
            }
            return RequiredModDependency(provider: "modrinth", projectID: projectID)
        }
    }

    private static func curseForgeLoaderType(_ loader: String) -> Int {
        switch loader.lowercased() {
        case "forge": return 1
        case "fabric": return 4
        case "quilt": return 5
        case "neoforge": return 6
        default: return 0
        }
    }

    private static func versionFromFilename(_ filename: String) -> String? {
        let base = filename.replacingOccurrences(of: #"\.(jar|zip)$"#, with: "", options: .regularExpression)
        return firstMatch(pattern: #"(?i)(v?\d+(?:\.\d+){1,4}(?:[+._-][A-Za-z0-9.]+)*)"#, in: base)
    }

    private static func title(fromSlug slug: String) -> String {
        slug.split(separator: "-").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    private static func modKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func serverKey(minecraftVersion: String) -> String {
        "minecraft_\(minecraftVersion.replacingOccurrences(of: ".", with: "_"))"
    }

    private static func versionedSourceID(_ sourceID: String, minecraftVersion: String) -> String {
        "\(sourceID)_mc_\(minecraftVersion.replacingOccurrences(of: ".", with: "_"))"
    }

    private static func stableID(_ value: String) -> String {
        let digest = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { partial, byte in
            (partial ^ UInt64(byte)).multipliedReportingOverflow(by: 1_099_511_628_211).partialValue
        }
        return "mod_source_\(String(digest, radix: 16))"
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let nsRange = match.range(at: 1)
        guard let stringRange = Range(nsRange, in: text) else {
            return nil
        }
        return String(text[stringRange])
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func urlQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private static func redactSecrets(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(--rcon-password\s+)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(rcon\.password\s*=\s*)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
    }
}

private struct ResolvedArtifact {
    let sourceURL: String
    let provider: String
    let projectID: String?
    let fileID: String?
    let displayName: String
    let fileName: String
    let version: String?
    let downloadURL: URL
    let localFile: URL
    let side: String
    let requiredDependencies: [RequiredModDependency]
    let cleanupDirectory: URL?

    var identityKey: String {
        if let projectID, !projectID.isEmpty {
            return "\(provider):\(projectID)"
        }
        return "\(provider):\(sourceURL):\(fileName)"
    }
}

private struct RequiredModDependency {
    let provider: String
    let projectID: String

    var key: String {
        "\(provider):\(projectID)"
    }
}

private struct JarMetadata {
    let displayName: String?
    let version: String?
    let side: String
}

private final class AddModURLFetchResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Data, Error>?

    func store(_ result: Result<Data, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    func result() -> Result<Data, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
