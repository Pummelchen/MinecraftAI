import Foundation
import PummelchenClientCore
import PummelchenCore

enum HeadlessSoakError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case commandFailed(String)
    case invalidValue(String)
    case missingPath(String)
    case loginNotObserved
    case connectedTooShort(Double)
    case fatalLogLines(Int)
    case crashReports(Int)
    case setupAcceptanceFailed([String])

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              pummelchen-headless-soak --dmg <path> --release-id <id> --server-address <host:25565> [--headless-command <shell>] [--server-url <url>] [--duration-seconds 300] [--work-dir <dir>] [--report <path>] [--client-api-token <token>] [--suppress-gui true] [--keep-work-dir true]

            By default this uses HeadlessMC plus HMC-Specifics to start a real Minecraft client from the synced isolated Minecraft directory and stay alive for the soak duration.
            The built-in runner suppresses HeadlessMC GUI probing by default so macOS soak runs do not steal focus or capture the mouse.
            Environment provided to the command:
              PUMMELCHEN_SOAK_MINECRAFT_DIR
              PUMMELCHEN_SOAK_HOME
              PUMMELCHEN_SOAK_JAVA
              PUMMELCHEN_SOAK_SERVER_ADDRESS
              PUMMELCHEN_SOAK_DURATION_SECONDS
              PUMMELCHEN_SOAK_SUPPRESS_GUI
            """
        case .missingValue(let option):
            return "missing value for \(option)"
        case .commandFailed(let message):
            return message
        case .invalidValue(let message):
            return message
        case .missingPath(let path):
            return "missing required path: \(path)"
        case .loginNotObserved:
            return "headless client did not produce a live-server login signal"
        case .connectedTooShort(let seconds):
            return "headless client stayed connected for only \(Int(seconds)) seconds"
        case .fatalLogLines(let count):
            return "headless client logs contain \(count) fatal line(s)"
        case .crashReports(let count):
            return "headless client produced \(count) crash report(s)"
        case .setupAcceptanceFailed(let failures):
            return "new-player setup acceptance failed: \(failures.joined(separator: "; "))"
        }
    }
}

struct Arguments {
    let options: [String: String]

    init(_ raw: [String]) throws {
        var options: [String: String] = [:]
        var index = 1
        while index < raw.count {
            let option = raw[index]
            guard option.hasPrefix("--") else { throw HeadlessSoakError.usage }
            guard index + 1 < raw.count else { throw HeadlessSoakError.missingValue(option) }
            options[option] = raw[index + 1]
            index += 2
        }
        self.options = options
    }

    func require(_ key: String) throws -> String {
        guard let value = options[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HeadlessSoakError.missingValue(key)
        }
        return value
    }
}

struct HeadlessSoakConfig {
    let dmg: URL
    let releaseID: String
    let serverAddress: String
    let serverURL: URL
    let durationSeconds: Double
    let workDir: URL
    let report: URL
    let headlessCommand: String?
    let headlessMCHome: URL
    let headlessMCVersion: String
    let minecraftVersion: String
    let loader: String
    let loaderVersion: String
    let heapGB: Int
    let inGameTimeoutSeconds: Double
    let clientAPIToken: String?
    let suppressGUI: Bool
    let keepWorkDir: Bool

    init(arguments: Arguments) throws {
        let dmg = URL(fileURLWithPath: try arguments.require("--dmg")).standardizedFileURL
        let releaseID = try arguments.require("--release-id")
        let serverAddress = try arguments.require("--server-address")
        let serverURL = URL(string: arguments.options["--server-url"] ?? "https://pummelchen.91.99.176.243.nip.io")
        guard let serverURL else { throw HeadlessSoakError.invalidValue("invalid --server-url") }
        let durationSeconds = Double(arguments.options["--duration-seconds"] ?? "300") ?? 300
        guard durationSeconds >= 300 else {
            throw HeadlessSoakError.invalidValue("--duration-seconds must be at least 300")
        }
        let defaultWork = FileManager.default.temporaryDirectory
            .appendingPathComponent("pummelchen-headless-soak-\(releaseID)-\(UUID().uuidString)", isDirectory: true)
        let workDir = arguments.options["--work-dir"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? defaultWork
        let report = arguments.options["--report"]
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? dmg.deletingLastPathComponent().appendingPathComponent("MCPummelchenModClient.dmg.headless-live-soak.json")
        self.dmg = dmg
        self.releaseID = releaseID
        self.serverAddress = serverAddress
        self.serverURL = serverURL
        self.durationSeconds = durationSeconds
        self.workDir = workDir
        self.report = report
        self.headlessCommand = arguments.options["--headless-command"]
        self.headlessMCHome = arguments.options["--headlessmc-home"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Pummelchen/headlessmc", isDirectory: true)
        self.headlessMCVersion = arguments.options["--headlessmc-version"] ?? "2.9.0"
        self.minecraftVersion = arguments.options["--minecraft-version"] ?? "26.1.2"
        self.loader = arguments.options["--loader"] ?? "neoforge"
        self.loaderVersion = arguments.options["--loader-version"] ?? "26.1.2.76"
        self.heapGB = Int(arguments.options["--heap-gb"] ?? "8") ?? 8
        self.inGameTimeoutSeconds = Double(arguments.options["--ingame-timeout-seconds"] ?? "300") ?? 300
        self.clientAPIToken = arguments.options["--client-api-token"] ?? ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"]
        self.suppressGUI = Self.boolOption(arguments.options["--suppress-gui"], default: true)
        self.keepWorkDir = arguments.options["--keep-work-dir"] == "true"
    }

    private static func boolOption(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }
}

struct ProcessResult {
    let exitCode: Int32
    let output: String
    let durationSeconds: Double
    let timedOut: Bool
}

private extension Data {
    func occurrences(of needle: Data) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = startIndex
        while searchStart < endIndex, let range = self[searchStart..<endIndex].range(of: needle) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

struct SoakReport: Encodable {
    let releaseID: String
    let dmgSHA256: String
    let serverAddress: String
    let startedAt: String
    let completedAt: String
    let durationSeconds: Double
    let status: String
    let installedFromDMG: Bool
    let javaOK: Bool
    let neoforgeOK: Bool
    let syncOK: Bool
    let loginOK: Bool
    let stayedConnected: Bool
    let crashReportCount: Int
    let fatalLogCount: Int
    let rendererSummary: String
    let notes: String
    let newPlayerSetup: NewPlayerSetupReport?

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case dmgSHA256 = "dmg_sha256"
        case serverAddress = "server_address"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case durationSeconds = "duration_seconds"
        case status
        case installedFromDMG = "installed_from_dmg"
        case javaOK = "java_ok"
        case neoforgeOK = "neoforge_ok"
        case syncOK = "sync_ok"
        case loginOK = "login_ok"
        case stayedConnected = "stayed_connected"
        case crashReportCount = "crash_report_count"
        case fatalLogCount = "fatal_log_count"
        case rendererSummary = "renderer_summary"
        case notes
        case newPlayerSetup = "new_player_setup"
    }
}

struct AcceptanceCheck: Encodable {
    let name: String
    let status: String
    let details: String
}

struct NewPlayerSetupReport: Encodable {
    let status: String
    let appBundlePath: String
    let minecraftDirectory: String
    let pummelchenHome: String
    let checks: [AcceptanceCheck]
    let manifestEntries: Int
    let verifiedManagedFiles: Int
    let downloadedFiles: Int
    let defaultsOK: Bool
    let serverEntryCount: Int
    let javaExecutable: String
    let javaVersion: String
    let neoforgeVersion: String
    let installedReleaseID: String

    enum CodingKeys: String, CodingKey {
        case status
        case appBundlePath = "app_bundle_path"
        case minecraftDirectory = "minecraft_directory"
        case pummelchenHome = "pummelchen_home"
        case checks
        case manifestEntries = "manifest_entries"
        case verifiedManagedFiles = "verified_managed_files"
        case downloadedFiles = "downloaded_files"
        case defaultsOK = "defaults_ok"
        case serverEntryCount = "server_entry_count"
        case javaExecutable = "java_executable"
        case javaVersion = "java_version"
        case neoforgeVersion = "neoforge_version"
        case installedReleaseID = "installed_release_id"
    }
}

struct HeadlessSoakRunner {
    let config: HeadlessSoakConfig
    let fileManager = FileManager.default

    func run() throws {
        guard fileManager.fileExists(atPath: config.dmg.path) else {
            throw HeadlessSoakError.missingPath(config.dmg.path)
        }
        let started = Date()
        var installedFromDMG = false
        var javaOK = false
        var neoforgeOK = false
        var syncOK = false
        var loginOK = false
        var stayedConnected = false
        var crashReportCount = 0
        var fatalLogCount = 0
        var setupReport: NewPlayerSetupReport?
        var notes: [String] = []
        let dmgSHA = try SHA256Hasher.hashFile(at: config.dmg)

        do {
            try fileManager.createDirectory(at: config.workDir, withIntermediateDirectories: true)
            let mountPoint = try mountDMG()
            defer { try? unmount(mountPoint: mountPoint) }

            let installedApp = try installApp(from: mountPoint)
            installedFromDMG = true
            try validateInstalledAppBundle(installedApp)
            let syncBinary = installedApp.appendingPathComponent("Contents/MacOS/pummelchen-client-sync")
            guard fileManager.isExecutableFile(atPath: syncBinary.path) else {
                throw HeadlessSoakError.missingPath(syncBinary.path)
            }

            let minecraftDir = config.workDir.appendingPathComponent("minecraft", isDirectory: true)
            let pummelchenHome = config.workDir.appendingPathComponent("pummelchen-home", isDirectory: true)
            try fileManager.createDirectory(at: minecraftDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: pummelchenHome, withIntermediateDirectories: true)

            let syncResult = try runSync(syncBinary: syncBinary, minecraftDir: minecraftDir, pummelchenHome: pummelchenHome)
            try syncResult.output.write(to: config.workDir.appendingPathComponent("pummelchen-client-sync.log"), atomically: true, encoding: .utf8)
            syncOK = syncResult.exitCode == 0
            guard syncOK else {
                throw HeadlessSoakError.commandFailed("client sync failed: \(syncResult.output)")
            }

            let java = try managedJavaExecutable(pummelchenHome: pummelchenHome)
            let javaResult = try runProcess(executable: java.path, arguments: ["-version"], timeoutSeconds: 30, environment: [:])
            javaOK = javaResult.exitCode == 0
            guard javaOK else {
                throw HeadlessSoakError.commandFailed("managed Java verification failed: \(javaResult.output)")
            }

            neoforgeOK = hasNeoForgeInstall(minecraftDir: minecraftDir)
            guard neoforgeOK else {
                throw HeadlessSoakError.missingPath(minecraftDir.appendingPathComponent("versions/neoforge-26.1.2.76").path)
            }

            setupReport = try inspectNewPlayerSetup(
                installedApp: installedApp,
                syncBinary: syncBinary,
                minecraftDir: minecraftDir,
                pummelchenHome: pummelchenHome,
                java: java,
                javaVersionOutput: javaResult.output,
                syncResult: syncResult
            )

            let soak = try runHeadless(minecraftDir: minecraftDir, pummelchenHome: pummelchenHome, java: java)
            try soak.output.write(to: config.workDir.appendingPathComponent("headless-minecraft.log"), atomically: true, encoding: .utf8)
            loginOK = observedLogin(in: soak.output, minecraftDir: minecraftDir)
            stayedConnected = soak.durationSeconds >= config.durationSeconds && soak.exitCode == 0
            crashReportCount = countCrashReports(minecraftDir: minecraftDir)
            fatalLogCount = countFatalLogLines(extraOutput: soak.output, minecraftDir: minecraftDir)

            if !loginOK { throw HeadlessSoakError.loginNotObserved }
            if !stayedConnected { throw HeadlessSoakError.connectedTooShort(soak.durationSeconds) }
            if crashReportCount > 0 { throw HeadlessSoakError.crashReports(crashReportCount) }
            if fatalLogCount > 0 { throw HeadlessSoakError.fatalLogLines(fatalLogCount) }
            notes.append("Installed DMG app, synced isolated client, verified managed Java and NeoForge, joined live server, and completed \(Int(soak.durationSeconds))s headless soak.")
        } catch {
            notes.append("failed: \(error)")
            let completed = Date()
            try writeReport(
                started: started,
                completed: completed,
                dmgSHA: dmgSHA,
                status: "failed",
                installedFromDMG: installedFromDMG,
                javaOK: javaOK,
                neoforgeOK: neoforgeOK,
                syncOK: syncOK,
                loginOK: loginOK,
                stayedConnected: stayedConnected,
                crashReportCount: crashReportCount,
                fatalLogCount: fatalLogCount,
                newPlayerSetup: setupReport,
                notes: notes.joined(separator: " ")
            )
            throw error
        }

        let completed = Date()
        try writeReport(
            started: started,
            completed: completed,
            dmgSHA: dmgSHA,
            status: "passed",
            installedFromDMG: installedFromDMG,
            javaOK: javaOK,
            neoforgeOK: neoforgeOK,
            syncOK: syncOK,
            loginOK: loginOK,
            stayedConnected: stayedConnected,
            crashReportCount: crashReportCount,
            fatalLogCount: fatalLogCount,
            newPlayerSetup: setupReport,
            notes: notes.joined(separator: " ")
        )
        if !config.keepWorkDir {
            try? fileManager.removeItem(at: config.workDir)
        }
    }

    private func mountDMG() throws -> URL {
        #if os(macOS)
        let result = try runProcess(executable: "/usr/bin/hdiutil", arguments: ["attach", "-nobrowse", "-readonly", "-plist", config.dmg.path], timeoutSeconds: 120, environment: [:])
        guard result.exitCode == 0, let data = result.output.data(using: .utf8),
              let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw HeadlessSoakError.commandFailed("hdiutil attach failed: \(result.output)")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
        #else
        throw HeadlessSoakError.commandFailed("DMG mounting requires macOS")
        #endif
    }

    private func unmount(mountPoint: URL) throws {
        _ = try runProcess(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint.path], timeoutSeconds: 60, environment: [:])
    }

    private func installApp(from mountPoint: URL) throws -> URL {
        let app = mountPoint.appendingPathComponent("MCPummelchenModClient.app", isDirectory: true)
        guard fileManager.fileExists(atPath: app.path) else {
            throw HeadlessSoakError.missingPath(app.path)
        }
        let target = config.workDir.appendingPathComponent("MCPummelchenModClient.app", isDirectory: true)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        _ = try runProcess(executable: "/bin/cp", arguments: ["-R", app.path, target.path], timeoutSeconds: 120, environment: [:])
        return target
    }

    private func validateInstalledAppBundle(_ app: URL) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        let guiBinary = app.appendingPathComponent("Contents/MacOS/PummelchenClient")
        let syncBinary = app.appendingPathComponent("Contents/MacOS/pummelchen-client-sync")
        let duckDB = app.appendingPathComponent("Contents/Frameworks/libduckdb.dylib")
        for required in [info, guiBinary, syncBinary, duckDB] {
            guard fileManager.fileExists(atPath: required.path) else {
                throw HeadlessSoakError.missingPath(required.path)
            }
        }
        guard fileManager.isExecutableFile(atPath: guiBinary.path) else {
            throw HeadlessSoakError.missingPath(guiBinary.path)
        }
        guard fileManager.isExecutableFile(atPath: syncBinary.path) else {
            throw HeadlessSoakError.missingPath(syncBinary.path)
        }
        let plist = try runProcess(executable: "/usr/bin/plutil", arguments: ["-lint", info.path], timeoutSeconds: 30, environment: [:])
        guard plist.exitCode == 0 else {
            throw HeadlessSoakError.commandFailed("app Info.plist failed validation: \(plist.output)")
        }
        let signature = try runProcess(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path], timeoutSeconds: 60, environment: [:])
        guard signature.exitCode == 0 else {
            throw HeadlessSoakError.commandFailed("app code signature failed validation: \(signature.output)")
        }
    }

    private func runSync(syncBinary: URL, minecraftDir: URL, pummelchenHome: URL) throws -> ProcessResult {
        var args = [
            "sync",
            "--force",
            "--server-url", config.serverURL.absoluteString,
            "--minecraft-dir", minecraftDir.path,
            "--pummelchen-home", pummelchenHome.path,
            "--db", pummelchenHome.appendingPathComponent("client.duckdb").path,
            "--client-id", "headless-soak-\(config.releaseID)",
            "--allow-while-running"
        ]
        if let token = config.clientAPIToken, !token.isEmpty {
            args.append(contentsOf: ["--client-api-token", token])
        } else {
            args.append("--no-report")
        }
        return try runProcess(executable: syncBinary.path, arguments: args, timeoutSeconds: 900, environment: [:])
    }

    private func managedJavaExecutable(pummelchenHome: URL) throws -> URL {
        let marker = pummelchenHome.appendingPathComponent("java/current-runtime.txt")
        guard let markerText = try? String(contentsOf: marker, encoding: .utf8) else {
            throw HeadlessSoakError.missingPath(marker.path)
        }
        for line in markerText.split(separator: "\n") {
            if line.hasPrefix("java=") {
                let path = String(line.dropFirst("java=".count))
                guard fileManager.isExecutableFile(atPath: path) else {
                    throw HeadlessSoakError.missingPath(path)
                }
                return URL(fileURLWithPath: path)
            }
        }
        throw HeadlessSoakError.commandFailed("managed Java marker does not contain java= path")
    }

    private func hasNeoForgeInstall(minecraftDir: URL) -> Bool {
        let version = minecraftDir.appendingPathComponent("versions/neoforge-\(config.loaderVersion)/neoforge-\(config.loaderVersion).json")
        let libraries = minecraftDir.appendingPathComponent("libraries/net/neoforged/neoforge/\(config.loaderVersion)", isDirectory: true)
        return fileManager.fileExists(atPath: version.path) && fileManager.fileExists(atPath: libraries.path)
    }

    private func inspectNewPlayerSetup(
        installedApp: URL,
        syncBinary: URL,
        minecraftDir: URL,
        pummelchenHome: URL,
        java: URL,
        javaVersionOutput: String,
        syncResult: ProcessResult
    ) throws -> NewPlayerSetupReport {
        var checks: [AcceptanceCheck] = []
        var failures: [String] = []

        func record(_ name: String, _ ok: Bool, _ details: String) {
            checks.append(AcceptanceCheck(name: name, status: ok ? "passed" : "failed", details: details))
            if !ok {
                failures.append("\(name): \(details)")
            }
        }

        let appInfo = installedApp.appendingPathComponent("Contents/Info.plist")
        let guiBinary = installedApp.appendingPathComponent("Contents/MacOS/PummelchenClient")
        let duckDBDylib = installedApp.appendingPathComponent("Contents/Frameworks/libduckdb.dylib")
        record("dmg_app_bundle_installed", fileManager.fileExists(atPath: appInfo.path), installedApp.path)
        record("gui_binary_executable", fileManager.isExecutableFile(atPath: guiBinary.path), guiBinary.path)
        record("sync_helper_executable", fileManager.isExecutableFile(atPath: syncBinary.path), syncBinary.path)
        record("duckdb_embedded_dylib_present", fileManager.fileExists(atPath: duckDBDylib.path), duckDBDylib.path)
        let codeSignature = (try? runProcess(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", installedApp.path], timeoutSeconds: 60, environment: [:]))?.exitCode == 0
        record("app_code_signature_valid", codeSignature, "codesign --verify --deep --strict")

        let database = pummelchenHome.appendingPathComponent("client.duckdb")
        let manifestPath = minecraftDir.appendingPathComponent(".pummelchen/client-sync-manifest.tsv")
        let installedReleasePath = minecraftDir.appendingPathComponent(".pummelchen/installed-release.txt")
        let installedRelease = readText(installedReleasePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try readSyncedManifest(at: manifestPath)
        let verifiedFiles = try countVerifiedManagedFiles(manifest: manifest, minecraftDir: minecraftDir, pummelchenHome: pummelchenHome)

        record("isolated_minecraft_directory_created", fileManager.fileExists(atPath: minecraftDir.path), minecraftDir.path)
        record("isolated_pummelchen_home_created", fileManager.fileExists(atPath: pummelchenHome.path), pummelchenHome.path)
        record("client_duckdb_created", fileManager.fileExists(atPath: database.path), database.path)
        record("installed_release_recorded", installedRelease == config.releaseID, installedRelease.isEmpty ? "missing" : installedRelease)
        record("manifest_saved", !manifest.entries.isEmpty, "\(manifest.entries.count) entries")
        record("managed_files_verified", verifiedFiles == manifest.entries.count, "\(verifiedFiles)/\(manifest.entries.count)")

        let defaults = MinecraftClientDefaults(javaExecutablePath: java.path, loaderVersion: config.loaderVersion)
        let defaultsHealth = ClientDefaultsInspector.inspect(minecraftDirectory: minecraftDir, defaults: defaults)
        let defaultFailures = defaultsHealth.filter { $0.status != .ok && $0.status != .unknown }
        record("client_defaults_healthy", defaultFailures.isEmpty, defaultFailures.map { "\($0.label)=\($0.status.rawValue)" }.joined(separator: ", "))
        record("shader_default_active", defaultsHealth.contains { $0.id == "shader" && $0.status == .ok }, "BSL shader default")
        record("resource_packs_default_active", defaultsHealth.contains { $0.id == "resource_packs" && $0.status == .ok }, "ModernArch stack")
        record("physics_mob_fracturing_default_active", defaultsHealth.contains { $0.id == "physics_mob_fracturing" && $0.status == .ok }, "Mob Fracturing (with blood)")
        record("server_entry_default_present", defaultsHealth.contains { $0.id == "server_entry" && $0.status == .ok }, config.serverAddress)

        let serverCount = countServerAddress(config.serverAddress, minecraftDir: minecraftDir)
        record("server_entry_not_duplicated", serverCount == 1, "\(serverCount) occurrence(s)")
        record("managed_java_marker_present", fileManager.fileExists(atPath: pummelchenHome.appendingPathComponent("java/current-runtime.txt").path), java.path)
        record("managed_java_version_ok", javaVersionOutput.contains("25.0.3"), oneLine(javaVersionOutput))
        record("neoforge_installed", hasNeoForgeInstall(minecraftDir: minecraftDir), config.loaderVersion)
        record("launcher_profile_points_to_managed_java", launcherProfileContains(minecraftDir: minecraftDir, value: java.path), java.path)
        record("launcher_profile_uses_neoforge", launcherProfileContains(minecraftDir: minecraftDir, value: "neoforge-\(config.loaderVersion)"), config.loaderVersion)
        record("sync_helper_completed", syncResult.exitCode == 0, oneLine(syncResult.output))

        if !failures.isEmpty {
            throw HeadlessSoakError.setupAcceptanceFailed(failures)
        }

        return NewPlayerSetupReport(
            status: "passed",
            appBundlePath: installedApp.path,
            minecraftDirectory: minecraftDir.path,
            pummelchenHome: pummelchenHome.path,
            checks: checks,
            manifestEntries: manifest.entries.count,
            verifiedManagedFiles: verifiedFiles,
            downloadedFiles: downloadedCount(fromSyncOutput: syncResult.output),
            defaultsOK: defaultFailures.isEmpty,
            serverEntryCount: serverCount,
            javaExecutable: java.path,
            javaVersion: oneLine(javaVersionOutput),
            neoforgeVersion: config.loaderVersion,
            installedReleaseID: installedRelease
        )
    }

    private func readSyncedManifest(at path: URL) throws -> ClientSyncManifest {
        guard let text = try? String(contentsOf: path, encoding: .utf8), !text.isEmpty else {
            throw HeadlessSoakError.missingPath(path.path)
        }
        return try ClientSyncManifestParser.parse(text)
    }

    private func countVerifiedManagedFiles(manifest: ClientSyncManifest, minecraftDir: URL, pummelchenHome: URL) throws -> Int {
        var count = 0
        for entry in manifest.entries {
            let destination = try managedDestination(for: entry, minecraftDir: minecraftDir, pummelchenHome: pummelchenHome)
            if (try? FileInventory.verify(fileURL: destination, expectedSize: entry.sizeBytes, expectedSHA256: entry.sha256)) == true {
                count += 1
            }
        }
        return count
    }

    private func managedDestination(for entry: ClientSyncManifestEntry, minecraftDir: URL, pummelchenHome: URL) throws -> URL {
        guard let section = ManagedClientSection(rawValue: entry.section) else {
            throw HeadlessSoakError.invalidValue("invalid manifest section: \(entry.section)")
        }
        switch section {
        case .mods, .resourcepacks, .shaderpacks:
            return minecraftDir.appendingPathComponent(entry.section, isDirectory: true).appendingPathComponent(entry.name)
        case .tools:
            return pummelchenHome.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(entry.name)
        }
    }

    private func countServerAddress(_ address: String, minecraftDir: URL) -> Int {
        let path = minecraftDir.appendingPathComponent("servers.dat")
        guard let data = try? Data(contentsOf: path) else { return 0 }
        return data.occurrences(of: Data(address.utf8))
    }

    private func launcherProfileContains(minecraftDir: URL, value: String) -> Bool {
        readText(minecraftDir.appendingPathComponent("launcher_profiles.json")).contains(value)
            || readText(minecraftDir.appendingPathComponent("launcher_profiles.json")).contains(value.replacingOccurrences(of: "/", with: "\\/"))
    }

    private func downloadedCount(fromSyncOutput output: String) -> Int {
        output
            .split(separator: "\n")
            .first { $0.hasPrefix("Downloaded:") }
            .flatMap { Int($0.replacingOccurrences(of: "Downloaded:", with: "").trimmingCharacters(in: .whitespaces)) }
            ?? 0
    }

    private func oneLine(_ value: String) -> String {
        value
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
    }

    private func runHeadless(minecraftDir: URL, pummelchenHome: URL, java: URL) throws -> ProcessResult {
        if let command = config.headlessCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try runCustomHeadless(command: command, minecraftDir: minecraftDir, pummelchenHome: pummelchenHome, java: java)
        }
        return try runBuiltInHeadlessMC(minecraftDir: minecraftDir, pummelchenHome: pummelchenHome, java: java)
    }

    private func runCustomHeadless(command: String, minecraftDir: URL, pummelchenHome: URL, java: URL) throws -> ProcessResult {
        var env = ProcessInfo.processInfo.environment
        env["PUMMELCHEN_SOAK_MINECRAFT_DIR"] = minecraftDir.path
        env["PUMMELCHEN_SOAK_HOME"] = pummelchenHome.path
        env["PUMMELCHEN_SOAK_JAVA"] = java.path
        env["PUMMELCHEN_SOAK_SERVER_ADDRESS"] = config.serverAddress
        env["PUMMELCHEN_SOAK_DURATION_SECONDS"] = String(Int(config.durationSeconds))
        env["PUMMELCHEN_SOAK_RELEASE_ID"] = config.releaseID
        env["PUMMELCHEN_SOAK_SUPPRESS_GUI"] = config.suppressGUI ? "true" : "false"
        let timeout = config.durationSeconds + 180
        return try runProcess(executable: "/bin/sh", arguments: ["-lc", command], timeoutSeconds: timeout, environment: env)
    }

    private func runBuiltInHeadlessMC(minecraftDir: URL, pummelchenHome: URL, java: URL) throws -> ProcessResult {
        try fileManager.createDirectory(at: config.headlessMCHome, withIntermediateDirectories: true)
        let hmcJar = try ensureHeadlessMCJar()
        try ensureHMCSpecifics(minecraftDir: minecraftDir)
        try seedClientOptions(minecraftDir: minecraftDir)

        let hmcLog = config.workDir.appendingPathComponent("headless-minecraft.log")
        let xvfb = try startXvfbIfNeeded()
        defer { stopProcess(xvfb.process) }

        let process = Process()
        process.executableURL = java
        process.arguments = [
            "-Dhmc.gamedir=\(minecraftDir.path)",
            "-Dhmc.jline.enabled=false",
            "-jar",
            hmcJar.path
        ]
        process.currentDirectoryURL = config.headlessMCHome
        var env = ProcessInfo.processInfo.environment
        env["DISPLAY"] = xvfb.display
        process.environment = env
        let stdin = Pipe()
        process.standardInput = stdin
        _ = fileManager.createFile(atPath: hmcLog.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: hmcLog)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()
        defer { stopProcess(process) }
        Thread.sleep(forTimeInterval: 4)

        let server = parsedServerAddress()
        let launchVersion = "\(config.loader)-\(config.loaderVersion)"
        let launch = """
        launch \(launchVersion) -specifics --jvm "-Xmx\(config.heapGB)G -Dio.netty.transport.noNative=true -Djava.net.preferIPv4Stack=true" --game-args "--quickPlayMultiplayer \(server.host):\(server.port) --width 320 --height 240"
        """
        try send(command: launch, to: stdin)
        try waitForInGame(process: process, stdin: stdin, hmcLog: hmcLog, minecraftDir: minecraftDir, timeoutSeconds: config.inGameTimeoutSeconds)
        let connectedStart = Date()
        let deadline = connectedStart.addingTimeInterval(config.durationSeconds)
        while Date() < deadline {
            if !process.isRunning {
                throw HeadlessSoakError.commandFailed("HeadlessMC exited during live soak")
            }
            let crashes = countCrashReports(minecraftDir: minecraftDir)
            let fatals = countFatalLogLines(extraOutput: readText(hmcLog), minecraftDir: minecraftDir)
            if crashes > 0 { throw HeadlessSoakError.crashReports(crashes) }
            if fatals > 0 { throw HeadlessSoakError.fatalLogLines(fatals) }
            if headlessMCNeedsAccount(readText(hmcLog)) {
                throw HeadlessSoakError.commandFailed("HeadlessMC account login is required for online-mode live soak")
            }
            Thread.sleep(forTimeInterval: 1)
        }
        try? send(command: "disconnect", to: stdin)
        Thread.sleep(forTimeInterval: 2)
        try? send(command: "quit", to: stdin)
        let output = readText(hmcLog)
        return ProcessResult(
            exitCode: 0,
            output: output,
            durationSeconds: Date().timeIntervalSince(connectedStart),
            timedOut: false
        )
    }

    private func ensureHeadlessMCJar() throws -> URL {
        let jar = config.headlessMCHome.appendingPathComponent("headlessmc-launcher-\(config.headlessMCVersion).jar")
        if fileManager.fileExists(atPath: jar.path) {
            return jar
        }
        let urls = [
            "https://github.com/3arthqu4ke/HeadlessMc/releases/download/\(config.headlessMCVersion)/headlessmc-launcher-\(config.headlessMCVersion).jar",
            "https://github.com/headlesshq/headlessmc/releases/download/\(config.headlessMCVersion)/headlessmc-launcher-\(config.headlessMCVersion).jar",
            "https://github.com/headlesshq/headlessmc/releases/download/\(config.headlessMCVersion)/headlessmc-launcher.jar"
        ]
        try downloadFirstAvailable(urls: urls, to: jar)
        return jar
    }

    private func ensureHMCSpecifics(minecraftDir: URL) throws {
        let mods = minecraftDir.appendingPathComponent("mods", isDirectory: true)
        try fileManager.createDirectory(at: mods, withIntermediateDirectories: true)
        let latestName = "hmc-specifics-\(config.minecraftVersion)-\(config.loader)-latest.jar"
        let latest = mods.appendingPathComponent(latestName)
        if !fileManager.fileExists(atPath: latest.path) {
            let url = "https://github.com/headlesshq/hmc-specifics/releases/download/\(config.minecraftVersion)-latest/\(latestName)"
            try downloadFirstAvailable(urls: [url], to: latest)
        }
        let legacyName = "hmc-specifics-\(config.minecraftVersion)-2.4.0-\(config.loader)-release.jar"
        let legacy = config.headlessMCHome
            .appendingPathComponent("HeadlessMC/specifics/hmc-specifics", isDirectory: true)
            .appendingPathComponent(legacyName)
        try fileManager.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: legacy.path) {
            try fileManager.copyItem(at: latest, to: legacy)
        }
    }

    private func seedClientOptions(minecraftDir: URL) throws {
        let options = minecraftDir.appendingPathComponent("options.txt")
        var values: [String: String] = [:]
        if let existing = try? String(contentsOf: options, encoding: .utf8) {
            for line in existing.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    values[parts[0]] = parts[1]
                }
            }
        }
        [
            "pauseOnLostFocus": "false",
            "onboardAccessibility": "false",
            "fullscreen": "false",
            "renderDistance": "6",
            "simulationDistance": "5",
            "maxFps": "60"
        ].forEach { values[$0.key] = $0.value }
        try values
            .keys
            .sorted()
            .map { "\($0):\(values[$0] ?? "")" }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: options, atomically: true, encoding: .utf8)
    }

    private func downloadFirstAvailable(urls: [String], to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        var errors: [String] = []
        for url in urls {
            do {
                let result = try runProcess(executable: "/usr/bin/curl", arguments: ["-fL", "--retry", "3", "--connect-timeout", "20", "-o", tmp.path, url], timeoutSeconds: 180, environment: [:])
                guard result.exitCode == 0 else {
                    errors.append("\(url): \(result.output)")
                    continue
                }
                let prefix = (try? Data(contentsOf: tmp).prefix(64)) ?? Data()
                if String(decoding: prefix, as: UTF8.self).lowercased().contains("<html") {
                    errors.append("\(url): returned HTML instead of jar")
                    try? fileManager.removeItem(at: tmp)
                    continue
                }
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: tmp, to: destination)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                return
            } catch {
                errors.append("\(url): \(error)")
                try? fileManager.removeItem(at: tmp)
            }
        }
        throw HeadlessSoakError.commandFailed("download failed: \(errors.joined(separator: " | "))")
    }

    private func startXvfbIfNeeded() throws -> (process: Process?, display: String) {
        if let display = ProcessInfo.processInfo.environment["DISPLAY"], !display.isEmpty {
            return (nil, display)
        }
        #if os(macOS)
        return (nil, "")
        #else
        let which = try runProcess(executable: "/usr/bin/which", arguments: ["Xvfb"], timeoutSeconds: 10, environment: [:])
        guard which.exitCode == 0 else {
            throw HeadlessSoakError.commandFailed("Xvfb is required when DISPLAY is not set")
        }
        let display = try firstFreeDisplay()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: which.output.trimmingCharacters(in: .whitespacesAndNewlines))
        process.arguments = [display, "-screen", "0", "1920x1080x24", "-ac", "+extension", "GLX", "+render", "-noreset"]
        let log = config.workDir.appendingPathComponent("xvfb.log")
        _ = fileManager.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        Thread.sleep(forTimeInterval: 2)
        try? handle.close()
        return (process, display)
        #endif
    }

    private func firstFreeDisplay() throws -> String {
        for number in 99..<130 {
            if !fileManager.fileExists(atPath: "/tmp/.X11-unix/X\(number)") {
                return ":\(number)"
            }
        }
        throw HeadlessSoakError.commandFailed("no free Xvfb display in :99-:129")
    }

    private func waitForInGame(process: Process, stdin: Pipe, hmcLog: URL, minecraftDir: URL, timeoutSeconds: Double) throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !process.isRunning {
                throw HeadlessSoakError.commandFailed("HeadlessMC exited before the client reached in-game state")
            }
            if !config.suppressGUI {
                try? send(command: "gui", to: stdin)
            }
            Thread.sleep(forTimeInterval: 5)
            let text = readText(hmcLog)
            if headlessMCNeedsAccount(text) {
                throw HeadlessSoakError.commandFailed("HeadlessMC account login is required for online-mode live soak")
            }
            if text.localizedCaseInsensitiveContains("currently not displaying a Gui") || observedLogin(in: text, minecraftDir: minecraftDir) {
                return
            }
            let crashes = countCrashReports(minecraftDir: minecraftDir)
            let fatals = countFatalLogLines(extraOutput: text, minecraftDir: minecraftDir)
            if crashes > 0 { throw HeadlessSoakError.crashReports(crashes) }
            if fatals > 0 { throw HeadlessSoakError.fatalLogLines(fatals) }
            if text.contains("TitleScreen") || text.contains("LoadingErrorScreen") {
                try? send(command: "connect \(parsedServerAddress().host) \(parsedServerAddress().port)", to: stdin)
            }
        }
        throw HeadlessSoakError.loginNotObserved
    }

    private func headlessMCNeedsAccount(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("You can't play the game without an account")
            || text.localizedCaseInsensitiveContains("Please use the login command")
    }

    private func parsedServerAddress() -> (host: String, port: Int) {
        let parts = config.serverAddress.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts.first ?? "91.99.176.243", parts.dropFirst().first.flatMap(Int.init) ?? 25565)
    }

    private func send(command: String, to stdin: Pipe) throws {
        try stdin.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
    }

    private func stopProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        Thread.sleep(forTimeInterval: 2)
        if process.isRunning {
            process.interrupt()
        }
    }

    private func readText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func observedLogin(in output: String, minecraftDir: URL) -> Bool {
        let text = (output + "\n" + collectedMinecraftLogs(minecraftDir: minecraftDir)).lowercased()
        let explicitLogin = [
            "joined the game",
            "logged in",
            "connected to server",
            "clientboundloginpacket",
            "minecraft:finish_configuration"
        ].contains { text.contains($0) }
        if explicitLogin {
            return true
        }

        let server = parsedServerAddress()
        let connectedToTargetServer = text.contains("connecting to \(server.host), \(server.port)")
            || text.contains("connecting to \(server.host):\(server.port)")
            || text.contains("--quickplaymultiplayer \(server.host):\(server.port)")
        let enteredGame = text.contains("time from main menu to in-game")
            || text.contains("total time to load game and open world")
        return connectedToTargetServer && enteredGame
    }

    private func countCrashReports(minecraftDir: URL) -> Int {
        let crashDir = minecraftDir.appendingPathComponent("crash-reports", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(at: crashDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "txt" }.count
    }

    private func countFatalLogLines(extraOutput: String, minecraftDir: URL) -> Int {
        let text = extraOutput + "\n" + collectedMinecraftLogs(minecraftDir: minecraftDir)
        return text
            .split(separator: "\n")
            .filter { isFatalLogLine(String($0)) }
            .count
    }

    private func isFatalLogLine(_ rawLine: String) -> Bool {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = line.lowercased()
        if lower.isEmpty { return false }

        if lower.contains("/fatal]") || lower.contains("[fatal]") {
            return true
        }

        if lower.contains("modloadingexception")
            || lower.contains("noclassdeffounderror")
            || lower.contains("crash report")
            || lower.contains("failed to connect")
            || lower.contains("connection refused")
            || lower.contains("version mismatch")
            || lower.contains("channel mismatch") {
            return true
        }

        if lower.contains("classnotfoundexception") {
            return lower.contains("/error]") && !lower.contains("[mixin/]")
        }

        return false
    }

    private func collectedMinecraftLogs(minecraftDir: URL) -> String {
        let logs = minecraftDir.appendingPathComponent("logs", isDirectory: true)
        let candidates = [
            logs.appendingPathComponent("latest.log"),
            config.workDir.appendingPathComponent("headless-minecraft.log"),
            config.workDir.appendingPathComponent("pummelchen-client-sync.log")
        ]
        return candidates.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    private func writeReport(
        started: Date,
        completed: Date,
        dmgSHA: String,
        status: String,
        installedFromDMG: Bool,
        javaOK: Bool,
        neoforgeOK: Bool,
        syncOK: Bool,
        loginOK: Bool,
        stayedConnected: Bool,
        crashReportCount: Int,
        fatalLogCount: Int,
        newPlayerSetup: NewPlayerSetupReport?,
        notes: String
    ) throws {
        try fileManager.createDirectory(at: config.report.deletingLastPathComponent(), withIntermediateDirectories: true)
        let report = SoakReport(
            releaseID: config.releaseID,
            dmgSHA256: dmgSHA,
            serverAddress: config.serverAddress,
            startedAt: Self.iso(started),
            completedAt: Self.iso(completed),
            durationSeconds: completed.timeIntervalSince(started),
            status: status,
            installedFromDMG: installedFromDMG,
            javaOK: javaOK,
            neoforgeOK: neoforgeOK,
            syncOK: syncOK,
            loginOK: loginOK,
            stayedConnected: stayedConnected,
            crashReportCount: crashReportCount,
            fatalLogCount: fatalLogCount,
            rendererSummary: "Swift DMG headless live soak",
            notes: notes,
            newPlayerSetup: newPlayerSetup
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: config.report, options: .atomic)
    }

    private func runProcess(executable: String, arguments: [String], timeoutSeconds: Double, environment: [String: String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pummelchen-process-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let start = Date()
        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var timedOut = false
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 2)
            if process.isRunning {
                process.interrupt()
            }
        }
        process.waitUntilExit()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return ProcessResult(
            exitCode: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            durationSeconds: Date().timeIntervalSince(start),
            timedOut: timedOut
        )
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

@main
struct PummelchenHeadlessSoakMain {
    static func main() {
        do {
            let config = try HeadlessSoakConfig(arguments: Arguments(CommandLine.arguments))
            try HeadlessSoakRunner(config: config).run()
            print("pummelchen_headless_soak=passed")
            print("report=\(config.report.path)")
        } catch {
            FileHandle.standardError.write(Data("pummelchen-headless-soak failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
