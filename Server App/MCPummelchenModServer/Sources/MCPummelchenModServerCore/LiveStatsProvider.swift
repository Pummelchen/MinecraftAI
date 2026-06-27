import Foundation
import MCPummelchenModShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct LiveStatsPayload: Codable, Equatable, Sendable {
    public let generatedAt: String
    public let intervalSeconds: Int
    public let stats: [String: String]
    public let metrics: LiveMetricSample
    public let history: [LiveMetricSample]
    public let worldSeed: String?

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case intervalSeconds = "interval_seconds"
        case stats
        case metrics
        case history
        case worldSeed = "world_seed"
    }
}

public struct LiveMetricSample: Codable, Equatable, Sendable {
    public let t: String
    public let cpuPercent: Double
    public let ramUsedPercent: Double
    public let ramUsedGB: Double
    public let ramTotalGB: Double
    public let diskUsedPercent: Double
    public let diskUsedGB: Double
    public let diskTotalGB: Double
    public let diskFreePercent: Double
    public let diskFreeGB: Double
    public let networkTrafficPercent: Double

    enum CodingKeys: String, CodingKey {
        case t
        case cpuPercent = "cpu_percent"
        case ramUsedPercent = "ram_used_percent"
        case ramUsedGB = "ram_used_gb"
        case ramTotalGB = "ram_total_gb"
        case diskUsedPercent = "disk_used_percent"
        case diskUsedGB = "disk_used_gb"
        case diskTotalGB = "disk_total_gb"
        case diskFreePercent = "disk_free_percent"
        case diskFreeGB = "disk_free_gb"
        case networkTrafficPercent = "network_traffic_percent"
    }
}

final class LiveStatsProvider: @unchecked Sendable {
    private static let defaultWorldSeed = "5605164115430518763"

    private struct CPUTimes {
        let idle: UInt64
        let total: UInt64
    }

    private struct NetworkCounters {
        let timestamp: Date
        let bytes: UInt64
    }

    private let projectRoot: URL
    private let duckDBURL: URL
    private let lock = NSLock()
    private var previousCPU: CPUTimes?
    private var previousNetwork: NetworkCounters?
    private var history: [LiveMetricSample] = []
    private var cachedPayload: (createdAt: Date, payload: LiveStatsPayload)?

    init(projectRoot: URL, duckDBURL: URL? = nil) {
        self.projectRoot = projectRoot
        self.duckDBURL = duckDBURL ?? projectRoot.appendingPathComponent("data/pummelchen.duckdb")
    }

    func payload() throws -> LiveStatsPayload {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let cachedPayload, now.timeIntervalSince(cachedPayload.createdAt) < 5 {
            return cachedPayload.payload
        }

        let timestamp = Self.isoTimestamp(now)
        let release = try? CurrentReleaseValidator.decode(readCurrentReleaseData())
        let metrics = sampleMetrics(timestamp: timestamp, now: now)
        history.append(metrics)
        if history.count > 120 {
            history.removeFirst(history.count - 120)
        }

        var stats = staticStats(release: release)
        stats["Generated"] = Self.displayTimestamp(now)
        stats["CPU usage"] = Self.percent(metrics.cpuPercent)
        stats["RAM used"] = "\(Self.gigabytes(memoryUsedBytes())) GB (\(Self.percent(metrics.ramUsedPercent)))"
        stats["RAM available"] = "\(Self.gigabytes(memoryAvailableBytes())) GB"
        stats["Disk used/free"] = diskSummary(metrics: metrics)
        stats["Network traffic"] = networkSummary(percent: metrics.networkTrafficPercent)
        stats["Server Address"] = serverAddress()
        stats["Web Address"] = webAddress()
        let clientCounts = clientPackageCounts(release: release)
        stats["Server Mods"] = "\(serverModCount() ?? clientCounts.mods) Server Mods"
        stats["Client Mods"] = "\(clientCounts.mods) Client Mods · \(clientCounts.shaderpacks) Shaders · \(clientCounts.resourcepacks) Resource Packs · \(clientCounts.config) Config Files"
        stats["Failed Mods"] = "\(failedModCount()) Failed Mods"
        stats["Mac Installer DMG URL"] = macInstallerDMGURL(release: release)

        let payload = LiveStatsPayload(
            generatedAt: timestamp,
            intervalSeconds: 5,
            stats: stats,
            metrics: metrics,
            history: history,
            worldSeed: worldSeed()
        )
        cachedPayload = (now, payload)
        return payload
    }

