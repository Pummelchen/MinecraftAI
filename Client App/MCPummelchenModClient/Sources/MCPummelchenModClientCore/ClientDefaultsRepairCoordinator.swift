import Foundation
import MCPummelchenModShared

public struct ClientDefaultsRepairAttempt: Sendable, Equatable {
    public let rowID: String
    public let rowLabel: String
    public let statusBefore: ClientDefaultStatus
    public let statusAfter: ClientDefaultStatus
    public let detail: String?
    public let recommendedAction: String

    public init(
        rowID: String,
        rowLabel: String,
        statusBefore: ClientDefaultStatus,
        statusAfter: ClientDefaultStatus,
        detail: String?,
        recommendedAction: String
    ) {
        self.rowID = rowID
        self.rowLabel = rowLabel
        self.statusBefore = statusBefore
        self.statusAfter = statusAfter
        self.detail = detail
        self.recommendedAction = recommendedAction
    }
}

public struct ClientDefaultsRepairResult: Sendable {
    public let rows: [ClientDefaultHealthRow]
    public let attempts: [ClientDefaultsRepairAttempt]

    public var failedAttempts: [ClientDefaultsRepairAttempt] {
        attempts.filter { $0.statusAfter == .fixedFailed }
    }

    public init(rows: [ClientDefaultHealthRow], attempts: [ClientDefaultsRepairAttempt]) {
        self.rows = rows
        self.attempts = attempts
    }
}

public struct ClientDefaultsRepairCoordinator: Sendable {
    public let maxAttempts: Int

    public init(maxAttempts: Int = 2) {
        self.maxAttempts = max(1, maxAttempts)
    }

    public func repairDefaults(
        defaults: MinecraftClientDefaults,
        rows: [ClientDefaultHealthRow],
        minecraftDirectory: URL,
        pummelchenHome: URL,
        rowIDs: Set<String>? = nil
    ) async -> ClientDefaultsRepairResult {
        guard rows.contains(where: { $0.status.isActionable }) else {
            return ClientDefaultsRepairResult(rows: rows, attempts: [])
        }

        let effectiveDefaults = await ensureManagedDefaults(defaults, minecraftDirectory: minecraftDirectory, pummelchenHome: pummelchenHome)
        var workingRows = rows
        var attempts: [ClientDefaultsRepairAttempt] = []

        for row in workingRows where row.status.isActionable {
            guard rowIDs == nil || rowIDs?.contains(row.id) == true else {
                continue
            }
            let attemptTargets = rowsToRepair(from: workingRows, target: row)
            guard !attemptTargets.isEmpty else {
                continue
            }

            let status = row.status
            if let index = workingRows.firstIndex(where: { $0.id == row.id }) {
                workingRows[index] = workingRows[index].withStatus(.repairing)
            }

            let attemptResult = await repairRow(
                rowID: row.id,
                defaults: effectiveDefaults,
                rows: attemptTargets,
                minecraftDirectory: minecraftDirectory,
                pummelchenHome: pummelchenHome
            )

            let finalRow = attemptResult.updatedRows.first { $0.id == row.id } ?? row
            if let index = workingRows.firstIndex(where: { $0.id == row.id }) {
                workingRows[index] = finalRow
            }
            attempts.append(
                ClientDefaultsRepairAttempt(
                    rowID: row.id,
                    rowLabel: row.label,
                    statusBefore: status,
                    statusAfter: finalRow.status,
                    detail: attemptResult.detail,
                    recommendedAction: finalRow.recommendedAction
                )
            )
        }

        return ClientDefaultsRepairResult(rows: workingRows, attempts: attempts)
    }

