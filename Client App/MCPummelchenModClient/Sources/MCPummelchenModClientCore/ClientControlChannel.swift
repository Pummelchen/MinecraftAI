import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MCPummelchenModShared

public struct ClientControlChannelConfiguration: Sendable {
    public let serverURL: URL
    public let clientID: String
    public let clientAPIToken: String

    public init(serverURL: URL = URL(string: "https://pummelchen.91.99.176.243.nip.io")!, clientID: String, clientAPIToken: String) {
        self.serverURL = serverURL
        self.clientID = clientID
        self.clientAPIToken = clientAPIToken
    }
}

public struct ClientControlChannel: Sendable {
    public let configuration: ClientControlChannelConfiguration
    private let http: ClientHTTPClient
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configuration: ClientControlChannelConfiguration) {
        self.configuration = configuration
        self.http = ClientHTTPClient(retryPolicy: ClientHTTPRetryPolicy(maxAttempts: 3, requestTimeoutSeconds: 40))
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func controlInfo() async throws -> ControlChannelInfo {
        let url = configuration.serverURL.appendingPathComponent("api/v1/control/info")
        let data = try await http.data(from: url, headers: authHeaders())
        return try decoder.decode(ControlChannelInfo.self, from: data)
    }

    public func fetchEvents(afterEventID: String? = nil, limit: Int = 50, waitSeconds: Int = 0) async throws -> ControlEventBatch {
        guard var components = URLComponents(url: configuration.serverURL.appendingPathComponent("api/v1/control/events"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var query = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let afterEventID, !afterEventID.isEmpty {
            query.append(URLQueryItem(name: "after_event_id", value: afterEventID))
        }
        if waitSeconds > 0 {
            query.append(URLQueryItem(name: "wait_seconds", value: String(min(waitSeconds, 30))))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuthHeaders(to: &request)
        let data = try await http.send(request)
        return try decoder.decode(ControlEventBatch.self, from: data)
    }

    public func acknowledge(_ event: ControlEvent) async throws {
        let payload = ControlEventAck(clientID: configuration.clientID, eventID: event.eventID, receivedAt: Self.isoNow())
        _ = try await post(payload, to: "api/v1/control/acks", as: ClientWriteAck.self)
    }

    @discardableResult
    public func register(_ payload: ClientRegistrationRequest) async throws -> ClientWriteAck {
        try await post(payload, to: "api/v1/clients/register", as: ClientWriteAck.self)
    }

    @discardableResult
    public func reportStatus(_ payload: ClientStatusReport) async throws -> ClientWriteAck {
        try await post(payload, to: "api/v1/clients/sync-runs", as: ClientWriteAck.self)
    }

    @discardableResult
    public func uploadInventory(_ payload: ClientInventoryUpload) async throws -> ClientWriteAck {
        try await post(payload, to: "api/v1/clients/inventory", as: ClientWriteAck.self)
    }

    @discardableResult
    public func uploadDiagnostics(_ payload: ClientDiagnosticsUpload) async throws -> ClientWriteAck {
        try await post(payload, to: "api/v1/clients/diagnostics", as: ClientWriteAck.self)
    }

    @discardableResult
    public func uploadDefaultsEvents(_ payload: ClientDefaultsEventUpload) async throws -> ClientWriteAck {
        try await post(payload, to: "api/v1/clients/defaults-events", as: ClientWriteAck.self)
    }

    public func lastNegotiatedProtocol() async -> String? {
        await http.lastNegotiatedProtocol()
    }

    private func post<Payload: Encodable, Response: Decodable>(_ payload: Payload, to path: String, as type: Response.Type) async throws -> Response {
        var request = URLRequest(url: configuration.serverURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeaders(to: &request)
        let data = try await http.send(request)
        return try decoder.decode(Response.self, from: data)
    }

    private func authHeaders() -> [String: String] {
        [
            "Authorization": "Bearer \(configuration.clientAPIToken)",
            "X-Pummelchen-Client-ID": configuration.clientID
        ]
    }

    private func addAuthHeaders(to request: inout URLRequest) {
        for (key, value) in authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
