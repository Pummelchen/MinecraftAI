import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum MinecraftRCONError: Error, CustomStringConvertible {
    case unsupportedHost(String)
    case socket(String)
    case authenticationFailed
    case protocolError(String)

    public var description: String {
        switch self {
        case .unsupportedHost(let host):
            return "RCON only supports IPv4 hosts in this build: \(host)"
        case .socket(let message):
            return "RCON socket error: \(message)"
        case .authenticationFailed:
            return "RCON authentication failed"
        case .protocolError(let message):
            return "RCON protocol error: \(message)"
        }
    }
}

public struct MinecraftRCONClient: Sendable {
    public let host: String
    public let port: Int
    public let password: String

    public init(host: String = "127.0.0.1", port: Int = 25575, password: String) {
        self.host = host
        self.port = port
        self.password = password
    }

    public func command(_ command: String) throws -> String {
        try commands([command]).first ?? ""
    }

    public func commands(_ commands: [String]) throws -> [String] {
        let socketFD = try connect()
        defer { platformClose(socketFD) }

        try sendPacket(socketFD, id: 1, type: 3, payload: password)
        let auth = try readPacket(socketFD)
        guard auth.id != -1 else {
            throw MinecraftRCONError.authenticationFailed
        }

        var responses: [String] = []
        for (offset, command) in commands.enumerated() {
            let requestID = Int32(2 + offset)
            try sendPacket(socketFD, id: requestID, type: 2, payload: command)
            let response = try readPacket(socketFD)
            guard response.id == requestID else {
                throw MinecraftRCONError.protocolError("unexpected response id \(response.id) for command \(command)")
            }
            responses.append(response.payload)
        }
        return responses
    }

    private func connect() throws -> Int32 {
        let fd = socket(AF_INET, streamSocketType(), 0)
        guard fd >= 0 else {
            throw MinecraftRCONError.socket("socket creation failed")
        }

        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        let encoded = inet_addr(host)
        guard encoded != in_addr_t(INADDR_NONE) else {
            platformClose(fd)
            throw MinecraftRCONError.unsupportedHost(host)
        }
        address.sin_addr = in_addr(s_addr: encoded)

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            platformClose(fd)
            throw MinecraftRCONError.socket("connect failed to \(host):\(port)")
        }
        return fd
    }

    private func sendPacket(_ fd: Int32, id: Int32, type: Int32, payload: String) throws {
        let payloadData = Data(payload.utf8)
        var packet = Data()
        appendInt32LE(Int32(8 + payloadData.count + 2), to: &packet)
        appendInt32LE(id, to: &packet)
        appendInt32LE(type, to: &packet)
        packet.append(payloadData)
        packet.append(0)
        packet.append(0)
        try writeAll(packet, to: fd)
    }

    private func readPacket(_ fd: Int32) throws -> (id: Int32, type: Int32, payload: String) {
        let lengthData = try readExactly(4, from: fd)
        let length = Int(readInt32LE(lengthData, at: 0))
        guard length >= 10 && length <= 4 * 1024 * 1024 else {
            throw MinecraftRCONError.protocolError("invalid packet length \(length)")
        }
        let body = try readExactly(length, from: fd)
        let id = readInt32LE(body, at: 0)
        let type = readInt32LE(body, at: 4)
        let payloadBytes = body.dropFirst(8).dropLast(2)
        let payload = String(decoding: payloadBytes, as: UTF8.self)
        return (id, type, payload)
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let written = DarwinOrGlibc.send(fd, base.advanced(by: sent), data.count - sent, 0)
                guard written > 0 else {
                    throw MinecraftRCONError.socket("send failed")
                }
                sent += written
            }
        }
    }

    private func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let readCount = buffer.withUnsafeMutableBytes { raw in
                DarwinOrGlibc.recv(fd, raw.baseAddress!.advanced(by: received), count - received, 0)
            }
            guard readCount > 0 else {
                throw MinecraftRCONError.socket("recv failed")
            }
            received += readCount
        }
        return Data(buffer)
    }

    private func appendInt32LE(_ value: Int32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func readInt32LE(_ data: Data, at offset: Int) -> Int32 {
        let bytes = [UInt8](data)
        let raw = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Int32(bitPattern: raw)
    }
}

private func streamSocketType() -> Int32 {
    #if os(Linux)
    Int32(SOCK_STREAM.rawValue)
    #else
    Int32(SOCK_STREAM)
    #endif
}

private func platformClose(_ fd: Int32) {
    _ = DarwinOrGlibc.close(fd)
}

private enum DarwinOrGlibc {
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if os(Linux)
        Glibc.connect(fd, address, length)
        #else
        Darwin.connect(fd, address, length)
        #endif
    }

    static func send(_ fd: Int32, _ buffer: UnsafeRawPointer, _ length: Int, _ flags: Int32) -> Int {
        #if os(Linux)
        Glibc.send(fd, buffer, length, flags)
        #else
        Darwin.send(fd, buffer, length, flags)
        #endif
    }

    static func recv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ length: Int, _ flags: Int32) -> Int {
        #if os(Linux)
        Glibc.recv(fd, buffer, length, flags)
        #else
        Darwin.recv(fd, buffer, length, flags)
        #endif
    }

    static func close(_ fd: Int32) -> Int32 {
        #if os(Linux)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }
}
