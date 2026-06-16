/// QUIC Packet Header (RFC 9000 Section 17)
///
/// Long headers (Initial, Handshake) and Short headers (1-RTT).

import Foundation

// MARK: - Packet Type

/// QUIC long header packet types
public enum LongPacketType: UInt8, Sendable {
    case initial = 0x00
    case zeroRTT = 0x01
    case handshake = 0x02
    case retry = 0x03
}

// MARK: - Packet Header

/// A parsed QUIC packet header
public enum PacketHeader: Sendable, Hashable {
    /// Long header (Initial, Handshake, 0-RTT)
    case long(LongHeader)

    /// Short header (1-RTT)
    case short(ShortHeader)

    /// The destination connection ID
    public var destinationConnectionID: ConnectionID {
        switch self {
        case .long(let h): return h.destinationConnectionID
        case .short(let h): return h.destinationConnectionID
        }
    }

    /// The source connection ID (long headers only)
    public var sourceConnectionID: ConnectionID? {
        switch self {
        case .long(let h): return h.sourceConnectionID
        case .short: return nil
        }
    }

    /// Whether this is a long header
    public var isLongHeader: Bool {
        if case .long = self { return true }
        return false
    }
}

// MARK: - Long Header

/// QUIC long header (RFC 9000 §17.2)
public struct LongHeader: Sendable, Hashable {
    public var packetType: LongPacketType
    public var version: QUICVersion
    public var destinationConnectionID: ConnectionID
    public var sourceConnectionID: ConnectionID
    public var packetNumber: UInt32
    public var payload: Data

    /// Token for Initial packets (empty for Handshake/0-RTT)
    public var token: Data

    public init(
        packetType: LongPacketType,
        version: QUICVersion = .v1,
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID,
        packetNumber: UInt32 = 0,
        payload: Data = Data(),
        token: Data = Data()
    ) {
        self.packetType = packetType
        self.version = version
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.packetNumber = packetNumber
        self.payload = payload
        self.token = token
    }
}

// MARK: - Short Header

/// QUIC short header (1-RTT, RFC 9000 §17.3)
public struct ShortHeader: Sendable, Hashable {
    public var destinationConnectionID: ConnectionID
    public var packetNumber: UInt32
    public var spinBit: Bool
    public var keyPhase: Bool
    public var payload: Data

    public init(
        destinationConnectionID: ConnectionID,
        packetNumber: UInt32 = 0,
        spinBit: Bool = false,
        keyPhase: Bool = false,
        payload: Data = Data()
    ) {
        self.destinationConnectionID = destinationConnectionID
        self.packetNumber = packetNumber
        self.spinBit = spinBit
        self.keyPhase = keyPhase
        self.payload = payload
    }
}

// MARK: - Packet Number Encoding

/// Encodes a packet number with the minimum number of bytes needed
/// to distinguish it from previously acknowledged numbers.
public func encodePacketNumber(_ pn: UInt64, largestAcknowledged: UInt64?) -> (data: Data, length: Int) {
    let fullPN = pn
    if let largest = largestAcknowledged {
        let truncated = pn & 0xFFFF_FFFF
        let expected = largest &+ 1
        let numUnacked = fullPN - expected

        // Determine minimum bytes needed
        let pnRange = numUnacked * 2
        let pnLength: Int
        if pnRange <= 0xFF { pnLength = 1 }
        else if pnRange <= 0xFFFF { pnLength = 2 }
        else if pnRange <= 0xFF_FFFF { pnLength = 3 }
        else { pnLength = 4 }

        var data = Data(count: pnLength)
        for i in 0..<pnLength {
            data[i] = UInt8((truncated >> ((pnLength - 1 - i) * 8)) & 0xFF)
        }
        return (data, pnLength)
    } else {
        // No ACKs yet — use full 4 bytes
        var data = Data(count: 4)
        for i in 0..<4 {
            data[i] = UInt8((fullPN >> ((3 - i) * 8)) & 0xFF)
        }
        return (data, 4)
    }
}

