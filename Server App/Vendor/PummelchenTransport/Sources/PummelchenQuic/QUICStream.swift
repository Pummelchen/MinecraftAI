/// QUIC Stream Layer (RFC 9000 Section 2)
///
/// Implements QUIC bidirectional and unidirectional streams with
/// flow control, ordered delivery, and stream state management.

import Foundation
import PummelchenQuicCore

// MARK: - Stream ID

/// QUIC stream identifier utilities.
public enum StreamID {
    /// Client-initiated bidirectional streams have IDs: 0, 4, 8, ...
    public static func isClientInitiated(_ id: UInt64) -> Bool { id & 1 == 0 }

    /// Server-initiated streams have odd IDs.
    public static func isServerInitiated(_ id: UInt64) -> Bool { id & 1 == 1 }

    /// Bidirectional streams have IDs where bit 1 is 0.
    public static func isBidirectional(_ id: UInt64) -> Bool { id & 2 == 0 }

    /// Unidirectional streams have IDs where bit 1 is 1.
    public static func isUnidirectional(_ id: UInt64) -> Bool { id & 2 == 2 }

    /// Stream type from ID.
    public enum StreamType: Sendable {
        case clientBidi, serverBidi, clientUni, serverUni
    }

    public static func streamType(_ id: UInt64) -> StreamType {
        switch (id & 3) {
        case 0: return .clientBidi
        case 1: return .serverBidi
        case 2: return .clientUni
        case 3: return .serverUni
        default: return .clientBidi // unreachable
        }
    }
}

// MARK: - Stream State

/// QUIC stream states (RFC 9000 §3).
public enum StreamSendState: Sendable {
    case ready
    case send
    case dataSent
    case resetSent
    case resetRecvd
    case dataRecvd  // terminal
}

public enum StreamRecvState: Sendable {
    case recv
    case sizeKnown
    case dataRecvd
    case resetRecvd  // terminal
    case dataRead    // terminal
}

// MARK: - Stream Data Buffer

/// A contiguous buffer for stream data with offset tracking.
public struct StreamBuffer: Sendable {
    /// Base offset in the stream (absolute position).
    public let baseOffset: UInt64

    /// The buffered data.
    public let data: Data

    public init(offset: UInt64, data: Data) {
        self.baseOffset = offset
        self.data = data
    }

    /// End offset (exclusive).
    public var endOffset: UInt64 { baseOffset + UInt64(data.count) }
}

// MARK: - Receive Buffer

/// Reorders incoming stream data and delivers in order.
public final class ReceiveBuffer: @unchecked Sendable {
    /// Next expected offset (delivery cursor).
    private var nextOffset: UInt64 = 0

    /// Out-of-order data awaiting delivery.
    private var pending: [StreamBuffer] = []

    /// Maximum bytes the peer is allowed to send (flow control).
    private var maxOffset: UInt64

    /// Total bytes read by the application.
    public private(set) var totalRead: UInt64 = 0

    /// Whether the final size has been received (FIN or RESET_STREAM).
    private var finalSize: UInt64?

    public init(maxOffset: UInt64 = 65536) {
        self.maxOffset = maxOffset
    }

    /// Insert data at the given offset.
    public func insert(offset: UInt64, data: Data) throws {
        guard data.count > 0 else { return }

        let endOffset = offset + UInt64(data.count)

        // Flow control check
        guard endOffset <= maxOffset else {
            throw QUICStreamError.flowControlExceeded("offset \(endOffset) > max \(maxOffset)")
        }

        // Skip data we've already delivered
        if endOffset <= nextOffset { return }

        if offset < nextOffset {
            // Partial overlap — trim the beginning
            let skip = Int(nextOffset - offset)
            let trimmed = data.dropFirst(skip)
            pending.append(StreamBuffer(offset: nextOffset, data: Data(trimmed)))
        } else {
            pending.append(StreamBuffer(offset: offset, data: data))
        }

        // Sort by offset for efficient delivery
        pending.sort { $0.baseOffset < $1.baseOffset }
    }

    /// Set the final size (from FIN flag or RESET_STREAM).
    public func setFinalSize(_ size: UInt64) {
        if let existing = finalSize {
            precondition(existing == size, "conflicting final sizes")
        }
        finalSize = size
    }