    private func sampleMetrics(timestamp: String, now: Date) -> LiveMetricSample {
        let cpuPercent = currentCPUPercent()
        let memory = memorySnapshot()
        let disk = diskSnapshot()
        let networkPercent = currentNetworkPercent(now: now)
        return LiveMetricSample(
            t: timestamp,
            cpuPercent: cpuPercent,
            ramUsedPercent: memory.usedPercent,
            ramUsedGB: Self.decimalGigabytesDouble(memory.used),
            ramTotalGB: Self.decimalGigabytesDouble(memory.total),
            diskUsedPercent: disk.usedPercent,
            diskUsedGB: Self.decimalGigabytesDouble(disk.used),
            diskTotalGB: Self.decimalGigabytesDouble(disk.total),
            diskFreePercent: disk.freePercent,
            diskFreeGB: disk.freeGB,
            networkTrafficPercent: networkPercent
        )
    }

    private func staticStats(release: CurrentRelease?) -> [String: String] {
        var stats: [String: String] = [
            "Minecraft Players": minecraftPlayers(),
            "Server OS": osRelease(),
            "OS Kernel": readFirstLine("/proc/sys/kernel/osrelease") ?? runAndCapture("/usr/bin/uname", ["-r"]) ?? "unknown",
            "Uptime": uptime(),
            "CPU": cpuModel(),
            "CPU Cores": cpuCores(),
            "Server Java": javaVersion(),
            "Minecraft Java": javaVersion()
        ]

        if let release {
            stats["Last Mod Version"] = displayReleaseID(release.releaseID)
            stats["Mac Installer Latest Version"] = "Latest version: \(displayShortReleaseVersion(release.releaseID))"
            stats["Mac Installer Release URL"] = macInstallerDMGURL(release: release)
            stats["Minecraft"] = release.minecraftVersion ?? "unknown"
            stats["NeoForge"] = release.loaderVersion ?? "unknown"
            stats["Client Mod Pack SHA256"] = release.clientZipSHA256
            if let zip = urlForPublicPath(release.clientZipURL),
               let attributes = try? FileManager.default.attributesOfItem(atPath: zip.path),
               let size = attributes[.size] as? NSNumber {
                stats["Client Mod Pack"] = Self.humanFileSize(size.uint64Value)
            }
            if let created = Self.date(from: release.createdAt) {
                stats["Client Mod Pack Generated"] = Self.displayTimestamp(created)
                stats["Client Mod Pack Generated ISO"] = Self.isoTimestamp(created)
            }
        }
        return stats
    }

    private func currentCPUPercent() -> Double {
        guard let current = readCPUTimes() else { return 0 }
        defer { previousCPU = current }
        guard let previous = previousCPU else {
            return min(100, loadAveragePercent())
        }
        let totalDelta = current.total > previous.total ? current.total - previous.total : 0
        let idleDelta = current.idle > previous.idle ? current.idle - previous.idle : 0
        guard totalDelta > 0 else { return 0 }
        return Self.roundPercent(Double(totalDelta - idleDelta) * 100.0 / Double(totalDelta))
    }

    private func readCPUTimes() -> CPUTimes? {
        guard let line = readFirstLine("/proc/stat"), line.hasPrefix("cpu ") else { return nil }
        let values = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard values.count >= 4 else { return nil }
        let idle = values[3] + (values.count > 4 ? values[4] : 0)
        let total = values.reduce(0, +)
        return CPUTimes(idle: idle, total: total)
    }

    private func loadAveragePercent() -> Double {
        guard let line = readFirstLine("/proc/loadavg"),
              let first = line.split(separator: " ").first,
              let load = Double(first) else {
            return 0
        }
        let cores = max(1.0, Double(ProcessInfo.processInfo.processorCount))
        return Self.roundPercent(min(100, load / cores * 100.0))
    }