/// Decodes a truncated packet number.
public func decodePacketNumber(truncated: UInt64, truncatedLength: Int, largestPN: UInt64) -> UInt64 {
    let expectedPN = largestPN &+ 1
    let pnWin = UInt64(1) << (truncatedLength * 8)
    let pnHalfWin = pnWin / 2

    var candidatePN = (expectedPN & ~(pnWin - 1)) | truncated
    if candidatePN + pnHalfWin <= expectedPN && candidatePN + pnWin <= (1 << 62) - 1 {
        candidatePN += pnWin
    } else if candidatePN > expectedPN + pnHalfWin && candidatePN >= pnWin {
        candidatePN -= pnWin
    }
    return candidatePN
}

// MARK: - Header Encoding/Decoding

public enum PacketCodec {
    /// Encodes a long header.
    public static func encodeLongHeader(_ header: LongHeader, dcidLength: Int = 8) -> Data {
        var data = Data()

        // First byte: 1 (long) | 1 (fixed) | type (2 bits) | reserved (2 bits) | pn length (2 bits)
        let pnLength = packetNumberLength(header.packetNumber)
        var firstByte: UInt8 = 0xC0  // long header + fixed bit
        firstByte |= (header.packetType.rawValue << 4)
        firstByte |= UInt8(pnLength - 1)
        data.append(firstByte)

        // Version (4 bytes)
        var version = header.version.rawValue.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &version) { Data($0) })

        // DCID
        data.append(UInt8(header.destinationConnectionID.length))
        data.append(header.destinationConnectionID.bytes)

        // SCID
        data.append(UInt8(header.sourceConnectionID.length))
        data.append(header.sourceConnectionID.bytes)

        // Token (Initial packets only)
        if header.packetType == .initial {
            Varint(UInt64(header.token.count)).encode(to: &data)
            data.append(header.token)
        }

        // Length = pn_length + payload_length (protected field, encoded as varint)
        let length = pnLength + header.payload.count
        Varint(UInt64(length)).encode(to: &data)

        // Packet number (1-4 bytes)
        let pn = UInt32(header.packetNumber & UInt32((1 << (pnLength * 8)) - 1))
        for i in stride(from: pnLength - 1, through: 0, by: -1) {
            data.append(UInt8((pn >> (i * 8)) & 0xFF))
        }

        // Payload
        data.append(header.payload)
        return data
    }

    /// Encodes a short header.
    public static func encodeShortHeader(_ header: ShortHeader, dcidLength: Int = 8) -> Data {
        var data = Data()

        // First byte: 0 (short) | 1 (fixed) | spin | reserved (2 bits) | key phase | pn length (2 bits)
        let pnLength = packetNumberLength(header.packetNumber)
        var firstByte: UInt8 = 0x40  // short header + fixed bit
        if header.spinBit { firstByte |= 0x20 }
        if header.keyPhase { firstByte |= 0x04 }
        firstByte |= UInt8(pnLength - 1)
        data.append(firstByte)

        // DCID (known length from connection context)
        data.append(header.destinationConnectionID.bytes)

        // Packet number
        let pn = UInt32(header.packetNumber & UInt32((1 << (pnLength * 8)) - 1))
        for i in stride(from: pnLength - 1, through: 0, by: -1) {
            data.append(UInt8((pn >> (i * 8)) & 0xFF))
        }

        // Payload
        data.append(header.payload)
        return data
    }

    /// Decodes a packet header from raw data.
    ///
    /// For long headers, returns the full header.
    /// For short headers, requires `dcidLength` to parse correctly.
    public static func decodeHeader(from data: Data, dcidLength: Int = 8) throws -> PacketHeader {
        guard let firstByte = data.first else {
            throw PacketCodecError.insufficientData
        }

        let isLong = (firstByte & 0x80) != 0
        if isLong {
            return try decodeLongHeader(from: data)
        } else {
            return try decodeShortHeader(from: data, dcidLength: dcidLength)
        }
    }

    /// Decodes a long header.
    public static func decodeLongHeader(from data: Data) throws -> PacketHeader {
        var reader = FrameReader(data)
        let firstByte = try reader.readByte()
        guard (firstByte & 0x80) != 0 else {
            throw PacketCodecError.invalidHeader("expected long header")
        }

        let typeBits = (firstByte >> 4) & 0x03
        guard let packetType = LongPacketType(rawValue: typeBits) else {
            throw PacketCodecError.invalidHeader("unknown long header type: \(typeBits)")
        }
        let pnLengthBits = Int(firstByte & 0x03) + 1

        // Version
        let versionBytes = try reader.readBytes(4)
        let version = versionBytes.withUnsafeBytes { buf -> UInt32 in
            buf.load(as: UInt32.self).bigEndian
        }

        // DCID
        let dcidLen = Int(try reader.readByte())
        let dcid = ConnectionID(try reader.readBytes(dcidLen))

        // SCID
        let scidLen = Int(try reader.readByte())
        let scid = ConnectionID(try reader.readBytes(scidLen))

        // Token (Initial only)
        var token = Data()
        if packetType == .initial {
            let tokenLen = Int(try reader.readVarint().value)
            if tokenLen > 0 {
                token = try reader.readBytes(tokenLen)
            }
        }

        // Length (covers pn + payload)
        let length = Int(try reader.readVarint().value)

        // Packet number
        var pn: UInt32 = 0
        for _ in 0..<pnLengthBits {
            pn = (pn << 8) | UInt32(try reader.readByte())
        }

        // Payload (remaining bytes up to `length - pnLengthBits`)
        let payloadLen = length - pnLengthBits
        let payload = payloadLen > 0 ? try reader.readBytes(payloadLen) : Data()

        return .long(LongHeader(
            packetType: packetType,
            version: QUICVersion(rawValue: version),
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            packetNumber: pn,
            payload: payload,
            token: token
        ))
    }

    /// Decodes a short header (1-RTT).
    public static func decodeShortHeader(from data: Data, dcidLength: Int) throws -> PacketHeader {
        var reader = FrameReader(data)
        let firstByte = try reader.readByte()
        guard (firstByte & 0x80) == 0 else {
            throw PacketCodecError.invalidHeader("expected short header")
        }

        let spinBit = (firstByte & 0x20) != 0
        let keyPhase = (firstByte & 0x04) != 0
        let pnLength = Int(firstByte & 0x03) + 1

        // DCID (known length)
        let dcid = ConnectionID(try reader.readBytes(dcidLength))

        // Packet number
        var pn: UInt32 = 0
        for _ in 0..<pnLength {
            pn = (pn << 8) | UInt32(try reader.readByte())
        }

        // Payload is the rest
        let payload = try reader.readBytes(reader.remaining)

        return .short(ShortHeader(
            destinationConnectionID: dcid,
            packetNumber: pn,
            spinBit: spinBit,
            keyPhase: keyPhase,
            payload: payload
        ))
    }

    /// Splits coalesced QUIC packets from a single UDP datagram.
    public static func splitCoalescedPackets(from data: Data, dcidLength: Int = 8) throws -> [Data] {
        var packets: [Data] = []
        var offset = 0

        while offset < data.count {
            let firstByte = data[data.startIndex.advanced(by: offset)]
            let isLong = (firstByte & 0x80) != 0

            if isLong {
                // Parse length field to determine packet boundary
                var tempReader = FrameReader(data, offset: offset)
                _ = try tempReader.readByte() // first byte
                _ = try tempReader.readBytes(4) // version
                let dcidLen = Int(try tempReader.readByte())
                _ = try tempReader.readBytes(dcidLen) // dcid
                let scidLen = Int(try tempReader.readByte())
                _ = try tempReader.readBytes(scidLen) // scid

                let packetType = (firstByte >> 4) & 0x03
                if packetType == LongPacketType.initial.rawValue {
                    let tokenLen = Int(try tempReader.readVarint().value)
                    if tokenLen > 0 {
                        _ = try tempReader.readBytes(tokenLen)
                    }
                }

                let length = Int(try tempReader.readVarint().value)
                let packetSize = tempReader.offset - offset + length
                let end = min(offset + packetSize, data.count)
                packets.append(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: end)])
                offset = end
            } else {
                // Short header — rest of datagram is this packet
                packets.append(data[data.startIndex.advanced(by: offset)...])
                break
            }
        }
        return packets
    }

    private static func packetNumberLength(_ pn: UInt32) -> Int {
        if pn == 0 { return 1 }
        if pn <= 0xFF { return 1 }
        if pn <= 0xFFFF { return 2 }
        if pn <= 0xFF_FFFF { return 3 }
        return 4
    }
}

public enum PacketCodecError: Error, Sendable {
    case insufficientData
    case invalidHeader(String)
    case unknownVersion(UInt32)
}
