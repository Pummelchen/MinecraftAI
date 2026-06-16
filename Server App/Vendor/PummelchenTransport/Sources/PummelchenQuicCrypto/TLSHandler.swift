/// TLS 1.3 Handshake Handler for QUIC
///
/// High-level TLS handshake processing. Receives CRYPTO frame data from QUIC,
/// produces CRYPTO frame data + encryption keys for each level.
///
/// Supports both client and server modes. Only AES-128-GCM-SHA256.

import Foundation
import CryptoKit

// MARK: - TLS Configuration

/// TLS configuration for QUIC connections.
public struct TLSConfiguration: Sendable {
    /// Server hostname (SNI) for client mode
    public var serverName: String?

    /// ALPN protocols (e.g. ["h3"])
    public var alpnProtocols: [String]

    /// DER-encoded certificate chain (server mode)
    public var certificateChain: [Data]

    /// Private key for signing (server mode) — PKCS8 DER
    public var signingPrivateKey: Data?

    /// Local QUIC transport parameters (encoded)
    public var transportParameters: Data

    /// Whether to verify peer certificates
    public var verifyPeerCertificate: Bool

    public init(
        serverName: String? = nil,
        alpnProtocols: [String] = ["h3"],
        certificateChain: [Data] = [],
        signingPrivateKey: Data? = nil,
        transportParameters: Data = Data(),
        verifyPeerCertificate: Bool = true
    ) {
        self.serverName = serverName
        self.alpnProtocols = alpnProtocols
        self.certificateChain = certificateChain
        self.signingPrivateKey = signingPrivateKey
        self.transportParameters = transportParameters
        self.verifyPeerCertificate = verifyPeerCertificate
    }
}

// MARK: - TLS Handshake Result

/// Result from processing TLS handshake data.
public enum TLSHandshakeResult: Sendable {
    /// Handshake data to send at a specific encryption level
    case sendData(Data, EncryptionLevel)

    /// New keys available for an encryption level
    case keys(EncryptionLevel, clientKeys: EncryptionKeys, serverKeys: EncryptionKeys)

    /// Handshake complete with negotiated values
    case complete(alpn: String?, peerTransportParameters: Data?)

    /// Need more data to continue
    case needMoreData
}

// MARK: - TLS Handshake State

/// Internal TLS handshake state.
public enum TLSState: Sendable {
    case idle
    case waitingForServerHello
    case waitingForEncryptedExtensions
    case waitingForCertificate
    case waitingForCertificateVerify
    case waitingForServerFinished
    case waitingForClientFinished  // server-side
    case handshakeComplete
    case failed(String)
}

// MARK: - TLS Handler

/// TLS 1.3 handshake handler for QUIC.
public final class TLSHandler: @unchecked Sendable {
    private let configuration: TLSConfiguration
    private let isClient: Bool
    private let keySchedule = TLSKeySchedule()
    private var transcript = TranscriptHash()
    private var state: TLSState = .idle

    // Key exchange
    private var keyExchange: X25519KeyExchange?

    // Secrets
    private var clientHSTrafficSecret: Data?
    private var serverHSTrafficSecret: Data?
    private var clientAppTrafficSecret: Data?
    private var serverAppTrafficSecret: Data?

    // Handshake buffer (for reassembling fragmented messages)
    private var buffer = Data()

    // ClientHello session ID (for middlebox compat — random 32 bytes)
    private var legacySessionID: Data?

    // Peer transport parameters (extracted from extensions)
    private var peerTransportParams: Data?

    // Negotiated ALPN
    private var negotiatedALPN: String?

    public init(configuration: TLSConfiguration, isClient: Bool) {
        self.configuration = configuration
        self.isClient = isClient
    }

    // MARK: - Public API

