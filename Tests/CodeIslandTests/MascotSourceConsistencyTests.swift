import XCTest
@testable import CodeIslandCore

/// Left mascot and right host badge must agree on which agent/app a card represents.
/// Empty hook `source` + Cursor host previously showed Clawd + "Cursor" (#296 follow-up).
final class MascotSourceConsistencyTests: XCTestCase {

    private func makeSession(source: String, termBundleId: String?) -> SessionSnapshot {
        var session = SessionSnapshot()
        session.source = source
        session.termBundleId = termBundleId
        return session
    }

    func testCursorBundleInfersMascotWhenSourceEmpty() {
        let session = makeSession(source: "", termBundleId: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.mascotSource, "cursor")
        XCTAssertFalse(session.isCLIHostedInForeignApp)
    }

    func testCursorSourceKeepsCursorMascot() {
        let session = makeSession(source: "cursor", termBundleId: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.mascotSource, "cursor")
        XCTAssertFalse(session.isCLIHostedInForeignApp)
    }

    func testClaudeCLIInsideCursorIsForeignHosted() {
        let session = makeSession(source: "claude", termBundleId: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.mascotSource, "claude")
        XCTAssertTrue(session.isIDETerminal)
        XCTAssertTrue(session.isCLIHostedInForeignApp)
    }

    func testCodexDesktopInfersMascotWhenSourceEmpty() {
        let session = makeSession(source: "", termBundleId: "com.openai.codex")
        XCTAssertEqual(session.mascotSource, "codex")
        XCTAssertFalse(session.isCLIHostedInForeignApp)
    }

    func testSourceForAppBundleIdMapsCursor() {
        XCTAssertEqual(
            SessionSnapshot.sourceForAppBundleId("com.todesktop.230313mzl4w4u92"),
            "cursor"
        )
    }

    func testTerminalBadgeLabelFollowsCLIWhenHostedInForeignApp() {
        let session = makeSession(source: "claude", termBundleId: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.terminalName, "Cursor")
        XCTAssertEqual(session.terminalBadgeLabel, "Claude")
        XCTAssertEqual(session.mascotSource, "claude")
    }

    func testTerminalBadgeLabelFollowsHostForNativeCursorSession() {
        let session = makeSession(source: "cursor", termBundleId: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.terminalBadgeLabel, "Cursor")
        XCTAssertEqual(session.mascotSource, "cursor")
    }

    func testTerminalBadgeLabelInfersCursorWhenSourceEmpty() {
        let session = makeSession(source: "", termBundleId: "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.mascotSource, "cursor")
        XCTAssertEqual(session.terminalBadgeLabel, "Cursor")
        XCTAssertFalse(session.isCLIHostedInForeignApp)
    }
}
