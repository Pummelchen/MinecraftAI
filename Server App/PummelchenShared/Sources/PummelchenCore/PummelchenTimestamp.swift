import Foundation

public enum PummelchenTimestamp {
    public static func displayUTC(fromISO8601 value: String) throws -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        let date = formatter.date(from: value) ?? fallbackFormatter.date(from: value)
        guard let date else {
            throw ContractValidationError.invalid("invalid ISO-8601 timestamp: \(value)")
        }

        let displayFormatter = DateFormatter()
        displayFormatter.calendar = Calendar(identifier: .gregorian)
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        displayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        displayFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return displayFormatter.string(from: date)
    }
}
