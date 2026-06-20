import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct MinecraftLiveServerSupervisorConfig: Sendable {
    public let enabled: Bool
    public let serverDirectory: URL
    public let startCommand: String
    public let host: String
    public let port: UInt16
    public let logFile: URL
    public let watchdogEnabled: Bool
    public let watchdogStartupGraceSeconds: TimeInterval
    public let watchdogIntervalSeconds: TimeInterval
    public let watchdogFailureThreshold: Int
    public let watchdogCommandTimeoutSeconds: Int
    public let watchdogCommand: String
    public let gracefulStopTimeoutSeconds: TimeInterval
    public let rconHost: String
    public let rconPort: Int
    public let rconPassword: String?

    public init(
        enabled: Bool,
        serverDirectory: URL,
        startCommand: String = "./run.sh nogui",
        host: String = "127.0.0.1",
        port: UInt16 = 25565,
        logFile: URL? = nil,
        watchdogEnabled: Bool = true,
        watchdogStartupGraceSeconds: TimeInterval = 300,
        watchdogIntervalSeconds: TimeInterval = 60,
        watchdogFailureThreshold: Int = 3,
        watchdogCommandTimeoutSeconds: Int = 5,
        watchdogCommand: String = "time query gametime",
        gracefulStopTimeoutSeconds: TimeInterval = 75,
        rconHost: String = "127.0.0.1",
        rconPort: Int = 25575,
        rconPassword: String? = nil
    ) {
        self.enabled = enabled
        self.serverDirectory = serverDirectory.standardizedFileURL
        self.startCommand = startCommand
        self.host = host
        self.port = port
        self.logFile = logFile ?? serverDirectory
            .standardizedFileURL
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("minecraft-live.log")
        self.watchdogEnabled = watchdogEnabled
        self.watchdogStartupGraceSeconds = max(0, watchdogStartupGraceSeconds)
        self.watchdogIntervalSeconds = max(10, watchdogIntervalSeconds)
        self.watchdogFailureThreshold = max(1, watchdogFailureThreshold)
        self.watchdogCommandTimeoutSeconds = max(1, watchdogCommandTimeoutSeconds)
        self.watchdogCommand = watchdogCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "time query gametime" : watchdogCommand
        self.gracefulStopTimeoutSeconds = max(10, gracefulStopTimeoutSeconds)
        self.rconHost = rconHost
        self.rconPort = rconPort
        self.rconPassword = rconPassword?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Self? {
        guard bool(environment["PUMMELCHEN_MINECRAFT_AUTOSTART"]) else {
            return nil
        }
        guard let directory = environment["PUMMELCHEN_MINECRAFT_DIR"], !directory.isEmpty else {
            return nil
        }

        let portValue = environment["PUMMELCHEN_MINECRAFT_PORT"].flatMap(UInt16.init) ?? 25565
        let logFile = environment["PUMMELCHEN_MINECRAFT_LOG"].map { URL(fileURLWithPath: $0) }
        let watchdogStartupGrace = environment["PUMMELCHEN_MINECRAFT_WATCHDOG_STARTUP_GRACE_SECONDS"].flatMap(TimeInterval.init) ?? 300
        let watchdogInterval = environment["PUMMELCHEN_MINECRAFT_WATCHDOG_INTERVAL_SECONDS"].flatMap(TimeInterval.init) ?? 60
        let watchdogFailureThreshold = environment["PUMMELCHEN_MINECRAFT_WATCHDOG_FAILURE_THRESHOLD"].flatMap(Int.init) ?? 3
        let watchdogCommandTimeout = environment["PUMMELCHEN_MINECRAFT_WATCHDOG_COMMAND_TIMEOUT_SECONDS"].flatMap(Int.init) ?? 5
        let gracefulStopTimeout = environment["PUMMELCHEN_MINECRAFT_GRACEFUL_STOP_TIMEOUT_SECONDS"].flatMap(TimeInterval.init) ?? 75
        return Self(
            enabled: true,
            serverDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            startCommand: environment["PUMMELCHEN_MINECRAFT_START_COMMAND"] ?? "./run.sh nogui",
            host: environment["PUMMELCHEN_MINECRAFT_HOST"] ?? "127.0.0.1",
            port: portValue,
            logFile: logFile,
            watchdogEnabled: bool(environment["PUMMELCHEN_MINECRAFT_WATCHDOG"], default: true),
            watchdogStartupGraceSeconds: watchdogStartupGrace,
            watchdogIntervalSeconds: watchdogInterval,
            watchdogFailureThreshold: watchdogFailureThreshold,
            watchdogCommandTimeoutSeconds: watchdogCommandTimeout,
            watchdogCommand: environment["PUMMELCHEN_MINECRAFT_WATCHDOG_COMMAND"] ?? "time query gametime",
            gracefulStopTimeoutSeconds: gracefulStopTimeout,
            rconHost: environment["PUMMELCHEN_MINECRAFT_RCON_HOST"] ?? "127.0.0.1",
            rconPort: environment["PUMMELCHEN_MINECRAFT_RCON_PORT"].flatMap(Int.init) ?? 25575,
            rconPassword: environment["PUMMELCHEN_MINECRAFT_RCON_PASSWORD"]
        )
    }

    private static func bool(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(normalized)
    }

    private static func bool(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
            return defaultValue
        }
        return ["1", "true", "yes", "on"].contains(normalized)
    }
}

