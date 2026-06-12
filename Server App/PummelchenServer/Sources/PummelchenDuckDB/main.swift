import Foundation

enum DuckDBCommandError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case commandFailed(String, Int32, String)
    case invalidOutput(String)

    var description: String {
        switch self {
        case .usage:
            return """
            Usage:
              pummelchen-duckdb health --duckdb <file>
              pummelchen-duckdb export-parquet --duckdb <file> --output-dir <dir>
              pummelchen-duckdb verify-parquet --duckdb <file> --input-dir <dir>
            """
        case .missingValue(let option):
            return "missing value for \(option)"
        case .commandFailed(let command, let status, let output):
            return "command failed (\(status)): \(command)\n\(output)"
        case .invalidOutput(let message):
            return message
        }
    }
}

struct Arguments {
    let command: String
    let options: [String: String]

    init(_ raw: [String]) throws {
        guard raw.count >= 2 else {
            throw DuckDBCommandError.usage
        }
        command = raw[1]
        var parsed: [String: String] = [:]
        var index = 2
        while index < raw.count {
            let option = raw[index]
            guard option.hasPrefix("--") else {
                throw DuckDBCommandError.usage
            }
            let valueIndex = index + 1
            guard valueIndex < raw.count else {
                throw DuckDBCommandError.missingValue(option)
            }
            parsed[option] = raw[valueIndex]
            index += 2
        }
        options = parsed
    }

    func require(_ name: String) throws -> String {
        guard let value = options[name], !value.isEmpty else {
            throw DuckDBCommandError.missingValue(name)
        }
        return value
    }
}

struct ProcessResult {
    let status: Int32
    let output: String
}

enum CommandRunner {
    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        return ProcessResult(status: process.terminationStatus, output: output)
    }

    static func require(_ executable: String, _ arguments: [String]) throws -> String {
        let result = try run(executable, arguments)
        if result.status != 0 {
            throw DuckDBCommandError.commandFailed(([executable] + arguments).joined(separator: " "), result.status, result.output)
        }
        return result.output
    }
}

enum Hashing {
    static func sha256(path: String) throws -> String {
        let shasum = try? CommandRunner.run("/usr/bin/shasum", ["-a", "256", path])
        if let shasum, shasum.status == 0 {
            return try parseHash(shasum.output, path: path)
        }
        let sha256sum = try CommandRunner.require("/usr/bin/sha256sum", [path])
        return try parseHash(sha256sum, path: path)
    }

    private static func parseHash(_ output: String, path: String) throws -> String {
        guard let first = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
            throw DuckDBCommandError.invalidOutput("could not parse sha256 for \(path)")
        }
        return String(first)
    }
}

struct DuckDB {
    let databasePath: String

    func execute(_ sql: String) throws {
        _ = try CommandRunner.require("/usr/bin/env", ["duckdb", databasePath, "-c", sql])
    }

