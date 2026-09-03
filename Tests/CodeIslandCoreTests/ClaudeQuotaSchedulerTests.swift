import XCTest
@testable import CodeIslandCore

final class ClaudeQuotaSchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testFirstLiveTickFiresImmediately() {
        let s = ClaudeQuotaScheduler()
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: t0), t0)
        XCTAssertNil(s.nextFireTime(wantsLive: false, now: t0))
    }

    /// Two sessions finishing 12s apart cost one request, 15s after the last Stop.
    func testStopsWithinDebounceCoalesceIntoOneFetch() {
        var s = ClaudeQuotaScheduler()
        s.recordFetchStart(now: at(-3600))   // some old fetch, throttle long expired
        s.recordStop(now: at(0))
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(0)), at(15))
        s.recordStop(now: at(12))
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(12)), at(27))
        s.recordFetchStart(now: at(27))
        XCTAssertFalse(s.pending)
        // No more stops: only the idle floor remains.
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(27)), at(27 + 600))
    }

    /// A Stop inside the 60s throttle is served by one trailing fetch at the window edge.
    func testStopInsideThrottleGetsTrailingFetch() {
        var s = ClaudeQuotaScheduler()
        s.recordFetchStart(now: at(0))
        s.recordStop(now: at(10))
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(10)), at(60))
        s.recordStop(now: at(50))    // debounce would say 65 → later than throttle edge
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(50)), at(65))
    }

    func testStopsAreRememberedWhileNothingIsOnScreen() {
        var s = ClaudeQuotaScheduler()
        s.recordStop(now: at(0))
        XCTAssertNil(s.nextFireTime(wantsLive: false, now: at(0)))
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(100)), at(15))
    }

    func testFailuresBackOffExponentiallyAndCap() {
        var s = ClaudeQuotaScheduler()
        s.recordFetchStart(now: at(0))
        s.recordFailure(unauthorized: false)
        XCTAssertEqual(s.backoff, 60)
        s.recordStop(now: at(1))
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(1)), at(60))
        for _ in 0..<10 { s.recordFailure(unauthorized: false) }
        XCTAssertEqual(s.backoff, 900)
        XCTAssertEqual(s.nextFireTime(wantsLive: true, now: at(1)), at(900))
        XCTAssertFalse(s.shouldFetchOnExpand(now: at(899)))
        XCTAssertTrue(s.shouldFetchOnExpand(now: at(900)))
        s.recordSuccess()
        XCTAssertNil(s.backoff)
    }

    func testRejectedTokenStopsBackgroundFetchesButExpandRetries() {
        var s = ClaudeQuotaScheduler()
        s.recordFetchStart(now: at(0))
        s.recordFailure(unauthorized: true)
        XCTAssertTrue(s.needsLogin)
        s.recordStop(now: at(5))
        XCTAssertNil(s.nextFireTime(wantsLive: true, now: at(5)))
        XCTAssertFalse(s.shouldFetchOnExpand(now: at(30)))
        XCTAssertTrue(s.shouldFetchOnExpand(now: at(60)))
        s.recordSuccess()
        XCTAssertFalse(s.needsLogin)
    }

    func testExpandRefreshesOnlyWhenStale() {
        var s = ClaudeQuotaScheduler()
        XCTAssertTrue(s.shouldFetchOnExpand(now: t0))
        s.recordFetchStart(now: t0)
        XCTAssertFalse(s.shouldFetchOnExpand(now: at(59)))
        XCTAssertTrue(s.shouldFetchOnExpand(now: at(60)))
    }
}
