import Foundation
import MCPummelchenModShared
import MCPummelchenModServerCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum ServerCommandError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case invalidValue(String)
    case socket(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage:
              MCPummelchenModServer smoke --project-root <repo>
              MCPummelchenModServer serve --project-root <repo> [--host 127.0.0.1] [--port 8787] [--webtransport-host pummelchen.91.99.176.243.nip.io] [--webtransport-bind-host 0.0.0.0] [--webtransport-port 443] [--webtransport-path /webtransport/v1/control] [--webtransport-cert <cert.pem>] [--webtransport-key <privkey.pem>]
              MCPummelchenModServer release-create --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id <id> [--activate true] [--restart-command <shell>] [--health-command <shell>]
              MCPummelchenModServer release-validate --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id <id>
              MCPummelchenModServer add-mod --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --url <curseforge-or-modrinth-url> --release-id <id> [--local-artifact <jar>] [--install-scope auto|server|client|both] [--activate true] [--dry-run false] [--server-test-command <shell>] [--build-dmg-command <shell>] [--restart-command <shell>] [--health-command <shell>]
              MCPummelchenModServer mod-update-scan --project-root <repo> --duckdb <file> [--minecraft-version 26.1.2] [--loader neoforge] [--seed-from-tested-updates true] [--limit <n>] [--max-urls-per-window 5] [--window-seconds 10] [--dry-run true]
              MCPummelchenModServer world-reset --project-root <repo> --server-dir <dir> --duckdb <file> --seed <seed> [--dry-run true] [--yes true] [--radius-blocks 1000] [--delete-backup-after-success true] [--stop-command <shell>] [--start-command <shell>] [--gamerule-command <shell>] [--pregenerate-command <shell>] [--verify-forceloads-command <shell>] [--rcon-host 127.0.0.1] [--rcon-port 25575] [--rcon-password <secret>] [--pregeneration-batch-size 384]
              MCPummelchenModServer rcon-command --project-root <repo> --server-dir <dir> --command <minecraft command> [--rcon-host 127.0.0.1] [--rcon-port 25575] [--rcon-password <secret>]
            """
        case .missingValue(let option):
            return "missing value for \(option)"
        case .invalidValue(let message):
            return message
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
    private let api: MCPummelchenModServerAPI
    private let host: String
    private let port: Int

    init(api: MCPummelchenModServerAPI, host: String, port: Int) {
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

        FileHandle.standardOutput.write(Data("MCPummelchenModServer=ready host=\(host) port=\(port) mode=read_only\n".utf8))

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
            "X-Pummelchen-Transport-Target: swift_webtransport_dedicated_udp",
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
        let api = MCPummelchenModServerAPI(config: MCPummelchenModServerConfig(projectRoot: projectRoot))
        try api.smokeCheck()
        print("MCPummelchenModServer_smoke=ok")
    case "serve":
        let host = args.options["--host"] ?? "127.0.0.1"
        let port = Int(args.options["--port"] ?? "8787") ?? 8787
        let webTransportHost = args.options["--webtransport-host"] ?? "pummelchen.91.99.176.243.nip.io"
        let webTransportBindHost = args.options["--webtransport-bind-host"] ?? "0.0.0.0"
        let webTransportPort = Int(args.options["--webtransport-port"] ?? "443") ?? 443
        let webTransportPath = args.options["--webtransport-path"] ?? "/webtransport/v1/control"
        guard (1...65_535).contains(port) else {
            throw ServerCommandError.invalidValue("--port must be between 1 and 65535")
        }
        guard (1...65_535).contains(webTransportPort) else {
            throw ServerCommandError.invalidValue("--webtransport-port must be between 1 and 65535")
        }
        let webTransportCert = args.options["--webtransport-cert"]
            ?? ProcessInfo.processInfo.environment["PUMMELCHEN_WEBTRANSPORT_CERTIFICATE"]
            ?? "/etc/letsencrypt/live/pummelchen.91.99.176.243.nip.io/cert.pem"
        let webTransportKey = args.options["--webtransport-key"]
            ?? ProcessInfo.processInfo.environment["PUMMELCHEN_WEBTRANSPORT_PRIVATE_KEY"]
            ?? "/etc/letsencrypt/live/pummelchen.91.99.176.243.nip.io/privkey.pem"
        let duckDBURL = projectRoot.appendingPathComponent("data/pummelchen.duckdb")
        let webTransportRuntime = WebTransportRuntimeState()
        let webTransportService = PummelchenWebTransportService(
            config: PummelchenWebTransportServiceConfig(
                host: webTransportBindHost,
                port: UInt16(webTransportPort),
                path: webTransportPath,
                certificatePath: webTransportCert,
                privateKeyPath: webTransportKey,
                projectRoot: projectRoot,
                databaseURL: duckDBURL,
                clientAPIToken: ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"],
                maxSessions: 128
            ),
            runtime: webTransportRuntime
        )
        webTransportService.start()
        let minecraftSupervisor: MinecraftLiveServerSupervisor?
        if let minecraftConfig = MinecraftLiveServerSupervisorConfig.fromEnvironment() {
            try MinecraftServerDefaultWriter.apply(to: minecraftConfig.serverDirectory)
            let supervisor = MinecraftLiveServerSupervisor(config: minecraftConfig)
            try supervisor.startIfNeeded()
            minecraftSupervisor = supervisor
        } else {
            minecraftSupervisor = nil
        }
        let configuredAPI = MCPummelchenModServerAPI(
            config: MCPummelchenModServerConfig(
                projectRoot: projectRoot,
                bindHost: host,
                port: port,
                duckDBURL: duckDBURL,
                webTransportPublicHost: webTransportHost,
                webTransportPort: webTransportPort,
                webTransportPath: webTransportPath,
                webTransportCertificatePath: webTransportCert,
                webTransportRuntimeState: webTransportRuntime
            )
        )
        let liveStatsPublisher = LiveStatsPublisher(projectRoot: projectRoot, intervalSeconds: 5)
        try liveStatsPublisher.publishOnce()
        liveStatsPublisher.start()
        try withExtendedLifetime((minecraftSupervisor, webTransportService, liveStatsPublisher)) {
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
    case "add-mod":
        let pipeline = try addModPipeline(args: args, projectRoot: projectRoot)
        let result = try pipeline.run()
        print("mod_add_release_id=\(result.releaseID)")
        print("mod_add_dry_run=\(result.dryRun)")
        print("mod_add_release_created=\(result.releaseCreated)")
        print("mod_add_release_activated=\(result.releaseActivated)")
        for artifact in result.artifacts {
            print("mod_add_artifact=\(artifact.fileName) provider=\(artifact.provider) side=\(artifact.side) server=\(artifact.copiedToServer) client=\(artifact.copiedToClient) sha256=\(artifact.sha256)")
        }
        for step in result.steps {
            print("mod_add_step=\(step)")
        }
    case "mod-update-scan":
        let scanner = try modUpdateScanner(args: args, projectRoot: projectRoot)
        let summary = try scanner.run()
        print("mod_update_scan=\(summary.scanID)")
        print("sources_checked=\(summary.sourcesChecked)")
        print("candidates_found=\(summary.candidatesFound)")
        print("unresolved=\(summary.unresolved)")
        print("seeded_sources=\(summary.seededSources)")
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
    case "rcon-command":
        let response = try runRCONCommand(args: args)
        print("rcon_command=ok")
        if !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print(response)
        }
    default:
        throw ServerCommandError.usage
    }
}

private func runRCONCommand(args: Arguments) throws -> String {
    let serverDir = URL(fileURLWithPath: try args.require("--server-dir"), isDirectory: true).standardizedFileURL
    let command = try args.require("--command")
    let port = Int(args.options["--rcon-port"] ?? "25575") ?? 25575
    let password = try resolvedRCONPassword(args: args, serverDir: serverDir)
    let client = MinecraftRCONClient(
        host: args.options["--rcon-host"] ?? "127.0.0.1",
        port: port,
        password: password
    )
    return try client.command(command)
}

private func resolvedRCONPassword(args: Arguments, serverDir: URL) throws -> String {
    if let password = args.options["--rcon-password"]?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
        return password
    }
    let properties = try readServerProperties(serverDir.appendingPathComponent("server.properties"))
    if let password = properties["rcon.password"]?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
        return password
    }
    throw ServerCommandError.missingValue("--rcon-password")
}

private func readServerProperties(_ path: URL) throws -> [String: String] {
    guard FileManager.default.fileExists(atPath: path.path) else {
        return [:]
    }
    var values: [String: String] = [:]
    for raw in try String(contentsOf: path, encoding: .utf8).split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else {
            continue
        }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        values[key] = value
    }
    return values
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

private func addModPipeline(args: Arguments, projectRoot: URL) throws -> ModAddPipeline {
    let serverDir = URL(fileURLWithPath: try args.require("--server-dir"), isDirectory: true).standardizedFileURL
    let releaseRoot = URL(fileURLWithPath: try args.require("--release-root"), isDirectory: true).standardizedFileURL
    let publicDownloads = URL(fileURLWithPath: try args.require("--public-downloads"), isDirectory: true).standardizedFileURL
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let localArtifact = args.options["--local-artifact"].map { URL(fileURLWithPath: $0).standardizedFileURL }
    return ModAddPipeline(config: ModAddPipelineConfig(
        projectRoot: projectRoot,
        serverDir: serverDir,
        releaseRoot: releaseRoot,
        publicDownloads: publicDownloads,
        databaseURL: duckDB,
        sourceURL: try args.require("--url"),
        localArtifact: localArtifact,
        releaseID: try args.require("--release-id"),
        minecraftVersion: args.options["--minecraft-version"] ?? "26.1.2",
        loader: args.options["--loader"] ?? "neoforge",
        loaderVersion: args.options["--loader-version"] ?? "26.1.2.76",
        installScope: args.options["--install-scope"] ?? "auto",
        activate: args.options["--activate"] == "true",
        dryRun: args.options["--dry-run"] != "false",
        buildDMGCommand: args.options["--build-dmg-command"],
        serverTestCommand: args.options["--server-test-command"],
        restartCommand: args.options["--restart-command"],
        healthCommand: args.options["--health-command"]
    ))
}

private func modUpdateScanner(args: Arguments, projectRoot: URL) throws -> ModUpdateScanner {
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let limit = args.options["--limit"].flatMap(Int.init)
    let maxURLs = Int(args.options["--max-urls-per-window"] ?? "5") ?? 5
    let windowSeconds = Double(args.options["--window-seconds"] ?? "10") ?? 10
    guard maxURLs > 0 else {
        throw ServerCommandError.invalidValue("--max-urls-per-window must be greater than zero")
    }
    guard windowSeconds >= 0 else {
        throw ServerCommandError.invalidValue("--window-seconds must be zero or greater")
    }
    return ModUpdateScanner(config: ModUpdateScannerConfig(
        projectRoot: projectRoot,
        databaseURL: duckDB,
        minecraftVersion: args.options["--minecraft-version"] ?? "26.1.2",
        loader: args.options["--loader"] ?? "neoforge",
        loaderVersion: args.options["--loader-version"] ?? "26.1.2.76",
        maxURLsPerWindow: maxURLs,
        windowSeconds: windowSeconds,
        limit: limit,
        seedFromTestedUpdates: args.options["--seed-from-tested-updates"] == "true",
        dryRun: args.options["--dry-run"] == "true"
    ))
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
