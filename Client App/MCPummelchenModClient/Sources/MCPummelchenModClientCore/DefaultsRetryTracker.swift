import Foundation

/// Tracks consecutive repair failures for client defaults rows so we can
/// back off instead of retrying every single check cycle.
public actor DefaultsRetryTracker {
    private var consecutiveFailures: [String: Int] = [:]
    public let cooldownChecks: Int

    public init(cooldownChecks: Int = 3) {
        self.cooldownChecks = max(1, cooldownChecks)
    }

    /// Returns `true` if the row should be retried this check cycle.
    /// A row with zero failures is always retried. A row with N consecutive
    /// failures is retried every `cooldownChecks` cycles.
    public func shouldRetry(rowID: String) -> Bool {
        let count = consecutiveFailures[rowID] ?? 0
        return count == 0 || count.isMultiple(of: cooldownChecks)
    }

    public func recordSuccess(rowID: String) {
        consecutiveFailures.removeValue(forKey: rowID)
    }

    public func recordFailure(rowID: String) {
        consecutiveFailures[rowID, default: 0] += 1
    }
}
