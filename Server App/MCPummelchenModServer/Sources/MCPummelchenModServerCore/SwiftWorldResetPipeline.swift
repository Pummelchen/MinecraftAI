import Foundation
import PummelchenCore

public enum PregenerationShape: String, Codable, Sendable {
    case circle
    case square
}

public enum SwiftWorldResetError: Error, CustomStringConvertible {
    case destructiveConfirmationRequired
    case missingRequiredPath(String)
    case unsafeWorldName(String)
    case commandRequired(String)
    case commandFailed(String)
    case rconPasswordRequired
    case forceloadVerificationFailed(String)

    public var description: String {
        switch self {
        case .destructiveConfirmationRequired:
            return "destructive world reset requires explicit confirmation"
        case .missingRequiredPath(let path):
            return "missing required path: \(path)"
        case .unsafeWorldName(let value):
            return "unsafe level-name in server.properties: \(value)"
        case .commandRequired(let name):
            return "non-dry-run world reset requires \(name)"
        case .commandFailed(let message):
            return message
        case .rconPasswordRequired:
            return "world reset requires an RCON password in server.properties or --rcon-password when gamerule/pregeneration hooks are not provided"
        case .forceloadVerificationFailed(let message):
            return "forceload verification failed: \(message)"
        }
    }
}

public struct SwiftWorldResetConfig: Sendable {
    public let projectRoot: URL
    public let serverDir: URL
    public let databaseURL: URL
    public let serviceName: String
    public let seed: String
    public let radiusBlocks: Int
    public let shape: PregenerationShape
    public let dryRun: Bool
    public let confirmDestructive: Bool
    public let deleteBackupAfterSuccess: Bool
    public let actor: String
    public let stopCommand: String?
    public let startCommand: String?
    public let gameruleCommand: String?
    public let pregenerateCommand: String?
    public let verifyForceloadsCommand: String?
    public let rconHost: String
    public let rconPort: Int
    public let rconPassword: String?
    public let pregenerationBatchSize: Int

    public init(
        projectRoot: URL,
        serverDir: URL,
        databaseURL: URL,
        serviceName: String = "pummelchen-minecraft.service",
        seed: String,
        radiusBlocks: Int = 1000,
        shape: PregenerationShape = .circle,
        dryRun: Bool = true,
        confirmDestructive: Bool = false,
        deleteBackupAfterSuccess: Bool = false,
        actor: String = "pummelchen-swift-world-reset",
        stopCommand: String? = nil,
        startCommand: String? = nil,
        gameruleCommand: String? = nil,
        pregenerateCommand: String? = nil,
        verifyForceloadsCommand: String? = nil,
        rconHost: String = "127.0.0.1",
        rconPort: Int = 25575,
        rconPassword: String? = nil,
        pregenerationBatchSize: Int = 384
    ) {
        self.projectRoot = projectRoot
        self.serverDir = serverDir
        self.databaseURL = databaseURL
        self.serviceName = serviceName
        self.seed = seed
        self.radiusBlocks = radiusBlocks
        self.shape = shape
        self.dryRun = dryRun
        self.confirmDestructive = confirmDestructive
        self.deleteBackupAfterSuccess = deleteBackupAfterSuccess
        self.actor = actor
        self.stopCommand = stopCommand
        self.startCommand = startCommand
        self.gameruleCommand = gameruleCommand
        self.pregenerateCommand = pregenerateCommand
        self.verifyForceloadsCommand = verifyForceloadsCommand
        self.rconHost = rconHost
        self.rconPort = rconPort
        self.rconPassword = rconPassword
        self.pregenerationBatchSize = pregenerationBatchSize
    }
}

public struct SwiftWorldResetResult: Codable, Equatable, Sendable {
    public let jobID: String
    public let status: String
    public let seed: String
    public let radiusBlocks: Int
    public let shape: String
    public let worldName: String
    public let oldWorldPath: String
    public let backupPath: String?
    public let backupDeleted: Bool
    public let datapacksInstalled: [String]
    public let requiredDatapacksVerified: [String]
    public let gamerules: [String: String]
    public let pregenerationChunks: Int
    public let pregenerationSegments: Int
    public let forceloadsCleared: Bool
    public let activeWorldExists: Bool
}

