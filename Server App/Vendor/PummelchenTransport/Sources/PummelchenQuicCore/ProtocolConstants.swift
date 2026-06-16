/// QUIC Protocol Constants
///
/// Version numbers, limits, and fixed values from RFC 9000.

import Foundation

/// QUIC version
public struct QUICVersion: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    /// QUIC v1 (RFC 9000)
    public static let v1 = QUICVersion(rawValue: 0x0000_0001)

    public var description: String {
        String(format: "0x%08x", rawValue)
    }
}

/// Protocol limits from RFC 9000
public enum ProtocolLimits {
    /// Minimum QUIC UDP payload size (RFC 9000 §14)
    public static let minimumMaximumDatagramSize = 1200

    /// Maximum connection ID length (RFC 9000 §5.1)
    public static let maxConnectionIDLength = 20

    /// Maximum packet number space (2^31 - 1)
    public static let maxPacketNumber: UInt64 = (1 << 31) - 1

    /// Maximum stream ID (2^62 - 1)
    public static let maxStreamID: UInt64 = Varint.maxValue

    /// Minimum Initial packet size (RFC 9000 §14.1)
    public static let minimumInitialPacketSize = 1200
}

/// Encryption levels used by QUIC (RFC 9001)
public enum EncryptionLevel: Int, Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case initial = 0
    case handshake = 2
    case application = 3

    public var description: String {
        switch self {
        case .initial: return "Initial"
        case .handshake: return "Handshake"
        case .application: return "Application"
        }
    }
}

/// Stream type identifiers (RFC 9000 §2.1)
public enum StreamIDType {
    /// Client-initiated bidirectional (stream ID % 4 == 0)
    public static func isClientBidi(_ id: UInt64) -> Bool { id & 0x03 == 0 }

    /// Server-initiated bidirectional (stream ID % 4 == 1)
    public static func isServerBidi(_ id: UInt64) -> Bool { id & 0x03 == 1 }

    /// Client-initiated unidirectional (stream ID % 4 == 2)
    public static func isClientUni(_ id: UInt64) -> Bool { id & 0x03 == 2 }

    /// Server-initiated unidirectional (stream ID % 4 == 3)
    public static func isServerUni(_ id: UInt64) -> Bool { id & 0x03 == 3 }
}
