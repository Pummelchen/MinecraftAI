import Foundation
import Testing
@testable import PummelchenQuicCore

@Test func varintRoundTrip() throws {
    let values: [UInt64] = [0, 1, 63, 64, 16383, 16384, 1_073_741_823, 1_073_741_824, (1 << 62) - 1]
    for v in values {
        let encoded = Varint(v).encode()
        let (decoded, consumed) = try Varint.decode(from: encoded)
        #expect(decoded.value == v, "Varint round-trip failed for \(v)")
        #expect(consumed == encoded.count, "Consumed bytes mismatch for \(v)")
    }
}

@Test func varintInsufficientData() throws {
    // 2-byte varint but only 1 byte available
    let data = Data([0x40])
    #expect(throws: Varint.DecodeError.insufficientData) {
        _ = try Varint.decode(from: data)
    }
}

@Test func connectionIDRandom() {
    let cid = ConnectionID.random(length: 8)
    #expect(cid.length == 8)
    #expect(!cid.isEmpty)
}

@Test func socketAddressParse() {
    let addr = SocketAddress(string: "192.168.1.1:8080")
    #expect(addr?.ipAddress == "192.168.1.1")
    #expect(addr?.port == 8080)

    let addr6 = SocketAddress(string: "[::1]:443")
    #expect(addr6?.ipAddress == "::1")
    #expect(addr6?.port == 443)
}

@Test func protocolConstants() {
    #expect(ProtocolLimits.minimumMaximumDatagramSize == 1200)
    #expect(ProtocolLimits.maxConnectionIDLength == 20)
    #expect(StreamIDType.isClientBidi(0))
    #expect(StreamIDType.isServerBidi(1))
    #expect(StreamIDType.isClientUni(2))
    #expect(StreamIDType.isServerUni(3))
}

// MARK: - Frame Codec Tests

