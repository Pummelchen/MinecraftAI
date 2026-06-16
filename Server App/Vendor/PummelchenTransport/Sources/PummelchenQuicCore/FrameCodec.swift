/// QUIC Frame Codec (RFC 9000 Section 12.4)
///
/// Encodes and decodes all QUIC frame types, including RESET_STREAM_AT (0x24).

import Foundation

/// A simple buffer reader for frame decoding.
public struct FrameReader {
    public var data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }
    public var isEmpty: Bool { offset >= data.count }

    /// Reads `count` bytes and advances the offset.
    public mutating func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw FrameCodecError.insufficientData
        }
        let slice = data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: offset + count)]
        offset += count
        return Data(slice)
    }

    /// Reads a single byte.
    public mutating func readByte() throws -> UInt8 {
        guard offset < data.count else {
            throw FrameCodecError.insufficientData
        }
        let byte = data[data.startIndex.advanced(by: offset)]
        offset += 1
        return byte
    }

    /// Reads a varint.
    public mutating func readVarint() throws -> Varint {
        let slice = data[data.startIndex.advanced(by:offset)...]
        let (value, consumed) = try Varint.decode(from: Data(slice))
        offset += consumed
        return value
    }

    /// Peek at the next byte without advancing.
    public func peekByte() throws -> UInt8 {
        guard offset < data.count else {
            throw FrameCodecError.insufficientData
        }
        return data[data.startIndex.advanced(by: offset)]
    }
}

// MARK: - Frame Codec Errors

public enum FrameCodecError: Error, Sendable {
    case insufficientData
    case unknownFrameType(UInt64)
    case invalidFrame(String)
}

// MARK: - Frame Codec

public enum FrameCodec {

    // MARK: - Decode

    /// Decodes all frames from a packet payload.
    public static func decodeFrames(from data: Data) throws -> [Frame] {
        var reader = FrameReader(data)
        var frames: [Frame] = []
        while !reader.isEmpty {
            let frame = try decodeFrame(&reader)
            frames.append(frame)
        }
        return frames
    }

    /// Decodes a single frame from the reader.
    public static func decodeFrame(_ reader: inout FrameReader) throws -> Frame {
        let firstByte = try reader.peekByte()

        // STREAM frames use 0x08–0x0f (3 flag bits)
        if firstByte >= 0x08 && firstByte <= 0x0f {
            return try decodeStreamFrame(&reader)
        }

        let typeValue = try reader.readVarint().value
        guard let type = FrameType(rawValue: typeValue) else {
            // Skip unknown frame types (try to read length-prefixed)
            throw FrameCodecError.unknownFrameType(typeValue)
        }

        switch type {
        case .padding:
            return try decodePadding(&reader)
        case .ping:
            return .ping
        case .ack, .ackECN:
            return try decodeAck(&reader, hasECN: type == .ackECN)
        case .resetStream:
            return try decodeResetStream(&reader)
        case .stopSending:
            return try decodeStopSending(&reader)
        case .crypto:
            return try decodeCrypto(&reader)
        case .newToken:
            return try decodeNewToken(&reader)
        case .maxData:
            let limit = try reader.readVarint().value
            return .maxData(limit)
        case .maxStreamData:
            let streamID = try reader.readVarint().value
            let limit = try reader.readVarint().value
            return .maxStreamData(MaxStreamDataFrame(streamID: streamID, maximumStreamData: limit))
        case .maxStreamsBidi:
            let limit = try reader.readVarint().value
            return .maxStreams(MaxStreamsFrame(maximumStreams: limit, isBidirectional: true))
        case .maxStreamsUni:
            let limit = try reader.readVarint().value
            return .maxStreams(MaxStreamsFrame(maximumStreams: limit, isBidirectional: false))
        case .dataBlocked:
            let limit = try reader.readVarint().value
            return .dataBlocked(limit)
        case .streamDataBlocked:
            let streamID = try reader.readVarint().value
            let limit = try reader.readVarint().value
            return .streamDataBlocked(StreamDataBlockedFrame(streamID: streamID, maximumStreamData: limit))
        case .streamsBlockedBidi:
            let limit = try reader.readVarint().value
            return .streamsBlocked(StreamsBlockedFrame(maximumStreams: limit, isBidirectional: true))
        case .streamsBlockedUni:
            let limit = try reader.readVarint().value
            return .streamsBlocked(StreamsBlockedFrame(maximumStreams: limit, isBidirectional: false))
        case .newConnectionID:
            return try decodeNewConnectionID(&reader)
        case .retireConnectionID:
            let seq = try reader.readVarint().value
            return .retireConnectionID(seq)
        case .pathChallenge:
            let data = try reader.readBytes(8)
            return .pathChallenge(data)
        case .pathResponse:
            let data = try reader.readBytes(8)
            return .pathResponse(data)
        case .connectionClose, .connectionCloseApp:
            return try decodeConnectionClose(&reader, isApp: type == .connectionCloseApp)
        case .handshakeDone:
            return .handshakeDone
        case .resetStreamAt:
            return try decodeResetStreamAt(&reader)
        case .datagram:
            let payload = try reader.readBytes(reader.remaining)
            return .datagram(DatagramFrame(data: payload, hasLength: false))
        case .datagramWithLength:
            let length = Int(try reader.readVarint().value)
            let payload = try reader.readBytes(length)
            return .datagram(DatagramFrame(data: payload, hasLength: true))
        case .stream:
            // Handled above by type-byte check
            return try decodeStreamFrame(&reader)
        }
    }

