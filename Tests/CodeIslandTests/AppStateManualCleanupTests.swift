import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class AppStateManualCleanupTests: XCTestCase {
    private func session(_ status: AgentStatus) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.status = status
        return value
    }

    func testClearRemovesOnlyIdleAndDrainsCompletionQueue() {
        let app = AppState()
        app.sessions = ["idle": session(.idle), "running": session(.running),
            "thinking": session(.processing), "approval": session(.waitingApproval),
            "question": session(.waitingQuestion)]
        app.enqueueCompletion("idle")
        app.clearCompletedSessions()
        XCTAssertNil(app.sessions["idle"])
        XCTAssertEqual(Set(app.sessions.keys), ["running", "thinking", "approval", "question"])
        XCTAssertNotEqual(app.surface, .completionCard(sessionId: "idle"))
        XCTAssertNotNil(app.manuallyClearedSessions["idle"])
        app.clearCompletedSessions()
        XCTAssertEqual(app.sessions.count, 4)
    }

    func testLiveSubagentsProtectAnIdleParent() {
        let app = AppState()
        var parent = session(.idle)
        var child = SubagentState(agentId: "worker", agentType: "test")
        child.status = .running
        parent.subagents["worker"] = child
        app.sessions = ["parent": parent]
        app.clearCompletedSessions()
        XCTAssertNotNil(app.sessions["parent"])
    }

    func testFoldedChildrenAreKeptWithActiveParentAndClearedTogetherWhenIdle() {
        let app = AppState()
        var child = session(.idle)
        child.source = "catpaw"
        child.catpawIsSubagent = true
        child.catpawParentSessionID = "parent"
        app.sessions = ["parent": session(.processing), "child": child]
        app.clearCompletedSessions()
        XCTAssertEqual(app.sessions.count, 2)
        app.sessions["parent"]?.status = .idle
        app.clearCompletedSessions()
        XCTAssertTrue(app.sessions.isEmpty)
    }

    func testActiveCatPawChildProtectsParent() {
        let app = AppState()
        var child = session(.running)
        child.catpawParentSessionID = "parent"
        app.sessions = ["parent": session(.idle), "child": child]
        app.clearCompletedSessions()
        XCTAssertEqual(app.sessions.count, 2)
    }

    func testOldDiscoveryAndLateStopsDoNotRecreateClearedCards() throws {
        let app = AppState()
        app.sessions = ["cleared": session(.idle)]
        app.clearCompletedSessions()
        let clearedAt = try XCTUnwrap(app.manuallyClearedSessions["cleared"])
        let info = AppState.DiscoveredSession(sessionId: "cleared", cwd: "/nonexistent",
            tty: nil, model: nil, pid: nil, modifiedAt: clearedAt.addingTimeInterval(-1), recentMessages: [])
        app.integrateDiscovered([info])
        let raw: [String: Any] = ["hook_event_name": "Stop", "session_id": "cleared"]
        app.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw))))
        XCTAssertNil(app.sessions["cleared"])
        var fresh = AppState.DiscoveredSession(sessionId: "cleared", cwd: "/nonexistent",
            tty: nil, model: nil, pid: nil, modifiedAt: clearedAt.addingTimeInterval(1), recentMessages: [])
        fresh.source = "catpaw"
        XCTAssertFalse(app.shouldSuppressManuallyClearedDiscovery(fresh))
        XCTAssertNil(app.manuallyClearedSessions["cleared"])
    }

    func testNewPromptCanBringBackClearedSession() throws {
        let app = AppState()
        app.sessions = ["catpaw:chat": session(.idle)]
        app.clearCompletedSessions()
        let raw: [String: Any] = ["hook_event_name": "beforeSubmitPrompt", "conversation_id": "chat",
            "suggest_uuid": "new", "is_sub_agent": false, "prompt": "new task"]
        let normalized = try XCTUnwrap(CatPawHookPayload.normalized(raw))
        app.handleEvent(try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: normalized))))
        XCTAssertEqual(app.sessions["catpaw:chat"]?.status, .processing)
        XCTAssertNil(app.manuallyClearedSessions["catpaw:chat"])
    }

    func testPendingPermissionSurvivesEvenIfCardLooksIdle() async throws {
        let app = AppState()
        let raw: [String: Any] = ["hook_event_name": "PermissionRequest", "session_id": "waiting",
            "tool_name": "Bash", "tool_input": ["command": "echo test"]]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw)))
        let response = await startHookRequest { app.handlePermissionRequest(event, continuation: $0) }
        app.sessions["waiting"]?.status = .idle
        app.clearCompletedSessions()
        XCTAssertNotNil(app.sessions["waiting"])
        XCTAssertTrue(app.permissionQueue.contains { $0.event.sessionId == "waiting" })
        app.denyPermission(expectedSessionId: "waiting")
        _ = try await awaitValue(of: response)
    }
}
