import Testing
import Foundation
@testable import PummelchenHTTP3
@testable import PummelchenQuic
@testable import PummelchenQuicCore
@testable import PummelchenQuicCrypto

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
        let frame = HTTP3Frame(type: 0x00, payload: Data([0xAA, 0xBB, 0xCC]))
        let encoded = frame.encode()
        #expect(encoded.count == 5)
        #expect(encoded[0] == 0x00)
        #expect(encoded[1] == 0x03)
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
        var data = Data()
        data.append(contentsOf: Varint.encode(0))
        data.append(0x00)
        data.append(0x80)
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
        #expect(data[0] == 0x00)
        var offset = 1
        let frame = HTTP3Frame.decode(from: data, offset: &offset)
        #expect(frame != nil)
        #expect(frame?.type == HTTP3FrameType.settings.rawValue)
    }

    @Test("Process peer SETTINGS from control stream")
    func processPeerSettings() throws {
        let conn = HTTP3Connection(localSettings: HTTP3SettingsFrame())
        var peerData = Data()
        let peerSettings = HTTP3SettingsFrame(settings: [
            HTTP3Setting(id: .maxFieldSectionSize, value: 8192)
        ])
        let settingsFrame = HTTP3Frame(type: .settings, payload: peerSettings.encodePayload())
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
    }
}

// MARK: - WebTransport Capsule Tests

@Suite("WebTransport Capsules")
struct WTCapsuleTests {

    @Test("Capsule encode/decode round-trip")
    func capsuleRoundTrip() {
        let payload = Data([0x00, 0x00, 0x00, 0x00])
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
    func sessionClose() async {
        let session = WebTransportSession(sessionID: 1)
        await session.close(errorCode: 0, reason: "done")
        #expect(!session.isActive)
    }

    @Test("Open bidirectional stream")
    func openBidiStream() async throws {
        let session = WebTransportSession(sessionID: 1, isClient: true)
        let stream = try await session.openBidirectionalStream()
        #expect(stream.isBidirectional)
        #expect(stream.sessionID == 1)
    }

    @Test("Incoming bidi stream yields to async stream")
    func incomingBidiStream() async {
        let session = WebTransportSession(sessionID: 1)
        let stream = session.handleIncomingBidiStream(streamID: 10)
        #expect(stream.isBidirectional)
        #expect(stream.streamID == 10)
        var iterator = session.incomingBidirectionalStreams.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.streamID == 10)
    }
}

// MARK: - WebTransport Stream Tests

@Suite("WebTransport Stream")
struct WTStreamTests {

    @Test("Stream write and read")
    func streamWriteRead() async throws {
        let stream = WebTransportStream(streamID: 1, sessionID: 1, isBidirectional: true)
        stream.receiveData(Data([0x01, 0x02, 0x03]))
        let data = try await stream.read(maxBytes: 10)
        #expect(data == Data([0x01, 0x02, 0x03]))
    }

    @Test("Stream close write")
    func streamCloseWrite() async throws {
        let stream = WebTransportStream(streamID: 1, sessionID: 1, isBidirectional: true)
        #expect(stream.isOpen)
        try await stream.closeWrite()
        #expect(!stream.isOpen)
    }
}

// MARK: - WebTransport Client Tests

@Suite("WebTransport Client")
struct WTClientTests {

    @Test("Client connect returns session")
    func clientConnect() async throws {
        let quic = QUICConfiguration.production {
            TLS13Handler(configuration: TLSConfiguration())
        }
        let endpoint = QUICEndpoint(configuration: quic)
        let connection = try await endpoint.dial(
            address: SocketAddress(ipAddress: "127.0.0.1", port: 443)
        )
        let client = WebTransportClient(quicConnection: connection)
        try await client.initialize()
        let session = try await client.connect(authority: "example.com:443", path: "/wt")
        #expect(session.isActive)
        await client.close()
        await endpoint.stop()
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
        #expect(WebTransportH3Constants.quicErrorCode(from: 0) == 0x52e4a40fa8db)
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

// MARK: - QUIC Configuration Tests

@Suite("QUIC Configuration")
struct QUICConfigurationTests {

    @Test("Production configuration defaults")
    func productionDefaults() {
        let config = QUICConfiguration.production {
            TLS13Handler(configuration: TLSConfiguration())
        }
        #expect(config.alpn == ["h3"])
        #expect(config.initialMaxStreamsBidi == 100)
        #expect(config.initialMaxStreamsUni == 100)
    }

    @Test("Configuration is mutable")
    func configurationMutable() {
        let config = QUICConfiguration.production {
            TLS13Handler(configuration: TLSConfiguration())
        }
        config.maxIdleTimeout = .seconds(90)
        config.initialMaxStreamsBidi = 512
        config.enableDatagrams = true
        config.maxDatagramFrameSize = 65_535
        #expect(config.initialMaxStreamsBidi == 512)
        #expect(config.enableDatagrams == true)
        #expect(config.maxDatagramFrameSize == 65_535)
    }
}

// MARK: - TLS Configuration Tests

@Suite("TLS Configuration")
struct TLSConfigurationTests {

    @Test("Client factory method")
    func clientConfig() {
        let config = TLSConfiguration.client(serverName: "example.com", alpnProtocols: ["h3"])
        #expect(config.serverName == "example.com")
        #expect(config.alpnProtocols == ["h3"])
    }

    @Test("Verify peer defaults to true")
    func verifyPeerDefault() {
        let config = TLSConfiguration()
        #expect(config.verifyPeer == true)
    }

    @Test("Use system trust store")
    func useSystemTrustStore() {
        var config = TLSConfiguration()
        config.useSystemTrustStore()
        #expect(config.useSystemTrust == true)
    }
}
