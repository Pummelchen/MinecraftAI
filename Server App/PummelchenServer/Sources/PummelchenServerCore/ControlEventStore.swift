import Foundation
import PummelchenCore

public struct ControlEventStore: Sendable {
    public static let maxControlPayloadBytes = 16 * 1024

    public let databaseURL: URL

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    public func create(_ request: ControlEventCreateRequest) throws -> ControlEvent {
        try initialize()
        try validate(request)
        let event = ControlEvent(
            eventID: UUID().uuidString,
            eventType: request.eventType,
            createdAt: Self.isoNow(),
            targetClientID: request.targetClientID,
            releaseID: request.releaseID,
            priority: request.priority,
            title: request.title,
            message: request.message,
            payload: request.payload
        )
        let payloadJSON = String(decoding: try JSONEncoder().encode(event.payload), as: UTF8.self)
        try execute("""
        INSERT INTO control.control_events(
          event_id, event_type, created_at, target_client_id, release_id,
          priority, title, message, payload_json
        )
        VALUES (
          \(Self.sqlLiteral(event.eventID)),
          \(Self.sqlLiteral(event.eventType.rawValue)),
          TIMESTAMP '\(Self.sqlTimestamp(event.createdAt))',
          \(Self.sqlLiteral(event.targetClientID)),
          \(Self.sqlLiteral(event.releaseID)),
          \(Self.sqlLiteral(event.priority)),
          \(Self.sqlLiteral(event.title)),
          \(Self.sqlLiteral(event.message)),
          \(Self.sqlLiteral(payloadJSON))
        );
        """)
        return event
    }

    public func pendingEvents(clientID: String, afterEventID: String?, limit: Int = 50) throws -> [ControlEvent] {
        try initialize()
        try validateClientID(clientID)
        let boundedLimit = min(max(limit, 1), 200)
        let afterClause: String
        if let afterEventID, !afterEventID.isEmpty {
            afterClause = """
            AND event_id != \(Self.sqlLiteral(afterEventID))
            AND created_at >= COALESCE((SELECT created_at FROM control.control_events WHERE event_id = \(Self.sqlLiteral(afterEventID))), TIMESTAMP '1970-01-01 00:00:00')
            """
        } else {
            afterClause = ""
        }
        let csv = try queryCSV("""
        SELECT event_id, event_type, created_at, COALESCE(target_client_id, ''), COALESCE(release_id, ''),
               priority, title, message, payload_json
        FROM control.control_events
        WHERE (target_client_id IS NULL OR target_client_id = \(Self.sqlLiteral(clientID)))
          \(afterClause)
          AND event_id NOT IN (
            SELECT event_id FROM control.control_acks WHERE client_id = \(Self.sqlLiteral(clientID))
          )
        ORDER BY created_at ASC
        LIMIT \(boundedLimit);
        """)
        return try parseEvents(csv)
    }

    public func acknowledge(_ ack: ControlEventAck) throws {
        try initialize()
        try validateClientID(ack.clientID)
        try execute("""
        INSERT INTO control.control_acks(client_id, event_id, received_at)
        VALUES (
          \(Self.sqlLiteral(ack.clientID)),
          \(Self.sqlLiteral(ack.eventID)),
          TIMESTAMP '\(Self.sqlTimestamp(ack.receivedAt))'
        )
        ON CONFLICT(client_id, event_id) DO UPDATE SET received_at = excluded.received_at;
        """)
    }

