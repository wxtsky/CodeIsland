import XCTest
import CoreGraphics

final class StandByLayoutTests: XCTestCase {
    func testVisibleCountByHeight() {
        // 高 400：usable = 356，356/66 = 5
        XCTAssertEqual(standbyVisibleSessionCount(boardHeight: 400), 5)
        // 高 800：usable = 756，756/66 = 11
        XCTAssertEqual(standbyVisibleSessionCount(boardHeight: 800), 11)
    }

    func testVisibleCountNeverBelowOne() {
        // 高度极小，至少 1 行
        XCTAssertEqual(standbyVisibleSessionCount(boardHeight: 30), 1)
    }
}
