import Foundation

public enum ContractValidationError: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

public enum ContractValidation {
    private static let sha256Pattern = try! NSRegularExpression(pattern: "^[0-9a-f]{64}$")

    public static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw ContractValidationError.invalid(message)
        }
    }

    public static func requireSHA256(_ value: String, field: String) throws {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = sha256Pattern.firstMatch(in: value, range: range) != nil
        try require(matches, "\(field) must be lowercase 64-character SHA256 hex")
    }
}