public final class MinecraftLiveServerSupervisor: @unchecked Sendable {
    private let config: MinecraftLiveServerSupervisorConfig
    private var process: Process?
    private var logHandle: FileHandle?
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var watchdogTimer: DispatchSourceTimer?
    private var consecutiveWatchdogFailures = 0
    private var restartInProgress = false

    public init(config: MinecraftLiveServerSupervisorConfig, fileManager: FileManager = .default) {
        self.config = config
        self.fileManager = fileManager
    }

    deinit {
        watchdogTimer?.cancel()
        try? logHandle?.close()
    }

    public func startIfNeeded() throws {
        guard config.enabled else {
            log("minecraft_autostart=disabled")
            return
        }

        guard fileManager.fileExists(atPath: config.serverDirectory.path) else {
            throw MCPummelchenModServerError.badRequest("Minecraft server directory is missing: \(config.serverDirectory.path)")
        }

        try startProcessIfPortClosed()
        startWatchdogIfNeeded()
    }

    private func startProcessIfPortClosed() throws {
        let command = Self.parseShellLikeCommand(config.startCommand)
        guard let first = command.first, !first.isEmpty else {
            throw MCPummelchenModServerError.badRequest("Minecraft start command is empty")
        }
        let executable = Self.resolveCommandExecutable(first, serverDirectory: config.serverDirectory)
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            throw MCPummelchenModServerError.badRequest("Minecraft start executable is missing or not executable: \(executable.path)")
        }

        if Self.isTCPPortOpen(host: config.host, port: config.port) {
            log("minecraft_autostart=already_running host=\(config.host) port=\(config.port)")
            return
        }

        let handle = try openLogHandle()
        let process = Process()
        process.currentDirectoryURL = config.serverDirectory
        process.executableURL = executable
        process.arguments = Array(command.dropFirst())
        process.standardOutput = handle
        process.standardError = handle
        process.terminationHandler = { [weak self] process in
            let message = "minecraft_process=terminated pid=\(process.processIdentifier) status=\(process.terminationStatus)\n"
            FileHandle.standardError.write(Data(message.utf8))
            self?.clearProcessIfCurrent(process)
        }

