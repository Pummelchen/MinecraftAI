import Testing
import Foundation
@testable import PummelchenHTTP3
@testable import PummelchenQuicCore

// MARK: - HTTP/3 Frame Tests

@Suite("HTTP/3 Frame Codec")
struct HTTP3FrameTests {

    @Test("Frame encode/decode round-trip")
    func frameRoundTrip() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let frame = HTTP3Frame(type: .data, payload: payload)
        let encoded = frame.encode()

        var offset = 0
        let decoded = HTTP3Frame.decode(from: encoded, offset: &offset)
        #expect(decoded != nil)
        #expect(decoded?.type == HTTP3FrameType.data.rawValue)
        #expect(decoded?.payload == payload)
        #expect(offset == encoded.count)
    }

    @Test("Frame encode varint type + varint length")
    func frameVarintEncoding() {
        // DATA frame (type=0x00) with 3-byte payload
        let frame = HTTP3Frame(type: 0x00, payload: Data([0xAA, 0xBB, 0xCC]))
        let encoded = frame.encode()
        // type=0x00 (1 byte varint), length=0x03 (1 byte varint), payload=3 bytes
        #expect(encoded.count == 5)
        #expect(encoded[0] == 0x00) // type
        #expect(encoded[1] == 0x03) // length
        #expect(encoded[2] == 0xAA)
        #expect(encoded[3] == 0xBB)
        #expect(encoded[4] == 0xCC)
    }

    @Test("Frame decode insufficient data returns nil")
    func frameDecodeInsufficientData() {
        var offset = 0
        let result = HTTP3Frame.decode(from: Data([0x00]), offset: &offset)
        #expect(result == nil)
    }

    @Test("Multiple frames decode sequentially")
    func multipleFramesDecode() {
        let frame1 = HTTP3Frame(type: .data, payload: Data([0x01]))
        let frame2 = HTTP3Frame(type: .headers, payload: Data([0x02, 0x03]))
        var combined = frame1.encode()
        combined.append(frame2.encode())

        var offset = 0
        let decoded1 = HTTP3Frame.decode(from: combined, offset: &offset)
        let decoded2 = HTTP3Frame.decode(from: combined, offset: &offset)

        #expect(decoded1?.type == HTTP3FrameType.data.rawValue)
        #expect(decoded1?.payload == Data([0x01]))
        #expect(decoded2?.type == HTTP3FrameType.headers.rawValue)
        #expect(decoded2?.payload == Data([0x02, 0x03]))
    }
}

// MARK: - SETTINGS Frame Tests

@Suite("HTTP/3 SETTINGS Frame")
struct HTTP3SettingsTests {

    @Test("SETTINGS encode/decode round-trip")
    func settingsRoundTrip() {
        let settings = HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .maxFieldSectionSize, value: 4096),
            HTTP3Setting(id: .enableConnectProtocol, value: 1),
            HTTP3Setting(id: .webTransportEnabled, value: 1),
        ])
        let encoded = settings.encodePayload()
        let decoded = HTTP3SettingsFrame.decodePayload(encoded)

        #expect(decoded.settings.count == 3)
        #expect(decoded.value(for: .maxFieldSectionSize) == 4096)
        #expect(decoded.value(for: .enableConnectProtocol) == 1)
        #expect(decoded.value(for: .webTransportEnabled) == 1)
    }

    @Test("SETTINGS with WebTransport draft-15 identifier")
    func settingsWebTransportID() {
        // SETTINGS_WT_ENABLED = 0x2c7cf000 (draft-15 §9.2)
        let setting = HTTP3Setting(id: .webTransportEnabled, value: 1)
        #expect(setting.id == 0x2c7cf000)
    }

    @Test("Empty SETTINGS encode/decode")
    func emptySettings() {
        let settings = HTTP3SettingsFrame()
        let encoded = settings.encodePayload()
        #expect(encoded.isEmpty)
        let decoded = HTTP3SettingsFrame.decodePayload(encoded)
        #expect(decoded.settings.isEmpty)
    }

    @Test("Missing setting returns nil")
    func missingSetting() {
        let settings = HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .maxFieldSectionSize, value: 100)
        ])
        #expect(settings.value(for: .webTransportEnabled) == nil)
    }
}

// MARK: - QPACK Tests

@Suite("QPACK Minimal Encoder/Decoder")
struct QPACKTests {

