/// PEM File Loader + X.509 Certificate + Signing Key
///
/// Quiver-compatible API for loading PEM certificates/keys
/// and parsing X.509 certificates using Security.framework + CryptoKit.

import Foundation
import CryptoKit
import Security

// MARK: - Signing Key

/// Signing key types supported for TLS operations.
public enum SigningKey: Sendable {
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)
}

/// Public key extracted from an X.509 certificate.
public enum ExtractedPublicKey: Sendable {
    case p256(P256.Signing.PublicKey)
    case p384(P384.Signing.PublicKey)
    case ed25519(Curve25519.Signing.PublicKey)
}

// MARK: - PEM Loader

/// Utility for loading PEM-encoded certificates and private keys.
public enum PEMLoader {

    public enum PEMError: Error, Sendable {
        case fileNotFound(String)
        case readError(String)
        case invalidPEMFormat(String)
        case noPEMBlockFound(String)
        case base64DecodingFailed
        case unsupportedKeyType(String)
        case invalidKeyFormat(String)
        case asn1ParsingError(String)
    }

    /// Load certificates from a PEM file.
    /// - Parameter path: Path to the PEM file
    /// - Returns: Array of DER-encoded certificates
    public static func loadCertificates(fromPath path: String) throws -> [Data] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw PEMError.fileNotFound(path)
        }
        let content: String
        do {
            content = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PEMError.readError("Failed to read file at \(path): \(error)")
        }
        return try parsePEMBlocks(content, type: "CERTIFICATE")
    }

    /// Load a private key from a PEM file.
    public static func loadPrivateKey(fromPath path: String) throws -> SigningKey {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw PEMError.fileNotFound(path)
        }
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parsePrivateKey(from: content)
    }

    /// Parse a private key from PEM string.
    public static func parsePrivateKey(from pemString: String) throws -> SigningKey {
        // Try PKCS#8 first
        if let derData = try? parsePEMBlocks(pemString, type: "PRIVATE KEY").first {
            return try parsePrivateKeyFromPKCS8(derData)
        }
        // Try EC PRIVATE KEY
        if let derData = try? parsePEMBlocks(pemString, type: "EC PRIVATE KEY").first {
            return try parseECPrivateKeyFromSEC1(derData)
        }
        throw PEMError.noPEMBlockFound("PRIVATE KEY")
    }

    // MARK: - PEM Parsing

    private static func parsePEMBlocks(_ content: String, type: String) throws -> [Data] {
        let beginMarker = "-----BEGIN \(type)-----"
        let endMarker = "-----END \(type)-----"

        var results: [Data] = []
        var searchRange = content.startIndex..<content.endIndex

        while let beginRange = content.range(of: beginMarker, range: searchRange) {
            guard let endRange = content.range(of: endMarker, range: beginRange.upperBound..<content.endIndex) else {
                throw PEMError.invalidPEMFormat("Missing end marker for \(type)")
            }
            let base64Content = content[beginRange.upperBound..<endRange.lowerBound]
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")

            guard let derData = Data(base64Encoded: base64Content) else {
                throw PEMError.base64DecodingFailed
            }
            results.append(derData)
            searchRange = endRange.upperBound..<content.endIndex
        }

        if results.isEmpty {
            throw PEMError.noPEMBlockFound(type)
        }
        return results
    }

    // MARK: - PKCS#8 Parsing

    private static func parsePrivateKeyFromPKCS8(_ derData: Data) throws -> SigningKey {
        var index = 0
        guard derData.count > 2, derData[index] == 0x30 else {
            throw PEMError.asn1ParsingError("Expected SEQUENCE")
        }
        index += 1
        let (_, lengthBytes) = try parseASN1Length(derData, at: index)
        index += lengthBytes

        // Skip version INTEGER
        guard derData[index] == 0x02 else {
            throw PEMError.asn1ParsingError("Expected INTEGER for version")
        }
        index += 1
        let versionLength = Int(derData[index])
        index += 1 + versionLength

        // Parse AlgorithmIdentifier SEQUENCE
        guard derData[index] == 0x30 else {
            throw PEMError.asn1ParsingError("Expected SEQUENCE for AlgorithmIdentifier")
        }
        index += 1
        let (_, algLengthBytes) = try parseASN1Length(derData, at: index)
        index += algLengthBytes

        // Parse algorithm OID
        guard derData[index] == 0x06 else {
            throw PEMError.asn1ParsingError("Expected OBJECT IDENTIFIER")
        }
        index += 1
        let oidLength = Int(derData[index])
        index += 1
        let oidBytes = Array(derData[index..<(index + oidLength)])
        index += oidLength

        let keyType = try determineKeyType(fromOID: oidBytes)

        // Skip remaining alg params — scan forward for OCTET STRING
        while index < derData.count && derData[index] != 0x04 {
            index += 1
        }

        guard index < derData.count, derData[index] == 0x04 else {
            throw PEMError.asn1ParsingError("Expected OCTET STRING for private key")
        }
        index += 1
        let (privateKeyLength, pkLengthBytes) = try parseASN1Length(derData, at: index)
        index += pkLengthBytes

        let privateKeyData = Data(derData[index..<(index + privateKeyLength)])
        return try createSigningKey(from: privateKeyData, type: keyType)
    }

    private static func parseECPrivateKeyFromSEC1(_ derData: Data) throws -> SigningKey {
        var index = 0
        guard derData[index] == 0x30 else {
            throw PEMError.asn1ParsingError("Expected SEQUENCE")
        }
        index += 1
        let (_, lengthBytes) = try parseASN1Length(derData, at: index)
        index += lengthBytes

        // Skip version
        guard derData[index] == 0x02 else {
            throw PEMError.asn1ParsingError("Expected INTEGER for version")
        }
        index += 1
        let versionLength = Int(derData[index])
        index += 1 + versionLength

        // Parse privateKey OCTET STRING
        guard derData[index] == 0x04 else {
            throw PEMError.asn1ParsingError("Expected OCTET STRING for private key")
        }
        index += 1
        let privateKeyLength = Int(derData[index])
        index += 1
        let rawPrivateKey = Data(derData[index..<(index + privateKeyLength)])

        // Determine key type from length
        if rawPrivateKey.count == 32 {
            // Could be P-256 or Ed25519; try P-256 first
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey) {
                return .p256(key)
            }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
            return .ed25519(key)
        } else if rawPrivateKey.count == 48 {
            let key = try P384.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
            return .p384(key)
        }

        // Try P-256 as default
        let key = try P256.Signing.PrivateKey(rawRepresentation: rawPrivateKey)
        return .p256(key)
    }

    // MARK: - ASN.1 Helpers

    private static func parseASN1Length(_ data: Data, at offset: Int) throws -> (Int, Int) {
        guard offset < data.count else {
            throw PEMError.asn1ParsingError("Unexpected end of data")
        }
        let firstByte = data[offset]
        if firstByte & 0x80 == 0 {
            return (Int(firstByte), 1)
        } else {
            let numLengthBytes = Int(firstByte & 0x7F)
            guard offset + 1 + numLengthBytes <= data.count else {
                throw PEMError.asn1ParsingError("Length extends beyond data")
            }
            var length = 0
            for i in 0..<numLengthBytes {
                length = (length << 8) | Int(data[offset + 1 + i])
            }
            return (length, 1 + numLengthBytes)
        }
    }

    private enum KeyType { case p256, p384, ed25519 }

    private static func determineKeyType(fromOID oidBytes: [UInt8]) throws -> KeyType {
        // id-Ed25519: 1.3.101.112
        if oidBytes == [0x2B, 0x65, 0x70] { return .ed25519 }
        // id-ecPublicKey: 1.2.840.10045.2.1
        if oidBytes == [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] { return .p256 }
        throw PEMError.unsupportedKeyType("Unknown key algorithm OID: \(oidBytes.map { String(format: "%02X", $0) }.joined())")
    }

    private static func createSigningKey(from data: Data, type: KeyType) throws -> SigningKey {
        switch type {
        case .ed25519:
            let rawKey = try extractEd25519RawKey(from: data)
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey))
        case .p256:
            return try .p256(P256.Signing.PrivateKey(rawRepresentation: data))
        case .p384:
            return try .p384(P384.Signing.PrivateKey(rawRepresentation: data))
        }
    }

    private static func extractEd25519RawKey(from data: Data) throws -> Data {
        var index = 0
        if data.count > 2 && data[index] == 0x04 {
            index += 1
            let length = Int(data[index])
            index += 1
            if length == 32 && index + 32 <= data.count {
                return Data(data[index..<(index + 32)])
            }
            if data[index] == 0x04 {
                index += 1
                let innerLength = Int(data[index])
                index += 1
                if innerLength == 32 && index + 32 <= data.count {
                    return Data(data[index..<(index + 32)])
                }
            }
        }
        if data.count == 32 { return data }
        throw PEMError.invalidKeyFormat("Could not extract Ed25519 raw key")
    }
}

