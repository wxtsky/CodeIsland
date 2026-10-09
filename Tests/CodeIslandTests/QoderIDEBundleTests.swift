import XCTest
@testable import CodeIsland
import CodeIslandCore

/// #327 — Qoder IDE 1.25.1 (2026-08-19) renamed the macOS bundle to
/// `Qoder IDE.app` and its executable from `Electron` to `Qoder`. Every path
/// CodeIsland matched the IDE by was spelled with the old name, so an updated
/// install stopped being recognised as Qoder at all.
final class QoderIDEBundleTests: XCTestCase {
    func testRecognisesTheRenamedBundle() {
        XCTAssertTrue(AppState.isQoderIDEBundlePath(
            "/Applications/Qoder IDE.app/Contents/MacOS/Qoder"))
        XCTAssertTrue(AppState.isQoderIDEBundlePath(
            "/Applications/Qoder IDE.app/Contents/Frameworks/Qoder Helper (Renderer).app/Contents/MacOS/Qoder Helper (Renderer)"))
    }

    /// The rename doesn't reach installs that haven't updated, so both names
    /// have to keep working — this is not a migration.
    func testStillRecognisesThePreRenameBundle() {
        XCTAssertTrue(AppState.isQoderIDEBundlePath(
            "/Applications/Qoder.app/Contents/MacOS/Electron"))
        XCTAssertTrue(AppState.isQoderIDEBundlePath(
            "/Applications/Qoder.app/Contents/Frameworks/Qoder Helper (GPU).app/Contents/MacOS/Qoder Helper (GPU)"))
    }

    /// QoderWork is a different product with its own source and its own card.
    /// Neither IDE prefix may swallow it.
    func testDoesNotMatchQoderWork() {
        XCTAssertFalse(AppState.isQoderIDEBundlePath(
            "/Applications/QoderWork.app/Contents/MacOS/QoderWork"))
    }

    func testDoesNotMatchTheStandaloneCLI() {
        XCTAssertFalse(AppState.isQoderIDEBundlePath(
            "/Users/someone/.qoder/bin/qodercli/qodercli-1.1.39"))
    }

    /// The standalone App reuses ~/.qoder hooks, but has its own bundle ID.
    /// Native-app mode is the first guard against orphan cleanup sending SIGTERM.
    func testQoderAppHookCreatesNativeAppSession() throws {
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "qoder-app-session",
            "_source": "qoder",
            "_term_bundle": "com.qoder.app",
            "_ppid": 10260,
            "cwd": "/Users/u/project",
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)

        let session = try XCTUnwrap(sessions["qoder-app-session"])
        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
        XCTAssertEqual(session.terminalBadgeLabel, "Qoder")
        XCTAssertEqual(session.mascotSource, "qoder")
        XCTAssertTrue(AppState.isQoderIDEBundlePath(
            "/Applications/Qoder.app/Contents/MacOS/Qoder"))
    }

    func testQoderIDEKeepsItsBundleAndJumpFallback() {
        var session = SessionSnapshot()
        session.source = "qoder"
        session.termBundleId = "com.qoder.ide"

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertEqual(session.terminalBadgeLabel, "Qoder IDE")
        XCTAssertEqual(TerminalActivator.sourceToNativeAppBundleId["qoder"], "com.qoder.ide")
    }

    func testQoderAppDoesNotClaimOtherAgentSources() {
        for source in ["qoder-cli", "qoderwork", "claude"] {
            var session = SessionSnapshot()
            session.source = source
            session.termBundleId = "com.qoder.app"

            XCTAssertFalse(session.isNativeAppMode, source)
            XCTAssertEqual(session.mascotSource, source)
            XCTAssertEqual(session.terminalBadgeLabel, session.sourceLabel)
        }
    }
}
