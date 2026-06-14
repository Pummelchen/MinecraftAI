import Foundation

public final class WebTransportRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeValue = false
    private var lastErrorValue: String?

    public init() {}

    public var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeValue
    }

    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return lastErrorValue
    }

    public func markActive() {
        lock.lock()
        activeValue = true
        lastErrorValue = nil
        lock.unlock()
    }

    public func markFailed(_ error: Error) {
        lock.lock()
        activeValue = false
        lastErrorValue = String(describing: error)
        lock.unlock()
    }

    public func markStopped() {
        lock.lock()
        activeValue = false
        lock.unlock()
    }
}
