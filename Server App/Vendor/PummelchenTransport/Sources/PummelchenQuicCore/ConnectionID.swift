/// QUIC Connection ID (RFC 9000 Section 5.1)
///
/// 0-20 byte opaque identifier used to route packets to connections.

import Foundation

/// QUIC connection ID (0-20 bytes)
public struct ConnectionID: Hashable, Sendable {
    /// The raw bytes
    public let bytes: Data

    /// Maximum allowed length (RFC 9000 §5.1)
    public static let maxLength = 20

    /// Creates a connection ID from raw bytes.
    public init(_ bytes: Data) {
        precondition(bytes.count <= Self.maxLength, "ConnectionID exceeds 20 bytes")
        self.bytes = bytes
    }

    /// Creates a connection ID of the given length with random bytes.
    public static func random(length: Int = 8) -> ConnectionID {
        precondition(length >= 0 && length <= maxLength)
        var data = Data(count: length)
        data.withUnsafeMutableBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<length {
                ptr[i] = UInt8.random(in: 0...255)
            }
        }
        return ConnectionID(data)
    }

    /// The length in bytes
    public var length: Int { bytes.count }

    /// Whether this is an empty (zero-length) connection ID
    public var isEmpty: Bool { bytes.isEmpty }
}

// MARK: - Conformances

extension ConnectionID: CustomStringConvertible {
    public var description: String {
        "CID(\(bytes.map { String(format: "%02x", $0) }.joined()))"
    }
}

extension ConnectionID: CustomDebugStringConvertible {
    public var debugDescription: String { description }
}
