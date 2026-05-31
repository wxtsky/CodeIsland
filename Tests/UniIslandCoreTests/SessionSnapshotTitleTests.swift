import XCTest
@testable import UniIslandCore

final class SessionSnapshotTitleTests: XCTestCase {
    func testDisplayTitlePrefersProviderSessionTitle() {
        var snapshot = SessionSnapshot()
        snapshot.sessionTitle = "Investigate icon sizing"

        XCTAssertEqual(
            snapshot.displayTitle(sessionId: "019d6331-3593-7b53-9513-c1dd25d708b0"),
            "Investigate icon sizing"
        )
    }

    func testDisplayTitleFallsBackToSessionIdWhenNoProviderTitleExists() {
        let snapshot = SessionSnapshot()

        XCTAssertEqual(
            snapshot.displayTitle(sessionId: "019d632b-abee-76e3-80d6-667ea86ebeaf"),
            "019d632b-abee-76e3-80d6-667ea86ebeaf"
        )
    }

    func testProjectDisplayNameStillUsesFolderName() {
        var snapshot = SessionSnapshot()
        snapshot.cwd = "/Users/wangnov/UniIsland"

        XCTAssertEqual(snapshot.projectDisplayName, "UniIsland")
    }

    func testDisplaySessionIdPrefersProviderSessionId() {
        var snapshot = SessionSnapshot()
        snapshot.providerSessionId = "019d6330-beed-7a13-b61e-cacf03d3cefe"

        XCTAssertEqual(
            snapshot.displaySessionId(sessionId: "hook-codex-session"),
            "019d6330-beed-7a13-b61e-cacf03d3cefe"
        )
    }

    func testDisplaySessionIdFallsBackToTrackedSessionId() {
        let snapshot = SessionSnapshot()

        XCTAssertEqual(
            snapshot.displaySessionId(sessionId: "hook-codex-session"),
            "hook-codex-session"
        )
    }

    func testSessionTitleAssignmentDoesNotOverwriteProjectDisplayName() {
        var snapshot = SessionSnapshot()
        snapshot.cwd = "/Users/wangnov/UniIsland"
        snapshot.sessionTitle = "查看图标bug和窗口大小bug解法"

        XCTAssertEqual(
            snapshot.displayTitle(sessionId: "019d6331-3593-7b53-9513-c1dd25d708b0"),
            "查看图标bug和窗口大小bug解法"
        )
        XCTAssertEqual(snapshot.projectDisplayName, "UniIsland")
    }
}
