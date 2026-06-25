import Foundation
import MCPummelchenModShared

public struct ClientControlWatcherResult: Equatable, Sendable {
    public let cycles: Int
    public let eventsHandled: Int
    public let syncsRun: Int
    public let lastEventID: String?
    public let jitterSecondsApplied: Int
}

public struct ClientControlWatcher: Sendable {
    public let syncConfiguration: ClientSyncConfiguration
    public let waitSeconds: Int
    public let idleDelayNanoseconds: UInt64
    public let errorDelayNanoseconds: UInt64
    public let syncJitterSeconds: Int

    public init(
        syncConfiguration: ClientSyncConfiguration,
        waitSeconds: Int = 0,
        idleDelayNanoseconds: UInt64 = 5_000_000_000,
        errorDelayNanoseconds: UInt64 = 5_000_000_000,
        syncJitterSeconds: Int = 30
    ) {
        self.syncConfiguration = syncConfiguration
        self.waitSeconds = min(max(waitSeconds, 0), 30)
        self.idleDelayNanoseconds = idleDelayNanoseconds
        self.errorDelayNanoseconds = errorDelayNanoseconds
        self.syncJitterSeconds = max(0, syncJitterSeconds)
    }

    public func run(
        maxCycles: Int? = nil,
        afterEventID initialAfterEventID: String? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> ClientControlWatcherResult {
        let clientID = Self.validClientID(syncConfiguration.clientID ?? Host.current().localizedName)
        let channel = ClientControlChannel(configuration: ClientControlChannelConfiguration(
            serverURL: syncConfiguration.serverURL,
            clientID: clientID,
            clientAPIToken: syncConfiguration.clientAPIToken
        ))
        let store = ClientStatusStore(databaseURL: syncConfiguration.databaseURL)

        var cycles = 0
        var handled = 0
        var syncs = 0
        var jitterApplied = 0
        var afterEventID = initialAfterEventID

        while !Task.isCancelled {
            if let maxCycles, cycles >= maxCycles {
                break
            }
            cycles += 1

            do {
                let batch = try await channel.fetchEvents(
                    afterEventID: afterEventID,
                    limit: 50,
                    waitSeconds: waitSeconds
                )
                try? store.recordClientState(key: "last_control_transport", value: batch.transport)

                if batch.events.isEmpty {
                    try await Task.sleep(nanoseconds: idleDelayNanoseconds)
                    continue
                }

                for event in batch.events {
                    handled += 1
                    afterEventID = event.eventID
                    log?("control event \(event.eventType.rawValue): \(event.title)")
                    try? store.recordClientState(key: "last_control_event_id", value: event.eventID)
                    try? store.recordClientState(key: "last_control_event_type", value: event.eventType.rawValue)

                    if Self.requiresImmediateSync(event) {
                        syncs += 1
                        try? store.recordClientState(key: "last_control_sync_trigger", value: event.eventType.rawValue)

                        if event.eventType == .releaseAvailable, syncJitterSeconds > 0 {
                            let jitter = UInt64.random(in: 0...(UInt64(syncJitterSeconds) * 1_000_000_000))
                            jitterApplied += Int(jitter / 1_000_000_000)
                            log?("applying \(jitter / 1_000_000_000)s jitter before sync for releaseAvailable")
                            try await Task.sleep(nanoseconds: jitter)
                        }

                        do {
                            let result = try await ClientSyncEngine(configuration: syncConfiguration).sync(force: true)
                            log?("sync finished for \(event.eventID): \(result.message)")
                            if result.selfUpdateScheduled {
                                try await channel.acknowledge(event)
                                log?("client self-update scheduled; exiting watcher for relaunch")
                                return ClientControlWatcherResult(
                                    cycles: cycles,
                                    eventsHandled: handled,
                                    syncsRun: syncs,
                                    lastEventID: afterEventID,
                                    jitterSecondsApplied: jitterApplied
                                )
                            }
                        } catch {
                            log?("sync failed for \(event.eventID): \(error)")
                        }
                    }

                    try await channel.acknowledge(event)
                }
            } catch {
                log?("control channel error: \(error)")
                try? store.recordClientState(key: "last_control_error", value: String(describing: error))
                try await Task.sleep(nanoseconds: errorDelayNanoseconds)
            }
        }

        return ClientControlWatcherResult(
            cycles: cycles,
            eventsHandled: handled,
            syncsRun: syncs,
            lastEventID: afterEventID,
            jitterSecondsApplied: jitterApplied
        )
    }

    public static func requiresImmediateSync(_ event: ControlEvent) -> Bool {
        switch event.eventType {
        case .releaseAvailable, .syncRequired, .defaultsChanged, .clientSyncRequested:
            return true
        case .serverMessage, .serverRestartNotice, .healthUpdate:
            return false
        }
    }

    private static func validClientID(_ proposed: String?) -> String {
        let raw = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sanitized = raw.map { character -> Character in
            if character.isLetter || character.isNumber || character == "." || character == "_" || character == ":" || character == "@" || character == "-" {
                return character
            }
            return "-"
        }
        let value = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: ".:_@-"))
        if value.count >= 8 && value.count <= 128 {
            return value
        }
        return "pummelchen-client"
    }
}
