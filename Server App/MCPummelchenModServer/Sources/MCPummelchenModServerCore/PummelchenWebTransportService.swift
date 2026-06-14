import Foundation
import HTTP3
import PummelchenCore
import QUIC
import QUICCrypto

public struct PummelchenWebTransportServiceConfig: Sendable {
    public static let defaultMaxControlPayloadBytes = 512 * 1024

    public let host: String
    public let port: UInt16
    public let path: String
    public let certificatePath: String
    public let privateKeyPath: String
    public let projectRoot: URL
    public let databaseURL: URL
    public let clientAPIToken: String?
    public let maxSessions: UInt64
    public let maxControlPayloadBytes: Int

    public init(
        host: String = "0.0.0.0",
        port: UInt16 = 443,
        path: String = "/webtransport/v1/control",
        certificatePath: String = "/etc/letsencrypt/live/pummelchen.91.99.176.243.nip.io/cert.pem",
        privateKeyPath: String = "/etc/letsencrypt/live/pummelchen.91.99.176.243.nip.io/privkey.pem",
        projectRoot: URL,
        databaseURL: URL,
        clientAPIToken: String?,
        maxSessions: UInt64 = 128,
        maxControlPayloadBytes: Int = PummelchenWebTransportServiceConfig.defaultMaxControlPayloadBytes
    ) {
        self.host = host
        self.port = port
        self.path = path.hasPrefix("/") ? path : "/\(path)"
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.projectRoot = projectRoot
        self.databaseURL = databaseURL
        self.clientAPIToken = clientAPIToken
        self.maxSessions = maxSessions
        self.maxControlPayloadBytes = maxControlPayloadBytes
    }
}

public final class PummelchenWebTransportService: @unchecked Sendable {
    private let config: PummelchenWebTransportServiceConfig
    private let runtime: WebTransportRuntimeState
    private let controlStore: ControlEventStore
    private let reportStore: ServerClientReportStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var task: Task<Void, Never>?