    func queryCSV(_ sql: String) throws -> String {
        try CommandRunner.require("/usr/bin/env", ["duckdb", databasePath, "-csv", "-noheader", "-c", sql])
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

func sqlString(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

func quotedIdentifier(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

func firstCSVValue(_ output: String) -> String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func requireCheck(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw CheckFailure(message: message)
    }
}

func requireReportingFields(duckdb: DuckDB) throws {
    let failedMissing = firstCSVValue(
        try duckdb.queryCSV(
            """
            SELECT COUNT(*)
            FROM reporting.v_failed_mods_table
            WHERE failed_at IS NULL OR title IS NULL OR failure_reason IS NULL OR details IS NULL;
            """
        )
    )
    try requireCheck(failedMissing == "0", "failed mods reporting view has rows missing required timestamp/title/reason/details")

    let testedMissing = firstCSVValue(
        try duckdb.queryCSV(
            """
            SELECT COUNT(*)
            FROM reporting.v_tested_updates_table
            WHERE tested_at IS NULL OR title IS NULL OR event_type IS NULL OR status IS NULL;
            """
        )
    )
    try requireCheck(testedMissing == "0", "tested updates reporting view has rows missing required timestamp/title/type/status")
}

func health(args: Arguments) throws {
    let duckdb = DuckDB(databasePath: try args.require("--duckdb"))
    let output = try duckdb.queryCSV("SELECT * FROM reporting.v_duckdb_health;")
    let values = output
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .split(separator: ",", omittingEmptySubsequences: false)
        .map(String.init)
    if values.count == 5 {
        print(
            "duckdb_health migration_count=\(values[0]) schema_version=\(values[1]) release_count=\(values[2]) mod_count=\(values[3]) client_status_count=\(values[4])"
        )
    } else {
        print(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    try requireReportingFields(duckdb: duckdb)
    print("duckdb_reporting_fields=ok")

    let schemaCounts = firstCSVValue(
        try duckdb.queryCSV(
            """
            SELECT string_agg(table_schema || '=' || CAST(table_count AS VARCHAR), ';' ORDER BY table_schema)
            FROM (
                SELECT table_schema, COUNT(*) AS table_count
                FROM information_schema.tables
                WHERE table_schema IN ('core', 'audit', 'reporting', 'archive')
                GROUP BY table_schema
            );
            """
        )
    )
    print("duckdb_table_counts \(schemaCounts)")

    let databaseSize = firstCSVValue(try duckdb.queryCSV("PRAGMA database_size;"))
    if !databaseSize.isEmpty {
        print("duckdb_database_size \(databaseSize)")
    }

    let settings = firstCSVValue(
        try duckdb.queryCSV(
            """
            SELECT string_agg(name || '=' || value, ';' ORDER BY name)
            FROM duckdb_settings()
            WHERE name IN ('memory_limit', 'temp_directory', 'threads', 'max_temp_directory_size');
            """
        )
    )
    print("duckdb_settings \(settings)")
}

func exportParquet(args: Arguments) throws {
    let duckdb = DuckDB(databasePath: try args.require("--duckdb"))
    let outputDir = try args.require("--output-dir")
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true, attributes: nil)

    let views = [
        "v_tested_updates_table",
        "v_failed_mods_table",
        "v_release_health_latest",
        "v_client_sync_status",
        "v_custom_datapack_status",
        "v_world_reset_history"
    ]

    for view in views {
        let output = URL(fileURLWithPath: outputDir).appendingPathComponent("\(view).parquet").path
        try duckdb.execute(
            """
            COPY (SELECT * FROM reporting.\(quotedIdentifier(view)))
            TO \(sqlString(output)) (FORMAT parquet);
            """
        )
        let rowCount = try duckdb.queryCSV("SELECT COUNT(*) FROM reporting.\(quotedIdentifier(view));")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let checksum = try Hashing.sha256(path: output)
        let exportID = "\(view)_\(ISO8601DateFormatter().string(from: Date()))"
        try duckdb.execute(
            """
            INSERT INTO audit.parquet_exports(export_id, exported_at, source_name, output_path, row_count, sha256)
            VALUES (
                \(sqlString(exportID)),
                now(),
                \(sqlString("reporting.\(view)")),
                \(sqlString(output)),
                \(rowCount),
                \(sqlString(checksum))
            );
            """
        )
        print("parquet_export=\(view) path=\(output)")
    }
}

func verifyParquet(args: Arguments) throws {
    let duckdb = DuckDB(databasePath: try args.require("--duckdb"))
    let inputDir = try args.require("--input-dir")
    let views = [
        "v_tested_updates_table",
        "v_failed_mods_table",
        "v_release_health_latest",
        "v_client_sync_status",
        "v_custom_datapack_status",
        "v_world_reset_history"
    ]

    for view in views {
        let input = URL(fileURLWithPath: inputDir).appendingPathComponent("\(view).parquet").path
        try requireCheck(FileManager.default.fileExists(atPath: input), "missing Parquet export: \(input)")
        let parquetRows = firstCSVValue(
            try duckdb.queryCSV("SELECT COUNT(*) FROM read_parquet(\(sqlString(input)));")
        )
        let auditRows = firstCSVValue(
            try duckdb.queryCSV(
                """
                SELECT COALESCE(CAST(row_count AS VARCHAR), '')
                FROM audit.parquet_exports
                WHERE source_name = \(sqlString("reporting.\(view)"))
                  AND output_path = \(sqlString(input))
                ORDER BY exported_at DESC
                LIMIT 1;
                """
            )
        )
        if !auditRows.isEmpty {
            try requireCheck(
                parquetRows == auditRows,
                "Parquet row count mismatch for \(view): parquet=\(parquetRows) audit=\(auditRows)"
            )
        }
        print("parquet_verify=\(view) rows=\(parquetRows)")
    }
    print("parquet_verify=ok")
}

func run() throws {
    let args = try Arguments(CommandLine.arguments)
    switch args.command {
    case "health":
        try health(args: args)
    case "export-parquet":
        try exportParquet(args: args)
    case "verify-parquet":
        try verifyParquet(args: args)
    default:
        throw DuckDBCommandError.usage
    }
}

do {
    try run()
} catch {
    if let data = "ERROR: \(error)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(1)
}
