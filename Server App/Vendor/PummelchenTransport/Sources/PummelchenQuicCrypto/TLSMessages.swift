/// TLS 1.3 Message Codec (RFC 8446)
///
/// Encodes and decodes TLS 1.3 handshake messages for QUIC integration.
/// Only supports TLS_AES_128_GCM_SHA256 (single cipher suite).
/// No PSK, no 0-RTT, no session resumption.

import Foundation
import CryptoKit

// MARK: - TLS Constants

/// TLS 1.3 protocol constants.
public enum TLS {
    /// TLS 1.2 legacy version (used in record layer and ClientHello/ServerHello)
    public static let version12: UInt16 = 0x0303
    /// TLS 1.3 version (used in supported_versions extension)
    public static let version13: UInt16 = 0x0304

    /// Random bytes length
    public static let randomLength = 32

    /// HelloRetryRequest magic random (SHA-256 of "HelloRetryRequest")
    public static let hrrRandom = Data([
        0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11,
        0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91,
        0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E,
        0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C
    ])

    /// Verify data length for Finished (SHA-256 = 32 bytes)
    public static let verifyDataLength = 32
}

// MARK: - Handshake Type

/// TLS 1.3 handshake message types (RFC 8446 §4).
public enum HandshakeType: UInt8, Sendable {
    case clientHello = 1
    case serverHello = 2
    case newSessionTicket = 4
    case endOfEarlyData = 5
    case encryptedExtensions = 8
    case certificate = 11
    case certificateRequest = 13
    case certificateVerify = 15
    case finished = 20
    case keyUpdate = 24
    case messageHash = 254
}

// MARK: - Cipher Suite

/// TLS 1.3 cipher suites. We only support one.
public enum CipherSuite: UInt16, Sendable {
    case aes128GcmSha256 = 0x1301
    // case aes256GcmSha384 = 0x1302      // not supported
    // case chacha20Poly1305Sha256 = 0x1303 // not supported
}

// MARK: - Extension Type

/// TLS extension identifiers (RFC 8446 §4.2, plus QUIC-specific).
public enum ExtensionType: UInt16, Sendable {
    case serverName = 0
    case supportedGroups = 10
    case signatureAlgorithms = 13
    case alpn = 16
    case supportedVersions = 43
    case keyShare = 51
    case quicTransportParameters = 0x39 // RFC 9000 §7.3
}

// MARK: - Named Group

/// Named groups for key exchange (RFC 8446 §4.2.7).
public enum NamedGroup: UInt16, Sendable {
    case x25519 = 0x001d
    // case secp256r1 = 0x0017  // not supported
}

// MARK: - Signature Algorithm

/// Signature algorithms (RFC 8446 §4.2.3).
public enum SignatureAlgorithm: UInt16, Sendable {
    case ecdsaSecp256r1Sha256 = 0x0403
    case rsaPssRsaSha256 = 0x0804
    case ed25519 = 0x0807
}

// MARK: - TLS Reader / Writer

/// Big-endian binary reader for TLS messages.
public struct TLSReader {
    public var data: Data
    public var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var isEmpty: Bool { offset >= data.endIndex }

    public mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw TLSError.truncated }
        let v = data[offset]
        offset += 1
        return v
    }

    public mutating func readUInt16() throws -> UInt16 {
        guard remaining >= 2 else { throw TLSError.truncated }
        let v = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return v
    }

    public mutating func readUInt24() throws -> UInt32 {
        guard remaining >= 3 else { throw TLSError.truncated }
        let v = UInt32(data[offset]) << 16 | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2])
        offset += 3
        return v
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        guard remaining >= count else { throw TLSError.truncated }
        let d = data[offset..<offset + count]
        offset += count
        return Data(d)
    }

    /// Read a vector with 1-byte length prefix.
    public mutating func readVector8() throws -> Data {
        let len = try Int(readUInt8())
        return try readBytes(len)
    }

    /// Read a vector with 2-byte length prefix.
    public mutating func readVector16() throws -> Data {
        let len = try Int(readUInt16())
        return try readBytes(len)
    }
}

/// Big-endian binary writer for TLS messages.
public struct TLSWriter {
    public var data: Data

    public init(capacity: Int = 256) {
        self.data = Data(capacity: capacity)
    }

    public mutating func writeUInt8(_ v: UInt8) {
        data.append(v)
    }

    public mutating func writeUInt16(_ v: UInt16) {
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    public mutating func writeUInt24(_ v: UInt32) {
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8(v & 0xFF))
    }

    public mutating func writeBytes(_ d: Data) {
        data.append(d)
    }

    /// Write a vector with 1-byte length prefix.
    public mutating func writeVector8(_ d: Data) {
        writeUInt8(UInt8(d.count))
        writeBytes(d)
    }

