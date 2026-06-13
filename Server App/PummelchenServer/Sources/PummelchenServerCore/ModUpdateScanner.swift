import Foundation
import PummelchenCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModUpdateScannerError: Error, CustomStringConvertible {
    case invalidSourceURL(String)
    case network(String)

    public var description: String {
        switch self {
        case .invalidSourceURL(let value):
            return "invalid mod source URL: \(value)"
        case .network(let value):
            return "network error: \(value)"
        }
    }
}

public struct ModUpdateScannerConfig: Sendable {
    public let projectRoot: URL
    public let databaseURL: URL
    public let minecraftVersion: String
    public let loader: String
    public let maxURLsPerWindow: Int
    public let windowSeconds: TimeInterval
    public let limit: Int?
    public let seedFromTestedUpdates: Bool
    public let dryRun: Bool

    public init(
        projectRoot: URL,
        databaseURL: URL,
        minecraftVersion: String = "26.1.2",
        loader: String = "neoforge",
        maxURLsPerWindow: Int = 5,
        windowSeconds: TimeInterval = 10,
        limit: Int? = nil,
        seedFromTestedUpdates: Bool = false,
        dryRun: Bool = false
    ) {
        self.projectRoot = projectRoot
        self.databaseURL = databaseURL
        self.minecraftVersion = minecraftVersion
        self.loader = loader
        self.maxURLsPerWindow = maxURLsPerWindow
        self.windowSeconds = windowSeconds
        self.limit = limit
        self.seedFromTestedUpdates = seedFromTestedUpdates
        self.dryRun = dryRun
    }
}

public struct ModUpdateScanSummary: Equatable, Sendable {
    public let scanID: String
    public let sourcesChecked: Int
    public let candidatesFound: Int
    public let unresolved: Int
    public let seededSources: Int
}

public struct ModSourceRecord: Equatable, Sendable {
    public let sourceID: String
    public let modKey: String
    public let displayName: String
    public let installedFile: String?
    public let installedVersion: String?
    public let provider: String
    public let sourceURL: String
}

public struct ModUpdateCheckResult: Equatable, Sendable {
    public let source: ModSourceRecord
    public let status: String
    public let latestVersion: String?
    public let latestURL: String?
    public let details: String
}

public struct ModUpdateScanner: Sendable {
    public let config: ModUpdateScannerConfig
    private var database: DuckDBDatabase { DuckDBDatabase(databaseURL: config.databaseURL) }
    private var fileManager: FileManager { FileManager.default }

    public init(config: ModUpdateScannerConfig) {
        self.config = config
    }

    public func run() throws -> ModUpdateScanSummary {
        try initializeDatabase()
        let seeded = config.seedFromTestedUpdates ? try seedSourcesFromTestedUpdates() : 0
        let scanID = "scan_\(Self.compactTimestamp())_\(UUID().uuidString.prefix(8))"
        let startedAt = Self.duckTimestamp(Date())
        if !config.dryRun {
            try execute("""
            INSERT INTO core.mod_update_scans(scan_id, started_at, status, urls_checked, candidates_found, unresolved, notes)
            VALUES (\(Self.sqlLiteral(scanID)), TIMESTAMP '\(startedAt)', 'running', 0, 0, 0, 'started');
            """)
        }

        let sources = try loadSources(limit: config.limit)
        var checked = 0
        var candidates = 0
        var unresolved = 0
        for source in sources {
            if checked > 0,
               config.maxURLsPerWindow > 0,
               checked % config.maxURLsPerWindow == 0,
               config.windowSeconds > 0 {
                Thread.sleep(forTimeInterval: config.windowSeconds)
            }
            let result = check(source: source)
            checked += 1
            if result.status == "update_available" {
                candidates += 1
            }
            if ["unresolved", "blocked", "error"].contains(result.status) {
                unresolved += 1
            }
            if !config.dryRun {
                try persist(result: result, scanID: scanID)
            }
        }

        if !config.dryRun {
            try execute("""
            UPDATE core.mod_update_scans
            SET finished_at = TIMESTAMP '\(Self.duckTimestamp(Date()))',
                status = 'completed',
                urls_checked = \(checked),
                candidates_found = \(candidates),
                unresolved = \(unresolved),
                notes = \(Self.sqlLiteral("seeded_sources=\(seeded) throttle=\(config.maxURLsPerWindow)/\(Int(config.windowSeconds))s"))
            WHERE scan_id = \(Self.sqlLiteral(scanID));
            """)
            try publishUpdateActivity(scanID: scanID, checked: checked, candidates: candidates, unresolved: unresolved, seeded: seeded)
        }
        return ModUpdateScanSummary(scanID: scanID, sourcesChecked: checked, candidatesFound: candidates, unresolved: unresolved, seededSources: seeded)
    }

