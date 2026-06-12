import Foundation

public struct APIEnvelope<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let ok: Bool
    public let generatedAt: String
    public let payload: Payload

    enum CodingKeys: String, CodingKey {
        case ok
        case generatedAt = "generated_at"
        case payload
    }

    public init(ok: Bool, generatedAt: String, payload: Payload) {
        self.ok = ok
        self.generatedAt = generatedAt
        self.payload = payload
    }
}

public struct ClientStatusReport: Codable, Equatable, Sendable {
    public let clientID: String
    public let reportedAt: String
    public let installedReleaseID: String?
    public let targetReleaseID: String?
    public let status: String
    public let manifestEntries: Int?
    public let changedFiles: Int
    public let lastError: String?
    public let message: String?
    public let osSummary: String?
    public let arch: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case reportedAt = "reported_at"
        case installedReleaseID = "installed_release_id"
        case targetReleaseID = "target_release_id"
        case status
        case manifestEntries = "manifest_entries"
        case changedFiles = "changed_files"
        case lastError = "last_error"
        case message
        case osSummary = "os_summary"
        case arch
    }

    public init(
        clientID: String,
        reportedAt: String,
        installedReleaseID: String?,
        targetReleaseID: String?,
        status: String,
        manifestEntries: Int?,
        changedFiles: Int,
        lastError: String?,
        message: String?,
        osSummary: String?,
        arch: String?
    ) {
        self.clientID = clientID
        self.reportedAt = reportedAt
        self.installedReleaseID = installedReleaseID
        self.targetReleaseID = targetReleaseID
        self.status = status
        self.manifestEntries = manifestEntries
        self.changedFiles = changedFiles
        self.lastError = lastError
        self.message = message
        self.osSummary = osSummary
        self.arch = arch
    }
}

public struct ClientRegistrationRequest: Codable, Equatable, Sendable {
    public let clientID: String
    public let displayName: String?
    public let osSummary: String?
    public let arch: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case displayName = "display_name"
        case osSummary = "os_summary"
        case arch
    }

    public init(clientID: String, displayName: String?, osSummary: String?, arch: String?) {
        self.clientID = clientID
        self.displayName = displayName
        self.osSummary = osSummary
        self.arch = arch
    }
}

public struct ClientInventoryUpload: Codable, Equatable, Sendable {
    public let clientID: String
    public let reportedAt: String
    public let files: [ClientInventoryFile]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case reportedAt = "reported_at"
        case files
    }

    public init(clientID: String, reportedAt: String, files: [ClientInventoryFile]) {
        self.clientID = clientID
        self.reportedAt = reportedAt
        self.files = files
    }
}

public struct ClientInventoryFile: Codable, Equatable, Sendable {
    public let section: String
    public let name: String
    public let sizeBytes: Int
    public let sha256: String
    public let status: String

    enum CodingKeys: String, CodingKey {
        case section
        case name
        case sizeBytes = "size_bytes"
        case sha256
        case status
    }

    public init(section: String, name: String, sizeBytes: Int, sha256: String, status: String) {
        self.section = section
        self.name = name
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.status = status
    }
}

public struct ClientDiagnosticsUpload: Codable, Equatable, Sendable {
    public let clientID: String
    public let reportedAt: String
    public let level: String
    public let summary: String
    public let details: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case reportedAt = "reported_at"
        case level
        case summary
        case details
    }

    public init(clientID: String, reportedAt: String, level: String, summary: String, details: String?) {
        self.clientID = clientID
        self.reportedAt = reportedAt
        self.level = level
        self.summary = summary
        self.details = details
    }
}

public struct ClientDefaultsEventUpload: Codable, Equatable, Sendable {
    public let clientID: String
    public let reportedAt: String
    public let defaultsOK: Bool
    public let events: [ClientDefaultsEvent]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case reportedAt = "reported_at"
        case defaultsOK = "defaults_ok"
        case events
    }

    public init(clientID: String, reportedAt: String, defaultsOK: Bool, events: [ClientDefaultsEvent]) {
        self.clientID = clientID
        self.reportedAt = reportedAt
        self.defaultsOK = defaultsOK
        self.events = events
    }
}

