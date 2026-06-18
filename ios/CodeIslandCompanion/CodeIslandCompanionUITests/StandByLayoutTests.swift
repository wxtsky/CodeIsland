import XCTest
import CoreGraphics

final class StandByLayoutTests: XCTestCase {
    func testSingleColumnWhenNarrow() {
        XCTAssertEqual(standbyColumnCount(boardWidth: 400), 1)
        XCTAssertEqual(standbyColumnCount(boardWidth: 559), 1)
    }

    func testTwoColumnsAtThreshold() {
        XCTAssertEqual(standbyColumnCount(boardWidth: 560), 2)
        XCTAssertEqual(standbyColumnCount(boardWidth: 900), 2)
    }

    func testVisibleCountNarrowBoard() {
        // 宽 400（单列），高 400：usable = 356，356/66 = 5
        XCTAssertEqual(standbyVisibleSessionCount(boardSize: CGSize(width: 400, height: 400)), 5)
    }

    func testVisibleCountWideTallBoard() {
        // 宽 700（双列），高 800：usable = 756，756/66 = 11，×2 = 22
        XCTAssertEqual(standbyVisibleSessionCount(boardSize: CGSize(width: 700, height: 800)), 22)
    }

    func testVisibleCountNeverBelowColumns() {
        // 高度极小，单列至少 1 行
        XCTAssertEqual(standbyVisibleSessionCount(boardSize: CGSize(width: 400, height: 30)), 1)
        // 双列极小高度至少 2
        XCTAssertEqual(standbyVisibleSessionCount(boardSize: CGSize(width: 700, height: 30)), 2)
    }
}
