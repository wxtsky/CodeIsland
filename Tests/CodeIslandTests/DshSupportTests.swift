import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// DeepSeek Harness desktop (`com.deepseek.dsh`) is a single-window Electron
/// app with no terminal of its own. Clicking its card used to fall through to
/// `detectRunningTerminal()` — a desktop session has no TTY — so the click
/// raised an unrelated terminal, or nothing at all.
///
/// The app is registered as a native app like Codex/Claude Desktop but is
/// deliberately absent from `sourceToNativeAppBundleId`: a `dsh` CLI run in a
/// real terminal must keep its terminal jump. The desktop case is recognised
/// by the session's missing-or-matching `_term_bundle` instead.
final class DshSupportTests: XCTestCase {
    private let dshBundle = "com.deepseek.dsh"

    func testDeepSeekHarnessDesktopIsRegisteredAsTheDshNativeApp() {
        XCTAssertEqual(TerminalActivator.deepSeekHarnessBundleId, dshBundle)
        XCTAssertEqual(SessionSnapshot.sourceForAppBundleId(dshBundle), "dsh")
        XCTAssertEqual(TerminalActivator.desktopAppBundleId(forSource: "dsh"), dshBundle)
        // Not a source fallback: a running DeepSeek Harness must never steal a
        // dsh CLI's terminal jump.
        XCTAssertNil(TerminalActivator.sourceToNativeAppBundleId["dsh"])
    }

    func testSessionWithTheDesktopBundleIsNativeAppMode() {
        var session = SessionSnapshot()
        session.source = "dsh"
        session.termBundleId = dshBundle
        session.termApp = "DeepSeek Harness"

        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertFalse(session.isIDETerminal)
        XCTAssertEqual(session.terminalName, "DeepSeek Harness")
        XCTAssertEqual(session.terminalBadgeLabel, "DeepSeek Harness")
        XCTAssertEqual(session.mascotSource, "dsh")
    }

    func testDesktopSessionWithoutTerminalMetadataStillRoutesToTheApp() {
        var session = SessionSnapshot()
        session.source = "dsh"
        XCTAssertTrue(TerminalActivator.isDeepSeekHarnessDesktopSession(session))

        session.termBundleId = dshBundle
        XCTAssertTrue(TerminalActivator.isDeepSeekHarnessDesktopSession(session))
    }

    func testDshCliInATerminalKeepsItsTerminalJump() {
        var session = SessionSnapshot()
        session.source = "dsh"
        session.termBundleId = "com.mitchellh.ghostty"
        session.termApp = "Ghostty"

        XCTAssertFalse(TerminalActivator.isDeepSeekHarnessDesktopSession(session))
        XCTAssertFalse(session.isNativeAppMode)
        XCTAssertEqual(session.terminalName, "Ghostty")
    }

    /// The dsh-island bridge reports the app's bundle id with every event; the
    /// hook pipeline must keep it and mark the session as the native app.
    func testHookWithTheDshBundleCreatesANativeAppSession() throws {
        let payload: [String: Any] = [
            "hook_event_name": "SessionStart",
            "session_id": "dsh-desktop-session",
            "_source": "dsh",
            "_term_app": "DeepSeek Harness",
            "_term_bundle": dshBundle,
            "cwd": "/Users/u/project",
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)

        let session = try XCTUnwrap(sessions["dsh-desktop-session"])
        XCTAssertTrue(session.isNativeAppMode)
        XCTAssertEqual(session.terminalName, "DeepSeek Harness")
        XCTAssertEqual(session.mascotSource, "dsh")
    }
}