    // MARK: - Specific Decoders

    private static func decodePadding(_ reader: inout FrameReader) throws -> Frame {
        // Already consumed the type byte; count remaining 0x00 bytes
        var count = 1
        while !reader.isEmpty, try reader.peekByte() == 0x00 {
            _ = try reader.readByte()
            count += 1
        }
        return .padding(count: count)
    }

    private static func decodeAck(_ reader: inout FrameReader, hasECN: Bool) throws -> Frame {
        let largestAck = try reader.readVarint().value
        let ackDelay = try reader.readVarint().value
        let ackRangeCount = try reader.readVarint().value
        let firstAckRange = try reader.readVarint().value

        var ranges: [AckRange] = [AckRange(gap: 0, rangeLength: firstAckRange)]
        for _ in 0..<ackRangeCount {
            let gap = try reader.readVarint().value
            let rangeLen = try reader.readVarint().value
            ranges.append(AckRange(gap: gap, rangeLength: rangeLen))
        }

        var ecnCounts: ECNCounts? = nil
        if hasECN {
            let ect0 = try reader.readVarint().value
            let ect1 = try reader.readVarint().value
            let ecnCE = try reader.readVarint().value
            ecnCounts = ECNCounts(ect0Count: ect0, ect1Count: ect1, ecnCECount: ecnCE)
        }

        return .ack(AckFrame(largestAcknowledged: largestAck, ackDelay: ackDelay, ackRanges: ranges, ecnCounts: ecnCounts))
    }

    private static func decodeResetStream(_ reader: inout FrameReader) throws -> Frame {
        let streamID = try reader.readVarint().value
        let errorCode = try reader.readVarint().value
        let finalSize = try reader.readVarint().value
        return .resetStream(ResetStreamFrame(streamID: streamID, applicationProtocolErrorCode: errorCode, finalSize: finalSize))
    }

    private static func decodeStopSending(_ reader: inout FrameReader) throws -> Frame {
        let streamID = try reader.readVarint().value
        let errorCode = try reader.readVarint().value
        return .stopSending(StopSendingFrame(streamID: streamID, applicationProtocolErrorCode: errorCode))
    }

    private static func decodeCrypto(_ reader: inout FrameReader) throws -> Frame {
        let offset = try reader.readVarint().value
        let length = Int(try reader.readVarint().value)
        let data = try reader.readBytes(length)
        return .crypto(CryptoFrame(offset: offset, data: data))
    }

    private static func decodeNewToken(_ reader: inout FrameReader) throws -> Frame {
        let length = Int(try reader.readVarint().value)
        let token = try reader.readBytes(length)
        return .newToken(token)
    }

