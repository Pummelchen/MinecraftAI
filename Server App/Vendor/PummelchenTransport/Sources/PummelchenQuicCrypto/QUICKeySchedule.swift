/// QUIC Key Schedule (RFC 9001 Section 5)
///
/// HKDF-SHA256 key derivation for QUIC packet protection.
/// Uses CryptoKit for all cryptographic operations.

import Foundation
import CryptoKit
import PummelchenQuicCore

// MARK: - HKDF Wrapper

/// HKDF-SHA256 operations for QUIC key derivation.
public enum QUICHKDF {
    /// HKDF-Extract (RFC 5869 §2.2)
    /// PRK = HMAC-Hash(salt, IKM)
    public static func extract(salt: Data, inputKeyingMaterial: Data) -> Data {
        let key = SymmetricKey(data: salt)
        let mac = HMAC<SHA256>.authenticationCode(for: inputKeyingMaterial, using: key)
        return Data(mac)
    }

    /// HKDF-Expand (RFC 5869 §2.3)
    /// Expands a PRK to the desired length using HMAC iteratively.
    public static func expand(prk: Data, info: Data, outputByteCount: Int) -> Data {
        let hashLen = 32 // SHA-256 output
        let n = (outputByteCount + hashLen - 1) / hashLen
        var okm = Data()
        var t = Data() // T(0) = empty

        let key = SymmetricKey(data: prk)
        for i in 1...n {
            var input = t
            input.append(info)
            input.append(UInt8(i))
            let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
            t = Data(mac)
            okm.append(t)
        }

        return okm.prefix(outputByteCount)
    }

    /// HKDF-Expand-Label as defined in TLS 1.3 (RFC 8446 §7.1)
    /// ```
    /// HKDF-Expand-Label(Secret, Label, Context, Length) =
    ///     HKDF-Expand(Secret, HkdfLabel, Length)
    /// ```
    public static func expandLabel(secret: Data, label: String, context: Data, length: Int) -> Data {
        let hkdfLabel = Self.buildHKDFLabel(label: label, context: context, length: length)
        return expand(prk: secret, info: hkdfLabel, outputByteCount: length)
    }

    /// Build the HKDFLabel structure:
    /// ```
    /// struct {
    ///   uint16 length;
    ///   opaque label<7..255> = "tls13 " + Label;
    ///   opaque context<0..255> = Context;
    /// } HkdfLabel;
    /// ```
    public static func buildHKDFLabel(label: String, context: Data, length: Int) -> Data {
        let fullLabel = Data("tls13 \(label)".utf8)
        var data = Data()
        // Length (2 bytes, big-endian)
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        // Label length + label
        data.append(UInt8(fullLabel.count))
        data.append(fullLabel)
        // Context length + context
        data.append(UInt8(context.count))
        data.append(context)
        return data
    }
}

// MARK: - QUIC Key Derivation

/// Derives QUIC-specific keys from TLS secrets (RFC 9001 §5.1).
public enum QUICKeyDerivation {
    /// Key length for AES-128-GCM (16 bytes)
    public static let keyLength = 16

    /// IV length for AES-128-GCM (12 bytes)
    public static let ivLength = 12

    /// Header protection key length (16 bytes for AES-128)
    public static let hpKeyLength = 16

    /// Derives the packet protection key from a TLS secret.
    public static func packetProtectionKey(from secret: Data) -> Data {
        return QUICHKDF.expandLabel(secret: secret, label: "quic key", context: Data(), length: keyLength)
    }

    /// Derives the packet protection IV from a TLS secret.
    public static func packetProtectionIV(from secret: Data) -> Data {
        return QUICHKDF.expandLabel(secret: secret, label: "quic iv", context: Data(), length: ivLength)
    }

    /// Derives the header protection key from a TLS secret.
    public static func headerProtectionKey(from secret: Data) -> Data {
        return QUICHKDF.expandLabel(secret: secret, label: "quic hp", context: Data(), length: hpKeyLength)
    }
}

// MARK: - Key Material

/// Holds the key material for one encryption level.
public struct EncryptionKeys: Sendable {
    /// Packet protection key (AES-128-GCM, 16 bytes)
    public let key: Data

    /// Packet protection IV (12 bytes)
    public let iv: Data

    /// Header protection key (AES-128-ECB, 16 bytes)
    public let hpKey: Data

    /// The secret this was derived from (for key update)
    public let secret: Data

    public init(key: Data, iv: Data, hpKey: Data, secret: Data) {
        self.key = key
        self.iv = iv
        self.hpKey = hpKey
        self.secret = secret
    }

    /// Creates from a TLS traffic secret.
    public static func fromTrafficSecret(_ secret: Data) -> EncryptionKeys {
        return EncryptionKeys(
            key: QUICKeyDerivation.packetProtectionKey(from: secret),
            iv: QUICKeyDerivation.packetProtectionIV(from: secret),
            hpKey: QUICKeyDerivation.headerProtectionKey(from: secret),
            secret: secret
        )
    }
}

// MARK: - Key Update (RFC 9001 §6)

/// Performs 1-RTT key update.
public enum KeyUpdate {
    /// Derives the next application traffic secret.
    public static func nextSecret(from current: Data) -> Data {
        return QUICHKDF.expandLabel(secret: current, label: "quic ku", context: Data(), length: 32)
    }

    /// Performs a full key rotation: derives new key, IV, and HP key.
    public static func rotate(keys current: EncryptionKeys) -> EncryptionKeys {
        let newSecret = nextSecret(from: current.secret)
        return EncryptionKeys.fromTrafficSecret(newSecret)
    }
}
