import Foundation
import MCPummelchenModShared

public enum ServerVersionBootstrapPipelineError: Error, CustomStringConvertible {
    case noTargetVersion(String)
    case noReferenceVersion(String)
    case missingReferenceDirectory(String)
    case missingTargetDirectory(String)

    public var description: String {
        switch self {
        case .noTargetVersion(let version):
            return "target Minecraft server version is not registered in DuckDB: \(version)"
        case .noReferenceVersion(let version):
            return "reference Minecraft server version is not registered in DuckDB: \(version)"
        case .missingReferenceDirectory(let path):
            return "reference server directory is missing: \(path)"
        case .missingTargetDirectory(let path):
            return "target server directory is missing: \(path)"
        }
    }
}

public struct ServerVersionBootstrapPipelineConfig: Sendable {
    public let projectRoot: URL
    public let databaseURL: URL
    public let targetMinecraftVersion: String
    public let referenceMinecraftVersion: String?
    public let discoverSourceLinks: Bool
    public let discoveryLimit: Int?
    public let discoverySearchesPerSecond: Double
    public let maxURLsPerWindow: Int
    public let windowSeconds: TimeInterval
    public let scanLimit: Int?
    public let dryRun: Bool
    public let applyUpdates: Bool
    public let releaseRoot: URL?
    public let publicDownloads: URL?
    public let releaseIDPrefix: String?
    public let serverPackageDirectory: URL?
    public let serviceName: String?
    public let clientAPIToken: String?
    public let requireClientToken: Bool

    public init(
        projectRoot: URL,
        databaseURL: URL,
        targetMinecraftVersion: String,
        referenceMinecraftVersion: String? = nil,
        discoverSourceLinks: Bool = true,
        discoveryLimit: Int? = nil,
        discoverySearchesPerSecond: Double = 2,
        maxURLsPerWindow: Int = 5,
        windowSeconds: TimeInterval = 10,
        scanLimit: Int? = nil,
        dryRun: Bool = true,
        applyUpdates: Bool = false,
        releaseRoot: URL? = nil,
        publicDownloads: URL? = nil,
        releaseIDPrefix: String? = nil,
        serverPackageDirectory: URL? = nil,
        serviceName: String? = nil,
        clientAPIToken: String? = nil,
        requireClientToken: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.databaseURL = databaseURL
        self.targetMinecraftVersion = targetMinecraftVersion
        self.referenceMinecraftVersion = referenceMinecraftVersion
        self.discoverSourceLinks = discoverSourceLinks
        self.discoveryLimit = discoveryLimit
        self.discoverySearchesPerSecond = discoverySearchesPerSecond
        self.maxURLsPerWindow = maxURLsPerWindow
        self.windowSeconds = windowSeconds
        self.scanLimit = scanLimit
        self.dryRun = dryRun
        self.applyUpdates = applyUpdates
        self.releaseRoot = releaseRoot
        self.publicDownloads = publicDownloads
        self.releaseIDPrefix = releaseIDPrefix
        self.serverPackageDirectory = serverPackageDirectory
        self.serviceName = serviceName
        self.clientAPIToken = clientAPIToken
        self.requireClientToken = requireClientToken
    }
}

public struct ServerVersionBootstrapFileCopy: Equatable, Sendable {
    public let modName: String
    public let fileName: String
    public let copiedToServer: Bool
    public let copiedToClient: Bool
    public let protected: Bool
}

public struct ServerVersionBootstrapResult: Equatable, Sendable {
    public let targetMinecraftVersion: String
    public let referenceMinecraftVersion: String
    public let dryRun: Bool
    public let scannedSources: Int
    public let seededSources: Int
    public let updateCandidatesFound: Int
    public let copiedFiles: [ServerVersionBootstrapFileCopy]
    public let protectedMods: Int
    public let applyResult: ModUpdateApplyPipelineResult?
}

public struct ServerVersionBootstrapPipeline: Sendable {
    public let config: ServerVersionBootstrapPipelineConfig
    private var fileManager: FileManager { FileManager.default }

    public init(config: ServerVersionBootstrapPipelineConfig) {
        self.config = config
    }

