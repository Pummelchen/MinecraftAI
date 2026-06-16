/// QUIC Variable-Length Integer Encoding (RFC 9000 Section 16)
///
/// Two most significant bits indicate length:
/// ```
/// 2MSB = 00: 6-bit  (1 byte,  max 63)
/// 2MSB = 01: 14-bit (2 bytes, max 16383)
/// 2MSB = 10: 30-bit (4 bytes, max 1073741823)
/// 2MSB = 11: 62-bit (8 bytes, max 4611686018427387903)
/// ```

import Foundation

/// QUIC variable-length integer (0 to 2^62 - 1)
public struct Varint: Hashable, Sendable {
    /// The decoded value
    public let value: UInt64

    /// Maximum representable value (2^62 - 1)
    public static let maxValue: UInt64 = (1 << 62) - 1

    /// Creates a Varint from a UInt64 value.
    @inlinable
    public init(_ value: UInt64) {
        precondition(value <= Self.maxValue, "Varint exceeds maximum (2^62 - 1)")
        self.value = value
    }

    /// Creates a Varint from any BinaryInteger.
    @inlinable
    public init<T: BinaryInteger>(_ value: T) {
        self.init(UInt64(value))
    }

    /// Minimum bytes needed to encode this value.
    public var encodedLength: Int {
        if value <= 63 { return 1 }
        else if value <= 16_383 { return 2 }
        else if value <= 1_073_741_823 { return 4 }
        else { return 8 }
    }
}

// MARK: - Encoding

extension Varint {
    /// Encodes the varint to bytes.
    public func encode() -> Data {
        var data = Data(capacity: encodedLength)
        encode(to: &data)
        return data
    }

    /// Appends the varint encoding to the given Data.
    @inlinable
    public func encode(to data: inout Data) {
        if value <= 63 {
            data.append(UInt8(value))
        } else if value <= 16_383 {
            data.append(UInt8(0x40 | (value >> 8)))
            data.append(UInt8(value & 0xFF))
        } else if value <= 1_073_741_823 {
            data.append(UInt8(0x80 | (value >> 24)))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        } else {
            data.append(UInt8(0xC0 | (value >> 56)))
            data.append(UInt8((value >> 48) & 0xFF))
            data.append(UInt8((value >> 40) & 0xFF))
            data.append(UInt8((value >> 32) & 0xFF))
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
    }
}

// MARK: - Decoding

extension Varint {
    public enum DecodeError: Error, Sendable {
        case insufficientData
        case invalidFormat
    }

    /// Decodes a varint from the start of Data.
    /// - Returns: (Varint, bytes consumed)
    @inlinable
    public static func decode(from data: Data) throws -> (Varint, Int) {
        return try data.withUnsafeBytes { buffer -> (Varint, Int) in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  buffer.count > 0 else {
                throw DecodeError.insufficientData
            }

            let firstByte = ptr[0]
            let prefix = firstByte >> 6
            let length: Int
            switch prefix {
            case 0b00: length = 1
            case 0b01: length = 2
            case 0b10: length = 4
            case 0b11: length = 8
            default: fatalError("Unreachable")
            }

            guard buffer.count >= length else {
                throw DecodeError.insufficientData
            }

            let value: UInt64
            switch length {
            case 1:
                value = UInt64(firstByte & 0x3F)
            case 2:
                value = UInt64(firstByte & 0x3F) << 8
                    | UInt64(ptr[1])
            case 4:
                value = UInt64(firstByte & 0x3F) << 24
                    | UInt64(ptr[1]) << 16
                    | UInt64(ptr[2]) << 8
                    | UInt64(ptr[3])
            case 8:
                value = UInt64(firstByte & 0x3F) << 56
                    | UInt64(ptr[1]) << 48
                    | UInt64(ptr[2]) << 40
                    | UInt64(ptr[3]) << 32
                    | UInt64(ptr[4]) << 24
                    | UInt64(ptr[5]) << 16
                    | UInt64(ptr[6]) << 8
                    | UInt64(ptr[7])
            default:
                fatalError("Unreachable")
            }

            return (Varint(value), length)
        }
    }

    /// Returns the encoded length for the first varint in the data without fully decoding.
    public static func peekEncodedLength(from data: Data) -> Int? {
        guard let firstByte = data.first else { return nil }
        switch firstByte >> 6 {
        case 0b00: return 1
        case 0b01: return 2
        case 0b10: return 4
        case 0b11: return 8
        default: return nil
        }
    }

    /// Returns the encoded length for a given value without creating a Varint.
    @inlinable
    public static func encodedLength(for value: UInt64) -> Int {
        if value <= 63 { return 1 }
        else if value <= 16_383 { return 2 }
        else if value <= 1_073_741_823 { return 4 }
        else { return 8 }
    }
}

// MARK: - Conformances

extension Varint: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(value)
    }
}

extension Varint: CustomStringConvertible {
    public var description: String { "Varint(\(value))" }
}

extension Varint: Comparable {
    public static func < (lhs: Varint, rhs: Varint) -> Bool {
        lhs.value < rhs.value
    }
}
