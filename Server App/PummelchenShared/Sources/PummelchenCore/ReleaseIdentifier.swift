import Foundation

public struct ReleaseIdentifier: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let date: String
    public let version: Int
    public let suffix: String?

    public var description: String {
        rawValue
    }

    public init(_ rawValue: String) throws {
        let pattern = #"^release_([0-9]{8})_V([0-9]+)([A-Za-z0-9_.-]*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(rawValue.startIndex..<rawValue.endIndex, in: rawValue)
        guard let match = regex.firstMatch(in: rawValue, range: range), match.numberOfRanges == 4 else {
            throw ContractValidationError.invalid("release_id has invalid format: \(rawValue)")
        }

        func capture(_ index: Int) -> String {
            let nsRange = match.range(at: index)
            guard let stringRange = Range(nsRange, in: rawValue) else {
                return ""
            }
            return String(rawValue[stringRange])
        }

        let date = capture(1)
        let versionText = capture(2)
        guard let version = Int(versionText) else {
            throw ContractValidationError.invalid("release_id version is invalid: \(rawValue)")
        }

        let suffixValue = capture(3)
        self.rawValue = rawValue
        self.date = date
        self.version = version
        self.suffix = suffixValue.isEmpty ? nil : suffixValue
    }
}