    public func run() throws -> ServerVersionBootstrapResult {
        let target = try loadVersion(config.targetMinecraftVersion)
        let referenceVersion = try config.referenceMinecraftVersion ?? liveReferenceMinecraftVersion(excluding: target.minecraftVersion)
        let reference = try loadVersion(referenceVersion)

        guard fileManager.fileExists(atPath: reference.serverDir.path) else {
            throw ServerVersionBootstrapPipelineError.missingReferenceDirectory(reference.serverDir.path)
        }
        guard fileManager.fileExists(atPath: target.serverDir.path) else {
            throw ServerVersionBootstrapPipelineError.missingTargetDirectory(target.serverDir.path)
        }

        let scanner = ModUpdateScanner(config: ModUpdateScannerConfig(
            projectRoot: config.projectRoot,
            databaseURL: config.databaseURL,
            minecraftVersion: target.minecraftVersion,
            loader: target.loader,
            loaderVersion: target.loaderVersion,
            maxURLsPerWindow: config.maxURLsPerWindow,
            windowSeconds: config.windowSeconds,
            limit: config.scanLimit,
            seedFromProjectData: true,
            discoverSourceLinks: config.discoverSourceLinks,
            discoveryLimit: config.discoveryLimit,
            discoverySearchesPerSecond: config.discoverySearchesPerSecond,
            dryRun: config.dryRun
        ))
        let scanSummary = try scanner.run()

        let copied = try copyBaselineFiles(reference: reference, target: target)
        let protectedMods = Set(copied.filter(\.protected).map(\.modName)).count

        let applyResult: ModUpdateApplyPipelineResult?
        if config.applyUpdates {
            guard let releaseRoot = config.releaseRoot,
                  let publicDownloads = config.publicDownloads,
                  let releaseIDPrefix = config.releaseIDPrefix,
                  !releaseIDPrefix.isEmpty else {
                throw ModUpdateApplyPipelineError.incompleteServerPackage("server-version-bootstrap --apply-updates true requires --release-root, --public-downloads, and --release-id-prefix")
            }
            applyResult = try ModUpdateApplyPipeline(config: ModUpdateApplyPipelineConfig(
                projectRoot: config.projectRoot,
                releaseRoot: releaseRoot,
                publicDownloads: publicDownloads,
                databaseURL: config.databaseURL,
                minecraftVersion: target.minecraftVersion,
                allSupported: false,
                releaseIDPrefix: releaseIDPrefix,
                activateLiveVersions: true,
                dryRun: config.dryRun,
                serverPackageDirectory: config.serverPackageDirectory,
                serviceName: config.serviceName,
                clientAPIToken: config.clientAPIToken,
                requireClientToken: config.requireClientToken
            )).run()
        } else {
            applyResult = nil
        }

        return ServerVersionBootstrapResult(
            targetMinecraftVersion: target.minecraftVersion,
            referenceMinecraftVersion: reference.minecraftVersion,
            dryRun: config.dryRun,
            scannedSources: scanSummary.sourcesChecked,
            seededSources: scanSummary.seededSources,
            updateCandidatesFound: scanSummary.candidatesFound,
            copiedFiles: copied,
            protectedMods: protectedMods,
            applyResult: applyResult
        )
    }

    private func baselineRolePaths(role: String) -> (serverSubpath: String, clientSubpath: String?) {
        switch role.lowercased() {
        case "server_file":
            return ("mods", nil)
        case "server_datapack":
            return ("server-datapacks", nil)
        case "shaderpack":
            return ("", "shaderpacks")
        case "resourcepack":
            return ("", "resourcepacks")
        case "client-mod":
            return ("", "mods")
        case "tool":
            return ("", "tools")
        default:
            return ("mods", "mods")
        }
    }

