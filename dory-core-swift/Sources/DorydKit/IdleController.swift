import Foundation

public struct IdleSnapshot: Sendable, Equatable {
    public var activeRequests: Int
    public var controlOperations: Int
    public var lastActivity: Date
    public var sleeping: Bool
}

public final class IdleController: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRequests = 0
    private var controlOperations = 0
    private var lastActivity: Date
    private var sleeping = false

    public init(now: Date = Date()) {
        self.lastActivity = now
    }

    public var snapshot: IdleSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return IdleSnapshot(
            activeRequests: activeRequests,
            controlOperations: controlOperations,
            lastActivity: lastActivity,
            sleeping: sleeping
        )
    }

    @discardableResult
    public func beginRequest(path: String, now: Date = Date()) -> Bool {
        guard path != "/_ping" else { return false }
        lock.lock()
        activeRequests += 1
        lastActivity = now
        let shouldWake = sleeping
        lock.unlock()
        return shouldWake
    }

    public func endRequest(now: Date = Date()) {
        lock.lock()
        if activeRequests > 0 {
            activeRequests -= 1
        }
        lastActivity = now
        lock.unlock()
    }

    public func touch(now: Date = Date()) {
        lock.lock()
        lastActivity = now
        lock.unlock()
    }

    public func beginControlOperation(now: Date = Date()) {
        lock.lock()
        controlOperations += 1
        lastActivity = now
        lock.unlock()
    }

    public func endControlOperation(now: Date = Date()) {
        lock.lock()
        if controlOperations > 0 {
            controlOperations -= 1
        }
        lastActivity = now
        lock.unlock()
    }

    public func setSleeping(_ value: Bool) {
        lock.lock()
        sleeping = value
        lock.unlock()
    }

    /// Claim sleep when idle. The lock is held across the whole check-and-set, so the
    /// counts cannot change between the guard and setting `sleeping`.
    public func claimSleepIfIdle(idleAfter seconds: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sleeping,
              activeRequests == 0,
              controlOperations == 0,
              now.timeIntervalSince(lastActivity) >= seconds else {
            return false
        }
        sleeping = true
        return true
    }

    /// Claim sleep for an engine that has independently proven it has no active containers.
    /// This prevents a stale dataplane request count from keeping an empty VM alive forever.
    public func claimSleepForEmptyEngine(idleAfter seconds: TimeInterval, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !sleeping,
              controlOperations == 0,
              now.timeIntervalSince(lastActivity) >= seconds else {
            return false
        }
        sleeping = true
        return true
    }
}