public struct SwiftWorldResetPipeline: Sendable {
    public static let safetyGamerules: [String: String] = [
        "keep_inventory": "true",
        "mob_griefing": "false",
        "projectiles_can_break_blocks": "false",
        "block_explosion_drop_decay": "false",
        "mob_explosion_drop_decay": "false",
        "tnt_explodes": "false",
        "tnt_explosion_drop_decay": "false"
    ]

    private static let requiredDatapackFiles = [
        "pummelchen-welcome.zip": [
            "data/pummelchen/function/load.mcfunction",
            "data/pummelchen/function/tick.mcfunction",
            "data/minecraft/loot_table/chests/spawn_bonus_chest.json"
        ],
        "pummelchen-tropical-worldgen.zip": [
            "data/minecraft/worldgen/multi_noise_biome_source_parameter_list/overworld.json"
        ],
        "pummelchen-rich-ores.zip": [
            "data/minecraft/worldgen/configured_feature/ore_iron.json",
            "data/minecraft/worldgen/configured_feature/ore_gold.json",
            "data/minecraft/worldgen/configured_feature/ore_diamond_large.json"
        ]
    ]

    public let config: SwiftWorldResetConfig
    private var fileManager: FileManager { FileManager.default }

    public init(config: SwiftWorldResetConfig) {
        self.config = config
    }

    public func plan() throws -> SwiftWorldResetResult {
        try validateConfig()
        let worldName = try activeWorldName()
        let worldDir = try activeWorldDirectory(worldName: worldName)
        let chunks = Self.pregenerationChunks(spawn: (0, 0, 0), radiusBlocks: config.radiusBlocks, shape: config.shape)
        let segments = Self.chunkSegments(chunks)
        let datapacks = try requiredDatapackSources().map(\.lastPathComponent).sorted()
        return SwiftWorldResetResult(
            jobID: UUID().uuidString,
            status: "dry_run",
            seed: config.seed,
            radiusBlocks: config.radiusBlocks,
            shape: config.shape.rawValue,
            worldName: worldName,
            oldWorldPath: worldDir.path,
            backupPath: worldDir.path + ".planned-backup",
            backupDeleted: false,
            datapacksInstalled: datapacks,
            requiredDatapacksVerified: datapacks,
            gamerules: Self.safetyGamerules,
            pregenerationChunks: chunks.count,
            pregenerationSegments: segments.count,
            forceloadsCleared: true,
            activeWorldExists: fileManager.fileExists(atPath: worldDir.path)
        )
    }

