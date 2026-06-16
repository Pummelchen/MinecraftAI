import Testing
import Foundation
import CryptoKit
@testable import PummelchenQuicCrypto
@testable import PummelchenQuicCore

// MARK: - TLS Reader/Writer Tests

struct TLSReaderWriterTests {
    @Test func readerWriterRoundTrip() throws {
        var w = TLSWriter()
        w.writeUInt8(0x42)
        w.writeUInt16(0x1234)
        w.writeUInt24(0xABCDEF)
        w.writeBytes(Data([0x01, 0x02, 0x03]))

        var r = TLSReader(w.data)
        #expect(try r.readUInt8() == 0x42)
        #expect(try r.readUInt16() == 0x1234)
        #expect(try r.readUInt24() == 0xABCDEF)
        #expect(try r.readBytes(3) == Data([0x01, 0x02, 0x03]))
        #expect(r.isEmpty)
    }

    @Test func vectorRoundTrip() throws {
        var w = TLSWriter()
        let payload = Data("hello".utf8)
        w.writeVector8(payload)
        w.writeVector16(Data("world".utf8))

        var r = TLSReader(w.data)
        #expect(try r.readVector8() == payload)
        #expect(try r.readVector16() == Data("world".utf8))
        #expect(r.isEmpty)
    }
}

// MARK: - Handshake Message Tests

struct HandshakeMessageTests {
    @Test func handshakeWrapperRoundTrip() throws {
        let body = Data("test body".utf8)
        let msg = HandshakeMessage(type: .clientHello, body: body)
        let encoded = msg.encode()

        let decoded = try HandshakeMessage.decode(encoded)
        #expect(decoded.type == .clientHello)
        #expect(decoded.body == body)
    }
}

// MARK: - Extension Tests

struct TLSExtensionTests {
    @Test func sniExtension() throws {
        let ext = TLSExtensionBuilder.serverName("example.com")
        let encoded = ext.encode()
        #expect(encoded.count > 4)

        // Verify type
        let type = UInt16(encoded[0]) << 8 | UInt16(encoded[1])
        #expect(type == ExtensionType.serverName.rawValue)
    }

    @Test func alpnExtension() throws {
        let ext = TLSExtensionBuilder.alpn(["h3"])
        #expect(ext.type == .alpn)

        // Decode the ALPN data
        var r = TLSReader(ext.data)
        let listData = try r.readVector16()
        var lr = TLSReader(listData)
        let len = try Int(lr.readUInt8())
        let proto = try lr.readBytes(len)
        #expect(String(data: proto, encoding: .utf8) == "h3")
    }

    @Test func supportedVersionsClient() throws {
        let ext = TLSExtensionBuilder.supportedVersionsClient()
        #expect(ext.type == .supportedVersions)
        var r = TLSReader(ext.data)
        let count = try Int(r.readUInt8())
        #expect(count == 2) // 1 version × 2 bytes
        let version = try r.readUInt16()
        #expect(version == TLS.version13)
    }

    @Test func keyShareExtension() throws {
        let pubKey = Data(repeating: 0xAB, count: 32)
        let ext = TLSExtensionBuilder.keyShareClient(publicKey: pubKey)
        #expect(ext.type == .keyShare)
    }

    @Test func extensionDecodeSkipsUnknown() throws {
        // Create an extension with an unknown type
        var w = TLSWriter()
        w.writeUInt16(0xFFFF) // unknown type
        w.writeVector16(Data([0x01, 0x02]))
        // Add a known extension
        let sni = TLSExtensionBuilder.serverName("test.example")
        w.writeBytes(sni.encode())

        let exts = try TLSExtension.decodeExtensions(w.data)
        #expect(exts.count == 1) // unknown one skipped, SNI kept
        #expect(exts[0].type == .serverName)
    }
}

// MARK: - ClientHello Tests

