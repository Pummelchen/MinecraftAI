import Foundation
import MCPummelchenModShared
import MCPummelchenModServerCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private let defaultSafeWorldResetSeed = "5605164115430518763"

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
              MCPummelchenModServer serve --project-root <repo> [--host 127.0.0.1] [--port 8787]
              MCPummelchenModServer release-create --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id <id> [--activate true] [--service <systemd-unit>]
              MCPummelchenModServer release-validate --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id <id>
              MCPummelchenModServer add-mod --project-root <repo> --server-dir <dir> --release-root <dir> --public-downloads <dir> --duckdb <file> --url <curseforge-or-modrinth-url> --release-id <id> [--server-package <dir>] [--service <systemd-unit>] [--local-artifact <jar>] [--install-scope auto|server|client|both] [--activate true] [--dry-run false] [--client-api-token <token>] [--require-client-token true|false]
              MCPummelchenModServer build-client-dmg --project-root <repo> [--client-package <dir>] [--server-package <dir>] [--release-id <id>] [--client-version <version>] [--server-url <url>] [--server-address <host:port>] [--duckdb-dylib <path>] [--macos-deployment-target <target>] [--skip-nginx-control-live-test true] [--skip-headless-soak true] [--require-headless-soak true] [--headless-soak-seconds 60] [--headless-command <command>] [--expected-installed-release-id <id>] [--require-client-token true|false]
              MCPummelchenModServer ban-mod --project-root <repo> --duckdb <file> --name <display-name> --file-pattern <jar-name-or-pattern> [--source-url <url>] [--reason "Banned by Admin"] [--dry-run true]
              MCPummelchenModServer mod-update-scan --project-root <repo> --duckdb <file> [--all-supported true] [--minecraft-version 26.1.2] [--loader neoforge] [--seed-from-project-data true] [--discover-source-links true] [--discovery-limit <n>] [--discovery-searches-per-second 2] [--limit <n>] [--max-urls-per-window 5] [--window-seconds 10] [--dry-run true]
              MCPummelchenModServer mod-update-apply --project-root <repo> --release-root <dir> --public-downloads <dir> --duckdb <file> --release-id-prefix <id> [--server-package <dir>] [--all-supported true] [--minecraft-version 26.1.2] [--dry-run true] [--activate-live true] [--service <systemd-unit>] [--client-api-token <token>] [--require-client-token true|false]
              MCPummelchenModServer server-version-bootstrap --project-root <repo> --duckdb <file> --minecraft-version <target> [--reference-minecraft-version <version>] [--discover-source-links true] [--discovery-limit <n>] [--discovery-searches-per-second 2] [--max-urls-per-window 5] [--window-seconds 10] [--apply-updates true] [--release-root <dir>] [--public-downloads <dir>] [--release-id-prefix <id>] [--server-package <dir>] [--service <systemd-unit>] [--dry-run true] [--client-api-token <token>] [--require-client-token true|false]
              MCPummelchenModServer client-force-update --project-root <repo> --duckdb <file> [--release-id <id>] [--target-client-id <id>]
              MCPummelchenModServer world-reset --project-root <repo> --server-dir <dir> --duckdb <file> [--seed <seed>] [--dry-run true] [--yes true] [--service <systemd-unit>] [--radius-blocks 1000] [--delete-backup-after-success true] [--rcon-host 127.0.0.1] [--rcon-port 25575] [--rcon-password <secret>] [--rcon-ready-timeout-seconds 600] [--pregeneration-batch-size 384]
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

final class LocalHTTPServer: @unchecked Sendable {
    private static let listenBacklog: Int32 = 512
    private static let maxConcurrentClients = 256

    private let api: MCPummelchenModServerAPI
    private let host: String
    private let port: Int
    private let concurrencyLimit = DispatchSemaphore(value: LocalHTTPServer.maxConcurrentClients)

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
        guard listen(fd, Self.listenBacklog) == 0 else {
            close(fd)
            throw ServerCommandError.socket("listen failed on \(host):\(port)")
        }