    public func run() throws -> SwiftWorldResetResult {
        try validateConfig()
        if !config.dryRun {
            guard config.confirmDestructive else {
                throw SwiftWorldResetError.destructiveConfirmationRequired
            }
            try requireHook(config.stopCommand, name: "--stop-command")
            try requireHook(config.startCommand, name: "--start-command")
            try validateMinecraftExecutionControl()
        }
        let jobID = UUID().uuidString
        let requestedAt = Self.isoNow()
        let dryPlan = try plan()
        try persist(jobID: jobID, requestedAt: requestedAt, startedAt: nil, completedAt: nil, status: "requested", result: dryPlan, error: nil)
        if config.dryRun {
            try persist(jobID: jobID, requestedAt: requestedAt, startedAt: nil, completedAt: Self.isoNow(), status: "dry_run", result: dryPlan, error: nil)
            return SwiftWorldResetResult(
                jobID: jobID,
                status: "dry_run",
                seed: dryPlan.seed,
                radiusBlocks: dryPlan.radiusBlocks,
                shape: dryPlan.shape,
                worldName: dryPlan.worldName,
                oldWorldPath: dryPlan.oldWorldPath,
                backupPath: dryPlan.backupPath,
                backupDeleted: false,
                datapacksInstalled: dryPlan.datapacksInstalled,
                requiredDatapacksVerified: dryPlan.requiredDatapacksVerified,
                gamerules: dryPlan.gamerules,
                pregenerationChunks: dryPlan.pregenerationChunks,
                pregenerationSegments: dryPlan.pregenerationSegments,
                forceloadsCleared: true,
                activeWorldExists: dryPlan.activeWorldExists
            )
        }

        var startedAt: String?
        do {
            startedAt = Self.isoNow()
            try persist(jobID: jobID, requestedAt: requestedAt, startedAt: startedAt, completedAt: nil, status: "running", result: dryPlan, error: nil)
            try runHook(config.stopCommand, phase: "stop")

            let worldName = dryPlan.worldName
            let worldDir = try activeWorldDirectory(worldName: worldName)
            let backupPath = try backupWorld(worldDir: worldDir)
            try writeServerProperties(worldName: worldName)
            try installRequiredDatapacks(worldDir: worldDir)
            try runHook(config.startCommand, phase: "start")
            try applySafetyGamerules()

            let spawn = readLevelSpawn(worldDir: worldDir) ?? (0, 0, 0)
            let chunks = Self.pregenerationChunks(spawn: spawn, radiusBlocks: config.radiusBlocks, shape: config.shape)
            let segments = Self.chunkSegments(chunks)
            try pregenerateWorld(segments: segments)
            let forceloadsCleared = try verifyForceloadsCleared()

            var backupDeleted = false
            if config.deleteBackupAfterSuccess, let backupPath {
                try fileManager.removeItem(at: backupPath)
                backupDeleted = true
            }

            let datapacks = try requiredDatapackSources().map(\.lastPathComponent).sorted()
            let result = SwiftWorldResetResult(
                jobID: jobID,
                status: "completed",
                seed: config.seed,
                radiusBlocks: config.radiusBlocks,
                shape: config.shape.rawValue,
                worldName: worldName,
                oldWorldPath: worldDir.path,
                backupPath: backupPath?.path,
                backupDeleted: backupDeleted,
                datapacksInstalled: datapacks,
                requiredDatapacksVerified: datapacks,
                gamerules: Self.safetyGamerules,
                pregenerationChunks: chunks.count,
                pregenerationSegments: segments.count,
                forceloadsCleared: forceloadsCleared,
                activeWorldExists: fileManager.fileExists(atPath: worldDir.path)
            )
            try persist(jobID: jobID, requestedAt: requestedAt, startedAt: startedAt, completedAt: Self.isoNow(), status: "completed", result: result, error: nil)
            return result
        } catch {
            try? persist(jobID: jobID, requestedAt: requestedAt, startedAt: startedAt, completedAt: Self.isoNow(), status: "failed", result: dryPlan, error: String(describing: error))
            throw error
        }
    }

    public static func pregenerationChunks(spawn: (Int, Int, Int), radiusBlocks: Int, shape: PregenerationShape) -> [(Int, Int)] {
        let radius = max(0, radiusBlocks)
        let minChunkX = floorDiv(spawn.0 - radius, 16)
        let maxChunkX = floorDiv(spawn.0 + radius, 16)
        let minChunkZ = floorDiv(spawn.2 - radius, 16)
        let maxChunkZ = floorDiv(spawn.2 + radius, 16)
        var chunks: [(Int, Int)] = []
        for chunkX in minChunkX...maxChunkX {
            for chunkZ in minChunkZ...maxChunkZ {
                if shape == .circle {
                    let centerX = chunkX * 16 + 8
                    let centerZ = chunkZ * 16 + 8
                    let distance = Double((centerX - spawn.0) * (centerX - spawn.0) + (centerZ - spawn.2) * (centerZ - spawn.2)).squareRoot()
                    if distance > Double(radius) {
                        continue
                    }
                }
                chunks.append((chunkX, chunkZ))
            }
        }
        return chunks
    }

