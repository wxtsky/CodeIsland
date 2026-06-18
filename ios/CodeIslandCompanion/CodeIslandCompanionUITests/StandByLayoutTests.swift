import XCTest
import CoreGraphics

final class StandByLayoutTests: XCTestCase {
    // 空间充裕、会话少：每条消息放到 3 行上限，全部可见。
    func testSpaciousFewSessionsUseThreeLines() {
        // 高 800：usable 756，maxRows 11，visible 2，perRow 378 → 远超 3 行 → 限 3
        let layout = standbySessionBoardLayout(boardHeight: 800, sessionCount: 2)
        XCTAssertEqual(layout, StandBySessionBoardLayout(visibleCount: 2, messageLineLimit: 3))
    }

    // 会话填满高度：压缩到 1 行，全部可见。
    func testManySessionsCompressToOneLine() {
        // 高 800：usable 756，maxRows 11，visible 11，perRow ≈68.7 → 额外 0 行 → 限 1
        let layout = standbySessionBoardLayout(boardHeight: 800, sessionCount: 11)
        XCTAssertEqual(layout, StandBySessionBoardLayout(visibleCount: 11, messageLineLimit: 1))
    }

    // 中等：每条约 2 行。
    func testMediumDensityUsesTwoLines() {
        // 高 400：usable 356，visible 4，perRow 89 → 额外 floor(23/17)=1 → 限 2
        let layout = standbySessionBoardLayout(boardHeight: 400, sessionCount: 4)
        XCTAssertEqual(layout, StandBySessionBoardLayout(visibleCount: 4, messageLineLimit: 2))
    }

    // 超过按 1 行也放不下：只显示能放下的条数。
    func testOverflowCapsVisibleCount() {
        // 高 400：usable 356，maxRows floor(356/66)=5 → visible 5（其余溢出）
        let layout = standbySessionBoardLayout(boardHeight: 400, sessionCount: 20)
        XCTAssertEqual(layout.visibleCount, 5)
        XCTAssertEqual(layout.messageLineLimit, 1)
    }

    // 极小高度：至少 1 条、1 行。
    func testTinyBoardKeepsOneRowOneLine() {
        let layout = standbySessionBoardLayout(boardHeight: 30, sessionCount: 6)
        XCTAssertEqual(layout, StandBySessionBoardLayout(visibleCount: 1, messageLineLimit: 1))
    }
}