    /// Read available in-order data.
    public func read(maxBytes: Int = Int.max) -> Data? {
        var result = Data()

        while !pending.isEmpty && pending[0].baseOffset <= nextOffset {
            let buf = pending.removeFirst()

            if buf.baseOffset < nextOffset {
                // Partial overlap — skip already-delivered bytes
                let skip = Int(nextOffset - buf.baseOffset)
                guard skip < buf.data.count else { continue }
                let remaining = buf.data.dropFirst(skip)
                let toRead = min(remaining.count, maxBytes - result.count)
                result.append(remaining.prefix(toRead))
                nextOffset += UInt64(toRead)
            } else {
                let toRead = min(buf.data.count, maxBytes - result.count)
                result.append(buf.data.prefix(toRead))
                nextOffset += UInt64(toRead)

                if toRead < buf.data.count {
                    // Put back the unread portion
                    let remaining = Data(buf.data.dropFirst(toRead))
                    pending.insert(StreamBuffer(offset: nextOffset, data: remaining), at: 0)
                    break
                }
            }

            if result.count >= maxBytes { break }
        }

        totalRead = nextOffset
        return result.isEmpty ? nil : result
    }

    /// Whether all data has been received and read (after FIN).
    public var isComplete: Bool {
        guard let fs = finalSize else { return false }
        return nextOffset >= fs && pending.isEmpty
    }

    /// Update the flow control limit.
    public func updateMaxOffset(_ newMax: UInt64) {
        if newMax > maxOffset { maxOffset = newMax }
    }

    /// Current flow control window.
    public var window: UInt64 { maxOffset - nextOffset }
}

// MARK: - Send Buffer

/// Tracks outgoing stream data and retransmissions.
public final class SendBuffer: @unchecked Sendable {
    /// Data waiting to be sent.
    private var unsent: Data = Data()

    /// Current send offset.
    public private(set) var sendOffset: UInt64 = 0

    /// Maximum bytes we're allowed to send (peer flow control).
    private var maxOffset: UInt64

    /// Data that has been sent but not yet acknowledged.
    private var unacked: [(offset: UInt64, data: Data)] = []

    public init(maxOffset: UInt64 = 65536) {
        self.maxOffset = maxOffset
    }

    /// Enqueue data for sending.
    public func write(_ data: Data) throws {
        guard sendOffset + UInt64(unsent.count) + UInt64(data.count) <= maxOffset else {
            throw QUICStreamError.flowControlExceeded("write exceeds flow control limit")
        }
        unsent.append(data)
    }

    /// Get data to send (up to maxSize bytes).
    public func readToSend(maxSize: Int) -> (offset: UInt64, data: Data)? {
        guard !unsent.isEmpty else { return nil }

        let toSend = min(unsent.count, maxSize)
        let chunk = Data(unsent.prefix(toSend))
        let offset = sendOffset

        unsent.removeFirst(toSend)
        sendOffset += UInt64(toSend)

        unacked.append((offset: offset, data: chunk))
        return (offset, chunk)
    }

    /// Mark data as acknowledged (remove from retransmission buffer).
    public func acknowledge(offset: UInt64, length: Int) {
        unacked.removeAll { $0.offset == offset && $0.data.count == length }
    }

    /// Get data for retransmission (all unacked data).
    public func retransmitAll() -> [(offset: UInt64, data: Data)] {
        return unacked
    }

    /// Whether there's data to send.
    public var hasDataToSend: Bool { !unsent.isEmpty }

    /// Update peer's flow control limit.
    public func updateMaxOffset(_ newMax: UInt64) {
        if newMax > maxOffset { maxOffset = newMax }
    }

    /// Available send window.
    public var window: UInt64 {
        maxOffset - sendOffset - UInt64(unsent.count)
    }
}

// MARK: - QUIC Stream

/// A QUIC stream (bidirectional or unidirectional).
public final class QUICStream: @unchecked Sendable {
    /// Stream ID
    public let streamID: UInt64

    /// Send side (nil for remote unidirectional streams)
    public let sendBuffer: SendBuffer?

    /// Receive side (nil for local unidirectional streams)
    public let recvBuffer: ReceiveBuffer?

    /// Send state
    public var sendState: StreamSendState = .ready

    /// Receive state
    public var recvState: StreamRecvState = .recv

    /// Whether a FIN has been sent on this stream
    public var finSent: Bool = false

    /// Whether a FIN has been received on this stream
    public var finReceived: Bool = false