    public static func chunkSegments(_ chunks: [(Int, Int)]) -> [(startX: Int, z: Int, endX: Int, count: Int)] {
        let grouped = Dictionary(grouping: chunks, by: \.1)
        var result: [(Int, Int, Int, Int)] = []
        for z in grouped.keys.sorted() {
            let xs = Array(Set(grouped[z, default: []].map(\.0))).sorted()
            guard var start = xs.first else { continue }
            var previous = start
            for x in xs.dropFirst() {
                if x == previous + 1 {
                    previous = x
                } else {
                    result.append((start, z, previous, previous - start + 1))
                    start = x
                    previous = x
                }
            }
            result.append((start, z, previous, previous - start + 1))
        }
        return result
    }

    private func validateConfig() throws {
        try ContractValidation.require(config.radiusBlocks > 0, "world reset radius must be positive")
        try ContractValidation.require(config.rconPort > 0 && config.rconPort < 65_536, "RCON port must be in TCP port range")
        try ContractValidation.require(config.pregenerationBatchSize > 0, "pregeneration batch size must be positive")
        try ContractValidation.require(!config.seed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "world reset seed must not be empty")
        try requireDirectory(config.projectRoot)
        try requireDirectory(config.serverDir)
        _ = try activeWorldName()
        _ = try requiredDatapackSources()
    }

    private func validateMinecraftExecutionControl() throws {
        if hasHook(config.gameruleCommand), hasHook(config.pregenerateCommand), hasHook(config.verifyForceloadsCommand) {
            return
        }
        _ = try resolvedRCONPassword()
    }

    private func activeWorldName() throws -> String {
        let values = try readProperties(config.serverDir.appendingPathComponent("server.properties"))
        let name = values["level-name"] ?? "world"
        if name.hasPrefix("/")
            || name.split(separator: "/").contains("..")
            || name.contains("\\")
            || name.contains("\0")
            || name.isEmpty {
            throw SwiftWorldResetError.unsafeWorldName(name)
        }
        return name
    }

    private func activeWorldDirectory(worldName: String) throws -> URL {
        try SafePath(root: config.serverDir).validateChild(
            config.serverDir.appendingPathComponent(worldName, isDirectory: true)
        )
    }

