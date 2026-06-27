import Foundation
import MCPummelchenModClientCore

enum ClientSyncCLIError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case invalidValue(String)

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              pummelchen-client-sync sync [--force] [--server-url <url>] [--api-base-path <path>] [--current-release-path <path>] [--minecraft-dir <path>] [--pummelchen-home <path>] [--db <path>] [--client-id <id>] [--no-client-api-token] [--allow-while-running] [--no-report] [--skip-java-repair]
              pummelchen-client-sync watch [--server-url <url>] [--api-base-path <path>] [--current-release-path <path>] [--minecraft-dir <path>] [--pummelchen-home <path>] [--db <path>] [--client-id <id>] [--no-client-api-token] [--max-cycles <n>] [--after-event-id <id>] [--allow-while-running] [--no-report] [--skip-java-repair]
            """
        case .missingValue(let option):
            return "missing value for \(option)"
        case .invalidValue(let message):
            return message
        }
    }
}

struct Args {
    let command: String
    let options: [String: String]
    let flags: Set<String>

    init(_ raw: [String]) throws {
        guard raw.count >= 2 else {
            throw ClientSyncCLIError.usage
        }
        command = raw[1]
        var options: [String: String] = [:]
        var flags: Set<String> = []
        var index = 2
        while index < raw.count {
            let value = raw[index]
            if ["--force", "--allow-while-running", "--no-report", "--skip-java-repair", "--no-client-api-token"].contains(value) {
                flags.insert(value)
                index += 1
                continue
            }
            guard value.hasPrefix("--") else {
                throw ClientSyncCLIError.usage
            }
            guard index + 1 < raw.count else {
                throw ClientSyncCLIError.missingValue(value)
            }
            options[value] = raw[index + 1]
            index += 2
        }
        self.options = options
        self.flags = flags
    }
}

func config(from args: Args) throws -> ClientSyncConfiguration {
    if args.options["--client-api-token"] != nil {
        throw ClientSyncCLIError.invalidValue("--client-api-token is not accepted; use PUMMELCHEN_CLIENT_API_TOKEN or the private app resource")
    }
    let defaults = ClientSyncConfiguration.productionDefault()
    let serverURL = args.options["--server-url"].flatMap(URL.init(string:)) ?? defaults.serverURL
    let minecraft = args.options["--minecraft-dir"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaults.minecraftDirectory
    let home = args.options["--pummelchen-home"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaults.pummelchenHome
    let db = args.options["--db"].map { URL(fileURLWithPath: $0) } ?? defaults.databaseURL
    return ClientSyncConfiguration(
        serverURL: serverURL,
        minecraftDirectory: minecraft,
        pummelchenHome: home,
        databaseURL: db,
        allowWhileMinecraftRunning: args.flags.contains("--allow-while-running"),
        reportToServer: !args.flags.contains("--no-report"),
        manageJavaRuntime: !args.flags.contains("--skip-java-repair"),
        clientID: args.options["--client-id"],
        clientAPIToken: args.flags.contains("--no-client-api-token") ? nil : ClientCredentialProvider.defaultClientAPIToken(),
        apiBasePath: args.options["--api-base-path"] ?? ClientAppBundleDefaults.apiBasePath,
        currentReleasePath: args.options["--current-release-path"] ?? ClientAppBundleDefaults.currentReleasePath
    )
}

@main
struct MCPummelchenModClientSyncMain {
    static func main() async {
        do {
            let args = try Args(CommandLine.arguments)
            guard ["sync", "watch"].contains(args.command) else {
                throw ClientSyncCLIError.usage
            }
            let configuration = try config(from: args)
            if args.command == "watch" {
                print("Pummelchen Swift Control Watcher")
                print("Server: \(configuration.serverURL.absoluteString)")
                let maxCycles = args.options["--max-cycles"].flatMap(Int.init)
                let result = try await ClientControlWatcher(syncConfiguration: configuration).run(
                    maxCycles: maxCycles,
                    afterEventID: args.options["--after-event-id"]
                ) { message in
                    print(message)
                }
                print("Cycles: \(result.cycles)")
                print("Events handled: \(result.eventsHandled)")
                print("Syncs run: \(result.syncsRun)")
                if let lastEventID = result.lastEventID {
                    print("Last event: \(lastEventID)")
                }
            } else {
                let engine = ClientSyncEngine(configuration: configuration)
                let result = try await engine.sync(force: args.flags.contains("--force"))
                print("Pummelchen Swift Sync")
                print("Release: \(result.targetReleaseID)")
                print("Manifest: \(result.manifestEntries) file(s)")
                print("Verified: \(result.filesVerified)")
                print("Downloaded: \(result.filesDownloaded)")
                print("Quarantined: \(result.filesQuarantined)")
                print("Status: \(result.message)")
                if result.selfUpdateScheduled {
                    print("Client app update: scheduled; the app will relaunch after this helper exits.")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("pummelchen-client-sync failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