    /// Start the handshake. For clients, returns the ClientHello to send.
    /// For servers, returns nothing (server waits for ClientHello).
    public func start() throws -> [TLSHandshakeResult] {
        guard isClient else { return [] }

        let kx = X25519KeyExchange()
        self.keyExchange = kx

        // Generate random session ID for middlebox compatibility
        var sid = Data(count: 32)
        for i in 0..<32 { sid[i] = UInt8.random(in: 0...255) }
        self.legacySessionID = sid

        // Build extensions
        var extensions: [TLSExtension] = []
        if let sn = configuration.serverName {
            extensions.append(TLSExtensionBuilder.serverName(sn))
        }
        if !configuration.alpnProtocols.isEmpty {
            extensions.append(TLSExtensionBuilder.alpn(configuration.alpnProtocols))
        }
        extensions.append(TLSExtensionBuilder.supportedVersionsClient())
        extensions.append(TLSExtensionBuilder.signatureAlgorithms([.ecdsaSecp256r1Sha256, .rsaPssRsaSha256, .ed25519]))
        extensions.append(TLSExtensionBuilder.supportedGroups([.x25519]))
        extensions.append(TLSExtensionBuilder.keyShareClient(publicKey: kx.publicKey))
        if !configuration.transportParameters.isEmpty {
            extensions.append(TLSExtensionBuilder.quicTransportParameters(configuration.transportParameters))
        }

        // Generate random
        var random = Data(count: 32)
        for i in 0..<32 { random[i] = UInt8.random(in: 0...255) }

        let ch = ClientHello(
            random: random,
            legacySessionID: sid,
            cipherSuites: [.aes128GcmSha256],
            extensions: extensions
        )

        let body = ch.encodeBody()
        let msg = HandshakeMessage(type: .clientHello, body: body)
        let encoded = msg.encode()

        // Update transcript
        transcript.update(encoded)

        state = .waitingForServerHello
        return [.sendData(encoded, .initial)]
    }

    /// Process incoming CRYPTO frame data at the given encryption level.
    public func processData(_ data: Data, at level: EncryptionLevel) throws -> [TLSHandshakeResult] {
        buffer.append(data)
        var results: [TLSHandshakeResult] = []

        while buffer.count >= 4 {
            // Parse handshake header
            let typeByte = buffer[buffer.startIndex]
            let length = Int(buffer[buffer.startIndex + 1]) << 16 |
                         Int(buffer[buffer.startIndex + 2]) << 8 |
                         Int(buffer[buffer.startIndex + 3])
            let totalLength = 4 + length

            guard buffer.count >= totalLength else {
                return results.isEmpty ? [.needMoreData] : results
            }

            let msgData = buffer.prefix(totalLength)
            buffer.removeFirst(totalLength)

            guard let type = HandshakeType(rawValue: typeByte) else {
                throw TLSError.invalidMessage("unknown handshake type: \(typeByte)")
            }

            let body = Data(msgData.suffix(length))
            let newResults = try processMessage(type: type, body: body, rawMessage: Data(msgData))
            results.append(contentsOf: newResults)
        }

        return results.isEmpty ? [.needMoreData] : results
    }

    // MARK: - Message Processing

    private func processMessage(type: HandshakeType, body: Data, rawMessage: Data) throws -> [TLSHandshakeResult] {
        switch (isClient, state, type) {

        // Client receives ServerHello
        case (true, .waitingForServerHello, .serverHello):
            return try processServerHello(body: body, rawMessage: rawMessage)

        // Client receives EncryptedExtensions
        case (true, .waitingForEncryptedExtensions, .encryptedExtensions):
            return try processEncryptedExtensions(body: body, rawMessage: rawMessage)

        // Client receives Certificate
        case (true, .waitingForCertificate, .certificate):
            transcript.update(rawMessage)
            state = .waitingForCertificateVerify
            return []

        // Client receives CertificateVerify
        case (true, .waitingForCertificateVerify, .certificateVerify):
            transcript.update(rawMessage)
            state = .waitingForServerFinished
            return []

        // Client receives Finished
        case (true, .waitingForServerFinished, .finished):
            return try processServerFinished(body: body, rawMessage: rawMessage)

        // Server receives ClientHello
        case (false, .idle, .clientHello):
            return try processClientHello(body: body, rawMessage: rawMessage)

        // Server receives Finished
        case (false, .waitingForClientFinished, .finished):
            return try processClientFinished(body: body, rawMessage: rawMessage)

        default:
            throw TLSError.invalidMessage("unexpected message \(type) in state \(state)")
        }
    }

    // MARK: - Client: Process ServerHello

