import Foundation

public enum SHA256Hasher {
    public static func hashFile(at url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        #if os(macOS)
        process.arguments = ["shasum", "-a", "256", url.path]
        #else
        process.arguments = ["sha256sum", url.path]
        #endif

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ContractValidationError.invalid("sha256 command failed for \(url.path): \(output)")
        }
        guard let hash = output.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first else {
            throw ContractValidationError.invalid("could not parse sha256 for \(url.path)")
        }
        let value = String(hash)
        try ContractValidation.requireSHA256(value, field: "sha256")
        return value
    }
}
