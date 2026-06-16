/// QUIC Header Protection (RFC 9001 Section 5.4)
///
/// Protects the packet number and certain header bits using AES-128-ECB.
/// The header protection mask is derived from the sample bytes in the
/// ciphertext.

import Foundation
import CryptoKit
import CommonCrypto
import PummelchenQuicCore

/// QUIC header protection using AES-128-ECB.
public enum HeaderProtection {
    /// Sample offset from the start of the packet number field.
    /// RFC 9001 §5.4.2: sample is taken at offset 4 from the start of PN field.
    public static let sampleOffset = 4

    /// Sample length (16 bytes for AES).
    public static let sampleLength = 16

    /// Generates the 5-byte header protection mask.
    ///
    /// - Parameters:
    ///   - hpKey: Header protection key (AES-128)
    ///   - sample: 16 bytes of ciphertext starting 4 bytes after the PN field
    /// - Returns: 5-byte mask
    public static func mask(hpKey: Data, sample: Data) throws -> Data {
        guard sample.count >= sampleLength else {
            throw QUICCryptoError.aeadDecryptionFailed("HP sample too short")
        }

        // AES-128-ECB encrypt the sample using CommonCrypto
        var encrypted = [UInt8](repeating: 0, count: sampleLength)
        let keyBytes = [UInt8](hpKey)
        let sampleBytes = [UInt8](sample.prefix(sampleLength))
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionECBMode),
            keyBytes, keyBytes.count,
            nil,  // no IV for ECB
            sampleBytes, sampleLength,
            &encrypted, sampleLength,
            nil
        )
        guard status == kCCSuccess else {
            throw QUICCryptoError.aeadDecryptionFailed("AES-ECB failed: \(status)")
        }

        return Data(encrypted.prefix(5))
    }

    /// Applies header protection to a long header packet.
    ///
    /// - Parameters:
    ///   - packet: The packet data (header + encrypted payload)
    ///   - hpKey: Header protection key
    ///   - pnOffset: Offset of the packet number field in the packet
    ///   - pnLength: Length of the packet number field (1-4 bytes)
    /// - Returns: Protected packet
    public static func applyLongHeaderProtection(
        packet: inout Data,
        hpKey: Data,
        pnOffset: Int,
        pnLength: Int
    ) throws {
        let sampleStart = pnOffset + sampleOffset
        guard sampleStart + sampleLength <= packet.count else {
            throw QUICCryptoError.aeadDecryptionFailed("packet too short for HP sample")
        }

        let sample = Data(packet[packet.startIndex.advanced(by: sampleStart)..<packet.startIndex.advanced(by: sampleStart + sampleLength)])
        let mask = try self.mask(hpKey: hpKey, sample: sample)

        // Protect the first byte (clear the reserved + pn length bits)
        packet[packet.startIndex] ^= mask[0] & 0x0F

        // Protect the packet number bytes
        for i in 0..<pnLength {
            packet[packet.startIndex.advanced(by: pnOffset + i)] ^= mask[1 + i]
        }
    }

    /// Applies header protection to a short header packet.
    ///
    /// - Parameters:
    ///   - packet: The packet data
    ///   - hpKey: Header protection key
    ///   - pnOffset: Offset of the packet number field
    ///   - pnLength: Length of the packet number field (1-4 bytes)
    public static func applyShortHeaderProtection(
        packet: inout Data,
        hpKey: Data,
        pnOffset: Int,
        pnLength: Int
    ) throws {
        let sampleStart = pnOffset + sampleOffset
        guard sampleStart + sampleLength <= packet.count else {
            throw QUICCryptoError.aeadDecryptionFailed("packet too short for HP sample")
        }

        let sample = Data(packet[packet.startIndex.advanced(by: sampleStart)..<packet.startIndex.advanced(by: sampleStart + sampleLength)])
        let mask = try self.mask(hpKey: hpKey, sample: sample)

        // Protect the first byte (clear the reserved + pn length bits + spin + key phase)
        packet[packet.startIndex] ^= mask[0] & 0x1F

        // Protect the packet number bytes
        for i in 0..<pnLength {
            packet[packet.startIndex.advanced(by: pnOffset + i)] ^= mask[1 + i]
        }
    }

    /// Removes header protection from a long header packet.
    ///
    /// After calling this, the first byte and packet number are unprotected.
    /// Returns the packet number length.
    public static func removeLongHeaderProtection(
        packet: inout Data,
        hpKey: Data,
        pnOffset: Int
    ) throws -> Int {
        let sampleStart = pnOffset + sampleOffset
        guard sampleStart + sampleLength <= packet.count else {
            throw QUICCryptoError.aeadDecryptionFailed("packet too short for HP sample")
        }

        let sample = Data(packet[packet.startIndex.advanced(by: sampleStart)..<packet.startIndex.advanced(by: sampleStart + sampleLength)])
        let mask = try self.mask(hpKey: hpKey, sample: sample)

        // Unprotect the first byte
        packet[packet.startIndex] ^= mask[0] & 0x0F

        // Extract pn length from the unprotected first byte
        let pnLength = Int(packet[packet.startIndex] & 0x03) + 1

        // Unprotect the packet number
        for i in 0..<pnLength {
            guard pnOffset + i < packet.count else {
                throw QUICCryptoError.aeadDecryptionFailed("PN extends beyond packet")
            }
            packet[packet.startIndex.advanced(by: pnOffset + i)] ^= mask[1 + i]
        }

        return pnLength
    }

    /// Removes header protection from a short header packet.
    ///
    /// Returns the packet number length.
    public static func removeShortHeaderProtection(
        packet: inout Data,
        hpKey: Data,
        pnOffset: Int
    ) throws -> Int {
        let sampleStart = pnOffset + sampleOffset
        guard sampleStart + sampleLength <= packet.count else {
            throw QUICCryptoError.aeadDecryptionFailed("packet too short for HP sample")
        }

        let sample = Data(packet[packet.startIndex.advanced(by: sampleStart)..<packet.startIndex.advanced(by: sampleStart + sampleLength)])
        let mask = try self.mask(hpKey: hpKey, sample: sample)

        // Unprotect the first byte
        packet[packet.startIndex] ^= mask[0] & 0x1F

        // Extract pn length from the unprotected first byte
        let pnLength = Int(packet[packet.startIndex] & 0x03) + 1

        // Unprotect the packet number
        for i in 0..<pnLength {
            guard pnOffset + i < packet.count else {
                throw QUICCryptoError.aeadDecryptionFailed("PN extends beyond packet")
            }
            packet[packet.startIndex.advanced(by: pnOffset + i)] ^= mask[1 + i]
        }

        return pnLength
    }
}
