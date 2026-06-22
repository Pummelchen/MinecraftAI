import Foundation
import MCPummelchenModShared

public enum MCPummelchenModServerError: Error, CustomStringConvertible {
    case badRequest(String)
    case unauthorized(String)
    case payloadTooLarge(Int)
    case notFound(String)
    case methodNotAllowed

    public var description: String {
        switch self {
        case .badRequest(let message):
            return "bad request: \(message)"
        case .unauthorized(let message):
            return "unauthorized: \(message)"
        case .payloadTooLarge(let size):
            return "payload too large: \(size) bytes"
        case .notFound(let message):
            return "not found: \(message)"
        case .methodNotAllowed:
            return "method not allowed"
        }
    }
}

private struct LiveModSourceInventory {
    let displayName: String
    let sourceURL: String
    let sourceLinks: String
    let installedFiles: String
    let installedVersions: String
    let latestStatuses: String
}

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = headers.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        self.body = body
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let contentType: String
    public let body: Data
    public let headers: [String: String]

    public init(statusCode: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    public static func text(_ value: String, statusCode: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: contentType, body: Data(value.utf8))
    }

    public static func json(_ value: Data, statusCode: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "application/json; charset=utf-8", body: value, headers: headers)
    }
}

public struct MCPummelchenModServerConfig: Sendable {
    public let projectRoot: URL
    public let bindHost: String
    public let port: Int
    public let duckDBURL: URL
    public let clientAPIToken: String?
    public let maxWritePayloadBytes: Int
    public let transportTarget: String
    public let transportFallback: String

    public init(
        projectRoot: URL,
        bindHost: String = "127.0.0.1",
        port: Int = 8787,
        duckDBURL: URL? = nil,
        clientAPIToken: String? = ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"],
        maxWritePayloadBytes: Int = 256 * 1024,
        transportTarget: String = ProcessInfo.processInfo.environment["PUMMELCHEN_TRANSPORT_TARGET"] ?? "nginx_https_api",
        transportFallback: String = "none"
    ) {
        self.projectRoot = projectRoot
        self.bindHost = bindHost
        self.port = port
        self.duckDBURL = duckDBURL ?? projectRoot.appendingPathComponent("data/pummelchen.duckdb")
        self.clientAPIToken = clientAPIToken
        self.maxWritePayloadBytes = maxWritePayloadBytes
        self.transportTarget = transportTarget
        self.transportFallback = transportFallback
    }
}

public struct ServerStatusPayload: Codable, Equatable, Sendable {
    public let apiVersion: String
    public let serverTime: String
    public let requestID: String
    public let service: String
    public let mode: String
    public let projectRoot: String
    public let currentReleaseID: String?
    public let transportTarget: String
    public let transportFallback: String

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case serverTime = "server_time"
        case requestID = "request_id"
        case service
        case mode
        case projectRoot = "project_root"
        case currentReleaseID = "current_release_id"
        case transportTarget = "transport_target"
        case transportFallback = "transport_fallback"
    }
}

public final class MCPummelchenModServerAPI: @unchecked Sendable {
    private let config: MCPummelchenModServerConfig
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let store: ServerClientReportStore
    private let controlStore: ControlEventStore
    private let liveStats: LiveStatsProvider

    public init(config: MCPummelchenModServerConfig) {
        self.config = config
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.store = ServerClientReportStore(databaseURL: config.duckDBURL)
        self.controlStore = ControlEventStore(databaseURL: config.duckDBURL)
        self.liveStats = LiveStatsProvider(projectRoot: config.projectRoot, duckDBURL: config.duckDBURL)
    }

    public func response(for request: HTTPRequest) -> HTTPResponse {
        do {
            let path = normalizedPath(request.path)
            switch (request.method, path) {
            case ("GET", "/api/v1/status"):
                return try status()
            case ("GET", "/api/v1/releases/current"):
                return try currentRelease()
            case ("GET", "/api/v1/clients/health"):
                return try clientHealth()
            case ("GET", "/api/v1/site/live-stats"):
                return try siteLiveStats()
            case ("GET", "/api/v1/minecraft/server-versions"):
                return try minecraftServerVersions()
            case ("GET", "/api/v1/site/mod-inventory/mods"):
                return try siteMergedModInventory()
            case ("GET", "/api/v1/site/mod-inventory/server"):
                return try siteModInventory(scope: "server")
            case ("GET", "/api/v1/site/mod-inventory/client"):
                return try siteModInventory(scope: "client")
            case ("GET", "/api/v1/site/failed-mods"):
                return try siteFailedMods()
            case ("GET", "/api/v1/site/release-history"):
                return try siteReleaseHistory()
            case ("GET", "/api/v1/site/update-activity"):
                return try siteUpdateActivity()
            case ("GET", "/api/v1/site/neoforge-version"):
                return try siteNeoForgeVersion()
            case ("GET", "/api/v1/site/release-health"):
                return try siteReleaseHealth()
            case ("GET", "/api/v1/control/info"):
                return try controlInfo()
            case ("POST", "/api/v1/control/events"):
                try requireAuthorized(request)
                return try createControlEvent(request)
            case ("GET", "/api/v1/control/events"):
                try requireAuthorized(request)
                return try controlEvents(request)
            case ("POST", "/api/v1/control/acks"):
                try requireAuthorized(request)
                return try acknowledgeControlEvent(request)
            case ("POST", "/api/v1/clients/register"):
                try requireAuthorized(request)
                return try registerClient(request)
            case ("POST", "/api/v1/clients/heartbeat"):
                try requireAuthorized(request)
                return try statusReport(request)
            case ("POST", "/api/v1/clients/sync-runs"):
                try requireAuthorized(request)
                return try statusReport(request)
            case ("POST", "/api/v1/clients/inventory"):
                try requireAuthorized(request)
                return try inventoryUpload(request)
            case ("POST", "/api/v1/clients/diagnostics"):
                try requireAuthorized(request)
                return try diagnosticsUpload(request)
            case ("POST", "/api/v1/clients/defaults-events"):
                try requireAuthorized(request)
                return try defaultsEventUpload(request)
            case ("GET", _):
                if let releaseID = releaseManifestID(from: request.path) {
                    return try manifest(releaseID: releaseID)
                }
                throw MCPummelchenModServerError.notFound(request.path)
            default:
                throw MCPummelchenModServerError.methodNotAllowed
            }
        } catch MCPummelchenModServerError.unauthorized(let message) {
            return errorResponse(status: 401, message: message)
        } catch MCPummelchenModServerError.payloadTooLarge(let size) {
            return errorResponse(status: 413, message: "payload too large: \(size) bytes")
        } catch MCPummelchenModServerError.methodNotAllowed {
            return errorResponse(status: 405, message: "method not allowed")
        } catch MCPummelchenModServerError.notFound(let message) {
            return errorResponse(status: 404, message: message)
        } catch MCPummelchenModServerError.badRequest(let message) {
            return errorResponse(status: 400, message: message)
        } catch ContractValidationError.invalid(let message) {
            return errorResponse(status: 400, message: message)
        } catch {
            return errorResponse(status: 500, message: String(describing: error))
        }
    }

    public func smokeCheck() throws {
        let current = try readCurrentReleaseData()
        let release = try CurrentReleaseValidator.decode(current)
        try CurrentReleaseValidator.validate(release)
        _ = try readManifest(releaseID: release.releaseID)
    }

    private func status() throws -> HTTPResponse {
        let release = try? CurrentReleaseValidator.decode(readCurrentReleaseData())
        let payload = ServerStatusPayload(
            apiVersion: "v1",
            serverTime: Self.isoNow(),
            requestID: UUID().uuidString,
            service: "MCPummelchenModServer",
            mode: config.clientAPIToken == nil ? "read_only" : "phase6_writes_enabled",
            projectRoot: config.projectRoot.path,
            currentReleaseID: release?.releaseID,
            transportTarget: config.transportTarget,
            transportFallback: config.transportFallback
        )
        return .json(try encoder.encode(payload))
    }