    public func initialize() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("""
        CREATE SCHEMA IF NOT EXISTS control;
        CREATE TABLE IF NOT EXISTS control.control_events (
          event_id VARCHAR PRIMARY KEY,
          event_type VARCHAR NOT NULL,
          created_at TIMESTAMP NOT NULL,
          target_client_id VARCHAR,
          release_id VARCHAR,
          priority VARCHAR NOT NULL,
          title VARCHAR NOT NULL,
          message VARCHAR NOT NULL,
          payload_json VARCHAR NOT NULL
        );
        CREATE TABLE IF NOT EXISTS control.control_acks (
          client_id VARCHAR NOT NULL,
          event_id VARCHAR NOT NULL,
          received_at TIMESTAMP NOT NULL,
          PRIMARY KEY(client_id, event_id)
        );
        """)
    }

    private func validate(_ request: ControlEventCreateRequest) throws {
        if let target = request.targetClientID {
            try validateClientID(target)
        }
        try ContractValidation.require(["low", "normal", "high", "critical"].contains(request.priority), "invalid control event priority")
        try ContractValidation.require(!request.title.isEmpty && request.title.count <= 120, "control event title must be 1-120 characters")
        try ContractValidation.require(!request.message.isEmpty && request.message.count <= 2_000, "control event message must be 1-2000 characters")
        let payloadData = try JSONEncoder().encode(request.payload)
        try ContractValidation.require(payloadData.count <= Self.maxControlPayloadBytes, "control event payload exceeds \(Self.maxControlPayloadBytes) bytes")
        let forbiddenKeys = ["download", "download_url", "client_zip_url", "mrpack_url", "dmg_url", "file_url"]
        for key in request.payload.keys.map({ $0.lowercased() }) {
            try ContractValidation.require(!forbiddenKeys.contains(key), "control events must not carry download URLs")
        }
        for value in request.payload.values {
            let lower = value.lowercased()
            try ContractValidation.require(!lower.contains("/downloads/") && !lower.contains(".jar") && !lower.contains(".zip") && !lower.contains(".dmg"), "control events must not carry downloadable file references")
        }
    }

    private func validateClientID(_ clientID: String) throws {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        try ContractValidation.require(trimmed.count >= 8 && trimmed.count <= 128, "client_id must be 8-128 characters")
    }

    private func parseEvents(_ csv: String) throws -> [ControlEvent] {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
        return try lines.compactMap { line in
            guard !line.isEmpty else { return nil }
            let columns = parseCSVLine(String(line))
            guard columns.count >= 9, let eventType = ControlEventType(rawValue: columns[1]) else {
                throw ContractValidationError.invalid("invalid control event row: \(line)")
            }
            let payloadData = Data(columns[8].utf8)
            let payload = (try? JSONDecoder().decode([String: String].self, from: payloadData)) ?? [:]
            return ControlEvent(
                eventID: columns[0],
                eventType: eventType,
                createdAt: Self.isoFromDuck(columns[2]),
                targetClientID: columns[3].isEmpty ? nil : columns[3],
                releaseID: columns[4].isEmpty ? nil : columns[4],
                priority: columns[5],
                title: columns[6],
                message: columns[7],
                payload: payload
            )
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var iterator = line.makeIterator()
        while let character = iterator.next() {
            if character == "\"" {
                if quoted, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        quoted = false
                        if next == "," {
                            result.append(current)
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    quoted.toggle()
                }
            } else if character == ",", !quoted {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    private func execute(_ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.duckDBExecutablePath())
        process.arguments = [databaseURL.path, "-c", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("duckdb control write failed: \(output)")
        }
    }

    private func queryCSV(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try Self.duckDBExecutablePath())
        process.arguments = [databaseURL.path, "-csv", "-c", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("duckdb control query failed: \(output)")
        }
        return output
    }

    private static func duckDBExecutablePath() throws -> String {
        let candidates = ["/opt/homebrew/bin/duckdb", "/usr/local/bin/duckdb", "/usr/bin/duckdb", "/bin/duckdb"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw ContractValidationError.invalid("duckdb executable not found; install DuckDB or bundle it with the server")
    }

    private static func sqlLiteral(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "NULL" }
        return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqlTimestamp(_ value: String) -> String {
        let parsed = ISO8601DateFormatter().date(from: value) ?? Date()
        return duckTimestamp(parsed)
    }

    private static func duckTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func isoFromDuck(_ value: String) -> String {
        if value.contains("T") {
            return value
        }
        return value.replacingOccurrences(of: " ", with: "T") + "Z"
    }
}
