import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {

    // MARK: - Multi-question answers

    func testAskUserQuestionMultiQuestionReturnsAllAnswers() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-1",
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
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.answerQuestionMulti([
            (question: "你希望我接下来以哪种方式协作？", answer: "先给方案"),
            (question: "你更喜欢我用哪种回答风格？", answer: "平衡"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["工作模式"] as? String, "先给方案")
        XCTAssertEqual(answers["输出风格"] as? String, "平衡")
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
        XCTAssertEqual(answers["语言偏好"] as? String, "中文")
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
        XCTAssertEqual(appState.toolDescription, "first approval")

        appState.approvePermission()
        let response1 = await r1.value
        XCTAssertEqual(try extractPermissionBehavior(from: response1), "allow")

        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.toolDescription, "second approval")

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

    // MARK: - Duplicate headers dedup

    func testDuplicateHeadersGetDedupedKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dup",
            questions: [
                question(header: "偏好", text: "第一个问题", options: ["A", "B"]),
                question(header: "偏好", text: "第二个问题", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "第一个问题", answer: "A"),
            (question: "第二个问题", answer: "D"),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["偏好"] as? String, "A")
        XCTAssertEqual(answers["偏好_2"] as? String, "D")
    }

    // MARK: - Missing/empty header fallback

    func testMissingHeaderUsesIndexedFallbackKeys() async throws {
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
        XCTAssertEqual(answers["answer_1"] as? String, "B")
        XCTAssertEqual(answers["answer_2"] as? String, "C")
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

    private func question(header: String?, text: String, options: [String]) -> [String: Any] {
        var result: [String: Any] = [
            "question": text,
            "options": options.map { ["label": $0, "description": ""] }
        ]
        if let header {
            result["header"] = header
        }
        return result
    }

    private func extractAnswers(from responseData: Data) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any])
        return try XCTUnwrap(updatedInput["answers"] as? [String: Any])
    }

    private func extractPermissionBehavior(from responseData: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let hookSpecificOutput = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
