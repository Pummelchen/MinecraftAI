/// TLS 1.3 Key Schedule (RFC 8446 Section 7.1)
///
/// Derives all secrets and traffic keys from the TLS handshake.
/// Only supports AES-128-GCM-SHA256 (no PSK, no 0-RTT).

import Foundation
import CryptoKit

// MARK: - Encryption Level

/// QUIC encryption levels (packet number spaces).
public enum EncryptionLevel: Int, Sendable, Hashable, CaseIterable {
    case initial = 0
    case handshake = 1
    case application = 2
}

// MARK: - Transcript Hash

/// Running SHA-256 transcript hash of handshake messages.
public struct TranscriptHash: Sendable {
    private var state = SHA256()

    public init() {}

    /// Feed a handshake message (including header) into the transcript.
    public mutating func update(_ data: Data) {
        state.update(data: data)
    }

    /// Current transcript hash value (32 bytes).
    public func finalize() -> Data {
        // SHA256 in CryptoKit is value-type, so we copy and finalize the copy
        let copy = state
        return Data(copy.finalize())
    }

    /// Creates a snapshot for later finalization.
    public func snapshot() -> TranscriptHash { self }
}

// MARK: - TLS Key Schedule

/// TLS 1.3 key schedule for AES-128-GCM-SHA256.
///
/// Key schedule flow:
/// ```
/// 0 → Extract(PSK=0) = Early Secret (skip, no PSK)
/// Derive-Secret(Early, "derived", "") → intermediate
/// Extract(intermediate, DHE_shared_secret) = Handshake Secret
/// Derive-Secret(HS, "c hs traffic", CH..SH) = client_hs_traffic_secret
/// Derive-Secret(HS, "s hs traffic", CH..SH) = server_hs_traffic_secret
/// Derive-Secret(HS, "derived", "") → intermediate
/// Extract(intermediate, 0) = Master Secret
/// Derive-Secret(MS, "c ap traffic", CH..SF) = client_app_traffic_secret_0
/// Derive-Secret(MS, "s ap traffic", CH..SF) = server_app_traffic_secret_0
/// ```
public final class TLSKeySchedule: @unchecked Sendable {
    /// All-zero 32-byte value (used as PSK placeholder)
    private static let zeros32 = Data(repeating: 0, count: 32)

    /// Early secret (PSK-derived, but we use zeros since no PSK)
    private var earlySecret: Data?

    /// Handshake secret
    var handshakeSecret: Data?

    /// Master secret
    private var masterSecret: Data?

    public init() {}

    // MARK: - Derive-Secret

    /// Derive-Secret(Secret, Label, TranscriptHash) =
    ///   HKDF-Expand-Label(Secret, Label, TranscriptHash, Hash.length)
    public static func deriveSecret(
        from secret: Data,
        label: String,
        transcriptHash: Data
    ) -> Data {
        return QUICHKDF.expandLabel(
            secret: secret,
            label: label,
            context: transcriptHash,
            length: 32 // SHA-256 hash length
        )
    }

    /// Derive-Secret with empty transcript hash (used for "derived" step).
    public static func deriveSecret(
        from secret: Data,
        label: String
    ) -> Data {
        // Hash of empty string
        let emptyHash = Data(SHA256.hash(data: Data()))
        return deriveSecret(from: secret, label: label, transcriptHash: emptyHash)
    }

    // MARK: - Key Schedule Steps

    /// Step 1: Compute early secret (no PSK, uses zeros).
    public func computeEarlySecret() -> Data {
        let es = QUICHKDF.extract(salt: Data(repeating: 0, count: 32), inputKeyingMaterial: Self.zeros32)
        self.earlySecret = es
        return es
    }

    /// Step 2: Compute the "derived" intermediate from early secret.
    public func computeDerivedSecret(from earlySecret: Data) -> Data {
        return Self.deriveSecret(from: earlySecret, label: "derived")
    }

    /// Step 3: Compute handshake secret from DHE shared secret.
    public func computeHandshakeSecret(derivedSecret: Data, sharedSecret: Data) -> Data {
        let hs = QUICHKDF.extract(salt: derivedSecret, inputKeyingMaterial: sharedSecret)
        self.handshakeSecret = hs
        return hs
    }

    /// Step 4: Derive handshake traffic secrets.
    public func deriveHandshakeTrafficSecrets(
        handshakeSecret: Data,
        transcriptHash: Data
    ) -> (client: Data, server: Data) {
        let client = Self.deriveSecret(from: handshakeSecret, label: "c hs traffic", transcriptHash: transcriptHash)
        let server = Self.deriveSecret(from: handshakeSecret, label: "s hs traffic", transcriptHash: transcriptHash)
        return (client, server)
    }

    /// Step 5: Compute the "derived" intermediate from handshake secret.
    public func computeDerivedFromHandshake(handshakeSecret: Data) -> Data {
        return Self.deriveSecret(from: handshakeSecret, label: "derived")
    }

    /// Step 6: Compute master secret.
    public func computeMasterSecret(derivedSecret: Data) -> Data {
        let ms = QUICHKDF.extract(salt: derivedSecret, inputKeyingMaterial: Self.zeros32)
        self.masterSecret = ms
        return ms
    }

    /// Step 7: Derive application traffic secrets.
    public func deriveApplicationTrafficSecrets(
        masterSecret: Data,
        transcriptHash: Data
    ) -> (client: Data, server: Data) {
        let client = Self.deriveSecret(from: masterSecret, label: "c ap traffic", transcriptHash: transcriptHash)
        let server = Self.deriveSecret(from: masterSecret, label: "s ap traffic", transcriptHash: transcriptHash)
        return (client, server)
    }

    // MARK: - Finished Verification

    /// Compute the Finished verify_data.
    /// verify_data = HMAC(finished_key, TranscriptHash)
    /// finished_key = HKDF-Expand-Label(traffic_secret, "finished", "", 32)
    public static func computeFinished(
        trafficSecret: Data,
        transcriptHash: Data
    ) -> Data {
        let finishedKey = QUICHKDF.expandLabel(
            secret: trafficSecret,
            label: "finished",
            context: Data(),
            length: 32
        )
        let key = SymmetricKey(data: finishedKey)
        let mac = HMAC<SHA256>.authenticationCode(for: transcriptHash, using: key)
        return Data(mac)
    }
}

// MARK: - X25519 Key Exchange

/// X25519 Diffie-Hellman key exchange using CryptoKit.
public struct X25519KeyExchange: Sendable {
    /// Our private key
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    /// Our public key (raw 32 bytes)
    public var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    /// Perform key agreement with the peer's public key.
    public func sharedSecret(peerPublicKey: Data) throws -> Data {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return shared.withUnsafeBytes { Data($0) }
    }
}

// MARK: - Traffic Keys

/// Derives QUIC packet protection keys from a TLS traffic secret.
public enum TLSTrafficKeys {
    /// Derives key + IV + HP key from a traffic secret.
    public static func derive(secret: Data) -> EncryptionKeys {
        return EncryptionKeys.fromTrafficSecret(secret)
    }
}
