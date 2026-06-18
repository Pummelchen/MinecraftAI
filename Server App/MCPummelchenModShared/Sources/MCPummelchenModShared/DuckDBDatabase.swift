import CDuckDB
import Foundation

public struct DuckDBDatabase: Sendable {
    public let databaseURL: URL
    public let readOnly: Bool

    private static let maxAttempts = 5
    private static let processLock = NSLock()

    public init(databaseURL: URL, readOnly: Bool = false) {
        self.databaseURL = databaseURL
        self.readOnly = readOnly
    }

    public func execute(_ sql: String) throws {
        _ = try query(sql, includeHeader: false)
    }

    public func queryCSV(_ sql: String, includeHeader: Bool = true) throws -> String {
        try query(sql, includeHeader: includeHeader)
    }

    public func queryScalar(_ sql: String) throws -> String {
        try queryCSV(sql, includeHeader: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func query(_ sql: String, includeHeader: Bool) throws -> String {
        var lastError = ""
        for attempt in 1...Self.maxAttempts {
            do {
                if readOnly {
                    return try run(sql, includeHeader: includeHeader)
                } else {
                    return try Self.withProcessLock {
                        try run(sql, includeHeader: includeHeader)
                    }
                }
            } catch {
                lastError = String(describing: error)
                guard attempt < Self.maxAttempts, Self.isTransientDuckDBFailure(lastError) else {
                    throw error
                }
                Thread.sleep(forTimeInterval: 0.08 * Double(attempt))
            }
        }
        throw ContractValidationError.invalid("duckdb operation failed: \(lastError)")
    }

    private static func withProcessLock<T>(_ body: () throws -> T) throws -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return try body()
    }

    private func run(_ sql: String, includeHeader: Bool) throws -> String {
        if !readOnly {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        return try withConnection { connection in
            var result = duckdb_result()
            let state = sql.withCString { queryPointer in
                duckdb_query(connection, queryPointer, &result)
            }
            defer { duckdb_destroy_result(&result) }
            guard state == DuckDBSuccess else {
                let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown DuckDB error"
                throw ContractValidationError.invalid("duckdb query failed: \(message)")
            }
            return Self.csvString(result: &result, includeHeader: includeHeader)
        }
    }

    private func withConnection<T>(_ body: (duckdb_connection) throws -> T) throws -> T {
        var config: duckdb_config?
        let configState = duckdb_create_config(&config)
        guard configState == DuckDBSuccess, let openedConfig = config else {
            throw ContractValidationError.invalid("duckdb config creation failed")
        }
        var configToClose: duckdb_config? = openedConfig
        defer { duckdb_destroy_config(&configToClose) }
        if readOnly {
            let setState = "access_mode".withCString { name in
                "READ_ONLY".withCString { value in
                    duckdb_set_config(openedConfig, name, value)
                }
            }
            guard setState == DuckDBSuccess else {
                throw ContractValidationError.invalid("duckdb readonly config failed")
            }
        }

        var database: duckdb_database?
        var errorMessage: UnsafeMutablePointer<CChar>?
        let openState = databaseURL.path.withCString { pathPointer in
            duckdb_open_ext(pathPointer, &database, openedConfig, &errorMessage)
        }
        defer {
            if let errorMessage {
                duckdb_free(errorMessage)
            }
        }
        guard openState == DuckDBSuccess, let openedDatabase = database else {
            let message = errorMessage.map { String(cString: $0) } ?? databaseURL.path
            throw ContractValidationError.invalid("duckdb open failed: \(message)")
        }
        var databaseToClose: duckdb_database? = openedDatabase
        defer { duckdb_close(&databaseToClose) }

        var connection: duckdb_connection?
        let connectState = duckdb_connect(openedDatabase, &connection)
        guard connectState == DuckDBSuccess, let openedConnection = connection else {
            throw ContractValidationError.invalid("duckdb connect failed: \(databaseURL.path)")
        }
        var connectionToClose: duckdb_connection? = openedConnection
        defer { duckdb_disconnect(&connectionToClose) }

        return try body(openedConnection)
    }

    private static func csvString(result: inout duckdb_result, includeHeader: Bool) -> String {
        let columnCount = Int(duckdb_column_count(&result))
        let rowCount = Int(duckdb_row_count(&result))
        guard columnCount > 0 else { return "" }

        var lines: [String] = []
        if includeHeader {
            var headers: [String] = []
            headers.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                let name = duckdb_column_name(&result, UInt64(column)).map { String(cString: $0) } ?? ""
                headers.append(csvField(name))
            }
            lines.append(headers.joined(separator: ","))
        }

        lines.reserveCapacity(lines.count + rowCount)
        for row in 0..<rowCount {
            var fields: [String] = []
            fields.reserveCapacity(columnCount)
            for column in 0..<columnCount {
                if duckdb_value_is_null(&result, UInt64(column), UInt64(row)) {
                    fields.append("")
                    continue
                }
                guard let raw = duckdb_value_varchar(&result, UInt64(column), UInt64(row)) else {
                    fields.append("")
                    continue
                }
                fields.append(csvField(String(cString: raw)))
                duckdb_free(raw)
            }
            lines.append(fields.joined(separator: ","))
        }

        if lines.isEmpty {
            return ""
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private static func isTransientDuckDBFailure(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("lock")
            || lower.contains("conflict")
            || lower.contains("busy")
            || lower.contains("could not set lock")
    }
}
