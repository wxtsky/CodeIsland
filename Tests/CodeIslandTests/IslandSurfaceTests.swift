import XCTest
@testable import CodeIsland

final class IslandSurfaceTests: XCTestCase {
    func testCollapsedSurfaceCannotAutoCollapse() {
        XCTAssertFalse(IslandSurface.collapsed.canAutoCollapse)
    }

    func testApprovalAndQuestionCardsAreProtectedFromAutoCollapse() {
        XCTAssertFalse(IslandSurface.approvalCard(sessionId: "s1").canAutoCollapse)
        XCTAssertFalse(IslandSurface.questionCard(sessionId: "s1").canAutoCollapse)
    }

    func testSessionListAndCompletionCardCanAutoCollapse() {
        XCTAssertTrue(IslandSurface.sessionList.canAutoCollapse)
        XCTAssertTrue(IslandSurface.completionCard(sessionId: "s1").canAutoCollapse)
    }
}
