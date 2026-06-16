/// QUIC Frame Types (RFC 9000 Section 12.4)
///
/// All frame structs and the Frame enum, including RESET_STREAM_AT (0x24)
/// from draft-ietf-quic-reliable-stream-reset-07.

import Foundation

// MARK: - Frame Type Identifiers

@frozen
public enum FrameType: UInt64, Sendable {
    case padding = 0x00
    case ping = 0x01
    case ack = 0x02
    case ackECN = 0x03
    case resetStream = 0x04
    case stopSending = 0x05
    case crypto = 0x06
    case newToken = 0x07
    case stream = 0x08            // 0x08–0x0f with flags
    case maxData = 0x10
    case maxStreamData = 0x11
    case maxStreamsBidi = 0x12
    case maxStreamsUni = 0x13
    case dataBlocked = 0x14
    case streamDataBlocked = 0x15
    case streamsBlockedBidi = 0x16
    case streamsBlockedUni = 0x17
    case newConnectionID = 0x18
    case retireConnectionID = 0x19
    case pathChallenge = 0x1a
    case pathResponse = 0x1b
    case connectionClose = 0x1c
    case connectionCloseApp = 0x1d
    case handshakeDone = 0x1e
    case resetStreamAt = 0x24     // draft-ietf-quic-reliable-stream-reset-07
    case datagram = 0x30
    case datagramWithLength = 0x31

    @inlinable public var isAckEliciting: Bool {
        switch self {
        case .padding, .ack, .ackECN, .connectionClose, .connectionCloseApp:
            return false
        default:
            return true
        }
    }
}

// MARK: - Sub-frame Structures

/// ACK range
public struct AckRange: Sendable, Hashable {
    public let gap: UInt64
    public let rangeLength: UInt64
    public init(gap: UInt64, rangeLength: UInt64) {
        self.gap = gap
        self.rangeLength = rangeLength
    }
}

/// ECN counts for ACK_ECN frames
public struct ECNCounts: Sendable, Hashable {
    public let ect0Count: UInt64
    public let ect1Count: UInt64
    public let ecnCECount: UInt64
    public init(ect0Count: UInt64, ect1Count: UInt64, ecnCECount: UInt64) {
        self.ect0Count = ect0Count
        self.ect1Count = ect1Count
        self.ecnCECount = ecnCECount
    }
}

/// ACK frame (RFC 9000 §19.3)
public struct AckFrame: Sendable, Hashable {
    public let largestAcknowledged: UInt64
    public let ackDelay: UInt64
    public let ackRanges: [AckRange]
    public let ecnCounts: ECNCounts?
    public init(largestAcknowledged: UInt64, ackDelay: UInt64, ackRanges: [AckRange], ecnCounts: ECNCounts? = nil) {
        self.largestAcknowledged = largestAcknowledged
        self.ackDelay = ackDelay
        self.ackRanges = ackRanges
        self.ecnCounts = ecnCounts
    }
}

/// RESET_STREAM frame (RFC 9000 §19.4)
public struct ResetStreamFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let applicationProtocolErrorCode: UInt64
    public let finalSize: UInt64
    public init(streamID: UInt64, applicationProtocolErrorCode: UInt64, finalSize: UInt64) {
        self.streamID = streamID
        self.applicationProtocolErrorCode = applicationProtocolErrorCode
        self.finalSize = finalSize
    }
}

/// STOP_SENDING frame (RFC 9000 §19.5)
public struct StopSendingFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let applicationProtocolErrorCode: UInt64
    public init(streamID: UInt64, applicationProtocolErrorCode: UInt64) {
        self.streamID = streamID
        self.applicationProtocolErrorCode = applicationProtocolErrorCode
    }
}

/// CRYPTO frame (RFC 9000 §19.6)
public struct CryptoFrame: Sendable, Hashable {
    public let offset: UInt64
    public let data: Data
    public init(offset: UInt64, data: Data) {
        self.offset = offset
        self.data = data
    }
}

/// STREAM frame (RFC 9000 §19.8, type 0x08–0x0f)
public struct StreamFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let offset: UInt64
    public let data: Data
    public let fin: Bool
    public let hasLength: Bool
    public init(streamID: UInt64, offset: UInt64 = 0, data: Data, fin: Bool = false, hasLength: Bool = true) {
        self.streamID = streamID
        self.offset = offset
        self.data = data
        self.fin = fin
        self.hasLength = hasLength
    }

    /// The frame type byte (0x08 with flags)
    public var typeByte: UInt8 {
        var t: UInt8 = 0x08
        if offset != 0 { t |= 0x04 }  // OFF bit
        if hasLength { t |= 0x02 }     // LEN bit
        if fin { t |= 0x01 }           // FIN bit
        return t
    }
}

/// MAX_STREAM_DATA frame (RFC 9000 §19.10)
public struct MaxStreamDataFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let maximumStreamData: UInt64
    public init(streamID: UInt64, maximumStreamData: UInt64) {
        self.streamID = streamID
        self.maximumStreamData = maximumStreamData
    }
}

/// MAX_STREAMS frame (RFC 9000 §19.11)
public struct MaxStreamsFrame: Sendable, Hashable {
    public let maximumStreams: UInt64
    public let isBidirectional: Bool
    public init(maximumStreams: UInt64, isBidirectional: Bool) {
        self.maximumStreams = maximumStreams
        self.isBidirectional = isBidirectional
    }
}

