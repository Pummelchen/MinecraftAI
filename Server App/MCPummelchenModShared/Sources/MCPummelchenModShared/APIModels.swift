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
    public let minecraftVersion: String?
    public let loaderVersion: String?

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
        case minecraftVersion = "minecraft_version"
        case loaderVersion = "loader_version"
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
        arch: String?,
        minecraftVersion: String? = nil,
        loaderVersion: String? = nil
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
        self.minecraftVersion = minecraftVersion
        self.loaderVersion = loaderVersion
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
    public let minecraftVersion: String?
    public let loaderVersion: String?
    public let files: [ClientInventoryFile]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case reportedAt = "reported_at"
        case minecraftVersion = "minecraft_version"
        case loaderVersion = "loader_version"
        case files
    }

    public init(
        clientID: String,
        reportedAt: String,
        minecraftVersion: String? = nil,
        loaderVersion: String? = nil,
        files: [ClientInventoryFile]
    ) {
        self.clientID = clientID
        self.reportedAt = reportedAt
        self.minecraftVersion = minecraftVersion
        self.loaderVersion = loaderVersion
        self.files = files
    }
}

public struct ClientInventoryFile: Codable, Equatable, Sendable {
    public let section: String
    public let name: String
    public let sizeBytes: Int
    public let sha256: String
    public let status: String
    public let minecraftVersion: String?
    public let loaderVersion: String?

    enum CodingKeys: String, CodingKey {
        case section
        case name
        case sizeBytes = "size_bytes"
        case sha256
        case status
        case minecraftVersion = "minecraft_version"
        case loaderVersion = "loader_version"
    }

    public init(
        section: String,
        name: String,
        sizeBytes: Int,
        sha256: String,
        status: String,
        minecraftVersion: String? = nil,
        loaderVersion: String? = nil
    ) {
        self.section = section
        self.name = name
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.status = status
        self.minecraftVersion = minecraftVersion
        self.loaderVersion = loaderVersion
    }
}

public struct ClientDiagnosticsUpload: Codable, Equatable, Sendable {
    public let clientID: String
    public let reportedAt: String
    public let level: String
    public let summary: String
    public let details: String?
    public let clientIP: String?
    public let logFiles: [String]
    public let logSnippet: String?

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case reportedAt = "reported_at"
        case level
        case summary
        case details
        case clientIP = "client_ip"
        case logFiles = "log_files"
        case logSnippet = "log_snippet"
    }

    public init(
        clientID: String,
        reportedAt: String,
        level: String,
        summary: String,
        details: String?,
        clientIP: String? = nil,
        logFiles: [String] = [],
        logSnippet: String? = nil
    ) {
        self.clientID = clientID
        self.reportedAt = reportedAt
        self.level = level
        self.summary = summary
        self.details = details
        self.clientIP = clientIP
        self.logFiles = logFiles
        self.logSnippet = logSnippet
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
    case syncRequired = "sync_required"
    case defaultsChanged = "defaults_changed"
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

public struct WebTransportPreflightPayload: Codable, Equatable, Sendable {
    public let apiVersion: String
    public let serverTime: String
    public let draft: String
    public let endpoint: String
    public let sessionURL: String
    public let publicHost: String
    public let publicPort: Int
    public let ready: Bool
    public let unsupportedReason: String?
    public let upgradeToken: String
    public let requiredHTTP3Settings: [String: UInt64]
    public let requiresQUICDatagrams: Bool
    public let requiresResetStreamAt: Bool
    public let usesNginx: Bool
    public let nginxRole: String
    public let serverPublicKeyX963Base64: String?

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case serverTime = "server_time"
        case draft
        case endpoint
        case sessionURL = "session_url"
        case publicHost = "public_host"
        case publicPort = "public_port"
        case ready
        case unsupportedReason = "unsupported_reason"
        case upgradeToken = "upgrade_token"
        case requiredHTTP3Settings = "required_http3_settings"
        case requiresQUICDatagrams = "requires_quic_datagrams"
        case requiresResetStreamAt = "requires_reset_stream_at"
        case usesNginx = "uses_nginx"
        case nginxRole = "nginx_role"
        case serverPublicKeyX963Base64 = "server_public_key_x963_base64"
    }

    public init(apiVersion: String, serverTime: String, draft: String, endpoint: String, sessionURL: String, publicHost: String, publicPort: Int, ready: Bool, unsupportedReason: String?, upgradeToken: String, requiredHTTP3Settings: [String: UInt64], requiresQUICDatagrams: Bool, requiresResetStreamAt: Bool, usesNginx: Bool, nginxRole: String, serverPublicKeyX963Base64: String? = nil) {
        self.apiVersion = apiVersion
        self.serverTime = serverTime
        self.draft = draft
        self.endpoint = endpoint
        self.sessionURL = sessionURL
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.ready = ready
        self.unsupportedReason = unsupportedReason
        self.upgradeToken = upgradeToken
        self.requiredHTTP3Settings = requiredHTTP3Settings
        self.requiresQUICDatagrams = requiresQUICDatagrams
        self.requiresResetStreamAt = requiresResetStreamAt
        self.usesNginx = usesNginx
        self.nginxRole = nginxRole
        self.serverPublicKeyX963Base64 = serverPublicKeyX963Base64
    }
}

