import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PummelchenCore

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

    public init(configuration: ClientControlChannelConfiguration) {
        self.configuration = configuration
    }

    public func controlInfo() async throws -> ControlChannelInfo {
        let url = configuration.serverURL.appendingPathComponent("h3/v1/control")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            try ContractValidation.require((200..<300).contains(http.statusCode), "control info failed with HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ControlChannelInfo.self, from: data)
    }

    public func fetchMissedEvents(afterEventID: String? = nil, limit: Int = 50, waitSeconds: Int = 0) async throws -> ControlEventBatch {
        var components = URLComponents(url: configuration.serverURL.appendingPathComponent("api/v1/control/events"), resolvingAgainstBaseURL: false)!
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
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(configuration.clientAPIToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.clientID, forHTTPHeaderField: "X-Pummelchen-Client-ID")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            try ContractValidation.require((200..<300).contains(http.statusCode), "control fallback fetch failed with HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(ControlEventBatch.self, from: data)
    }

    public func acknowledge(_ event: ControlEvent) async throws {
        let ack = ControlEventAck(clientID: configuration.clientID, eventID: event.eventID, receivedAt: Self.isoNow())
        var request = URLRequest(url: configuration.serverURL.appendingPathComponent("api/v1/control/acks"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.clientAPIToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.clientID, forHTTPHeaderField: "X-Pummelchen-Client-ID")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ack)
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            try ContractValidation.require((200..<300).contains(http.statusCode), "control ack failed with HTTP \(http.statusCode)")
        }
    }

    public func reconnectWithFallback(afterEventID: String? = nil) async throws -> ControlEventBatch {
        do {
            let info = try await controlInfo()
            if !info.transportTarget.contains("http3_quic") || !info.bidirectional || info.downloadsAllowed {
                throw ContractValidationError.invalid("control endpoint does not advertise safe QUIC control semantics")
            }
        } catch {
            return try await fetchMissedEvents(afterEventID: afterEventID, waitSeconds: 5)
        }
        return try await fetchMissedEvents(afterEventID: afterEventID, waitSeconds: 5)
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