    public init(streamID: UInt64, isLocalSend: Bool, isRemoteSend: Bool) {
        self.streamID = streamID
        self.sendBuffer = isLocalSend ? SendBuffer() : nil
        self.recvBuffer = isRemoteSend ? ReceiveBuffer() : nil

        self.sendState = isLocalSend ? .send : .dataSent
        self.recvState = isRemoteSend ? .recv : .dataRecvd
    }

    /// Whether this stream is bidirectional.
    public var isBidirectional: Bool { StreamID.isBidirectional(streamID) }

    /// Whether this stream was initiated by us (assuming client perspective).
    public func isLocallyInitiated(isClient: Bool) -> Bool {
        let clientInit = StreamID.isClientInitiated(streamID)
        return isClient ? clientInit : !clientInit
    }
}

// MARK: - Stream Errors

/// QUIC stream errors.
public enum QUICStreamError: Error, Sendable {
    case flowControlExceeded(String)
    case streamLimitExceeded
    case invalidStreamID(UInt64)
    case streamClosed(UInt64)
}

// MARK: - Stream Manager

/// Manages all streams for a QUIC connection.
public final class StreamManager: @unchecked Sendable {
    /// Active streams indexed by ID.
    private var streams: [UInt64: QUICStream] = [:]

    /// Whether we're the client side.
    private let isClient: Bool

    /// Next stream ID for client-initiated bidi streams.
    private var nextClientBidiID: UInt64 = 0

    /// Next stream ID for client-initiated uni streams.
    private var nextClientUniID: UInt64 = 2

    /// Next stream ID for server-initiated bidi streams.
    private var nextServerBidiID: UInt64 = 1

    /// Next stream ID for server-initiated uni streams.
    private var nextServerUniID: UInt64 = 3

    /// Peer's max stream limit for bidi streams.
    private var peerMaxBidiStreams: UInt64 = 100

    /// Peer's max stream limit for uni streams.
    private var peerMaxUniStreams: UInt64 = 100

    public init(isClient: Bool) {
        self.isClient = isClient
    }

    /// Open a new bidirectional stream.
    public func openBidirectionalStream() -> QUICStream? {
        let id = isClient ? nextClientBidiID : nextServerBidiID
        let currentCount = streams.values.filter { $0.isBidirectional && $0.isLocallyInitiated(isClient: isClient) }.count
        guard UInt64(currentCount) < peerMaxBidiStreams else { return nil }

        let stream = QUICStream(streamID: id, isLocalSend: true, isRemoteSend: true)
        streams[id] = stream

        if isClient { nextClientBidiID += 4 } else { nextServerBidiID += 4 }
        return stream
    }

    /// Open a new unidirectional stream.
    public func openUnidirectionalStream() -> QUICStream? {
        let id = isClient ? nextClientUniID : nextServerUniID
        let currentCount = streams.values.filter { !StreamID.isBidirectional($0.streamID) && $0.isLocallyInitiated(isClient: isClient) }.count
        guard UInt64(currentCount) < peerMaxUniStreams else { return nil }

        let stream = QUICStream(streamID: id, isLocalSend: true, isRemoteSend: false)
        streams[id] = stream

        if isClient { nextClientUniID += 4 } else { nextServerUniID += 4 }
        return stream
    }

    /// Get or create a stream for an incoming stream ID.
    public func getOrCreateStream(for streamID: UInt64) -> QUICStream {
        if let existing = streams[streamID] { return existing }

        let isBidi = StreamID.isBidirectional(streamID)
        let isLocal = (isClient && StreamID.isClientInitiated(streamID)) ||
                      (!isClient && StreamID.isServerInitiated(streamID))

        let stream = QUICStream(
            streamID: streamID,
            isLocalSend: isBidi || isLocal,
            isRemoteSend: isBidi || !isLocal
        )
        streams[streamID] = stream
        return stream
    }

    /// Get an existing stream.
    public func stream(for streamID: UInt64) -> QUICStream? {
        return streams[streamID]
    }

    /// Remove a completed stream.
    public func removeStream(_ streamID: UInt64) {
        streams.removeValue(forKey: streamID)
    }

    /// Update peer's max stream limits.
    public func updateMaxStreams(bidi: UInt64? = nil, uni: UInt64? = nil) {
        if let b = bidi { peerMaxBidiStreams = b }
        if let u = uni { peerMaxUniStreams = u }
    }

    /// Get all active stream IDs.
    public var activeStreamIDs: [UInt64] {
        Array(streams.keys).sorted()
    }
}
