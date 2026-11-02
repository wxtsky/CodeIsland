import XCTest
import CodeIslandCore
@testable import CodeIsland

@MainActor
final class AppStateIdleSessionRemovalTests: XCTestCase {
    private func session(_ status: AgentStatus, parent: String? = nil) -> SessionSnapshot {
        var value = SessionSnapshot()
        value.status = status
        value.parentSessionId = parent
        return value
    }

    func testRemovalKeepsNonIdleCardsAndDrainsCompletionCard() {
        let app = AppState()
        app.sessions = [
            "idle": session(.idle),
            "running": session(.running),
            "thinking": session(.processing),
            "approval": session(.waitingApproval),
        ]
        app.surface = .completionCard(sessionId: "idle")

        app.removeIdleSessions()

        XCTAssertNil(app.sessions["idle"])
        XCTAssertEqual(Set(app.sessions.keys), ["running", "thinking", "approval"])
        XCTAssertNotEqual(app.surface, .completionCard(sessionId: "idle"))
        XCTAssertNotNil(app.manuallyRemovedSessions["idle"])
    }

    func testParentAndChildAreRemovedAtomically() {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]

        let selection = app.idleSessionRemovalSelection
        XCTAssertEqual(selection.groups, [Set(["parent", "child"])])
        app.removeIdleSessions(selection: selection)