    private func rowsToRepair(from rows: [ClientDefaultHealthRow], target: ClientDefaultHealthRow) -> [ClientDefaultHealthRow] {
        if target.id == "shader" || target.id == "resource_packs" {
            return rows.filter { ["shader", "resource_packs", "memory", "java_runtime", "server_entry", "physics_mob_fracturing"].contains($0.id) }
        }
        if target.id.hasPrefix("config/") || target.id == "server_entry" {
            return rows.filter { $0.id == target.id || $0.id == "shader" || $0.id == "resource_packs" }
        }
        return [target]
    }

    private func repairRow(
        rowID: String,
        defaults: MinecraftClientDefaults,
        rows: [ClientDefaultHealthRow],
        minecraftDirectory: URL,
        pummelchenHome: URL
    ) async -> (updatedRows: [ClientDefaultHealthRow], detail: String?) {
        var lastError: String?
        var currentDefaults = defaults

        for attempt in 1...maxAttempts {
            do {
                if rowID == "java_runtime" {
                    let java = try await JavaRuntimeManager.ensureInstalled(pummelchenHome: pummelchenHome)
                    currentDefaults = MinecraftClientDefaults(
                        shaderPack: defaults.shaderPack,
                        resourcePacks: defaults.resourcePacks,
                        javaArguments: defaults.javaArguments,
                        javaExecutablePath: java.javaExecutableURL.path,
                        loaderVersion: defaults.loaderVersion,
                        serverName: defaults.serverName,
                        serverAddress: defaults.serverAddress,
                        supportedServers: defaults.supportedServers,
                        irisProperties: defaults.irisProperties,
                        configProperties: defaults.configProperties,
                        physicsMobType: defaults.physicsMobType
                    )
                }

                try MinecraftClientDefaultWriter.apply(defaults: currentDefaults, to: minecraftDirectory)
                let refreshed = ClientDefaultsInspector.inspect(minecraftDirectory: minecraftDirectory, defaults: currentDefaults)
                let row = refreshed.first { $0.id == rowID }

                let merged = rows.map { candidate in
                    guard candidate.id == rowID else {
                        return candidate
                    }
                    if let row, row.status.isHealthy {
                        return row.withStatus(.fixedOK)
                    } else if let row {
                        return row.withStatus(.fail)
                    } else {
                        return candidate.withStatus(.fixedFailed)
                    }
                }

                if let row, row.status.isHealthy {
                    return (merged, nil)
                }

                lastError = "Attempt #\(attempt): row still reports status \(row?.status.displayValue ?? "unknown")"
            } catch {
                lastError = "Attempt #\(attempt): \(error)"
            }
        }

        return (rows.map { row in
            guard row.id == rowID else {
                return row
            }
            return row.withStatus(.fixedFailed)
        }, lastError)
    }

    private func ensureManagedDefaults(
        _ defaults: MinecraftClientDefaults,
        minecraftDirectory: URL,
        pummelchenHome: URL
    ) async -> MinecraftClientDefaults {
        guard defaults.javaExecutablePath == nil else {
            return defaults
        }
        do {
            let java = try await JavaRuntimeManager.ensureInstalled(pummelchenHome: pummelchenHome)
            return MinecraftClientDefaults(
                shaderPack: defaults.shaderPack,
                resourcePacks: defaults.resourcePacks,
                javaArguments: defaults.javaArguments,
                javaExecutablePath: java.javaExecutableURL.path,
                loaderVersion: defaults.loaderVersion,
                serverName: defaults.serverName,
                serverAddress: defaults.serverAddress,
                supportedServers: defaults.supportedServers,
                irisProperties: defaults.irisProperties,
                configProperties: defaults.configProperties,
                physicsMobType: defaults.physicsMobType
            )
        } catch {
            _ = minecraftDirectory
            return defaults
        }
    }
}

private extension ClientDefaultHealthRow {
    func withStatus(_ status: ClientDefaultStatus) -> ClientDefaultHealthRow {
        ClientDefaultHealthRow(
            id: id,
            label: label,
            desiredValue: desiredValue,
            observedValue: observedValue,
            status: status,
            source: source,
            recommendedAction: recommendedAction
        )
    }
}