    private func requiredDatapackSources() throws -> [URL] {
        let roots = [
            config.projectRoot.appendingPathComponent("server-datapacks", isDirectory: true),
            config.serverDir.appendingPathComponent("server-datapacks", isDirectory: true)
        ]
        var found: [String: URL] = [:]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            for file in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey]) where file.pathExtension.lowercased() == "zip" {
                found[file.lastPathComponent] = file
            }
        }
        for (name, requiredEntries) in Self.requiredDatapackFiles {
            guard let source = found[name] else {
                throw SwiftWorldResetError.missingRequiredPath("required datapack \(name)")
            }
            try validateZip(source, contains: requiredEntries)
        }
        return Self.requiredDatapackFiles.keys.compactMap { found[$0] }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func installRequiredDatapacks(worldDir: URL) throws {
        let serverDatapacks = config.serverDir.appendingPathComponent("server-datapacks", isDirectory: true)
        let worldDatapacks = worldDir.appendingPathComponent("datapacks", isDirectory: true)
        try fileManager.createDirectory(at: serverDatapacks, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worldDatapacks, withIntermediateDirectories: true)
        for source in try requiredDatapackSources() {
            try copyFileIfChanged(source, to: serverDatapacks.appendingPathComponent(source.lastPathComponent))
            try copyFileIfChanged(source, to: worldDatapacks.appendingPathComponent(source.lastPathComponent))
        }
    }

    private func backupWorld(worldDir: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: worldDir.path) else {
            try fileManager.createDirectory(at: worldDir, withIntermediateDirectories: true)
            return nil
        }
        let backupRoot = config.serverDir.appendingPathComponent("world-reset-backups", isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let stamp = Self.backupStamp()
        var backup = backupRoot.appendingPathComponent("\(worldDir.lastPathComponent)-\(stamp)", isDirectory: true)
        var index = 1
        while fileManager.fileExists(atPath: backup.path) {
            index += 1
            backup = backupRoot.appendingPathComponent("\(worldDir.lastPathComponent)-\(stamp)-\(index)", isDirectory: true)
        }
        try fileManager.moveItem(at: worldDir, to: backup)
        try fileManager.createDirectory(at: worldDir, withIntermediateDirectories: true)
        return backup
    }

    private func writeServerProperties(worldName: String) throws {
        let path = config.serverDir.appendingPathComponent("server.properties")
        var lines = (try? String(contentsOf: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)) ?? []
        let updates = [
            "level-name": worldName,
            "level-seed": config.seed,
            "bonus-chest": "true",
            "white-list": "false",
            "enforce-whitelist": "false"
        ]
        var seen = Set<String>()
        lines = lines.map { line in
            guard let eq = line.firstIndex(of: "="), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
                return line
            }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard let value = updates[key] else {
                return line
            }
            seen.insert(key)
            return "\(key)=\(value)"
        }
        for (key, value) in updates where !seen.contains(key) {
            lines.append("\(key)=\(value)")
        }
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
    }

    private func readProperties(_ path: URL) throws -> [String: String] {
        guard fileManager.fileExists(atPath: path.path) else {
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

    private func readLevelSpawn(worldDir: URL) -> (Int, Int, Int)? {
        if let spawn = readLevelDatSpawn(worldDir: worldDir) {
            return spawn
        }
        let marker = worldDir.appendingPathComponent("pummelchen-spawn.txt")
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else {
            return nil
        }
        let parts = text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else {
            return nil
        }
        return (parts[0], parts[1], parts[2])
    }

    private func readLevelDatSpawn(worldDir: URL) -> (Int, Int, Int)? {
        let levelDat = worldDir.appendingPathComponent("level.dat")
        guard fileManager.fileExists(atPath: levelDat.path) else {
            return nil
        }
        let raw: Data
        do {
            raw = try runCommandData(executable: "/usr/bin/env", arguments: ["gzip", "-dc", levelDat.path], currentDirectory: config.projectRoot)
        } catch {
            raw = (try? Data(contentsOf: levelDat)) ?? Data()
        }
        return NBTSpawnReader(data: raw).spawn()
    }

    private func copyFileIfChanged(_ source: URL, to target: URL) throws {
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path), (try? Data(contentsOf: source)) == (try? Data(contentsOf: target)) {
            return
        }
        let tmp = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).tmp")
        if fileManager.fileExists(atPath: tmp.path) {
            try fileManager.removeItem(at: tmp)
        }
        try fileManager.copyItem(at: source, to: tmp)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try fileManager.moveItem(at: tmp, to: target)
    }

    private func validateZip(_ zip: URL, contains requiredEntries: [String]) throws {
        let output = try runCommand(executable: "/usr/bin/env", arguments: ["unzip", "-Z1", zip.path], currentDirectory: config.projectRoot)
        let entries = Set(output.split(separator: "\n").map(String.init))
        for entry in requiredEntries where !entries.contains(entry) {
            throw SwiftWorldResetError.missingRequiredPath("\(zip.lastPathComponent):\(entry)")
        }
    }

    private func requireHook(_ value: String?, name: String) throws {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SwiftWorldResetError.commandRequired(name)
        }
    }

    private func hasHook(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runHook(_ command: String?, phase: String) throws {
        guard let command, !command.isEmpty else {
            return
        }
        var env = ProcessInfo.processInfo.environment
        env["PUMMELCHEN_WORLD_RESET_PHASE"] = phase
        env["PUMMELCHEN_WORLD_RESET_SEED"] = config.seed
        env["PUMMELCHEN_WORLD_RESET_RADIUS_BLOCKS"] = String(config.radiusBlocks)
        env["PUMMELCHEN_WORLD_RESET_SERVICE"] = config.serviceName
        _ = try runCommand(executable: "/bin/sh", arguments: ["-lc", command], currentDirectory: config.projectRoot, environment: env)
    }

    private func applySafetyGamerules() throws {
        if hasHook(config.gameruleCommand) {
            try runHook(config.gameruleCommand, phase: "gamerules")
            return
        }
        let commands = Self.safetyGamerules
            .compactMap { gamerule, value in
                return "gamerule \(gamerule) \(value)"
            }
            .sorted()
        let responses = try rconClient().commands(commands)
        for response in responses where isCommandFailure(response) {
            throw SwiftWorldResetError.commandFailed("RCON gamerule failed: \(response)")
        }
    }

    private func pregenerateWorld(segments: [(startX: Int, z: Int, endX: Int, count: Int)]) throws {
        if hasHook(config.pregenerateCommand) {
            try runHook(config.pregenerateCommand, phase: "pregenerate")
            return
        }
        let client = try rconClient()
        for batch in pregenerationCommandBatches(for: segments) {
            let responses = try client.commands(batch)
            for response in responses where isCommandFailure(response) {
                throw SwiftWorldResetError.commandFailed("RCON pregeneration failed: \(response)")
            }
        }
        let finalSave = try client.command("save-all flush")
        if isCommandFailure(finalSave) {
            throw SwiftWorldResetError.commandFailed("RCON final save failed: \(finalSave)")
        }
    }

    private func verifyForceloadsCleared() throws -> Bool {
        if hasHook(config.verifyForceloadsCommand) {
            try runHook(config.verifyForceloadsCommand, phase: "verify_forceloads")
            return true
        }
        let response = try rconClient().command("forceload query")
        let normalized = response.lowercased()
        if normalized.contains("no force loaded chunks") || normalized.contains("0 force") || normalized.contains("0 chunk") {
            return true
        }
        throw SwiftWorldResetError.forceloadVerificationFailed(response)
    }

    private func pregenerationCommandBatches(for segments: [(startX: Int, z: Int, endX: Int, count: Int)]) -> [[String]] {
        var batches: [[String]] = []
        var commands: [String] = []
        var loaded: [(startX: Int, z: Int, endX: Int)] = []
        var loadedChunks = 0
        for segment in segments {
            commands.append(forceloadCommand(action: "add", startX: segment.startX, z: segment.z, endX: segment.endX))
            loaded.append((segment.startX, segment.z, segment.endX))
            loadedChunks += segment.count
            if loadedChunks >= config.pregenerationBatchSize {
                commands.append("save-all flush")
                commands += loaded.map { forceloadCommand(action: "remove", startX: $0.startX, z: $0.z, endX: $0.endX) }
                commands.append("save-all flush")
                batches.append(commands)
                commands.removeAll()
                loaded.removeAll()
                loadedChunks = 0
            }
        }
        if !loaded.isEmpty {
            commands.append("save-all flush")
            commands += loaded.map { forceloadCommand(action: "remove", startX: $0.startX, z: $0.z, endX: $0.endX) }
            commands.append("save-all flush")
            batches.append(commands)
        }
        return batches
    }

    private func forceloadCommand(action: String, startX: Int, z: Int, endX: Int) -> String {
        let startBlockX = startX * 16 + 8
        let blockZ = z * 16 + 8
        let endBlockX = endX * 16 + 8
        if startBlockX == endBlockX {
            return "forceload \(action) \(startBlockX) \(blockZ)"
        }
        return "forceload \(action) \(startBlockX) \(blockZ) \(endBlockX) \(blockZ)"
    }

    private func rconClient() throws -> MinecraftRCONClient {
        try MinecraftRCONClient(host: config.rconHost, port: config.rconPort, password: resolvedRCONPassword())
    }

    private func resolvedRCONPassword() throws -> String {
        if let password = config.rconPassword?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            return password
        }
        let properties = try readProperties(config.serverDir.appendingPathComponent("server.properties"))
        if let password = properties["rcon.password"]?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty {
            return password
        }
        throw SwiftWorldResetError.rconPasswordRequired
    }

    private func isCommandFailure(_ response: String) -> Bool {
        let normalized = response.lowercased()
        return normalized.contains("unknown or incomplete command")
            || normalized.contains("incorrect argument")
            || normalized.contains("permission")
            || normalized.contains("failed")
            || normalized.contains("error")
    }

    private func persist(jobID: String, requestedAt: String, startedAt: String?, completedAt: String?, status: String, result: SwiftWorldResetResult, error: String?) throws {
        try initializeDB()
        let resultJSON = String(decoding: try JSONEncoder.pummelchenWorldReset.encode(result), as: UTF8.self)
        let sql = """
        INSERT OR REPLACE INTO world.reset_jobs(
          job_id, requested_at, started_at, completed_at, status, seed, radius_blocks,
          old_world_path, backup_path, result_json, error
        )
        VALUES (
          \(Self.sqlLiteral(jobID)),
          TIMESTAMP '\(Self.sqlTimestamp(requestedAt))',
          \(startedAt.map { "TIMESTAMP '\(Self.sqlTimestamp($0))'" } ?? "NULL"),
          \(completedAt.map { "TIMESTAMP '\(Self.sqlTimestamp($0))'" } ?? "NULL"),
          \(Self.sqlLiteral(status)),
          \(Self.sqlLiteral(config.seed)),
          \(config.radiusBlocks),
          \(Self.sqlLiteral(result.oldWorldPath)),
          \(Self.sqlLiteral(result.backupPath)),
          \(Self.sqlLiteral(resultJSON)),
          \(Self.sqlLiteral(error))
        );
        """
        try DuckDBDatabase(databaseURL: config.databaseURL).execute(sql)
    }

    private func initializeDB() throws {
        try fileManager.createDirectory(at: config.databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sql = """
        CREATE SCHEMA IF NOT EXISTS world;
        CREATE TABLE IF NOT EXISTS world.reset_jobs (
          job_id VARCHAR PRIMARY KEY,
          requested_at TIMESTAMP NOT NULL,
          started_at TIMESTAMP,
          completed_at TIMESTAMP,
          status VARCHAR NOT NULL,
          seed VARCHAR,
          radius_blocks INTEGER NOT NULL DEFAULT 1000,
          old_world_path VARCHAR,
          backup_path VARCHAR,
          result_json JSON,
          error VARCHAR
        );
        """
        try DuckDBDatabase(databaseURL: config.databaseURL).execute(sql)
    }

    private func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SwiftWorldResetError.missingRequiredPath(url.path)
        }
    }

    @discardableResult
    private func runCommand(executable: String, arguments: [String], currentDirectory: URL? = nil, environment: [String: String]? = nil) throws -> String {
        String(decoding: try runCommandData(executable: executable, arguments: arguments, currentDirectory: currentDirectory, environment: environment), as: UTF8.self)
    }

    private func runCommandData(executable: String, arguments: [String], currentDirectory: URL? = nil, environment: [String: String]? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw SwiftWorldResetError.commandFailed(Self.redactSecrets(([executable] + arguments).joined(separator: " ") + "\n" + String(decoding: output, as: UTF8.self)))
        }
        return output
    }

    private static func floorDiv(_ value: Int, _ divisor: Int) -> Int {
        let quotient = value / divisor
        let remainder = value % divisor
        return remainder < 0 ? quotient - 1 : quotient
    }

    private static func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlTimestamp(_ value: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: value) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: parsed)
    }

    private static func redactSecrets(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"Bearer\s+[A-Za-z0-9._~+/\-=]+"#, with: "Bearer [REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(--rcon-password\s+)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #"(rcon\.password\s*=\s*)(\S+)"#, with: "$1[REDACTED]", options: .regularExpression)
            .replacingOccurrences(of: #""client_secret"\s*:\s*"[^"]+""#, with: #""client_secret":"[REDACTED]""#, options: .regularExpression)
    }

}

