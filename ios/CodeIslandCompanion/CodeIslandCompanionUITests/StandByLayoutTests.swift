import XCTest
import CoreGraphics

final class StandByLayoutTests: XCTestCase {
    // 消息行数固定为 3。
    func testMessageLimitAlwaysThree() {
        XCTAssertEqual(standbySessionBoardLayout(boardHeight: 800, sessionCount: 2).messageLineLimit, 3)
        XCTAssertEqual(standbySessionBoardLayout(boardHeight: 200, sessionCount: 6).messageLineLimit, 3)
    }

    // 可见会话数按 3 行高度（stride 92）容纳。
    func testVisibleCountFitsByHeight() {
        // usable 756，Int(756/92)=8 行，6 个会话全显
        XCTAssertEqual(standbySessionBoardLayout(boardHeight: 800, sessionCount: 6).visibleCount, 6)
        // usable 356，Int(356/92)=3 行，10 个会话只显 3 个
        XCTAssertEqual(standbySessionBoardLayout(boardHeight: 400, sessionCount: 10).visibleCount, 3)
    }

    // 极小高度也至少显示 1 条。
    func testAtLeastOneRow() {
        XCTAssertEqual(standbySessionBoardLayout(boardHeight: 30, sessionCount: 6).visibleCount, 1)
    }
}