    private func processServerHello(body: Data, rawMessage: Data) throws -> [TLSHandshakeResult] {
        let sh = try ServerHello.decodeBody(body)

        guard !sh.isHelloRetryRequest else {
            throw TLSError.invalidMessage("HelloRetryRequest not supported")
        }
        guard sh.cipherSuite == .aes128GcmSha256 else {
            throw TLSError.invalidMessage("unsupported cipher suite")
        }

        // Extract key share
        guard let ksExt = sh.extensions.first(where: { $0.type == .keyShare }) else {
            throw TLSError.invalidMessage("missing key_share extension")
        }
        var ksReader = TLSReader(ksExt.data)
        _ = try ksReader.readUInt16() // group (x25519)
        let peerPublicKey = try ksReader.readVector16()

        // Perform key exchange
        guard let kx = keyExchange else {
            throw TLSError.invalidMessage("no key exchange initialized")
        }
        let sharedSecret = try kx.sharedSecret(peerPublicKey: peerPublicKey)

        // Update transcript with ServerHello
        transcript.update(rawMessage)

        // Derive handshake secrets
        let earlySecret = keySchedule.computeEarlySecret()
        let derived = keySchedule.computeDerivedSecret(from: earlySecret)
        let hsSecret = keySchedule.computeHandshakeSecret(derivedSecret: derived, sharedSecret: sharedSecret)

        let transcriptHash = transcript.snapshot().finalize()
        let (clientHS, serverHS) = keySchedule.deriveHandshakeTrafficSecrets(
            handshakeSecret: hsSecret,
            transcriptHash: transcriptHash
        )

        self.clientHSTrafficSecret = clientHS
        self.serverHSTrafficSecret = serverHS

        let clientHSKeys = TLSTrafficKeys.derive(secret: clientHS)
        let serverHSKeys = TLSTrafficKeys.derive(secret: serverHS)

        state = .waitingForEncryptedExtensions

        return [
            .keys(.handshake, clientKeys: clientHSKeys, serverKeys: serverHSKeys)
        ]
    }

    // MARK: - Client: Process EncryptedExtensions

    private func processEncryptedExtensions(body: Data, rawMessage: Data) throws -> [TLSHandshakeResult] {
        let ee = try EncryptedExtensions.decodeBody(body)

        // Extract ALPN
        if let alpnExt = ee.extensions.first(where: { $0.type == .alpn }) {
            var r = TLSReader(alpnExt.data)
            let listData = try r.readVector16()
            if !listData.isEmpty {
                var lr = TLSReader(listData)
                let len = try Int(lr.readUInt8())
                let proto = try lr.readBytes(len)
                self.negotiatedALPN = String(data: proto, encoding: .utf8)
            }
        }

        // Extract peer transport parameters
        if let tpExt = ee.extensions.first(where: { $0.type == .quicTransportParameters }) {
            self.peerTransportParams = tpExt.data
        }

        transcript.update(rawMessage)

        // Server may optionally send Certificate + CertificateVerify + Finished
        // For now, assume server always sends them (authenticated handshake)
        state = .waitingForCertificate
        return []
    }

    // MARK: - Client: Process Server Finished

    private func processServerFinished(body: Data, rawMessage: Data) throws -> [TLSHandshakeResult] {
        let finished = try FinishedMessage.decodeBody(body)

        // Verify server's Finished
        guard let serverHS = serverHSTrafficSecret else {
            throw TLSError.invalidMessage("no server handshake secret")
        }

        let transcriptBeforeFinished = transcript.snapshot().finalize()
        let expectedVerify = TLSKeySchedule.computeFinished(
            trafficSecret: serverHS,
            transcriptHash: transcriptBeforeFinished
        )

        guard finished.verifyData == expectedVerify else {
            throw TLSError.invalidMessage("server Finished verify_data mismatch")
        }

        // Update transcript with server Finished
        transcript.update(rawMessage)

        // Derive application secrets
        guard let hsSecret = keySchedule.handshakeSecret else {
            throw TLSError.invalidMessage("no handshake secret")
        }

        let derived = keySchedule.computeDerivedFromHandshake(handshakeSecret: hsSecret)
        let masterSecret = keySchedule.computeMasterSecret(derivedSecret: derived)

        // Per RFC 8446 §7.1, app traffic secrets use transcript hash CH..SF
        // where SF = server Finished. Use the transcript AFTER adding server Finished.
        let appHash = transcript.snapshot().finalize()

        let (clientApp, serverApp) = keySchedule.deriveApplicationTrafficSecrets(
            masterSecret: masterSecret,
            transcriptHash: appHash
        )

        self.clientAppTrafficSecret = clientApp
        self.serverAppTrafficSecret = serverApp

        let clientAppKeys = TLSTrafficKeys.derive(secret: clientApp)
        let serverAppKeys = TLSTrafficKeys.derive(secret: serverApp)

        // Compute and send client Finished
        let clientFinished = TLSKeySchedule.computeFinished(
            trafficSecret: clientApp,
            transcriptHash: appHash
        )
        let finishedMsg = FinishedMessage(verifyData: clientFinished)
        let bodyData = finishedMsg.encodeBody()
        let msg = HandshakeMessage(type: .finished, body: bodyData)
        let encoded = msg.encode()
        transcript.update(encoded)

        state = .handshakeComplete

        return [
            .sendData(encoded, .handshake),
            .keys(.application, clientKeys: clientAppKeys, serverKeys: serverAppKeys),
            .complete(alpn: negotiatedALPN, peerTransportParameters: peerTransportParams),
        ]
    }