// MARK: - X.509 Certificate

/// A parsed X.509 certificate.
public struct X509Certificate: Sendable {
    /// DER-encoded certificate data
    public let derEncoded: Data

    /// The SecCertificate reference (macOS/iOS)
    public let secCertificate: SecCertificate

    /// Parse from DER-encoded data.
    public static func parse(from data: Data) throws -> X509Certificate {
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            throw PEMLoader.PEMError.asn1ParsingError("Failed to parse X.509 certificate")
        }
        return X509Certificate(derEncoded: data, secCertificate: cert)
    }

    /// Extract the public key from this certificate.
    public func extractPublicKey() throws -> ExtractedPublicKey {
        guard let secKey = SecCertificateCopyKey(secCertificate) else {
            throw PEMLoader.PEMError.asn1ParsingError("Failed to extract public key from certificate")
        }

        guard let attributes = SecKeyCopyAttributes(secKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String] as? String,
              let keySize = attributes[kSecAttrKeySizeInBits as String] as? Int else {
            throw PEMLoader.PEMError.asn1ParsingError("Failed to read key attributes")
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(secKey, nil) as Data? else {
            throw PEMLoader.PEMError.asn1ParsingError("Failed to export public key")
        }

        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            switch keySize {
            case 256:
                // x963 representation = 04 || X || Y (uncompressed point)
                return .p256(try P256.Signing.PublicKey(x963Representation: publicKeyData))
            case 384:
                return .p384(try P384.Signing.PublicKey(x963Representation: publicKeyData))
            default:
                throw PEMLoader.PEMError.unsupportedKeyType("Unsupported EC key size: \(keySize)")
            }
        } else if keyType == "com.apple.crypto.ed25519" {
            return .ed25519(try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData))
        }

        throw PEMLoader.PEMError.unsupportedKeyType("Unsupported key type: \(keyType)")
    }
}