public struct ClientDefaultsEvent: Codable, Equatable, Sendable {
    public let key: String
    public let status: String
    public let desiredValue: String
    public let observedValue: String?

    enum CodingKeys: String, CodingKey {
        case key
        case status
        case desiredValue = "desired_value"
        case observedValue = "observed_value"
    }

    public init(key: String, status: String, desiredValue: String, observedValue: String?) {
        self.key = key
        self.status = status
        self.desiredValue = desiredValue
        self.observedValue = observedValue
    }
}

public struct ClientHealthSummary: Codable, Equatable, Sendable {
    public let totalClients: Int
    public let synced: Int
    public let needsDefaultsRepair: Int
    public let failedChecksum: Int
    public let staleRelease: Int
    public let error: Int

    enum CodingKeys: String, CodingKey {
        case totalClients = "total_clients"
        case synced
        case needsDefaultsRepair = "needs_defaults_repair"
        case failedChecksum = "failed_checksum"
        case staleRelease = "stale_release"
        case error
    }

    public init(totalClients: Int, synced: Int, needsDefaultsRepair: Int, failedChecksum: Int, staleRelease: Int, error: Int) {
        self.totalClients = totalClients
        self.synced = synced
        self.needsDefaultsRepair = needsDefaultsRepair
        self.failedChecksum = failedChecksum
        self.staleRelease = staleRelease
        self.error = error
    }
}

public struct ClientWriteAck: Codable, Equatable, Sendable {
    public let ok: Bool
    public let clientID: String?
    public let files: Int?
    public let events: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case clientID = "client_id"
        case files
        case events
    }

    public init(ok: Bool = true, clientID: String? = nil, files: Int? = nil, events: Int? = nil) {
        self.ok = ok
        self.clientID = clientID
        self.files = files
        self.events = events
    }
}

public enum ControlEventType: String, Codable, CaseIterable, Sendable {
    case releaseAvailable = "release_available"
    case serverMessage = "server_message"
    case serverRestartNotice = "server_restart_notice"
    case clientSyncRequested = "client_sync_requested"
    case healthUpdate = "health_update"
}

public struct ControlEvent: Codable, Equatable, Sendable {
    public let eventID: String
    public let eventType: ControlEventType
    public let createdAt: String
    public let targetClientID: String?
    public let releaseID: String?
    public let priority: String
    public let title: String
    public let message: String
    public let payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case eventType = "event_type"
        case createdAt = "created_at"
        case targetClientID = "target_client_id"
        case releaseID = "release_id"
        case priority
        case title
        case message
        case payload
    }

    public init(
        eventID: String,
        eventType: ControlEventType,
        createdAt: String,
        targetClientID: String?,
        releaseID: String?,
        priority: String,
        title: String,
        message: String,
        payload: [String: String] = [:]
    ) {
        self.eventID = eventID
        self.eventType = eventType
        self.createdAt = createdAt
        self.targetClientID = targetClientID
        self.releaseID = releaseID
        self.priority = priority
        self.title = title
        self.message = message
        self.payload = payload
    }
}

public struct ControlEventCreateRequest: Codable, Equatable, Sendable {
    public let eventType: ControlEventType
    public let targetClientID: String?
    public let releaseID: String?
    public let priority: String
    public let title: String
    public let message: String
    public let payload: [String: String]

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case targetClientID = "target_client_id"
        case releaseID = "release_id"
        case priority
        case title
        case message
        case payload
    }

    public init(
        eventType: ControlEventType,
        targetClientID: String?,
        releaseID: String?,
        priority: String = "normal",
        title: String,
        message: String,
        payload: [String: String] = [:]
    ) {
        self.eventType = eventType
        self.targetClientID = targetClientID
        self.releaseID = releaseID
        self.priority = priority
        self.title = title
        self.message = message
        self.payload = payload
    }
}

