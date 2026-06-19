import Foundation
import MCPummelchenModShared

public enum ModBanPipelineError: Error, CustomStringConvertible {
    case noSupportedVersions
    case invalidPattern

    public var description: String {
        switch self {
        case .noSupportedVersions:
            return "no live or staging Minecraft versions found"
        case .invalidPattern:
            return "ban pattern must contain at least one letter or number"
        }
    }
}

public struct ModBanPipelineConfig: Sendable {
    public let projectRoot: URL
    public let databaseURL: URL
    public let displayName: String
    public let filePatterns: [String]
    public let sourceURL: String?
    public let reason: String
    public let dryRun: Bool

    public init(
        projectRoot: URL,
        databaseURL: URL,
        displayName: String,
        filePatterns: [String],
        sourceURL: String? = nil,
        reason: String = "Banned by Admin",
        dryRun: Bool = true
    ) {
        self.projectRoot = projectRoot
        self.databaseURL = databaseURL
        self.displayName = displayName
        self.filePatterns = filePatterns
        self.sourceURL = sourceURL
        self.reason = reason
        self.dryRun = dryRun
    }
}

public struct ModBanRemoval: Equatable, Sendable {
    public let minecraftVersion: String
    public let path: String
    public let removed: Bool
}

public struct ModBanPipelineResult: Equatable, Sendable {
    public let displayName: String
    public let reason: String
    public let dryRun: Bool
    public let removals: [ModBanRemoval]
}

public struct ModBanPipeline: Sendable {
    public let config: ModBanPipelineConfig
    private var fileManager: FileManager { FileManager.default }

    public init(config: ModBanPipelineConfig) {
        self.config = config
    }

    public func run() throws -> ModBanPipelineResult {
        let patterns = normalizedPatterns()
        guard !patterns.isEmpty else {
            throw ModBanPipelineError.invalidPattern
        }

        try ensureTables()
        let versions = try loadVersionTargets()
        guard !versions.isEmpty else {
            throw ModBanPipelineError.noSupportedVersions
        }

        var removals: [ModBanRemoval] = []
        for version in versions {
            for root in [
                version.serverDir.appendingPathComponent("mods", isDirectory: true),
                version.serverDir.appendingPathComponent("client-package/mods", isDirectory: true),
                version.serverDir.appendingPathComponent("config", isDirectory: true),
                version.serverDir.appendingPathComponent("client-package/config", isDirectory: true)
            ] {
                for item in try matchingItems(in: root, patterns: patterns) {
                    let didRemove = try remove(item)
                    removals.append(ModBanRemoval(
                        minecraftVersion: version.minecraftVersion,
                        path: item.path,
                        removed: didRemove
                    ))
                }
            }
        }

        if !config.dryRun {
            try recordBan(patterns: patterns, versions: versions)
        }

        return ModBanPipelineResult(
            displayName: config.displayName,
            reason: config.reason,
            dryRun: config.dryRun,
            removals: removals.sorted { $0.path < $1.path }
        )
    }

    private func remove(_ file: URL) throws -> Bool {
        guard !config.dryRun else {
            return false
        }
        try fileManager.removeItem(at: file)
        return true
    }

    private func normalizedPatterns() -> [String] {
        let raw = config.filePatterns + [
            config.displayName,
            config.displayName.replacingOccurrences(of: " ", with: "_"),
            config.displayName.replacingOccurrences(of: " ", with: "-")
        ]
        return Array(Set(raw.map(Self.normalizedPattern).filter { !$0.isEmpty })).sorted()
    }

