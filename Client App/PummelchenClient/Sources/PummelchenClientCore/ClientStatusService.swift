import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PummelchenCore

public enum ClientSyncState: String, Codable, Equatable, Sendable {
    case synced
    case updateAvailable = "update_available"
    case offline
    case repairNeeded = "repair_needed"
}

public struct ClientStatusSnapshot: Codable, Equatable, Sendable {
    public let state: ClientSyncState
    public let serverURL: String
    public let serverReleaseID: String?
    public let localReleaseID: String?
    public let checkedAt: String
    public let minecraftDirectory: String
    public let localDatabase: String
    public let defaultsHealth: [ClientDefaultHealthRow]
    public let errorMessage: String?

    public var defaultsOK: Bool {
        defaultsHealth.allSatisfy { $0.status == .ok }
    }

    public init(
        state: ClientSyncState,
        serverURL: String,
        serverReleaseID: String?,
        localReleaseID: String?,
        checkedAt: String,
        minecraftDirectory: String,
        localDatabase: String,
        defaultsHealth: [ClientDefaultHealthRow],
        errorMessage: String?
    ) {
        self.state = state
        self.serverURL = serverURL
        self.serverReleaseID = serverReleaseID
        self.localReleaseID = localReleaseID
        self.checkedAt = checkedAt
        self.minecraftDirectory = minecraftDirectory
        self.localDatabase = localDatabase
        self.defaultsHealth = defaultsHealth
        self.errorMessage = errorMessage
    }
}

public struct ClientStatusConfiguration: Sendable {
    public let serverURL: URL
    public let minecraftDirectory: URL
    public let databaseURL: URL

    public init(serverURL: URL = URL(string: "https://pummelchen.91.99.176.243.nip.io")!, minecraftDirectory: URL, databaseURL: URL) {
        self.serverURL = serverURL
        self.minecraftDirectory = minecraftDirectory
        self.databaseURL = databaseURL
    }

    public static func productionDefault(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> ClientStatusConfiguration {
        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        return ClientStatusConfiguration(
            minecraftDirectory: appSupport.appendingPathComponent("minecraft", isDirectory: true),
            databaseURL: appSupport.appendingPathComponent("Pummelchen/client.duckdb")
        )
    }
}

public struct ClientStatusService: Sendable {
    public let configuration: ClientStatusConfiguration
    public let store: ClientStatusStore

    public init(configuration: ClientStatusConfiguration) {
        self.configuration = configuration
        self.store = ClientStatusStore(databaseURL: configuration.databaseURL)
    }

    public func checkAndRecord() async -> ClientStatusSnapshot {
        let snapshot = await check()
        do {
            try store.record(snapshot: snapshot)
        } catch {
            return ClientStatusSnapshot(
                state: snapshot.state == .offline ? .offline : .repairNeeded,
                serverURL: snapshot.serverURL,
                serverReleaseID: snapshot.serverReleaseID,
                localReleaseID: snapshot.localReleaseID,
                checkedAt: snapshot.checkedAt,
                minecraftDirectory: snapshot.minecraftDirectory,
                localDatabase: snapshot.localDatabase,
                defaultsHealth: snapshot.defaultsHealth,
                errorMessage: "local DuckDB write failed: \(error)"
            )
        }
        return snapshot
    }

    public func check() async -> ClientStatusSnapshot {
        let checkedAt = Self.isoNow()
        let localRelease = readInstalledRelease()
        let defaultsHealth = ClientDefaultsInspector.inspect(minecraftDirectory: configuration.minecraftDirectory)

        do {
            let serverRelease = try await fetchCurrentRelease()
            let state: ClientSyncState = localRelease == serverRelease.releaseID ? .synced : .updateAvailable
            return ClientStatusSnapshot(
                state: state,
                serverURL: configuration.serverURL.absoluteString,
                serverReleaseID: serverRelease.releaseID,
                localReleaseID: localRelease,
                checkedAt: checkedAt,
                minecraftDirectory: configuration.minecraftDirectory.path,
                localDatabase: configuration.databaseURL.path,
                defaultsHealth: defaultsHealth,
                errorMessage: nil
            )
        } catch {
            return ClientStatusSnapshot(
                state: .offline,
                serverURL: configuration.serverURL.absoluteString,
                serverReleaseID: nil,
                localReleaseID: localRelease,
                checkedAt: checkedAt,
                minecraftDirectory: configuration.minecraftDirectory.path,
                localDatabase: configuration.databaseURL.path,
                defaultsHealth: defaultsHealth,
                errorMessage: String(describing: error)
            )
        }
    }

    private func fetchCurrentRelease() async throws -> CurrentRelease {
        let url = configuration.serverURL
            .appendingPathComponent("downloads/current-release.json")
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse {
            try ContractValidation.require((200..<300).contains(http.statusCode), "current release fetch failed with HTTP \(http.statusCode)")
        }
        let release = try CurrentReleaseValidator.decode(data)
        try CurrentReleaseValidator.validate(release)
        return release
    }

    private func readInstalledRelease() -> String? {
        let url = configuration.minecraftDirectory
            .appendingPathComponent(".pummelchen/installed-release.txt")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let filtered = raw.filter { character in
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }
        return filtered.isEmpty ? nil : String(filtered.prefix(120))
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
