import Testing
import Foundation
import CryptoKit
@testable import PummelchenQuicCrypto
@testable import PummelchenQuicCore

// MARK: - HKDF Tests

struct HKDFTests {
    /// RFC 5869 Test Case 1
    @Test func hkdfExtractRfc5869() {
        let ikm = Data(repeating: 0x0b, count: 22)
        let salt = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c
        ])
        let expectedPRK = Data([
            0x07, 0x77, 0x09, 0x36, 0x2c, 0x2e, 0x32, 0xdf,
            0x0d, 0xdc, 0x3f, 0x0d, 0xc4, 0x7b, 0xba, 0x63,
            0x90, 0xb6, 0xc7, 0x3b, 0xb5, 0x0f, 0x9c, 0x31,
            0x22, 0xec, 0x84, 0x4a, 0xd7, 0xc2, 0xb3, 0xe5
        ])

        let prk = QUICHKDF.extract(salt: salt, inputKeyingMaterial: ikm)
        #expect(prk == expectedPRK)
    }

    @Test func hkdfExpandLabelFormat() {
        // Verify HKDF-Label encoding
        let label = QUICHKDF.buildHKDFLabel(label: "quic key", context: Data(), length: 16)
        // Length: 0x0010 (16)
        #expect(label[0] == 0x00)
        #expect(label[1] == 0x10)
        // Label length: 14 ("tls13 quic key".count = 14)
        #expect(label[2] == 14)
        // Label: "tls13 quic key"
        let labelStr = String(data: label[3..<17], encoding: .utf8)
        #expect(labelStr == "tls13 quic key")
        // Context length: 0
        #expect(label[17] == 0x00)
    }
}

// MARK: - RFC 9001 Appendix A Test Vectors

struct RFC9001InitialKeyTests {
    /// RFC 9001 Appendix A — Client Initial keys from DCID 0x8394c8f03e515708
    @Test func clientInitialKeysFromRfc9001() {
        let dcid = ConnectionID(Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let keys = InitialSecrets.clientInitialKeys(from: dcid)

        // Expected client initial secret = HKDF-Expand-Label(initial_secret, "client in", "", 32)
        let expectedClientSecret = Data([
            0xc0, 0x0c, 0xf1, 0x51, 0xca, 0x5b, 0xe0, 0x75,
            0xed, 0x0e, 0xbf, 0xb5, 0xc8, 0x03, 0x23, 0xc4,
            0x2d, 0x6b, 0x7d, 0xb6, 0x78, 0x81, 0x28, 0x9a,
            0xf4, 0x00, 0x8f, 0x1f, 0x6c, 0x35, 0x7a, 0xea
        ])

        // key = HKDF-Expand-Label(client_initial_secret, "quic key", "", 16)
        let expectedKey = Data([
            0x1f, 0x36, 0x96, 0x13, 0xdd, 0x76, 0xd5, 0x46,
            0x77, 0x30, 0xef, 0xcb, 0xe3, 0xb1, 0xa2, 0x2d
        ])

        // iv = HKDF-Expand-Label(client_initial_secret, "quic iv", "", 12)
        let expectedIV = Data([
            0xfa, 0x04, 0x4b, 0x2f, 0x42, 0xa3, 0xfd, 0x3b,
            0x46, 0xfb, 0x25, 0x5c
        ])

        // hp = HKDF-Expand-Label(client_initial_secret, "quic hp", "", 16)
        let expectedHP = Data([
            0x9f, 0x50, 0x44, 0x9e, 0x04, 0xa0, 0xe8, 0x10,
            0x28, 0x3a, 0x1e, 0x99, 0x33, 0xad, 0xed, 0xd2
        ])

        #expect(keys.secret == expectedClientSecret, "Client initial secret mismatch")
        #expect(keys.key == expectedKey, "Client key mismatch")
        #expect(keys.iv == expectedIV, "Client IV mismatch")
        #expect(keys.hpKey == expectedHP, "Client HP key mismatch")
    }

    /// RFC 9001 Appendix A — Server Initial keys from DCID 0x8394c8f03e515708
    @Test func serverInitialKeysFromRfc9001() {
        let dcid = ConnectionID(Data([0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08]))
        let keys = InitialSecrets.serverInitialKeys(from: dcid)

        // server_initial_secret = HKDF-Expand-Label(initial_secret, "server in", "", 32)
        let expectedServerSecret = Data([
            0x3c, 0x19, 0x98, 0x28, 0xfd, 0x13, 0x9e, 0xfd,
            0x21, 0x6c, 0x15, 0x5a, 0xd8, 0x44, 0xcc, 0x81,
            0xfb, 0x82, 0xfa, 0x8d, 0x74, 0x46, 0xfa, 0x7d,
            0x78, 0xbe, 0x80, 0x3a, 0xcd, 0xda, 0x95, 0x1b
        ])

        // key = HKDF-Expand-Label(server_initial_secret, "quic key", "", 16)
        let expectedKey = Data([
            0xcf, 0x3a, 0x53, 0x31, 0x65, 0x3c, 0x36, 0x4c,
            0x88, 0xf0, 0xf3, 0x79, 0xb6, 0x06, 0x7e, 0x37
        ])

        // iv = HKDF-Expand-Label(server_initial_secret, "quic iv", "", 12)
        let expectedIV = Data([
            0x0a, 0xc1, 0x49, 0x3c, 0xa1, 0x90, 0x58, 0x53,
            0xb0, 0xbb, 0xa0, 0x3e
        ])

        // hp = HKDF-Expand-Label(server_initial_secret, "quic hp", "", 16)
        let expectedHP = Data([
            0xc2, 0x06, 0xb8, 0xd9, 0xb9, 0xf0, 0xf3, 0x76,
            0x44, 0x43, 0x0b, 0x49, 0x0e, 0xea, 0xa3, 0x14
        ])

        #expect(keys.secret == expectedServerSecret, "Server initial secret mismatch")
        #expect(keys.key == expectedKey, "Server key mismatch")
        #expect(keys.iv == expectedIV, "Server IV mismatch")
        #expect(keys.hpKey == expectedHP, "Server HP key mismatch")
    }
}

// MARK: - AEAD Tests

struct AEADTests {
    @Test func aeadRoundTrip() throws {
        let keySym = SymmetricKey(size: .bits128)
        let key = keySym.withUnsafeBytes { Data($0) }
        let ivSym = SymmetricKey(size: .bits128)
        let iv = Data(ivSym.withUnsafeBytes { Data($0).prefix(12) })
        let plaintext = Data("Hello, QUIC world!".utf8)
        let aad = Data("header data".utf8)
        let pn: UInt64 = 42

        let ciphertext = try QUICAEAD.seal(plaintext: plaintext, aad: aad, key: key, iv: iv, packetNumber: pn)
        #expect(ciphertext.count == plaintext.count + 16) // 16 byte tag

        let decrypted = try QUICAEAD.open(ciphertext: ciphertext, aad: aad, key: key, iv: iv, packetNumber: pn)
        #expect(decrypted == plaintext)
    }