    /// Write a vector with 2-byte length prefix.
    public mutating func writeVector16(_ d: Data) {
        writeUInt16(UInt16(d.count))
        writeBytes(d)
    }
}

// MARK: - TLS Errors

/// TLS protocol errors.
public enum TLSError: Error, Sendable {
    case truncated
    case invalidMessage(String)
    case unsupportedExtension(UInt16)
    case alert(UInt8, String)
}

// MARK: - TLS Extension

/// A TLS extension (type + opaque data).
public struct TLSExtension: Sendable {
    public let type: ExtensionType
    public let data: Data

    public init(type: ExtensionType, data: Data) {
        self.type = type
        self.data = data
    }

    /// Encodes the extension (type + length-prefixed data).
    public func encode() -> Data {
        var w = TLSWriter()
        w.writeUInt16(type.rawValue)
        w.writeVector16(data)
        return w.data
    }

    /// Decodes extensions from a 2-byte length-prefixed list.
    public static func decodeExtensions(_ rawData: Data) throws -> [TLSExtension] {
        var r = TLSReader(rawData)
        var exts: [TLSExtension] = []
        while !r.isEmpty {
            let type = try r.readUInt16()
            let data = try r.readVector16()
            if let extType = ExtensionType(rawValue: type) {
                exts.append(TLSExtension(type: extType, data: data))
            }
            // Unknown extensions are silently skipped (per RFC 8446)
        }
        return exts
    }
}

// MARK: - Extension Builders

/// Builders for common TLS extensions.
public enum TLSExtensionBuilder {
    /// SNI extension (RFC 8446 §4.2.1)
    public static func serverName(_ hostname: String) -> TLSExtension {
        var w = TLSWriter()
        // server_name_list (2-byte length prefix)
        var entry = TLSWriter()
        entry.writeUInt8(0) // host_name type
        let nameData = Data(hostname.utf8)
        entry.writeUInt16(UInt16(nameData.count))
        entry.writeBytes(nameData)
        w.writeVector16(entry.data)
        return TLSExtension(type: .serverName, data: w.data)
    }

    /// ALPN extension (RFC 7301)
    public static func alpn(_ protocols: [String]) -> TLSExtension {
        var list = Data()
        for proto in protocols {
            let bytes = Data(proto.utf8)
            list.append(UInt8(bytes.count))
            list.append(bytes)
        }
        var w = TLSWriter()
        w.writeVector16(list)
        return TLSExtension(type: .alpn, data: w.data)
    }

    /// Supported versions extension (RFC 8446 §4.2.1)
    public static func supportedVersionsClient() -> TLSExtension {
        var w = TLSWriter()
        w.writeUInt8(2) // 1 version × 2 bytes
        w.writeUInt16(TLS.version13)
        return TLSExtension(type: .supportedVersions, data: w.data)
    }

    /// Supported versions for ServerHello (single version)
    public static func supportedVersionsServer() -> TLSExtension {
        var w = TLSWriter()
        w.writeUInt16(TLS.version13)
        return TLSExtension(type: .supportedVersions, data: w.data)
    }

    /// Key share entry for X25519 (client)
    public static func keyShareClient(publicKey: Data) -> TLSExtension {
        var w = TLSWriter()
        // client_shares list (2-byte length prefix)
        var entry = TLSWriter()
        entry.writeUInt16(NamedGroup.x25519.rawValue)
        entry.writeVector16(publicKey)
        w.writeVector16(entry.data)
        return TLSExtension(type: .keyShare, data: w.data)
    }

    /// Key share for ServerHello (single entry)
    public static func keyShareServer(publicKey: Data) -> TLSExtension {
        var w = TLSWriter()
        w.writeUInt16(NamedGroup.x25519.rawValue)
        w.writeVector16(publicKey)
        return TLSExtension(type: .keyShare, data: w.data)
    }

    /// Signature algorithms (RFC 8446 §4.2.3)
    public static func signatureAlgorithms(_ algs: [SignatureAlgorithm]) -> TLSExtension {
        var w = TLSWriter()
        var list = Data()
        for alg in algs {
            list.append(UInt8((alg.rawValue >> 8) & 0xFF))
            list.append(UInt8(alg.rawValue & 0xFF))
        }
        w.writeVector16(list)
        return TLSExtension(type: .signatureAlgorithms, data: w.data)
    }

    /// Supported groups
    public static func supportedGroups(_ groups: [NamedGroup]) -> TLSExtension {
        var w = TLSWriter()
        var list = Data()
        for g in groups {
            list.append(UInt8((g.rawValue >> 8) & 0xFF))
            list.append(UInt8(g.rawValue & 0xFF))
        }
        w.writeVector16(list)
        return TLSExtension(type: .supportedGroups, data: w.data)
    }