struct ClientHelloTests {
    @Test func clientHelloRoundTrip() throws {
        var randomData = Data(count: 32)
        for i in 0..<32 { randomData[i] = UInt8(i) }
        let sessionID = Data(repeating: 0xAA, count: 8)

        let extensions = [
            TLSExtensionBuilder.serverName("example.com"),
            TLSExtensionBuilder.alpn(["h3"]),
            TLSExtensionBuilder.supportedVersionsClient(),
            TLSExtensionBuilder.signatureAlgorithms([.ecdsaSecp256r1Sha256, .rsaPssRsaSha256]),
            TLSExtensionBuilder.supportedGroups([.x25519]),
            TLSExtensionBuilder.keyShareClient(publicKey: Data(repeating: 0xBB, count: 32)),
        ]

        let ch = ClientHello(
            random: randomData,
            legacySessionID: sessionID,
            cipherSuites: [.aes128GcmSha256],
            extensions: extensions
        )

        let body = ch.encodeBody()
        let decoded = try ClientHello.decodeBody(body)

        #expect(decoded.random == randomData)
        #expect(decoded.legacySessionID == sessionID)
        #expect(decoded.cipherSuites == [.aes128GcmSha256])
        #expect(decoded.extensions.count == 6)
    }

    @Test func clientHelloMinimalRoundTrip() throws {
        let random = Data(repeating: 0x42, count: 32)
        let ch = ClientHello(random: random, legacySessionID: Data(), cipherSuites: [.aes128GcmSha256], extensions: [])
        let decoded = try ClientHello.decodeBody(ch.encodeBody())
        #expect(decoded.random == random)
        #expect(decoded.legacySessionID.isEmpty)
        #expect(decoded.cipherSuites == [.aes128GcmSha256])
    }
}

// MARK: - ServerHello Tests

struct ServerHelloTests {
    @Test func serverHelloRoundTrip() throws {
        let random = Data(repeating: 0x55, count: 32)
        let sessionEcho = Data(repeating: 0xAA, count: 8)
        let ext = TLSExtensionBuilder.supportedVersionsServer()

        let sh = ServerHello(
            random: random,
            legacySessionIDEcho: sessionEcho,
            cipherSuite: .aes128GcmSha256,
            extensions: [ext]
        )

        let decoded = try ServerHello.decodeBody(sh.encodeBody())
        #expect(decoded.random == random)
        #expect(decoded.legacySessionIDEcho == sessionEcho)
        #expect(decoded.cipherSuite == .aes128GcmSha256)
        #expect(!decoded.isHelloRetryRequest)
    }

    @Test func helloRetryRequest() {
        let sh = ServerHello(
            random: TLS.hrrRandom,
            legacySessionIDEcho: Data(),
            cipherSuite: .aes128GcmSha256,
            extensions: []
        )
        #expect(sh.isHelloRetryRequest)
    }
}

// MARK: - EncryptedExtensions Tests

struct EncryptedExtensionsTests {
    @Test func roundTrip() throws {
        let exts = [
            TLSExtensionBuilder.alpn(["h3"]),
            TLSExtensionBuilder.quicTransportParameters(Data([0x01, 0x02, 0x03])),
        ]
        let ee = EncryptedExtensions(extensions: exts)
        let decoded = try EncryptedExtensions.decodeBody(ee.encodeBody())
        #expect(decoded.extensions.count == 2)
    }
}

// MARK: - Certificate Tests

struct CertificateTests {
    @Test func certificateRoundTrip() throws {
        let cert1 = Data(repeating: 0x30, count: 100) // fake DER cert
        let cert2 = Data(repeating: 0x31, count: 80)
        let msg = CertificateMessage(certificates: [cert1, cert2])
        let decoded = try CertificateMessage.decodeBody(msg.encodeBody())
        #expect(decoded.certificates.count == 2)
        #expect(decoded.certificates[0] == cert1)
        #expect(decoded.certificates[1] == cert2)
    }
}

// MARK: - CertificateVerify Tests

struct CertificateVerifyTests {
    @Test func roundTrip() throws {
        let sig = Data(repeating: 0xAB, count: 64)
        let cv = CertificateVerify(algorithm: .ecdsaSecp256r1Sha256, signature: sig)
        let decoded = try CertificateVerify.decodeBody(cv.encodeBody())
        #expect(decoded.algorithm == .ecdsaSecp256r1Sha256)
        #expect(decoded.signature == sig)
    }
}

// MARK: - Finished Tests

struct FinishedTests {
    @Test func roundTrip() throws {
        let verifyData = Data(repeating: 0xCD, count: 32)
        let msg = FinishedMessage(verifyData: verifyData)
        let decoded = try FinishedMessage.decodeBody(msg.encodeBody())
        #expect(decoded.verifyData == verifyData)
    }

    @Test func wrongLengthFails() {
        #expect(throws: TLSError.self) {
            _ = try FinishedMessage.decodeBody(Data(repeating: 0, count: 16))
        }
    }
}
