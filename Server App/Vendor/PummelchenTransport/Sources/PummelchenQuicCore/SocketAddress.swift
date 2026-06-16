/// Network socket address for QUIC endpoints.
///
/// IPv4/IPv6 address + port. No NIO dependency — pure value type.

import Foundation

/// A network socket address (IP + port)
public struct SocketAddress: Sendable, Hashable {
    /// The IP address string
    public let ipAddress: String

    /// The port number
    public let port: UInt16

    /// Creates a socket address.
    public init(ipAddress: String, port: UInt16) {
        self.ipAddress = ipAddress
        self.port = port
    }

    /// Parses a string like "192.168.1.1:8080" or "[::1]:8080".
    public init?(string: String) {
        // Handle IPv6 in brackets
        if string.hasPrefix("[") {
            guard let closeBracket = string.firstIndex(of: "]"),
                  let colonIndex = string[string.index(after: closeBracket)...].firstIndex(of: ":"),
                  let port = UInt16(string[string.index(after: colonIndex)...]) else {
                return nil
            }
            let ip = String(string[string.index(after: string.startIndex)..<closeBracket])
            self.ipAddress = ip
            self.port = port
        } else {
            let parts = string.split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1]) else {
                return nil
            }
            self.ipAddress = String(parts[0])
            self.port = port
        }
    }
}

extension SocketAddress: CustomStringConvertible {
    public var description: String {
        "\(ipAddress):\(port)"
    }
}