        FileHandle.standardOutput.write(Data("MCPummelchenModServer=ready host=\(host) port=\(port) mode=read_only\n".utf8))

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                continue
            }
            concurrencyLimit.wait()
            Thread.detachNewThread { [self] in
                defer {
                    close(client)
                    concurrencyLimit.signal()
                }
                handle(client: client)
            }
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
            "X-Pummelchen-Transport-Target: nginx_https_api",
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
        guard (1...65_535).contains(port) else {
            throw ServerCommandError.invalidValue("--port must be between 1 and 65535")
        }
        let duckDBURL = projectRoot.appendingPathComponent("data/pummelchen.duckdb")
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
                duckDBURL: duckDBURL
            )
        )
        let liveStatsPublisher = LiveStatsPublisher(projectRoot: projectRoot, intervalSeconds: 5)
        try liveStatsPublisher.publishOnce()
        liveStatsPublisher.start()
        try withExtendedLifetime((minecraftSupervisor, liveStatsPublisher)) {
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
    case "ban-mod":
        let pipeline = try banModPipeline(args: args, projectRoot: projectRoot)
        let result = try pipeline.run()
        print("mod_ban_name=\(result.displayName)")
        print("mod_ban_reason=\(result.reason)")
        print("mod_ban_dry_run=\(result.dryRun)")
        print("mod_ban_removals=\(result.removals.count)")
        for removal in result.removals {
            print("mod_ban_removed=\(removal.removed) minecraft_version=\(removal.minecraftVersion) path=\(removal.path)")
        }
    case "mod-update-scan":
        if optionBool(args.options["--all-supported"]) {
            let summaries = try runAllSupportedModUpdateScans(args: args, projectRoot: projectRoot)
            let checked = summaries.reduce(0) { $0 + $1.summary.sourcesChecked }
            let candidates = summaries.reduce(0) { $0 + $1.summary.candidatesFound }
            let unresolved = summaries.reduce(0) { $0 + $1.summary.unresolved }
            print("mod_update_scan_all_supported=ok")
            print("versions_checked=\(summaries.count)")
            print("sources_checked=\(checked)")
            print("candidates_found=\(candidates)")
            print("unresolved=\(unresolved)")
            for item in summaries {
                print("mod_update_scan_version=\(item.version.minecraftVersion) loader=\(item.version.loader) loader_version=\(item.version.loaderVersion ?? "") scan_id=\(item.summary.scanID) sources_checked=\(item.summary.sourcesChecked) candidates_found=\(item.summary.candidatesFound) unresolved=\(item.summary.unresolved)")
            }
        } else {
            let scanner = try modUpdateScanner(args: args, projectRoot: projectRoot)
            let summary = try scanner.run()
            print("mod_update_scan=\(summary.scanID)")
            print("sources_checked=\(summary.sourcesChecked)")
            print("candidates_found=\(summary.candidatesFound)")
            print("unresolved=\(summary.unresolved)")
            print("seeded_sources=\(summary.seededSources)")
        }
    case "mod-update-apply":
        let pipeline = try modUpdateApplyPipeline(args: args, projectRoot: projectRoot)
        let result = try pipeline.run()
        print("mod_update_apply=ok")
        print("mod_update_apply_dry_run=\(result.dryRun)")
        for version in result.versions {
            print("mod_update_apply_version=\(version.minecraftVersion) status=\(version.status) release_id=\(version.releaseID ?? "") updates=\(version.appliedUpdates.count) skipped=\(version.skippedReason ?? "")")
            for update in version.appliedUpdates {
                print("mod_update_applied=\(version.minecraftVersion) old=\(update.oldFiles.joined(separator: "|")) new=\(update.newFile) latest=\(update.latestVersion) sha256=\(update.sha256)")
            }
        }
    case "server-version-bootstrap":
        let pipeline = try serverVersionBootstrapPipeline(args: args, projectRoot: projectRoot)
        let result = try pipeline.run()
        print("server_version_bootstrap=ok")
        print("server_version_bootstrap_dry_run=\(result.dryRun)")
        print("target_minecraft_version=\(result.targetMinecraftVersion)")
        print("reference_minecraft_version=\(result.referenceMinecraftVersion)")
        print("scanned_sources=\(result.scannedSources)")
        print("seeded_sources=\(result.seededSources)")
        print("update_candidates_found=\(result.updateCandidatesFound)")
        print("protected_mods=\(result.protectedMods)")
        print("copied_files=\(result.copiedFiles.count)")
        for copied in result.copiedFiles {
            print("bootstrap_copied=\(copied.fileName) mod=\(copied.modName) server=\(copied.copiedToServer) client=\(copied.copiedToClient) protected=\(copied.protected)")
        }
        if let apply = result.applyResult {
            for version in apply.versions {
                print("bootstrap_apply_version=\(version.minecraftVersion) status=\(version.status) release_id=\(version.releaseID ?? "") updates=\(version.appliedUpdates.count) skipped=\(version.skippedReason ?? "")")
            }
        }
    case "build-client-dmg":
        let command = try buildClientDMGCommand(args: args, projectRoot: projectRoot)
        let result = try ClientDMGBuilder(config: command).build()
        print("build_client_dmg=ok")
        print("build_client_dmg_path=\(result.dmgPath.path)")
        print("build_client_dmg_sha256=\(result.dmgSHA256)")
    case "client-force-update":
        let event = try runClientForceUpdate(args: args, projectRoot: projectRoot)
        print("client_force_update=ok")
        print("event_id=\(event.eventID)")
        print("event_type=\(event.eventType.rawValue)")
        print("release_id=\(event.releaseID ?? "")")
        print("target_client_id=\(event.targetClientID ?? "all")")
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

private func runClientForceUpdate(args: Arguments, projectRoot: URL) throws -> ControlEvent {
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let releaseID = try args.options["--release-id"] ?? currentReleaseID(projectRoot: projectRoot)
    let targetClientID = args.options["--target-client-id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let request = ControlEventCreateRequest(
        eventType: .releaseAvailable,
        targetClientID: targetClientID?.isEmpty == false ? targetClientID : nil,
        releaseID: releaseID,
        priority: "critical",
        title: "Client app update required",
        message: "A validated Pummelchen client app release is available. Sync now and self-update if your app bundle is older.",
        payload: [
            "action": "sync",
            "reason": "operator_forced_client_app_update",
            "release_id": releaseID
        ]
    )
    return try ControlEventStore(databaseURL: duckDB).create(request)
}

private func currentReleaseID(projectRoot: URL) throws -> String {
    let candidates = [
        projectRoot.appendingPathComponent("site/public/downloads/current-release.json"),
        projectRoot.appendingPathComponent("downloads/current-release.json")
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        let release = try CurrentReleaseValidator.decode(Data(contentsOf: url))
        try CurrentReleaseValidator.validate(release)
        return release.releaseID
    }
    throw ServerCommandError.missingValue("--release-id")
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
    let minecraftVersion = args.options["--minecraft-version"] ?? "26.1.2"
    let config = SwiftReleasePipelineConfig(
        projectRoot: projectRoot,
        serverDir: serverDir,
        releaseRoot: releaseRoot,
        publicDownloads: publicDownloads,
        databaseURL: duckDB,
        releaseID: try args.require("--release-id"),
        serverKey: args.options["--server-key"] ?? serverKey(minecraftVersion: minecraftVersion),
        minecraftVersion: minecraftVersion,
        loaderVersion: args.options["--loader-version"] ?? "26.1.2.76",
        status: args.options["--status"] ?? "tested",
        notes: args.options["--notes"] ?? "",
        actor: args.options["--actor"] ?? "pummelchen-swift-release",
        activate: args.options["--activate"] == "true",
        buildClientZipIfMissing: args.options["--build-client-zip-if-missing"] != "false",
        serviceName: args.options["--service"] ?? "",
    )
    return SwiftReleasePipeline(config: config)
}

private func addModPipeline(args: Arguments, projectRoot: URL) throws -> ModAddPipeline {
    let serverDir = URL(fileURLWithPath: try args.require("--server-dir"), isDirectory: true).standardizedFileURL
    let releaseRoot = URL(fileURLWithPath: try args.require("--release-root"), isDirectory: true).standardizedFileURL
    let publicDownloads = URL(fileURLWithPath: try args.require("--public-downloads"), isDirectory: true).standardizedFileURL
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let localArtifact = args.options["--local-artifact"].map { URL(fileURLWithPath: $0).standardizedFileURL }
    let releaseID = try args.require("--release-id")
        return ModAddPipeline(config: ModAddPipelineConfig(
            projectRoot: projectRoot,
            serverDir: serverDir,
            releaseRoot: releaseRoot,
            publicDownloads: publicDownloads,
        databaseURL: duckDB,
        sourceURL: try args.require("--url"),
        localArtifact: localArtifact,
        releaseID: releaseID,
        serverPackageDirectory: URL(fileURLWithPath: args.options["--server-package"] ?? envOrDefault("PUMMELCHEN_SERVER_PACKAGE_DIR", defaultPath: projectRoot.appendingPathComponent("Server App/MCPummelchenModServer").path)),
        serviceName: args.options["--service"],
        minecraftVersion: args.options["--minecraft-version"] ?? "26.1.2",
        loader: args.options["--loader"] ?? "neoforge",
        loaderVersion: args.options["--loader-version"] ?? "26.1.2.76",
        installScope: args.options["--install-scope"] ?? "auto",
            activate: args.options["--activate"] == "true",
            dryRun: optionBool(args.options["--dry-run"]),
        clientAPIToken: args.options["--client-api-token"] ?? ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"],
        requireClientToken: optionBool(args.options["--require-client-token"], defaultValue: optionBool(ProcessInfo.processInfo.environment["PUMMELCHEN_REQUIRE_CLIENT_TOKEN"]))
    ))
}

private func buildClientDMGCommand(args: Arguments, projectRoot: URL) throws -> ClientDMGBuilderConfig {
    let env = ProcessInfo.processInfo.environment
    let runNginxControlLiveTest = optionBool(args.options["--require-nginx-control-live-test"], defaultValue: optionBool(env["PUMMELCHEN_REQUIRE_NGINX_CONTROL_LIVE_TEST"], defaultValue: true))
    let skipNginxControlLiveTest = optionBool(args.options["--skip-nginx-control-live-test"], defaultValue: optionBool(env["PUMMELCHEN_SKIP_NGINX_CONTROL_LIVE_TEST"]))
    let runHeadlessSoak = optionBool(args.options["--require-headless-soak"], defaultValue: optionBool(env["PUMMELCHEN_REQUIRE_HEADLESS_SOAK"], defaultValue: false))
    let skipHeadlessSoak = optionBool(args.options["--skip-headless-soak"], defaultValue: optionBool(env["PUMMELCHEN_SKIP_HEADLESS_SOAK"]))
    return ClientDMGBuilderConfig(
        projectRoot: projectRoot,
        clientPackageRoot: URL(fileURLWithPath: args.options["--client-package"] ?? projectRoot.appendingPathComponent("Client App/MCPummelchenModClient").path),
        serverPackageRoot: URL(fileURLWithPath: args.options["--server-package"] ?? envOrDefault("PUMMELCHEN_SERVER_PACKAGE_DIR", defaultPath: projectRoot.appendingPathComponent("Server App/MCPummelchenModServer").path)),
        releaseID: args.options["--release-id"] ?? env["PUMMELCHEN_RELEASE_ID"] ?? "development",
        clientVersion: args.options["--client-version"] ?? env["PUMMELCHEN_CLIENT_VERSION"] ?? "0.8.4",
        serverURL: args.options["--server-url"] ?? env["PUMMELCHEN_SERVER_URL"] ?? "https://pummelchen.91.99.176.243.nip.io",
        serverAddress: args.options["--server-address"] ?? env["PUMMELCHEN_SERVER_ADDRESS"] ?? "91.99.176.243:25565",
        duckdbDylibPath: args.options["--duckdb-dylib"] ?? env["PUMMELCHEN_DUCKDB_DYLIB"] ?? "/opt/homebrew/lib/libduckdb.dylib",
        macOSDeploymentTarget: args.options["--macos-deployment-target"] ?? env["MACOSX_DEPLOYMENT_TARGET"] ?? "26.0",
        runNginxControlLiveTest: runNginxControlLiveTest && !skipNginxControlLiveTest,
        runHeadlessSoak: runHeadlessSoak && !skipHeadlessSoak,
        headlessSoakSeconds: Int(args.options["--headless-soak-seconds"] ?? env["PUMMELCHEN_HEADLESS_SOAK_SECONDS"] ?? "60") ?? 60,
        headlessCommand: args.options["--headless-command"],
        expectedInstalledReleaseID: args.options["--expected-installed-release-id"],
        clientAPIToken: args.options["--client-api-token"] ?? env["PUMMELCHEN_CLIENT_API_TOKEN"],
        requireClientToken: optionBool(args.options["--require-client-token"], defaultValue: optionBool(env["PUMMELCHEN_REQUIRE_CLIENT_TOKEN"]))
    )
}

private func banModPipeline(args: Arguments, projectRoot: URL) throws -> ModBanPipeline {
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let filePattern = try args.require("--file-pattern")
    let extraPatterns = (args.options["--extra-file-patterns"] ?? "")
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    return ModBanPipeline(config: ModBanPipelineConfig(
        projectRoot: projectRoot,
        databaseURL: duckDB,
        displayName: try args.require("--name"),
        filePatterns: [filePattern] + extraPatterns,
        sourceURL: args.options["--source-url"],
        reason: args.options["--reason"] ?? "Banned by Admin",
        dryRun: args.options["--dry-run"] != "false"
    ))
}

private func modUpdateScanner(args: Arguments, projectRoot: URL) throws -> ModUpdateScanner {
    try modUpdateScanner(
        args: args,
        projectRoot: projectRoot,
        minecraftVersion: args.options["--minecraft-version"] ?? "26.1.2",
        loader: args.options["--loader"] ?? "neoforge",
        loaderVersion: args.options["--loader-version"] ?? "26.1.2.76"
    )
}

private func modUpdateScanner(
    args: Arguments,
    projectRoot: URL,
    minecraftVersion: String,
    loader: String,
    loaderVersion: String?
) throws -> ModUpdateScanner {
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let limit = args.options["--limit"].flatMap(Int.init)
    let discoveryLimit = args.options["--discovery-limit"].flatMap(Int.init)
    let maxURLs = Int(args.options["--max-urls-per-window"] ?? "5") ?? 5
    let windowSeconds = Double(args.options["--window-seconds"] ?? "10") ?? 10
    let discoverySearchesPerSecond = Double(args.options["--discovery-searches-per-second"] ?? "2") ?? 2
    guard maxURLs > 0 else {
        throw ServerCommandError.invalidValue("--max-urls-per-window must be greater than zero")
    }
    guard windowSeconds >= 0 else {
        throw ServerCommandError.invalidValue("--window-seconds must be zero or greater")
    }
    guard discoverySearchesPerSecond > 0, discoverySearchesPerSecond <= 2 else {
        throw ServerCommandError.invalidValue("--discovery-searches-per-second must be greater than zero and at most 2")
    }
    return ModUpdateScanner(config: ModUpdateScannerConfig(
        projectRoot: projectRoot,
        databaseURL: duckDB,
        minecraftVersion: minecraftVersion,
        loader: loader,
        loaderVersion: loaderVersion,
        maxURLsPerWindow: maxURLs,
        windowSeconds: windowSeconds,
        limit: limit,
        seedFromProjectData: args.options["--seed-from-project-data"] == "true",
        discoverSourceLinks: args.options["--discover-source-links"] == "true",
        discoveryLimit: discoveryLimit,
        discoverySearchesPerSecond: discoverySearchesPerSecond,
        dryRun: args.options["--dry-run"] == "true"
    ))
}

private func modUpdateApplyPipeline(args: Arguments, projectRoot: URL) throws -> ModUpdateApplyPipeline {
    let releaseRoot = URL(fileURLWithPath: try args.require("--release-root"), isDirectory: true).standardizedFileURL
    let publicDownloads = URL(fileURLWithPath: try args.require("--public-downloads"), isDirectory: true).standardizedFileURL
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    return ModUpdateApplyPipeline(config: ModUpdateApplyPipelineConfig(
        projectRoot: projectRoot,
        releaseRoot: releaseRoot,
        publicDownloads: publicDownloads,
        databaseURL: duckDB,
        minecraftVersion: args.options["--minecraft-version"],
        allSupported: optionBool(args.options["--all-supported"]),
        releaseIDPrefix: try args.require("--release-id-prefix"),
        activateLiveVersions: args.options["--activate-live"] != "false",
        dryRun: args.options["--dry-run"] != "false",
        serverPackageDirectory: URL(fileURLWithPath: args.options["--server-package"] ?? envOrDefault("PUMMELCHEN_SERVER_PACKAGE_DIR", defaultPath: projectRoot.appendingPathComponent("Server App/MCPummelchenModServer").path)),
        serviceName: args.options["--service"],
        clientAPIToken: args.options["--client-api-token"],
        requireClientToken: optionBool(args.options["--require-client-token"], defaultValue: optionBool(ProcessInfo.processInfo.environment["PUMMELCHEN_REQUIRE_CLIENT_TOKEN"]))
    ))
}

private func serverVersionBootstrapPipeline(args: Arguments, projectRoot: URL) throws -> ServerVersionBootstrapPipeline {
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let maxURLs = Int(args.options["--max-urls-per-window"] ?? "5") ?? 5
    let windowSeconds = Double(args.options["--window-seconds"] ?? "10") ?? 10
    let discoverySearchesPerSecond = Double(args.options["--discovery-searches-per-second"] ?? "2") ?? 2
    guard maxURLs > 0 else {
        throw ServerCommandError.invalidValue("--max-urls-per-window must be greater than zero")
    }
    guard windowSeconds >= 0 else {
        throw ServerCommandError.invalidValue("--window-seconds must be zero or greater")
    }
    guard discoverySearchesPerSecond > 0, discoverySearchesPerSecond <= 2 else {
        throw ServerCommandError.invalidValue("--discovery-searches-per-second must be greater than zero and at most 2")
    }
    let releaseRoot = args.options["--release-root"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    let publicDownloads = args.options["--public-downloads"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    let serverPackage = args.options["--server-package"].map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    return ServerVersionBootstrapPipeline(config: ServerVersionBootstrapPipelineConfig(
        projectRoot: projectRoot,
        databaseURL: duckDB,
        targetMinecraftVersion: try args.require("--minecraft-version"),
        referenceMinecraftVersion: args.options["--reference-minecraft-version"],
        discoverSourceLinks: optionBool(args.options["--discover-source-links"], defaultValue: true),
        discoveryLimit: args.options["--discovery-limit"].flatMap(Int.init),
        discoverySearchesPerSecond: discoverySearchesPerSecond,
        maxURLsPerWindow: maxURLs,
        windowSeconds: windowSeconds,
        dryRun: args.options["--dry-run"] != "false",
        applyUpdates: optionBool(args.options["--apply-updates"]),
        releaseRoot: releaseRoot,
        publicDownloads: publicDownloads,
        releaseIDPrefix: args.options["--release-id-prefix"],
        serverPackageDirectory: serverPackage,
        serviceName: args.options["--service"],
        clientAPIToken: args.options["--client-api-token"],
        requireClientToken: optionBool(args.options["--require-client-token"], defaultValue: optionBool(ProcessInfo.processInfo.environment["PUMMELCHEN_REQUIRE_CLIENT_TOKEN"]))
    ))
}

private struct SupportedVersionForScan {
    let minecraftVersion: String
    let loader: String
    let loaderVersion: String?
}

private struct VersionedScanSummary {
    let version: SupportedVersionForScan
    let summary: ModUpdateScanSummary
}

private func runAllSupportedModUpdateScans(args: Arguments, projectRoot: URL) throws -> [VersionedScanSummary] {
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let versions = try supportedVersionsForScanning(databaseURL: duckDB)
    guard !versions.isEmpty else {
        throw ServerCommandError.invalidValue("no live or staging Minecraft server versions found in DuckDB")
    }
    var summaries: [VersionedScanSummary] = []
    for version in versions {
        let scanner = try modUpdateScanner(
            args: args,
            projectRoot: projectRoot,
            minecraftVersion: version.minecraftVersion,
            loader: version.loader,
            loaderVersion: version.loaderVersion
        )
        summaries.append(VersionedScanSummary(version: version, summary: try scanner.run()))
    }
    return summaries
}

private func supportedVersionsForScanning(databaseURL: URL) throws -> [SupportedVersionForScan] {
    let csv = try DuckDBDatabase(databaseURL: databaseURL, readOnly: true).queryCSV("""
    SELECT minecraft_version, loader, loader_version
    FROM core.minecraft_server_versions
    WHERE lower(status) IN ('live', 'staging')
    ORDER BY sort_order, minecraft_version;
    """)
    return parseCSVRows(csv).compactMap { row in
        guard row.count >= 3, !row[0].isEmpty else {
            return nil
        }
        return SupportedVersionForScan(
            minecraftVersion: row[0],
            loader: row[1].isEmpty ? "neoforge" : row[1],
            loaderVersion: row[2].isEmpty ? nil : row[2]
        )
    }
}

private func serverKey(minecraftVersion: String) -> String {
    "minecraft_\(minecraftVersion.replacingOccurrences(of: ".", with: "_"))"
}

private func optionBool(_ value: String?, defaultValue: Bool = false) -> Bool {
    guard let value else { return defaultValue }
    if ["1", "true", "yes", "y"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
        return true
    }
    if ["0", "false", "no", "n", "off"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
        return false
    }
    return defaultValue
}

private func envOrDefault(_ key: String, defaultPath: String) -> String {
    let env = ProcessInfo.processInfo.environment
    return env[key] ?? defaultPath
}

private func parseCSVRows(_ csv: String) -> [[String]] {
    csv.split(separator: "\n").dropFirst().map { parseCSVLine(String($0)) }
}

private func parseCSVLine(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var quoted = false
    let characters = Array(line)
    var index = 0
    while index < characters.count {
        let char = characters[index]
        if char == "\"" {
            if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                current.append("\"")
                index += 2
                continue
            }
            quoted.toggle()
        } else if char == ",", !quoted {
            fields.append(current)
            current = ""
        } else {
            current.append(char)
        }
        index += 1
    }
    fields.append(current)
    return fields
}

private func worldResetPipeline(args: Arguments, projectRoot: URL) throws -> SwiftWorldResetPipeline {
    let serverDir = URL(fileURLWithPath: try args.require("--server-dir"), isDirectory: true).standardizedFileURL
    let duckDB = URL(fileURLWithPath: try args.require("--duckdb")).standardizedFileURL
    let radius = Int(args.options["--radius-blocks"] ?? "1000") ?? 1000
    let shape = PregenerationShape(rawValue: args.options["--shape"] ?? "circle") ?? .circle
    let rconPort = Int(args.options["--rcon-port"] ?? "25575") ?? 25575
    let rconReadyTimeout = TimeInterval(args.options["--rcon-ready-timeout-seconds"] ?? "600") ?? 600
    let batchSize = Int(args.options["--pregeneration-batch-size"] ?? "384") ?? 384
    let config = SwiftWorldResetConfig(
        projectRoot: projectRoot,
        serverDir: serverDir,
        databaseURL: duckDB,
        serviceName: args.options["--service"] ?? "pummelchen-minecraft.service",
        seed: args.options["--seed"] ?? defaultSafeWorldResetSeed,
        radiusBlocks: radius,
        shape: shape,
        dryRun: args.options["--dry-run"] != "false",
        confirmDestructive: args.options["--yes"] == "true",
        deleteBackupAfterSuccess: args.options["--delete-backup-after-success"] == "true",
        actor: args.options["--actor"] ?? "pummelchen-swift-world-reset",
        rconHost: args.options["--rcon-host"] ?? "127.0.0.1",
        rconPort: rconPort,
        rconPassword: args.options["--rcon-password"],
        rconReadyTimeoutSeconds: rconReadyTimeout,
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
