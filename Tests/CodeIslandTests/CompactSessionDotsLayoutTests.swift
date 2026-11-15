import XCTest
@testable import CodeIsland

/// The collapsed bar's session dots (Settings → "Session Dots in Compact
/// Bar"): a session that is doing or wanting something gets a filled dot in
/// its status colour, an idle or finished one a grey ring, and past eight
/// sessions the rest collapse into `+N`.
final class CompactSessionDotsLayoutTests: XCTestCase {

    func testActiveStatusesFillAndRestingStatusesRing() {
        for status in [SessionCardStatus.needsYou, .working, .thinking, .stopped, .error] {
            XCTAssertTrue(CompactSessionDotsLayout.isFilled(status), "\(status) should be a filled dot")
        }
        for status in [SessionCardStatus.idle, .done] {
            XCTAssertFalse(CompactSessionDotsLayout.isFilled(status), "\(status) should be a ring")
        }
        // Every status is decided — a new case has to pick a side here.
        XCTAssertEqual(SessionCardStatus.allCases.count, 7)
    }

    func testDotsKeepTheListOrder() {
        let model = CompactSessionDotsLayout.model([
            (id: "a", status: .needsYou), (id: "b", status: .done), (id: "c", status: .working),
        ])
        XCTAssertEqual(model.dots.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(model.dots.map(\.isFilled), [true, false, true])
        XCTAssertEqual(model.overflow, 0)
    }

    func testEightSessionsFitWithoutALabel() {
        let sessions = (0..<8).map { (id: "s\($0)", status: SessionCardStatus.working) }
        let model = CompactSessionDotsLayout.model(sessions)
        XCTAssertEqual(model.dots.count, 8)
        XCTAssertEqual(model.overflow, 0)
    }

    func testPastTheCapTheRestBecomePlusN() {
        let sessions = (0..<11).map { (id: "s\($0)", status: SessionCardStatus.idle) }
        let model = CompactSessionDotsLayout.model(sessions)
        XCTAssertEqual(model.dots.count, CompactSessionDotsLayout.maxDots)
        XCTAssertEqual(model.dots.last?.id, "s7")
        XCTAssertEqual(model.overflow, 3)
    }

    func testNoSessionsDrawNothing() {
        let model = CompactSessionDotsLayout.model([])
        XCTAssertTrue(model.dots.isEmpty)
        XCTAssertEqual(model.overflow, 0)
    }
}