    public func check(source: ModSourceRecord) -> ModUpdateCheckResult {
        do {
            guard let url = URL(string: source.sourceURL), let host = url.host?.lowercased() else {
                throw ModUpdateScannerError.invalidSourceURL(source.sourceURL)
            }
            if host.contains("modrinth.com") {
                return try checkModrinth(source: source, sourceURL: url)
            }
            let body = try fetchText(url)
            if Self.isCloudflareChallenge(body) {
                return ModUpdateCheckResult(
                    source: source,
                    status: "blocked",
                    latestVersion: nil,
                    latestURL: nil,
                    details: "curl received a Cloudflare challenge page; use official API metadata or a mirror URL for this source"
                )
            }
            let latest = Self.parseLatestVersion(fromHTML: body, provider: source.provider)
            let status = Self.classify(installedVersion: source.installedVersion, latestVersion: latest)
            return ModUpdateCheckResult(source: source, status: status, latestVersion: latest, latestURL: source.sourceURL, details: latest == nil ? "latest version could not be parsed from HTML" : "parsed from source HTML")
        } catch {
            return ModUpdateCheckResult(source: source, status: "error", latestVersion: nil, latestURL: nil, details: String(describing: error))
        }
    }

    public static func parseLatestVersion(fromHTML html: String, provider: String) -> String? {
        let patterns = [
            #""version_number"\s*:\s*"([^"]+)""#,
            #""versionNumber"\s*:\s*"([^"]+)""#,
            #""latestVersion"\s*:\s*"([^"]+)""#,
            #""fileName"\s*:\s*"([^"]+\.(?:jar|zip))""#
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern: pattern, in: html) {
                if value.hasSuffix(".jar") || value.hasSuffix(".zip") {
                    return versionFromFilename(value)
                }
                return cleanVersionCandidate(value, provider: provider)
            }
        }
        return nil
    }

    public static func isCloudflareChallenge(_ html: String) -> Bool {
        let lower = html.lowercased()
        return lower.contains("<title>just a moment...</title>")
            || lower.contains("cf-mitigated")
            || lower.contains("challenges.cloudflare.com")
    }

    public static func provider(for sourceURL: String) -> String {
        let lower = sourceURL.lowercased()
        if lower.contains("modrinth.com") { return "modrinth" }
        if lower.contains("curseforge.com") { return "curseforge" }
        return "web"
    }

    private func initializeDatabase() throws {
        try fileManager.createDirectory(at: config.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
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
          updated_at TIMESTAMP NOT NULL DEFAULT now()
        );
        CREATE TABLE IF NOT EXISTS core.mod_update_scans (
          scan_id VARCHAR PRIMARY KEY,
          started_at TIMESTAMP NOT NULL,
          finished_at TIMESTAMP,
          status VARCHAR NOT NULL,
          urls_checked INTEGER NOT NULL DEFAULT 0,
          candidates_found INTEGER NOT NULL DEFAULT 0,
          unresolved INTEGER NOT NULL DEFAULT 0,
          notes VARCHAR
        );
        CREATE TABLE IF NOT EXISTS core.mod_update_scan_results (
          result_id VARCHAR PRIMARY KEY,
          scan_id VARCHAR NOT NULL,
          source_id VARCHAR NOT NULL,
          checked_at TIMESTAMP NOT NULL,
          provider VARCHAR NOT NULL,
          source_url VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          installed_file VARCHAR,
          installed_version VARCHAR,
          latest_version VARCHAR,
          latest_url VARCHAR,
          details VARCHAR
        );
        """)
    }

    private func seedSourcesFromTestedUpdates() throws -> Int {
        let candidates = [
            config.projectRoot.appendingPathComponent("site/public/tested-updates.json"),
            config.projectRoot.appendingPathComponent("site/public/data/tested-updates.json"),
            config.projectRoot.appendingPathComponent("Server App/nginx/site/public/tested-updates.json"),
            config.projectRoot.appendingPathComponent("Server App/nginx/site/public/data/tested-updates.json")
        ]
        guard let sourceFile = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return 0
        }
        let data = try Data(contentsOf: sourceFile)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        let updates = object["updates"] as? [[String: Any]] ?? object["rows"] as? [[String: Any]] ?? []
        var seededSourceIDs = Set<String>()
        for row in updates {
            guard let sourceURL = row["source_url"] as? String,
                  sourceURL.hasPrefix("http://") || sourceURL.hasPrefix("https://") else {
                continue
            }
            let title = (row["title"] as? String) ?? "Unknown Mod"
            let version = row["version"] as? String
            let files = Self.files(from: row["new_file"] as? String)
            let fileList = files.count == 1 ? files.map(Optional.some) : [nil]
            for installedFile in fileList {
                let displayName = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let modKey = Self.modKey(displayName: displayName, installedFile: installedFile, sourceURL: sourceURL)
                let installedVersion = version ?? installedFile.flatMap(Self.versionFromFilename)
                let source = ModSourceRecord(
                    sourceID: Self.stableID("\(modKey)|\(sourceURL)|\(installedFile ?? "")"),
                    modKey: modKey,
                    displayName: displayName,
                    installedFile: installedFile,
                    installedVersion: installedVersion,
                    provider: Self.provider(for: sourceURL),
                    sourceURL: sourceURL
                )
                try upsert(source: source)
                seededSourceIDs.insert(source.sourceID)
            }
        }
        return seededSourceIDs.count
    }

    private func loadSources(limit: Int?) throws -> [ModSourceRecord] {
        let limitClause = limit.map { " LIMIT \(max(0, $0))" } ?? ""
        let csv = try query("""
        SELECT source_id, mod_key, display_name, COALESCE(installed_file, ''), COALESCE(installed_version, ''), provider, source_url
        FROM core.mod_sources
        WHERE active = true
        ORDER BY priority ASC, display_name ASC, source_url ASC
        \(limitClause);
        """)
        return csvRows(csv).compactMap { row in
            guard row.count >= 7 else { return nil }
            return ModSourceRecord(
                sourceID: row[0],
                modKey: row[1],
                displayName: row[2],
                installedFile: row[3].isEmpty ? nil : row[3],
                installedVersion: row[4].isEmpty ? nil : row[4],
                provider: row[5],
                sourceURL: row[6]
            )
        }
    }

    private func checkModrinth(source: ModSourceRecord, sourceURL: URL) throws -> ModUpdateCheckResult {
        guard let slug = Self.modrinthSlug(from: sourceURL) else {
            let body = try fetchText(sourceURL)
            let latest = Self.parseLatestVersion(fromHTML: body, provider: source.provider)
            return ModUpdateCheckResult(source: source, status: Self.classify(installedVersion: source.installedVersion, latestVersion: latest), latestVersion: latest, latestURL: source.sourceURL, details: latest == nil ? "modrinth slug not found and HTML parse failed" : "parsed from Modrinth HTML")
        }
        let endpoint = "https://api.modrinth.com/v2/project/\(slug)/version?loaders=%5B%22\(config.loader)%22%5D&game_versions=%5B%22\(config.minecraftVersion)%22%5D"
        let data = try fetchData(URL(string: endpoint)!)
        guard let versions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let latest = versions.first else {
            return ModUpdateCheckResult(source: source, status: "unresolved", latestVersion: nil, latestURL: endpoint, details: "Modrinth API returned no compatible versions")
        }
        let latestVersion = latest["version_number"] as? String
        let latestURL = ((latest["files"] as? [[String: Any]])?.first(where: { ($0["primary"] as? Bool) == true }) ?? (latest["files"] as? [[String: Any]])?.first)?["url"] as? String
        return ModUpdateCheckResult(
            source: source,
            status: Self.classify(installedVersion: source.installedVersion, latestVersion: latestVersion),
            latestVersion: latestVersion,
            latestURL: latestURL ?? endpoint,
            details: "checked Modrinth project API for \(config.loader) \(config.minecraftVersion)"
        )
    }

    private func upsert(source: ModSourceRecord) throws {
        try execute("""
        DELETE FROM core.mod_sources WHERE source_id = \(Self.sqlLiteral(source.sourceID));
        INSERT INTO core.mod_sources(source_id, mod_key, display_name, installed_file, installed_version, provider, source_url, priority, active, updated_at)
        VALUES (
          \(Self.sqlLiteral(source.sourceID)),
          \(Self.sqlLiteral(source.modKey)),
          \(Self.sqlLiteral(source.displayName)),
          \(Self.sqlLiteral(source.installedFile)),
          \(Self.sqlLiteral(source.installedVersion)),
          \(Self.sqlLiteral(source.provider)),
          \(Self.sqlLiteral(source.sourceURL)),
          100,
          true,
          now()
        );
        """)
    }

    private func persist(result: ModUpdateCheckResult, scanID: String) throws {
        try execute("""
        INSERT INTO core.mod_update_scan_results(
          result_id, scan_id, source_id, checked_at, provider, source_url, status,
          installed_file, installed_version, latest_version, latest_url, details
        )
        VALUES (
          \(Self.sqlLiteral(UUID().uuidString)),
          \(Self.sqlLiteral(scanID)),
          \(Self.sqlLiteral(result.source.sourceID)),
          TIMESTAMP '\(Self.duckTimestamp(Date()))',
          \(Self.sqlLiteral(result.source.provider)),
          \(Self.sqlLiteral(result.source.sourceURL)),
          \(Self.sqlLiteral(result.status)),
          \(Self.sqlLiteral(result.source.installedFile)),
          \(Self.sqlLiteral(result.source.installedVersion)),
          \(Self.sqlLiteral(result.latestVersion)),
          \(Self.sqlLiteral(result.latestURL)),
          \(Self.sqlLiteral(result.details))
        );
        """)
    }

    private func publishUpdateActivity(scanID: String, checked: Int, candidates: Int, unresolved: Int, seeded: Int) throws {
        let timestamp = Self.displayTimestamp(Date())
        let feed: [String: Any] = [
            "updated_at": timestamp,
            "entry_count": 1,
            "entries": [[
                "timestamp": timestamp,
                "stage": "scan",
                "status": unresolved == 0 ? "ok" : "warning",
                "message": "Mod source scan \(scanID): checked \(checked) URL(s), found \(candidates) candidate(s), unresolved \(unresolved), seeded \(seeded) source row(s)."
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: feed, options: [.prettyPrinted, .sortedKeys])
        for target in [
            config.projectRoot.appendingPathComponent("site/public/update-activity.json"),
            config.projectRoot.appendingPathComponent("site/public/data/update-activity.json")
        ] {
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
    }

    private func fetchText(_ url: URL) throws -> String {
        String(decoding: try fetchData(url), as: UTF8.self)
    }

    private func fetchData(_ url: URL) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("PummelchenModUpdateScanner/1.0", forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        let output = URLFetchResultBox()
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                output.store(.failure(error))
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                if let data,
                   String(decoding: data, as: UTF8.self).lowercased().contains("challenges.cloudflare.com") {
                    output.store(.success(data))
                    return
                }
                output.store(.failure(ModUpdateScannerError.network("HTTP \(http.statusCode) for \(url.absoluteString)")))
                return
            }
            output.store(.success(data ?? Data()))
        }.resume()
        semaphore.wait()
        guard let result = output.result() else {
            throw ModUpdateScannerError.network("request produced no response for \(url.absoluteString)")
        }
        return try result.get()
    }

    private func execute(_ sql: String) throws {
        try database.execute(sql)
    }

    private func query(_ sql: String) throws -> String {
        try database.queryCSV(sql)
    }

    private static func classify(installedVersion: String?, latestVersion: String?) -> String {
        guard let latestVersion, !latestVersion.isEmpty else { return "unresolved" }
        guard let installedVersion, !installedVersion.isEmpty else { return "unknown_installed_version" }
        return normalizedVersion(installedVersion) == normalizedVersion(latestVersion) ? "current" : "update_available"
    }

    private static func modrinthSlug(from url: URL) -> String? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "mod"), parts.indices.contains(index + 1) else {
            return nil
        }
        return parts[index + 1]
    }

    private static func files(from value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && ($0.hasSuffix(".jar") || $0.hasSuffix(".zip")) }
    }

    private static func modKey(displayName: String, installedFile: String?, sourceURL: String) -> String {
        let raw = installedFile ?? displayName
        let value = raw
            .lowercased()
            .replacingOccurrences(of: #"\.(jar|zip)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return value.isEmpty ? stableID(sourceURL) : value
    }

    private static func versionFromFilename(_ filename: String) -> String? {
        let base = filename.replacingOccurrences(of: #"\.(jar|zip)$"#, with: "", options: .regularExpression)
        let patterns = [
            #"(?i)(?:mc|neoforge|forge)?-?(\d+(?:\.\d+){1,4}(?:[+._-][A-Za-z0-9.]+)*)$"#,
            #"(?i)(v?\d+(?:\.\d+){1,4}(?:[+._-][A-Za-z0-9.]+)*)"#
        ]
        for pattern in patterns {
            if let value = firstMatch(pattern: pattern, in: base) {
                return value
            }
        }
        return nil
    }

    private static func cleanVersionCandidate(_ value: String, provider: String) -> String {
        var result = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if provider == "modrinth", result.contains(" - ") {
            result = String(result.split(separator: " - ").first ?? Substring(result))
        }
        if result.lowercased().contains("minecraft mod") {
            result = result.replacingOccurrences(of: " - Minecraft Mod", with: "")
        }
        return result
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"^(v|mc)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[+_ ]"#, with: "-", options: .regularExpression)
    }

    private static func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[range])
    }

    private func csvRows(_ csv: String) -> [[String]] {
        csv.split(separator: "\n").dropFirst().map { line in
            parseCSVLine(String(line))
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
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
                } else {
                    quoted.toggle()
                }
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

    private static func stableID(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return "src_\(String(hash, radix: 16))"
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func duckTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }

    private static func displayTimestamp(_ date: Date) -> String {
        duckTimestamp(date)
    }
}

private final class URLFetchResultBox: @unchecked Sendable {
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