    private static func normalizedPattern(_ value: String) -> String {
        value
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func matchingItems(in directory: URL, patterns: [String]) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var matches: [URL] = []
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            guard values?.isRegularFile == true || isDirectory else {
                continue
            }
            let normalizedName = Self.normalizedPattern(item.lastPathComponent)
            if patterns.contains(where: { normalizedName.contains($0) }) {
                matches.append(item)
                if isDirectory {
                    enumerator.skipDescendants()
                }
            }
        }
        return matches
    }

    private func ensureTables() throws {
        try DuckDBDatabase(databaseURL: config.databaseURL).execute("""
        CREATE SCHEMA IF NOT EXISTS core;
        CREATE TABLE IF NOT EXISTS core.mods (
          id BIGINT PRIMARY KEY,
          canonical_key VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          category VARCHAR,
          active_status VARCHAR NOT NULL,
          server_status VARCHAR,
          client_package VARCHAR,
          primary_url VARCHAR,
          updated_at TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS core.failed_mod_update_status (
          failed_mod_id VARCHAR PRIMARY KEY,
          title VARCHAR NOT NULL,
          source_url VARCHAR,
          filename VARCHAR,
          installed_version VARCHAR,
          failure_reason VARCHAR NOT NULL,
          details VARCHAR,
          failed_at TIMESTAMP,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader VARCHAR DEFAULT 'neoforge',
          loader_version VARCHAR,
          latest_status VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          last_check_details VARCHAR,
          last_checked_at TIMESTAMP,
          active_status VARCHAR NOT NULL DEFAULT 'failed',
          updated_at TIMESTAMP NOT NULL DEFAULT now()
        );
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
        """)
    }

    private func loadVersionTargets() throws -> [BanVersionTarget] {
        let csv = try DuckDBDatabase(databaseURL: config.databaseURL, readOnly: true).queryCSV("""
        SELECT minecraft_version, loader, loader_version, server_dir, status, is_live
        FROM core.minecraft_server_versions
        WHERE lower(status) IN ('live', 'staging')
        ORDER BY sort_order, minecraft_version;
        """)
        return Self.parseCSV(csv).compactMap { row in
            guard let minecraftVersion = row["minecraft_version"], !minecraftVersion.isEmpty,
                  let serverDir = row["server_dir"], !serverDir.isEmpty else {
                return nil
            }
            return BanVersionTarget(
                minecraftVersion: minecraftVersion,
                loader: row["loader"] ?? "neoforge",
                loaderVersion: row["loader_version"] ?? "",
                serverDir: URL(fileURLWithPath: serverDir, isDirectory: true).standardizedFileURL,
                status: row["status"] ?? "unknown",
                isLive: Self.duckBool(row["is_live"] ?? "")
            )
        }
    }

    private func recordBan(patterns: [String], versions: [BanVersionTarget]) throws {
        let database = DuckDBDatabase(databaseURL: config.databaseURL)
        let canonicalKey = Self.slug(config.displayName)
        let source = config.sourceURL ?? ""
        let files = patterns.joined(separator: ", ")
        let details = "\(config.displayName) was removed from all managed server and client package mod folders by admin policy."
        try database.execute("""
        DELETE FROM core.mods WHERE canonical_key = \(Self.sqlLiteral(canonicalKey)) OR lower(name) = lower(\(Self.sqlLiteral(config.displayName)));
        INSERT INTO core.mods(
          id, canonical_key, name, category, active_status, server_status, client_package, primary_url, updated_at
        )
        VALUES (
          (SELECT COALESCE(MAX(id), 0) + 1 FROM core.mods),
          \(Self.sqlLiteral(canonicalKey)),
          \(Self.sqlLiteral(config.displayName)),
          'Worldgen and Structures',
          \(Self.sqlLiteral(config.reason)),
          'removed',
          'removed',
          \(Self.sqlLiteral(source)),
          now()
        );
        UPDATE core.mod_sources
        SET active = false, updated_at = now()
        WHERE \(Self.sqlLikeAny(column: "installed_file", patterns: patterns))
           OR lower(display_name) = lower(\(Self.sqlLiteral(config.displayName)))
           OR lower(source_url) = lower(\(Self.sqlLiteral(source)));
        """)

        for version in versions {
            let failedID = "\(canonicalKey)-\(version.minecraftVersion.replacingOccurrences(of: ".", with: "-"))"
            try database.execute("""
            DELETE FROM core.failed_mod_update_status WHERE failed_mod_id = \(Self.sqlLiteral(failedID));
            INSERT INTO core.failed_mod_update_status(
              failed_mod_id, title, source_url, filename, installed_version,
              failure_reason, details, failed_at, minecraft_version, loader,
              loader_version, latest_status, last_check_details, active_status, updated_at
            )
            VALUES (
              \(Self.sqlLiteral(failedID)),
              \(Self.sqlLiteral(config.displayName)),
              \(Self.sqlLiteral(source)),
              \(Self.sqlLiteral(files)),
              '',
              \(Self.sqlLiteral(config.reason)),
              \(Self.sqlLiteral(details)),
              now(),
              \(Self.sqlLiteral(version.minecraftVersion)),
              \(Self.sqlLiteral(version.loader)),
              \(Self.sqlLiteral(version.loaderVersion)),
              'banned',
              'Removed by admin policy; do not reinstall.',
              \(Self.sqlLiteral(config.reason)),
              now()
            );
            """)
        }
    }

    private static func sqlLikeAny(column: String, patterns: [String]) -> String {
        patterns.map {
            "regexp_replace(lower(\(column)), '[^a-z0-9]', '', 'g') LIKE '%' || \(sqlLiteral($0)) || '%'"
        }.joined(separator: " OR ")
    }

    private static func slug(_ value: String) -> String {
        let chars = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(chars).replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func sqlLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func parseCSV(_ csv: String) -> [[String: String]] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return [] }
        let headers = parseCSVLine(header)
        return lines.dropFirst().filter { !$0.isEmpty }.map { line in
            let fields = parseCSVLine(line)
            var row: [String: String] = [:]
            for (index, name) in headers.enumerated() {
                row[name] = fields.indices.contains(index) ? fields[index] : ""
            }
            return row
        }
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let char = characters[index]
            if char == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
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

    private static func duckBool(_ value: String) -> Bool {
        ["true", "t", "1"].contains(value.lowercased())
    }
}

private struct BanVersionTarget {
    let minecraftVersion: String
    let loader: String
    let loaderVersion: String
    let serverDir: URL
    let status: String
    let isLive: Bool
}
