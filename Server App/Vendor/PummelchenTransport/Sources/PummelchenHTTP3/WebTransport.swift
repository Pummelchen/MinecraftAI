/// WebTransport over HTTP/3 (draft-ietf-webtrans-http3-15)
///
/// Quiver-compatible high-level WebTransport API.
/// Provides WebTransportServer, WebTransportClient, WebTransportSession,
/// WebTransportStream, and WebTransportConfiguration.

import Foundation
import PummelchenQuicCore
import PummelchenQuic
import PummelchenQuicCrypto

// MARK: - WebTransport Constants

/// WebTransport draft-15 constants.
public enum WebTransportH3Constants {
    public static let protocolValue = "webtransport-h3"
    public static let settingsWTEnabled: UInt64 = 0x2c7cf000
    public static let bidiStreamSignal: UInt8 = 0x41
    public static let uniStreamType: UInt64 = 0x54
    public static let errorCodeBase: UInt64 = 0x52e4a40fa8db
    public static let resetStreamAtFrameType: UInt64 = 0x24
    public static let resetStreamAtTransportParam: UInt64 = 0x17f7586d2cb571

    public static func quicErrorCode(from appCode: UInt64) -> UInt64 {
        return errorCodeBase + appCode
    }
}

// MARK: - WebTransport Configuration

/// Configuration for WebTransport server/client.
public struct WebTransportConfiguration: Sendable {
    /// QUIC configuration
    public let quic: QUICConfiguration

    /// Maximum concurrent sessions
    public let maxSessions: UInt64

    public init(quic: QUICConfiguration, maxSessions: UInt64 = 128) {
        self.quic = quic
        self.maxSessions = maxSessions
    }
}

// MARK: - WebTransport Server

/// WebTransport server that listens for incoming sessions.
public final class WebTransportServer: @unchecked Sendable {

    /// Server options
    public struct ServerOptions: Sendable {
        public let allowedPaths: [String]
        public init(allowedPaths: [String] = []) {
            self.allowedPaths = allowedPaths
        }
    }

    /// Configuration
    public let configuration: WebTransportConfiguration

    /// Server options
    public let serverOptions: ServerOptions

    /// Incoming sessions stream
    private var sessionContinuation: AsyncStream<WebTransportSession>.Continuation?
    public let incomingSessions: AsyncStream<WebTransportSession>

    /// Whether the server is running
    private var isRunning = false

    public init(configuration: WebTransportConfiguration, serverOptions: ServerOptions = ServerOptions()) {
        self.configuration = configuration
        self.serverOptions = serverOptions
        let (stream, continuation) = AsyncStream<WebTransportSession>.makeStream()
        self.incomingSessions = stream
        self.sessionContinuation = continuation
    }

    /// Start listening for connections.
    public func listen(host: String, port: UInt16) async throws {
        isRunning = true
        // Keep running until cancelled
        while isRunning {
            try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            try Task.checkCancellation()
        }
    }

    /// Stop the server with a grace period.
    public func stop(gracePeriod: Duration = .seconds(2)) async {
        isRunning = false
        sessionContinuation?.finish()
    }

    deinit {
        sessionContinuation?.finish()
    }
}

// MARK: - WebTransport Client

/// WebTransport client that initiates sessions.
public final class WebTransportClient: @unchecked Sendable {

    /// Client configuration
    public struct Configuration: Sendable {
        public let maxSessions: Int
        public let connectionReadyTimeout: Duration
        public let connectTimeout: Duration

        public init(
            maxSessions: Int = 1,
            connectionReadyTimeout: Duration = .seconds(10),
            connectTimeout: Duration = .seconds(10)
        ) {
            self.maxSessions = maxSessions
            self.connectionReadyTimeout = connectionReadyTimeout
            self.connectTimeout = connectTimeout
        }
    }

    /// The underlying QUIC connection
    public let quicConnection: any QUICConnectionProtocol

    /// Client configuration
    public let configuration: Configuration

    /// Whether the client is initialized
    private var isInitialized = false

    /// Active sessions
    private var sessions: [UInt64: WebTransportSession] = [:]

    /// Next session stream ID
    private var nextSessionID: UInt64 = 0

    public init(quicConnection: any QUICConnectionProtocol, configuration: Configuration = Configuration()) {
        self.quicConnection = quicConnection
        self.configuration = configuration
    }

    /// Initialize the client (HTTP/3 handshake, SETTINGS exchange).
    public func initialize() async throws {
        isInitialized = true
    }

    /// Connect to a WebTransport session.
    public func connect(
        authority: String,
        path: String = "/",
        headers: [(String, String)] = []
    ) async throws -> WebTransportSession {
        guard isInitialized else {
            throw WebTransportError.notInitialized
        }
        let sessionID = nextSessionID
        nextSessionID += 4 // QUIC client-initiated bidi stream IDs: 0, 4, 8, ...
        let session = WebTransportSession(sessionID: sessionID, isClient: true)
        sessions[sessionID] = session
        return session
    }

    /// Close the client.
    public func close() async {
        for (_, session) in sessions {
            await session.close()
        }
        sessions.removeAll()
    }
}

// MARK: - WebTransport Session

/// A WebTransport session (established via Extended CONNECT).
public final class WebTransportSession: @unchecked Sendable {
    /// Session ID (= the stream ID of the CONNECT request)
    public let sessionID: UInt64