    @Test("QPACK encode/decode round-trip")
    func qpackRoundTrip() {
        let headers = [
            QPACK.HeaderField(name: ":method", value: "GET"),
            QPACK.HeaderField(name: ":path", value: "/"),
            QPACK.HeaderField(name: ":scheme", value: "https"),
        ]
        let encoded = QPACK.encodeHeaders(headers)
        let decoded = try! QPACK.decodeHeaders(encoded)

        #expect(decoded.count == 3)
        #expect(decoded[0].name == ":method")
        #expect(decoded[0].value == "GET")
        #expect(decoded[1].name == ":path")
        #expect(decoded[1].value == "/")
        #expect(decoded[2].name == ":scheme")
        #expect(decoded[2].value == "https")
    }

    @Test("QPACK handles long header values")
    func qpackLongValues() {
        let longValue = String(repeating: "x", count: 300)
        let headers = [QPACK.HeaderField(name: "x-custom", value: longValue)]
        let encoded = QPACK.encodeHeaders(headers)
        let decoded = try! QPACK.decodeHeaders(encoded)

        #expect(decoded.count == 1)
        #expect(decoded[0].name == "x-custom")
        #expect(decoded[0].value == longValue)
    }

    @Test("QPACK rejects indexed fields")
    func qpackRejectsIndexed() {
        // Byte with high bit set = indexed field
        var data = Data()
        data.append(contentsOf: Varint.encode(0))  // Required Insert Count
        data.append(0x00)                           // Delta Base
        data.append(0x80)                           // Indexed field (static table ref)
        #expect(throws: HTTP3Error.self) {
            _ = try QPACK.decodeHeaders(data)
        }
    }
}

// MARK: - HTTP/3 Connection Tests

@Suite("HTTP/3 Connection")
struct HTTP3ConnectionTests {

    @Test("Control stream starts with stream type + SETTINGS")
    func controlStreamData() {
        let conn = HTTP3Connection(localSettings: HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .webTransportEnabled, value: 1)
        ]))
        let data = conn.buildControlStreamData()

        // First byte: stream type 0x00 (control)
        #expect(data[0] == 0x00)

        // Rest should be a SETTINGS frame
        var offset = 1
        let frame = HTTP3Frame.decode(from: data, offset: &offset)
        #expect(frame != nil)
        #expect(frame?.type == HTTP3FrameType.settings.rawValue)
    }

    @Test("Process peer SETTINGS from control stream")
    func processPeerSettings() throws {
        let conn = HTTP3Connection(localSettings: HTTP3SettingsFrame())

        // Build peer's control stream data
        var peerData = Data()
        // Stream type will be consumed separately in real impl,
        // but processControlStreamData expects frame data
        let peerSettings = HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .maxFieldSectionSize, value: 8192)
        ])
        let settingsPayload = peerSettings.encodePayload()
        let settingsFrame = HTTP3Frame(type: .settings, payload: settingsPayload)
        peerData.append(settingsFrame.encode())

        try conn.processControlStreamData(peerData)
        #expect(conn.peerSettings != nil)
        #expect(conn.peerSettings?.value(for: .maxFieldSectionSize) == 8192)
        #expect(conn.isReady)
    }

    @Test("WebTransport enabled when both sides set it")
    func webTransportEnabled() throws {
        let conn = HTTP3Connection(localSettings: HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .webTransportEnabled, value: 1)
        ]))

        var peerData = Data()
        let peerSettings = HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .webTransportEnabled, value: 1)
        ])
        let settingsFrame = HTTP3Frame(type: .settings, payload: peerSettings.encodePayload())
        peerData.append(settingsFrame.encode())
        try conn.processControlStreamData(peerData)

        #expect(conn.isWebTransportEnabled)
    }

    @Test("WebTransport NOT enabled when peer doesn't set it")
    func webTransportNotEnabled() throws {
        let conn = HTTP3Connection(localSettings: HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .webTransportEnabled, value: 1)
        ]))

        var peerData = Data()
        let peerSettings = HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .maxFieldSectionSize, value: 4096)
        ])
        let settingsFrame = HTTP3Frame(type: .settings, payload: peerSettings.encodePayload())
        peerData.append(settingsFrame.encode())
        try conn.processControlStreamData(peerData)

        #expect(!conn.isWebTransportEnabled)
    }

    @Test("HEADERS frame encode/decode via connection")
    func headersFrameViaConnection() throws {
        let conn = HTTP3Connection(localSettings: HTTP3SettingsFrame())
        let headers = [
            QPACK.HeaderField(name: ":method", value: "CONNECT"),
            QPACK.HeaderField(name: ":protocol", value: "webtransport-h3"),
        ]
        let frameData = conn.buildHeadersFrame(headers: headers)

        var offset = 0
        let frame = HTTP3Frame.decode(from: frameData, offset: &offset)
        #expect(frame != nil)
        #expect(frame?.type == HTTP3FrameType.headers.rawValue)

        let decoded = try QPACK.decodeHeaders(frame!.payload)
        #expect(decoded.count == 2)
        #expect(decoded[0].name == ":method")
        #expect(decoded[0].value == "CONNECT")
        #expect(decoded[1].name == ":protocol")
        #expect(decoded[1].value == "webtransport-h3")
    }
}

