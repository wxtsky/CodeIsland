import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {

    // MARK: - Multi-question answers

    func testAskUserQuestionMultiQuestionReturnsQuestionsAndAnswers() async throws {
        let appState = AppState()
        let questions = [
            question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
            question(header: "输出风格", text: "你更喜欢我用哪种回答风格？", options: ["极简", "平衡"]),
        ]
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-1",
            questions: questions
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.answerQuestionMulti([
            (question: "你希望我接下来以哪种方式协作？", answer: "先给方案"),
            (question: "你更喜欢我用哪种回答风格？", answer: "平衡"),
        ])

        let responseData = await responseTask.value
        let updatedInput = try extractUpdatedInput(from: responseData)
        let returnedQuestions = try XCTUnwrap(updatedInput["questions"] as? [[String: Any]])
        XCTAssertEqual(returnedQuestions.count, questions.count)
        XCTAssertEqual(returnedQuestions[0]["question"] as? String, questions[0]["question"] as? String)
        XCTAssertEqual(returnedQuestions[1]["question"] as? String, questions[1]["question"] as? String)

        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["你希望我接下来以哪种方式协作？"] as? String, "先给方案")
        XCTAssertEqual(answers["你更喜欢我用哪种回答风格？"] as? String, "平衡")
    }

    // MARK: - Single question

    func testAskUserQuestionSingleQuestionWorks() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-2",
            questions: [
                question(header: "语言偏好", text: "你希望我主要使用哪种语言回复？", options: ["中文", "英文"])
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "你希望我主要使用哪种语言回复？", answer: "中文"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["你希望我主要使用哪种语言回复？"] as? String, "中文")
    }

    // MARK: - Skip returns deny

    func testSkipAskUserQuestionReturnsDeny() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-skip",
            questions: [
                question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.skipQuestion()

        let responseData = await responseTask.value
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    // MARK: - Disconnect drains with deny

    func testDisconnectDuringAskUserQuestionReturnsDeny() async throws {
        let appState = AppState()
        let sessionId = "s-disconnect"
        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.handlePeerDisconnect(sessionId: sessionId)

        let responseData = await responseTask.value
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    // MARK: - Permission queue does not overwrite

    func testTwoPermissionRequestsKeepFirstVisibleUntilHandled() async throws {
        let appState = AppState()
        let sessionId = "s-perm"

        let event1 = try makePermissionRequestEvent(
            sessionId: sessionId,
            description: "first approval",
            command: "echo 1"
        )
        let event2 = try makePermissionRequestEvent(
            sessionId: sessionId,
            description: "second approval",
            command: "echo 2"
        )

        let r1 = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event1, continuation: continuation)
            }
        }
        await Task.yield()

        let r2 = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event2, continuation: continuation)
            }
        }
        await Task.yield()

        XCTAssertEqual(appState.permissionQueue.count, 2)
        XCTAssertEqual(appState.currentTool, "Bash")
        XCTAssertEqual(appState.toolDescription, "first approval\nCommand:\necho 1")

        appState.approvePermission()
        let response1 = await r1.value
        XCTAssertEqual(try extractPermissionBehavior(from: response1), "allow")

        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.toolDescription, "second approval\nCommand:\necho 2")

        appState.denyPermission()
        let response2 = await r2.value
        XCTAssertEqual(try extractPermissionBehavior(from: response2), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPermissionRequestKeepsSessionListSurfaceWhenAlreadyOpen() async throws {
        let appState = AppState()
        appState.surface = .sessionList

        let event = try makePermissionRequestEvent(
            sessionId: "s-list",
            description: "needs approval",
            command: "echo 1"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handlePermissionRequest(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.surface, .sessionList)
        XCTAssertEqual(appState.permissionQueue.count, 1)

        appState.approvePermission()
        let response = await responseTask.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertEqual(appState.surface, .sessionList)
    }

    func testApprovalInlineSummaryPrefersToolDescriptionAndFallsBackToCommand() async throws {
        // Prefer toolDescription
        let withDesc = approvalInlineSummary(
            tool: "Bash",
            toolDescription: "needs approval",
            toolInput: ["command": "echo 1"]
        )
        XCTAssertEqual(withDesc, .text("needs approval"))

        // Empty description falls back to bash command
        let fallback = approvalInlineSummary(
            tool: "Bash",
            toolDescription: "   ",
            toolInput: ["command": "echo 2"]
        )
        XCTAssertEqual(fallback, .bashCommand("echo 2"))
    }

    // MARK: - Duplicate question text dedup

    func testDuplicateQuestionTextGetsDedupedKeys() async throws {
        // Answer keys are the question text (matching Claude Code's
        // `answers[question.question]` lookup). Two questions sharing the same
        // text get a suffixed key so each answer stays addressable.
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dup",
            questions: [
                question(header: "偏好", text: "重复的问题", options: ["A", "B"]),
                question(header: "其他", text: "重复的问题", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "重复的问题", answer: "A"),
            (question: "重复的问题", answer: "D"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["重复的问题"] as? String, "A")
        XCTAssertEqual(answers["重复的问题_2"] as? String, "D")
    }

    // MARK: - Answer key ignores header

    func testAnswerKeyUsesQuestionTextRegardlessOfHeader() async throws {
        // header used to be the answer key but no longer participates. Even
        // when header is nil or empty, the key stays the question text so
        // Claude Code's `answers[question.question]` lookup resolves.
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-nohdr",
            questions: [
                question(header: nil, text: "没有 header", options: ["A", "B"]),
                question(header: "", text: "空 header", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "没有 header", answer: "B"),
            (question: "空 header", answer: "C"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["没有 header"] as? String, "B")
        XCTAssertEqual(answers["空 header"] as? String, "C")
    }

    // MARK: - Direct answerQuestion blocked

    func testDirectAnswerQuestionIgnoredForAskUserQuestion() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-block",
            questions: [
                question(header: "Q1", text: "Question?", options: ["A", "B"]),
            ]
        )

        _ = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestion("A")
        XCTAssertEqual(appState.questionQueue.count, 1, "Queue should not be drained by direct answerQuestion")
    }

    // MARK: - iPhone Buddy question mirror

    func testAppleCompanionPayloadMirrorsPendingAskUserQuestion() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-companion-payload",
            questions: [
                question(
                    header: "小说类型",
                    text: "你想看什么类型的小说？",
                    options: ["都市/现实", "科幻/未来"],
                    descriptions: ["现代都市背景、职场、情感、生活故事", "未来世界、人工智能、太空探索、时间旅行"]
                ),
                question(header: "篇幅长度", text: "你希望多长？", options: ["短篇", "长篇"]),
            ]
        )

        _ = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()

        let payload = appState.appleCompanionStatePayload(sequence: 42)
        XCTAssertEqual(payload.sequence, 42)
        XCTAssertEqual(payload.sessionId, "s-companion-payload")
        XCTAssertEqual(payload.status, .waitingQuestion)
        XCTAssertEqual(payload.pendingAction, .question)
        XCTAssertEqual(payload.toolName, "AskUserQuestion")

        let question = try XCTUnwrap(payload.question)
        XCTAssertEqual(question.header, "小说类型")
        XCTAssertEqual(question.question, "你想看什么类型的小说？")
        XCTAssertEqual(question.options, ["都市/现实", "科幻/未来"])
        XCTAssertEqual(question.descriptions, ["现代都市背景、职场、情感、生活故事", "未来世界、人工智能、太空探索、时间旅行"])
        XCTAssertEqual(question.index, 1)
        XCTAssertEqual(question.total, 2)
        XCTAssertFalse(question.allowsMultipleSelection)
    }

    func testCompanionAnswerAdvancesAskUserQuestionAndCompletes() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-companion-answer",
            questions: [
                question(header: "工作模式", text: "你希望我接下来以哪种方式协作？", options: ["直接执行", "先给方案"]),
                question(header: "输出风格", text: "你更喜欢我用哪种回答风格？", options: ["极简", "平衡"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()

        appState.answerCompanionQuestion("直接执行")
        let secondPayload = appState.appleCompanionStatePayload(sequence: 43)
        let secondQuestion = try XCTUnwrap(secondPayload.question)
        XCTAssertEqual(secondQuestion.header, "输出风格")
        XCTAssertEqual(secondQuestion.index, 2)
        XCTAssertEqual(secondQuestion.total, 2)
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.answerCompanionQuestion("平衡")
        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["你希望我接下来以哪种方式协作？"] as? String, "直接执行")
        XCTAssertEqual(answers["你更喜欢我用哪种回答风格？"] as? String, "平衡")
        XCTAssertEqual(appState.questionQueue.count, 0)

        let completedPayload = appState.appleCompanionStatePayload(sequence: 44)
        XCTAssertNil(completedPayload.question)
        XCTAssertNil(completedPayload.pendingAction)
    }

    // MARK: - Helpers

    private func makeAskUserQuestionEvent(sessionId: String, questions: [[String: Any]]) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": questions
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStateQuestionFlowTests", code: 1)
        }
        return event
    }

    private func makePermissionRequestEvent(sessionId: String, description: String, command: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": [
                "command": command,
                "description": description,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStateQuestionFlowTests", code: 2)
        }
        return event
    }

    private func question(header: String?, text: String, options: [String], descriptions: [String]? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "question": text,
            "options": options.enumerated().map { index, option in
                ["label": option, "description": descriptions?[safe: index] ?? ""]
            }
        ]
        if let header {
            result["header"] = header
        }
        return result
    }

    private func extractUpdatedInput(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["updatedInput"] as? [String: Any])
    }

    private func extractAnswers(from responseData: Data) throws -> [String: Any] {
        let updatedInput = try extractUpdatedInput(from: responseData)
        return try XCTUnwrap(updatedInput["answers"] as? [String: Any])
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
