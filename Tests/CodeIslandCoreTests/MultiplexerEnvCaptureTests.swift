import XCTest
@testable import CodeIslandCore

/// Verifies the bridge → reducer → SessionSnapshot path correctly captures terminal
/// multiplexer / fork hints (Zellij, WezTerm, Kaku) so TerminalActivator can use them
/// for precise pane/tab focus. The bridge writes underscore-prefixed payload keys; the
/// reducer reads them in two places (SessionStart fast path, and extractMetadata for
/// every event), so both code paths need explicit coverage.
final class MultiplexerEnvCaptureTests: XCTestCase {

    // MARK: - Zellij

    func testSessionStartCapturesZellijPaneAndSessionName() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-1",
            "_zellij": "0.40.0",
            "_zellij_pane_id": "12",
            "_zellij_session_name": "main",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-1"]?.zellijPaneId, "12")
        XCTAssertEqual(sessions["sess-1"]?.zellijSessionName, "main")
    }

    func testNonSessionStartEventStillCapturesZellijFields() {
        // Important: hook events landing after SessionStart (PostToolUse / Stop / etc.)
        // also carry the env hints — extractMetadata must pick them up so a session
        // discovered via PreToolUse alone still gets routable to the right pane.
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-2",
            "_zellij_pane_id": "7",
            "_zellij_session_name": "work",
        ])

        var sessions: [String: SessionSnapshot] = ["sess-2": SessionSnapshot()]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-2"]?.zellijPaneId, "7")
        XCTAssertEqual(sessions["sess-2"]?.zellijSessionName, "work")
    }

    func testZellijFieldsAbsentWhenNoEnvVarsPresent() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-3",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertNil(sessions["sess-3"]?.zellijPaneId)
        XCTAssertNil(sessions["sess-3"]?.zellijSessionName)
    }

    func testEmptyZellijPaneStringIsNotStored() {
        // Bridge filters empty strings, but defense-in-depth: reducer must also ignore
        // empty values so we don't store a bogus pane id like "" that fails Int parsing.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-4",
            "_zellij_pane_id": "",
            "_zellij_session_name": "",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertNil(sessions["sess-4"]?.zellijPaneId)
        XCTAssertNil(sessions["sess-4"]?.zellijSessionName)
    }

    // MARK: - WezTerm / Kaku

    func testSessionStartCapturesWeztermPane() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-wez",
            "_wezterm_pane": "42",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-wez"]?.weztermPaneId, "42")
    }

    func testKakuPaneCapturedThroughSamePayloadKey() {
        // Kaku is a WezTerm fork that also exports WEZTERM_PANE; the bridge writes
        // _wezterm_pane regardless of which fork emitted it, and the activator decides
        // which CLI to invoke based on termBundleId. This test pins that contract:
        // the same payload key serves both forks at the snapshot level.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-kaku",
            "_wezterm_pane": "9",
            "_term_bundle": "fun.tw93.kaku",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-kaku"]?.weztermPaneId, "9")
        XCTAssertEqual(sessions["sess-kaku"]?.termBundleId, "fun.tw93.kaku")
    }

    // MARK: - Helpers

    private func makeEvent(_ payload: [String: Any]) -> HookEvent {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HookEvent(from: data)!
    }
}