    /// QUIC transport parameters (RFC 9000 §7.3)
    public static func quicTransportParameters(_ params: Data) -> TLSExtension {
        return TLSExtension(type: .quicTransportParameters, data: params)
    }
}

// MARK: - Handshake Message Wrapper

/// Wraps a handshake message body with its header (type + 3-byte length).
public struct HandshakeMessage {
    public let type: HandshakeType
    public let body: Data

    /// Encodes with the 4-byte handshake header.
    public func encode() -> Data {
        var w = TLSWriter()
        w.writeUInt8(type.rawValue)
        w.writeUInt24(UInt32(body.count))
        w.writeBytes(body)
        return w.data
    }

    /// Decodes a handshake message from raw bytes.
    public static func decode(_ data: Data) throws -> HandshakeMessage {
        var r = TLSReader(data)
        let typeByte = try r.readUInt8()
        guard let type = HandshakeType(rawValue: typeByte) else {
            throw TLSError.invalidMessage("unknown handshake type: \(typeByte)")
        }
        let length = try Int(r.readUInt24())
        let body = try r.readBytes(length)
        return HandshakeMessage(type: type, body: body)
    }
}

// MARK: - ClientHello

/// TLS 1.3 ClientHello (RFC 8446 §4.1.2).
public struct ClientHello: Sendable {
    public let random: Data
    public let legacySessionID: Data
    public let cipherSuites: [CipherSuite]
    public let extensions: [TLSExtension]

    public init(random: Data, legacySessionID: Data, cipherSuites: [CipherSuite], extensions: [TLSExtension]) {
        self.random = random
        self.legacySessionID = legacySessionID
        self.cipherSuites = cipherSuites
        self.extensions = extensions
    }

    /// Encode the body (without handshake header).
    public func encodeBody() -> Data {
        var w = TLSWriter(capacity: 512)
        w.writeUInt16(TLS.version12) // legacy_version
        w.writeBytes(random)          // 32 bytes
        w.writeVector8(legacySessionID)

        // cipher_suites (2-byte length prefix)
        var suites = Data()
        for s in cipherSuites {
            suites.append(UInt8((s.rawValue >> 8) & 0xFF))
            suites.append(UInt8(s.rawValue & 0xFF))
        }
        w.writeVector16(suites)

        // legacy_compression_methods: single zero byte
        w.writeUInt8(1) // length
        w.writeUInt8(0) // null compression

        // extensions (2-byte length prefix)
        var extData = Data()
        for ext in extensions { extData.append(ext.encode()) }
        w.writeVector16(extData)

        return w.data
    }

    /// Decode from the body (after handshake header).
    public static func decodeBody(_ data: Data) throws -> ClientHello {
        var r = TLSReader(data)
        _ = try r.readUInt16() // legacy_version (ignored)
        let random = try r.readBytes(TLS.randomLength)
        let sessionID = try r.readVector8()

        let suitesData = try r.readVector16()
        var suites: [CipherSuite] = []
        var sr = TLSReader(suitesData)
        while !sr.isEmpty {
            let v = try sr.readUInt16()
            if let s = CipherSuite(rawValue: v) { suites.append(s) }
        }

        let compLen = try Int(r.readUInt8())
        _ = try r.readBytes(compLen) // skip compression methods

        let extData = try r.readVector16()
        let extensions = try TLSExtension.decodeExtensions(extData)

        return ClientHello(random: random, legacySessionID: sessionID, cipherSuites: suites, extensions: extensions)
    }
}

// MARK: - ServerHello

/// TLS 1.3 ServerHello (RFC 8446 §4.1.3).
public struct ServerHello: Sendable {
    public let random: Data
    public let legacySessionIDEcho: Data
    public let cipherSuite: CipherSuite
    public let extensions: [TLSExtension]

    public init(random: Data, legacySessionIDEcho: Data, cipherSuite: CipherSuite, extensions: [TLSExtension]) {
        self.random = random
        self.legacySessionIDEcho = legacySessionIDEcho
        self.cipherSuite = cipherSuite
        self.extensions = extensions
    }

    public var isHelloRetryRequest: Bool { random == TLS.hrrRandom }

    /// Encode the body (without handshake header).
    public func encodeBody() -> Data {
        var w = TLSWriter()
        w.writeUInt16(TLS.version12) // legacy_version
        w.writeBytes(random)
        w.writeVector8(legacySessionIDEcho)
        w.writeUInt16(cipherSuite.rawValue)
        w.writeUInt8(0) // legacy_compression_method

        var extData = Data()
        for ext in extensions { extData.append(ext.encode()) }
        w.writeVector16(extData)

        return w.data
    }

