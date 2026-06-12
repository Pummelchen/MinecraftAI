import Foundation
import PummelchenCore

public enum PummelchenServerError: Error, CustomStringConvertible {
    case badRequest(String)
    case notFound(String)
    case methodNotAllowed
    case unsupported(String)

    public var description: String {
        switch self {
        case .badRequest(let message):
            return "bad request: \(message)"
        case .notFound(let message):
            return "not found: \(message)"
        case .methodNotAllowed:
            return "method not allowed"
        case .unsupported(let message):
            return "unsupported: \(message)"
        }
    }
}

public struct HTTPRequest: Equatable, Sendable {
    public let method: String
    public let path: String

    public init(method: String, path: String) {
        self.method = method
        self.path = path
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

    public static func json(_ value: Data, statusCode: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: statusCode, contentType: "application/json; charset=utf-8", body: value)
    }
}

public struct PummelchenServerConfig: Sendable {
    public let projectRoot: URL
    public let bindHost: String
    public let port: Int

    public init(projectRoot: URL, bindHost: String = "127.0.0.1", port: Int = 8787) {
        self.projectRoot = projectRoot
        self.bindHost = bindHost
        self.port = port
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

public final class PummelchenReadOnlyAPI: @unchecked Sendable {
    private let config: PummelchenServerConfig
    private let encoder: JSONEncoder

    public init(config: PummelchenServerConfig) {
        self.config = config
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func response(for request: HTTPRequest) -> HTTPResponse {
        do {
            guard request.method == "GET" else {
                throw PummelchenServerError.methodNotAllowed
            }

            switch normalizedPath(request.path) {
            case "/api/v1/status":
                return try status()
            case "/api/v1/releases/current":
                return try currentRelease()
            default:
                if let releaseID = releaseManifestID(from: request.path) {
                    return try manifest(releaseID: releaseID)
                }
                throw PummelchenServerError.notFound(request.path)
            }
        } catch PummelchenServerError.methodNotAllowed {
            return errorResponse(status: 405, message: "method not allowed")
        } catch PummelchenServerError.notFound(let message) {
            return errorResponse(status: 404, message: message)
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
            mode: "read_only",
            projectRoot: config.projectRoot.path,
            currentReleaseID: release?.releaseID,
            transportTarget: "http3_quic",
            transportFallback: "http2_https_polling"
        )
        return .json(try encoder.encode(payload))
    }

    private func currentRelease() throws -> HTTPResponse {
        let data = try readCurrentReleaseData()
        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)
        return .json(data)
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
