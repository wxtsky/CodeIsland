import XCTest
@testable import CodeIsland

final class NotchGesturePolicyTests: XCTestCase {
    func testOnlyCollapsedNotchWithSessionsCanOpen() {
        XCTAssertTrue(NotchGesturePolicy.canOpen(surface: .collapsed, hasSessions: true))
        XCTAssertFalse(NotchGesturePolicy.canOpen(surface: .sessionList, hasSessions: true))
        XCTAssertFalse(NotchGesturePolicy.canOpen(surface: .collapsed, hasSessions: false))
    }

    func testCloseProtectsApprovalAndQuestionCards() {
        XCTAssertTrue(NotchGesturePolicy.canClose(surface: .sessionList))
        XCTAssertTrue(NotchGesturePolicy.canClose(surface: .completionCard(sessionId: "s")))
        XCTAssertFalse(NotchGesturePolicy.canClose(surface: .approvalCard(sessionId: "s")))
        XCTAssertFalse(NotchGesturePolicy.canClose(surface: .questionCard(sessionId: "s")))
        XCTAssertFalse(NotchGesturePolicy.canClose(surface: .collapsed))
    }

    func testFilterNavigationUsesNaturalDirectionAndClamps() {
        XCTAssertEqual(NotchGesturePolicy.filterMode(from: "all", action: .navigateNext, controlsVisible: true), "status")
        XCTAssertEqual(NotchGesturePolicy.filterMode(from: "status", action: .navigateNext, controlsVisible: true), "cli")
        XCTAssertEqual(NotchGesturePolicy.filterMode(from: "cli", action: .navigateNext, controlsVisible: true), "cli")
        XCTAssertEqual(NotchGesturePolicy.filterMode(from: "status", action: .navigatePrevious, controlsVisible: true), "all")
        XCTAssertEqual(NotchGesturePolicy.filterMode(from: "all", action: .navigatePrevious, controlsVisible: true), "all")
        XCTAssertNil(NotchGesturePolicy.filterMode(from: "all", action: .navigateNext, controlsVisible: false))
    }
}
