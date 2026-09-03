import Foundation

/// Pure refresh policy for plan-limit fetches. Limits only move when a turn
/// finishes, so the driver is the Stop hook rather than a clock:
///
/// - Stop events are coalesced: wait `debounce` after the *last* Stop, so a
///   burst of sessions finishing together costs one request.
/// - Never more often than `throttle`; a Stop inside the window is remembered
///   and served once the window ends (trailing fetch).
/// - With the collapsed chip visible and no Stops, a slow `idleFloor` tick
///   catches window resets.
/// - Failures back off exponentially; a rejected token stops background
///   fetches entirely until the user expands the panel again.
///
/// The owner turns `nextFireTime` into one scheduled task; nothing here touches
/// timers, so it is fully testable.
public struct ClaudeQuotaScheduler: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var debounce: TimeInterval = 15
        public var throttle: TimeInterval = 60
        public var idleFloor: TimeInterval = 600
        public var expandStale: TimeInterval = 60
        public var backoffBase: TimeInterval = 60
        public var backoffMax: TimeInterval = 900
        public init() {}
    }

    public var config = Config()
    public private(set) var lastFetchAt: Date?
    public private(set) var lastStopAt: Date?
    /// A Stop arrived after the last fetch started and hasn't been served.
    public private(set) var pending = false
    public private(set) var failures = 0
    public private(set) var needsLogin = false

    public init(config: Config = Config()) { self.config = config }

    public mutating func recordStop(now: Date) {
        lastStopAt = now
        pending = true
    }

    public mutating func recordFetchStart(now: Date) {
        lastFetchAt = now
        pending = false
    }

    public mutating func recordSuccess() {
        failures = 0
        needsLogin = false
    }

    /// `unauthorized` covers both a rejected token and a missing credential.
    public mutating func recordFailure(unauthorized: Bool) {
        if unauthorized {
            needsLogin = true
            failures = 0
        } else {
            failures += 1
        }
    }

    /// Current backoff window, nil when the last fetch succeeded.
    public var backoff: TimeInterval? {
        guard failures > 0 else { return nil }
        let exp = min(Double(failures - 1), 10)
        return min(config.backoffBase * pow(2, exp), config.backoffMax)
    }

    /// Earliest time a background fetch may run. `wantsLive` is true while
    /// anything on screen shows the numbers (collapsed chip, or expanded
    /// footer). nil means nothing to schedule.
    public func nextFireTime(wantsLive: Bool, now: Date) -> Date? {
        guard wantsLive, !needsLogin else { return nil }
        var candidate: Date
        if pending, let lastStopAt {
            candidate = lastStopAt.addingTimeInterval(config.debounce)
            if let lastFetchAt {
                candidate = max(candidate, lastFetchAt.addingTimeInterval(config.throttle))
            }
        } else if let lastFetchAt {
            candidate = lastFetchAt.addingTimeInterval(config.idleFloor)
        } else {
            candidate = now
        }
        if let lastFetchAt, let backoff {
            candidate = max(candidate, lastFetchAt.addingTimeInterval(backoff))
        }
        return candidate
    }

    /// Panel expansion is user-initiated: refresh if stale, and let it retry a
    /// rejected token (the user may have signed in again) once the stale
    /// window has passed. Still honours error backoff.
    public func shouldFetchOnExpand(now: Date) -> Bool {
        guard let lastFetchAt else { return true }
        let age = now.timeIntervalSince(lastFetchAt)
        if let backoff { return age >= backoff }
        return age >= config.expandStale
    }
}