    private func copyBaselineFiles(reference: VersionTarget, target: VersionTarget) throws -> [ServerVersionBootstrapFileCopy] {
        let rows = try loadBaselineRows(reference: reference, target: target)
        var copied: [ServerVersionBootstrapFileCopy] = []

        let clientSections = ["mods", "shaderpacks", "resourcepacks", "tools"]
        for section in clientSections {
            let dir = target.serverDir.appendingPathComponent("client-package/\(section)", isDirectory: true)
            if !fileManager.fileExists(atPath: dir.path) {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        let dataDir = target.serverDir.appendingPathComponent("server-datapacks", isDirectory: true)
        if !fileManager.fileExists(atPath: dataDir.path) {
            try fileManager.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }

        var copiedKeys = Set<String>()
        for row in rows {
            let paths = baselineRolePaths(role: row.role)
            let serverSubpath = paths.serverSubpath.isEmpty ? "mods" : paths.serverSubpath
            let clientSubpath = paths.clientSubpath ?? serverSubpath

            let sourceServerFile = reference.serverDir.appendingPathComponent(serverSubpath).appendingPathComponent(row.fileName)
            let sourceClientFile = reference.serverDir.appendingPathComponent("client-package/\(clientSubpath)").appendingPathComponent(row.fileName)
            let targetServerFile = target.serverDir.appendingPathComponent(serverSubpath).appendingPathComponent(row.fileName)
            let targetClientFile = target.serverDir.appendingPathComponent("client-package/\(clientSubpath)").appendingPathComponent(row.fileName)

            var copiedServer = false
            var copiedClient = false

            if row.installedOnServer, fileManager.fileExists(atPath: sourceServerFile.path) {
                if !config.dryRun {
                    try copyFile(sourceServerFile, to: targetServerFile)
                }
                copiedServer = true
            }

            if row.includedInClient, fileManager.fileExists(atPath: sourceClientFile.path) {
                if !config.dryRun {
                    try copyFile(sourceClientFile, to: targetClientFile)
                }
                copiedClient = true
            }

            guard copiedServer || copiedClient else {
                continue
            }

            copiedKeys.insert(row.fileName)

            if !config.dryRun {
                try markTargetFile(row: row, target: target, copiedServer: copiedServer, copiedClient: copiedClient)
            }

            copied.append(ServerVersionBootstrapFileCopy(
                modName: row.modName,
                fileName: row.fileName,
                copiedToServer: copiedServer,
                copiedToClient: copiedClient,
                protected: row.protected
            ))
        }

        let referenceClientPackage = reference.serverDir.appendingPathComponent("client-package", isDirectory: true)
        let targetClientPackage = target.serverDir.appendingPathComponent("client-package", isDirectory: true)
        for section in clientSections {
            let sourceDir = referenceClientPackage.appendingPathComponent(section, isDirectory: true)
            guard fileManager.fileExists(atPath: sourceDir.path) else { continue }
            for file in try fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                guard !copiedKeys.contains(file.lastPathComponent) else { continue }
                let targetFile = targetClientPackage.appendingPathComponent("\(section)/\(file.lastPathComponent)")
                if !config.dryRun {
                    try copyFile(file, to: targetFile)
                }
                copied.append(ServerVersionBootstrapFileCopy(
                    modName: file.lastPathComponent,
                    fileName: file.lastPathComponent,
                    copiedToServer: false,
                    copiedToClient: true,
                    protected: false
                ))
            }
        }

        return copied
    }

    private func loadBaselineRows(reference: VersionTarget, target: VersionTarget) throws -> [BaselineFileRow] {
        let targetJoin = config.dryRun
            ? "\(Self.sqlLiteral(reference.minecraftVersion)) AS target_version_marker, m.id AS target_mod_id"
            : "t.minecraft_version AS target_version_marker, t.id AS target_mod_id"
        let targetJoinClause = config.dryRun
            ? ""
            : """
              JOIN core.mods t
                ON COALESCE(t.minecraft_version, \(Self.sqlLiteral(target.minecraftVersion))) = \(Self.sqlLiteral(target.minecraftVersion))
               AND t.canonical_key = m.canonical_key
            """
        let csv = try DuckDBDatabase(databaseURL: config.databaseURL, readOnly: true).queryCSV("""
        WITH working_mods AS (
          SELECT
            m.id AS reference_mod_id,
            \(targetJoin),
            m.name AS mod_name,
            lower(COALESCE(m.active_status, '')) IN ('priority mod', 'admin locked') AS is_protected
          FROM core.mods m
          \(targetJoinClause)
          WHERE COALESCE(m.minecraft_version, \(Self.sqlLiteral(reference.minecraftVersion))) = \(Self.sqlLiteral(reference.minecraftVersion))
            AND lower(COALESCE(m.active_status, '')) IN ('active', 'ok', 'priority mod', 'admin locked')
        )
        SELECT
          wm.target_mod_id,
          wm.mod_name,
          mf.file_name,
          mf.role,
          COALESCE(mf.status, '') AS file_status,
          COALESCE(msf.compatibility_status, '') AS compatibility_status,
          COALESCE(msf.file_sha256, '') AS file_sha256,
          COALESCE(msf.file_size_bytes, 0) AS file_size_bytes,
          COALESCE(msf.source_url, '') AS source_url,
          mf.installed_on_server,
          mf.included_in_client,
          wm.is_protected
        FROM working_mods wm
        JOIN core.mod_files mf
          ON mf.mod_id = wm.reference_mod_id
         AND COALESCE(mf.minecraft_version, \(Self.sqlLiteral(reference.minecraftVersion))) = \(Self.sqlLiteral(reference.minecraftVersion))
        LEFT JOIN core.mod_server_files msf
          ON msf.mod_id = wm.reference_mod_id
         AND msf.file_name = mf.file_name
         AND COALESCE(msf.minecraft_version, \(Self.sqlLiteral(reference.minecraftVersion))) = \(Self.sqlLiteral(reference.minecraftVersion))
        WHERE COALESCE(mf.file_name, '') <> ''
          AND lower(COALESCE(mf.status, '')) NOT LIKE '%banned%'
          AND lower(COALESCE(mf.status, '')) NOT LIKE '%failed%'
        ORDER BY wm.mod_name, mf.file_name;
        """)
        return Self.parseCSV(csv).compactMap { row in
            guard let targetModID = Int64(row["target_mod_id"] ?? ""),
                  let fileName = row["file_name"],
                  !fileName.isEmpty else {
                return nil
            }
            return BaselineFileRow(
                targetModID: targetModID,
                modName: row["mod_name"] ?? fileName,
                fileName: fileName,
                dbRole: row["role"] ?? "server_file",
                fileStatus: row["file_status"] ?? "",
                compatibilityStatus: row["compatibility_status"] ?? "",
                fileSHA256: row["file_sha256"] ?? "",
                fileSizeBytes: Int64(row["file_size_bytes"] ?? "") ?? 0,
                sourceURL: row["source_url"] ?? "",
                installedOnServer: Self.duckBool(row["installed_on_server"] ?? ""),
                includedInClient: Self.duckBool(row["included_in_client"] ?? ""),
                protected: Self.duckBool(row["is_protected"] ?? "")
            )
        }
    }

    private func markTargetFile(row: BaselineFileRow, target: VersionTarget, copiedServer: Bool, copiedClient: Bool) throws {
        let compatibility = row.protected ? "admin_forced_carry_forward_candidate" : "carry_forward_candidate"
        let status = "Copied from previous supported server version; needs \(target.minecraftVersion) validation"
        try DuckDBDatabase(databaseURL: config.databaseURL).execute("""
        UPDATE core.mod_files
        SET installed_on_server = installed_on_server OR \(copiedServer ? "true" : "false"),
            included_in_client = included_in_client OR \(copiedClient ? "true" : "false"),
            status = \(Self.sqlLiteral(status)),
            loader = \(Self.sqlLiteral(target.loader)),
            loader_version = \(Self.sqlLiteral(target.loaderVersion))
        WHERE mod_id = \(row.targetModID)
          AND file_name = \(Self.sqlLiteral(row.fileName))
          AND COALESCE(minecraft_version, \(Self.sqlLiteral(target.minecraftVersion))) = \(Self.sqlLiteral(target.minecraftVersion));

        UPDATE core.mod_server_files
        SET installed_on_server = installed_on_server OR \(copiedServer ? "true" : "false"),
            included_in_client = included_in_client OR \(copiedClient ? "true" : "false"),
            selected = true,
            compatibility_status = \(Self.sqlLiteral(compatibility)),
            loader = \(Self.sqlLiteral(target.loader)),
            loader_version = \(Self.sqlLiteral(target.loaderVersion)),
            last_synced = now(),
            notes = concat_ws(' ', NULLIF(notes, ''), \(Self.sqlLiteral(status)))
        WHERE mod_id = \(row.targetModID)
          AND file_name = \(Self.sqlLiteral(row.fileName))
          AND COALESCE(minecraft_version, \(Self.sqlLiteral(target.minecraftVersion))) = \(Self.sqlLiteral(target.minecraftVersion));
        """)
    }

    private func loadVersion(_ minecraftVersion: String) throws -> VersionTarget {
        let csv = try DuckDBDatabase(databaseURL: config.databaseURL, readOnly: true).queryCSV("""
        SELECT minecraft_version, loader, loader_version, server_dir, status, is_live
        FROM core.minecraft_server_versions
        WHERE minecraft_version = \(Self.sqlLiteral(minecraftVersion))
        LIMIT 1;
        """)
        guard let row = Self.parseCSV(csv).first else {
            if minecraftVersion == config.targetMinecraftVersion {
                throw ServerVersionBootstrapPipelineError.noTargetVersion(minecraftVersion)
            }
            throw ServerVersionBootstrapPipelineError.noReferenceVersion(minecraftVersion)
        }
        return VersionTarget(
            minecraftVersion: row["minecraft_version"] ?? minecraftVersion,
            loader: row["loader"] ?? "neoforge",
            loaderVersion: row["loader_version"] ?? "",
            serverDir: URL(fileURLWithPath: row["server_dir"] ?? "", isDirectory: true).standardizedFileURL,
            status: row["status"] ?? "unknown",
            isLive: Self.duckBool(row["is_live"] ?? "")
        )
    }

    private func liveReferenceMinecraftVersion(excluding targetVersion: String) throws -> String {
        let csv = try DuckDBDatabase(databaseURL: config.databaseURL, readOnly: true).queryCSV("""
        SELECT minecraft_version
        FROM core.minecraft_server_versions
        WHERE is_live = true
          AND minecraft_version <> \(Self.sqlLiteral(targetVersion))
        ORDER BY sort_order, minecraft_version
        LIMIT 1;
        """)
        if let value = Self.parseCSV(csv).first?["minecraft_version"], !value.isEmpty {
            return value
        }
        throw ServerVersionBootstrapPipelineError.noReferenceVersion("live version excluding \(targetVersion)")
    }

    private func copyFile(_ source: URL, to target: URL) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.copyItem(at: source, to: target)
    }