        XCTAssertTrue(app.sessions.isEmpty)
    }

    func testActiveChildRetainsWholeGroup() {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.running, parent: "parent")]

        XCTAssertTrue(app.idleSessionRemovalSelection.isEmpty)
        app.removeIdleSessions()

        XCTAssertEqual(Set(app.sessions.keys), ["parent", "child"])
    }

    func testPendingRequestOnChildRetainsWholeGroup() async throws {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        let raw: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "child",
            "tool_name": "Bash", "tool_input": ["command": "echo test"],
        ]
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw)))
        let response = await startHookRequest { app.handlePermissionRequest(event, continuation: $0) }
        app.sessions["child"]?.status = .idle

        XCTAssertTrue(app.idleSessionRemovalSelection.isEmpty)
        app.denyPermission(expectedSessionId: "child")
        _ = try await awaitValue(of: response)
    }

    func testEmbeddedLiveSubagentRetainsParent() {
        let app = AppState()
        var parent = session(.idle)
        var child = SubagentState(agentId: "worker", agentType: "test")
        child.status = .running
        parent.subagents["worker"] = child
        app.sessions = ["parent": parent]

        XCTAssertTrue(app.idleSessionRemovalSelection.isEmpty)
    }

    func testChecklistInProgressDoesNotPretendTheAgentIsRunning() {
        let app = AppState()
        var idle = session(.idle)
        idle.agentTasks.apply(.replace(opId: "old", items: [
            AgentTaskDraft(title: "Stale checklist item", status: .inProgress),
        ]), now: Date())
        app.sessions = ["idle": idle]

        XCTAssertEqual(app.idleSessionRemovalSelection.sessionIDs, ["idle"])
    }

    func testNewChildDuringConfirmationRetainsOriginalGroup() {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        let selected = app.idleSessionRemovalSelection
        app.sessions["late-child"] = session(.idle, parent: "parent")

        app.removeIdleSessions(selection: selected)

        XCTAssertEqual(Set(app.sessions.keys), ["parent", "child", "late-child"])
    }

    func testStatusChangeDuringConfirmationRetainsWholeGroupAndNewlyIdleGroupIsNotAdded() {
        let app = AppState()
        app.sessions = [
            "parent": session(.idle),
            "child": session(.idle, parent: "parent"),
            "other": session(.running),
        ]
        let selected = app.idleSessionRemovalSelection
        app.sessions["child"]?.status = .running
        app.sessions["other"]?.status = .idle

        app.removeIdleSessions(selection: selected)

        XCTAssertEqual(Set(app.sessions.keys), ["parent", "child", "other"])
    }

    func testParentCycleIsCycleSafeAndAtomic() {
        let app = AppState()
        app.sessions = ["a": session(.idle, parent: "b"), "b": session(.idle, parent: "a")]

        XCTAssertEqual(app.idleSessionRemovalSelection.groups, [Set(["a", "b"])])
    }

    func testPassiveInputsStaySuppressedUntilRealActivity() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()

        var rediscovered = DiscoveredSession(
            sessionId: "removed", cwd: "/nonexistent", tty: nil, model: nil, pid: nil,
            modifiedAt: Date().addingTimeInterval(60), recentMessages: []
        )
        rediscovered.status = .idle
        app.integrateDiscovered([rediscovered])
        let stop = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": "removed",
        ])))
        app.handleEvent(stop)

        XCTAssertNil(app.sessions["removed"])
        XCTAssertNotNil(app.manuallyRemovedSessions["removed"])

        rediscovered.status = .processing
        app.integrateDiscovered([rediscovered])
        XCTAssertNotNil(app.sessions["removed"])
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    func testNewPromptRevivesRemovedSession() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "removed", "prompt": "new task",
        ])))

        app.handleEvent(event)

        XCTAssertEqual(app.sessions["removed"]?.status, .processing)
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    func testActivityFromOneRemovedGroupMemberReleasesTheWholeGroup() throws {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        app.removeIdleSessions()
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "child", "prompt": "continue",
        ])))

        app.handleEvent(event)

        XCTAssertNil(app.manuallyRemovedSessions["parent"])
        XCTAssertNil(app.manuallyRemovedSessions["child"])
    }

    func testPassiveAiWorkHydrateDoesNotReviveButActiveStreamDoes() {
        let app = AppState()
        let key = AppState.aiworkSessionPrefix + "acp:coder:removed"
        app.sessions = [key: session(.idle)]
        app.removeIdleSessions()

        app.applyAiWorkHydrate(
            key: key,
            daemonSessionId: "acp:coder:removed",
            entry: ["status": .string("idle")]
        )
        XCTAssertNil(app.sessions[key])

        let frame = AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","event":{"name":"stream.started"},"data":{"session":{"session_id":"acp:coder:removed"}},"meta":{"session_id":"acp:coder:removed"}}
        """#.utf8))!
        app.handleAiWorkStreamEvent(name: "stream.started", frame: frame, agentId: "coder")

        XCTAssertNotNil(app.sessions[key])
        XCTAssertNil(app.manuallyRemovedSessions[key])
    }

    // MARK: - Requests always surface, and the card that comes back hears its hooks

    private func hook(_ raw: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: raw)))
    }

    /// AskUserQuestion reaches its own handler, not handleEvent: it used to
    /// rebuild the card but leave the tombstone, so the rest of the turn —
    /// PostToolUse, Stop — was dropped as passive and the card hung.
    func testAQuestionBringsTheCardBackAndTheRestOfItsTurnReachesIt() async throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()
        let ask = try hook([
            "hook_event_name": "PermissionRequest", "session_id": "removed", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [["question": "Ship it?", "options": [["label": "Yes"], ["label": "No"]]]]],
        ])
        let response = await startHookRequest { app.handleAskUserQuestion(ask, continuation: $0) }

        XCTAssertEqual(app.questionQueue.count, 1)
        XCTAssertNotNil(app.sessions["removed"])
        XCTAssertNil(app.manuallyRemovedSessions["removed"])

        app.handleEvent(try hook([
            "hook_event_name": "Stop", "session_id": "removed", "last_assistant_message": "Shipped.",
        ]))
        XCTAssertEqual(app.sessions["removed"]?.lastAssistantMessage, "Shipped.")
        _ = try await awaitValue(of: response)
    }

    func testATerminalPermissionPromptBringsTheCardBack() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()

        app.handleEvent(try hook([
            "hook_event_name": "Notification", "session_id": "removed", "notification_type": "idle_prompt",
            "message": "Claude is waiting for your input",
        ]))
        XCTAssertNil(app.sessions["removed"], "the idle reminder trails the finished turn")

        app.handleEvent(try hook([
            "hook_event_name": "Notification", "session_id": "removed", "notification_type": "permission_prompt",
            "message": "Claude needs your permission to use Bash",
        ]))
        XCTAssertEqual(app.sessions["removed"]?.status, .waitingApproval)
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    func testACodexAppServerQuestionBringsTheCardBack() throws {
        let app = AppState()
        app.sessions = ["codexapp:t-removed": session(.idle)]
        app.removeIdleSessions()
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": "req-1", "method": "item/tool/requestUserInput",
            "params": ["threadId": "t-removed", "turnId": "turn-1", "itemId": "item-1",
                       "questions": [["id": "q1", "question": "Pick one", "options": [["label": "A", "description": ""]]]]],
        ]
        let message = try XCTUnwrap(CodexAppServerClient.parseMessage(JSONSerialization.data(withJSONObject: body)))

        app.handleCodexAppServerMessage(message)

        XCTAssertEqual(app.questionQueue.count, 1)
        XCTAssertEqual(app.sessions["codexapp:t-removed"]?.status, .waitingQuestion)
        XCTAssertNil(app.manuallyRemovedSessions["codexapp:t-removed"])
    }

    /// A /compact the user types is their session at work again.
    func testAManualCompactBringsTheCardBack() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()

        app.handleEvent(try hook(["hook_event_name": "PreCompact", "session_id": "removed", "trigger": "manual"]))

        XCTAssertEqual(app.sessions["removed"]?.status, .processing)
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    /// Claude Code compacting the finished session in the background is not
    /// (#388): the card stays removed, and its tombstone with it, so the
    /// next discovery scan doesn't bring it back either.
    func testABackgroundCompactionLeavesARemovedCardRemoved() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()

        for payload: [String: Any] in [
            ["hook_event_name": "PreCompact", "trigger": "auto"],
            ["hook_event_name": "SubagentStop", "agent_id": "compactor-agent", "agent_type": ""],
            ["hook_event_name": "SessionStart", "source": "compact"],
        ] {
            var payload = payload
            payload["session_id"] = "removed"
            payload["_source"] = "claude"
            app.handleEvent(try hook(payload))
            XCTAssertNil(app.sessions["removed"], "\(payload)")
            XCTAssertNotNil(app.manuallyRemovedSessions["removed"], "\(payload)")
        }

        var rediscovered = DiscoveredSession(
            sessionId: "removed", cwd: "/nonexistent", tty: nil, model: nil, pid: nil,
            modifiedAt: Date().addingTimeInterval(60), recentMessages: []
        )
        rediscovered.status = .idle
        app.integrateDiscovered([rediscovered])
        XCTAssertNil(app.sessions["removed"])
    }

    /// Whatever brings a card back — a Cursor fold creating its parent, a
    /// path that never asked — its tombstone must not keep its hooks away.
    func testACardBackByAnyOtherWayHearsItsHooks() throws {
        let app = AppState()
        app.sessions = ["parent": session(.idle), "child": session(.idle, parent: "parent")]
        app.removeIdleSessions()
        app.sessions["parent"] = session(.idle)

        app.handleEvent(try hook([
            "hook_event_name": "Stop", "session_id": "parent", "last_assistant_message": "Done.",
        ]))

        XCTAssertEqual(app.sessions["parent"]?.lastAssistantMessage, "Done.")
        XCTAssertNil(app.manuallyRemovedSessions["parent"])
        XCTAssertNil(app.manuallyRemovedSessions["child"], "the group comes back together")
    }

    /// A scan that read the store before the click says nothing about now,
    /// whatever status it read.
    func testDiscoveryFromBeforeTheRemovalCannotBringTheCardBack() throws {
        let app = AppState()
        app.sessions = ["removed": session(.idle)]
        app.removeIdleSessions()
        let removedAt = try XCTUnwrap(app.manuallyRemovedSessions["removed"])
        func discovered(at date: Date) -> DiscoveredSession {
            var info = DiscoveredSession(
                sessionId: "removed", cwd: "/nonexistent", tty: nil, model: nil, pid: nil,
                modifiedAt: date, recentMessages: []
            )
            info.status = .processing
            return info
        }

        app.integrateDiscovered([discovered(at: removedAt.addingTimeInterval(-2))])
        XCTAssertNil(app.sessions["removed"])
        XCTAssertNotNil(app.manuallyRemovedSessions["removed"])

        app.integrateDiscovered([discovered(at: removedAt.addingTimeInterval(2))])
        XCTAssertEqual(app.sessions["removed"]?.status, .processing)
        XCTAssertNil(app.manuallyRemovedSessions["removed"])
    }

    /// The AiWork sweep forgets a card's hydrate; every removal now does, so a
    /// card that comes back gets its title, folder and client again.
    func testARemovedAiWorkCardIsHydratedAgainWhenItComesBack() {
        let app = AppState()
        let daemonId = "acp:coder:removed"
        var card = session(.idle)
        card.providerSessionId = daemonId
        app.sessions = [AppState.aiworkSessionPrefix + daemonId: card]
        XCTAssertTrue(app.beginAiWorkHydrateAttempt(daemonId))
        XCTAssertFalse(app.beginAiWorkHydrateAttempt(daemonId))

        app.removeIdleSessions()

        XCTAssertTrue(app.beginAiWorkHydrateAttempt(daemonId))
    }

    // MARK: - The confirmation banner

    func testTheBannerAsksOnlyOnTheSessionListAndGoesWithIt() {
        let app = AppState()
        app.sessions = ["idle": session(.idle), "running": session(.running)]
        app.surface = .completionCard(sessionId: "idle")
        app.toggleIdleSessionRemovalRequest()
        XCTAssertNil(app.idleSessionRemovalRequest)

        app.surface = .sessionList
        app.toggleIdleSessionRemovalRequest()
        XCTAssertEqual(app.pendingIdleSessionRemoval?.sessionIDs, ["idle"])

        app.surface = .collapsed
        XCTAssertNil(app.idleSessionRemovalRequest)
        XCTAssertEqual(Set(app.sessions.keys), ["idle", "running"])
    }

    func testTheButtonAgainPutsTheBannerAway() {
        let app = AppState()
        app.sessions = ["idle": session(.idle)]
        app.surface = .sessionList
        app.toggleIdleSessionRemovalRequest()
        XCTAssertNotNil(app.pendingIdleSessionRemoval)

        app.toggleIdleSessionRemovalRequest()

        XCTAssertNil(app.idleSessionRemovalRequest)
        XCTAssertNotNil(app.sessions["idle"])
    }

    /// Before the next refresh drops a request whose cards all came back, a
    /// click must open a banner for what is idle now, not just clear it.
    func testTheButtonAsksAfreshOverARequestWhoseCardsCameBack() {
        let app = AppState()
        app.sessions = ["a": session(.idle), "b": session(.running)]
        app.surface = .sessionList
        app.toggleIdleSessionRemovalRequest()
        app.sessions["a"]?.status = .running
        app.sessions["b"]?.status = .idle
        XCTAssertNil(app.pendingIdleSessionRemoval)

        app.toggleIdleSessionRemovalRequest()

        XCTAssertEqual(app.pendingIdleSessionRemoval?.sessionIDs, ["b"])
    }

    func testConfirmingRemovesOnlyWhatIsStillIdle() {
        let app = AppState()
        app.sessions = ["a": session(.idle), "b": session(.idle), "running": session(.running)]
        app.surface = .sessionList
        app.toggleIdleSessionRemovalRequest()
        app.sessions["b"]?.status = .processing

        XCTAssertEqual(app.pendingIdleSessionRemoval?.cardCount, 1)
        app.confirmIdleSessionRemoval()

        XCTAssertEqual(Set(app.sessions.keys), ["b", "running"])
        XCTAssertNil(app.idleSessionRemovalRequest)
    }

    func testABannerWhoseCardsCameBackDoesNotReturnWhenTheyGoIdleAgain() {
        let app = AppState()
        app.sessions = ["a": session(.idle)]
        app.surface = .sessionList
        app.toggleIdleSessionRemovalRequest()
        app.sessions["a"]?.status = .running
        XCTAssertNil(app.pendingIdleSessionRemoval)
        app.refreshDerivedState()

        app.sessions["a"]?.status = .idle
        app.refreshDerivedState()

        XCTAssertNil(app.pendingIdleSessionRemoval, "the click was about a card that has worked since")
    }

    func testARequestWhileTheBannerIsUpKeepsItsCard() async throws {
        let app = AppState()
        app.sessions = ["asker": session(.idle), "other": session(.idle)]
        let selection = app.idleSessionRemovalSelection
        let request = try hook([
            "hook_event_name": "PermissionRequest", "session_id": "asker",
            "tool_name": "Bash", "tool_input": ["command": "make deploy"],
        ])
        let response = await startHookRequest { app.handlePermissionRequest(request, continuation: $0) }
        app.sessions["asker"]?.status = .idle

        app.removeIdleSessions(selection: selection)

        XCTAssertNotNil(app.sessions["asker"])
        XCTAssertNil(app.sessions["other"])
        app.denyPermission(expectedSessionId: "asker")
        _ = try await awaitValue(of: response)
    }
}
