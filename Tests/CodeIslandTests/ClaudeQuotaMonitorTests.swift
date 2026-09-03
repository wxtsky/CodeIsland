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
        defaults.set(ClaudeQuotaChipMode.auto.rawValue, forKey: SettingsKey.claudeQuotaChip)
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
        XCTAssertEqual(m.chipLimit()?.kind, .weeklyScoped)
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
        XCTAssertNil(m.chipLimit())
    }

    func testBurstOfStopsCoalescesIntoOneFetch() async {
        defaults.set(ClaudeQuotaChipMode.off.rawValue, forKey: SettingsKey.claudeQuotaChip)
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
