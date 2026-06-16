import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import PummelchenHTTP3
import MCPummelchenModShared
import PummelchenQuic
import PummelchenQuicCrypto

/// A persistent WebTransport channel that reuses a single QUIC connection
/// across multiple control requests. Reconnects automatically on failure
/// or after the idle timeout expires.
actor PooledWebTransportChannel {
    private static let maxControlPayloadBytes = 512 * 1024
    private let idleTimeout: TimeInterval = 40

    private let preflightProvider: @Sendable () async throws -> WebTransportPreflightPayload
    private let clientID: String
    private let clientAPIToken: String

    private var endpoint: QUICEndpoint?
    private var connection: (any QUICConnectionProtocol)?
    private var client: WebTransportClient?
    private var session: WebTransportSession?
    private var lastUsed: Date = .distantPast

    init(
        preflightProvider: @escaping @Sendable () async throws -> WebTransportPreflightPayload,
        clientID: String,
        clientAPIToken: String
    ) {
        self.preflightProvider = preflightProvider
        self.clientID = clientID
        self.clientAPIToken = clientAPIToken
    }

    func fetchEvents(afterEventID: String? = nil, limit: Int = 50) async throws -> ControlEventBatch {
        let response = try await send(WebTransportControlRequest(
            action: "fetch_events",
            clientID: clientID,
            clientAPIToken: clientAPIToken,
            afterEventID: afterEventID,
            limit: limit
        ))
        if let batch = response.batch {
            return batch
        }
        throw ContractValidationError.invalid(response.error ?? "WebTransport fetch_events returned no batch")
    }

    func acknowledge(_ event: ControlEvent) async throws {
        let response = try await send(WebTransportControlRequest(
            action: "ack_event",
            clientID: clientID,
            clientAPIToken: clientAPIToken,
            eventID: event.eventID,
            receivedAt: Self.isoNow()
        ))
        if !response.ok {
            throw ContractValidationError.invalid(response.error ?? "WebTransport ack_event failed")
        }
    }

    func currentRelease() async throws -> CurrentRelease {
        let response = try await send(WebTransportControlRequest(
            action: "current_release",
            clientID: clientID,
            clientAPIToken: clientAPIToken
        ))
        guard let release = response.currentRelease else {
            throw ContractValidationError.invalid(response.error ?? "WebTransport current_release returned no release")
        }
        try CurrentReleaseValidator.validate(release)
        return release
    }

    func reportStatus(_ payload: ClientStatusReport, action: String = "status_report") async throws -> ClientWriteAck {
        try await write(
            action: action,
            request: WebTransportControlRequest(
                action: action,
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                statusReport: payload
            )
        )
    }

    func uploadInventory(_ payload: ClientInventoryUpload) async throws -> ClientWriteAck {
        try await write(
            action: "inventory_upload",
            request: WebTransportControlRequest(
                action: "inventory_upload",
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                inventory: payload
            )
        )
    }

    func uploadDefaultsEvents(_ payload: ClientDefaultsEventUpload) async throws -> ClientWriteAck {
        try await write(
            action: "defaults_events_upload",
            request: WebTransportControlRequest(
                action: "defaults_events_upload",
                clientID: clientID,
                clientAPIToken: clientAPIToken,
                defaultsEvents: payload
            )
        )
    }

    func teardown() async {
        try? await session?.close()
        session = nil
        await client?.close()
        client = nil
        await connection?.close(error: nil)
        connection = nil
        try? await Task.sleep(nanoseconds: 150_000_000)
        await endpoint?.stop()
        endpoint = nil
    }

    // MARK: - Private

    private func write(action: String, request: WebTransportControlRequest) async throws -> ClientWriteAck {
        let response = try await send(request)
        if let ack = response.ack {
            return ack
        }
        throw ContractValidationError.invalid(response.error ?? "WebTransport \(action) returned no acknowledgement")
    }

    private func send(_ request: WebTransportControlRequest) async throws -> WebTransportControlResponse {
        if Date().timeIntervalSince(lastUsed) > idleTimeout {
            await teardown()
        }

        if session == nil {
            try await establishConnection()
        }

        lastUsed = Date()

        do {
            let stream = try await session!.openBidirectionalStream()
            try await stream.write(JSONEncoder().encode(request))
            try await stream.closeWrite()
            let data = try await readAll(from: stream)
            let response = try JSONDecoder().decode(WebTransportControlResponse.self, from: data)
            if !response.ok {
                throw ContractValidationError.invalid(response.error ?? "WebTransport control request failed")
            }
            return response
        } catch {
            await teardown()
            throw error
        }
    }

    private func establishConnection() async throws {
        let preflight = try await preflightProvider()
        guard preflight.ready else {
            throw ContractValidationError.invalid(preflight.unsupportedReason ?? "WebTransport is not ready")
        }

        guard let url = URL(string: preflight.sessionURL),
              let host = url.host(),
              let port = url.port else {
            throw ContractValidationError.invalid("invalid WebTransport session URL: \(preflight.sessionURL)")
        }
        let path = url.path().isEmpty ? "/" : url.path()
        let authority = "\(host):\(port)"

        var tls = TLSConfiguration.client(serverName: host, alpnProtocols: ["h3"])
        if let publicKey = preflight.serverPublicKeyX963Base64,
           let publicKeyData = Data(base64Encoded: publicKey),
           !publicKeyData.isEmpty {
            tls.verifyPeer = true
            tls.allowSelfSigned = false
            tls.expectedPeerPublicKey = publicKeyData
        } else {
            do {
                try tls.useSystemTrustStore()
                tls.verifyPeer = true
                tls.allowSelfSigned = false
            } catch {
                tls.verifyPeer = true
                tls.allowSelfSigned = false
            }
        }
        let tlsConfiguration = tls

        var quic = QUICConfiguration.production {
            TLS13Handler(configuration: tlsConfiguration)
        }
        quic.alpn = ["h3"]
        quic.maxIdleTimeout = .seconds(45)
        quic.initialMaxStreamsBidi = 64
        quic.initialMaxStreamsUni = 64
        quic.initialMaxData = 8_000_000
        quic.initialMaxStreamDataBidiLocal = 1_000_000
        quic.initialMaxStreamDataBidiRemote = 1_000_000
        quic.initialMaxStreamDataUni = 1_000_000
        quic.enableDatagrams = true
        quic.maxDatagramFrameSize = 65_535

        let dialHost = try Self.resolveDialHost(host)
        let newEndpoint = QUICEndpoint(configuration: quic)

        do {
            let newConnection = try await newEndpoint.dial(
                address: QUIC.SocketAddress(ipAddress: dialHost, port: UInt16(port)),
                timeout: .seconds(10)
            )

            let newClient = WebTransportClient(
                quicConnection: newConnection,
                configuration: WebTransportClient.Configuration(
                    maxSessions: 1,
                    connectionReadyTimeout: .seconds(10),
                    connectTimeout: .seconds(10)
                )
            )

            do {
                try await newClient.initialize()
            } catch {
                await newClient.close()
                await newEndpoint.stop()
                throw error
            }

            do {
                let newSession = try await newClient.connect(
                    authority: authority,
                    path: path,
                    headers: [
                        ("authorization", "Bearer \(clientAPIToken)"),
                        ("x-pummelchen-client-id", clientID)
                    ]
                )

                self.endpoint = newEndpoint
                self.connection = newConnection
                self.client = newClient
                self.session = newSession
            } catch {
                await newClient.close()
                await newEndpoint.stop()
                throw error
            }
        } catch {
            await newEndpoint.stop()
            throw error
        }
    }

    private func readAll(from stream: WebTransportStream) async throws -> Data {
        var data = Data()
        while true {
            let chunk = try await stream.read(maxBytes: 64 * 1024)
            if chunk.isEmpty {
                return data
            }
            data.append(chunk)
            if data.count > Self.maxControlPayloadBytes {
                throw ContractValidationError.invalid("WebTransport control response exceeded maximum size")
            }
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func resolveDialHost(_ host: String) throws -> String {
        if host.withCString({ inet_addr($0) }) != in_addr_t.max {
            return host
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw ContractValidationError.invalid("failed to resolve host \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }

        var ipv4Candidate: UnsafeMutablePointer<addrinfo>?
        var ipv6Candidate: UnsafeMutablePointer<addrinfo>?
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let ptr = current {
            let family = ptr.pointee.ai_addr.pointee.sa_family
            if family == UInt8(AF_INET), ipv4Candidate == nil {
                ipv4Candidate = ptr
            } else if family == UInt8(AF_INET6), ipv6Candidate == nil {
                ipv6Candidate = ptr
            }
            current = ptr.pointee.ai_next
        }

        let chosen = ipv4Candidate ?? ipv6Candidate
        guard let selected = chosen else {
            throw ContractValidationError.invalid("no usable address found for host \(host)")
        }

        let family = selected.pointee.ai_addr.pointee.sa_family
        if family == UInt8(AF_INET) {
            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let sinAddr = selected.pointee.ai_addr.withMemoryRebound(
                to: sockaddr_in.self, capacity: 1
            ) { $0.pointee.sin_addr }
            var mutableAddr = sinAddr
            guard inet_ntop(AF_INET, &mutableAddr, &address, socklen_t(INET_ADDRSTRLEN)) != nil else {
                throw ContractValidationError.invalid("failed to format IPv4 address for \(host)")
            }
            let length = address.firstIndex(of: 0) ?? address.count
            return String(decoding: address[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        } else {
            var address = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            let sin6 = selected.pointee.ai_addr.withMemoryRebound(
                to: sockaddr_in6.self, capacity: 1
            ) { $0.pointee.sin6_addr }
            var mutableAddr = sin6
            guard inet_ntop(AF_INET6, &mutableAddr, &address, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                throw ContractValidationError.invalid("failed to format IPv6 address for \(host)")
            }
            let length = address.firstIndex(of: 0) ?? address.count
            return String(decoding: address[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
}