    /// Decode from the body.
    public static func decodeBody(_ data: Data) throws -> ServerHello {
        var r = TLSReader(data)
        _ = try r.readUInt16() // legacy_version
        let random = try r.readBytes(TLS.randomLength)
        let sessionIDEcho = try r.readVector8()
        let suiteRaw = try r.readUInt16()
        guard let suite = CipherSuite(rawValue: suiteRaw) else {
            throw TLSError.invalidMessage("unsupported cipher suite: \(suiteRaw)")
        }
        _ = try r.readUInt8() // legacy_compression_method

        let extData = try r.readVector16()
        let extensions = try TLSExtension.decodeExtensions(extData)

        return ServerHello(random: random, legacySessionIDEcho: sessionIDEcho, cipherSuite: suite, extensions: extensions)
    }
}

// MARK: - EncryptedExtensions

/// TLS 1.3 EncryptedExtensions (RFC 8446 §4.3.1).
public struct EncryptedExtensions: Sendable {
    public let extensions: [TLSExtension]

    public init(extensions: [TLSExtension]) {
        self.extensions = extensions
    }

    public func encodeBody() -> Data {
        var w = TLSWriter()
        var extData = Data()
        for ext in extensions { extData.append(ext.encode()) }
        w.writeVector16(extData)
        return w.data
    }

    public static func decodeBody(_ data: Data) throws -> EncryptedExtensions {
        var r = TLSReader(data)
        let extData = try r.readVector16()
        let extensions = try TLSExtension.decodeExtensions(extData)
        return EncryptedExtensions(extensions: extensions)
    }
}

// MARK: - Certificate

/// TLS 1.3 Certificate (RFC 8446 §4.4.2).
public struct CertificateMessage: Sendable {
    /// Each entry is a DER-encoded certificate with empty extensions.
    public let certificates: [Data]

    public init(certificates: [Data]) {
        self.certificates = certificates
    }

    public func encodeBody() -> Data {
        var w = TLSWriter()
        w.writeUInt8(0) // certificate_request_context (empty for server)

        var list = Data()
        for cert in certificates {
            // cert_data (3-byte length) + extensions (2-byte length, empty)
            var entry = TLSWriter()
            entry.writeUInt24(UInt32(cert.count))
            entry.writeBytes(cert)
            entry.writeUInt16(0) // empty extensions
            list.append(entry.data)
        }
        w.writeUInt24(UInt32(list.count))
        w.writeBytes(list)
        return w.data
    }

    public static func decodeBody(_ data: Data) throws -> CertificateMessage {
        var r = TLSReader(data)
        _ = try r.readVector8() // certificate_request_context
        let listData = try r.readBytes(Int(try r.readUInt24()))
        var lr = TLSReader(listData)
        var certs: [Data] = []
        while !lr.isEmpty {
            let certLen = try Int(lr.readUInt24())
            let cert = try lr.readBytes(certLen)
            _ = try lr.readVector16() // extensions (skip)
            certs.append(cert)
        }
        return CertificateMessage(certificates: certs)
    }
}

// MARK: - CertificateVerify

/// TLS 1.3 CertificateVerify (RFC 8446 §4.4.3).
public struct CertificateVerify: Sendable {
    public let algorithm: SignatureAlgorithm
    public let signature: Data

    public init(algorithm: SignatureAlgorithm, signature: Data) {
        self.algorithm = algorithm
        self.signature = signature
    }

    public func encodeBody() -> Data {
        var w = TLSWriter()
        w.writeUInt16(algorithm.rawValue)
        w.writeVector16(signature)
        return w.data
    }

    public static func decodeBody(_ data: Data) throws -> CertificateVerify {
        var r = TLSReader(data)
        let algRaw = try r.readUInt16()
        guard let alg = SignatureAlgorithm(rawValue: algRaw) else {
            throw TLSError.invalidMessage("unsupported signature algorithm: \(algRaw)")
        }
        let sig = try r.readVector16()
        return CertificateVerify(algorithm: alg, signature: sig)
    }
}

// MARK: - Finished

/// TLS 1.3 Finished (RFC 8446 §4.4.4).
public struct FinishedMessage: Sendable {
    public let verifyData: Data // 32 bytes for SHA-256

    public init(verifyData: Data) {
        self.verifyData = verifyData
    }

    public func encodeBody() -> Data { verifyData }

    public static func decodeBody(_ data: Data) throws -> FinishedMessage {
        guard data.count == TLS.verifyDataLength else {
            throw TLSError.invalidMessage("Finished verify_data must be \(TLS.verifyDataLength) bytes, got \(data.count)")
        }
        return FinishedMessage(verifyData: data)
    }
}
