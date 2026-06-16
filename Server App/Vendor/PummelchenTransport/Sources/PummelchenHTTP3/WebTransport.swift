/// WebTransport over HTTP/3 (draft-ietf-webtrans-http3-15)
///
/// Implements WebTransport sessions, streams, and capsules
/// on top of HTTP/3 connections.
///
/// Key draft-15 compliance:
/// - `:protocol` = "webtransport-h3"
/// - SETTINGS_WT_ENABLED = 0x2c7cf000
/// - Bidi stream prefix: 0x41 (WT_STREAM) + session ID
/// - Uni stream type: 0x54
/// - Error code base: 0x52e4a40fa8db
/// - RESET_STREAM_AT frame (0x24) + transport parameter (0x17f7586d2cb571)

import Foundation
import PummelchenQuicCore
import PummelchenQuic
import PummelchenQuicCrypto

// MARK: - WebTransport Constants

/// WebTransport draft-15 constants.
public enum WebTransportH3Constants {
    /// The `:protocol` pseudo-header value for WebTransport sessions
    public static let protocolValue = "webtransport-h3"

    /// SETTINGS_WT_ENABLED identifier (draft-15 §9.2)
    public static let settingsWTEnabled: UInt64 = 0x2c7cf000

    /// Bidirectional stream signal byte (draft-15 §4.3)
    public static let bidiStreamSignal: UInt8 = 0x41

    /// Unidirectional stream type (draft-15 §4.4)
    public static let uniStreamType: UInt64 = 0x54

    /// WebTransport error code base (draft-15 §4.6)
    public static let errorCodeBase: UInt64 = 0x52e4a40fa8db

    /// RESET_STREAM_AT frame type (draft-ietf-quic-reliable-stream-reset-07)
    public static let resetStreamAtFrameType: UInt64 = 0x24

    /// RESET_STREAM_AT transport parameter
    public static let resetStreamAtTransportParam: UInt64 = 0x17f7586d2cb571

    /// Map an application error code (0-0x10000) to a QUIC error code.
    public static func quicErrorCode(from appCode: UInt64) -> UInt64 {
        return errorCodeBase + appCode
    }
}

// MARK: - WebTransport Capsule Types

/// WebTransport capsule types (draft-15 §5).
public enum WTCapsuleType: UInt64, Sendable {
    case drainUni = 0x00 // CLOSE_WEBTRANSPORT_SESSION
    case wtStreamUni = 0x01 // WT_RESET_STREAM (not used in this impl)
}

/// A WebTransport capsule (type + length + payload).
public struct WTCapsule: Sendable {
    public let type: UInt64
    public let payload: Data

