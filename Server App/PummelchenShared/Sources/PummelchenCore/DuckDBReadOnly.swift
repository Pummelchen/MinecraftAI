import Foundation

public struct DuckDBReportingClient: Sendable {
    public let databasePath: String

    public init(databasePath: String) {
        self.databasePath = databasePath
    }

    public func countRows(inReportingView viewName: String) throws -> Int {
        try ContractValidation.require(
            viewName.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
            "invalid reporting view name: \(viewName)"
        )
        let output = try queryCSV("SELECT COUNT(*) FROM reporting.\"\(viewName)\";")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(output) else {
            throw ContractValidationError.invalid("could not parse DuckDB count for \(viewName): \(output)")
        }
        return value
    }

    public func queryCSV(_ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["duckdb", "-readonly", databasePath, "-csv", "-noheader", "-c", sql]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("duckdb readonly query failed: \(output)")
        }
        return output
    }
}
