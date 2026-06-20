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

    public init(
        enabled: Bool,
        serverDirectory: URL,
        startCommand: String = "./run.sh nogui",
        host: String = "127.0.0.1",
        port: UInt16 = 25565,
        logFile: URL? = nil
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
        return Self(
            enabled: true,
            serverDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            startCommand: environment["PUMMELCHEN_MINECRAFT_START_COMMAND"] ?? "./run.sh nogui",
            host: environment["PUMMELCHEN_MINECRAFT_HOST"] ?? "127.0.0.1",
            port: portValue,
            logFile: logFile
        )
    }

    private static func bool(_ value: String?) -> Bool {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(normalized)
    }
}

public final class MinecraftLiveServerSupervisor: @unchecked Sendable {
    private let config: MinecraftLiveServerSupervisorConfig
    private var process: Process?
    private var logHandle: FileHandle?
    private let fileManager: FileManager

    public init(config: MinecraftLiveServerSupervisorConfig, fileManager: FileManager = .default) {
        self.config = config
        self.fileManager = fileManager
    }

    deinit {
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
        process.terminationHandler = { process in
            let message = "minecraft_process=terminated pid=\(process.processIdentifier) status=\(process.terminationStatus)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        try process.run()
        self.process = process
        self.logHandle = handle
        log("minecraft_autostart=started pid=\(process.processIdentifier) dir=\(config.serverDirectory.path) command=\(config.startCommand)")
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