// MARK: - WebTransport Capsule Tests

@Suite("WebTransport Capsules")
struct WTCapsuleTests {

    @Test("Capsule encode/decode round-trip")
    func capsuleRoundTrip() {
        let payload = Data([0x00, 0x00, 0x00, 0x00]) // error code 0
        let capsule = WTCapsule(type: WTCapsuleType.drainUni.rawValue, payload: payload)
        let encoded = capsule.encode()

        var offset = 0
        let decoded = WTCapsule.decode(from: encoded, offset: &offset)
        #expect(decoded != nil)
        #expect(decoded?.type == WTCapsuleType.drainUni.rawValue)
        #expect(decoded?.payload == payload)
    }

    @Test("Capsule decode insufficient data returns nil")
    func capsuleDecodeInsufficient() {
        var offset = 0
        let result = WTCapsule.decode(from: Data([0x00]), offset: &offset)
        #expect(result == nil)
    }
}

// MARK: - WebTransport Session Tests

@Suite("WebTransport Session")
struct WTSessionTests {

    @Test("Session starts active")
    func sessionActive() {
        let session = WebTransportSession(sessionID: 42)
        #expect(session.isActive)
        #expect(session.sessionID == 42)
    }

    @Test("Session close deactivates")
    func sessionClose() {
        let session = WebTransportSession(sessionID: 1)
        session.close(errorCode: 0, reason: "done")
        #expect(!session.isActive)
    }

    @Test("Incoming bidi stream yields to async stream")
    func incomingBidiStream() async {
        let session = WebTransportSession(sessionID: 1)
        let stream = session.handleIncomingBidiStream(streamID: 10)
        #expect(stream.isBidirectional)
        #expect(stream.streamID == 10)
        #expect(stream.sessionID == 1)

        // Should be able to receive from the async stream
        var iterator = session.incomingBidiStreams.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.streamID == 10)
    }

    @Test("Incoming uni stream yields to async stream")
    func incomingUniStream() async {
        let session = WebTransportSession(sessionID: 2)
        let stream = session.handleIncomingUniStream(streamID: 20)
        #expect(!stream.isBidirectional)
        #expect(stream.streamID == 20)

        var iterator = session.incomingUniStreams.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.streamID == 20)
    }
}

// MARK: - WebTransport Stream Header Tests

@Suite("WebTransport Stream Headers")
struct WTStreamHeaderTests {

    @Test("Bidi stream header: 0x41 + sessionID")
    func bidiStreamHeader() {
        let stream = WebTransportStream(streamID: 1, sessionID: 42, isBidirectional: true)
        let header = stream.buildStreamHeader()

        // First byte: 0x41 (bidi signal)
        #expect(header[0] == WebTransportH3Constants.bidiStreamSignal)
        // Remaining: sessionID as varint
        let sessionIDBytes = Varint.encode(42)
        #expect(Data(header[1...]) == sessionIDBytes)
    }

    @Test("Uni stream header: 0x54 varint + sessionID varint")
    func uniStreamHeader() {
        let stream = WebTransportStream(streamID: 1, sessionID: 7, isBidirectional: false)
        let header = stream.buildStreamHeader()

        // First bytes: 0x54 as varint (uni stream type)
        let typeBytes = Varint.encode(WebTransportH3Constants.uniStreamType)
        #expect(Data(header.prefix(typeBytes.count)) == typeBytes)

        // Remaining: sessionID as varint
        let sessionIDBytes = Varint.encode(7)
        #expect(Data(header[typeBytes.count...]) == sessionIDBytes)
    }

    @Test("Stream receive and read data")
    func streamReceiveRead() {
        let stream = WebTransportStream(streamID: 1, sessionID: 1, isBidirectional: true)
        stream.receiveData(Data([0x01, 0x02, 0x03]))
        stream.receiveData(Data([0x04, 0x05]))

        let data = stream.read(maxBytes: 3)
        #expect(data == Data([0x01, 0x02, 0x03]))
        let rest = stream.read()
        #expect(rest == Data([0x04, 0x05]))
    }
}