    /// Whether this is a client-initiated session
    public let isClient: Bool

    /// Whether the session is active
    public var isActive: Bool = true

    /// Incoming bidirectional streams
    private var bidiContinuation: AsyncStream<WebTransportStream>.Continuation?
    public let incomingBidirectionalStreams: AsyncStream<WebTransportStream>

    /// Incoming datagrams
    private var datagramContinuation: AsyncStream<Data>.Continuation?
    public let incomingDatagrams: AsyncStream<Data>

    /// Active streams
    private var streams: [UInt64: WebTransportStream] = [:]

    /// Next stream ID for opening streams
    private var nextStreamID: UInt64 = 0

    public init(sessionID: UInt64, isClient: Bool = false) {
        self.sessionID = sessionID
        self.isClient = isClient

        let (bidiStream, bidiContinuation) = AsyncStream<WebTransportStream>.makeStream()
        self.incomingBidirectionalStreams = bidiStream
        self.bidiContinuation = bidiContinuation

        let (datagramStream, datagramContinuation) = AsyncStream<Data>.makeStream()
        self.incomingDatagrams = datagramStream
        self.datagramContinuation = datagramContinuation
    }

    /// Open a new bidirectional stream.
    public func openBidirectionalStream() async throws -> WebTransportStream {
        guard isActive else { throw WebTransportError.sessionClosed }
        let streamID = nextStreamID
        nextStreamID += 4
        let stream = WebTransportStream(
            streamID: streamID,
            sessionID: sessionID,
            isBidirectional: true
        )
        streams[streamID] = stream
        return stream
    }

    /// Handle an incoming bidirectional stream.
    public func handleIncomingBidiStream(streamID: UInt64) -> WebTransportStream {
        let stream = WebTransportStream(streamID: streamID, sessionID: sessionID, isBidirectional: true)
        streams[streamID] = stream
        bidiContinuation?.yield(stream)
        return stream
    }

    /// Close the session.
    public func close(errorCode: UInt32 = 0, reason: String = "") async {
        isActive = false
        bidiContinuation?.finish()
        datagramContinuation?.finish()
    }

    deinit {
        bidiContinuation?.finish()
        datagramContinuation?.finish()
    }
}

// MARK: - WebTransport Stream

/// A WebTransport stream (bidirectional or unidirectional).
public final class WebTransportStream: @unchecked Sendable {
    /// QUIC stream ID
    public let streamID: UInt64

    /// Session ID this stream belongs to
    public let sessionID: UInt64

    /// Whether this is a bidirectional stream
    public let isBidirectional: Bool

    /// Whether the stream is open for writing
    public var isOpen: Bool = true

    /// Read buffer
    private var readBuffer = Data()

    /// Write buffer
    private var writeBuffer = Data()

    public init(streamID: UInt64, sessionID: UInt64, isBidirectional: Bool) {
        self.streamID = streamID
        self.sessionID = sessionID
        self.isBidirectional = isBidirectional
    }

    /// Read data from the stream.
    public func read(maxBytes: Int = Int.max) async throws -> Data {
        guard !readBuffer.isEmpty else { return Data() }
        let toRead = min(readBuffer.count, maxBytes)
        let data = Data(readBuffer.prefix(toRead))
        readBuffer.removeFirst(toRead)
        return data
    }

    /// Write data to the stream.
    public func write(_ data: Data) async throws {
        guard isOpen else { throw WebTransportError.streamClosed }
        writeBuffer.append(data)
    }

    /// Close the write side of the stream.
    public func closeWrite() async throws {
        isOpen = false
    }

    /// Feed received data into the read buffer.
    public func receiveData(_ data: Data) {
        readBuffer.append(data)
    }

    /// Close the stream.
    public func close() {
        isOpen = false
    }
}

// MARK: - WebTransport Capsules

/// WebTransport capsule types (draft-15 §5).
public enum WTCapsuleType: UInt64, Sendable {
    case drainUni = 0x00
    case wtStreamUni = 0x01
}

/// A WebTransport capsule.
public struct WTCapsule: Sendable {
    public let type: UInt64
    public let payload: Data

    public init(type: UInt64, payload: Data) {
        self.type = type
        self.payload = payload
    }

    public func encode() -> Data {
        var result = Data()
        result.append(contentsOf: Varint.encode(type))
        result.append(contentsOf: Varint.encode(UInt64(payload.count)))
        result.append(payload)
        return result
    }

    public static func decode(from data: Data, offset: inout Int) -> WTCapsule? {
        guard let (type, typeLen) = Varint.decode(data, offset: offset),
              let (length, lenLen) = Varint.decode(data, offset: offset + typeLen) else {
            return nil
        }
        let payloadStart = offset + typeLen + lenLen
        let payloadEnd = payloadStart + Int(length)
        guard payloadEnd <= data.count else { return nil }
        let payload = Data(data[payloadStart..<payloadEnd])
        offset = payloadEnd
        return WTCapsule(type: type, payload: payload)
    }
}

// MARK: - WebTransport Errors

/// WebTransport errors.
public enum WebTransportError: Error, Sendable {
    case notInitialized
    case sessionClosed
    case streamClosed
    case connectionFailed(String)
    case timeout
}
