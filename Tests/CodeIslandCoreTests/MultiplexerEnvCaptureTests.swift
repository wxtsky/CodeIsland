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

    // MARK: - kitty

    func testSessionStartCapturesKittyWindowAndSocket() {
        // kitty is reachable from outside only through its remote-control socket
        // (KITTY_LISTEN_ON): `kitten @` without `--to` wants a controlling tty,
        // which a GUI app does not have. The window id picks the tab, the socket
        // picks the instance, so both have to survive to the snapshot.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-kitty",
            "_kitty_window": "4",
            "_kitty_listen_on": "unix:/var/folders/xy/T/kitty-9001",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-kitty"]?.kittyWindowId, "4")
        XCTAssertEqual(sessions["sess-kitty"]?.kittyListenOn, "unix:/var/folders/xy/T/kitty-9001")
    }

    func testNonSessionStartEventStillCapturesKittySocket() {
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-kitty-2",
            "_kitty_listen_on": "unix:/tmp/kitty-7",
        ])

        var sessions: [String: SessionSnapshot] = ["sess-kitty-2": SessionSnapshot()]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-kitty-2"]?.kittyListenOn, "unix:/tmp/kitty-7")
    }

    func testKittySocketCapturedFromEnvSubObject() {
        // Direct-plugin payload shape: the plugin forwards KITTY_LISTEN_ON inside `_env`.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-kitty-env",
            "_env": [
                "KITTY_WINDOW_ID": "6",
                "KITTY_LISTEN_ON": "unix:/tmp/kitty-env",
            ],
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-kitty-env"]?.kittyWindowId, "6")
        XCTAssertEqual(sessions["sess-kitty-env"]?.kittyListenOn, "unix:/tmp/kitty-env")
    }

    func testEmptyKittyListenOnIsNotStored() {
        // kitty sets KITTY_LISTEN_ON only when listen_on is configured; an empty
        // value must not become an address `kitten @ --to` would fail to dial.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-kitty-empty",
            "_kitty_window": "3",
            "_kitty_listen_on": "",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-kitty-empty"]?.kittyWindowId, "3")
        XCTAssertNil(sessions["sess-kitty-empty"]?.kittyListenOn)
    }

    // MARK: - Superset (#213)

    func testSessionStartCapturesSupersetWorkspaceAndPane() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset",
            "_superset_workspace_id": "ws-abc",
            "_superset_pane_id": "pane-1",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset"]?.supersetWorkspaceId, "ws-abc")
        XCTAssertEqual(sessions["sess-superset"]?.supersetPaneId, "pane-1")
    }

    func testNonSessionStartEventStillCapturesSupersetFields() {
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-superset-2",
            "_superset_workspace_id": "ws-xyz",
        ])

        var sessions: [String: SessionSnapshot] = ["sess-superset-2": SessionSnapshot()]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset-2"]?.supersetWorkspaceId, "ws-xyz")
    }

    func testSupersetCapturedFromEnvSubObject() {
        // Direct-plugin payload shape: SUPERSET_* arrives inside the `_env` sub-object.
        // SUPERSET_TERMINAL_ID is an accepted alias for the pane id.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset-env",
            "_env": [
                "SUPERSET_WORKSPACE_ID": "ws-env",
                "SUPERSET_TERMINAL_ID": "term-7",
            ],
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset-env"]?.supersetWorkspaceId, "ws-env")
        XCTAssertEqual(sessions["sess-superset-env"]?.supersetPaneId, "term-7")
    }

    func testEmptySupersetStringsAreNotStored() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset-empty",
            "_superset_workspace_id": "",
            "_superset_pane_id": "",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertNil(sessions["sess-superset-empty"]?.supersetWorkspaceId)
        XCTAssertNil(sessions["sess-superset-empty"]?.supersetPaneId)
    }

    func testSupersetTerminalNameOverridesSpoofedKittyTermProgram() {
        // ROOT BUG (#213): Superset spoofs TERM_PROGRAM=kitty and strips __CFBundleIdentifier.
        // Without the SUPERSET_* override the tag would read "Kitty"; with it, the session must
        // label as "Superset" so the user (and the activator's display) sees the right terminal.
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-superset-name",
            "_term_app": "kitty",
            "_superset_workspace_id": "ws-name",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-superset-name"]?.termApp, "kitty")
        XCTAssertEqual(sessions["sess-superset-name"]?.terminalName, "Superset")
    }

    // MARK: - Herdr

    func testSessionStartCapturesCompleteHerdrRoute() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-herdr",
            "_term_bundle": "com.mitchellh.ghostty",
            "_herdr_pane_id": "w2:p1",
            "_herdr_socket_path": "/tmp/herdr.sock",
            "_herdr_bin_path": "/opt/homebrew/bin/herdr",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-herdr"]?.herdrPaneId, "w2:p1")
        XCTAssertEqual(sessions["sess-herdr"]?.herdrSocketPath, "/tmp/herdr.sock")
        XCTAssertEqual(sessions["sess-herdr"]?.herdrBinaryPath, "/opt/homebrew/bin/herdr")
        // Herdr nests inside a host terminal, so it reads as a multiplexer chip
        // beside the terminal name rather than replacing it — same rule tmux and
        // zellij follow.
        XCTAssertEqual(sessions["sess-herdr"]?.terminalName, "Ghostty")
        XCTAssertEqual(sessions["sess-herdr"]?.multiplexerLabel, "herdr")
    }

    func testNonSessionStartEventCapturesCompleteHerdrRoute() {
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "sess-herdr-late",
            "_herdr_pane_id": "w3:p2",
            "_herdr_socket_path": "/tmp/named/herdr.sock",
        ])

        var sessions = ["sess-herdr-late": SessionSnapshot()]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-herdr-late"]?.herdrPaneId, "w3:p2")
        XCTAssertEqual(sessions["sess-herdr-late"]?.herdrSocketPath, "/tmp/named/herdr.sock")
    }

    func testIncompleteHerdrRouteKeepsOuterTerminalLabel() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-herdr-incomplete",
            "_term_bundle": "com.mitchellh.ghostty",
            "_herdr_pane_id": "w1:p1",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-herdr-incomplete"]?.terminalName, "Ghostty")
        XCTAssertNil(sessions["sess-herdr-incomplete"]?.multiplexerLabel,
                     "half a route must not advertise Herdr routing on the badge")
    }

    /// tmux inside a Herdr pane: the CLI actually sits in tmux, and that is where
    /// both the jump (`HerdrController.shouldRoute`) and the badge must point.
    func testTmuxInsideHerdrReportsTmux() {
        let event = makeEvent([
            "hook_event_name": "SessionStart",
            "session_id": "sess-herdr-tmux",
            "_term_bundle": "com.mitchellh.ghostty",
            "_herdr_pane_id": "w1:p1",
            "_herdr_socket_path": "/tmp/herdr.sock",
            "_tmux_pane": "%3",
        ])

        var sessions: [String: SessionSnapshot] = [:]
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 100)

        XCTAssertEqual(sessions["sess-herdr-tmux"]?.multiplexerLabel, "tmux")
        XCTAssertEqual(sessions["sess-herdr-tmux"]?.terminalName, "Ghostty")
    }

    func testSubagentMetadataFillsMissingHerdrRouteWithoutOverwritingParent() {
        var parent = SessionSnapshot()
        parent.herdrPaneId = "existing-pane"
        var sessions = ["parent": parent]
        let event = makeEvent([
            "hook_event_name": "PostToolUse",
            "session_id": "child",
            "_herdr_pane_id": "child-pane",
            "_herdr_socket_path": "/tmp/child.sock",
            "_herdr_bin_path": "/tmp/herdr",
        ])

        fillMissingParentMetadataFromSubagentEvent(
            into: &sessions,
            sessionId: "parent",
            event: event
        )

        XCTAssertEqual(sessions["parent"]?.herdrPaneId, "existing-pane")
        XCTAssertEqual(sessions["parent"]?.herdrSocketPath, "/tmp/child.sock")
        XCTAssertEqual(sessions["parent"]?.herdrBinaryPath, "/tmp/herdr")
    }

    // MARK: - Helpers

    private func makeEvent(_ payload: [String: Any]) -> HookEvent {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return HookEvent(from: data)!
    }
}
