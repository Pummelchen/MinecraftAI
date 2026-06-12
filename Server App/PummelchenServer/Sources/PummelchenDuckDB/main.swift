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
              pummelchen-duckdb phase1-build --duckdb <file> --sqlite <file> --project-root <repo>
              pummelchen-duckdb phase1-check --duckdb <file> --sqlite <file> [--current-release-json <file>] [--tested-updates-json <file>]
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

func readSQL(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

func applyMigration(duckdb: DuckDB, path: String, version: Int, name: String) throws {
    let checksum = try Hashing.sha256(path: path)
    let sql = try readSQL(path)
    try duckdb.execute(sql)
    try duckdb.execute(
        """
        DELETE FROM core.schema_migrations WHERE version = \(version);
        INSERT INTO core.schema_migrations(version, name, applied_at, checksum)
        VALUES (\(version), \(sqlString(name)), now(), \(sqlString(checksum)));
        """
    )
}

func importSQLiteTables(duckdb: DuckDB, sqlitePath: String) throws -> Int {
    let attachSQL = "INSTALL sqlite; LOAD sqlite; ATTACH \(sqlString(sqlitePath)) AS sqlite_source (TYPE sqlite);"
    let tableOutput = try duckdb.queryCSV("\(attachSQL) SHOW TABLES FROM sqlite_source;")
    let tables = tableOutput
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("v_") }

    for table in tables {
        let identifier = quotedIdentifier(table)
        try duckdb.execute(
            """
            \(attachSQL)
            DROP TABLE IF EXISTS raw.\(identifier);
            CREATE TABLE raw.\(identifier) AS SELECT * FROM sqlite_source.\(identifier);
            """
        )
    }

    return tables.count
}

func normalize(duckdb: DuckDB, projectRoot: String) throws {
    let path = URL(fileURLWithPath: projectRoot)
        .appendingPathComponent("database/duckdb/normalize_from_raw.sql")
        .path
    try duckdb.execute(try readSQL(path))
}

func firstCSVValue(_ output: String) -> String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func requireCheck(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw CheckFailure(message: message)
    }
}

func requireCountMatch(duckdb: DuckDB, sqlitePath: String, table: String, coreExpression: String? = nil) throws {
    let tableIdentifier = quotedIdentifier(table)
    let sqliteCount = firstCSVValue(
        try duckdb.queryCSV(
            """
            INSTALL sqlite;
            LOAD sqlite;
            ATTACH \(sqlString(sqlitePath)) AS sqlite_source (TYPE sqlite);
            SELECT COUNT(*) FROM sqlite_source.\(tableIdentifier);
            """
        )
    )
    let duckdbExpression = coreExpression ?? "core.\(tableIdentifier)"
    let duckdbCount = firstCSVValue(try duckdb.queryCSV("SELECT COUNT(*) FROM \(duckdbExpression);"))
    try requireCheck(
        sqliteCount == duckdbCount,
        "row count mismatch for \(table): sqlite=\(sqliteCount) duckdb=\(duckdbCount)"
    )
    print("parity_count table=\(table) rows=\(duckdbCount)")
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

    print("parity_reporting_fields=ok")
}

func requireCurrentReleaseParity(duckdb: DuckDB, path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    let jsonReleaseID = object?["release_id"] as? String
    let duckdbReleaseID = firstCSVValue(
        try duckdb.queryCSV(
            """
            SELECT release_id
            FROM core.pack_releases
            WHERE active = true
            ORDER BY activated_at DESC
            LIMIT 1;
            """
        )
    )
    try requireCheck(
        jsonReleaseID == duckdbReleaseID,
        "current-release mismatch: json=\(jsonReleaseID ?? "nil") duckdb=\(duckdbReleaseID)"
    )
    print("parity_current_release=ok release_id=\(duckdbReleaseID)")
}

func requireTestedUpdatesParity(duckdb: DuckDB, path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let totalEntries = object?["total_entries"] as? Int else {
        throw CheckFailure(message: "tested-updates JSON has no total_entries value")
    }
    let viewCount = firstCSVValue(try duckdb.queryCSV("SELECT COUNT(*) FROM reporting.v_tested_updates_table;"))
    try requireCheck(
        String(totalEntries) == viewCount,
        "tested updates count mismatch: json_total_entries=\(totalEntries) duckdb=\(viewCount)"
    )
    print("parity_tested_updates=ok rows=\(viewCount)")
}

func phase1Build(args: Arguments) throws {
    let duckdb = DuckDB(databasePath: try args.require("--duckdb"))
    let sqlitePath = try args.require("--sqlite")
    let projectRoot = try args.require("--project-root")
    let migration = URL(fileURLWithPath: projectRoot)
        .appendingPathComponent("database/duckdb/migrations/001_foundation.sql")
        .path

    try applyMigration(duckdb: duckdb, path: migration, version: 1, name: "phase1_foundation")
    let imported = try importSQLiteTables(duckdb: duckdb, sqlitePath: sqlitePath)
    try normalize(duckdb: duckdb, projectRoot: projectRoot)
    print("phase1_build=ok raw_tables=\(imported)")
}

func phase1Check(args: Arguments) throws {
    let duckdb = DuckDB(databasePath: try args.require("--duckdb"))
    let sqlitePath = try args.require("--sqlite")

    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "pack_releases")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "release_artifacts")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "release_events")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "mods")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "mod_files")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "mod_server_files")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "test_runs")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "mod_acceptance_blocks")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "mod_acceptance_releases")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "headless_client_runs")
    try requireCountMatch(duckdb: duckdb, sqlitePath: sqlitePath, table: "client_update_status")

    try requireReportingFields(duckdb: duckdb)

    if let currentReleaseJSON = args.options["--current-release-json"] {
        try requireCurrentReleaseParity(duckdb: duckdb, path: currentReleaseJSON)
    }
    if let testedUpdatesJSON = args.options["--tested-updates-json"] {
        try requireTestedUpdatesParity(duckdb: duckdb, path: testedUpdatesJSON)
    }

    print("phase1_check=ok")
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
    let sqliteExtension = firstCSVValue(
        try duckdb.queryCSV(
            """
            INSTALL sqlite;
            LOAD sqlite;
            SELECT installed || ',' || loaded
            FROM duckdb_extensions()
            WHERE extension_name = 'sqlite_scanner';
            """
        )
    )
    print("duckdb_extension sqlite_scanner=\(sqliteExtension)")

    let schemaCounts = firstCSVValue(
        try duckdb.queryCSV(
            """
            SELECT string_agg(table_schema || '=' || CAST(table_count AS VARCHAR), ';' ORDER BY table_schema)
            FROM (
                SELECT table_schema, COUNT(*) AS table_count
                FROM information_schema.tables
                WHERE table_schema IN ('raw', 'core', 'audit', 'reporting', 'archive')
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
    case "phase1-build":
        try phase1Build(args: args)
    case "phase1-check":
        try phase1Check(args: args)
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