    private static func decodeStreamFrame(_ reader: inout FrameReader) throws -> Frame {
        let typeByte = try reader.readByte()
        let hasOffset = (typeByte & 0x04) != 0
        let hasLength = (typeByte & 0x02) != 0
        let hasFin = (typeByte & 0x01) != 0

        let streamID = try reader.readVarint().value
        let offset = hasOffset ? try reader.readVarint().value : 0
        let data: Data
        if hasLength {
            let length = Int(try reader.readVarint().value)
            data = try reader.readBytes(length)
        } else {
            data = try reader.readBytes(reader.remaining)
        }
        return .stream(StreamFrame(streamID: streamID, offset: offset, data: data, fin: hasFin, hasLength: hasLength))
    }

    private static func decodeNewConnectionID(_ reader: inout FrameReader) throws -> Frame {
        let seqNum = try reader.readVarint().value
        let retirePriorTo = try reader.readVarint().value
        let cidLength = Int(try reader.readVarint().value)
        let cidBytes = try reader.readBytes(cidLength)
        let token = try reader.readBytes(16)
        return .newConnectionID(NewConnectionIDFrame(
            sequenceNumber: seqNum,
            retirePriorTo: retirePriorTo,
            connectionID: ConnectionID(cidBytes),
            statelessResetToken: token
        ))
    }

    private static func decodeConnectionClose(_ reader: inout FrameReader, isApp: Bool) throws -> Frame {
        let errorCode = try reader.readVarint().value
        let frameType: UInt64? = isApp ? nil : try reader.readVarint().value
        let reasonLen = Int(try reader.readVarint().value)
        let reasonData = try reader.readBytes(reasonLen)
        let reason = String(data: reasonData, encoding: .utf8) ?? ""
        return .connectionClose(ConnectionCloseFrame(
            errorCode: errorCode,
            frameType: frameType,
            reasonPhrase: reason,
            isApplicationError: isApp
        ))
    }

    private static func decodeResetStreamAt(_ reader: inout FrameReader) throws -> Frame {
        let streamID = try reader.readVarint().value
        let errorCode = try reader.readVarint().value
        let finalSize = try reader.readVarint().value
        let reliableSize = try reader.readVarint().value
        return .resetStreamAt(ResetStreamAtFrame(
            streamID: streamID,
            applicationProtocolErrorCode: errorCode,
            finalSize: finalSize,
            reliableSize: reliableSize
        ))
    }

    // MARK: - Encode

    /// Encodes a frame to Data.
    public static func encode(_ frame: Frame) -> Data {
        var data = Data()
        encode(frame, to: &data)
        return data
    }

