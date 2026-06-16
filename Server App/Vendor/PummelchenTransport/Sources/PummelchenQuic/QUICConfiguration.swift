/// QUIC Configuration & Endpoint (Quiver-compatible API)
///
/// High-level QUIC configuration and endpoint types that provide
/// the same API surface as the Quiver library.

import Foundation
import PummelchenQuicCore
import PummelchenQuicCrypto

// MARK: - QUIC Configuration

/// QUIC connection configuration.
public final class QUICConfiguration: @unchecked Sendable {
    /// ALPN protocols
    public var alpn: [String] = ["h3"]

    /// Maximum idle timeout
    public var maxIdleTimeout: Duration = .seconds(30)

    /// Maximum bidirectional streams
    public var initialMaxStreamsBidi: UInt64 = 100

    /// Maximum unidirectional streams
    public var initialMaxStreamsUni: UInt64 = 100

    /// Maximum data
    public var initialMaxData: UInt64 = 10_000_000

    /// Maximum stream data (bidi local)
    public var initialMaxStreamDataBidiLocal: UInt64 = 1_000_000

    /// Maximum stream data (bidi remote)
    public var initialMaxStreamDataBidiRemote: UInt64 = 1_000_000

    /// Maximum stream data (uni)
    public var initialMaxStreamDataUni: UInt64 = 1_000_000

    /// Enable datagrams
    public var enableDatagrams: Bool = false

    /// Maximum datagram frame size
    public var maxDatagramFrameSize: UInt64 = 0

    /// TLS handler factory
    public let tlsHandlerFactory: @Sendable () -> TLSHandler

    public init(tlsHandlerFactory: @escaping @Sendable () -> TLSHandler) {
        self.tlsHandlerFactory = tlsHandlerFactory
    }

    /// Production configuration with a TLS handler factory.
    public static func production(_ tlsHandlerFactory: @escaping @Sendable () -> TLSHandler) -> QUICConfiguration {
        let config = QUICConfiguration(tlsHandlerFactory: tlsHandlerFactory)
        config.alpn = ["h3"]
        config.maxIdleTimeout = .seconds(30)
        config.initialMaxStreamsBidi = 100
        config.initialMaxStreamsUni = 100
        config.initialMaxData = 10_000_000
        return config
    }
}

// MARK: - QUIC Socket Address (namespace alias)

/// QUIC namespace for Quiver-compatible types.
public enum QUIC {
    /// Socket address — type alias for PummelchenQuicCore.SocketAddress.
    public typealias SocketAddress = PummelchenQuicCore.SocketAddress
}

// MARK: - QUIC Connection Protocol

/// Protocol for a QUIC connection.
public protocol QUICConnectionProtocol: AnyObject, Sendable {
    /// Close the connection.
    func close(error: UInt64?) async
}

// MARK: - QUIC Endpoint Errors

/// QUIC endpoint errors.
public enum QUICEndpointError: Error, Sendable {
    case stopped
    case connectionFailed(String)
    case timeout
}
