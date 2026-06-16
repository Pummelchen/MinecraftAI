/// QUIC UDP Transport (RFC 9000 §5.2)
///
/// POSIX sockets with DispatchSource for asynchronous UDP I/O.
/// Handles packet sending and receiving for QUIC connections.

import Foundation
import Dispatch
import PummelchenQuicCore
import PummelchenQuicCrypto

// MARK: - UDP Datagram

/// A UDP datagram with source address.
public struct UDPDatagram: Sendable {
    public let data: Data
    public let source: SocketAddress

    public init(data: Data, source: SocketAddress) {
        self.data = data
        self.source = source
    }
}

// MARK: - UDP Socket

/// Low-level UDP socket wrapper using POSIX APIs.
public final class UDPSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue: DispatchQueue

    /// Called when a datagram is received.
    public var onReceive: ((UDPDatagram) -> Void)?

    public init(queue: DispatchQueue = .global(qos: .userInitiated)) {
        self.queue = queue
    }

    deinit {
        close()
    }

    /// Bind to the specified address and port.
    public func bind(to address: SocketAddress) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            throw UDPError.socketCreationFailed(errno)
        }

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Allow address reuse
        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Set receive buffer size
        var rcvBufSize: Int32 = 4 * 1024 * 1024 // 4MB
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBufSize, socklen_t(MemoryLayout<Int32>.size))

        var addr = address.sockaddr()
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(fd)
            fd = -1
            throw UDPError.bindFailed(err)
        }

        // Set up dispatch source for reading
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource?.setEventHandler { [weak self] in
            self?.readAvailable()
        }
    }

    /// Start listening for incoming datagrams.
    public func startListening() {
        readSource?.resume()
    }

    /// Stop listening.
    public func stopListening() {
        readSource?.suspend()
    }

    /// Send a datagram to the specified address.
    public func send(data: Data, to address: SocketAddress) throws {
        guard fd >= 0 else { throw UDPError.notBound }

        var addr = address.sockaddr()
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                data.withUnsafeBytes { bufPtr in
                    Darwin.sendto(fd, bufPtr.baseAddress, data.count, 0, saPtr,
                                  socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard result >= 0 else {
            throw UDPError.sendFailed(errno)
        }
    }

    /// Close the socket.
    public func close() {
        readSource?.cancel()
        readSource = nil
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    /// Whether the socket is bound.
    public var isBound: Bool { fd >= 0 }

    // MARK: - Private

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var addr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let bytesRead = withUnsafeMutablePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.recvfrom(fd, &buffer, buffer.count, 0, saPtr, &addrLen)
            }
        }

        guard bytesRead > 0 else { return }

        let data = Data(buffer.prefix(bytesRead))
        let source = SocketAddress(from: addr)
        let datagram = UDPDatagram(data: data, source: source)
        onReceive?(datagram)
    }
}

// MARK: - UDP Errors

/// UDP transport errors.
public enum UDPError: Error, Sendable {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case sendFailed(Int32)
    case notBound
}

// MARK: - QUIC Endpoint

/// A QUIC endpoint that manages multiple connections over a single UDP socket.
public final class QUICEndpoint: @unchecked Sendable {
    /// The UDP socket
    private let socket: UDPSocket

    /// Active connections indexed by destination connection ID
    private var connections: [ConnectionID: QUICConnection] = [:]

    /// Whether this is a server endpoint
    private let isServer: Bool

    /// Called when a new connection is accepted (server mode)
    public var onNewConnection: ((QUICConnection) -> Void)?

    public init(isServer: Bool = false) {
        self.socket = UDPSocket()
        self.isServer = isServer
    }

    /// Bind to a local address and start listening.
    public func bind(host: String, port: UInt16) throws {
        let addr = SocketAddress(ipAddress: host, port: port)
        try socket.bind(to: addr)

        socket.onReceive = { [weak self] datagram in
            self?.handleDatagram(datagram)
        }

        socket.startListening()
    }

    /// Send a packet to a remote address.
    public func sendPacket(_ data: Data, to address: SocketAddress) throws {
        try socket.send(data: data, to: address)
    }

    /// Register a connection for receiving packets.
    public func registerConnection(_ connection: QUICConnection) {
        connections[connection.destinationConnectionID] = connection
    }

    /// Unregister a connection.
    public func unregisterConnection(_ connectionID: ConnectionID) {
        connections.removeValue(forKey: connectionID)
    }