private enum NBTValue {
    case int(Int)
    case compound([String: NBTValue])
    case other
}

private struct NBTSpawnReader {
    let data: Data
    private var bytes: [UInt8] { Array(data) }

    func spawn() -> (Int, Int, Int)? {
        var cursor = 0
        let payload = bytes
        guard readByte(payload, &cursor) == 10 else {
            return nil
        }
        _ = readString(payload, &cursor)
        guard case .compound(let root) = parseCompound(payload, &cursor) else {
            return nil
        }
        let dataCompound: [String: NBTValue]
        if case .compound(let nested)? = root["Data"] {
            dataCompound = nested
        } else {
            dataCompound = root
        }
        if case .int(let x)? = dataCompound["SpawnX"],
           case .int(let y)? = dataCompound["SpawnY"],
           case .int(let z)? = dataCompound["SpawnZ"] {
            return (x, y, z)
        }
        return nil
    }

    private func parseCompound(_ payload: [UInt8], _ cursor: inout Int) -> NBTValue {
        var result: [String: NBTValue] = [:]
        while cursor < payload.count {
            let tag = readByte(payload, &cursor)
            if tag == 0 {
                return .compound(result)
            }
            guard let name = readString(payload, &cursor) else {
                return .compound(result)
            }
            result[name] = parseValue(tag: tag, payload, &cursor)
        }
        return .compound(result)
    }

