import Foundation
import MCPummelchenModShared

public struct ClientSupportedVersionsResolver: Sendable {
    public let serverURL: URL
    public let http: ClientHTTPClient
    public let store: ClientStatusStore?
    public let apiBasePath: String
    public let assignedMinecraftVersion: String?

    public init(
        serverURL: URL,
        http: ClientHTTPClient,
        store: ClientStatusStore? = nil,
        apiBasePath: String = ClientAppBundleDefaults.apiBasePath,
        assignedMinecraftVersion: String? = ClientAppBundleDefaults.minecraftVersion
    ) {
        self.serverURL = serverURL
        self.http = http
        self.store = store
        let trimmed = apiBasePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.apiBasePath = trimmed.isEmpty ? "api" : trimmed
        let assigned = assignedMinecraftVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.assignedMinecraftVersion = assigned.isEmpty ? nil : assigned
    }

    public func resolve() async -> [MinecraftSupportedServer] {
        do {
            let servers = filterAssigned(try await fetchFromServer())
            try? store?.record(supportedServers: servers)
            return servers
        } catch {
            if let cached = (try? store?.loadSupportedServers()).map(filterAssigned) ?? nil,
               !cached.isEmpty {
                return cached
            }
            return filterAssigned(MinecraftClientDefaults.defaultSupportedServers)
        }
    }

    public func fetchFromServer() async throws -> [MinecraftSupportedServer] {
        let url = serverURL.appendingPathComponent([apiBasePath, "v1/minecraft/server-versions"].joined(separator: "/"))
        let data = try await http.data(from: url)
        let response = try JSONDecoder().decode(MinecraftSupportedServersResponse.self, from: data)
        return try Self.validated(response.versions)
    }

    private func filterAssigned(_ servers: [MinecraftSupportedServer]) -> [MinecraftSupportedServer] {
        guard let assignedMinecraftVersion else {
            return servers
        }
        return servers.filter { $0.minecraftVersion == assignedMinecraftVersion }
    }

    public static func validated(_ servers: [MinecraftSupportedServer]) throws -> [MinecraftSupportedServer] {
        var seenVersions = Set<String>()
        var validated: [MinecraftSupportedServer] = []
        for server in servers {
            let minecraftVersion = server.minecraftVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            let loader = server.loader.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let loaderVersion = server.loaderVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverName = server.serverName.trimmingCharacters(in: .whitespacesAndNewlines)
            let serverAddress = server.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !minecraftVersion.isEmpty,
                  !loader.isEmpty,
                  !loaderVersion.isEmpty,
                  !serverName.isEmpty,
                  !serverAddress.isEmpty,
                  seenVersions.insert(minecraftVersion).inserted else {
                continue
            }
            validated.append(MinecraftSupportedServer(
                minecraftVersion: minecraftVersion,
                loader: loader,
                loaderVersion: loaderVersion,
                serverName: serverName,
                serverAddress: serverAddress,
                isLive: server.isLive,
                status: server.status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (server.isLive ? "live" : "staging") : server.status,
                installerName: cleanOptional(server.installerName),
                installerSHA256: cleanOptional(server.installerSHA256)?.lowercased(),
                installerURL: cleanOptional(server.installerURL)
            ))
        }
        guard !validated.isEmpty, validated.contains(where: \.isLive) else {
            throw ContractValidationError.invalid("server versions response must include at least one live supported version")
        }
        return validated
    }

    private static func cleanOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
