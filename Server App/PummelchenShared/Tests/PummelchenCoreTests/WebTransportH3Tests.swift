import Foundation
import Testing
@testable import PummelchenCore

@Suite("WebTransport over HTTP/3 draft-15 core")
struct WebTransportH3Tests {
    @Test("QUIC variable-length integers round-trip boundary values")
    func quicVariableLengthIntegersRoundTripBoundaries() throws {
        let cases: [(UInt64, [UInt8])] = [
            (0, [0x00]),
            (63, [0x3f]),
            (64, [0x40, 0x40]),
            (16_383, [0x7f, 0xff]),
            (16_384, [0x80, 0x00, 0x40, 0x00]),
            (1_073_741_823, [0xbf, 0xff, 0xff, 0xff]),
            (1_073_741_824, [0xc0, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00])
        ]

        for (value, expectedBytes) in cases {
            let encoded = try QUICVariableLengthInteger.encode(value)
            #expect(Array(encoded) == expectedBytes)
            var offset = 0
            #expect(try QUICVariableLengthInteger.decode(encoded, offset: &offset) == value)
            #expect(offset == encoded.count)
        }
    }

    @Test("WebTransport stream prefixes encode session ownership")
    func webTransportStreamPrefixesEncodeSessionOwnership() throws {
        let bidi = try WebTransportH3StreamPrefix(kind: .bidirectional, sessionID: 4)
        #expect(Array(try bidi.encode()) == [0x40, 0x41, 0x04])

        let uni = try WebTransportH3StreamPrefix(kind: .unidirectional, sessionID: 4)
        #expect(Array(try uni.encode()) == [0x40, 0x54, 0x04])

        var offset = 0
        let decodedBidi = try WebTransportH3StreamPrefix.decode(try bidi.encode(), expectedKind: .bidirectional, consumedBytes: &offset)
        #expect(decodedBidi == bidi)
        #expect(offset == 3)

        #expect(throws: WebTransportH3Error.invalidWebTransportSessionID(5)) {
            _ = try WebTransportH3StreamPrefix(kind: .bidirectional, sessionID: 5)
        }
    }

    @Test("Capsule protocol frames type length and payload")
    func capsuleProtocolFramesTypeLengthAndPayload() throws {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let capsule = WebTransportH3Capsule(type: WebTransportH3Draft15.Capsule.wtMaxStreamsBidi, payload: payload)
        let encoded = try capsule.encode()

        var offset = 0
        let decoded = try WebTransportH3Capsule.decode(encoded, offset: &offset)
        #expect(decoded == capsule)
        #expect(offset == encoded.count)
    }

    @Test("Server preflight requires all WebTransport-over-H3 capabilities")
    func serverPreflightRequiresAllWebTransportCapabilities() throws {
        let nginxHTTP3Only = WebTransportH3Preflight(
            serverHTTP3Settings: [:],
            maxDatagramFrameSize: nil,
            resetStreamAtEnabled: false,
            sessionEngineActive: false,
            dedicatedUDPPort: 7443,
            behindNginx: false
        )
        #expect(nginxHTTP3Only.unsupportedReason()?.contains("session engine is not active") == true)

        let forbiddenNginxPath = WebTransportH3Preflight(
            serverHTTP3Settings: [
                WebTransportH3Draft15.Setting.wtEnabled: 1,
                WebTransportH3Draft15.Setting.enableConnectProtocol: 1,
                WebTransportH3Draft15.Setting.h3Datagram: 1
            ],
            maxDatagramFrameSize: 1_200,
            resetStreamAtEnabled: true,
            sessionEngineActive: true,
            dedicatedUDPPort: 443,
            behindNginx: true
        )
        #expect(forbiddenNginxPath.unsupportedReason()?.contains("not the nginx HTTP/3 edge") == true)

        let capable = WebTransportH3Preflight(
            serverHTTP3Settings: [
                WebTransportH3Draft15.Setting.wtEnabled: 1,
                WebTransportH3Draft15.Setting.enableConnectProtocol: 1,
                WebTransportH3Draft15.Setting.h3Datagram: 1
            ],
            maxDatagramFrameSize: 1_200,
            resetStreamAtEnabled: true,
            sessionEngineActive: true,
            dedicatedUDPPort: 7443,
            behindNginx: false
        )
        #expect(capable.unsupportedReason() == nil)
        try capable.validateServerSupport()
    }
}