    /// Encodes a frame, appending to the given Data.
    public static func encode(_ frame: Frame, to data: inout Data) {
        switch frame {
        case .padding(let count):
            data.append(Data(repeating: 0x00, count: count))

        case .ping:
            Varint(FrameType.ping.rawValue).encode(to: &data)

        case .ack(let f):
            Varint(f.ecnCounts != nil ? FrameType.ackECN.rawValue : FrameType.ack.rawValue).encode(to: &data)
            Varint(f.largestAcknowledged).encode(to: &data)
            Varint(f.ackDelay).encode(to: &data)
            Varint(UInt64(f.ackRanges.count - 1)).encode(to: &data) // ACK Range Count - 1
            if let first = f.ackRanges.first {
                Varint(first.rangeLength).encode(to: &data)
            }
            for range in f.ackRanges.dropFirst() {
                Varint(range.gap).encode(to: &data)
                Varint(range.rangeLength).encode(to: &data)
            }
            if let ecn = f.ecnCounts {
                Varint(ecn.ect0Count).encode(to: &data)
                Varint(ecn.ect1Count).encode(to: &data)
                Varint(ecn.ecnCECount).encode(to: &data)
            }

        case .resetStream(let f):
            Varint(FrameType.resetStream.rawValue).encode(to: &data)
            Varint(f.streamID).encode(to: &data)
            Varint(f.applicationProtocolErrorCode).encode(to: &data)
            Varint(f.finalSize).encode(to: &data)

        case .stopSending(let f):
            Varint(FrameType.stopSending.rawValue).encode(to: &data)
            Varint(f.streamID).encode(to: &data)
            Varint(f.applicationProtocolErrorCode).encode(to: &data)

        case .crypto(let f):
            Varint(FrameType.crypto.rawValue).encode(to: &data)
            Varint(f.offset).encode(to: &data)
            Varint(UInt64(f.data.count)).encode(to: &data)
            data.append(f.data)

        case .newToken(let token):
            Varint(FrameType.newToken.rawValue).encode(to: &data)
            Varint(UInt64(token.count)).encode(to: &data)
            data.append(token)

        case .stream(let f):
            data.append(f.typeByte)
            Varint(f.streamID).encode(to: &data)
            if f.offset != 0 { Varint(f.offset).encode(to: &data) }
            if f.hasLength { Varint(UInt64(f.data.count)).encode(to: &data) }
            data.append(f.data)

        case .maxData(let limit):
            Varint(FrameType.maxData.rawValue).encode(to: &data)
            Varint(limit).encode(to: &data)

        case .maxStreamData(let f):
            Varint(FrameType.maxStreamData.rawValue).encode(to: &data)
            Varint(f.streamID).encode(to: &data)
            Varint(f.maximumStreamData).encode(to: &data)

        case .maxStreams(let f):
            Varint(f.isBidirectional ? FrameType.maxStreamsBidi.rawValue : FrameType.maxStreamsUni.rawValue).encode(to: &data)
            Varint(f.maximumStreams).encode(to: &data)

        case .dataBlocked(let limit):
            Varint(FrameType.dataBlocked.rawValue).encode(to: &data)
            Varint(limit).encode(to: &data)

        case .streamDataBlocked(let f):
            Varint(FrameType.streamDataBlocked.rawValue).encode(to: &data)
            Varint(f.streamID).encode(to: &data)
            Varint(f.maximumStreamData).encode(to: &data)

        case .streamsBlocked(let f):
            Varint(f.isBidirectional ? FrameType.streamsBlockedBidi.rawValue : FrameType.streamsBlockedUni.rawValue).encode(to: &data)
            Varint(f.maximumStreams).encode(to: &data)

        case .newConnectionID(let f):
            Varint(FrameType.newConnectionID.rawValue).encode(to: &data)
            Varint(f.sequenceNumber).encode(to: &data)
            Varint(f.retirePriorTo).encode(to: &data)
            Varint(UInt64(f.connectionID.length)).encode(to: &data)
            data.append(f.connectionID.bytes)
            data.append(f.statelessResetToken)

        case .retireConnectionID(let seq):
            Varint(FrameType.retireConnectionID.rawValue).encode(to: &data)
            Varint(seq).encode(to: &data)

        case .pathChallenge(let payload):
            Varint(FrameType.pathChallenge.rawValue).encode(to: &data)
            data.append(payload)

        case .pathResponse(let payload):
            Varint(FrameType.pathResponse.rawValue).encode(to: &data)
            data.append(payload)

        case .connectionClose(let f):
            Varint(f.isApplicationError ? FrameType.connectionCloseApp.rawValue : FrameType.connectionClose.rawValue).encode(to: &data)
            Varint(f.errorCode).encode(to: &data)
            if !f.isApplicationError {
                Varint(f.frameType ?? 0).encode(to: &data)
            }
            let reasonBytes = Data(f.reasonPhrase.utf8)
            Varint(UInt64(reasonBytes.count)).encode(to: &data)
            data.append(reasonBytes)

        case .handshakeDone:
            Varint(FrameType.handshakeDone.rawValue).encode(to: &data)

        case .resetStreamAt(let f):
            Varint(FrameType.resetStreamAt.rawValue).encode(to: &data)
            Varint(f.streamID).encode(to: &data)
            Varint(f.applicationProtocolErrorCode).encode(to: &data)
            Varint(f.finalSize).encode(to: &data)
            Varint(f.reliableSize).encode(to: &data)

        case .datagram(let f):
            Varint(f.hasLength ? FrameType.datagramWithLength.rawValue : FrameType.datagram.rawValue).encode(to: &data)
            if f.hasLength {
                Varint(UInt64(f.data.count)).encode(to: &data)
            }
            data.append(f.data)
        }
    }
}
