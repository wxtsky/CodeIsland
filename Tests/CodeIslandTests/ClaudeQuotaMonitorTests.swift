import XCTest
import CodeIslandCore
@testable import CodeIsland

/// Uses a private defaults suite: flipping the real `showClaudeQuota` would
/// wake every other test's AppState-owned monitor into a real keychain read,
/// which blocks on the macOS access prompt and hangs the run.
@MainActor
final class ClaudeQuotaMonitorTests: XCTestCase {
    private let suiteName = "ClaudeQuotaMonitorTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: SettingsKey.showClaudeQuota)
        // Footer-only by default, so the Stop / expand tests see main's
        // behaviour; the chip tests switch it on themselves.
        defaults.set(ClaudeQuotaChipMode.off.rawValue, forKey: SettingsKey.claudeQuotaChip)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static let snapshot = ClaudeQuotaSnapshot(limits: [
        ClaudeQuotaLimit(kind: .session, percent: 3, resetsAt: Date().addingTimeInterval(3600)),
        ClaudeQuotaLimit(kind: .weeklyScoped, percent: 48, scopeLabel: "Fable"),
    ], fetchedAt: Date())

    /// Counts fetches; safe to touch from the detached fetch task.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func fastConfig() -> ClaudeQuotaScheduler.Config {
        var c = ClaudeQuotaScheduler.Config()
        c.debounce = 0.05
        c.throttle = 0.2
        c.idleFloor = 100
        return c
    }

    private func waitUntil(_ cond: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testExpandFetchesAndPublishesSnapshot() async {
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump(); return Self.snapshot
        })
        m.noteExpanded()
        await waitUntil { m.snapshot != nil }
        XCTAssertEqual(m.snapshot, Self.snapshot)
        XCTAssertNil(m.lastError)
        // Second expand inside the stale window does not refetch.
        m.noteCollapsed(); m.noteExpanded()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter.value, 1)
    }

    func testDisabledSettingNeverFetches() async {
        defaults.set(false, forKey: SettingsKey.showClaudeQuota)
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump(); return Self.snapshot
        })
        m.noteExpanded(); m.noteStop()
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(m.snapshot)
    }

    func testBurstOfStopsCoalescesIntoOneFetch() async {
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump(); return Self.snapshot
        })
        m.noteExpanded()                       // first fetch (stale) → 1
        await waitUntil { counter.value == 1 }
        m.noteStop(); m.noteStop(); m.noteStop()
        await waitUntil { counter.value == 2 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, 2, "three Stops inside the debounce window must produce exactly one trailing fetch")
    }

    func testStopsWhileCollapsedScheduleNothingWithChipOff() async {
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump(); return Self.snapshot
        })
        m.noteStop(); m.noteStop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, 0, "with the chip off the footer is the only surface, so a collapsed island must not fetch")
        // The pending Stop is served once the footer is on screen.
        m.noteExpanded()
        await waitUntil { counter.value == 1 }
        XCTAssertEqual(counter.value, 1)
    }

    func testLaunchWithTheChipOnFetchesWithoutWaitingForAnEvent() async {
        // Chip off (setUp) or the setting off: nothing at launch, as on main.
        let idle = Counter()
        let footerOnly = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = idle.bump(); return Self.snapshot
        })
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(idle.value, 0, "a collapsed island with the chip off must not fetch at launch")
        XCTAssertNil(footerOnly.snapshot)

        // Chip on: the numbers are on screen from the start, so the first
        // fetch runs without a Stop, an expand or a settings write.
        defaults.set(ClaudeQuotaChipMode.auto.rawValue, forKey: SettingsKey.claudeQuotaChip)
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump(); return Self.snapshot
        })
        await waitUntil { m.snapshot != nil }
        XCTAssertEqual(m.snapshot, Self.snapshot)
        XCTAssertEqual(counter.value, 1)
        // Then only the idle floor (100 s here) is left: nothing else fires.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, 1)
    }

    func testCollapsedChipRefreshesOnStopAndIdleTickUntilTurnedOff() async {
        // The chip shows the numbers on the collapsed bar: a Stop is served
        // without the panel opening, and the idle tick keeps catching resets.
        defaults.set(ClaudeQuotaChipMode.auto.rawValue, forKey: SettingsKey.claudeQuotaChip)
        var config = fastConfig()
        config.idleFloor = 0.3
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: config), defaults: defaults, fetcher: {
            _ = counter.bump(); return Self.snapshot
        })
        await waitUntil { counter.value == 1 }   // launch fetch
        m.noteStop()
        await waitUntil { counter.value == 2 }
        XCTAssertEqual(counter.value, 2, "a Stop must be fetched while collapsed when the chip is on")
        await waitUntil { counter.value == 3 }
        XCTAssertEqual(counter.value, 3, "the idle tick must refresh a collapsed island showing the chip")
        // Chip off while collapsed: back to main's behaviour, nothing scheduled.
        defaults.set(ClaudeQuotaChipMode.off.rawValue, forKey: SettingsKey.claudeQuotaChip)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let settled = counter.value
        try? await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(counter.value, settled, "turning the chip off must cancel the idle tick")
    }

    func testResultLandingAfterDisableIsDropped() async {
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump()
            try? await Task.sleep(nanoseconds: 200_000_000)
            return Self.snapshot
        })
        m.noteExpanded()
        await waitUntil { counter.value == 1 }
        defaults.set(false, forKey: SettingsKey.showClaudeQuota)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(m.snapshot, "a fetch that finishes after the setting is off must not repopulate the snapshot")
        XCTAssertNil(m.lastError)
    }

    func testUnauthorizedSurfacesLoginErrorAndStopsPolling() async {
        let counter = Counter()
        let m = ClaudeQuotaMonitor(scheduler: .init(config: fastConfig()), defaults: defaults, fetcher: {
            _ = counter.bump(); throw ClaudeQuotaClientError.unauthorized
        })
        m.noteExpanded()
        await waitUntil { m.lastError != nil }
        XCTAssertEqual(m.lastError, .unauthorized)
        XCTAssertTrue(m.scheduler.needsLogin)
        m.noteStop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(counter.value, 1)
    }
}
