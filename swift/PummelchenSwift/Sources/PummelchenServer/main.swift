import Foundation
import PummelchenServerCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ServerCommandError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case socket(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage:
              pummelchen-server smoke --project-root <repo>
              pummelchen-server serve --project-root <repo> [--host 127.0.0.1] [--port 8787]
            """
        case .missingValue(let option):
            return "missing value for \(option)"
        case .socket(let message):
            return message
        }
    }
}

struct Arguments {
    let command: String
    let options: [String: String]

    init(_ raw: [String]) throws {
        guard raw.count >= 2 else {
            throw ServerCommandError.usage
        }
        command = raw[1]
        var parsed: [String: String] = [:]
        var index = 2
        while index < raw.count {
            let option = raw[index]
            guard option.hasPrefix("--") else {
                throw ServerCommandError.usage
            }
            let valueIndex = index + 1
            guard valueIndex < raw.count else {
                throw ServerCommandError.missingValue(option)
            }
            parsed[option] = raw[valueIndex]
            index += 2
        }
        options = parsed
    }

    func require(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw ServerCommandError.missingValue(name)
        }
        return value
    }
}

final class LocalHTTPServer {
    private let api: PummelchenReadOnlyAPI
    private let host: String
    private let port: Int

    init(api: PummelchenReadOnlyAPI, host: String, port: Int) {
        self.api = api
        self.host = host
        self.port = port
    }

    func run() throws -> Never {
        let fd = socket(AF_INET, socketStreamType(), 0)
        guard fd >= 0 else {
            throw ServerCommandError.socket("socket creation failed")
        }

        var enabled: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(host))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerCommandError.socket("bind failed on \(host):\(port)")
        }
        guard listen(fd, 64) == 0 else {
            close(fd)
            throw ServerCommandError.socket("listen failed on \(host):\(port)")
        }

        FileHandle.standardOutput.write(Data("pummelchen_server=ready host=\(host) port=\(port) mode=read_only\n".utf8))

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                continue
            }
            handle(client: client)
            close(client)
        }
    }

    private func handle(client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else {
            return
        }
        let requestText = String(decoding: buffer.prefix(count), as: UTF8.self)
        let request = parseRequest(requestText) ?? HTTPRequest(method: "GET", path: "/bad-request")
        let response = api.response(for: request)
        writeResponse(response, to: client)
    }

    private func parseRequest(_ text: String) -> HTTPRequest? {
        guard let firstLine = text.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return nil
        }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]))
    }

    private func writeResponse(_ response: HTTPResponse, to client: Int32) {
        let reason = statusReason(response.statusCode)
        var headers = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "X-Pummelchen-Transport-Target: http3_quic",
            "X-Pummelchen-Mode: read_only"
        ]
        for key in response.headers.keys.sorted() {
            if let value = response.headers[key] {
                headers.append("\(key): \(value)")
            }
        }
        let head = headers.joined(separator: "\r\n") + "\r\n\r\n"
        writeAll(Data(head.utf8), to: client)
        writeAll(response.body, to: client)
    }

    private func writeAll(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return
            }
            var sent = 0
            while sent < data.count {
                let written = write(client, base.advanced(by: sent), data.count - sent)
                if written <= 0 {
                    break
                }
                sent += written
            }
        }
    }

    private func statusReason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "Internal Server Error"
        }
    }
}

private func socketStreamType() -> Int32 {
    #if os(Linux)
    Int32(SOCK_STREAM.rawValue)
    #else
    Int32(SOCK_STREAM)
    #endif
}

func run(arguments: [String]) throws {
    let args = try Arguments(arguments)
    let projectRoot = URL(fileURLWithPath: try args.require("--project-root")).standardizedFileURL
    let api = PummelchenReadOnlyAPI(config: PummelchenServerConfig(projectRoot: projectRoot))

    switch args.command {
    case "smoke":
        try api.smokeCheck()
        print("pummelchen_server_smoke=ok")
    case "serve":
        let host = args.options["--host"] ?? "127.0.0.1"
        let port = Int(args.options["--port"] ?? "8787") ?? 8787
        let configuredAPI = PummelchenReadOnlyAPI(
            config: PummelchenServerConfig(projectRoot: projectRoot, bindHost: host, port: port)
        )
        try LocalHTTPServer(api: configuredAPI, host: host, port: port).run()
    default:
        throw ServerCommandError.usage
    }
}

do {
    try run(arguments: CommandLine.arguments)
} catch {
    if let data = "ERROR: \(error)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(1)
}
