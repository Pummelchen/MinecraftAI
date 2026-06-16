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

// MARK: - POSIX sockaddr Conversion

extension SocketAddress {
    /// Converts to a `sockaddr_in` for use with POSIX socket APIs.
    public func sockaddr() -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(ipAddress)
        return addr
    }

    /// Creates from a `sockaddr_in`.
    public init(from addr: sockaddr_in) {
        let port = UInt16(bigEndian: addr.sin_port)
        var mutableAddr = addr
        var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &mutableAddr.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: ipBuffer)
        self.init(ipAddress: ip, port: port)
    }
}
