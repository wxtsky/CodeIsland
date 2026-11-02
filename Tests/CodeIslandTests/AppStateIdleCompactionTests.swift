import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// A compaction Claude Code runs for an idle session must not bring back a
/// card the idle sweep already removed, nor wake a finished one.
@MainActor
final class AppStateIdleCompactionTests: XCTestCase {
    private func hook(_ payload: [String: Any]) throws -> HookEvent {
        var payload = payload
        payload["session_id"] = "finished-session"
        payload["_source"] = "claude"
        payload["cwd"] = "/tmp/project"
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    /// What Claude Code sends for one: the PreCompact, the stop of the agent
    /// writing the summary, and — where it applies the summary at once —
    /// the conversation starting over from it.
    private var backgroundCompaction: [[String: Any]] {
        [
            ["hook_event_name": "PreCompact", "trigger": "auto"],
            ["hook_event_name": "SubagentStop", "agent_id": "compactor-agent", "agent_type": ""],
            ["hook_event_name": "SessionStart", "source": "compact"],
        ]
    }

    func testBackgroundCompactionDoesNotBringBackARemovedCard() throws {
        let appState = AppState()

        for payload in backgroundCompaction {
            appState.handleEvent(try hook(payload))
            XCTAssertNil(appState.sessions["finished-session"], "\(payload)")
        }
        XCTAssertEqual(appState.surface, .collapsed)
    }

    /// The finished card keeps its reply, stays idle, and its idle clock runs
    /// on: the compaction is no activity of the user's session.
    func testBackgroundCompactionLeavesAFinishedCardAsItWas() throws {
        let appState = AppState()
        appState.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "prompt": "upgrade the engine"]))
        appState.handleEvent(try hook(["hook_event_name": "Stop", "last_assistant_message": "Upgrade done."]))
        let finishedAt = Date(timeIntervalSinceNow: -54 * 60)
        appState.sessions["finished-session"]?.lastActivity = finishedAt

        for payload in backgroundCompaction {
            appState.handleEvent(try hook(payload))
            let card = try XCTUnwrap(appState.sessions["finished-session"], "\(payload)")
            XCTAssertEqual(card.status, .idle, "\(payload)")
            XCTAssertEqual(card.lastActivity, finishedAt, "\(payload)")
            XCTAssertEqual(card.lastAssistantMessage, "Upgrade done.", "\(payload)")
        }

        // The user's next prompt is a turn as ever.
        appState.handleEvent(try hook(["hook_event_name": "UserPromptSubmit", "prompt": "now the docs"]))
        XCTAssertEqual(appState.sessions["finished-session"]?.status, .processing)
    }

    func testManualCompactStillOpensACard() throws {
        let appState = AppState()

        appState.handleEvent(try hook(["hook_event_name": "PreCompact", "trigger": "manual"]))

        XCTAssertEqual(appState.sessions["finished-session"]?.status, .processing)
    }
}