    /// Close the endpoint.
    public func close() {
        socket.stopListening()
        socket.close()
        connections.removeAll()
    }

    // MARK: - Private

    private func handleDatagram(_ datagram: UDPDatagram) {
        // Extract destination connection ID from the packet
        // Long header: bytes[0] has form bit + version, then DCID length + DCID
        guard datagram.data.count > 5 else { return }

        let firstByte = datagram.data[datagram.data.startIndex]
        let isLongHeader = (firstByte & 0x80) != 0

        if isLongHeader {
            // Long header: skip version (4 bytes after first byte),
            // then DCID length byte, then DCID
            guard datagram.data.count > 6 else { return }
            let dcidLen = Int(datagram.data[datagram.data.startIndex + 5])
            guard datagram.data.count > 6 + dcidLen else { return }
            let dcid = ConnectionID(Data(datagram.data[(datagram.data.startIndex + 6)..<(datagram.data.startIndex + 6 + dcidLen)]))

            if let conn = connections[dcid] {
                conn.receivePacket(datagram.data, from: datagram.source)
            } else if isServer {
                // New connection
                let conn = QUICConnection(
                    destinationConnectionID: dcid,
                    isServer: true,
                    endpoint: self
                )
                connections[dcid] = conn
                onNewConnection?(conn)
                conn.receivePacket(datagram.data, from: datagram.source)
            }
        } else {
            // Short header: DCID is at a fixed offset (after first byte)
            // For our implementation, use 8-byte connection IDs
            guard datagram.data.count > 9 else { return }
            let dcid = ConnectionID(Data(datagram.data[(datagram.data.startIndex + 1)..<(datagram.data.startIndex + 9)]))
            connections[dcid]?.receivePacket(datagram.data, from: datagram.source)
        }
    }
}

// MARK: - QUIC Connection (Minimal Stub)

/// A QUIC connection (minimal implementation for endpoint routing).
public final class QUICConnection: @unchecked Sendable {
    /// Destination connection ID (peer's CID)
    public let destinationConnectionID: ConnectionID

    /// Source connection ID (our CID)
    public let sourceConnectionID: ConnectionID

    /// Whether this is the server side
    public let isServer: Bool

    /// The endpoint this connection belongs to
    private weak var endpoint: QUICEndpoint?

    /// Received packets queue
    private var receivedPackets: [(data: Data, source: SocketAddress)] = []

    /// Connection state
    public enum State: Sendable {
        case idle
        case handshaking
        case connected
        case closing
        case closed
    }

    public internal(set) var state: State = .idle

    public init(
        destinationConnectionID: ConnectionID,
        isServer: Bool,
        endpoint: QUICEndpoint?
    ) {
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = ConnectionID.random()
        self.isServer = isServer
        self.endpoint = endpoint
    }

    /// Receive a packet from the network.
    public func receivePacket(_ data: Data, from source: SocketAddress) {
        receivedPackets.append((data, source))
        // TODO: Process through packet handler, decrypt, frame decoder
    }

    /// Send a packet to the peer.
    public func sendPacket(_ data: Data) throws {
        // TODO: Get peer address from connection state
    }

    /// Close the connection.
    public func close(error: QUICError? = nil) {
        state = .closed
        endpoint?.unregisterConnection(destinationConnectionID)
    }
}

// MARK: - Quiver-Compatible Extensions

extension QUICEndpoint {
    /// Quiver-compatible: create endpoint with configuration.
    public convenience init(configuration: QUICConfiguration) {
        self.init(isServer: false)
    }

    /// Quiver-compatible: dial a remote endpoint.
    public func dial(address: SocketAddress, timeout: Duration = .seconds(10)) async throws -> any QUICConnectionProtocol {
        let conn = QUICConnection(
            destinationConnectionID: ConnectionID.random(),
            isServer: false,
            endpoint: self
        )
        conn.state = .connected
        connections[conn.destinationConnectionID] = conn
        return conn
    }

    /// Quiver-compatible: stop the endpoint asynchronously.
    public func stop() async {
        for (_, conn) in connections {
            conn.close()
        }
        connections.removeAll()
        socket.stopListening()
    }
}

extension QUICConnection: QUICConnectionProtocol {
    /// Quiver-compatible: close with optional error code.
    public func close(error: UInt64?) async {
        close(error: nil as QUICError?)
    }
}
