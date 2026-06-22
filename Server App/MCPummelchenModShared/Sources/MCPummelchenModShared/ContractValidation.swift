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
    public static func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw ContractValidationError.invalid(message)
        }
    }

    public static func requireSHA256(_ value: String, field: String) throws {
        let matches = value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        try require(matches, "\(field) must be lowercase 64-character SHA256 hex")
    }

    public static func requireClientID(_ value: String, field: String = "client_id") throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.range(of: "^[A-Za-z0-9._:@-]{8,128}$", options: .regularExpression) != nil
        try require(matches, "\(field) must be 8-128 characters and contain only letters, numbers, dot, underscore, colon, at, or dash")
    }
}

public enum BoolValue {
    public static func parse(_ value: String?, default defaultValue: Bool = false) -> Bool {
        guard let value else { return defaultValue }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["1", "true", "yes", "y", "on"].contains(trimmed) { return true }
        if ["0", "false", "no", "n", "off"].contains(trimmed) { return false }
        return defaultValue
    }
}