@Test func frameRoundTripCrypto() throws {
    let frame = Frame.crypto(CryptoFrame(offset: 42, data: Data([0x01, 0x02, 0x03])))
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func frameRoundTripStream() throws {
    let frame = Frame.stream(StreamFrame(streamID: 4, offset: 100, data: Data("hello".utf8), fin: true, hasLength: true))
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func frameRoundTripAck() throws {
    let frame = Frame.ack(AckFrame(largestAcknowledged: 10, ackDelay: 5, ackRanges: [AckRange(gap: 0, rangeLength: 3)]))
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func frameRoundTripConnectionClose() throws {
    let frame = Frame.connectionClose(ConnectionCloseFrame(errorCode: 0x0a, frameType: 0x06, reasonPhrase: "test error", isApplicationError: false))
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func frameRoundTripResetStreamAt() throws {
    let frame = Frame.resetStreamAt(ResetStreamAtFrame(
        streamID: 8, applicationProtocolErrorCode: 42, finalSize: 1024, reliableSize: 512
    ))
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func frameRoundTripDatagram() throws {
    let frame = Frame.datagram(DatagramFrame(data: Data([0xAA, 0xBB]), hasLength: true))
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func frameRoundTripMaxData() throws {
    let frame = Frame.maxData(1_000_000)
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == frame)
}

@Test func framePadding() throws {
    let frame = Frame.padding(count: 5)
    let encoded = FrameCodec.encode(frame)
    #expect(encoded.count == 5)
    #expect(encoded.allSatisfy { $0 == 0 })
}

@Test func framePing() throws {
    let frame = Frame.ping
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == .ping)
}

@Test func frameHandshakeDone() throws {
    let frame = Frame.handshakeDone
    let encoded = FrameCodec.encode(frame)
    let decoded = try FrameCodec.decodeFrames(from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0] == .handshakeDone)
}

@Test func multipleFrames() throws {
    var data = Data()
    FrameCodec.encode(.ping, to: &data)
    FrameCodec.encode(.maxData(42), to: &data)
    FrameCodec.encode(.handshakeDone, to: &data)
    let decoded = try FrameCodec.decodeFrames(from: data)
    #expect(decoded.count == 3)
    #expect(decoded[0] == .ping)
    #expect(decoded[1] == .maxData(42))
    #expect(decoded[2] == .handshakeDone)
}

// MARK: - Transport Parameters Tests

@Test func transportParametersRoundTrip() throws {
    var params = TransportParameters()
    params.maxIdleTimeout = 30_000
    params.initialMaxData = 10_000_000
    params.initialMaxStreamsBidi = 512
    params.initialMaxStreamsUni = 512
    params.maxDatagramFrameSize = 65535
    params.resetStreamAtSupport = true
    params.initialSourceConnectionID = ConnectionID.random(length: 8)

    let encoded = params.encode()
    let decoded = try TransportParameters.decode(from: encoded)

    #expect(decoded.maxIdleTimeout == params.maxIdleTimeout)
    #expect(decoded.initialMaxData == params.initialMaxData)
    #expect(decoded.initialMaxStreamsBidi == params.initialMaxStreamsBidi)
    #expect(decoded.initialMaxStreamsUni == params.initialMaxStreamsUni)
    #expect(decoded.maxDatagramFrameSize == params.maxDatagramFrameSize)
    #expect(decoded.resetStreamAtSupport == true)
    #expect(decoded.initialSourceConnectionID == params.initialSourceConnectionID)
}

@Test func transportParametersMaxDatagram() throws {
    var params = TransportParameters()
    params.maxDatagramFrameSize = 65535

    let encoded = params.encode()
    let decoded = try TransportParameters.decode(from: encoded)
    #expect(decoded.maxDatagramFrameSize == 65535)
}

// MARK: - Packet Header Tests

@Test func longHeaderRoundTrip() throws {
    let header = LongHeader(
        packetType: .initial,
        version: .v1,
        destinationConnectionID: ConnectionID.random(length: 8),
        sourceConnectionID: ConnectionID.random(length: 8),
        packetNumber: 0,
        payload: Data(repeating: 0x42, count: 10),
        token: Data()
    )

    let encoded = PacketCodec.encodeLongHeader(header)
    let decoded = try PacketCodec.decodeLongHeader(from: encoded)

    if case .long(let h) = decoded {
        #expect(h.packetType == .initial)
        #expect(h.version == .v1)
        #expect(h.destinationConnectionID == header.destinationConnectionID)
        #expect(h.sourceConnectionID == header.sourceConnectionID)
        #expect(h.payload.count == 10)
    } else {
        Issue.record("Expected long header")
    }
}

@Test func shortHeaderRoundTrip() throws {
    let dcid = ConnectionID.random(length: 8)
    let header = ShortHeader(
        destinationConnectionID: dcid,
        packetNumber: 1,
        spinBit: false,
        keyPhase: false,
        payload: Data(repeating: 0xAA, count: 20)
    )

    let encoded = PacketCodec.encodeShortHeader(header, dcidLength: 8)
    let decoded = try PacketCodec.decodeShortHeader(from: encoded, dcidLength: 8)

    if case .short(let h) = decoded {
        #expect(h.destinationConnectionID == dcid)
        #expect(h.payload.count == 20)
    } else {
        Issue.record("Expected short header")
    }
}

@Test func packetNumberEncodeDecode() {
    let (_, length) = encodePacketNumber(0, largestAcknowledged: nil)
    #expect(length == 4)
    let decoded = decodePacketNumber(truncated: 0, truncatedLength: length, largestPN: 0)
    #expect(decoded == 0)

    let (data2, length2) = encodePacketNumber(42, largestAcknowledged: 41)
    let decoded2 = decodePacketNumber(truncated: UInt64(data2[0]), truncatedLength: length2, largestPN: 41)
    #expect(decoded2 == 42)
}

// MARK: - Error Tests

@Test func quicErrorCodes() {
    #expect(QUICErrorCode.noError.rawValue == 0x00)
    #expect(QUICErrorCode.protocolViolation.rawValue == 0x0a)
    #expect(QUICErrorCode.tlsAlert(44) == 0x012c) // certificate_required
}