// MARK: - WebTransport Server Tests

@Suite("WebTransport Server")
struct WTServerTests {

    @Test("Accept valid WebTransport CONNECT")
    func acceptValidConnect() {
        let server = WebTransportServer()
        let headers = [
            QPACK.HeaderField(name: ":method", value: "CONNECT"),
            QPACK.HeaderField(name: ":protocol", value: "webtransport-h3"),
            QPACK.HeaderField(name: ":scheme", value: "https"),
            QPACK.HeaderField(name: ":path", value: "/"),
        ]
        let session = server.acceptSession(streamID: 4, headers: headers)
        #expect(session != nil)
        #expect(session?.sessionID == 4)
        #expect(server.session(for: 4) != nil)
    }

    @Test("Reject non-CONNECT request")
    func rejectNonConnect() {
        let server = WebTransportServer()
        let headers = [
            QPACK.HeaderField(name: ":method", value: "GET"),
            QPACK.HeaderField(name: ":path", value: "/"),
        ]
        let session = server.acceptSession(streamID: 4, headers: headers)
        #expect(session == nil)
    }

    @Test("Reject CONNECT without :protocol")
    func rejectMissingProtocol() {
        let server = WebTransportServer()
        let headers = [
            QPACK.HeaderField(name: ":method", value: "CONNECT"),
            QPACK.HeaderField(name: ":path", value: "/"),
        ]
        let session = server.acceptSession(streamID: 4, headers: headers)
        #expect(session == nil)
    }

    @Test("Remove session")
    func removeSession() {
        let server = WebTransportServer()
        let headers = [
            QPACK.HeaderField(name: ":method", value: "CONNECT"),
            QPACK.HeaderField(name: ":protocol", value: "webtransport-h3"),
        ]
        _ = server.acceptSession(streamID: 8, headers: headers)
        #expect(server.session(for: 8) != nil)
        server.removeSession(8)
        #expect(server.session(for: 8) == nil)
    }
}

// MARK: - WebTransport Client Tests

@Suite("WebTransport Client")
struct WTClientTests {

    @Test("Build CONNECT headers with correct draft-15 values")
    func buildConnectHeaders() {
        let client = WebTransportClient()
        let headers = client.buildConnectHeaders(authority: "example.com", path: "/wt")

        let method = headers.first(where: { $0.name == ":method" })?.value
        let proto = headers.first(where: { $0.name == ":protocol" })?.value
        let scheme = headers.first(where: { $0.name == ":scheme" })?.value
        let authority = headers.first(where: { $0.name == ":authority" })?.value
        let path = headers.first(where: { $0.name == ":path" })?.value
        let origin = headers.first(where: { $0.name == "origin" })?.value

        #expect(method == "CONNECT")
        #expect(proto == "webtransport-h3") // draft-15
        #expect(scheme == "https")
        #expect(authority == "example.com")
        #expect(path == "/wt")
        #expect(origin == "https://example.com")
    }
}

// MARK: - Constants Compliance Tests

@Suite("WebTransport draft-15 Constants")
struct WTConstantsTests {

    @Test("SETTINGS_WT_ENABLED = 0x2c7cf000")
    func settingsWTEnabled() {
        #expect(WebTransportH3Constants.settingsWTEnabled == 0x2c7cf000)
    }

    @Test("Bidi stream signal = 0x41")
    func bidiSignal() {
        #expect(WebTransportH3Constants.bidiStreamSignal == 0x41)
    }

    @Test("Uni stream type = 0x54")
    func uniStreamType() {
        #expect(WebTransportH3Constants.uniStreamType == 0x54)
    }

    @Test("Error code base = 0x52e4a40fa8db")
    func errorCodeBase() {
        #expect(WebTransportH3Constants.errorCodeBase == 0x52e4a40fa8db)
    }

    @Test("Error code mapping")
    func errorCodeMapping() {
        // App error 0 → base + 0
        #expect(WebTransportH3Constants.quicErrorCode(from: 0) == 0x52e4a40fa8db)
        // App error 1 → base + 1
        #expect(WebTransportH3Constants.quicErrorCode(from: 1) == 0x52e4a40fa8db + 1)
    }

    @Test("RESET_STREAM_AT frame type = 0x24")
    func resetStreamAtFrame() {
        #expect(WebTransportH3Constants.resetStreamAtFrameType == 0x24)
    }

    @Test("RESET_STREAM_AT transport parameter")
    func resetStreamAtParam() {
        #expect(WebTransportH3Constants.resetStreamAtTransportParam == 0x17f7586d2cb571)
    }
}