    private func memorySnapshot() -> (usedPercent: Double, total: UInt64, available: UInt64, used: UInt64) {
        let values = meminfo()
        let total = values["MemTotal"] ?? 0
        let available = values["MemAvailable"] ?? 0
        guard total > 0 else { return (0, 0, 0, 0) }
        let used = total > available ? total - available : 0
        return (Self.roundPercent(Double(used) * 100.0 / Double(total)), total, available, used)
    }

    private func memoryUsedBytes() -> UInt64 {
        let snapshot = memorySnapshot()
        return snapshot.used
    }

    private func memoryAvailableBytes() -> UInt64 {
        memorySnapshot().available
    }

    private func meminfo() -> [String: UInt64] {
        guard let data = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else { return [:] }
        var result: [String: UInt64] = [:]
        for line in data.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let key = String(parts[0].dropLast())
            if let kib = UInt64(parts[1]) {
                result[key] = kib * 1024
            }
        }
        return result
    }

    private func diskSnapshot() -> (usedPercent: Double, freePercent: Double, freeGB: Double, total: UInt64, free: UInt64, used: UInt64) {
        let url = projectRoot
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let totalNumber = values[.systemSize] as? NSNumber,
              let freeNumber = values[.systemFreeSize] as? NSNumber else {
            return (0, 0, 0, 0, 0, 0)
        }
        let total = totalNumber.uint64Value
        let free = freeNumber.uint64Value
        let used = total > free ? total - free : 0
        guard total > 0 else { return (0, 0, 0, total, free, used) }
        let usedPercent = Self.roundPercent(Double(used) * 100.0 / Double(total))
        let freePercent = Self.roundPercent(Double(free) * 100.0 / Double(total))
        return (usedPercent, freePercent, Self.gigabytesDouble(free), total, free, used)
    }

    private func currentNetworkPercent(now: Date) -> Double {
        let current = NetworkCounters(timestamp: now, bytes: networkBytes())
        defer { previousNetwork = current }
        guard let previous = previousNetwork else { return 0 }
        let elapsed = max(0.001, now.timeIntervalSince(previous.timestamp))
        let bytesDelta = current.bytes > previous.bytes ? current.bytes - previous.bytes : 0
        let bitsPerSecond = Double(bytesDelta) * 8.0 / elapsed
        let oneGigabit = 1_000_000_000.0
        return Self.roundPercent(min(100, bitsPerSecond / oneGigabit * 100.0))
    }

    private func networkBytes() -> UInt64 {
        guard let data = try? String(contentsOfFile: "/proc/net/dev", encoding: .utf8) else { return 0 }
        var total: UInt64 = 0
        for line in data.split(separator: "\n") {
            guard line.contains(":") else { continue }
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let interface = pair[0].trimmingCharacters(in: .whitespaces)
            guard interface != "lo" else { continue }
            let fields = pair[1].split(separator: " ").compactMap { UInt64($0) }
            if fields.count >= 9 {
                total += fields[0] + fields[8]
            }
        }
        return total
    }

    private func diskSummary(metrics: LiveMetricSample) -> String {
        let disk = diskSnapshot()
        let usedGB = disk.total > disk.free ? Self.gigabytesDouble(disk.total - disk.free) : 0
        return "\(Self.decimal(usedGB)) GB / \(Self.decimal(Self.gigabytesDouble(disk.total))) GB (\(Self.percent(metrics.diskUsedPercent))); \(Self.decimal(metrics.diskFreeGB)) GB free"
    }

    private func networkSummary(percent: Double) -> String {
        "\(Self.percent(percent)) of 1.0 Gbps interface budget"
    }

    private func minecraftPlayers() -> String {
        let maxPlayers = serverProperty("max-players") ?? "100"
        if Self.isTCPPortOpen(host: minecraftStatusHost(), port: minecraftStatusPort()) {
            return "0 / \(maxPlayers)"
        }
        return "unavailable / \(maxPlayers)"
    }

    private func minecraftStatusHost() -> String {
        ProcessInfo.processInfo.environment["PUMMELCHEN_MINECRAFT_HOST"] ?? "127.0.0.1"
    }

    private func minecraftStatusPort() -> UInt16 {
        ProcessInfo.processInfo.environment["PUMMELCHEN_MINECRAFT_PORT"].flatMap(UInt16.init) ?? 25565
    }

    private func serverAddress() -> String {
        ProcessInfo.processInfo.environment["PUMMELCHEN_MINECRAFT_ADDRESS"] ?? "91.99.176.243:25565"
    }

    private func webAddress() -> String {
        ProcessInfo.processInfo.environment["PUMMELCHEN_WEB_ADDRESS"] ?? "https://pummelchen.91.99.176.243.nip.io"
    }

    private func serverModCount() -> Int? {
        let mods = projectRoot.appendingPathComponent("minecraft/mods", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: mods,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return entries.filter { url in
            url.pathExtension.localizedCaseInsensitiveCompare("jar") == .orderedSame
        }.count
    }

    private func clientPackageCounts(release: CurrentRelease?) -> (mods: Int, shaderpacks: Int, resourcepacks: Int, config: Int) {
        guard let release,
              let manifest = urlForPublicPath(release.manifestURL),
              let data = try? String(contentsOf: manifest, encoding: .utf8) else {
            return (0, 0, 0, 0)
        }
        return data.split(separator: "\n").reduce(into: (mods: 0, shaderpacks: 0, resourcepacks: 0, config: 0)) { counts, line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard !line.hasPrefix("#"), fields.count >= 2 else { return }
            let section = fields[0]
            let fileName = String(fields[1])
            let normalizedFileName = fileName.lowercased()
            switch section {
            case "mods":
                if normalizedFileName.hasSuffix(".jar") {
                    counts.mods += 1
                }
            case "shaderpacks":
                if normalizedFileName.hasSuffix(".zip") {
                    counts.shaderpacks += 1
                } else {
                    counts.config += 1
                }
            case "resourcepacks":
                if Self.isDefaultResourcePack(fileName) {
                    counts.resourcepacks += 1
                }
            case "config", "configs", "configuration":
                counts.config += 1
            default:
                break
            }
        }
    }

    private static func isDefaultResourcePack(_ fileName: String) -> Bool {
        fileName.localizedCaseInsensitiveContains("ModernArch")
    }

    private func failedModCount() -> Int {
        guard FileManager.default.fileExists(atPath: duckDBURL.path),
              let value = try? DuckDBDatabase(databaseURL: duckDBURL, readOnly: true).queryScalar("""
              SELECT COUNT(*)
              FROM core.failed_mod_update_status
              WHERE lower(active_status) IN ('failed', 'banned by admin');
              """),
              let count = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return count
    }

    private func macInstallerDMGURL(release: CurrentRelease?) -> String {
        let rootPath = "/downloads/MCPummelchenModClient.dmg"
        if let rootURL = urlForPublicPath(rootPath), FileManager.default.fileExists(atPath: rootURL.path) {
            return rootPath
        }
        return rootPath
    }

    private func worldSeed() -> String? {
        if let seed = serverProperty("level-seed"), !seed.isEmpty {
            return seed
        }
        return Self.defaultWorldSeed
    }

    private func serverProperty(_ key: String) -> String? {
        let candidates = [
            projectRoot.appendingPathComponent("server/server.properties"),
            projectRoot.appendingPathComponent("minecraft/server.properties")
        ]
        for candidate in candidates {
            guard let data = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            for line in data.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == key {
                    return parts[1]
                }
            }
        }
        return nil
    }

    private func osRelease() -> String {
        guard let data = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        for key in ["PRETTY_NAME", "NAME"] {
            if let value = data
                .split(separator: "\n")
                .first(where: { $0.hasPrefix("\(key)=") })?
                .split(separator: "=", maxSplits: 1)
                .last {
                return String(value).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func uptime() -> String {
        guard let line = readFirstLine("/proc/uptime"),
              let first = line.split(separator: " ").first,
              let seconds = Double(first) else {
            return "unknown"
        }
        return Self.duration(Int(seconds))
    }

    private func cpuModel() -> String {
        guard let data = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else {
            return "CPU cores: \(ProcessInfo.processInfo.processorCount)"
        }
        for line in data.split(separator: "\n") where line.hasPrefix("model name") {
            return line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "unknown"
        }
        return "CPU cores: \(ProcessInfo.processInfo.processorCount)"
    }

    private func cpuCores() -> String {
        String(ProcessInfo.processInfo.processorCount)
    }

    private func javaVersion() -> String {
        if let version = runAndCapture("/usr/bin/java", ["-version"]) ?? runAndCapture("/usr/local/bin/java", ["-version"]) {
            return version.split(separator: "\n").first.map(String.init) ?? version
        }
        return "not found"
    }

    private func readCurrentReleaseData() throws -> Data {
        try Data(contentsOf: projectRoot.appendingPathComponent("site/public/downloads/current-release.json"))
    }

    private func urlForPublicPath(_ path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return projectRoot.appendingPathComponent("site/public").appendingPathComponent(String(path.dropFirst()))
    }

    private func displayReleaseID(_ releaseID: String) -> String {
        var value = releaseID
        if value.hasPrefix("release_") {
            value.removeFirst("release_".count)
        }
        return value.replacingOccurrences(of: "_", with: " ")
    }

    private func displayShortReleaseVersion(_ releaseID: String) -> String {
        var value = releaseID
        if value.hasPrefix("release_") {
            value.removeFirst("release_".count)
        }
        let parts = value.split(separator: "_", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return value
        }
        let date = String(parts[0])
        let version = String(parts[1])
        guard date.count == 8, date.allSatisfy(\.isNumber), version.hasPrefix("V") else {
            return value
        }
        let year = date.prefix(4)
        let month = date.dropFirst(4).prefix(2)
        let day = date.suffix(2)
        return "\(year)-\(month)-\(day)_\(version)"
    }

    private func readFirstLine(_ path: String) -> String? {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return data.split(separator: "\n").first.map(String.init)
    }

    private func runAndCapture(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private static func isoTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func date(from value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: date)
    }

    private static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static func humanFileSize(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824.0
        if gib >= 1 { return "\(decimal(gib)) GB" }
        let mib = Double(bytes) / 1_048_576.0
        return "\(decimal(mib)) MB"
    }

    private static func gigabytes(_ bytes: UInt64) -> String {
        decimal(gigabytesDouble(bytes))
    }

    private static func gigabytesDouble(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_073_741_824.0
    }

    private static func decimalGigabytesDouble(_ bytes: UInt64) -> Double {
        Double(bytes) / 1_000_000_000.0
    }

    private static func percent(_ value: Double) -> String {
        "\(decimal(value))%"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func roundPercent(_ value: Double) -> Double {
        (value * 100).rounded() / 100
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
}

public final class LiveStatsPublisher: @unchecked Sendable {
    private let provider: LiveStatsProvider
    private let outputURL: URL
    private let intervalSeconds: TimeInterval
    private let encoder: JSONEncoder
    private let queue = DispatchQueue(label: "pummelchen.live-stats-publisher")
    private var isRunning = false

    public init(projectRoot: URL, intervalSeconds: TimeInterval = 5) {
        self.provider = LiveStatsProvider(projectRoot: projectRoot)
        self.outputURL = projectRoot.appendingPathComponent("site/public/live-stats.json")
        self.intervalSeconds = max(1, intervalSeconds)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func start() {
        queue.async { [self] in
            guard !isRunning else {
                return
            }
            isRunning = true
            publishLoop()
        }
    }

    private func publishLoop() {
        while isRunning {
            do {
                try publishOnce()
            } catch {
                FileHandle.standardError.write(Data("live_stats_publish_error=\(error)\n".utf8))
            }
            Thread.sleep(forTimeInterval: intervalSeconds)
        }
    }

    public func publishOnce() throws {
        let payload = try provider.payload()
        let data = try encoder.encode(payload)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }
}
