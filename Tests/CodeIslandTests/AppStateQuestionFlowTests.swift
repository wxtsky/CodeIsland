import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {
    func testAskUserQuestionAdvancesToNextQuestionBeforeFinalResponse() async throws {
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
        XCTAssertEqual(appState.pendingQuestion?.question.question, "你希望我接下来以哪种方式协作？")

        appState.selectAskUserQuestionOption(questionIndex: 0, option: "先给方案")
        XCTAssertFalse(appState.canConfirmAskUserQuestion)

        appState.selectAskUserQuestionOption(questionIndex: 1, option: "平衡")
        XCTAssertTrue(appState.canConfirmAskUserQuestion)

        appState.confirmAskUserQuestionAnswers()

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["工作模式"] as? String, "先给方案")
        XCTAssertEqual(answers["输出风格"] as? String, "平衡")
    }

    func testAskUserQuestionSingleQuestionStillReturnsAnswerMap() async throws {
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
        XCTAssertFalse(appState.canConfirmAskUserQuestion)
        appState.selectAskUserQuestionOption(questionIndex: 0, option: "中文")
        XCTAssertTrue(appState.canConfirmAskUserQuestion)
        appState.confirmAskUserQuestionAnswers()

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["语言偏好"] as? String, "中文")
    }

    func testSkipAskUserQuestionReturnsDenyAndClearsQueue() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-skip",
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
        appState.skipQuestion()

        let responseData = await responseTask.value
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    func testDisconnectDuringAskUserQuestionReturnsDenyAndClearsQueue() async throws {
        let appState = AppState()
        let sessionId = "s-disconnect"
        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
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
        appState.handlePeerDisconnect(sessionId: sessionId)

        let responseData = await responseTask.value
        let behavior = try extractPermissionBehavior(from: responseData)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    func testAskUserQuestionDuplicateHeadersDoNotOverwriteAnswers() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-dup-header",
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
        appState.selectAskUserQuestionOption(questionIndex: 0, option: "A")
        appState.selectAskUserQuestionOption(questionIndex: 1, option: "D")
        appState.confirmAskUserQuestionAnswers()

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["偏好"] as? String, "A")
        XCTAssertEqual(answers["偏好_2"] as? String, "D")
    }

    func testAskUserQuestionMissingOrEmptyHeaderUsesIndexedFallbackKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-missing-header",
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
        appState.selectAskUserQuestionOption(questionIndex: 0, option: "B")
        appState.selectAskUserQuestionOption(questionIndex: 1, option: "C")
        appState.confirmAskUserQuestionAnswers()

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["answer_1"] as? String, "B")
        XCTAssertEqual(answers["answer_2"] as? String, "C")
    }

    func testAskUserQuestionHeaderAndFallbackKeyCollisionStillKeepsUniqueKeys() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-mixed-collision",
            questions: [
                question(header: "answer_2", text: "第一题", options: ["A", "B"]),
                question(header: nil, text: "第二题", options: ["C", "D"]),
                question(header: "answer_2", text: "第三题", options: ["E", "F"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.selectAskUserQuestionOption(questionIndex: 0, option: "A")
        appState.selectAskUserQuestionOption(questionIndex: 1, option: "D")
        appState.selectAskUserQuestionOption(questionIndex: 2, option: "F")
        appState.confirmAskUserQuestionAnswers()

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["answer_2"] as? String, "A")
        XCTAssertEqual(answers["answer_2_2"] as? String, "D")
        XCTAssertEqual(answers["answer_2_3"] as? String, "F")
    }

    func testConfirmRequiresAllQuestionsSelected() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-confirm-gate",
            questions: [
                question(header: "Q1", text: "第一题", options: ["A", "B"]),
                question(header: "Q2", text: "第二题", options: ["C", "D"]),
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertFalse(appState.canConfirmAskUserQuestion)

        appState.selectAskUserQuestionOption(questionIndex: 0, option: "A")
        XCTAssertFalse(appState.canConfirmAskUserQuestion)

        appState.confirmAskUserQuestionAnswers()
        XCTAssertEqual(appState.questionQueue.count, 1)

        appState.selectAskUserQuestionOption(questionIndex: 1, option: "D")
        XCTAssertTrue(appState.canConfirmAskUserQuestion)

        appState.confirmAskUserQuestionAnswers()
        _ = await responseTask.value
        XCTAssertEqual(appState.questionQueue.count, 0)
    }

    func testAskUserQuestionReselectOverridesPreviousOption() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-reselect",
            questions: [
                question(header: "偏好", text: "请选择", options: ["A", "B"])
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.selectAskUserQuestionOption(questionIndex: 0, option: "A")
        appState.selectAskUserQuestionOption(questionIndex: 0, option: "B")
        appState.confirmAskUserQuestionAnswers()

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["偏好"] as? String, "B")
    }

    func testDebugLoggingFlagMatchesDebugBuild() {
        #if DEBUG
            XCTAssertTrue(CodeIslandLogger.isDebugLoggingEnabled)
        #else
            XCTAssertFalse(CodeIslandLogger.isDebugLoggingEnabled)
        #endif
    }

    func testDebugEventLoggingEnabledForDebugBuild() {
        XCTAssertTrue(CodeIslandLog.isDebugEventLoggingEnabled(environment: [:], isDebugBuild: true))
    }

    func testDebugEventLoggingDisabledByDefaultForReleaseBuild() {
        XCTAssertFalse(CodeIslandLog.isDebugEventLoggingEnabled(environment: [:], isDebugBuild: false))
    }

    func testDebugEventLoggingEnabledForReleaseBuildWhenEnvSet() {
        XCTAssertTrue(
            CodeIslandLog.isDebugEventLoggingEnabled(
                environment: ["CODE_ISLAND_DEBUG_EVENTS": "1"],
                isDebugBuild: false
            ))
        XCTAssertTrue(
            CodeIslandLog.isDebugEventLoggingEnabled(
                environment: ["CODE_ISLAND_DEBUG_EVENTS": "true"],
                isDebugBuild: false
            ))
        XCTAssertTrue(
            CodeIslandLog.isDebugEventLoggingEnabled(
                environment: ["CODE_ISLAND_DEBUG_EVENTS": "YES"],
                isDebugBuild: false
            ))
        XCTAssertTrue(
            CodeIslandLog.isDebugEventLoggingEnabled(
                environment: ["CODE_ISLAND_DEBUG_EVENTS": " YES "],
                isDebugBuild: false
            ))
    }

    func testAppendDebugEventDoesNotWriteWhenReleaseAndEnvDisabled() throws {
        let tempDir = try makeTempDirectory()
        let logURL = tempDir.appendingPathComponent("debug-events.2026-04-10_17:00:00.ndjson")

        CodeIslandLog.appendDebugEvent(
            ["kind": "test", "value": 1],
            environment: [:],
            isDebugBuild: false,
            logURL: logURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: logURL.path))
    }

    func testAppendDebugEventWritesWhenReleaseAndEnvEnabled() throws {
        let tempDir = try makeTempDirectory()
        let logURL = tempDir.appendingPathComponent("debug-events.2026-04-10_17:00:00.ndjson")

        CodeIslandLog.appendDebugEvent(
            ["kind": "test", "value": 2],
            environment: ["CODE_ISLAND_DEBUG_EVENTS": "1"],
            isDebugBuild: false,
            logURL: logURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let data = try Data(contentsOf: logURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"kind\":\"test\""))
    }

    func testDefaultDebugEventLogFileNameContainsStartupTimestamp() {
        let startup = Date(timeIntervalSince1970: 1_712_765_292)
        let url = CodeIslandLog.defaultDebugLogURL(
            currentDirectoryPath: "/tmp/codeisland-tests",
            startupTime: startup
        )

        let fileName = url.lastPathComponent
        let pattern = #"^debug-events\.\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2}\.ndjson$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)

        XCTAssertNotNil(regex?.firstMatch(in: fileName, options: [], range: range))
    }

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

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