    public init(config: PummelchenWebTransportServiceConfig, runtime: WebTransportRuntimeState) {
        self.config = config
        self.runtime = runtime
        self.controlStore = ControlEventStore(databaseURL: config.databaseURL)
        self.reportStore = ServerClientReportStore(databaseURL: config.databaseURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func start() {
        guard task == nil else {
            return
        }
        task = Task {
            do {
                try await run()
            } catch {
                runtime.markFailed(error)
                FileHandle.standardError.write(Data("pummelchen_webtransport_error=\(error)\n".utf8))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        runtime.markStopped()
    }

    private func run() async throws {
        try controlStore.initialize()
        var tls = try TLSConfiguration.server(
            certificatePath: config.certificatePath,
            privateKeyPath: config.privateKeyPath,
            alpnProtocols: ["h3"]
        )
        tls.verifyPeer = false
        let tlsConfiguration = tls

        var quic = QUICConfiguration.production {
            TLS13Handler(configuration: tlsConfiguration)
        }
        quic.alpn = ["h3"]
        quic.maxIdleTimeout = .seconds(90)
        quic.initialMaxStreamsBidi = 512
        quic.initialMaxStreamsUni = 512
        quic.initialMaxData = 32_000_000
        quic.initialMaxStreamDataBidiLocal = 4_000_000
        quic.initialMaxStreamDataBidiRemote = 4_000_000
        quic.initialMaxStreamDataUni = 4_000_000
        quic.enableDatagrams = true
        quic.maxDatagramFrameSize = 65_535

        let server = WebTransportServer(
            configuration: WebTransportConfiguration(
                quic: quic,
                maxSessions: config.maxSessions
            ),
            serverOptions: WebTransportServer.ServerOptions(
                allowedPaths: [config.path]
            )
        )

        let sessionTask = Task {
            for await session in await server.incomingSessions {
                Task {
                    await self.handle(session)
                }
            }
        }

        runtime.markActive()
        FileHandle.standardOutput.write(Data("pummelchen_webtransport=ready host=\(config.host) port=\(config.port) path=\(config.path)\n".utf8))

        do {
            try await server.listen(host: config.host, port: config.port)
        } catch {
            sessionTask.cancel()
            await server.stop(gracePeriod: .seconds(2))
            throw error
        }
    }

    private func handle(_ session: WebTransportSession) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await stream in await session.incomingBidirectionalStreams {
                    await self.handle(stream)
                }
            }
            group.addTask {
                for await _ in await session.incomingDatagrams {
                    // Datagrams are negotiated for WebTransport capability, but
                    // Pummelchen control traffic is authenticated JSON on streams.
                }
            }
        }
    }

    private func handle(_ stream: WebTransportStream) async {
        do {
            let requestData = try await readAll(from: stream)
            let request = try decoder.decode(WebTransportControlRequest.self, from: requestData)
            let response = try process(request)
            try await stream.write(encoder.encode(response))
            try await stream.closeWrite()
        } catch {
            let response = WebTransportControlResponse(
                ok: false,
                error: String(describing: error),
                serverTime: Self.isoNow()
            )
            try? await stream.write(encoder.encode(response))
            try? await stream.closeWrite()
        }
    }

    private func process(_ request: WebTransportControlRequest) throws -> WebTransportControlResponse {
        try authorize(request)
        switch request.action {
        case "current_release":
            let release = try currentRelease()
            return WebTransportControlResponse(
                ok: true,
                currentRelease: release,
                serverTime: Self.isoNow()
            )

        case "fetch_events":
            let events = try controlStore.pendingEvents(
                clientID: request.clientID,
                afterEventID: request.afterEventID,
                limit: request.limit ?? 50
            )
            let batch = ControlEventBatch(
                events: events,
                nextAfterEventID: events.last?.eventID ?? request.afterEventID,
                transport: "webtransport_h3_dedicated_udp",
                fallback: "none"
            )
            return WebTransportControlResponse(ok: true, batch: batch, serverTime: Self.isoNow())

        case "ack_event":
            guard let eventID = request.eventID, !eventID.isEmpty else {
                throw ContractValidationError.invalid("event_id is required for ack_event")
            }
            let ack = ControlEventAck(
                clientID: request.clientID,
                eventID: eventID,
                receivedAt: request.receivedAt ?? Self.isoNow()
            )
            try controlStore.acknowledge(ack)
            return WebTransportControlResponse(
                ok: true,
                ack: ClientWriteAck(clientID: request.clientID, events: 1),
                serverTime: Self.isoNow()
            )

        case "register_client":
            guard let payload = request.registration else {
                throw ContractValidationError.invalid("registration is required for register_client")
            }
            try requireMatchingClientID(request.clientID, payload.clientID)
            try reportStore.register(payload)
            return WebTransportControlResponse(
                ok: true,
                ack: ClientWriteAck(clientID: payload.clientID),
                serverTime: Self.isoNow()
            )

        case "status_report", "sync_run_report", "heartbeat_report":
            guard let payload = request.statusReport else {
                throw ContractValidationError.invalid("status_report is required for \(request.action)")
            }
            try requireMatchingClientID(request.clientID, payload.clientID)
            try reportStore.recordStatus(payload)
            return WebTransportControlResponse(
                ok: true,
                ack: ClientWriteAck(clientID: payload.clientID),
                serverTime: Self.isoNow()
            )

        case "inventory_upload":
            guard let payload = request.inventory else {
                throw ContractValidationError.invalid("inventory is required for inventory_upload")
            }
            try requireMatchingClientID(request.clientID, payload.clientID)
            try reportStore.recordInventory(payload)
            return WebTransportControlResponse(
                ok: true,
                ack: ClientWriteAck(clientID: payload.clientID, files: payload.files.count),
                serverTime: Self.isoNow()
            )

        case "diagnostics_upload":
            guard let payload = request.diagnostics else {
                throw ContractValidationError.invalid("diagnostics is required for diagnostics_upload")
            }
            try requireMatchingClientID(request.clientID, payload.clientID)
            try reportStore.recordDiagnostics(payload)
            return WebTransportControlResponse(
                ok: true,
                ack: ClientWriteAck(clientID: payload.clientID),
                serverTime: Self.isoNow()
            )

        case "defaults_events_upload":
            guard let payload = request.defaultsEvents else {
                throw ContractValidationError.invalid("defaults_events is required for defaults_events_upload")
            }
            try requireMatchingClientID(request.clientID, payload.clientID)
            try reportStore.recordDefaultsEvent(payload)
            return WebTransportControlResponse(
                ok: true,
                ack: ClientWriteAck(clientID: payload.clientID, events: payload.events.count),
                serverTime: Self.isoNow()
            )

        default:
            throw ContractValidationError.invalid("unsupported WebTransport control action: \(request.action)")
        }
    }

    private func authorize(_ request: WebTransportControlRequest) throws {
        try ContractValidation.requireClientID(request.clientID)
        guard let expected = config.clientAPIToken, !expected.isEmpty else {
            throw MCPummelchenModServerError.unauthorized("client API token not configured")
        }
        guard request.clientAPIToken == expected else {
            throw MCPummelchenModServerError.unauthorized("invalid client API token")
        }
    }

    private func currentRelease() throws -> CurrentRelease {
        let data = try Data(contentsOf: config.projectRoot.appendingPathComponent("site/public/downloads/current-release.json"))
        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)
        return release
    }

    private func requireMatchingClientID(_ requestClientID: String, _ payloadClientID: String) throws {
        if requestClientID != payloadClientID {
            throw MCPummelchenModServerError.unauthorized("client id does not match payload")
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
            if data.count > config.maxControlPayloadBytes {
                throw MCPummelchenModServerError.payloadTooLarge(data.count)
            }
        }
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