/// STREAM_DATA_BLOCKED frame (RFC 9000 §19.13)
public struct StreamDataBlockedFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let maximumStreamData: UInt64
    public init(streamID: UInt64, maximumStreamData: UInt64) {
        self.streamID = streamID
        self.maximumStreamData = maximumStreamData
    }
}

/// STREAMS_BLOCKED frame (RFC 9000 §19.14)
public struct StreamsBlockedFrame: Sendable, Hashable {
    public let maximumStreams: UInt64
    public let isBidirectional: Bool
    public init(maximumStreams: UInt64, isBidirectional: Bool) {
        self.maximumStreams = maximumStreams
        self.isBidirectional = isBidirectional
    }
}

/// NEW_CONNECTION_ID frame (RFC 9000 §19.15)
public struct NewConnectionIDFrame: Sendable, Hashable {
    public let sequenceNumber: UInt64
    public let retirePriorTo: UInt64
    public let connectionID: ConnectionID
    public let statelessResetToken: Data  // 16 bytes
    public init(sequenceNumber: UInt64, retirePriorTo: UInt64, connectionID: ConnectionID, statelessResetToken: Data) {
        self.sequenceNumber = sequenceNumber
        self.retirePriorTo = retirePriorTo
        self.connectionID = connectionID
        self.statelessResetToken = statelessResetToken
    }
}

/// CONNECTION_CLOSE frame (RFC 9000 §19.19)
public struct ConnectionCloseFrame: Sendable, Hashable {
    public let errorCode: UInt64
    public let frameType: UInt64?  // Only for transport-level close (0x1c)
    public let reasonPhrase: String
    public let isApplicationError: Bool
    public init(errorCode: UInt64, frameType: UInt64? = nil, reasonPhrase: String = "", isApplicationError: Bool = false) {
        self.errorCode = errorCode
        self.frameType = frameType
        self.reasonPhrase = reasonPhrase
        self.isApplicationError = isApplicationError
    }
}

/// DATAGRAM frame (RFC 9221)
public struct DatagramFrame: Sendable, Hashable {
    public let data: Data
    public let hasLength: Bool
    public init(data: Data, hasLength: Bool = true) {
        self.data = data
        self.hasLength = hasLength
    }
}

/// RESET_STREAM_AT frame (draft-ietf-quic-reliable-stream-reset-07, type 0x24)
///
/// Extends RESET_STREAM with a reliable size: data up to `reliableSize`
/// is delivered before the reset is processed.
public struct ResetStreamAtFrame: Sendable, Hashable {
    public let streamID: UInt64
    public let applicationProtocolErrorCode: UInt64
    public let finalSize: UInt64
    public let reliableSize: UInt64
    public init(streamID: UInt64, applicationProtocolErrorCode: UInt64, finalSize: UInt64, reliableSize: UInt64) {
        self.streamID = streamID
        self.applicationProtocolErrorCode = applicationProtocolErrorCode
        self.finalSize = finalSize
        self.reliableSize = reliableSize
    }
}

// MARK: - Frame Enum

/// A QUIC frame
public enum Frame: Sendable, Hashable {
    case padding(count: Int)
    case ping
    case ack(AckFrame)
    case resetStream(ResetStreamFrame)
    case stopSending(StopSendingFrame)
    case crypto(CryptoFrame)
    case newToken(Data)
    case stream(StreamFrame)
    case maxData(UInt64)
    case maxStreamData(MaxStreamDataFrame)
    case maxStreams(MaxStreamsFrame)
    case dataBlocked(UInt64)
    case streamDataBlocked(StreamDataBlockedFrame)
    case streamsBlocked(StreamsBlockedFrame)
    case newConnectionID(NewConnectionIDFrame)
    case retireConnectionID(UInt64)
    case pathChallenge(Data)
    case pathResponse(Data)
    case connectionClose(ConnectionCloseFrame)
    case handshakeDone
    case resetStreamAt(ResetStreamAtFrame)
    case datagram(DatagramFrame)

    /// The frame type identifier
    @inlinable
    public var frameType: FrameType {
        switch self {
        case .padding: return .padding
        case .ping: return .ping
        case .ack(let f): return f.ecnCounts != nil ? .ackECN : .ack
        case .resetStream: return .resetStream
        case .stopSending: return .stopSending
        case .crypto: return .crypto
        case .newToken: return .newToken
        case .stream: return .stream
        case .maxData: return .maxData
        case .maxStreamData: return .maxStreamData
        case .maxStreams(let f): return f.isBidirectional ? .maxStreamsBidi : .maxStreamsUni
        case .dataBlocked: return .dataBlocked
        case .streamDataBlocked: return .streamDataBlocked
        case .streamsBlocked(let f): return f.isBidirectional ? .streamsBlockedBidi : .streamsBlockedUni
        case .newConnectionID: return .newConnectionID
        case .retireConnectionID: return .retireConnectionID
        case .pathChallenge: return .pathChallenge
        case .pathResponse: return .pathResponse
        case .connectionClose(let f): return f.isApplicationError ? .connectionCloseApp : .connectionClose
        case .handshakeDone: return .handshakeDone
        case .resetStreamAt: return .resetStreamAt
        case .datagram(let f): return f.hasLength ? .datagramWithLength : .datagram
        }
    }

    @inlinable
    public var isAckEliciting: Bool {
        frameType.isAckEliciting
    }
}
