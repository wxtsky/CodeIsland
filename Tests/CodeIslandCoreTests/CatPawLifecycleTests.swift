import XCTest
@testable import CodeIslandCore

final class CatPawLifecycleTests: XCTestCase {
    private var sessions: [String: SessionSnapshot] = [:]

    @discardableResult
    private func send(_ name: String, _ id: String, _ request: String, child: Bool = false,
                      source: String = "catpaw", pid: Int = 4759, status: String = "completed") throws -> [SideEffect] {
        let raw: [String: Any] = ["hook_event_name": name, "conversation_id": id,
            "suggest_uuid": request, "is_sub_agent": child, "agent_name": "Explorer",
            "_ppid": pid, "workspace_roots": ["/project"], "status": status, "text": request]
        let normalized = try XCTUnwrap(CatPawHookPayload.normalized(raw, source: source))
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: normalized)))
        return reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
    }

    func testConcurrentIDEReplayResolvesHistoryAndStopBeforeResponse() throws {
        try send("beforeSubmitPrompt", "root", "prompt")
        try send("afterAgentResponse", "root", "root-early")
        for child in ["yaml", "markdown", "shell"] {
            try send("beforeSubmitPrompt", child, "start-\(child)", child: true)
        }
        try send("afterAgentResponse", "yaml", "yaml-final", child: true)
        try send("afterAgentResponse", "shell", "shell-early", child: true)
        XCTAssertEqual(try send("stop", "root", "yaml-final"), [])
        XCTAssertEqual(sessions["catpaw:yaml"]?.status, .idle)
        try send("stop", "root", "markdown-final")
        XCTAssertEqual(sessions["catpaw:markdown"]?.status, .processing)
        let delayed = try send("afterAgentResponse", "markdown", "markdown-final", child: true)
        XCTAssertFalse(delayed.contains { if case .enqueueCompletion = $0 { return true }; return false })
        XCTAssertEqual(sessions["catpaw:markdown"]?.status, .idle)
        try send("stop", "root", "shell-early")
        try send("afterAgentResponse", "shell", "shell-final", child: true)
        XCTAssertEqual(sessions["catpaw:shell"]?.status, .idle)
        XCTAssertNil(sessions["catpaw:shell"]?.lastAssistantMessage)
        XCTAssertEqual(sessions["catpaw:root"]?.status, .processing)
        try send("beforeShellExecution", "root", "root-tool")
        XCTAssertEqual(sessions["catpaw:root"]?.status, .running)
        try send("afterShellExecution", "root", "root-tool")
        let done = try send("stop", "root", "root-early")
        XCTAssertEqual(done, [.enqueueCompletion(sessionId: "catpaw:root"), .playSound("Stop")])
        try send("afterAgentResponse", "root", "root-final")
        try send("beforeShellExecution", "root", "root-tool")
        XCTAssertEqual(sessions["catpaw:root"]?.status, .idle)
        XCTAssertEqual(sessions["catpaw:root"]?.lastAssistantMessage, "root-final")
        XCTAssertEqual(try send("stop", "root", "root-early"), [])
    }

    func testIDEKitHistoricalToolRequestEndsChildOnly() throws {
        let source = "catpaw-idekit"
        try send("beforeSubmitPrompt", "root", "start-root", source: source)
        try send("beforeSubmitPrompt", "child", "start-child", child: true, source: source)
        try send("beforeShellExecution", "child", "tool-request", child: true, source: source)
        try send("afterShellExecution", "child", "tool-request", child: true, source: source)
        try send("afterAgentResponse", "child", "new-response", child: true, source: source)
        XCTAssertEqual(try send("stop", "root", "tool-request", source: source), [])
        XCTAssertEqual(sessions["\(source):child"]?.status, .idle)
        XCTAssertEqual(sessions["\(source):root"]?.status, .processing)
    }

    func testUnknownFailureAndAmbiguousRequestsNeverComplete() throws {
        try send("beforeSubmitPrompt", "root", "root-start")
        try send("stop", "root", "unknown")
        for child in ["a", "b"] {
            try send("beforeSubmitPrompt", child, "shared", child: true)
        }
        XCTAssertEqual(try send("stop", "root", "shared"), [])
        XCTAssertEqual(try send("stop", "root", "root-start", status: "aborted"), [])
        XCTAssertEqual(try send("stop", "root", "root-start", status: "error"), [])
        XCTAssertTrue(sessions.values.allSatisfy { $0.status == .processing })
        XCTAssertEqual(try send("stop", "unseen", "new"), [])
        XCTAssertNil(sessions["catpaw:unseen"])
    }

    func testNewPromptRejectsOldRequestsAndClearsPendingStops() throws {
        try send("beforeSubmitPrompt", "root", "old")
        try send("stop", "root", "not-yet-seen")
        try send("beforeSubmitPrompt", "root", "new")
        XCTAssertEqual(try send("stop", "root", "old"), [])
        try send("afterAgentResponse", "root", "not-yet-seen")
        XCTAssertEqual(sessions["catpaw:root"]?.status, .processing)
        XCTAssertTrue(try send("stop", "root", "new").contains(.enqueueCompletion(sessionId: "catpaw:root")))
        try send("beforeSubmitPrompt", "root", "next")
        XCTAssertEqual(sessions["catpaw:root"]?.status, .processing)
    }

    func testSourcesHostsAndUnresolvedHostsCannotCrossAssociate() throws {
        try send("beforeSubmitPrompt", "root", "root", pid: 1)
        try send("beforeSubmitPrompt", "other-host", "foreign", child: true, pid: 2)
        try send("beforeSubmitPrompt", "other-source", "foreign", child: true, source: "catpaw-idekit", pid: 1)
        XCTAssertEqual(try send("stop", "root", "foreign", pid: 1), [])
        try send("beforeSubmitPrompt", "unresolved", "root-zero", pid: 0)
        try send("beforeSubmitPrompt", "child-zero", "zero", child: true, pid: 0)
        XCTAssertEqual(try send("stop", "unresolved", "zero", pid: 0), [])
        XCTAssertTrue(sessions.values.allSatisfy { $0.status == .processing })
    }

    func testLiveGroupingIsOnlyPresentationAndAmbiguousRootsRemainSeparate() throws {
        try send("beforeSubmitPrompt", "root", "root-start")
        try send("beforeSubmitPrompt", "child", "child-start", child: true)
        XCTAssertTrue(sessions["catpaw:child"]!.isFoldedCatPawChild(in: sessions))
        XCTAssertEqual(sessions["catpaw:root"]?.catpawChildrenRunning, 1)
        XCTAssertFalse(sessions["catpaw:child"]!.catpawLifecycle.parentConfirmed)
        try send("beforeSubmitPrompt", "root-2", "root-2-start")
        // Both roots now precede this new child; no unique display group.
        try send("beforeSubmitPrompt", "child-2", "child-2-start", child: true)
        XCTAssertFalse(sessions["catpaw:child-2"]!.isFoldedCatPawChild(in: sessions))
        try send("stop", "root-2", "child-2-start")
        XCTAssertEqual(sessions["catpaw:child-2"]?.catpawParentSessionID, "catpaw:root-2")
        XCTAssertEqual(sessions["catpaw:root-2"]?.catpawChildrenCompleted, 1)
    }

    func testUnknownStopCannotFinishWhileChildrenActiveOrAfterMoreWork() throws {
        try send("beforeSubmitPrompt", "root", "start")
        try send("beforeSubmitPrompt", "child", "child", child: true)
        try send("afterAgentResponse", "root", "progress")
        XCTAssertEqual(try send("stop", "root", "unknown"), [])
        XCTAssertEqual(sessions["catpaw:root"]?.status, .processing)
        try send("beforeShellExecution", "root", "tool")
        try send("afterShellExecution", "root", "tool")
        try send("stop", "root", "child")
        try send("afterAgentResponse", "root", "reply")
        // A pre-tool stop is not allowed to settle this later work.
        XCTAssertEqual(sessions["catpaw:root"]?.status, .processing)
        let effects = try send("stop", "root", "fresh-final")
        XCTAssertEqual(effects, [.enqueueCompletion(sessionId: "catpaw:root"), .playSound("Stop")])
        XCTAssertTrue(sessions["catpaw:root"]!.catpawLifecycle.completionInferred)
    }

    func testChildDetailsAreStrippedBeforeTransportAndNeverStored() throws {
        let raw: [String: Any] = ["hook_event_name": "afterAgentResponse", "conversation_id": "child",
            "is_sub_agent": true, "suggest_uuid": "request", "text": "secret reply",
            "prompt": "secret prompt", "command": "secret command", "output": "secret output",
            "unknown_content": "future private content", "attachments": ["file"], "tool_input": "secret"]
        let normalized = try XCTUnwrap(CatPawHookPayload.normalized(raw))
        for key in ["text", "prompt", "command", "output", "unknown_content", "attachments", "tool_input"] {
            XCTAssertNil(normalized[key], key)
        }
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: normalized)))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
        XCTAssertNil(sessions["catpaw:child"]?.lastAssistantMessage)
        XCTAssertTrue(sessions["catpaw:child"]!.recentMessages.isEmpty)
        XCTAssertTrue(sessions["catpaw:child"]!.toolHistory.isEmpty)
    }

    func testToolCwdDoesNotResetConversationEvidence() throws {
        try send("beforeSubmitPrompt", "root", "start")
        try send("beforeSubmitPrompt", "child", "child-start", child: true)
        let raw: [String: Any] = ["hook_event_name": "beforeShellExecution", "conversation_id": "child",
            "suggest_uuid": "tool", "is_sub_agent": true, "_ppid": 4759,
            "workspace_roots": ["/project"], "cwd": "/project/subfolder"]
        let normalized = try XCTUnwrap(CatPawHookPayload.normalized(raw))
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: normalized)))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
        try send("stop", "root", "child-start")
        XCTAssertEqual(sessions["catpaw:child"]?.status, .idle)
        XCTAssertTrue(sessions["catpaw:child"]!.catpawLifecycle.parentConfirmed)
    }
    // Sanitized event identities from the complete 2026-10-16 Hook capture.
    func testCapturedIDERun() throws {
        let source = "catpaw"
        let events: [(String, String, String, Bool)] = [
            ("beforeSubmitPrompt", "root", "e9a26af6-d2a0-4aba-a6e6-a1ea51903e71", false),
            ("beforeSubmitPrompt", "child-1", "5e723ca8-e1ca-4d8e-b98d-79252397d75c", true),
            ("beforeSubmitPrompt", "child-2", "6f17bfbb-17ec-4525-a180-f2979004f090", true),
            ("afterAgentResponse", "root", "983fde0a-9846-42ae-b36b-ccaf4673b8e2", false),
            ("beforeSubmitPrompt", "child-3", "0c0f56b8-4388-4575-96e9-0984fc4820b3", true),
            ("afterAgentResponse", "child-1", "c7404aac-57ca-4d68-9145-43dc3b6867f9", true),
            ("afterAgentResponse", "child-2", "76a1cb0c-6494-4998-b384-31f36d008fd8", true),
            ("afterAgentResponse", "child-3", "8324b672-379c-464b-b6ad-b51e43529a3e", true),
            ("afterAgentResponse", "child-2", "b64ed347-d365-4a29-96f3-c24cb3cc7f46", true),
            ("stop", "root", "b64ed347-d365-4a29-96f3-c24cb3cc7f46", false),
            ("stop", "root", "102e94bb-82e8-47cd-91ac-5753c31bfd1c", false),
            ("afterAgentResponse", "child-1", "102e94bb-82e8-47cd-91ac-5753c31bfd1c", true),
            ("stop", "root", "8324b672-379c-464b-b6ad-b51e43529a3e", false),
            ("afterAgentResponse", "child-3", "f92b449e-95fe-4851-904e-12cfba7e8d37", true),
            ("afterAgentResponse", "root", "63d53661-1b6a-498a-92a7-0fc2548ffb52", false),
            ("beforeShellExecution", "root", "63d53661-1b6a-498a-92a7-0fc2548ffb52", false),
            ("afterShellExecution", "root", "63d53661-1b6a-498a-92a7-0fc2548ffb52", false),
            ("stop", "root", "983fde0a-9846-42ae-b36b-ccaf4673b8e2", false),
            ("afterAgentResponse", "root", "ff44c0d7-d479-46b5-a1c7-13a3981f2f36", false),
        ]
        var completions: [SideEffect] = []
        for (name, id, request, child) in events {
            completions += try send(name, id, request, child: child, source: source).filter {
                if case .enqueueCompletion = $0 { return true }; return false
            }
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(sessions["\(source):root"]?.status, .idle)
        for (id, session) in sessions where id != "\(source):root" {
            XCTAssertEqual(session.status, .idle, id)
            XCTAssertNil(session.lastAssistantMessage)
        }
    }

    // Sanitized event identities from the complete 2026-10-16 Hook capture.
    func testCapturedIDEKitRun() throws {
        let source = "catpaw-idekit"
        let events: [(String, String, String, Bool)] = [
            ("beforeSubmitPrompt", "root", "db52b658-9180-4cd6-9b64-fc80c67414ec", false),
            ("afterAgentResponse", "root", "8dbe4eee-b9f0-46a5-bd0a-492347c8b998", false),
            ("beforeSubmitPrompt", "child-1", "0676b940-5012-4942-b155-c7159b111b4f", true),
            ("afterAgentResponse", "child-1", "ddfe4d4e-9409-484e-ba11-0b0b6e7a3449", true),
            ("beforeShellExecution", "child-1", "ddfe4d4e-9409-484e-ba11-0b0b6e7a3449", true),
            ("afterShellExecution", "child-1", "ddfe4d4e-9409-484e-ba11-0b0b6e7a3449", true),
            ("stop", "root", "ddfe4d4e-9409-484e-ba11-0b0b6e7a3449", false),
            ("afterAgentResponse", "child-1", "4febc3d6-5497-4c43-ad87-9e72ab39e32d", true),
            ("afterAgentResponse", "root", "e7ee1df7-ff06-46bf-b4da-1529ac1cea79", false),
            ("stop", "root", "9441c20c-eb74-4084-b657-b3c9cb81133c", false),
        ]
        var completions: [SideEffect] = []
        for (name, id, request, child) in events {
            completions += try send(name, id, request, child: child, source: source).filter {
                if case .enqueueCompletion = $0 { return true }; return false
            }
        }
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(sessions["\(source):root"]?.status, .idle)
        for (id, session) in sessions where id != "\(source):root" {
            XCTAssertEqual(session.status, .idle, id)
            XCTAssertNil(session.lastAssistantMessage)
        }
    }

    func testCapturedFourChildIDEKitRunCompletesAndFoldsWithoutDetails() throws {
        let source = "catpaw-idekit"
        let events: [(String, String, String, Bool)] = [
            ("beforeSubmitPrompt", "root", "c36367ee-3e05-4357-bf1b-4ea82de4c054", false),
            ("beforeSubmitPrompt", "child-1", "cf14a013-2e30-40cc-9c1b-2cd8bd773e90", true),
            ("beforeSubmitPrompt", "child-2", "7dfb2559-4d1c-4be1-bfe2-3b845bf8530b", true),
            ("beforeSubmitPrompt", "child-3", "547b199f-4094-47d9-abfb-c15f12796bf3", true),
            ("afterAgentResponse", "root", "84a4b18e-4584-4c72-b972-f73770a367a1", false),
            ("beforeSubmitPrompt", "child-4", "3a35a471-69bd-43a7-8fb7-188ccc8bbc90", true),
            ("beforeShellExecution", "child-1", "43756d03-8e8e-4562-86be-bb67c269a6d0", true),
            ("afterShellExecution", "child-1", "43756d03-8e8e-4562-86be-bb67c269a6d0", true),
            ("afterAgentResponse", "child-1", "43756d03-8e8e-4562-86be-bb67c269a6d0", true),
            ("beforeShellExecution", "child-1", "43756d03-8e8e-4562-86be-bb67c269a6d0", true),
            ("afterShellExecution", "child-1", "43756d03-8e8e-4562-86be-bb67c269a6d0", true),
            ("beforeShellExecution", "child-3", "aac7516f-5de5-4e8a-8499-c2aebecec095", true),
            ("beforeShellExecution", "child-3", "aac7516f-5de5-4e8a-8499-c2aebecec095", true),
            ("beforeShellExecution", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("afterShellExecution", "child-3", "aac7516f-5de5-4e8a-8499-c2aebecec095", true),
            ("afterShellExecution", "child-3", "aac7516f-5de5-4e8a-8499-c2aebecec095", true),
            ("afterShellExecution", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("beforeShellExecution", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("afterShellExecution", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("afterAgentResponse", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("beforeShellExecution", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("afterShellExecution", "child-4", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", true),
            ("afterAgentResponse", "child-1", "14ce7e32-d1c8-4864-8c9d-2cc91a1d5e3c", true),
            ("beforeShellExecution", "child-1", "14ce7e32-d1c8-4864-8c9d-2cc91a1d5e3c", true),
            ("afterShellExecution", "child-1", "14ce7e32-d1c8-4864-8c9d-2cc91a1d5e3c", true),
            ("beforeShellExecution", "child-3", "7a7ce655-9188-4eaa-a36a-9c2750b567b5", true),
            ("afterAgentResponse", "child-3", "7a7ce655-9188-4eaa-a36a-9c2750b567b5", true),
            ("afterShellExecution", "child-3", "7a7ce655-9188-4eaa-a36a-9c2750b567b5", true),
            ("stop", "root", "43756d03-8e8e-4562-86be-bb67c269a6d0", false),
            ("afterAgentResponse", "child-1", "1dc06a86-9173-4f3f-902d-d00bb4992af1", true),
            ("beforeShellExecution", "child-4", "7bfe9d58-7817-4963-a0dd-d504777b7714", true),
            ("afterShellExecution", "child-4", "7bfe9d58-7817-4963-a0dd-d504777b7714", true),
            ("afterAgentResponse", "child-4", "7bfe9d58-7817-4963-a0dd-d504777b7714", true),
            ("beforeShellExecution", "child-4", "7bfe9d58-7817-4963-a0dd-d504777b7714", true),
            ("afterShellExecution", "child-4", "7bfe9d58-7817-4963-a0dd-d504777b7714", true),
            ("stop", "root", "7a7ce655-9188-4eaa-a36a-9c2750b567b5", false),
            ("afterAgentResponse", "child-3", "b5b36ad0-10a3-4385-98cb-d6aa9b6c9020", true),
            ("afterAgentResponse", "child-2", "24c6ebbd-d9df-4e5e-a4ae-2e2b9a8e1ed6", true),
            ("beforeShellExecution", "child-2", "24c6ebbd-d9df-4e5e-a4ae-2e2b9a8e1ed6", true),
            ("afterShellExecution", "child-2", "24c6ebbd-d9df-4e5e-a4ae-2e2b9a8e1ed6", true),
            ("afterAgentResponse", "child-4", "cd791d1e-fd28-4ded-a640-643dc4d2dfc5", true),
            ("beforeShellExecution", "child-4", "cd791d1e-fd28-4ded-a640-643dc4d2dfc5", true),
            ("afterShellExecution", "child-4", "cd791d1e-fd28-4ded-a640-643dc4d2dfc5", true),
            ("afterAgentResponse", "child-2", "38899600-fc29-4d14-859f-3f6e42a5b889", true),
            ("beforeShellExecution", "child-2", "38899600-fc29-4d14-859f-3f6e42a5b889", true),
            ("afterShellExecution", "child-2", "38899600-fc29-4d14-859f-3f6e42a5b889", true),
            ("stop", "root", "8b0f9ef5-9950-4fee-adad-d848fb9fbca0", false),
            ("afterAgentResponse", "child-4", "9c6c4247-48da-4a7e-b1a6-a66b77b48dfd", true),
            ("afterAgentResponse", "child-2", "96ea42fb-d9f6-48bd-b0aa-f3e6cab783c4", true),
            ("stop", "root", "38899600-fc29-4d14-859f-3f6e42a5b889", false),
            ("stop", "root", "ee9af512-1faf-457b-9939-89d42df057b3", false),
            ("afterAgentResponse", "root", "e02778e4-4cfe-4748-a73e-2c3a27377d7d", false),
        ]
        var completions = 0
        for (name, id, request, child) in events {
            completions += try send(name, id, request, child: child, source: source).filter {
                if case .enqueueCompletion = $0 { return true }; return false
            }.count
        }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(sessions["catpaw-idekit:root"]?.status, .idle)
        XCTAssertEqual(sessions["catpaw-idekit:root"]?.catpawChildrenCompleted, 4)
        XCTAssertEqual(sessions["catpaw-idekit:root"]?.catpawChildrenRunning, 0)
        XCTAssertEqual(sessions.filter { !$0.value.isFoldedCatPawChild(in: sessions) }.count, 1)
        for child in sessions.values where child.catpawIsSubagent {
            XCTAssertEqual(child.status, .idle)
            XCTAssertNil(child.lastUserPrompt)
            XCTAssertNil(child.lastAssistantMessage)
            XCTAssertTrue(child.recentMessages.isEmpty)
            XCTAssertTrue(child.toolHistory.isEmpty)
        }
    }

}