    @Test func aeadWrongPacketNumberFails() throws {
        let keySym = SymmetricKey(size: .bits128)
        let key = keySym.withUnsafeBytes { Data($0) }
        let ivSym = SymmetricKey(size: .bits128)
        let iv = Data(ivSym.withUnsafeBytes { Data($0).prefix(12) })
        let plaintext = Data("test".utf8)
        let aad = Data("header".utf8)

        let ciphertext = try QUICAEAD.seal(plaintext: plaintext, aad: aad, key: key, iv: iv, packetNumber: 1)
        #expect(throws: Error.self) {
            _ = try QUICAEAD.open(ciphertext: ciphertext, aad: aad, key: key, iv: iv, packetNumber: 2)
        }
    }

    @Test func nonceConstruction() {
        let iv = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b])
        let pn: UInt64 = 1

        let nonce = QUICAEAD.makeNonce(iv: iv, packetNumber: pn)
        #expect(nonce.count == 12)
        // Last byte should be XORed with 1
        #expect(nonce[11] == 0x0b ^ 0x01)
        // First 4 bytes unchanged
        #expect(nonce[0] == 0x00)
    }
}

// MARK: - Header Protection Tests

struct HeaderProtectionTests {
    @Test func hpMaskDeterministic() throws {
        let hpKey = Data(repeating: 0xab, count: 16)
        let sample = Data(repeating: 0xcd, count: 16)

        let mask1 = try HeaderProtection.mask(hpKey: hpKey, sample: sample)
        let mask2 = try HeaderProtection.mask(hpKey: hpKey, sample: sample)
        #expect(mask1 == mask2)
        #expect(mask1.count == 5)
    }

    @Test func longHeaderProtectionRoundTrip() throws {
        let hpKeySym = SymmetricKey(size: .bits128)
        let hpKey = hpKeySym.withUnsafeBytes { Data($0) }

        // Build a fake packet with enough payload for the HP sample
        var packet = Data(repeating: 0, count: 80)
        // Long header first byte with pn_length=2 encoded (bits 0-1 = 01)
        packet[0] = 0xC1 // 0xC0 | (2-1) = 0xC1
        let pnOffset = 30
        let pnLength = 2

        // Write some PN bytes
        packet[pnOffset] = 0x12
        packet[pnOffset + 1] = 0x34

        // Fill sample area (pnOffset + 4 .. pnOffset + 20) with non-zero data
        for i in 0..<16 {
            packet[pnOffset + 4 + i] = UInt8(i + 1)
        }

        let originalFirstByte = packet[0]
        let originalPN0 = packet[pnOffset]
        let originalPN1 = packet[pnOffset + 1]

        try HeaderProtection.applyLongHeaderProtection(
            packet: &packet, hpKey: hpKey, pnOffset: pnOffset, pnLength: pnLength
        )

        // At least one byte should have changed
        let changed = packet[0] != originalFirstByte ||
                      packet[pnOffset] != originalPN0 ||
                      packet[pnOffset + 1] != originalPN1
        #expect(changed)

        // Now remove it
        let recoveredPnLength = try HeaderProtection.removeLongHeaderProtection(
            packet: &packet, hpKey: hpKey, pnOffset: pnOffset
        )

        #expect(recoveredPnLength == pnLength)
        #expect(packet[0] == originalFirstByte)
        #expect(packet[pnOffset] == originalPN0)
        #expect(packet[pnOffset + 1] == originalPN1)
    }
}

// MARK: - Key Update Tests

struct KeyUpdateTests {
    @Test func keyRotationProducesDifferentKeys() {
        let secret = Data(repeating: 0x42, count: 32)
        let keys = EncryptionKeys.fromTrafficSecret(secret)
        let rotated = KeyUpdate.rotate(keys: keys)

        #expect(rotated.key != keys.key)
        #expect(rotated.iv != keys.iv)
        #expect(rotated.hpKey != keys.hpKey)
        #expect(rotated.secret != keys.secret)
    }
}