    private struct VersionTarget {
        let minecraftVersion: String
        let loader: String
        let loaderVersion: String
        let serverDir: URL
        let status: String
        let isLive: Bool
    }

    private struct BaselineFileRow {
        let targetModID: Int64
        let modName: String
        let fileName: String
        let dbRole: String
        let fileStatus: String
        let compatibilityStatus: String
        let fileSHA256: String
        let fileSizeBytes: Int64
        let sourceURL: String
        let installedOnServer: Bool
        let includedInClient: Bool
        let protected: Bool

        var role: String {
            dbRole.isEmpty ? "server_file" : dbRole
        }
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func duckBool(_ value: String) -> Bool {
        ["true", "1", "t"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func parseCSV(_ csv: String) -> [[String: String]] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerLine = lines.first else { return [] }
        let headers = parseCSVLine(headerLine)
        return lines.dropFirst().filter { !$0.isEmpty }.map { line in
            let values = parseCSVLine(line)
            var row: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                row[header] = index < values.count ? values[index] : ""
            }
            return row
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted, index + 1 < chars.count, chars[index + 1] == "\"" {
                    current.append("\"")
                    index += 2
                    continue
                }
                quoted.toggle()
            } else if char == ",", !quoted {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
            index += 1
        }
        fields.append(current)
        return fields
    }
}
