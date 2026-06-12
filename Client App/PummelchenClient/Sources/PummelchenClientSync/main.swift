import Foundation
import PummelchenClientCore

enum ClientSyncCLIError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              pummelchen-client-sync sync [--force] [--server-url <url>] [--minecraft-dir <path>] [--pummelchen-home <path>] [--db <path>] [--client-id <id>] [--client-api-token <token>] [--allow-while-running] [--no-report] [--skip-java-repair]
            """
        case .missingValue(let option):
            return "missing value for \(option)"
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
            if ["--force", "--allow-while-running", "--no-report", "--skip-java-repair"].contains(value) {
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
        clientAPIToken: args.options["--client-api-token"] ?? ProcessInfo.processInfo.environment["PUMMELCHEN_CLIENT_API_TOKEN"]
    )
}

@main
struct PummelchenClientSyncMain {
    static func main() async {
        do {
            let args = try Args(CommandLine.arguments)
            guard args.command == "sync" else {
                throw ClientSyncCLIError.usage
            }
            let engine = ClientSyncEngine(configuration: try config(from: args))
            let result = try await engine.sync(force: args.flags.contains("--force"))
            print("Pummelchen Swift Sync")
            print("Release: \(result.targetReleaseID)")
            print("Manifest: \(result.manifestEntries) file(s)")
            print("Verified: \(result.filesVerified)")
            print("Downloaded: \(result.filesDownloaded)")
            print("Quarantined: \(result.filesQuarantined)")
            print("Status: \(result.message)")
        } catch {
            FileHandle.standardError.write(Data("pummelchen-client-sync failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
