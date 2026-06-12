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
              pummelchen-server release-create --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id <id> [--activate true] [--restart-command <shell>] [--health-command <shell>]
              pummelchen-server release-validate --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id <id>
              pummelchen-server world-reset --project-root <repo> --server-dir <dir> --duckdb <file> --seed <seed> [--dry-run true] [--yes true] [--radius-blocks 1000] [--delete-backup-after-success true] [--stop-command <shell>] [--start-command <shell>] [--gamerule-command <shell>] [--pregenerate-command <shell>] [--verify-forceloads-command <shell>] [--rcon-host 127.0.0.1] [--rcon-port 25575] [--rcon-password <secret>] [--pregeneration-batch-size 384]
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
    private let api: PummelchenServerAPI
    private let host: String
    private let port: Int

    init(api: PummelchenServerAPI, host: String, port: Int) {
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
        guard let raw = readRequest(from: client) else {
            return
        }
        let requestText = String(decoding: raw, as: UTF8.self)
        let request = parseRequest(requestText, raw: raw) ?? HTTPRequest(method: "GET", path: "/bad-request")
        let response = api.response(for: request)
        writeResponse(response, to: client)
    }

    private func readRequest(from client: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else {
                return data.isEmpty ? nil : data
            }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > 512 * 1024 {
                return data
            }
            guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }
            let headerText = String(decoding: data.prefix(upTo: headerEnd.lowerBound), as: UTF8.self)
            let contentLength = headerText
                .split(separator: "\r\n")
                .dropFirst()
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            let expected = headerEnd.upperBound + contentLength
            if data.count >= expected {
                return data
            }
        }
    }

    private func parseRequest(_ text: String, raw: Data) -> HTTPRequest? {
        let headerText = text.components(separatedBy: "\r\n\r\n").first ?? text
        guard let firstLine = headerText.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else {
            return nil
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 2 else {
            return nil
        }
        var headers: [String: String] = [:]
        for line in headerText.split(separator: "\r\n").dropFirst() {
            let header = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard header.count == 2 else {
                continue
            }
            headers[String(header[0]).lowercased()] = String(header[1]).trimmingCharacters(in: .whitespaces)
        }
        let marker = Data("\r\n\r\n".utf8)
        let body: Data
        if let range = raw.range(of: marker) {
            body = raw.subdata(in: range.upperBound..<raw.endIndex)
        } else {
            body = Data()
        }
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    private func writeResponse(_ response: HTTPResponse, to client: Int32) {
        let reason = statusReason(response.statusCode)
        var headers = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Content-Type: \(response.contentType)",
            "Content-Length: \(response.body.count)",
            "Connection: close",
            "X-Pummelchen-Transport-Target: http3_quic_edge",
            "X-Pummelchen-Mode: swift_api",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Referrer-Policy: no-referrer"
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
        case 201: return "Created"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
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

    switch args.command {
    case "smoke":
        let api = PummelchenServerAPI(config: PummelchenServerConfig(projectRoot: projectRoot))
        try api.smokeCheck()
        print("pummelchen_server_smoke=ok")
    case "serve":
        let host = args.options["--host"] ?? "127.0.0.1"
        let port = Int(args.options["--port"] ?? "8787") ?? 8787
        let minecraftSupervisor: MinecraftLiveServerSupervisor?
        if let minecraftConfig = MinecraftLiveServerSupervisorConfig.fromEnvironment() {
            let supervisor = MinecraftLiveServerSupervisor(config: minecraftConfig)
            try supervisor.startIfNeeded()
            minecraftSupervisor = supervisor
        } else {
            minecraftSupervisor = nil
        }
        let configuredAPI = PummelchenServerAPI(
            config: PummelchenServerConfig(projectRoot: projectRoot, bindHost: host, port: port)
        )
        try withExtendedLifetime(minecraftSupervisor) {
            try LocalHTTPServer(api: configuredAPI, host: host, port: port).run()
        }
    case "release-create":
        let pipeline = try releasePipeline(args: args, projectRoot: projectRoot)
        let result = try pipeline.createRelease()
        print("swift_release_created=\(result.releaseID)")
        print("release_dir=\(result.releaseDir)")
        print("client_zip_sha256=\(result.clientZipSHA256)")
        print("mrpack_sha256=\(result.mrpackSHA256)")
        print("activated=\(result.activated)")
    case "release-validate":
        let pipeline = try releasePipeline(args: args, projectRoot: projectRoot)
        try pipeline.validateRelease()
        print("swift_release_valid=\(try args.require("--release-id"))")
    case "world-reset":
        let pipeline = try worldResetPipeline(args: args, projectRoot: projectRoot)
        let result = try pipeline.run()
        print("swift_world_reset=\(result.status)")
        print("job_id=\(result.jobID)")
        print("seed=\(result.seed)")
        print("world_name=\(result.worldName)")
        print("radius_blocks=\(result.radiusBlocks)")
        print("pregeneration_chunks=\(result.pregenerationChunks)")
        print("backup_path=\(result.backupPath ?? "")")
        print("backup_deleted=\(result.backupDeleted)")
    default:
        throw ServerCommandError.usage
    }
}

private func releasePipeline(args: Arguments, projectRoot: URL) throws -> SwiftReleasePipeline {
    let serverDir = URL(fileURLWithPath: try args.require("--server-dir"), isDirectory: true).standardizedFileURL
    let releaseRoot = URL(fileURLWithPath: try args.require("--release-root"), isDirectory: true).standardizedFileURL
    let publicDownloads = URL(fileURLWithPath: try args.require("--public-downloads"), isDirectory: true).standardizedFileURL
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let config = SwiftReleasePipelineConfig(
        projectRoot: projectRoot,
        serverDir: serverDir,
        releaseRoot: releaseRoot,
        publicDownloads: publicDownloads,
        databaseURL: duckDB,
        releaseID: try args.require("--release-id"),
        serverKey: args.options["--server-key"] ?? "minecraft_26_1_2",
        minecraftVersion: args.options["--minecraft-version"] ?? "26.1.2",
        loaderVersion: args.options["--loader-version"] ?? "26.1.2.76",
        status: args.options["--status"] ?? "tested",
        notes: args.options["--notes"] ?? "",
        actor: args.options["--actor"] ?? "pummelchen-swift-release",
        activate: args.options["--activate"] == "true",
        buildClientZipIfMissing: args.options["--build-client-zip-if-missing"] != "false",
        restartCommand: args.options["--restart-command"],
        healthCommand: args.options["--health-command"]
    )
    return SwiftReleasePipeline(config: config)
}

private func worldResetPipeline(args: Arguments, projectRoot: URL) throws -> SwiftWorldResetPipeline {
    let serverDir = URL(fileURLWithPath: try args.require("--server-dir"), isDirectory: true).standardizedFileURL
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let radius = Int(args.options["--radius-blocks"] ?? "1000") ?? 1000
    let shape = PregenerationShape(rawValue: args.options["--shape"] ?? "circle") ?? .circle
    let rconPort = Int(args.options["--rcon-port"] ?? "25575") ?? 25575
    let batchSize = Int(args.options["--pregeneration-batch-size"] ?? "384") ?? 384
    let config = SwiftWorldResetConfig(
        projectRoot: projectRoot,
        serverDir: serverDir,
        databaseURL: duckDB,
        serviceName: args.options["--service"] ?? "pummelchen-minecraft.service",
        seed: try args.require("--seed"),
        radiusBlocks: radius,
        shape: shape,
        dryRun: args.options["--dry-run"] != "false",
        confirmDestructive: args.options["--yes"] == "true",
        deleteBackupAfterSuccess: args.options["--delete-backup-after-success"] == "true",
        actor: args.options["--actor"] ?? "pummelchen-swift-world-reset",
        stopCommand: args.options["--stop-command"],
        startCommand: args.options["--start-command"],
        gameruleCommand: args.options["--gamerule-command"],
        pregenerateCommand: args.options["--pregenerate-command"],
        verifyForceloadsCommand: args.options["--verify-forceloads-command"],
        rconHost: args.options["--rcon-host"] ?? "127.0.0.1",
        rconPort: rconPort,
        rconPassword: args.options["--rcon-password"],
        pregenerationBatchSize: batchSize
    )
    return SwiftWorldResetPipeline(config: config)
}

do {
    try run(arguments: CommandLine.arguments)
} catch {
    if let data = "ERROR: \(error)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(1)
}