    private func currentRelease() throws -> HTTPResponse {
        let data = try readCurrentReleaseData()
        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)
        return .json(data)
    }

    private func clientHealth() throws -> HTTPResponse {
        try .json(encoder.encode(store.healthSummary()))
    }

    private func siteLiveStats() throws -> HTTPResponse {
        try .json(
            encoder.encode(liveStats.payload()),
            headers: [
                "Cache-Control": "no-store, max-age=0",
                "X-Pummelchen-Stats-Source": "swift-server"
            ]
        )
    }

    private func siteModInventory(scope: String) throws -> HTTPResponse {
        guard ["server", "client"].contains(scope) else {
            throw MCPummelchenModServerError.badRequest("invalid mod inventory scope")
        }

        let current = try CurrentReleaseValidator.decode(readCurrentReleaseData())
        let supportedVersions = try supportedMinecraftVersionsForInventory()
        let rows = try siteModInventoryRows(scope: scope, current: current, supportedVersions: supportedVersions)
        let payload: [String: Any] = [
            "api_version": "v1",
            "generated_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-site-inventory",
            "scope": scope,
            "release_id": current.releaseID,
            "server_key": current.serverKey,
            "minecraft_version": current.minecraftVersion ?? "",
            "loader_version": current.loaderVersion ?? "",
            "status": "live",
            "supported_versions": supportedVersions,
            "total_entries": rows.count,
            "rows": rows
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-site-inventory"
        ])
    }

    private func siteMergedModInventory() throws -> HTTPResponse {
        let current = try CurrentReleaseValidator.decode(readCurrentReleaseData())
        let supportedVersions = try supportedMinecraftVersionsForInventory()
        let serverRows = try siteModInventoryRows(
            scope: "server",
            current: current,
            supportedVersions: supportedVersions
        )
        let clientRows = try siteModInventoryRows(
            scope: "client",
            current: current,
            supportedVersions: supportedVersions
        )
        let rows = Self.mergedModInventoryRows(serverRows: serverRows, clientRows: clientRows)
        let payload: [String: Any] = [
            "api_version": "v1",
            "generated_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-site-inventory",
            "scope": "mods",
            "release_id": current.releaseID,
            "server_key": current.serverKey,
            "minecraft_version": current.minecraftVersion ?? "",
            "loader_version": current.loaderVersion ?? "",
            "status": "live",
            "supported_versions": supportedVersions,
            "total_entries": rows.count,
            "rows": rows
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-site-inventory"
        ])
    }

    private func siteModInventoryRows(
        scope: String,
        current: CurrentRelease,
        supportedVersions: [[String: Any]]
    ) throws -> [[String: Any]] {
        let liveModSources = try liveModSourceInventory(minecraftVersion: current.minecraftVersion ?? "")
        let versionedModSources = try versionedModSourceInventory(supportedVersions: supportedVersions)
        let currentManifestFiles = try currentReleaseManifestFileRoles(current: current, scope: scope)
        var rows: [[String: Any]] = []
        rows.append(contentsOf: missingManifestInventoryRows(
            existingRows: rows,
            currentManifestFiles: currentManifestFiles,
            current: current,
            supportedVersions: supportedVersions,
            liveModSources: liveModSources,
            versionedModSources: versionedModSources
        ))
        return rows.map {
            var row = $0
            row.removeValue(forKey: "_has_inventory_evidence")
            row.removeValue(forKey: "_manifest_role")
            return row
        }
    }

    private static func mergedModInventoryRows(serverRows: [[String: Any]], clientRows: [[String: Any]]) -> [[String: Any]] {
        var merged: [String: [String: Any]] = [:]
        var order: [String] = []
        var placement: [String: (server: Bool, client: Bool)] = [:]
        var generatedServerRows = Set<String>()

        func add(_ row: [String: Any], isServer: Bool, isClient: Bool) {
            let key = modInventoryMergeKey(row)
            if merged[key] == nil {
                merged[key] = row
                order.append(key)
            } else {
                merged[key] = mergedModInventoryRow(merged[key] ?? [:], with: row)
            }
            let previous = placement[key] ?? (server: false, client: false)
            placement[key] = (server: previous.server || isServer, client: previous.client || isClient)
            if isServer, isGeneratedDuckDBInventoryRow(row) {
                generatedServerRows.insert(key)
            }
        }

        serverRows.forEach { add($0, isServer: true, isClient: false) }
        clientRows.forEach { add($0, isServer: false, isClient: true) }

        return order.compactMap { key in
            guard var row = merged[key] else { return nil }
            let flags = placement[key] ?? (server: false, client: false)
            let serverPlacement = flags.server && !(flags.client && generatedServerRows.contains(key))
            let placementLabel = modInventoryPlacementLabel(server: serverPlacement, client: flags.client)
            row["placement"] = placementLabel
            row["scope"] = placementLabel
            let existingSearch = row["search"] as? String ?? ""
            row["search"] = "\(existingSearch) \(placementLabel)"
            return row
        }.sorted {
            String(describing: $0["name"] ?? "").localizedCaseInsensitiveCompare(String(describing: $1["name"] ?? "")) == .orderedAscending
        }
    }

    private static func isGeneratedDuckDBInventoryRow(_ row: [String: Any]) -> Bool {
        return (row["details"] as? String ?? "").contains("generated from DuckDB")
    }

    private static func modInventoryMergeKey(_ row: [String: Any]) -> String {
        if let sourceURL = row["sourceUrl"] as? String, !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "url:\(sourceURL.lowercased())"
        }
        if let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "name:\(normalizedModInventoryKey(name))"
        }
        if let files = row["files"] as? String, !files.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "files:\(normalizedModInventoryKey(files))"
        }
        return "row:unknown"
    }

    private static func mergedModInventoryRow(_ existing: [String: Any], with incoming: [String: Any]) -> [String: Any] {
        var row = existing
        for field in ["name", "type", "sourceUrl", "sourceHost"] where (row[field] as? String ?? "").isEmpty {
            row[field] = incoming[field]
        }
        row["files"] = mergedInventoryList(existing["files"] as? String, incoming["files"] as? String)
        row["versionFile"] = mergedInventoryList(existing["versionFile"] as? String, incoming["versionFile"] as? String)
        row["installed_version"] = mergedInventoryList(existing["installed_version"] as? String, incoming["installed_version"] as? String)
        row["compatibility"] = mergedCompatibility(existing["compatibility"] as? [String: String], incoming["compatibility"] as? [String: String])

        let existingDetails = existing["details"] as? String ?? ""
        let incomingDetails = incoming["details"] as? String ?? ""
        if existingDetails.isEmpty {
            row["details"] = incomingDetails
        } else if !incomingDetails.isEmpty, !existingDetails.contains(incomingDetails) {
            row["details"] = "\(existingDetails) Also included in the Mac client package when required."
        }

        let search = [existing["search"] as? String, incoming["search"] as? String]
            .compactMap { $0 }
            .joined(separator: " ")
        if !search.isEmpty {
            row["search"] = search
        }
        return row
    }

    private static func mergedInventoryList(_ left: String?, _ right: String?) -> String {
        var seen = Set<String>()
        var values: [String] = []
        for value in [left, right].compactMap({ $0 }) {
            for item in splitInventoryFileList(value) {
                let key = item.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    values.append(item)
                }
            }
        }
        return values.joined(separator: ", ")
    }

    private static func mergedCompatibility(_ left: [String: String]?, _ right: [String: String]?) -> [String: String] {
        var values = left ?? [:]
        for (version, status) in right ?? [:] {
            let existing = values[version] ?? ""
            if compatibilityRank(status) > compatibilityRank(existing) {
                values[version] = status
            }
        }
        return values
    }

    private static func compatibilityRank(_ value: String) -> Int {
        switch value.lowercased() {
        case "active": return 6
        case "staged": return 5
        case "compatible": return 4
        case "compatible by file": return 3
        case "needs test": return 2
        case "not installed": return 1
        default: return 0
        }
    }

    private static func hasCompatibleScanEvidence(_ statuses: String) -> Bool {
        let values = statuses
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return values.contains("current")
            || values.contains("update_available")
            || values.contains("unknown_installed_version")
    }

    private static func modInventoryPlacementLabel(server: Bool, client: Bool) -> String {
        switch (server, client) {
        case (true, true): return "Server & Client Mod"
        case (true, false): return "Server Mod"
        case (false, true): return "Client Mod"
        default: return "Unknown"
        }
    }

    private func siteFailedMods() throws -> HTTPResponse {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT
          COALESCE(CAST(failed_at AS VARCHAR), '') AS failed_at,
          title,
          COALESCE(source_url, '') AS source_url,
          COALESCE(filename, '') AS filename,
          COALESCE(installed_version, '') AS installed_version,
          failure_reason,
          COALESCE(details, '') AS details,
          COALESCE(latest_status, 'not_checked') AS latest_status,
          COALESCE(latest_version, '') AS latest_version,
          COALESCE(latest_url, '') AS latest_url,
          COALESCE(last_check_details, '') AS last_check_details,
          COALESCE(CAST(last_checked_at AS VARCHAR), '') AS last_checked_at,
          COALESCE(minecraft_version, '') AS minecraft_version,
          COALESCE(loader_version, '') AS loader_version,
          active_status
        FROM core.failed_mod_update_status
        WHERE lower(active_status) IN ('failed', 'banned by admin')
        ORDER BY failed_at DESC NULLS LAST, title ASC;
        """)
        let rows = Self.parseCSV(csv).map { row -> [String: Any] in
            let failedAtRaw = row["failed_at"] ?? ""
            let lastCheckedRaw = row["last_checked_at"] ?? ""
            let failedAt = failedAtRaw.isEmpty ? "" : Self.isoTimestamp(fromDuckDB: failedAtRaw)
            let lastCheckedAt = lastCheckedRaw.isEmpty ? "" : Self.isoTimestamp(fromDuckDB: lastCheckedRaw)
            let search = [
                row["title"],
                row["source_url"],
                row["filename"],
                row["installed_version"],
                row["failure_reason"],
                row["details"],
                row["latest_status"],
                row["latest_version"],
                row["last_check_details"],
                row["minecraft_version"],
                row["loader_version"]
            ].compactMap { $0 }.joined(separator: " ")
            return [
                "failed_at": failedAt,
                "failed_at_display": Self.displayTimestamp(fromISO: failedAt),
                "title": row["title"] ?? "",
                "source_url": row["source_url"] ?? "",
                "filename": row["filename"] ?? "",
                "version": row["installed_version"] ?? "",
                "failure_reason": row["failure_reason"] ?? "",
                "details": row["details"] ?? "",
                "latest_status": row["latest_status"] ?? "not_checked",
                "latest_version": row["latest_version"] ?? "",
                "latest_url": row["latest_url"] ?? "",
                "last_check_details": row["last_check_details"] ?? "",
                "last_checked_at": lastCheckedAt,
                "last_checked_at_display": Self.displayTimestamp(fromISO: lastCheckedAt),
                "minecraft_version": row["minecraft_version"] ?? "",
                "loader_version": row["loader_version"] ?? "",
                "search": search.lowercased()
            ]
        }
        let payload: [String: Any] = [
            "api_version": "v1",
            "generated_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-duckdb-failed-mods",
            "total_entries": rows.count,
            "rows": rows
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-duckdb"
        ])
    }

    private func supportedMinecraftVersionsForInventory() throws -> [[String: Any]] {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT minecraft_version, loader_version, status, is_live, sort_order
        FROM reporting.v_minecraft_server_versions
        WHERE lower(status) IN ('live', 'staging')
        ORDER BY sort_order, minecraft_version;
        """)
        let rows = Self.parseCSV(csv).compactMap { row -> [String: Any]? in
            guard let version = row["minecraft_version"], !version.isEmpty else {
                return nil
            }
            return [
                "minecraft_version": version,
                "loader_version": row["loader_version"] ?? "",
                "status": row["status"] ?? "",
                "is_live": Self.duckBool(row["is_live"] ?? ""),
                "sort_order": Int(row["sort_order"] ?? "") ?? 100
            ]
        }
        try ContractValidation.require(!rows.isEmpty, "DuckDB supported Minecraft versions view returned no live/staging rows")
        return rows
    }

    private func annotatedModInventoryRow(
        _ row: [String: Any],
        current: CurrentRelease,
        supportedVersions: [[String: Any]],
        liveModSources: [String: LiveModSourceInventory],
        versionedModSources: [String: [String: LiveModSourceInventory]],
        currentManifestFiles: [String: String]
    ) -> [String: Any] {
        let currentVersion = current.minecraftVersion ?? ""
        let sourceByVersion = versionedModSource(for: row, versionedModSources: versionedModSources) ?? [:]
        let inCurrentManifest = rowMatchesCurrentManifest(row, currentManifestFiles: currentManifestFiles)
        let searchable = [
            row["name"] as? String,
            row["files"] as? String,
            row["versionFile"] as? String,
            row["details"] as? String,
            row["search"] as? String,
            row["sourceUrl"] as? String
        ].compactMap { $0?.lowercased() }.joined(separator: " ")

        var compatibility: [String: String] = [:]
        for version in supportedVersions {
            guard let minecraftVersion = version["minecraft_version"] as? String, !minecraftVersion.isEmpty else {
                continue
            }
            let versionStatus = (version["status"] as? String)?.lowercased() ?? ""
            if minecraftVersion == currentVersion && (sourceByVersion[minecraftVersion] != nil || inCurrentManifest) {
                compatibility[minecraftVersion] = "Active"
            } else if let versionSource = sourceByVersion[minecraftVersion], versionStatus == "staging" {
                compatibility[minecraftVersion] = Self.hasCompatibleScanEvidence(versionSource.latestStatuses) ? "Compatible" : "Needs test"
            } else if let versionSource = sourceByVersion[minecraftVersion] {
                compatibility[minecraftVersion] = Self.hasCompatibleScanEvidence(versionSource.latestStatuses) ? "Compatible" : "Needs test"
            } else if Self.modInventoryText(searchable, mentionsMinecraftVersion: minecraftVersion),
                      minecraftVersion != currentVersion {
                compatibility[minecraftVersion] = versionStatus == "staging" ? "Needs test" : "Compatible by file"
            } else if versionStatus == "staging" {
                compatibility[minecraftVersion] = "Needs test"
            } else {
                compatibility[minecraftVersion] = "Not installed"
            }
        }

        var annotated = row
        if let live = sourceByVersion[currentVersion] ?? liveModSource(for: row, liveModSources: liveModSources) {
            if !live.displayName.isEmpty {
                annotated["name"] = live.displayName
            }
            annotated["files"] = live.installedFiles
            annotated["versionFile"] = live.installedFiles
            annotated["installed_version"] = live.installedVersions
            annotated["sourceLinks"] = Self.sourceLinksPayload(live.sourceLinks)
            if !live.sourceURL.isEmpty {
                annotated["sourceUrl"] = live.sourceURL
                annotated["sourceHost"] = URL(string: live.sourceURL)?.host ?? live.sourceURL
            }
            let existingSearch = annotated["search"] as? String ?? ""
            annotated["search"] = "\(existingSearch) \(live.installedFiles) \(live.installedVersions) \(live.sourceURL)"
        }
        let manifestRole = annotated["_manifest_role"] as? String ?? ""
        let fallbackType = annotated["type"] as? String ?? "Gameplay"
        annotated["type"] = Self.playerFacingModType(
            name: annotated["name"] as? String ?? "",
            files: [
                annotated["files"] as? String,
                annotated["versionFile"] as? String,
                annotated["sourceUrl"] as? String
            ].compactMap { $0 }.joined(separator: " "),
            manifestRole: manifestRole,
            fallback: fallbackType
        )
        annotated["compatibility"] = compatibility
        annotated["_has_inventory_evidence"] = inCurrentManifest || !sourceByVersion.isEmpty
        return annotated
    }

    private func currentReleaseManifestFileRoles(current: CurrentRelease, scope: String) throws -> [String: String] {
        let manifestName = scope == "server" ? "server-files.tsv" : "client-package.tsv"
        let candidates = [
            config.projectRoot.appendingPathComponent("releases/\(current.releaseID)/manifests/\(manifestName)"),
            config.projectRoot.appendingPathComponent("site/public/downloads/releases/\(current.releaseID)/manifests/\(manifestName)")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            let text = try String(contentsOf: try safeProjectFile(candidate), encoding: .utf8)
            return Self.parseManifestFileRoles(text, scope: scope)
        }
        throw MCPummelchenModServerError.notFound("current release \(manifestName) for \(current.releaseID)")
    }

    private static func parseManifestFileRoles(_ text: String, scope: String) -> [String: String] {
        var files: [String: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else {
                continue
            }
            let role = fields[0]
            if scope == "server", role != "server_mod" {
                continue
            }
            let relativePath = fields[1]
            let fileName = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
            if !fileName.isEmpty {
                files[fileName] = role
            }
        }
        return files
    }

    private func rowMatchesCurrentManifest(_ row: [String: Any], currentManifestFiles: [String: String]) -> Bool {
        guard !currentManifestFiles.isEmpty else {
            return false
        }
        let candidates = [
            row["files"] as? String,
            row["versionFile"] as? String
        ].compactMap { $0 }
        for candidate in candidates {
            for piece in Self.splitInventoryFileList(candidate) {
                let fileName = URL(fileURLWithPath: piece).lastPathComponent.lowercased()
                if currentManifestFiles[fileName] != nil {
                    return true
                }
            }
        }
        return false
    }

    private func modSourceLatestScanResultCTE(whereClause: String) throws -> String {
        if try duckDBTableExists(schema: "core", table: "mod_update_scan_results") {
            return """
            WITH latest_scan_result AS (
              SELECT source_id, minecraft_version, status
              FROM (
                SELECT
                  source_id,
                  minecraft_version,
                  status,
                  row_number() OVER (
                    PARTITION BY source_id, minecraft_version
                    ORDER BY checked_at DESC
                  ) AS rn
                FROM core.mod_update_scan_results
                WHERE \(whereClause)
              )
              WHERE rn = 1
            )
            """
        }
        return """
        WITH latest_scan_result AS (
          SELECT
            CAST(NULL AS VARCHAR) AS source_id,
            CAST(NULL AS VARCHAR) AS minecraft_version,
            CAST(NULL AS VARCHAR) AS status
          WHERE false
        )
        """
    }

    private func duckDBTableExists(schema: String, table: String) throws -> Bool {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT COUNT(*)
        FROM information_schema.tables
        WHERE table_schema = \(Self.sqlLiteral(schema))
          AND table_name = \(Self.sqlLiteral(table));
        """)
        return Self.parseCSV(csv).first?["count_star()"] == "1"
    }

    private func modSourceLinksJoinSQL() throws -> String {
        guard try duckDBTableExists(schema: "core", table: "mod_source_links") else {
            return """
                  LEFT JOIN (
                    SELECT
                      CAST(NULL AS VARCHAR) AS source_id,
                      CAST(NULL AS VARCHAR) AS minecraft_version,
                      CAST(NULL AS VARCHAR) AS source_links
                    WHERE false
                  ) l
                    ON false
            """
        }
        return """
              LEFT JOIN (
                SELECT
                  source_id,
                  minecraft_version,
                  string_agg(
                    DISTINCT link_role || '|||' || provider || '|||' || source_url,
                    '~~~'
                    ORDER BY link_role || '|||' || provider || '|||' || source_url
                  ) AS source_links
                FROM core.mod_source_links
                WHERE active
                  AND (source_url LIKE 'http://%' OR source_url LIKE 'https://%')
                GROUP BY source_id, minecraft_version
              ) l
                ON l.source_id = s.source_id
               AND l.minecraft_version = s.minecraft_version
        """
    }

    private func versionedModSourceInventory(supportedVersions: [[String: Any]]) throws -> [String: [String: LiveModSourceInventory]] {
        let versions = supportedVersions.compactMap { $0["minecraft_version"] as? String }.filter { !$0.isEmpty }
        guard !versions.isEmpty else {
            return [:]
        }
        let versionList = versions.map(Self.sqlLiteral).joined(separator: ", ")
        let latestScanCTE = try modSourceLatestScanResultCTE(whereClause: "minecraft_version IN (\(versionList))")
        let sourceLinksJoin = try modSourceLinksJoinSQL()
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
              \(latestScanCTE)
              SELECT
                lower(s.source_url) AS source_url_key,
                s.source_url,
                COALESCE(l.source_links, 'primary' || '|||' || s.provider || '|||' || s.source_url) AS source_links,
                s.display_name,
                regexp_replace(lower(s.display_name), '[^a-z0-9]+', '-', 'g') AS name_key,
                s.minecraft_version,
                string_agg(DISTINCT s.installed_file, ', ' ORDER BY s.installed_file) AS installed_files,
                string_agg(DISTINCT COALESCE(s.installed_version, ''), ', ' ORDER BY COALESCE(s.installed_version, '')) AS installed_versions,
                string_agg(DISTINCT COALESCE(r.status, ''), ', ' ORDER BY COALESCE(r.status, '')) AS latest_statuses
              FROM core.mod_sources
              s
              LEFT JOIN latest_scan_result r
                ON r.source_id = s.source_id
               AND r.minecraft_version = s.minecraft_version
              \(sourceLinksJoin)
              WHERE s.active
                AND s.minecraft_version IN (\(versionList))
                AND COALESCE(s.installed_file, '') <> ''
              GROUP BY 1, 2, 3, 4, 5, 6;
              """)

        var values: [String: [String: LiveModSourceInventory]] = [:]
        for row in Self.parseCSV(csv) {
            guard let minecraftVersion = row["minecraft_version"], !minecraftVersion.isEmpty else {
                continue
            }
            let inventory = LiveModSourceInventory(
                displayName: row["display_name"] ?? "",
                sourceURL: row["source_url"] ?? "",
                sourceLinks: row["source_links"] ?? "",
                installedFiles: row["installed_files"] ?? "",
                installedVersions: row["installed_versions"] ?? "",
                latestStatuses: row["latest_statuses"] ?? ""
            )
            if let sourceURL = row["source_url_key"], !sourceURL.isEmpty {
                values["url:\(sourceURL)", default: [:]][minecraftVersion] = inventory
            }
            if let name = row["name_key"], !name.isEmpty {
                values["name:\(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")))", default: [:]][minecraftVersion] = inventory
            }
            for fileName in Self.splitInventoryFileList(inventory.installedFiles) {
                let key = URL(fileURLWithPath: fileName).lastPathComponent.lowercased()
                if !key.isEmpty {
                    values["file:\(key)", default: [:]][minecraftVersion] = inventory
                }
            }
        }
        return values
    }

    private func liveModSourceInventory(minecraftVersion: String) throws -> [String: LiveModSourceInventory] {
        guard !minecraftVersion.isEmpty else {
            return [:]
        }
        let latestScanCTE = try modSourceLatestScanResultCTE(whereClause: "minecraft_version = \(Self.sqlLiteral(minecraftVersion))")
        let sourceLinksJoin = try modSourceLinksJoinSQL()
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
              \(latestScanCTE)
              SELECT
                lower(s.source_url) AS source_url_key,
                s.source_url,
                COALESCE(l.source_links, 'primary' || '|||' || s.provider || '|||' || s.source_url) AS source_links,
                s.display_name,
                regexp_replace(lower(s.display_name), '[^a-z0-9]+', '-', 'g') AS name_key,
                string_agg(DISTINCT s.installed_file, ', ' ORDER BY s.installed_file) AS installed_files,
                string_agg(DISTINCT COALESCE(s.installed_version, ''), ', ' ORDER BY COALESCE(s.installed_version, '')) AS installed_versions,
                string_agg(DISTINCT COALESCE(r.status, ''), ', ' ORDER BY COALESCE(r.status, '')) AS latest_statuses
              FROM core.mod_sources
              s
              LEFT JOIN latest_scan_result r
                ON r.source_id = s.source_id
               AND r.minecraft_version = s.minecraft_version
              \(sourceLinksJoin)
              WHERE s.active
                AND s.minecraft_version = \(Self.sqlLiteral(minecraftVersion))
                AND COALESCE(s.installed_file, '') <> ''
              GROUP BY 1, 2, 3, 4, 5;
              """)
        var values: [String: LiveModSourceInventory] = [:]
        for row in Self.parseCSV(csv) {
            let inventory = LiveModSourceInventory(
                displayName: row["display_name"] ?? "",
                sourceURL: row["source_url"] ?? "",
                sourceLinks: row["source_links"] ?? "",
                installedFiles: row["installed_files"] ?? "",
                installedVersions: row["installed_versions"] ?? "",
                latestStatuses: row["latest_statuses"] ?? ""
            )
            if let sourceURL = row["source_url_key"], !sourceURL.isEmpty {
                values["url:\(sourceURL)"] = inventory
            }
            if let name = row["name_key"], !name.isEmpty {
                values["name:\(name.trimmingCharacters(in: CharacterSet(charactersIn: "-")))"] = inventory
            }
            for fileName in Self.splitInventoryFileList(inventory.installedFiles) {
                let key = URL(fileURLWithPath: fileName).lastPathComponent.lowercased()
                if !key.isEmpty {
                    values["file:\(key)"] = inventory
                }
            }
        }
        return values
    }

    private func missingManifestInventoryRows(
        existingRows: [[String: Any]],
        currentManifestFiles: [String: String],
        current: CurrentRelease,
        supportedVersions: [[String: Any]],
        liveModSources: [String: LiveModSourceInventory],
        versionedModSources: [String: [String: LiveModSourceInventory]]
    ) -> [[String: Any]] {
        var existingFiles = Set<String>()
        for row in existingRows {
            for candidate in [row["files"] as? String, row["versionFile"] as? String].compactMap({ $0 }) {
                Self.splitInventoryFileList(candidate)
                    .forEach { existingFiles.insert(URL(fileURLWithPath: $0).lastPathComponent.lowercased()) }
            }
        }

        return currentManifestFiles
            .filter { !existingFiles.contains($0.key) }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { fileName, role in
                let displayName = Self.displayNameFromManifestFile(fileName)
                let row: [String: Any] = [
                    "name": displayName,
                    "type": Self.typeLabel(forManifestRole: role, fileName: fileName, displayName: displayName),
                    "files": fileName,
                    "versionFile": fileName,
                    "sourceUrl": "",
                    "sourceHost": "release manifest",
                    "details": "\(displayName) is shipped by the active release manifest. No source URL is recorded in DuckDB yet.",
                    "search": "\(displayName) \(fileName) \(role)",
                    "_manifest_role": role
                ]
                return annotatedModInventoryRow(
                    row,
                    current: current,
                    supportedVersions: supportedVersions,
                    liveModSources: liveModSources,
                    versionedModSources: versionedModSources,
                    currentManifestFiles: currentManifestFiles
                )
            }
    }

    private static func typeLabel(forManifestRole role: String, fileName: String = "", displayName: String = "") -> String {
        switch role {
        case "server_mod", "mods", "client_mods":
            return playerFacingModType(name: displayName, files: fileName, manifestRole: role)
        case "resourcepacks", "client_resourcepacks": return "Textures Resource Pack"
        case "shaderpacks", "client_shaderpacks": return fileName.lowercased().hasSuffix(".txt") ? "Shader Configuration" : "Shader Pack"
        case "tools", "client_tools": return "Configuration"
        default: return "Release Manifest"
        }
    }

    private static func playerFacingModType(name: String, files: String, manifestRole: String = "", fallback: String = "Gameplay") -> String {
        let value = "\(name) \(files) \(fallback)".lowercased()
        let role = manifestRole.lowercased()
        if role.contains("resourcepack") { return "Textures Resource Pack" }
        if role.contains("shaderpack") {
            return files.lowercased().contains(".txt") ? "Shader Configuration" : "Shader Pack"
        }
        if role.contains("tool") { return "Configuration" }
        if containsAny(value, [
            "architectury", "balm", "bookshelf", "catalogue", "citadel", "cloth-config", "collective",
            "configured", "cupboard", "framework", "geckolib", "glitchcore", "kotlin", "lithostitched",
            "moonlight", "mru", "playeranimation", "prickle", "puzzleslib", "resourcefulconfig",
            "resourcefullib", "smartbrainlib", "terrablender", "yungsapi", "aquamirae api",
            "aquariuslibs", "bagus", "better_lib", "berezka", "coroutil", "craterlib", "creativecore",
            "cristellib", "curios", "cyclopscore", "epherolib", "forgeendertech", "jauml",
            "mint lib", "mint_lib", "monolib", "oelib", "unified api", "yet-another-config",
            "yetanotherconfiglib"
        ]) {
            return "Library"
        }
        if containsAny(value, [
            "ai-improvements", "alternate_current", "cull", "dynamic-fps", "embeddium", "entityculling",
            "connectivity", "clumps", "dynamic view", "dynamicview", "ferritecore", "immediatelyfast",
            "lithium", "low latency", "low-latency", "modernfix", "noisium", "smoothchunk", "sodium", "spark"
        ]) {
            return "Performance"
        }
        if containsAny(value, [
            "betterf3", "debug", "f3"
        ]) {
            return "Client HUD"
        }
        if containsAny(value, [
            "ambient", "camera", "emf", "entity_model", "entity_texture", "etf", "iris",
            "extra animations", "model", "panorama", "physics", "shader", "spawnanimations",
            "visual", "volumetrics"
        ]) {
            return "Client Visuals"
        }
        if containsAny(value, ["sound", "ambience", "ambient environment"]) {
            return "Sound and Ambience"
        }
        if containsAny(value, ["modernarch", "texture", "resource pack", "glowing ores"]) {
            return "Textures Resource Pack"
        }
        if containsAny(value, [
            "bioluminescence", "lambdynamiclights", "factory lights", "lantern", "lamp", "lighting",
            "lights", "luminax", "magnum torch", "torch"
        ]) {
            return "Lighting"
        }
        if containsAny(value, [
            "beach", "biome", "biomes", "geophilic", "jungle", "prettybeaches", "river", "tectonic",
            "terrain", "terralith", "tropicraft", "underground rivers", "wild world", "worldgen"
        ]) {
            return "Biomes and Terrain"
        }
        if containsAny(value, [
            "abandoned", "arena", "castle", "camp", "complementary structures", "depillage",
            "desert temple", "desert tomb", "dungeon", "explorify", "fortress", "hobbit",
            "illager", "lost castle", "lost city", "moai", "moog", "paths", "portal", "ruin",
            "ship", "snowy tents", "statue", "stronghold", "structure", "temple", "tent",
            "tower", "town", "village", "villager", "warship", "wreck"
        ]) {
            return "Structures and Villages"
        }
        if containsAny(value, [
            "aircraft", "automobility", "boat", "car mod", "car-neoforge", "carts", "flight",
            "immersive vehicles", "minecart", "plane", "planes", "trains", "ultimate car",
            "vehicle", "vehicles"
        ]) {
            return "Cars and Planes"
        }
        if containsAny(value, [
            "aquaculture", "autofishing", "fish", "fishtank", "fishing"
        ]) {
            return "Fishing"
        }
        if containsAny(value, [
            "alligator", "animal", "bear", "bird", "bull shark", "cow", "crab", "duck", "fauna",
            "fennec", "giraffe", "goose", "hog", "manatee", "meerkat", "mob", "mouse", "naturalist",
            "owl", "pet", "phantom", "plushables", "quack", "rabbit", "realistic bees", "shark",
            "snow leopard", "springhare", "sugar glider", "waddles", "wildlife"
        ]) {
            return "Animals"
        }
        if containsAny(value, [
            "creeper", "golem", "hunter", "monster", "mutant", "skeleton", "spider", "stray",
            "tiny skeleton", "variantsandventures", "wolf", "zombie"
        ]) {
            return "Mobs and Monsters"
        }
        if containsAny(value, [
            "crop", "fallingtree", "farm", "fertilizer", "field", "garden", "harvest", "hydrofarm",
            "giant natural additions", "kelp", "leaves", "plant", "sapling", "seed", "tree", "watering"
        ]) {
            return "Farming and Gardens"
        }
        if containsAny(value, [
            "factory", "laserio", "machine", "mechanism", "pipe", "power", "technology"
        ]) {
            return "Technology"
        }
        if containsAny(value, [
            "building", "chipped", "chimney", "comforts", "decor", "display", "door", "fence",
            "furniture", "handcrafted", "macaw", "paint", "refurbished", "rechiseled", "roof",
            "stoneworks", "table", "window"
        ]) {
            return "Building and Decor"
        }
        if containsAny(value, [
            "backpack", "bartering", "chest", "goblin trader", "inventory", "storage", "trade",
            "trading", "water bucket"
        ]) {
            return "Storage and Trading"
        }
        if containsAny(value, [
            "armor", "arrow", "axe", "bomb", "combat", "dynamite", "gun", "jeg", "shield", "tnt",
            "torchbow", "weapon"
        ]) {
            return "Weapons and Combat"
        }
        if containsAny(value, [
            "burger", "choco", "chocolate", "cooker", "cooking", "cuisine", "farmersdelight", "food",
            "kiwi", "meal", "milk", "nutritious"
        ]) {
            return "Food and Cooking"
        }
        if containsAny(value, [
            "aether", "artifact", "artifacts", "beacon", "magic", "mystic", "portal", "trinket"
        ]) {
            return "Magic and Artifacts"
        }
        if containsAny(value, [
            "deposit", "easiernetherite", "mineral", "mining", "netherite", "ore", "rich ores"
        ]) {
            return "Mining and Ores"
        }
        if containsAny(value, [
            "clean swing", "elytra", "leash", "movement", "recast", "tools+", "tools-neoforge",
            "toolsplus"
        ]) {
            return "Movement and Utility"
        }
        if containsAny(value, ["map", "journey", "waystone", "navigation"]) {
            return "Maps and Navigation"
        }
        if containsAny(value, ["weather"]) {
            return "Weather"
        }
        return fallbackTypeLabel(fallback)
    }

    private static func fallbackTypeLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.isEmpty || [
            "server mod", "client mod", "test new mods", "requested url batch", "requested 2026-06-03",
            "world mods", "world mods - fix", "core game mods", "provided local jar", "watchlist",
            "online resources"
        ].contains(lower) {
            return "Gameplay"
        }
        if lower == "dependency" { return "Library" }
        if lower == "server optimizer" { return "Performance" }
        if lower == "client mods" { return "Client Visuals" }
        if lower == "custom datapacks" { return "Configuration" }
        if lower == "worldgen and structures" || lower == "utility and world generation" {
            return "Biomes and Terrain"
        }
        return trimmed.split(separator: " ").prefix(5).joined(separator: " ")
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    private static func displayNameFromManifestFile(_ fileName: String) -> String {
        fileName
            .replacingOccurrences(of: #"\.(jar|zip|json|toml|properties|txt|sh)$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[-_]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitInventoryFileList(_ value: String) -> [String] {
        value
            .replacingOccurrences(of: " + ", with: ",")
            .replacingOccurrences(of: ";", with: ",")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func sourceLinksPayload(_ value: String) -> [[String: String]] {
        value
            .components(separatedBy: "~~~")
            .compactMap { line -> [String: String]? in
                let parts = line.components(separatedBy: "|||")
                guard parts.count >= 3, !parts[2].isEmpty else {
                    return nil
                }
                return [
                    "role": parts[0],
                    "provider": parts[1],
                    "url": parts[2],
                    "host": URL(string: parts[2])?.host ?? parts[2]
                ]
            }
    }

    private func liveModSource(for row: [String: Any], liveModSources: [String: LiveModSourceInventory]) -> LiveModSourceInventory? {
        if let sourceURL = (row["sourceUrl"] as? String)?.lowercased(), let value = liveModSources["url:\(sourceURL)"] {
            return value
        }
        if let name = row["name"] as? String,
           let value = liveModSources["name:\(Self.normalizedModInventoryKey(name))"] {
            return value
        }
        for fileName in Self.inventoryFileNames(for: row) {
            if let value = liveModSources["file:\(fileName)"] {
                return value
            }
        }
        return nil
    }

    private func versionedModSource(
        for row: [String: Any],
        versionedModSources: [String: [String: LiveModSourceInventory]]
    ) -> [String: LiveModSourceInventory]? {
        if let sourceURL = (row["sourceUrl"] as? String)?.lowercased(), let value = versionedModSources["url:\(sourceURL)"] {
            return value
        }
        if let name = row["name"] as? String,
           let value = versionedModSources["name:\(Self.normalizedModInventoryKey(name))"] {
            return value
        }
        for fileName in Self.inventoryFileNames(for: row) {
            if let value = versionedModSources["file:\(fileName)"] {
                return value
            }
        }
        return nil
    }

    private static func inventoryFileNames(for row: [String: Any]) -> [String] {
        [row["files"] as? String, row["versionFile"] as? String]
            .compactMap { $0 }
            .flatMap(splitInventoryFileList)
            .map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }
            .filter { !$0.isEmpty }
    }

    private static func modInventoryText(_ text: String, mentionsMinecraftVersion version: String) -> Bool {
        let normalized = version.lowercased()
        let underscore = normalized.replacingOccurrences(of: ".", with: "_")
        let dashed = normalized.replacingOccurrences(of: ".", with: "-")
        let compact = normalized.replacingOccurrences(of: ".", with: "")
        let tokens = [
            normalized,
            underscore,
            dashed,
            "mc\(normalized)",
            "mc\(underscore)",
            "mc\(dashed)",
            "minecraft \(normalized)",
            "neoforge \(normalized)",
            "neoforge-\(normalized)",
            "neoforge_\(underscore)",
            "neo_\(underscore)",
            "neo-\(dashed)",
            compact.isEmpty ? nil : "mc\(compact)"
        ].compactMap { $0 }
        return tokens.contains { text.contains($0) }
    }

    private static func normalizedModInventoryKey(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func minecraftServerVersions() throws -> HTTPResponse {
        let hasInstallerName = try reportingViewHasColumn("v_minecraft_server_versions", column: "installer_name")
        let hasInstallerSHA256 = try reportingViewHasColumn("v_minecraft_server_versions", column: "installer_sha256")
        let hasInstallerURL = try reportingViewHasColumn("v_minecraft_server_versions", column: "installer_url")
        let installerNameSQL = hasInstallerName
            ? "COALESCE(installer_name, '') AS installer_name"
            : "'' AS installer_name"
        let installerSHA256SQL = hasInstallerSHA256
            ? "COALESCE(installer_sha256, '') AS installer_sha256"
            : "'' AS installer_sha256"
        let installerURLSQL = hasInstallerURL
            ? "COALESCE(installer_url, '') AS installer_url"
            : "'' AS installer_url"
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT
          minecraft_version,
          loader,
          loader_version,
          server_name,
          server_address,
          server_dir,
          status,
          is_live,
          sort_order,
          CAST(updated_at AS VARCHAR) AS updated_at,
          COALESCE(notes, '') AS notes,
          \(installerNameSQL),
          \(installerSHA256SQL),
          \(installerURLSQL)
        FROM reporting.v_minecraft_server_versions
        ORDER BY sort_order, minecraft_version;
        """)
        var versions = Self.parseCSV(csv).map { row -> [String: Any] in
            let minecraftVersion = row["minecraft_version"] ?? ""
            let loaderVersion = row["loader_version"] ?? ""
            let installerName = row["installer_name"] ?? Self.neoForgeInstallerName(loaderVersion: loaderVersion)
            let installerURL = row["installer_url"] ?? Self.neoForgeInstallerURL(loaderVersion: loaderVersion)
            return [
                "minecraft_version": minecraftVersion,
                "loader": row["loader"] ?? "neoforge",
                "loader_version": loaderVersion,
                "server_name": row["server_name"] ?? "Pummelchen Server \(minecraftVersion)",
                "server_address": row["server_address"] ?? "",
                "server_dir": row["server_dir"] ?? "",
                "status": row["status"] ?? "unknown",
                "is_live": Self.duckBool(row["is_live"] ?? ""),
                "sort_order": Int(row["sort_order"] ?? "") ?? 100,
                "updated_at": Self.isoTimestamp(fromDuckDB: row["updated_at"] ?? ""),
                "installer_name": installerName.isEmpty ? Self.neoForgeInstallerName(loaderVersion: loaderVersion) : installerName,
                "installer_sha256": row["installer_sha256"] ?? "",
                "installer_url": installerURL.isEmpty ? Self.neoForgeInstallerURL(loaderVersion: loaderVersion) : installerURL,
                "page_url": Self.versionPageURL(minecraftVersion: minecraftVersion),
                "notes": row["notes"] ?? ""
            ]
        }
        let current = try CurrentReleaseValidator.decode(readCurrentReleaseData())
        let serverRows = try siteModInventoryRows(scope: "server", current: current, supportedVersions: versions)
        let clientRows = try siteModInventoryRows(scope: "client", current: current, supportedVersions: versions)
        let serverModCounts = Self.compatibleInventoryCountsByMinecraftVersion(rows: serverRows)
        let clientModCounts = Self.compatibleInventoryCountsByMinecraftVersion(rows: clientRows)
        versions = versions.map { version in
            var enriched = version
            let minecraftVersion = version["minecraft_version"] as? String ?? ""
            enriched["server_mod_count"] = serverModCounts[minecraftVersion] ?? 0
            enriched["client_mod_count"] = clientModCounts[minecraftVersion] ?? 0
            return enriched
        }
        let payload: [String: Any] = [
            "api_version": "v1",
            "generated_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-duckdb-live",
            "versions": versions
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-duckdb"
        ])
    }

    private func reportingViewHasColumn(_ view: String, column: String) throws -> Bool {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT COUNT(*) AS c
        FROM information_schema.columns
        WHERE table_schema = 'reporting'
          AND table_name = \(Self.sqlLiteral(view))
          AND column_name = \(Self.sqlLiteral(column));
        """)
        return Self.parseCSV(csv).first?["c"] == "1"
    }

    private static func neoForgeInstallerName(loaderVersion: String) -> String {
        loaderVersion.isEmpty ? "" : "neoforge-\(loaderVersion)-installer.jar"
    }

    private static func neoForgeInstallerURL(loaderVersion: String) -> String {
        loaderVersion.isEmpty ? "" : "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(loaderVersion)/neoforge-\(loaderVersion)-installer.jar"
    }

    private static func compatibleInventoryCountsByMinecraftVersion(rows: [[String: Any]]) -> [String: Int] {
        let compatibleStatuses: Set<String> = ["active", "staged", "compatible", "compatible by file"]
        var counts: [String: Int] = [:]
        for row in rows {
            guard let compatibility = row["compatibility"] as? [String: String] else {
                continue
            }
            for (minecraftVersion, status) in compatibility {
                if compatibleStatuses.contains(status.lowercased()) {
                    counts[minecraftVersion, default: 0] += 1
                }
            }
        }
        return counts
    }

    private func siteUpdateActivity() throws -> HTTPResponse {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        WITH activity AS (
          SELECT
            event_at AS timestamp,
            event_type AS stage,
            status,
            COALESCE(notes, release_id, '') AS message,
            release_id,
            NULL AS minecraft_version
          FROM release.release_events
          WHERE event_at >= now() - INTERVAL 14 DAYS

          UNION ALL

          SELECT
            COALESCE(finished_at, started_at) AS timestamp,
            'mod_update_scan' AS stage,
            status,
            'Mod update scan ' || scan_id || ': checked ' || CAST(urls_checked AS VARCHAR)
              || ' URL(s), found ' || CAST(candidates_found AS VARCHAR)
              || ' candidate(s), unresolved ' || CAST(unresolved AS VARCHAR) AS message,
            NULL AS release_id,
            minecraft_version
          FROM core.mod_update_scans
          WHERE COALESCE(finished_at, started_at) >= now() - INTERVAL 14 DAYS

          UNION ALL

          SELECT
            checked_at AS timestamp,
            'release_health' AS stage,
            status,
            COALESCE(details, release_id, '') AS message,
            release_id,
            NULL AS minecraft_version
          FROM release.release_health_results
          WHERE checked_at >= now() - INTERVAL 14 DAYS
        )
        SELECT
          CAST(timestamp AS VARCHAR) AS timestamp,
          stage,
          status,
          message,
          COALESCE(release_id, '') AS release_id,
          COALESCE(minecraft_version, '') AS minecraft_version
        FROM activity
        WHERE timestamp IS NOT NULL
        ORDER BY timestamp DESC
        LIMIT 50;
        """)
        let entries = Self.parseCSV(csv).map { row -> [String: Any] in
            let timestamp = Self.isoTimestamp(fromDuckDB: row["timestamp"] ?? "")
            return [
                "timestamp": Self.displayTimestamp(fromISO: timestamp),
                "timestamp_iso": timestamp,
                "stage": row["stage"] ?? "",
                "status": row["status"] ?? "",
                "message": row["message"] ?? "",
                "release_id": row["release_id"] ?? "",
                "minecraft_version": row["minecraft_version"] ?? ""
            ]
        }
        let payload: [String: Any] = [
            "api_version": "v1",
            "updated_at": Self.displayTimestamp(fromISO: Self.isoNow()),
            "generated_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-duckdb-update-activity",
            "source": "duckdb.release_events_mod_scans_release_health",
            "entry_count": entries.count,
            "entries": entries
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-duckdb"
        ])
    }

    private func siteNeoForgeVersion() throws -> HTTPResponse {
        let current = try CurrentReleaseValidator.decode(readCurrentReleaseData())
        let minecraftVersion = current.minecraftVersion ?? "26.1.2"
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT
          minecraft_version,
          loader,
          loader_version,
          status,
          CAST(updated_at AS VARCHAR) AS checked_at
        FROM reporting.v_minecraft_server_versions
        WHERE minecraft_version = \(Self.sqlLiteral(minecraftVersion))
        LIMIT 1;
        """)
        guard let row = Self.parseCSV(csv).first else {
            throw MCPummelchenModServerError.notFound("DuckDB Minecraft server version \(minecraftVersion)")
        }
        let currentLoaderVersion = current.loaderVersion ?? ""
        let latestLoaderVersion = row["loader_version"] ?? currentLoaderVersion
        let updateAvailable = !currentLoaderVersion.isEmpty && !latestLoaderVersion.isEmpty && currentLoaderVersion != latestLoaderVersion
        let checkedAt = Self.isoTimestamp(fromDuckDB: row["checked_at"] ?? "")
        let status = updateAvailable ? "update_available" : "current"
        let message: String
        if updateAvailable {
            message = "NeoForge \(latestLoaderVersion) is configured for Minecraft \(minecraftVersion); current release uses \(currentLoaderVersion)"
        } else {
            message = "NeoForge \(currentLoaderVersion.isEmpty ? latestLoaderVersion : currentLoaderVersion) is current for Minecraft \(minecraftVersion)"
        }
        let payload: [String: Any] = [
            "api_version": "v1",
            "checked_at": checkedAt.isEmpty ? Self.isoNow() : checkedAt,
            "generated_by": "MCPummelchenModServer-duckdb-neoforge-version",
            "current_neoforge_version": currentLoaderVersion,
            "latest_neoforge_version": latestLoaderVersion,
            "minecraft_version": minecraftVersion,
            "loader": row["loader"] ?? "neoforge",
            "server_version_status": row["status"] ?? "",
            "official_url": ModUpdateScanner.neoForgeOfficialDownloadPageURL,
            "official_download_url": ModUpdateScanner.neoForgeInstallerURL(version: latestLoaderVersion),
            "metadata_url": ModUpdateScanner.neoForgeOfficialMetadataURL,
            "status": status,
            "update_available": updateAvailable,
            "message": message
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-duckdb"
        ])
    }

    private func siteReleaseHealth() throws -> HTTPResponse {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT
          release_id,
          CAST(checked_at AS VARCHAR) AS checked_at,
          status,
          COALESCE(details, '') AS details
        FROM release.release_health_results
        ORDER BY checked_at DESC
        LIMIT 50;
        """)
        let findings = Self.parseCSV(csv).map { row -> [String: Any] in
            let checkedAt = Self.isoTimestamp(fromDuckDB: row["checked_at"] ?? "")
            return [
                "release_id": row["release_id"] ?? "",
                "checked_at": checkedAt,
                "checked_at_display": Self.displayTimestamp(fromISO: checkedAt),
                "level": row["status"] ?? "",
                "check": row["release_id"] ?? "",
                "detail": row["details"] ?? ""
            ]
        }
        let statuses = findings.compactMap { ($0["level"] as? String)?.lowercased() }
        let overall: String
        if statuses.contains(where: { ["error", "failed", "failure"].contains($0) }) {
            overall = "error"
        } else if statuses.contains(where: { ["warning", "warn"].contains($0) }) {
            overall = "warning"
        } else {
            overall = findings.isEmpty ? "unknown" : "healthy"
        }
        let payload: [String: Any] = [
            "api_version": "v1",
            "checked_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-duckdb-release-health",
            "overall": overall,
            "ok_count": statuses.filter { ["ok", "passed", "healthy"].contains($0) }.count,
            "warn_count": statuses.filter { ["warning", "warn"].contains($0) }.count,
            "error_count": statuses.filter { ["error", "failed", "failure"].contains($0) }.count,
            "findings": findings
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-duckdb"
        ])
    }

    private func siteReleaseHistory() throws -> HTTPResponse {
        let updates = try latestReleaseUpdatesFromDuckDB().map(\.jsonObject)
        let object: [String: Any] = [
            "api_version": "v1",
            "generated_at": Self.isoNow(),
            "generated_by": "MCPummelchenModServer-duckdb-live",
            "source": "duckdb.release.pack_releases",
            "cutoff_days": 30,
            "total_entries": updates.count,
            "updates": updates
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        return .json(data, headers: [
            "Cache-Control": "no-store, max-age=0",
            "X-Pummelchen-Stats-Source": "swift-server-duckdb"
        ])
    }

    private struct TestedUpdateRow {
        let id: String
        let jsonObject: [String: Any]
    }

    private func latestReleaseUpdatesFromDuckDB() throws -> [TestedUpdateRow] {
        let csv = try DuckDBDatabase(databaseURL: config.duckDBURL, readOnly: true).queryCSV("""
        SELECT
          release_id,
          CAST(COALESCE(activated_at, created_at) AS VARCHAR) AS tested_at,
          COALESCE(status, '') AS status,
          COALESCE(notes, '') AS notes
        FROM release.pack_releases
        WHERE COALESCE(activated_at, created_at) >= now() - INTERVAL 30 DAYS
        ORDER BY COALESCE(activated_at, created_at) DESC
        LIMIT 100;
        """)
        let rows = Self.parseCSV(csv)
        return rows.compactMap { row in
            guard let releaseID = row["release_id"], !releaseID.isEmpty else {
                return nil
            }
            let testedAt = Self.isoTimestamp(fromDuckDB: row["tested_at"] ?? "")
            let id = "pr_\(releaseID)"
            return TestedUpdateRow(id: id, jsonObject: [
                "id": id,
                "source": "pack_releases",
                "title": "Release promoted: \(releaseID)",
                "event_type": "release_promotion",
                "status": row["status"]?.isEmpty == false ? row["status"]! : "active",
                "tested_at": testedAt,
                "tested_at_display": Self.displayTimestamp(fromISO: testedAt),
                "old_file": NSNull(),
                "new_file": NSNull(),
                "source_url": "/release.html?release=\(releaseID)",
                "test_label": releaseID,
                "notes": row["notes"]?.isEmpty == false ? row["notes"]! : "New immutable release activated",
                "mod_id": NSNull()
            ])
        }
    }

    private func controlInfo() throws -> HTTPResponse {
        let payload = ControlChannelInfo(
            endpoint: "/api/v1/control/events",
            transportTarget: "nginx_https_poll",
            bidirectional: true,
            fallbackEndpoint: "",
            maxPayloadBytes: ControlEventStore.maxControlPayloadBytes,
            downloadsAllowed: false,
            supportedEvents: ControlEventType.allCases.map(\.rawValue)
        )
        return .json(try encoder.encode(payload), headers: ["X-Pummelchen-Downloads-Allowed": "false"])
    }

    private func createControlEvent(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ControlEventCreateRequest = try decodeBody(request)
        let event = try controlStore.create(payload)
        return .json(try encoder.encode(event), statusCode: 201)
    }

    private func controlEvents(_ request: HTTPRequest) throws -> HTTPResponse {
        let params = queryParameters(request.path)
        let clientID = params["client_id"] ?? request.headers["x-pummelchen-client-id"] ?? ""
        try validateClientID(clientID, header: request.headers["x-pummelchen-client-id"])
        let limit = params["limit"].flatMap(Int.init) ?? 50
        let events = try controlStore.pendingEvents(
            clientID: clientID,
            afterEventID: params["after_event_id"],
            limit: limit
        )
        let batch = ControlEventBatch(
            events: events,
            nextAfterEventID: events.last?.eventID ?? params["after_event_id"],
            transport: "authenticated_https_operator_poll",
            fallback: "none"
        )
        return .json(try encoder.encode(batch), headers: ["X-Pummelchen-Downloads-Allowed": "false"])
    }

    private func acknowledgeControlEvent(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ControlEventAck = try decodeBody(request)
        try validateClientID(payload.clientID, header: request.headers["x-pummelchen-client-id"])
        try controlStore.acknowledge(payload)
        return .json(try encoder.encode(ClientWriteAck(clientID: payload.clientID, events: 1)))
    }

    private func registerClient(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ClientRegistrationRequest = try decodeBody(request)
        try validateClientID(payload.clientID, header: request.headers["x-pummelchen-client-id"])
        try store.register(payload)
        return .json(try encoder.encode(ClientWriteAck(clientID: payload.clientID)), statusCode: 201)
    }

    private func statusReport(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ClientStatusReport = try decodeBody(request)
        try validateClientID(payload.clientID, header: request.headers["x-pummelchen-client-id"])
        try store.recordStatus(payload)
        return .json(try encoder.encode(ClientWriteAck(clientID: payload.clientID)))
    }

    private func inventoryUpload(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ClientInventoryUpload = try decodeBody(request)
        try validateClientID(payload.clientID, header: request.headers["x-pummelchen-client-id"])
        try store.recordInventory(payload)
        return .json(try encoder.encode(ClientWriteAck(files: payload.files.count)))
    }

    private func diagnosticsUpload(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ClientDiagnosticsUpload = try decodeBody(request)
        try validateClientID(payload.clientID, header: request.headers["x-pummelchen-client-id"])
        try store.recordDiagnostics(payload)
        return .json(try encoder.encode(ClientWriteAck(clientID: payload.clientID)))
    }

    private func defaultsEventUpload(_ request: HTTPRequest) throws -> HTTPResponse {
        let payload: ClientDefaultsEventUpload = try decodeBody(request)
        try validateClientID(payload.clientID, header: request.headers["x-pummelchen-client-id"])
        try store.recordDefaultsEvent(payload)
        return .json(try encoder.encode(ClientWriteAck(events: payload.events.count)))
    }

    private func decodeBody<T: Decodable>(_ request: HTTPRequest) throws -> T {
        try requirePayloadLimit(request)
        guard !request.body.isEmpty else {
            throw MCPummelchenModServerError.badRequest("JSON body is required")
        }
        do {
            return try decoder.decode(T.self, from: request.body)
        } catch {
            throw MCPummelchenModServerError.badRequest("invalid JSON body: \(error)")
        }
    }

    private func requirePayloadLimit(_ request: HTTPRequest) throws {
        if request.body.count > config.maxWritePayloadBytes {
            throw MCPummelchenModServerError.payloadTooLarge(request.body.count)
        }
    }

    private func requireAuthorized(_ request: HTTPRequest) throws {
        guard let expected = config.clientAPIToken, !expected.isEmpty else {
            throw MCPummelchenModServerError.unauthorized("client write API token is not configured")
        }
        guard Self.constantTimeEquals(request.headers["authorization"] ?? "", "Bearer \(expected)") else {
            throw MCPummelchenModServerError.unauthorized("invalid client API token")
        }
    }

    private func validateClientID(_ bodyClientID: String, header: String?) throws {
        let trimmed = bodyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        try ContractValidation.requireClientID(trimmed)
        if let header, !header.isEmpty, header.trimmingCharacters(in: .whitespacesAndNewlines) != trimmed {
            throw MCPummelchenModServerError.unauthorized("client id header does not match payload")
        }
    }

    private func manifest(releaseID: String) throws -> HTTPResponse {
        _ = try ReleaseIdentifier(releaseID)
        let data = try readManifest(releaseID: releaseID)
        let text = String(decoding: data, as: UTF8.self)
        _ = try ClientSyncManifestParser.parse(text)
        return HTTPResponse(statusCode: 200, contentType: "text/tab-separated-values; charset=utf-8", body: data)
    }

    private func readCurrentReleaseData() throws -> Data {
        let url = config.projectRoot
            .appendingPathComponent("site/public/downloads/current-release.json")
        return try Data(contentsOf: try safeProjectFile(url))
    }

    private func readManifest(releaseID: String) throws -> Data {
        let url = config.projectRoot
            .appendingPathComponent("site/public/downloads/releases")
            .appendingPathComponent(releaseID)
            .appendingPathComponent("client-sync-manifest.tsv")
        return try Data(contentsOf: try safeProjectFile(url))
    }

    private func safeProjectFile(_ url: URL) throws -> URL {
        try SafePath(root: config.projectRoot).validateChild(url)
    }

    private func releaseManifestID(from path: String) -> String? {
        let value = normalizedPath(path)
        let prefix = "/api/v1/releases/"
        let suffix = "/manifest"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix) else {
            return nil
        }
        let start = value.index(value.startIndex, offsetBy: prefix.count)
        let end = value.index(value.endIndex, offsetBy: -suffix.count)
        let releaseID = String(value[start..<end])
        return releaseID.isEmpty || releaseID.contains("/") ? nil : releaseID
    }

    private func normalizedPath(_ path: String) -> String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return withoutQuery.isEmpty ? "/" : withoutQuery
    }

    private func queryParameters(_ path: String) -> [String: String] {
        guard let query = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first else {
            return [:]
        }
        var result: [String: String] = [:]
        for item in query.split(separator: "&") {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else {
                continue
            }
            let value = parts.count > 1 ? String(parts[1]) : ""
            result[String(key).removingPercentEncoding ?? String(key)] = value.removingPercentEncoding ?? value
        }
        return result
    }

    private func errorResponse(status: Int, message: String) -> HTTPResponse {
        let body: [String: Any] = [
            "api_version": "v1",
            "error": Self.redactSecrets(message),
            "request_id": UUID().uuidString,
            "server_time": Self.isoNow()
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data(#"{"api_version":"v1","error":"internal server error"}"#.utf8)
        return .json(data, statusCode: status)
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func isoTimestamp(fromDuckDB value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("T") {
            return trimmed
        }
        if trimmed.count >= 19 {
            return trimmed.replacingOccurrences(of: " ", with: "T") + "Z"
        }
        return isoNow()
    }

    private static func displayTimestamp(fromISO value: String) -> String {
        value
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: " UTC")
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

    private static func htmlText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseCSV(_ csv: String) -> [[String: String]] {
        let rows = parseCSVRows(csv)
        guard let header = rows.first else {
            return []
        }
        return rows.dropFirst().map { row in
            var object: [String: String] = [:]
            for index in 0..<min(header.count, row.count) {
                object[header[index]] = row[index]
            }
            return object
        }
    }

    private static func parseCSVRows(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = csv.startIndex
        while index < csv.endIndex {
            let char = csv[index]
            if inQuotes {
                if char == "\"" {
                    let next = csv.index(after: index)
                    if next < csv.endIndex, csv[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
            } else if char == "\"" {
                inQuotes = true
            } else if char == "," {
                row.append(field)
                field = ""
            } else if char == "\n" {
                row.append(field)
                if !row.allSatisfy({ $0.isEmpty }) {
                    rows.append(row)
                }
                row = []
                field = ""
            } else if char != "\r" {
                field.append(char)
            }
            index = csv.index(after: index)
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !row.allSatisfy({ $0.isEmpty }) {
                rows.append(row)
            }
        }
        return rows
    }

    private static func constantTimeEquals(_ left: String, _ right: String) -> Bool {
        let leftBytes = [UInt8](left.utf8)
        let rightBytes = [UInt8](right.utf8)
        var difference = UInt8(leftBytes.count ^ rightBytes.count)
        for index in 0..<max(leftBytes.count, rightBytes.count) {
            let leftByte = index < leftBytes.count ? leftBytes[index] : 0
            let rightByte = index < rightBytes.count ? rightBytes[index] : 0
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }

    private static func redactSecrets(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(--rcon-password\s+)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(rcon\.password\s*=\s*)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #""client_secret"\s*:\s*"[^"]+""#, with: #""client_secret":"[REDACTED]""#, options: .regularExpression)
    }

    private static func duckBool(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "t", "1", "yes":
            return true
        default:
            return false
        }
    }

    private static func versionPageURL(minecraftVersion: String) -> String {
        guard !minecraftVersion.isEmpty else {
            return "index.html"
        }
        let safe = minecraftVersion
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9.]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "server-\(safe).html"
    }
}

public typealias MCPummelchenModReadOnlyAPI = MCPummelchenModServerAPI

public struct ServerClientReportStore: Sendable {
    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func register(_ payload: ClientRegistrationRequest) throws {
        try initialize()
        try Self.validateClientID(payload.clientID)
        let now = Self.duckTimestamp(Date())
        try execute("""
        INSERT INTO client.client_latest_status(
          client_id, first_seen_at, last_seen_at, installed_release_id, target_release_id,
          status, manifest_entries, changed_files, last_error, last_status_message, os_summary, arch
        )
        VALUES (
          \(Self.sqlLiteral(payload.clientID)),
          TIMESTAMP '\(now)',
          TIMESTAMP '\(now)',
          NULL,
          NULL,
          'registered',
          0,
          0,
          NULL,
          \(Self.sqlLiteral(payload.displayName ?? "registered")),
          \(Self.sqlLiteral(payload.osSummary)),
          \(Self.sqlLiteral(payload.arch))
        )
        ON CONFLICT(client_id) DO UPDATE SET
          last_seen_at = excluded.last_seen_at,
          last_status_message = excluded.last_status_message,
          os_summary = excluded.os_summary,
          arch = excluded.arch;
        """)
    }

    public func recordStatus(_ payload: ClientStatusReport) throws {
        try initialize()
        try Self.validateClientID(payload.clientID)
        try Self.validateStatus(payload.status)
        if let manifestEntries = payload.manifestEntries {
            try ContractValidation.require(manifestEntries >= 0, "manifest_entries must be non-negative")
        }
        try ContractValidation.require(payload.changedFiles >= 0, "changed_files must be non-negative")
        let reportedAt = Self.sqlTimestamp(payload.reportedAt)
        try execute("""
        INSERT INTO client.client_reports(
          client_id, reported_at, installed_release_id, target_release_id, status,
          manifest_entries, changed_files, last_error, message, os_summary, arch,
          minecraft_version, loader_version
        )
        VALUES (
          \(Self.sqlLiteral(payload.clientID)),
          TIMESTAMP '\(reportedAt)',
          \(Self.sqlLiteral(payload.installedReleaseID)),
          \(Self.sqlLiteral(payload.targetReleaseID)),
          \(Self.sqlLiteral(payload.status)),
          \(payload.manifestEntries ?? 0),
          \(payload.changedFiles),
          \(Self.sqlLiteral(payload.lastError)),
          \(Self.sqlLiteral(payload.message)),
          \(Self.sqlLiteral(payload.osSummary)),
          \(Self.sqlLiteral(payload.arch)),
          \(Self.sqlLiteral(payload.minecraftVersion)),
          \(Self.sqlLiteral(payload.loaderVersion))
        );
        INSERT INTO client.client_latest_status(
          client_id, first_seen_at, last_seen_at, installed_release_id, target_release_id,
          status, manifest_entries, changed_files, last_error, last_status_message, os_summary, arch,
          minecraft_version, loader_version
        )
        VALUES (
          \(Self.sqlLiteral(payload.clientID)),
          TIMESTAMP '\(reportedAt)',
          TIMESTAMP '\(reportedAt)',
          \(Self.sqlLiteral(payload.installedReleaseID)),
          \(Self.sqlLiteral(payload.targetReleaseID)),
          \(Self.sqlLiteral(payload.status)),
          \(payload.manifestEntries ?? 0),
          \(payload.changedFiles),
          \(Self.sqlLiteral(payload.lastError)),
          \(Self.sqlLiteral(payload.message)),
          \(Self.sqlLiteral(payload.osSummary)),
          \(Self.sqlLiteral(payload.arch)),
          \(Self.sqlLiteral(payload.minecraftVersion)),
          \(Self.sqlLiteral(payload.loaderVersion))
        )
        ON CONFLICT(client_id) DO UPDATE SET
          last_seen_at = excluded.last_seen_at,
          installed_release_id = excluded.installed_release_id,
          target_release_id = excluded.target_release_id,
          status = excluded.status,
          manifest_entries = excluded.manifest_entries,
          changed_files = excluded.changed_files,
          last_error = excluded.last_error,
          last_status_message = excluded.last_status_message,
          os_summary = excluded.os_summary,
          arch = excluded.arch,
          minecraft_version = excluded.minecraft_version,
          loader_version = excluded.loader_version;
        """)
    }

    public func recordInventory(_ payload: ClientInventoryUpload) throws {
        try initialize()
        try Self.validateClientID(payload.clientID)
        let reportedAt = Self.sqlTimestamp(payload.reportedAt)
        let payloadMinecraftVersion = payload.minecraftVersion ?? Self.liveMinecraftVersion
        let payloadLoaderVersion = payload.loaderVersion ?? Self.liveLoaderVersion
        var sql = """
        DELETE FROM client.client_inventory_by_version
        WHERE client_id = \(Self.sqlLiteral(payload.clientID))
          AND minecraft_version = \(Self.sqlLiteral(payloadMinecraftVersion));
        DELETE FROM client.client_inventory
        WHERE client_id = \(Self.sqlLiteral(payload.clientID))
          AND COALESCE(minecraft_version, '26.1.2') = \(Self.sqlLiteral(payloadMinecraftVersion));
        """
        for file in payload.files {
            try ContractValidation.requireSHA256(file.sha256, field: "inventory sha256")
            try ContractValidation.require(file.sizeBytes >= 0, "inventory size_bytes must be non-negative")
            try ContractValidation.require(["mods", "resourcepacks", "shaderpacks", "tools"].contains(file.section), "invalid inventory section")
            let fileMinecraftVersion = file.minecraftVersion ?? payloadMinecraftVersion
            let fileLoaderVersion = file.loaderVersion ?? payloadLoaderVersion
            sql += """
            INSERT OR REPLACE INTO client.client_inventory(
              client_id, reported_at, section, name, size_bytes, sha256,
              status, minecraft_version, loader_version
            )
            VALUES (
              \(Self.sqlLiteral(payload.clientID)),
              TIMESTAMP '\(reportedAt)',
              \(Self.sqlLiteral(file.section)),
              \(Self.sqlLiteral(file.name)),
              \(file.sizeBytes),
              \(Self.sqlLiteral(file.sha256)),
              \(Self.sqlLiteral(file.status)),
              \(Self.sqlLiteral(fileMinecraftVersion)),
              \(Self.sqlLiteral(fileLoaderVersion))
            );
            INSERT OR REPLACE INTO client.client_inventory_by_version(
              minecraft_version, loader_version, client_id, reported_at, section,
              name, size_bytes, sha256, status
            )
            VALUES (
              \(Self.sqlLiteral(fileMinecraftVersion)),
              \(Self.sqlLiteral(fileLoaderVersion)),
              \(Self.sqlLiteral(payload.clientID)),
              TIMESTAMP '\(reportedAt)',
              \(Self.sqlLiteral(file.section)),
              \(Self.sqlLiteral(file.name)),
              \(file.sizeBytes),
              \(Self.sqlLiteral(file.sha256)),
              \(Self.sqlLiteral(file.status))
            );
            """
        }
        try execute(sql)
    }

    public func recordDiagnostics(_ payload: ClientDiagnosticsUpload) throws {
        try initialize()
        try Self.validateClientID(payload.clientID)
        try execute("""
        INSERT INTO client.client_diagnostics(
          diagnostic_id, client_id, reported_at, level, summary, details, client_ip, log_files, log_snippet
        )
        VALUES (
          \(Self.sqlLiteral(UUID().uuidString)),
          \(Self.sqlLiteral(payload.clientID)),
          TIMESTAMP '\(Self.sqlTimestamp(payload.reportedAt))',
          \(Self.sqlLiteral(payload.level)),
          \(Self.sqlLiteral(Self.redact(payload.summary) ?? "")),
          \(Self.sqlLiteral(Self.redact(payload.details))),
          \(Self.sqlLiteral(payload.clientIP)),
          \(Self.sqlLiteral(payload.logFiles.joined(separator: ", "))),
          \(Self.sqlLiteral(payload.logSnippet))
        );
        """)
    }

    public func recordDefaultsEvent(_ payload: ClientDefaultsEventUpload) throws {
        try initialize()
        try Self.validateClientID(payload.clientID)
        let reportedAt = Self.sqlTimestamp(payload.reportedAt)
        var sql = """
        INSERT INTO client.client_defaults_reports(report_id, client_id, reported_at, defaults_ok)
        VALUES (\(Self.sqlLiteral(UUID().uuidString)), \(Self.sqlLiteral(payload.clientID)), TIMESTAMP '\(reportedAt)', \(payload.defaultsOK ? "true" : "false"));
        """
        for event in payload.events {
            sql += """
            INSERT INTO client.client_defaults_events(event_id, client_id, reported_at, key, status, desired_value, observed_value)
            VALUES (
              \(Self.sqlLiteral(UUID().uuidString)),
              \(Self.sqlLiteral(payload.clientID)),
              TIMESTAMP '\(reportedAt)',
              \(Self.sqlLiteral(event.key)),
              \(Self.sqlLiteral(event.status)),
              \(Self.sqlLiteral(event.desiredValue)),
              \(Self.sqlLiteral(event.observedValue))
            );
            """
        }
        if !payload.defaultsOK {
            sql += """
            UPDATE client.client_latest_status
            SET status = 'needs_defaults_repair',
                last_seen_at = TIMESTAMP '\(reportedAt)',
                last_status_message = 'client defaults need repair'
            WHERE client_id = \(Self.sqlLiteral(payload.clientID));
            """
        }
        try execute(sql)
    }

    public func healthSummary() throws -> ClientHealthSummary {
        try initialize()
        let csv = try queryCSV("""
        SELECT
          COUNT(*),
          SUM(CASE WHEN status = 'synced' THEN 1 ELSE 0 END),
          SUM(CASE WHEN status = 'needs_defaults_repair' THEN 1 ELSE 0 END),
          SUM(CASE WHEN status = 'failed_checksum' THEN 1 ELSE 0 END),
          SUM(CASE WHEN status = 'stale_release' OR installed_release_id IS DISTINCT FROM target_release_id THEN 1 ELSE 0 END),
          SUM(CASE WHEN status IN ('error', 'blocked_minecraft_running') THEN 1 ELSE 0 END)
        FROM client.client_latest_status;
        """)
        let values = csv.split(separator: "\n").last?.split(separator: ",").map { Int($0) ?? 0 } ?? []
        return ClientHealthSummary(
            totalClients: values.count > 0 ? values[0] : 0,
            synced: values.count > 1 ? values[1] : 0,
            needsDefaultsRepair: values.count > 2 ? values[2] : 0,
            failedChecksum: values.count > 3 ? values[3] : 0,
            staleRelease: values.count > 4 ? values[4] : 0,
            error: values.count > 5 ? values[5] : 0
        )
    }

    private func initialize() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
        CREATE SCHEMA IF NOT EXISTS client;
        CREATE TABLE IF NOT EXISTS client.client_reports (
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          installed_release_id VARCHAR,
          target_release_id VARCHAR,
          status VARCHAR NOT NULL,
          manifest_entries INTEGER,
          changed_files INTEGER,
          last_error VARCHAR,
          message VARCHAR,
          os_summary VARCHAR,
          arch VARCHAR,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client.client_latest_status (
          client_id VARCHAR PRIMARY KEY,
          first_seen_at TIMESTAMP NOT NULL,
          last_seen_at TIMESTAMP NOT NULL,
          installed_release_id VARCHAR,
          target_release_id VARCHAR,
          status VARCHAR NOT NULL,
          manifest_entries INTEGER,
          changed_files INTEGER,
          last_error VARCHAR,
          last_status_message VARCHAR,
          os_summary VARCHAR,
          arch VARCHAR,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client.client_inventory (
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          section VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          size_bytes BIGINT NOT NULL,
          sha256 VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          minecraft_version VARCHAR DEFAULT '26.1.2',
          loader_version VARCHAR,
          PRIMARY KEY(client_id, section, name)
        );
        CREATE TABLE IF NOT EXISTS client.client_inventory_by_version (
          minecraft_version VARCHAR NOT NULL,
          loader_version VARCHAR,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          section VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          size_bytes BIGINT NOT NULL,
          sha256 VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          PRIMARY KEY(minecraft_version, client_id, section, name)
        );
        CREATE TABLE IF NOT EXISTS client.client_diagnostics (
          diagnostic_id VARCHAR PRIMARY KEY,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          level VARCHAR NOT NULL,
          summary VARCHAR NOT NULL,
          details VARCHAR,
          client_ip VARCHAR,
          log_files VARCHAR,
          log_snippet VARCHAR
        );
        ALTER TABLE client.client_diagnostics ADD COLUMN IF NOT EXISTS client_ip VARCHAR;
        ALTER TABLE client.client_diagnostics ADD COLUMN IF NOT EXISTS log_files VARCHAR;
        ALTER TABLE client.client_diagnostics ADD COLUMN IF NOT EXISTS log_snippet VARCHAR;
        CREATE TABLE IF NOT EXISTS client.client_defaults_reports (
          report_id VARCHAR PRIMARY KEY,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          defaults_ok BOOLEAN NOT NULL,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client.client_defaults_events (
          event_id VARCHAR PRIMARY KEY,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          key VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          desired_value VARCHAR NOT NULL,
          observed_value VARCHAR,
          minecraft_version VARCHAR,
          loader_version VARCHAR
        );
        ALTER TABLE client.client_reports ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE client.client_reports ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE client.client_latest_status ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE client.client_latest_status ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE client.client_inventory ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR DEFAULT '26.1.2';
        ALTER TABLE client.client_inventory ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE client.client_defaults_reports ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE client.client_defaults_reports ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        ALTER TABLE client.client_defaults_events ADD COLUMN IF NOT EXISTS minecraft_version VARCHAR;
        ALTER TABLE client.client_defaults_events ADD COLUMN IF NOT EXISTS loader_version VARCHAR;
        """)
    }

    private func execute(_ sql: String) throws {
        try DuckDBDatabase(databaseURL: databaseURL).execute(sql)
    }

    private func queryCSV(_ sql: String) throws -> String {
        try DuckDBDatabase(databaseURL: databaseURL).queryCSV(sql)
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(sql(value))'"
    }

    private static func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func sqlTimestamp(_ value: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: value) ?? Date()
        return duckTimestamp(parsed)
    }

    private static var liveMinecraftVersion: String {
        MinecraftClientDefaults.defaultSupportedServers.first(where: { $0.isLive })?.minecraftVersion ?? "26.1.2"
    }

    private static var liveLoaderVersion: String {
        MinecraftClientDefaults.defaultSupportedServers.first(where: { $0.isLive })?.loaderVersion ?? "26.1.2.76"
    }

    private static func duckTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func redact(_ value: String?) -> String? {
        value?
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #""client_secret"\s*:\s*"[^"]+""#, with: #""client_secret":"[REDACTED]""#, options: .regularExpression)
    }

    private static func validateClientID(_ clientID: String) throws {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        try ContractValidation.requireClientID(trimmed)
    }

    private static func validateStatus(_ status: String) throws {
        let allowed = [
            "registered",
            "heartbeat",
            "synced",
            "outdated",
            "stale_release",
            "downloading",
            "needs_defaults_repair",
            "failed_checksum",
            "error",
            "offline",
            "blocked_minecraft_running"
        ]
        try ContractValidation.require(allowed.contains(status), "invalid client status: \(status)")
    }
}