    public init(type: UInt64, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// Encode the capsule.
    public func encode() -> Data {
        var result = Data()
        result.append(contentsOf: Varint.encode(type))
        result.append(contentsOf: Varint.encode(UInt64(payload.count)))
        result.append(payload)
        return result
    }

    /// Decode a capsule from data.
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

// MARK: - WebTransport Session

/// A WebTransport session (established via Extended CONNECT).
public final class WebTransportSession: @unchecked Sendable {
    /// Session ID (= the stream ID of the CONNECT request)
    public let sessionID: UInt64

    /// Whether the session is active
    public var isActive: Bool = true

    /// Active bidirectional streams
    private var bidiStreams: [UInt64: WebTransportStream] = [:]

    /// Active unidirectional streams
    private var uniStreams: [UInt64: WebTransportStream] = [:]

    /// Async stream for incoming bidirectional streams from the peer
    private var incomingBidiContinuation: AsyncStream<WebTransportStream>.Continuation?
    public let incomingBidiStreams: AsyncStream<WebTransportStream>

    /// Async stream for incoming unidirectional streams from the peer
    private var incomingUniContinuation: AsyncStream<WebTransportStream>.Continuation?
    public let incomingUniStreams: AsyncStream<WebTransportStream>

    public init(sessionID: UInt64) {
        self.sessionID = sessionID

        let (bidiStream, bidiContinuation) = AsyncStream<WebTransportStream>.makeStream()
        self.incomingBidiStreams = bidiStream
        self.incomingBidiContinuation = bidiContinuation

        let (uniStream, uniContinuation) = AsyncStream<WebTransportStream>.makeStream()
        self.incomingUniStreams = uniStream
        self.incomingUniContinuation = uniContinuation
    }

    // MARK: - Stream Management

    /// Handle an incoming bidirectional stream from the peer.
    public func handleIncomingBidiStream(streamID: UInt64) -> WebTransportStream {
        let stream = WebTransportStream(streamID: streamID, sessionID: sessionID, isBidirectional: true)
        bidiStreams[streamID] = stream
        incomingBidiContinuation?.yield(stream)
        return stream
    }

    /// Handle an incoming unidirectional stream from the peer.
    public func handleIncomingUniStream(streamID: UInt64) -> WebTransportStream {
        let stream = WebTransportStream(streamID: streamID, sessionID: sessionID, isBidirectional: false)
        uniStreams[streamID] = stream
        incomingUniContinuation?.yield(stream)
        return stream
    }

    /// Close the session with an optional error.
    public func close(errorCode: UInt32 = 0, reason: String = "") {
        isActive = false

        // Send CLOSE_WEBTRANSPORT_SESSION capsule on the connect stream
        var payload = Data()
        var code = errorCode.bigEndian
        payload.append(Data(bytes: &code, count: 4))
        if !reason.isEmpty {
            payload.append(Data(reason.utf8))
        }
        let capsule = WTCapsule(type: WTCapsuleType.drainUni.rawValue, payload: payload)
        _ = capsule.encode() // Would be sent on the connect stream

        incomingBidiContinuation?.finish()
        incomingUniContinuation?.finish()
    }

    deinit {
        incomingBidiContinuation?.finish()
        incomingUniContinuation?.finish()
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

    /// Whether the stream is open
    public var isOpen: Bool = true

    /// Read buffer for incoming data
    private var readBuffer = Data()

    public init(streamID: UInt64, sessionID: UInt64, isBidirectional: Bool) {
        self.streamID = streamID
        self.sessionID = sessionID
        self.isBidirectional = isBidirectional
    }

    /// Write the stream header (for outgoing streams).
    /// Bidi: 0x41 + sessionID varint
    /// Uni: 0x54 varint + sessionID varint
    public func buildStreamHeader() -> Data {
        var header = Data()
        if isBidirectional {
            header.append(WebTransportH3Constants.bidiStreamSignal)
            header.append(contentsOf: Varint.encode(sessionID))
        } else {
            header.append(contentsOf: Varint.encode(WebTransportH3Constants.uniStreamType))
            header.append(contentsOf: Varint.encode(sessionID))
        }
        return header
    }

    /// Feed received data into the read buffer.
    public func receiveData(_ data: Data) {
        readBuffer.append(data)
    }

    /// Read available data.
    public func read(maxBytes: Int = Int.max) -> Data? {
        guard !readBuffer.isEmpty else { return nil }
        let toRead = min(readBuffer.count, maxBytes)
        let data = Data(readBuffer.prefix(toRead))
        readBuffer.removeFirst(toRead)
        return data
    }

    /// Close the stream.
    public func close() {
        isOpen = false
    }
}

// MARK: - WebTransport Server

/// WebTransport server that accepts sessions.
public final class WebTransportServer: @unchecked Sendable {
    /// Maximum concurrent sessions
    public let maxSessions: Int

    /// Active sessions
    private var sessions: [UInt64: WebTransportSession] = [:]

    /// Async stream for incoming session requests
    private var sessionContinuation: AsyncStream<WebTransportSession>.Continuation?
    public let incomingSessions: AsyncStream<WebTransportSession>

    public init(maxSessions: Int = 128) {
        self.maxSessions = maxSessions

        let (stream, continuation) = AsyncStream<WebTransportSession>.makeStream()
        self.incomingSessions = stream
        self.sessionContinuation = continuation
    }

    /// Handle an incoming CONNECT request that is a WebTransport session.
    public func acceptSession(streamID: UInt64, headers: [QPACK.HeaderField]) -> WebTransportSession? {
        guard sessions.count < maxSessions else { return nil }

        // Verify this is a WebTransport CONNECT
        let method = headers.first(where: { $0.name == ":method" })?.value
        let proto = headers.first(where: { $0.name == ":protocol" })?.value
        guard method == "CONNECT", proto == WebTransportH3Constants.protocolValue else {
            return nil
        }

        let session = WebTransportSession(sessionID: streamID)
        sessions[streamID] = session
        sessionContinuation?.yield(session)
        return session
    }

    /// Remove a closed session.
    public func removeSession(_ sessionID: UInt64) {
        sessions.removeValue(forKey: sessionID)
    }

    /// Get an active session by ID.
    public func session(for sessionID: UInt64) -> WebTransportSession? {
        return sessions[sessionID]
    }

    deinit {
        sessionContinuation?.finish()
    }
}

// MARK: - WebTransport Client

/// WebTransport client that initiates sessions.
public final class WebTransportClient: @unchecked Sendable {
    public init() {}

    /// Build the CONNECT request headers for a new WebTransport session.
    public func buildConnectHeaders(authority: String, path: String = "/") -> [QPACK.HeaderField] {
        return [
            QPACK.HeaderField(name: ":method", value: "CONNECT"),
            QPACK.HeaderField(name: ":protocol", value: WebTransportH3Constants.protocolValue),
            QPACK.HeaderField(name: ":scheme", value: "https"),
            QPACK.HeaderField(name: ":authority", value: authority),
            QPACK.HeaderField(name: ":path", value: path),
            QPACK.HeaderField(name: "origin", value: "https://\(authority)"),
        ]
    }
}
