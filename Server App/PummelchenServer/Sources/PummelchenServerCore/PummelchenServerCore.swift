import Foundation
import PummelchenCore

public enum PummelchenServerError: Error, CustomStringConvertible {
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

public struct PummelchenServerConfig: Sendable {
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
        transportTarget: String = ProcessInfo.processInfo.environment["PUMMELCHEN_TRANSPORT_TARGET"] ?? "http3_quic_edge",
        transportFallback: String = "authenticated_https_long_poll"
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

public final class PummelchenServerAPI: @unchecked Sendable {
    private let config: PummelchenServerConfig
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let store: ServerClientReportStore
    private let controlStore: ControlEventStore

    public init(config: PummelchenServerConfig) {
        self.config = config
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.store = ServerClientReportStore(databaseURL: config.duckDBURL)
        self.controlStore = ControlEventStore(databaseURL: config.duckDBURL)
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
            case ("GET", "/h3/v1/control"):
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
                throw PummelchenServerError.notFound(request.path)
            default:
                throw PummelchenServerError.methodNotAllowed
            }
        } catch PummelchenServerError.unauthorized(let message) {
            return errorResponse(status: 401, message: message)
        } catch PummelchenServerError.payloadTooLarge(let size) {
            return errorResponse(status: 413, message: "payload too large: \(size) bytes")
        } catch PummelchenServerError.methodNotAllowed {
            return errorResponse(status: 405, message: "method not allowed")
        } catch PummelchenServerError.notFound(let message) {
            return errorResponse(status: 404, message: message)
        } catch PummelchenServerError.badRequest(let message) {
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
            service: "PummelchenServer",
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

    private func controlInfo() throws -> HTTPResponse {
        let payload = ControlChannelInfo(
            endpoint: "/h3/v1/control",
            transportTarget: "http3_quic_edge_control",
            bidirectional: true,
            fallbackEndpoint: "/api/v1/control/events",
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
        let waitSeconds = min(max(params["wait_seconds"].flatMap(Int.init) ?? 0, 0), 30)
        var events = try controlStore.pendingEvents(
            clientID: clientID,
            afterEventID: params["after_event_id"],
            limit: limit
        )
        if events.isEmpty && waitSeconds > 0 {
            let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
            while events.isEmpty && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                events = try controlStore.pendingEvents(
                    clientID: clientID,
                    afterEventID: params["after_event_id"],
                    limit: limit
                )
            }
        }
        let batch = ControlEventBatch(
            events: events,
            nextAfterEventID: events.last?.eventID ?? params["after_event_id"],
            transport: waitSeconds > 0 ? "http3_edge_long_poll" : "http_polling_fallback",
            fallback: "authenticated_https_polling"
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
            throw PummelchenServerError.badRequest("JSON body is required")
        }
        do {
            return try decoder.decode(T.self, from: request.body)
        } catch {
            throw PummelchenServerError.badRequest("invalid JSON body: \(error)")
        }
    }

    private func requirePayloadLimit(_ request: HTTPRequest) throws {
        if request.body.count > config.maxWritePayloadBytes {
            throw PummelchenServerError.payloadTooLarge(request.body.count)
        }
    }

    private func requireAuthorized(_ request: HTTPRequest) throws {
        guard let expected = config.clientAPIToken, !expected.isEmpty else {
            throw PummelchenServerError.unauthorized("client write API token is not configured")
        }
        guard request.headers["authorization"] == "Bearer \(expected)" else {
            throw PummelchenServerError.unauthorized("invalid client API token")
        }
    }

    private func validateClientID(_ bodyClientID: String, header: String?) throws {
        let trimmed = bodyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        try ContractValidation.require(trimmed.count >= 8 && trimmed.count <= 128, "client_id must be 8-128 characters")
        if let header, !header.isEmpty, header != bodyClientID {
            throw PummelchenServerError.unauthorized("client id header does not match payload")
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
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let body = #"{"api_version":"v1","error":"\#(escaped)","request_id":"\#(UUID().uuidString)","server_time":"\#(Self.isoNow())"}"#
        return .json(Data(body.utf8), statusCode: status)
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

public typealias PummelchenReadOnlyAPI = PummelchenServerAPI

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
          manifest_entries, changed_files, last_error, message, os_summary, arch
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
          \(Self.sqlLiteral(payload.arch))
        );
        INSERT INTO client.client_latest_status(
          client_id, first_seen_at, last_seen_at, installed_release_id, target_release_id,
          status, manifest_entries, changed_files, last_error, last_status_message, os_summary, arch
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
          \(Self.sqlLiteral(payload.arch))
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
          arch = excluded.arch;
        """)
    }

    public func recordInventory(_ payload: ClientInventoryUpload) throws {
        try initialize()
        try Self.validateClientID(payload.clientID)
        let reportedAt = Self.sqlTimestamp(payload.reportedAt)
        var sql = "DELETE FROM client.client_inventory WHERE client_id = \(Self.sqlLiteral(payload.clientID));\n"
        for file in payload.files {
            try ContractValidation.requireSHA256(file.sha256, field: "inventory sha256")
            try ContractValidation.require(file.sizeBytes >= 0, "inventory size_bytes must be non-negative")
            try ContractValidation.require(["mods", "resourcepacks", "shaderpacks", "tools"].contains(file.section), "invalid inventory section")
            sql += """
            INSERT INTO client.client_inventory(client_id, reported_at, section, name, size_bytes, sha256, status)
            VALUES (
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
        INSERT INTO client.client_diagnostics(diagnostic_id, client_id, reported_at, level, summary, details)
        VALUES (
          \(Self.sqlLiteral(UUID().uuidString)),
          \(Self.sqlLiteral(payload.clientID)),
          TIMESTAMP '\(Self.sqlTimestamp(payload.reportedAt))',
          \(Self.sqlLiteral(payload.level)),
          \(Self.sqlLiteral(Self.redact(payload.summary) ?? "")),
          \(Self.sqlLiteral(Self.redact(payload.details)))
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
          arch VARCHAR
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
          arch VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client.client_inventory (
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          section VARCHAR NOT NULL,
          name VARCHAR NOT NULL,
          size_bytes BIGINT NOT NULL,
          sha256 VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          PRIMARY KEY(client_id, section, name)
        );
        CREATE TABLE IF NOT EXISTS client.client_diagnostics (
          diagnostic_id VARCHAR PRIMARY KEY,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          level VARCHAR NOT NULL,
          summary VARCHAR NOT NULL,
          details VARCHAR
        );
        CREATE TABLE IF NOT EXISTS client.client_defaults_reports (
          report_id VARCHAR PRIMARY KEY,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          defaults_ok BOOLEAN NOT NULL
        );
        CREATE TABLE IF NOT EXISTS client.client_defaults_events (
          event_id VARCHAR PRIMARY KEY,
          client_id VARCHAR NOT NULL,
          reported_at TIMESTAMP NOT NULL,
          key VARCHAR NOT NULL,
          status VARCHAR NOT NULL,
          desired_value VARCHAR NOT NULL,
          observed_value VARCHAR
        );
        """)
    }

    private func execute(_ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.duckDBExecutablePath())
        process.arguments = [databaseURL.path, "-c", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("duckdb server write failed: \(output)")
        }
    }

    private func queryCSV(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.duckDBExecutablePath())
        process.arguments = [databaseURL.path, "-csv", "-c", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("duckdb server query failed: \(output)")
        }
        return output
    }

    private static func duckDBExecutablePath() throws -> String {
        let candidates = ["/opt/homebrew/bin/duckdb", "/usr/local/bin/duckdb", "/usr/bin/duckdb", "/bin/duckdb"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-lc", "command -v duckdb"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus == 0, !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }
        throw ContractValidationError.invalid("duckdb executable not found; install DuckDB or bundle it with the server")
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
        try ContractValidation.require(trimmed.count >= 8 && trimmed.count <= 128, "client_id must be 8-128 characters")
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
