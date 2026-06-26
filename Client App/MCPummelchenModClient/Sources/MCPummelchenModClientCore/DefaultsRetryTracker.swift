import Foundation

/// Tracks repair backoff for client defaults rows so we retry periodically
/// instead of attempting repair on every single check cycle.
///
/// The counter tracks *cycles since last attempt*, not consecutive failures.
/// This avoids a deadlock where a failed row is skipped by backoff but the
/// counter can never advance because no attempt is made to increment it.
public actor DefaultsRetryTracker {
    private var cyclesSinceAttempt: [String: Int] = [:]
    public let cooldownChecks: Int

    public init(cooldownChecks: Int = 3) {
        self.cooldownChecks = max(1, cooldownChecks)
    }

    /// Returns `true` if the row should be retried this check cycle.
    /// A row that has never been attempted (or was last repaired successfully)
    /// is always retried. A row that failed its last attempt is retried after
    /// `cooldownChecks` skipped cycles have been recorded.
    public func shouldRetry(rowID: String) -> Bool {
        guard let count = cyclesSinceAttempt[rowID] else {
            return true
        }
        return count >= cooldownChecks
    }

    public func recordSuccess(rowID: String) {
        cyclesSinceAttempt.removeValue(forKey: rowID)
    }

    /// Records that a repair attempt was made and failed. Resets the cycle
    /// counter so the row is skipped for `cooldownChecks` cycles before
    /// being retried.
    public func recordFailure(rowID: String) {
        cyclesSinceAttempt[rowID] = 0
    }

    /// Records that a check cycle passed without a repair attempt for this row
    /// (because `shouldRetry` returned false). Advances the cycle counter so
    /// the row eventually becomes eligible for retry again.
    public func recordSkippedCycle(rowID: String) {
        cyclesSinceAttempt[rowID, default: 0] += 1
    }
}