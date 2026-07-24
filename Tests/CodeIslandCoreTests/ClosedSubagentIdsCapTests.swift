import XCTest
@testable import CodeIslandCore

final class ClosedSubagentIdsCapTests: XCTestCase {
    func testHasClosedSubagentIdMatchesRecordedIds() {
        var snapshot = SessionSnapshot()
        snapshot.recordClosedSubagentId("a")
        XCTAssertTrue(snapshot.hasClosedSubagentId("a"))
        XCTAssertFalse(snapshot.hasClosedSubagentId("b"))
        snapshot.clearClosedSubagentId("a")
        XCTAssertFalse(snapshot.hasClosedSubagentId("a"))
    }

    func testHasClosedSubagentIdTrimsLikeRecord() {
        var snapshot = SessionSnapshot()
        snapshot.recordClosedSubagentId("  a  ")
        XCTAssertTrue(snapshot.hasClosedSubagentId("  a  "))
        XCTAssertTrue(snapshot.hasClosedSubagentId("a"))
        XCTAssertFalse(snapshot.hasClosedSubagentId("   "))
    }

    func testClearClosedSubagentIdTrimsLikeRecord() {
        var snapshot = SessionSnapshot()
        snapshot.recordClosedSubagentId("  a  ")
        XCTAssertEqual(snapshot.closedSubagentIds, ["a"])
        snapshot.clearClosedSubagentId("  a  ")
        XCTAssertTrue(snapshot.closedSubagentIds.isEmpty)
    }

    func testRecordClosedSubagentIdKeepsLastNInInsertionOrder() {
        var snapshot = SessionSnapshot()
        let limit = SessionSnapshot.maxClosedSubagentIds
        for i in 0..<(limit + 10) {
            snapshot.recordClosedSubagentId(String(format: "id-%03d", i))
        }
        XCTAssertEqual(snapshot.closedSubagentIds.count, limit)
        XCTAssertEqual(snapshot.closedSubagentIds.first, "id-010")
        XCTAssertEqual(snapshot.closedSubagentIds.last, String(format: "id-%03d", limit + 9))
        XCTAssertFalse(snapshot.closedSubagentIds.contains("id-000"))
        XCTAssertTrue(snapshot.closedSubagentIds.contains("id-010"))
    }

    func testRecordClosedSubagentIdIsIdempotent() {
        var snapshot = SessionSnapshot()
        snapshot.recordClosedSubagentId("a")
        snapshot.recordClosedSubagentId("a")
        XCTAssertEqual(snapshot.closedSubagentIds, ["a"])
    }

    func testClearClosedSubagentIdRemovesTombstone() {
        var snapshot = SessionSnapshot()
        snapshot.recordClosedSubagentId("a")
        snapshot.recordClosedSubagentId("b")
        snapshot.clearClosedSubagentId("a")
        XCTAssertEqual(snapshot.closedSubagentIds, ["b"])
    }

    func testRestoreClosedSubagentIdsKeepsAllWithoutLiveCap() {
        var snapshot = SessionSnapshot()
        let ids = (0..<80).map { String(format: "p-%03d", $0) }
        snapshot.restoreClosedSubagentIds(ids)
        // Restore must not invent recency via keep-last-N (legacy files were
        // lexicographically sorted).
        XCTAssertEqual(snapshot.closedSubagentIds.count, 80)
        XCTAssertEqual(snapshot.closedSubagentIds.first, "p-000")
        XCTAssertEqual(snapshot.closedSubagentIds.last, "p-079")
        XCTAssertTrue(snapshot.hasClosedSubagentId("p-000"))
        XCTAssertTrue(snapshot.hasClosedSubagentId("p-079"))
    }

    func testRecordAfterLargeRestoreStillAppliesLiveCap() {
        var snapshot = SessionSnapshot()
        let over = SessionSnapshot.maxClosedSubagentIds + 10
        let ids = (0..<over).map { String(format: "p-%03d", $0) }
        snapshot.restoreClosedSubagentIds(ids)
        XCTAssertEqual(snapshot.closedSubagentIds.count, over)
        snapshot.recordClosedSubagentId("new-1")
        XCTAssertEqual(snapshot.closedSubagentIds.count, SessionSnapshot.maxClosedSubagentIds)
        XCTAssertEqual(snapshot.closedSubagentIds.last, "new-1")
        XCTAssertFalse(snapshot.hasClosedSubagentId("p-000"))
    }
}