public struct WebTransportControlRequest: Codable, Equatable, Sendable {
    public let action: String
    public let clientID: String
    public let clientAPIToken: String
    public let afterEventID: String?
    public let limit: Int?
    public let eventID: String?
    public let receivedAt: String?
    public let registration: ClientRegistrationRequest?
    public let statusReport: ClientStatusReport?
    public let inventory: ClientInventoryUpload?
    public let diagnostics: ClientDiagnosticsUpload?
    public let defaultsEvents: ClientDefaultsEventUpload?

    enum CodingKeys: String, CodingKey {
        case action
        case clientID = "client_id"
        case clientAPIToken = "client_api_token"
        case afterEventID = "after_event_id"
        case limit
        case eventID = "event_id"
        case receivedAt = "received_at"
        case registration
        case statusReport = "status_report"
        case inventory
        case diagnostics
        case defaultsEvents = "defaults_events"
    }

    public init(
        action: String,
        clientID: String,
        clientAPIToken: String,
        afterEventID: String? = nil,
        limit: Int? = nil,
        eventID: String? = nil,
        receivedAt: String? = nil,
        registration: ClientRegistrationRequest? = nil,
        statusReport: ClientStatusReport? = nil,
        inventory: ClientInventoryUpload? = nil,
        diagnostics: ClientDiagnosticsUpload? = nil,
        defaultsEvents: ClientDefaultsEventUpload? = nil
    ) {
        self.action = action
        self.clientID = clientID
        self.clientAPIToken = clientAPIToken
        self.afterEventID = afterEventID
        self.limit = limit
        self.eventID = eventID
        self.receivedAt = receivedAt
        self.registration = registration
        self.statusReport = statusReport
        self.inventory = inventory
        self.diagnostics = diagnostics
        self.defaultsEvents = defaultsEvents
    }
}

public struct WebTransportControlResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let error: String?
    public let batch: ControlEventBatch?
    public let ack: ClientWriteAck?
    public let currentRelease: CurrentRelease?
    public let serverTime: String

    enum CodingKeys: String, CodingKey {
        case ok
        case error
        case batch
        case ack
        case currentRelease = "current_release"
        case serverTime = "server_time"
    }

    public init(ok: Bool, error: String? = nil, batch: ControlEventBatch? = nil, ack: ClientWriteAck? = nil, currentRelease: CurrentRelease? = nil, serverTime: String) {
        self.ok = ok
        self.error = error
        self.batch = batch
        self.ack = ack
        self.currentRelease = currentRelease
        self.serverTime = serverTime
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