public struct ControlEventBatch: Codable, Equatable, Sendable {
    public let events: [ControlEvent]
    public let nextAfterEventID: String?
    public let transport: String
    public let fallback: String

    enum CodingKeys: String, CodingKey {
        case events
        case nextAfterEventID = "next_after_event_id"
        case transport
        case fallback
    }

    public init(events: [ControlEvent], nextAfterEventID: String?, transport: String, fallback: String) {
        self.events = events
        self.nextAfterEventID = nextAfterEventID
        self.transport = transport
        self.fallback = fallback
    }
}

public struct ControlChannelInfo: Codable, Equatable, Sendable {
    public let endpoint: String
    public let transportTarget: String
    public let bidirectional: Bool
    public let fallbackEndpoint: String
    public let maxPayloadBytes: Int
    public let downloadsAllowed: Bool
    public let supportedEvents: [String]

    enum CodingKeys: String, CodingKey {
        case endpoint
        case transportTarget = "transport_target"
        case bidirectional
        case fallbackEndpoint = "fallback_endpoint"
        case maxPayloadBytes = "max_payload_bytes"
        case downloadsAllowed = "downloads_allowed"
        case supportedEvents = "supported_events"
    }

    public init(endpoint: String, transportTarget: String, bidirectional: Bool, fallbackEndpoint: String, maxPayloadBytes: Int, downloadsAllowed: Bool, supportedEvents: [String]) {
        self.endpoint = endpoint
        self.transportTarget = transportTarget
        self.bidirectional = bidirectional
        self.fallbackEndpoint = fallbackEndpoint
        self.maxPayloadBytes = maxPayloadBytes
        self.downloadsAllowed = downloadsAllowed
        self.supportedEvents = supportedEvents
    }
}

public struct ControlEventAck: Codable, Equatable, Sendable {
    public let clientID: String
    public let eventID: String
    public let receivedAt: String

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case eventID = "event_id"
        case receivedAt = "received_at"
    }

    public init(clientID: String, eventID: String, receivedAt: String) {
        self.clientID = clientID
        self.eventID = eventID
        self.receivedAt = receivedAt
    }
}

public struct ReleaseHistoryEntry: Codable, Equatable, Sendable {
    public let releaseID: String
    public let status: String
    public let createdAt: String
    public let activatedAt: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case releaseID = "release_id"
        case status
        case createdAt = "created_at"
        case activatedAt = "activated_at"
        case notes
    }

    public init(releaseID: String, status: String, createdAt: String, activatedAt: String?, notes: String?) {
        self.releaseID = releaseID
        self.status = status
        self.createdAt = createdAt
        self.activatedAt = activatedAt
        self.notes = notes
    }
}

public struct TestedUpdateRow: Codable, Equatable, Sendable {
    public let testedAt: String
    public let testedAtDisplay: String
    public let title: String
    public let eventType: String
    public let source: String
    public let status: String
    public let oldFile: String?
    public let newFile: String?
    public let version: String?
    public let sourceURL: String?
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case testedAt = "tested_at"
        case testedAtDisplay = "tested_at_display"
        case title
        case eventType = "event_type"
        case source
        case status
        case oldFile = "old_file"
        case newFile = "new_file"
        case version
        case sourceURL = "source_url"
        case notes
    }
}

public struct FailedModRow: Codable, Equatable, Sendable {
    public let failedAt: String
    public let failedAtDisplay: String
    public let title: String
    public let sourceURL: String?
    public let filename: String?
    public let version: String?
    public let failureReason: String
    public let details: String

    enum CodingKeys: String, CodingKey {
        case failedAt = "failed_at"
        case failedAtDisplay = "failed_at_display"
        case title
        case sourceURL = "source_url"
        case filename
        case version
        case failureReason = "failure_reason"
        case details
    }
}
