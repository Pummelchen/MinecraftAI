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
    public let webTransportFailureThreshold: Int
    public let webTransportProbeInterval: Int

    public init(
        syncConfiguration: ClientSyncConfiguration,
        waitSeconds: Int = 25,
        idleDelayNanoseconds: UInt64 = 700_000_000,
        errorDelayNanoseconds: UInt64 = 3_000_000_000,
        syncJitterSeconds: Int = 30,
        webTransportFailureThreshold: Int = 3,
        webTransportProbeInterval: Int = 5
    ) {
        self.syncConfiguration = syncConfiguration
        self.waitSeconds = min(max(waitSeconds, 1), 30)
        self.idleDelayNanoseconds = idleDelayNanoseconds
        self.errorDelayNanoseconds = errorDelayNanoseconds
        self.syncJitterSeconds = max(0, syncJitterSeconds)
        self.webTransportFailureThreshold = max(1, webTransportFailureThreshold)
        self.webTransportProbeInterval = max(1, webTransportProbeInterval)
    }

    private enum TransportMode {
        case webTransport
        case httpFallback(cyclesInFallback: Int)
    }

    public func run(
        maxCycles: Int? = nil,
        afterEventID initialAfterEventID: String? = nil,
        log: (@Sendable (String) -> Void)? = nil
    ) async throws -> ClientControlWatcherResult {
        guard let token = syncConfiguration.clientAPIToken, !token.isEmpty else {
            throw ContractValidationError.invalid("client API token is required for the control channel")
        }

        let clientID = Self.validClientID(syncConfiguration.clientID ?? Host.current().localizedName)
        let channel = ClientControlChannel(configuration: ClientControlChannelConfiguration(
            serverURL: syncConfiguration.serverURL,
            clientID: clientID,
            clientAPIToken: token
        ))
        let store = ClientStatusStore(databaseURL: syncConfiguration.databaseURL)

        let pooledChannel = PooledWebTransportChannel(
            preflightProvider: { try await channel.webTransportPreflight() },
            clientID: clientID,
            clientAPIToken: token
        )

        var cycles = 0
        var handled = 0
        var syncs = 0
        var jitterApplied = 0
        var afterEventID = initialAfterEventID
        var transportMode: TransportMode = .webTransport
        var consecutiveWTFailures = 0

        while !Task.isCancelled {
            if let maxCycles, cycles >= maxCycles {
                break
            }
            cycles += 1

            do {
                let batch: ControlEventBatch

                switch transportMode {
                case .webTransport:
                    batch = try await pooledChannel.fetchEvents(afterEventID: afterEventID)
                    consecutiveWTFailures = 0
                    try? store.recordClientState(key: "last_control_network_protocol", value: "webtransport-pooled")

                case .httpFallback(var cyclesInFallback):
                    cyclesInFallback += 1

                    if cyclesInFallback.isMultiple(of: webTransportProbeInterval) {
                        if let preflight = try? await channel.webTransportPreflight(), preflight.ready {
                            log?("WebTransport recovered, switching back")
                            transportMode = .webTransport
                            consecutiveWTFailures = 0
                            try? store.recordClientState(key: "last_control_transport", value: "webtransport")
                            continue
                        }
                    }

                    batch = try await channel.fetchMissedEvents(
                        afterEventID: afterEventID,
                        limit: 50,
                        waitSeconds: waitSeconds
                    )
                    transportMode = .httpFallback(cyclesInFallback: cyclesInFallback)
                    try? store.recordClientState(key: "last_control_transport", value: "http-fallback")
                }

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
                                try await pooledChannel.acknowledge(event)
                                log?("client self-update scheduled; exiting watcher for relaunch")
                                await pooledChannel.teardown()
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

                    try await pooledChannel.acknowledge(event)
                }
            } catch {
                log?("control channel error: \(error)")

                if case .webTransport = transportMode {
                    consecutiveWTFailures += 1
                    if consecutiveWTFailures >= webTransportFailureThreshold {
                        log?("switching to HTTP long-poll fallback after \(consecutiveWTFailures) WebTransport failures")
                        transportMode = .httpFallback(cyclesInFallback: 0)
                        try? store.recordClientState(key: "last_control_transport", value: "http-fallback")
                        consecutiveWTFailures = 0
                    }
                }

                try await Task.sleep(nanoseconds: errorDelayNanoseconds)
            }
        }

        await pooledChannel.teardown()

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