        try process.run()
        setProcess(process)
        self.logHandle = handle
        log("minecraft_autostart=started pid=\(process.processIdentifier) dir=\(config.serverDirectory.path) command=\(config.startCommand)")
    }

    private func startWatchdogIfNeeded() {
        guard config.enabled, config.watchdogEnabled else {
            log("minecraft_watchdog=disabled")
            return
        }
        guard resolvedRCONPassword() != nil else {
            log("minecraft_watchdog=disabled reason=missing_rcon_password")
            return
        }

        stateLock.lock()
        if watchdogTimer != nil {
            stateLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdogTimer = timer
        stateLock.unlock()

        timer.schedule(deadline: .now() + config.watchdogStartupGraceSeconds, repeating: config.watchdogIntervalSeconds)
        timer.setEventHandler { [weak self] in
            self?.runWatchdogProbe()
        }
        timer.resume()
        log("minecraft_watchdog=started startup_grace_seconds=\(Int(config.watchdogStartupGraceSeconds)) interval_seconds=\(Int(config.watchdogIntervalSeconds)) failure_threshold=\(config.watchdogFailureThreshold) command=\(Self.shellSafeLogValue(config.watchdogCommand))")
    }

    private func runWatchdogProbe() {
        stateLock.lock()
        let restartBusy = restartInProgress
        stateLock.unlock()
        guard !restartBusy else {
            return
        }

        do {
            try probeMinecraftServerThread()
            stateLock.lock()
            let recovered = consecutiveWatchdogFailures > 0
            consecutiveWatchdogFailures = 0
            stateLock.unlock()
            if recovered {
                log("minecraft_watchdog=recovered")
            }
        } catch {
            let failureCount: Int
            stateLock.lock()
            consecutiveWatchdogFailures += 1
            failureCount = consecutiveWatchdogFailures
            stateLock.unlock()
            log("minecraft_watchdog=probe_failed count=\(failureCount) threshold=\(config.watchdogFailureThreshold) error=\(Self.redactSecrets(String(describing: error)))")
            guard failureCount >= config.watchdogFailureThreshold else {
                return
            }
            restartMinecraft(reason: "rcon_probe_failed_\(failureCount)_times")
        }
    }

    private func probeMinecraftServerThread() throws {
        guard Self.isTCPPortOpen(host: config.host, port: config.port) else {
            throw MCPummelchenModServerError.badRequest("Minecraft TCP port \(config.host):\(config.port) is closed")
        }
        guard let password = resolvedRCONPassword() else {
            throw MCPummelchenModServerError.badRequest("Minecraft RCON password is missing")
        }
        let client = MinecraftRCONClient(
            host: config.rconHost,
            port: config.rconPort,
            password: password,
            timeoutSeconds: config.watchdogCommandTimeoutSeconds
        )
        _ = try client.command(config.watchdogCommand)
    }

    private func restartMinecraft(reason: String) {
        stateLock.lock()
        if restartInProgress {
            stateLock.unlock()
            return
        }
        restartInProgress = true
        consecutiveWatchdogFailures = 0
        let currentProcess = process
        stateLock.unlock()
        defer {
            stateLock.lock()
            restartInProgress = false
            stateLock.unlock()
        }

        log("minecraft_watchdog=restart_started reason=\(Self.shellSafeLogValue(reason))")
        if let password = resolvedRCONPassword() {
            let client = MinecraftRCONClient(
                host: config.rconHost,
                port: config.rconPort,
                password: password,
                timeoutSeconds: config.watchdogCommandTimeoutSeconds
            )
            do {
                _ = try client.command("stop")
                log("minecraft_watchdog=stop_command_sent")
            } catch {
                log("minecraft_watchdog=stop_command_failed error=\(Self.redactSecrets(String(describing: error)))")
            }
        }

        if let currentProcess {
            waitForExitOrKill(currentProcess)
        } else {
            log("minecraft_watchdog=restart_no_managed_process")
        }

        waitForPortToClose(timeoutSeconds: 15)
        do {
            try startProcessIfPortClosed()
            log("minecraft_watchdog=restart_completed")
        } catch {
            log("minecraft_watchdog=restart_failed error=\(Self.redactSecrets(String(describing: error)))")
        }
    }

    private func waitForExitOrKill(_ process: Process) {
        let deadline = Date().addingTimeInterval(config.gracefulStopTimeoutSeconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
        guard process.isRunning else {
            return
        }
        log("minecraft_watchdog=force_kill pid=\(process.processIdentifier)")
        Self.forceKill(process.processIdentifier)
        process.waitUntilExit()
    }

    private func waitForPortToClose(timeoutSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Self.isTCPPortOpen(host: config.host, port: config.port), Date() < deadline {
            Thread.sleep(forTimeInterval: 1)
        }
    }

    private func resolvedRCONPassword() -> String? {
        if let password = config.rconPassword, !password.isEmpty {
            return password
        }
        let properties = config.serverDirectory.appendingPathComponent("server.properties")
        guard let contents = try? String(contentsOf: properties, encoding: .utf8) else {
            return nil
        }
        for line in contents.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("rcon.password=") else {
                continue
            }
            let value = String(trimmed.dropFirst("rcon.password=".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func setProcess(_ process: Process) {
        stateLock.lock()
        self.process = process
        stateLock.unlock()
    }

    private func clearProcessIfCurrent(_ terminatedProcess: Process) {
        stateLock.lock()
        if process === terminatedProcess {
            process = nil
        }
        stateLock.unlock()
    }

    private func openLogHandle() throws -> FileHandle {
        let logDirectory = config.logFile.deletingLastPathComponent()
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: config.logFile.path) {
            _ = fileManager.createFile(atPath: config.logFile.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: config.logFile)
        try handle.seekToEnd()
        let separator = "\n--- pummelchen swift supervisor \(Self.isoNow()) ---\n"
        try handle.write(contentsOf: Data(separator.utf8))
        return handle
    }

    private func log(_ message: String) {
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
    }

    private static func isTCPPortOpen(host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, socketStreamType(), 0)
        guard fd >= 0 else {
            return false
        }
        defer {
            close(fd)
        }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port.bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(host))

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func socketStreamType() -> Int32 {
        #if os(Linux)
        Int32(SOCK_STREAM.rawValue)
        #else
        Int32(SOCK_STREAM)
        #endif
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func forceKill(_ pid: Int32) {
        #if os(Linux)
        _ = Glibc.kill(pid, SIGKILL)
        #else
        _ = Darwin.kill(pid, SIGKILL)
        #endif
    }

    private static func shellSafeLogValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func redactSecrets(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(--rcon-password\s+)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(rcon\.password\s*=\s*)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(password=)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
    }

    private static func parseShellLikeCommand(_ value: String) -> [String] {
        let source = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty {
            return []
        }
        var result: [String] = []
        var current = ""
        var singleQuote = false
        var doubleQuote = false
        var escaped = false

        for scalar in source.unicodeScalars {
            let ch = scalar.value

            if escaped {
                current.append(Character(scalar))
                escaped = false
                continue
            }

            if ch == 0x5c { // \
                escaped = true
                continue
            }

            if ch == 0x27 && !doubleQuote { // '
                singleQuote.toggle()
                continue
            }

            if ch == 0x22 && !singleQuote { // "
                doubleQuote.toggle()
                continue
            }

            if ch == 0x20 && !singleQuote && !doubleQuote {
                if !current.isEmpty {
                    result.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(Character(scalar))
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result.filter { !$0.isEmpty }
    }

    private static func resolveCommandExecutable(_ command: String, serverDirectory: URL) -> URL {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        if trimmed.hasPrefix("~") {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        if trimmed.hasPrefix(".") {
            return serverDirectory.appendingPathComponent(trimmed).standardizedFileURL
        }

        let direct = serverDirectory.appendingPathComponent(trimmed).standardizedFileURL
        if FileManager.default.isExecutableFile(atPath: direct.path) {
            return direct
        }

        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent(trimmed).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return serverDirectory.appendingPathComponent(trimmed).standardizedFileURL
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
