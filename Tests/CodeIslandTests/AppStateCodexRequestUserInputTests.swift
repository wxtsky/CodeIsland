import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Issue #209 — Codex plan-mode `item/tool/requestUserInput` requests must reach
/// the popup (they used to be dropped because only `.notification` was handled).
@MainActor
final class AppStateCodexRequestUserInputTests: XCTestCase {

    private func makeRequest(threadId: String, questions: [[String: Any]], id: Any = "req-1") -> CodexJSONRPCMessage {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "item/tool/requestUserInput",
            "params": [
                "threadId": threadId,
                "turnId": "turn-1",
                "itemId": "item-1",
                "questions": questions,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: body)
        return CodexAppServerClient.parseMessage(data)!
    }

    func testRequestUserInputEnqueuesQuestionWithOptionsAndAnswerKey() {
        let appState = AppState()
        let message = makeRequest(threadId: "t-209", questions: [[
            "id": "q1",
            "header": "Plan",
            "question": "Which approach should I take?",
            "isOther": false,
            "isSecret": false,
            "options": [
                ["label": "Refactor", "description": "Clean up first"],
                ["label": "Patch", "description": "Minimal change"],
            ],
        ]])

        appState.handleCodexAppServerMessage(message)

        XCTAssertEqual(appState.questionQueue.count, 1)
        let pending = appState.pendingQuestion
        XCTAssertEqual(pending?.event.sessionId, "codexapp:t-209")
        XCTAssertTrue(pending?.isCodexAppServer == true)
        XCTAssertEqual(pending?.question.question, "Which approach should I take?")
        XCTAssertEqual(pending?.question.header, "Plan")
        XCTAssertEqual(pending?.question.options, ["Refactor", "Patch"])
        XCTAssertEqual(pending?.askUserQuestionState?.items.first?.answerKey, "q1")
    }

    func testRequestUserInputDroppedNotificationPathDoesNotEnqueue() {
        // Regression guard for the original bug: a request (has an id) must NOT be
        // misrouted as a notification and silently dropped.
        let appState = AppState()
        let message = makeRequest(threadId: "t-dup", questions: [[
            "id": "q1", "question": "Pick one", "options": [["label": "A", "description": ""]],
        ]])
        appState.handleCodexAppServerMessage(message)
        XCTAssertEqual(appState.questionQueue.count, 1)
    }

    func testAnsweringCodexQuestionDequeuesWithoutCrashWhenNoClient() {
        // No live client in tests — the reply closure guards on `client == nil`,
        // so answering must still dequeue cleanly through the wizard path.
        let appState = AppState()
        let message = makeRequest(threadId: "t-answer", questions: [[
            "id": "q1", "question": "Pick", "options": [["label": "A", "description": ""]],
        ]])
        appState.handleCodexAppServerMessage(message)
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.answerQuestionMulti([(question: "Pick", answer: "A")])
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    /// The Codex branches used to be reachable only at the head of the queue.
    /// Session-addressed answers can land on any index, so a Codex request
    /// queued behind another session's question must still reply over the
    /// JSON-RPC path rather than the hook path. (#308)
    func testCodexQuestionIsAnsweredWhileQueuedBehindAnotherSession() async throws {
        let appState = AppState()

        let hookPayload: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "s-hook",
            "question": "First?",
            "options": ["A", "B"],
        ]
        let hookEvent = try XCTUnwrap(
            HookEvent(from: try JSONSerialization.data(withJSONObject: hookPayload))
        )
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(hookEvent, continuation: $0) }
        }
        await Task.yield()

        // Enqueued with a capturing reply closure rather than through the live
        // client: dequeuing is not the half that was at risk. A head-anchored
        // Codex check sends the answer down the hook path while the indexed
        // remove still dequeues it — the queue looks identical and the Codex
        // server waits forever. Only invoking this closure proves which path ran.
        var repliedAnswers: [String: [String]]?
        var replyCalled = false
        let codexEvent = try XCTUnwrap(
            HookEvent(from: try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "Notification",
                "session_id": "codexapp:t-behind",
            ]))
        )
        let payload = QuestionPayload(question: "Pick", options: ["A"], header: "Plan")
        appState.questionQueue.append(QuestionRequest(
            event: codexEvent,
            question: payload,
            resolution: .codexAppServer { answers in
                replyCalled = true
                repliedAnswers = answers
            },
            askUserQuestionState: AskUserQuestionState(
                items: [AskUserQuestionItem(payload: payload, answerKey: "q1", multiSelect: false)],
                answers: [:]
            )
        ))
        XCTAssertEqual(appState.questionQueue.count, 2)
        XCTAssertTrue(appState.questionQueue[1].isCodexAppServer)

        appState.answerQuestionMulti(
            [(question: "Pick", answer: "A")],
            expectedSessionId: "codexapp:t-behind"
        )

        XCTAssertEqual(
            appState.questionQueue.map { $0.event.sessionId },
            ["s-hook"],
            "the Codex request must be the one dequeued, and the hook question must stay queued"
        )
        XCTAssertTrue(replyCalled, "the reply must go out over the Codex JSON-RPC path, not the hook path")
        XCTAssertEqual(repliedAnswers?["q1"], ["A"])
    }

    func testServerRequestResolvedDropsQueuedQuestion() {
        let appState = AppState()
        let message = makeRequest(threadId: "t-resolve", questions: [[
            "id": "q1", "question": "Pick", "options": [["label": "A", "description": ""]],
        ]])
        appState.handleCodexAppServerMessage(message)
        XCTAssertEqual(appState.questionQueue.count, 1)

        let resolved = CodexAppServerClient.parseMessage(Data(
            #"{"jsonrpc":"2.0","method":"serverRequest/resolved","params":{"threadId":"t-resolve","requestId":"req-1"}}"#.utf8
        ))!
        appState.handleCodexAppServerMessage(resolved)
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    func testReplyResultEncodesAnswersByQuestionId() {
        let result = AppState.codexRequestUserInputResult(answersByKey: ["q1": ["Refactor"]])
        let answers = result["answers"] as? [String: Any]
        let q1 = answers?["q1"] as? [String: Any]
        XCTAssertEqual(q1?["answers"] as? [String], ["Refactor"])
    }

    func testReplyResultForSkipIsEmptyAnswers() {
        let result = AppState.codexRequestUserInputResult(answersByKey: nil)
        let answers = result["answers"] as? [String: Any]
        XCTAssertEqual(answers?.isEmpty, true)
    }

    func testSecretQuestionIsMarkedSecret() {
        let appState = AppState()
        let message = makeRequest(threadId: "t-secret", questions: [[
            "id": "q1", "question": "API key?", "isSecret": true, "options": NSNull(),
        ]])
        appState.handleCodexAppServerMessage(message)
        XCTAssertEqual(appState.pendingQuestion?.question.isSecret, true)
    }
}
