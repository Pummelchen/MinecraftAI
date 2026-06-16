/// QUIC Transport Error Codes (RFC 9000 Section 20)

import Foundation

/// QUIC transport error codes
public enum QUICErrorCode: UInt64, Sendable {
    case noError = 0x00
    case internalError = 0x01
    case connectionRefused = 0x02
    case flowControlError = 0x03
    case streamLimitError = 0x04
    case streamStateError = 0x05
    case finalSizeError = 0x06
    case frameEncodingError = 0x07
    case transportParameterError = 0x08
    case connectionIDLimitError = 0x09
    case protocolViolation = 0x0a
    case invalidToken = 0x0b
    case applicationError = 0x0c
    case cryptoBufferExceeded = 0x0d
    case keyUpdateError = 0x0e
    case aeadLimitReached = 0x0f
    case noViablePath = 0x10

    /// TLS alert errors (0x0100 + alert description)
    /// Range: 0x0100 to 0x01ff
    public static func tlsAlert(_ alert: UInt8) -> UInt64 {
        return 0x0100 + UInt64(alert)
    }
}

/// QUIC error type
public enum QUICError: Error, Sendable, CustomStringConvertible {
    case transport(QUICErrorCode, reason: String = "")
    case application(code: UInt64, reason: String = "")
    case tls(code: UInt8, reason: String = "")
    case connectionClosed
    case idleTimeout
    case handshakeFailed(String)
    case streamReset(streamID: UInt64, errorCode: UInt64)
    case peerClosed(errorCode: UInt64, reason: String)

    public var description: String {
        switch self {
        case .transport(let code, let reason):
            return "QUIC transport error: \(code)\(reason.isEmpty ? "" : " (\(reason))")"
        case .application(let code, let reason):
            return "QUIC application error: \(code)\(reason.isEmpty ? "" : " (\(reason))")"
        case .tls(let code, let reason):
            return "TLS alert: \(code)\(reason.isEmpty ? "" : " (\(reason))")"
        case .connectionClosed:
            return "QUIC connection closed"
        case .idleTimeout:
            return "QUIC idle timeout"
        case .handshakeFailed(let reason):
            return "QUIC handshake failed: \(reason)"
        case .streamReset(let streamID, let errorCode):
            return "Stream \(streamID) reset with error \(errorCode)"
        case .peerClosed(let code, let reason):
            return "Peer closed connection: \(code)\(reason.isEmpty ? "" : " (\(reason))")"
        }
    }
}