    private func parseValue(tag: UInt8, _ payload: [UInt8], _ cursor: inout Int) -> NBTValue {
        switch tag {
        case 1:
            cursor += 1
            return .other
        case 2:
            cursor += 2
            return .other
        case 3:
            return .int(Int(readInt32(payload, &cursor) ?? 0))
        case 4:
            cursor += 8
            return .other
        case 5:
            cursor += 4
            return .other
        case 6:
            cursor += 8
            return .other
        case 7:
            let count = Int(readInt32(payload, &cursor) ?? 0)
            cursor += max(0, count)
            return .other
        case 8:
            _ = readString(payload, &cursor)
            return .other
        case 9:
            let childTag = readByte(payload, &cursor)
            let count = Int(readInt32(payload, &cursor) ?? 0)
            for _ in 0..<max(0, count) {
                _ = parseValue(tag: childTag, payload, &cursor)
            }
            return .other
        case 10:
            return parseCompound(payload, &cursor)
        case 11:
            let count = Int(readInt32(payload, &cursor) ?? 0)
            cursor += max(0, count) * 4
            return .other
        case 12:
            let count = Int(readInt32(payload, &cursor) ?? 0)
            cursor += max(0, count) * 8
            return .other
        default:
            return .other
        }
    }

    private func readByte(_ payload: [UInt8], _ cursor: inout Int) -> UInt8 {
        guard cursor < payload.count else { return 0 }
        defer { cursor += 1 }
        return payload[cursor]
    }

    private func readString(_ payload: [UInt8], _ cursor: inout Int) -> String? {
        guard cursor + 2 <= payload.count else { return nil }
        let size = Int(UInt16(payload[cursor]) << 8 | UInt16(payload[cursor + 1]))
        cursor += 2
        guard size >= 0, cursor + size <= payload.count else { return nil }
        defer { cursor += size }
        return String(bytes: payload[cursor..<cursor + size], encoding: .utf8)
    }

    private func readInt32(_ payload: [UInt8], _ cursor: inout Int) -> Int32? {
        guard cursor + 4 <= payload.count else { return nil }
        let value = Int32(bitPattern:
            UInt32(payload[cursor]) << 24 |
            UInt32(payload[cursor + 1]) << 16 |
            UInt32(payload[cursor + 2]) << 8 |
            UInt32(payload[cursor + 3])
        )
        cursor += 4
        return value
    }
}

private extension JSONEncoder {
    static var pummelchenWorldReset: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