    // MARK: - Server: Process ClientHello

    private func processClientHello(body: Data, rawMessage: Data) throws -> [TLSHandshakeResult] {
        let ch = try ClientHello.decodeBody(body)

        // Verify cipher suite
        guard ch.cipherSuites.contains(.aes128GcmSha256) else {
            throw TLSError.invalidMessage("client doesn't support AES-128-GCM-SHA256")
        }

        // Extract key share
        guard let ksExt = ch.extensions.first(where: { $0.type == .keyShare }) else {
            throw TLSError.invalidMessage("missing key_share extension")
        }
        var ksReader = TLSReader(ksExt.data)
        let listData = try ksReader.readVector16()
        var listReader = TLSReader(listData)
        let group = try listReader.readUInt16()
        guard group == NamedGroup.x25519.rawValue else {
            throw TLSError.invalidMessage("unsupported key share group")
        }
        let peerPublicKey = try listReader.readVector16()

        // Perform key exchange
        let kx = X25519KeyExchange()
        self.keyExchange = kx
        let sharedSecret = try kx.sharedSecret(peerPublicKey: peerPublicKey)

        // Extract peer transport parameters
        if let tpExt = ch.extensions.first(where: { $0.type == .quicTransportParameters }) {
            self.peerTransportParams = tpExt.data
        }

        // Extract ALPN preference
        if let alpnExt = ch.extensions.first(where: { $0.type == .alpn }) {
            var r = TLSReader(alpnExt.data)
            let alpnListData = try r.readVector16()
            var lr = TLSReader(alpnListData)
            while !lr.isEmpty {
                let len = try Int(lr.readUInt8())
                let proto = try lr.readBytes(len)
                if let protoStr = String(data: proto, encoding: .utf8),
                   configuration.alpnProtocols.contains(protoStr) {
                    self.negotiatedALPN = protoStr
                    break
                }
            }
        }

        // Update transcript with ClientHello
        transcript.update(rawMessage)

        // Build ServerHello
        var serverRandom = Data(count: 32)
        for i in 0..<32 { serverRandom[i] = UInt8.random(in: 0...255) }

        let sh = ServerHello(
            random: serverRandom,
            legacySessionIDEcho: ch.legacySessionID,
            cipherSuite: .aes128GcmSha256,
            extensions: [
                TLSExtensionBuilder.supportedVersionsServer(),
                TLSExtensionBuilder.keyShareServer(publicKey: kx.publicKey),
            ]
        )
        let shBody = sh.encodeBody()
        let shMsg = HandshakeMessage(type: .serverHello, body: shBody)
        let shEncoded = shMsg.encode()
        transcript.update(shEncoded)

        // Derive handshake secrets
        let earlySecret = keySchedule.computeEarlySecret()
        let derived = keySchedule.computeDerivedSecret(from: earlySecret)
        let hsSecret = keySchedule.computeHandshakeSecret(derivedSecret: derived, sharedSecret: sharedSecret)

        let shTranscriptHash = transcript.snapshot().finalize()
        let (clientHS, serverHS) = keySchedule.deriveHandshakeTrafficSecrets(
            handshakeSecret: hsSecret,
            transcriptHash: shTranscriptHash
        )

        self.clientHSTrafficSecret = clientHS
        self.serverHSTrafficSecret = serverHS

        let clientHSKeys = TLSTrafficKeys.derive(secret: clientHS)
        let serverHSKeys = TLSTrafficKeys.derive(secret: serverHS)

        // Build EncryptedExtensions
        var eeExtensions: [TLSExtension] = []
        if let alpn = negotiatedALPN {
            eeExtensions.append(TLSExtensionBuilder.alpn([alpn]))
        }
        if !configuration.transportParameters.isEmpty {
            eeExtensions.append(TLSExtensionBuilder.quicTransportParameters(configuration.transportParameters))
        }
        let ee = EncryptedExtensions(extensions: eeExtensions)
        let eeBody = ee.encodeBody()
        let eeMsg = HandshakeMessage(type: .encryptedExtensions, body: eeBody)
        let eeEncoded = eeMsg.encode()
        transcript.update(eeEncoded)

        // Build Certificate (if we have certificates)
        var results: [TLSHandshakeResult] = [
            .sendData(shEncoded, .initial),
            .keys(.handshake, clientKeys: clientHSKeys, serverKeys: serverHSKeys),
        ]

        var handshakeData = Data() // collect all handshake-level messages

        if !configuration.certificateChain.isEmpty {
            let cert = CertificateMessage(certificates: configuration.certificateChain)
            let certBody = cert.encodeBody()
            let certMsg = HandshakeMessage(type: .certificate, body: certBody)
            let certEncoded = certMsg.encode()
            transcript.update(certEncoded)
            handshakeData.append(certEncoded)

            // Build CertificateVerify (sign the transcript)
            if let privKeyData = configuration.signingPrivateKey {
                let transcriptForVerify = transcript.snapshot().finalize()
                let signature = try signTranscript(transcriptHash: transcriptForVerify, privateKey: privKeyData)
                let cv = CertificateVerify(algorithm: .ecdsaSecp256r1Sha256, signature: signature)
                let cvBody = cv.encodeBody()
                let cvMsg = HandshakeMessage(type: .certificateVerify, body: cvBody)
                let cvEncoded = cvMsg.encode()
                transcript.update(cvEncoded)
                handshakeData.append(cvEncoded)
            }
        }

        // Build server Finished
        let serverFinishedVerify = TLSKeySchedule.computeFinished(
            trafficSecret: serverHS,
            transcriptHash: transcript.snapshot().finalize()
        )
        let sfMsg = FinishedMessage(verifyData: serverFinishedVerify)
        let sfBody = sfMsg.encodeBody()
        let sfHandshake = HandshakeMessage(type: .finished, body: sfBody)
        let sfEncoded = sfHandshake.encode()
        transcript.update(sfEncoded)
        handshakeData.append(sfEncoded)

        results.append(.sendData(handshakeData, .handshake))

        // Derive application secrets
        let derivedFromHS = keySchedule.computeDerivedFromHandshake(handshakeSecret: hsSecret)
        let masterSecret = keySchedule.computeMasterSecret(derivedSecret: derivedFromHS)

        // App secrets use transcript up to and including server Finished
        let appHash = transcript.snapshot().finalize()
        let (clientApp, serverApp) = keySchedule.deriveApplicationTrafficSecrets(
            masterSecret: masterSecret,
            transcriptHash: appHash
        )

        self.clientAppTrafficSecret = clientApp
        self.serverAppTrafficSecret = serverApp

        let clientAppKeys = TLSTrafficKeys.derive(secret: clientApp)
        let serverAppKeys = TLSTrafficKeys.derive(secret: serverApp)

        results.append(.keys(.application, clientKeys: clientAppKeys, serverKeys: serverAppKeys))

        state = .waitingForClientFinished
        return results
    }

