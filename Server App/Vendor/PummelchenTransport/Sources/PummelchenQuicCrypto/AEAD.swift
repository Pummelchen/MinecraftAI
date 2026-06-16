/// QUIC AEAD (RFC 9001 Section 5.3)
///
/// AES-128-GCM packet protection: seal (encrypt) and open (decrypt).
/// Nonce is constructed by XORing the IV with the packet number.

import Foundation
import CryptoKit
import PummelchenQuicCore

/// QUIC AEAD operations using AES-128-GCM via CryptoKit.
public enum QUICAEAD {
    /// Constructs the AEAD nonce from IV and packet number (RFC 9001 §5.3).
    ///
    /// nonce = iv XOR (packet_number left-padded to 12 bytes)
    public static func makeNonce(iv: Data, packetNumber: UInt64) -> Data {
        var nonce = iv
        let pnBytes = withUnsafeBytes(of: packetNumber.bigEndian) { Data($0) }
        // XOR the last 8 bytes of IV with the packet number
        for i in 0..<8 {
            nonce[iv.count - 8 + i] ^= pnBytes[i]
        }
        return nonce
    }

    /// Encrypts (seals) a QUIC packet payload.
    ///
    /// - Parameters:
    ///   - plaintext: The payload to encrypt
    ///   - aad: Additional authenticated data (the unencrypted header)
    ///   - key: AES-128-GCM key (16 bytes)
    ///   - iv: 12-byte IV
    ///   - packetNumber: Packet number for nonce construction
    /// - Returns: Ciphertext + 16-byte authentication tag
    public static func seal(
        plaintext: Data,
        aad: Data,
        key: Data,
        iv: Data,
        packetNumber: UInt64
    ) throws -> Data {
        let nonce = makeNonce(iv: iv, packetNumber: packetNumber)
        let nonceBytes = try AES.GCM.Nonce(data: nonce)
        let symmetricKey = SymmetricKey(data: key)

        let sealed = try AES.GCM.seal(
            plaintext,
            using: symmetricKey,
            nonce: nonceBytes,
            authenticating: aad
        )

        // CryptoKit returns ciphertext + tag concatenated
        return sealed.ciphertext + sealed.tag
    }

    /// Decrypts (opens) a QUIC packet payload.
    ///
    /// - Parameters:
    ///   - ciphertext: Ciphertext + 16-byte authentication tag
    ///   - aad: Additional authenticated data (the unencrypted header)
    ///   - key: AES-128-GCM key (16 bytes)
    ///   - iv: 12-byte IV
    ///   - packetNumber: Packet number for nonce construction
    /// - Returns: Decrypted plaintext
    public static func open(
        ciphertext: Data,
        aad: Data,
        key: Data,
        iv: Data,
        packetNumber: UInt64
    ) throws -> Data {
        let nonce = makeNonce(iv: iv, packetNumber: packetNumber)
        let nonceBytes = try AES.GCM.Nonce(data: nonce)
        let symmetricKey = SymmetricKey(data: key)

        // Split ciphertext and tag (last 16 bytes are the tag)
        guard ciphertext.count >= 16 else {
            throw QUICCryptoError.aeadDecryptionFailed("ciphertext too short")
        }

        let encryptedData = ciphertext[ciphertext.startIndex..<ciphertext.endIndex.advanced(by: -16)]
        let tag = ciphertext[ciphertext.endIndex.advanced(by: -16)...]

        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonceBytes,
            ciphertext: encryptedData,
            tag: tag
        )

        return try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
    }
}

/// QUIC cryptographic errors.
public enum QUICCryptoError: Error, Sendable {
    case aeadDecryptionFailed(String)
    case invalidKeySize
    case handshakeError(String)
}
