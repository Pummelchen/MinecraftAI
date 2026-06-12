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
              pummelchen-duckdb health --duckdb <file>
              pummelchen-duckdb export-parquet --duckdb <file> --output-dir <dir>
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

func run() throws {
    let args = try Arguments(CommandLine.arguments)
    switch args.command {
    case "phase1-build":
        try phase1Build(args: args)
    case "health":
        try health(args: args)
    case "export-parquet":
        try exportParquet(args: args)
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