    // MARK: - Server: Process Client Finished

    private func processClientFinished(body: Data, rawMessage: Data) throws -> [TLSHandshakeResult] {
        let finished = try FinishedMessage.decodeBody(body)

        guard let clientApp = clientAppTrafficSecret else {
            throw TLSError.invalidMessage("no client app traffic secret")
        }

        // Verify client Finished
        let transcriptBeforeFinished = transcript.snapshot().finalize()
        let expectedVerify = TLSKeySchedule.computeFinished(
            trafficSecret: clientApp,
            transcriptHash: transcriptBeforeFinished
        )

        guard finished.verifyData == expectedVerify else {
            throw TLSError.invalidMessage("client Finished verify_data mismatch")
        }

        transcript.update(rawMessage)
        state = .handshakeComplete

        return [.complete(alpn: negotiatedALPN, peerTransportParameters: peerTransportParams)]
    }

    // MARK: - Certificate Signing

    /// Signs the transcript hash for CertificateVerify.
    /// Content to sign: 64 spaces + "TLS 1.3, server CertificateVerify" + 0x00 + transcriptHash
    private func signTranscript(transcriptHash: Data, privateKey: Data) throws -> Data {
        // Build the content to sign per RFC 8446 §4.4.3
        var content = Data()
        content.append(Data(repeating: 0x20, count: 64)) // 64 spaces
        content.append(Data("TLS 1.3, server CertificateVerify".utf8))
        content.append(0x00)
        content.append(transcriptHash)

        // For now, use a simple HMAC-based "signature" placeholder.
        // In production, this would use Security.framework with the actual private key.
        // TODO: Replace with proper ECDSA/RSA signing via Security.framework
        let key = SymmetricKey(data: privateKey)
        let mac = HMAC<SHA256>.authenticationCode(for: content, using: key)
        return Data(mac)
    }
}
