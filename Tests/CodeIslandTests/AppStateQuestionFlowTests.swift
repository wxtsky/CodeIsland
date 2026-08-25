import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateQuestionFlowTests: XCTestCase {
    private var savedSmartSuppress: Any?

    override func setUp() {
        super.setUp()
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        if let savedSmartSuppress {
            UserDefaults.standard.set(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress)
        }
        super.tearDown()
    }

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

    func testStructuredAnswerDetailsPreserveMultiSelectAndCustomInput() async throws {
        let appState = AppState()
        var multiQuestion = question(
            header: "组合选择",
            text: "请选择多个选项，也可以补充自定义内容",
            options: ["Alpha, Beta", "Gamma"]
        )
        multiQuestion["multiSelect"] = true
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-structured",
            questions: [multiQuestion],
            piToolCallId: "omp-structured"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            AskUserQuestionAnswer(
                question: "请选择多个选项，也可以补充自定义内容",
                answer: "Alpha, Beta, Gamma, custom, value",
                selectedOptions: ["Alpha, Beta", "Gamma"],
                customInput: "custom, value"
            ),
        ])

        let responseData = await responseTask.value
        let updatedInput = try extractUpdatedInput(from: responseData)
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: Any])
        XCTAssertEqual(answers["请选择多个选项，也可以补充自定义内容"] as? String, "Alpha, Beta, Gamma, custom, value")

        let details = try XCTUnwrap(updatedInput["_codeislandAnswerDetails"] as? [String: Any])
        let answerDetails = try XCTUnwrap(details["请选择多个选项，也可以补充自定义内容"] as? [String: Any])
        XCTAssertEqual(answerDetails["selectedOptions"] as? [String], ["Alpha, Beta", "Gamma"])
        XCTAssertEqual(answerDetails["customInput"] as? String, "custom, value")
    }

    func testMultiSelectWithoutOptionsPreservesFreeTextAsCustomInput() async throws {
        let appState = AppState()
        var freeTextQuestion = question(
            header: "补充说明",
            text: "请填写补充内容",
            options: []
        )
        freeTextQuestion["multiSelect"] = true
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-free-text-multi",
            questions: [freeTextQuestion],
            piToolCallId: "omp-free-text-multi"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            AskUserQuestionAnswer(
                question: "请填写补充内容",
                answer: "自由输入",
                selectedOptions: [],
                customInput: "自由输入"
            ),
        ])

        let responseData = await responseTask.value
        let updatedInput = try extractUpdatedInput(from: responseData)
        let details = try XCTUnwrap(updatedInput["_codeislandAnswerDetails"] as? [String: Any])
        let answerDetails = try XCTUnwrap(details["请填写补充内容"] as? [String: Any])
        XCTAssertNil(answerDetails["selectedOptions"])
        XCTAssertEqual(answerDetails["customInput"] as? String, "自由输入")
    }

    func testQuestionBarFreeTextAnswerPreservesCustomInput() throws {
        let answer = try XCTUnwrap(
            makeQuestionBarFreeTextAnswer(question: "请填写补充内容", text: "自由输入")
        )

        XCTAssertEqual(answer.question, "请填写补充内容")
        XCTAssertEqual(answer.answer, "自由输入")
        XCTAssertEqual(answer.selectedOptions, [])
        XCTAssertEqual(answer.customInput, "自由输入")
        XCTAssertNil(makeQuestionBarFreeTextAnswer(question: "请填写补充内容", text: ""))
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
            AskUserQuestionAnswer(
                question: "你希望我主要使用哪种语言回复？",
                answer: "中文",
                selectedOptions: ["中文"],
                customInput: nil
            ),
        ])

        let responseData = await responseTask.value
        let answers = try extractAnswers(from: responseData)
        XCTAssertEqual(answers["你希望我主要使用哪种语言回复？"] as? String, "中文")
        let updatedInput = try extractUpdatedInput(from: responseData)
        XCTAssertNil(updatedInput["_codeislandAnswerDetails"])
    }

    func testAskUserQuestionOpensQuestionCardWhenSmartSuppressSeesGhosttyFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let sessionId = "s-smart-question"
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        session.termBundleId = "com.mitchellh.ghostty"
        appState.sessions[sessionId] = session
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: sessionId, isTerminalFrontmost: { _ in true }), "test setup must model Smart Suppress considering the Ghostty-backed session frontmost")

        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "继续吗", text: "需要用户确认下一步吗？", options: ["继续", "停止"])
            ]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 1)
        let surfaceAfterRequest = appState.surface

        appState.skipQuestion()
        _ = await responseTask.value

        XCTAssertEqual(
            surfaceAfterRequest,
            .questionCard(sessionId: sessionId),
            "AskUserQuestion must open its card even when Smart Suppress considers the Ghostty-backed terminal frontmost; otherwise OMP waits on CodeIsland while the native terminal dialog is blocked."
        )
    }

    func testAskUserQuestionQueueOpensNextQuestionCardWhenSmartSuppressSeesGhosttyFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let frontmostBundleId = "com.mitchellh.ghostty"
        let firstSessionId = "s-smart-question-first"
        let secondSessionId = "s-smart-question-second"
        var firstSession = SessionSnapshot()
        firstSession.termApp = "Ghostty"
        firstSession.termBundleId = frontmostBundleId
        var secondSession = SessionSnapshot()
        secondSession.termApp = "Ghostty"
        secondSession.termBundleId = frontmostBundleId
        appState.sessions[firstSessionId] = firstSession
        appState.sessions[secondSessionId] = secondSession
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: firstSessionId, isTerminalFrontmost: { _ in true }), "test setup must model Smart Suppress considering the first Ghostty-backed session frontmost")
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: secondSessionId, isTerminalFrontmost: { _ in true }), "test setup must model Smart Suppress considering the second Ghostty-backed session frontmost")

        let firstEvent = try makeAskUserQuestionEvent(
            sessionId: firstSessionId,
            questions: [
                question(header: "第一步", text: "先处理第一个问题吗？", options: ["继续", "停止"])
            ]
        )
        let secondEvent = try makeAskUserQuestionEvent(
            sessionId: secondSessionId,
            questions: [
                question(header: "第二步", text: "现在处理第二个问题吗？", options: ["继续", "停止"])
            ]
        )

        let firstResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(firstEvent, continuation: continuation)
            }
        }
        await Task.yield()
        let secondResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(secondEvent, continuation: continuation)
            }
        }
        await Task.yield()
        let queueCountAfterEnqueue = appState.questionQueue.count

        appState.skipQuestion()
        _ = await firstResponseTask.value
        await Task.yield()
        let queueCountAfterPromotingSecond = appState.questionQueue.count
        let surfaceAfterPromotingSecond = appState.surface

        appState.skipQuestion()
        _ = await secondResponseTask.value

        XCTAssertEqual(queueCountAfterEnqueue, 2)
        XCTAssertEqual(queueCountAfterPromotingSecond, 1)
        XCTAssertEqual(
            surfaceAfterPromotingSecond,
            .questionCard(sessionId: secondSessionId),
            "showNextPending must open the next AskUserQuestion card even when Smart Suppress considers that Ghostty-backed terminal frontmost; otherwise queued OMP questions remain hidden behind the compact badge."
        )
    }

    func testPiAskUserQuestionStaysCollapsedWhenSmartSuppressSeesTerminalFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let sessionId = "s-smart-pi-question"
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        session.termBundleId = "com.mitchellh.ghostty"
        appState.sessions[sessionId] = session
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: sessionId, isTerminalFrontmost: { _ in true }))

        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "继续吗", text: "需要用户确认下一步吗？", options: ["继续", "停止"])
            ],
            piToolCallId: "omp-smart-suppressed",
            nativeAskRacing: true
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 1)
        let surfaceAfterRequest = appState.surface

        appState.skipQuestion()
        _ = await responseTask.value

        XCTAssertEqual(
            surfaceAfterRequest,
            .collapsed,
            "Marker-enabled OMP keeps its native ask dialog available in parallel, so Smart Suppress should not force the duplicate CodeIsland card open."
        )
    }

    func testPiAndLegacyOmpAskWithoutNativeRaceMarkerOpensWhenTerminalIsFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let sessionId = "s-smart-legacy-pi-question"
        var session = SessionSnapshot()
        session.termApp = "Ghostty"
        session.termBundleId = "com.mitchellh.ghostty"
        appState.sessions[sessionId] = session

        let event = try makeAskUserQuestionEvent(
            sessionId: sessionId,
            questions: [
                question(header: "继续吗", text: "需要用户确认下一步吗？", options: ["继续", "停止"])
            ],
            piToolCallId: "legacy-pi-blocking-ask"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        let surfaceAfterRequest = appState.surface
        appState.skipQuestion()
        _ = await responseTask.value

        XCTAssertEqual(
            surfaceAfterRequest,
            .questionCard(sessionId: sessionId),
            "Pi and legacy OMP block their native prompt while CodeIsland waits, so an unmarked AskUserQuestion must force-open."
        )
    }

    func testPiAskUserQuestionQueueKeepsNextCardCollapsedWhenTerminalIsFrontmost() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let frontmostBundleId = "com.mitchellh.ghostty"
        let firstSessionId = "s-smart-pi-question-first"
        let secondSessionId = "s-smart-pi-question-second"
        var firstSession = SessionSnapshot()
        firstSession.termApp = "Ghostty"
        firstSession.termBundleId = frontmostBundleId
        var secondSession = SessionSnapshot()
        secondSession.termApp = "Ghostty"
        secondSession.termBundleId = frontmostBundleId
        appState.sessions[firstSessionId] = firstSession
        appState.sessions[secondSessionId] = secondSession
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: firstSessionId, isTerminalFrontmost: { _ in true }))
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: secondSessionId, isTerminalFrontmost: { _ in true }))

        let firstEvent = try makeAskUserQuestionEvent(
            sessionId: firstSessionId,
            questions: [
                question(header: "第一步", text: "先处理第一个问题吗？", options: ["继续", "停止"])
            ],
            piToolCallId: "omp-smart-first",
            nativeAskRacing: true
        )
        let secondEvent = try makeAskUserQuestionEvent(
            sessionId: secondSessionId,
            questions: [
                question(header: "第二步", text: "现在处理第二个问题吗？", options: ["继续", "停止"])
            ],
            piToolCallId: "omp-smart-second",
            nativeAskRacing: true
        )

        let firstResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(firstEvent, continuation: continuation)
            }
        }
        await Task.yield()
        let secondResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(secondEvent, continuation: continuation)
            }
        }
        await Task.yield()

        appState.skipQuestion()
        _ = await firstResponseTask.value
        await Task.yield()
        let queueCountAfterPromotingSecond = appState.questionQueue.count
        let surfaceAfterPromotingSecond = appState.surface

        appState.skipQuestion()
        _ = await secondResponseTask.value

        XCTAssertEqual(queueCountAfterPromotingSecond, 1)
        XCTAssertEqual(
            surfaceAfterPromotingSecond,
            .collapsed,
            "Queued OMP questions should keep honoring Smart Suppress after promotion because the native terminal dialog remains usable."
        )
    }

    func testPromotedOmpAskCollapsesVisibleNonOmpQuestionCardWhenSmartSuppressed() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        let appState = AppState()
        appState.questionTerminalFrontmostDetector = { _ in true }
        let legacySessionId = "s-smart-legacy-first"
        let ompSessionId = "s-smart-omp-second"
        var legacySession = SessionSnapshot()
        legacySession.termApp = "Ghostty"
        legacySession.termBundleId = "com.mitchellh.ghostty"
        var ompSession = SessionSnapshot()
        ompSession.termApp = "Ghostty"
        ompSession.termBundleId = "com.mitchellh.ghostty"
        appState.sessions[legacySessionId] = legacySession
        appState.sessions[ompSessionId] = ompSession

        // Legacy Pi ask (no race marker) — must force-open.
        let legacyEvent = try makeAskUserQuestionEvent(
            sessionId: legacySessionId,
            questions: [
                question(header: "旧版", text: "旧版 OMP 会阻塞吗？", options: ["是", "否"])
            ],
            piToolCallId: "legacy-pi-1"
        )
        // OMP v4 ask (with race marker) — should be Smart Suppressed.
        let ompEvent = try makeAskUserQuestionEvent(
            sessionId: ompSessionId,
            questions: [
                question(header: "新版", text: "新版 OMP 是否并行？", options: ["是", "否"])
            ],
            piToolCallId: "omp-racing-2",
            nativeAskRacing: true
        )

        let legacyResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(legacyEvent, continuation: continuation)
            }
        }
        await Task.yield()
        // Legacy question must have forced the card open.
        XCTAssertEqual(appState.surface, .questionCard(sessionId: legacySessionId))

        let ompResponseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(ompEvent, continuation: continuation)
            }
        }
        await Task.yield()

        // Skip the legacy question — the OMP question should be promoted.
        appState.skipQuestion()
        _ = await legacyResponseTask.value
        await Task.yield()
        let surfaceAfterPromotion = appState.surface

        appState.skipQuestion()
        _ = await ompResponseTask.value

        XCTAssertEqual(
            surfaceAfterPromotion,
            .collapsed,
            "A Smart Suppress decision must replace the previous question-card surface when a queued OMP ask is promoted."
        )
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

    // MARK: - Qoder strict schema

    func testQoderAnswerOmitsScalarAnswerKey() async throws {
        // Qoder CLI validates PermissionRequest updatedInput against the
        // AskUserQuestion schema (additionalProperties: false). The scalar
        // `answer` key trips "params must NOT have additional properties",
        // so it must be omitted for qoder sources while `answers` stays.
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-qoder",
            questions: [
                question(header: "确认", text: "继续执行吗？", options: ["继续", "停止"]),
            ],
            source: "qoder"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "继续执行吗？", answer: "继续"),
        ])

        let responseData = await responseTask.value
        let updatedInput = try extractUpdatedInput(from: responseData)
        XCTAssertNil(updatedInput["answer"], "qoder updatedInput must not carry the extra scalar `answer` key")
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: Any])
        XCTAssertEqual(answers["继续执行吗？"] as? String, "继续")
    }

    func testNonQoderAnswerKeepsScalarAnswerKey() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-claude-answer-key",
            questions: [
                question(header: "确认", text: "继续执行吗？", options: ["继续", "停止"]),
            ],
            source: "claude"
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        appState.answerQuestionMulti([
            (question: "继续执行吗？", answer: "继续"),
        ])

        let responseData = await responseTask.value
        let updatedInput = try extractUpdatedInput(from: responseData)
        XCTAssertEqual(updatedInput["answer"] as? String, "继续")
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

    // MARK: - Click-to-jump

    /// Clicking the question card focuses the asking terminal and — when
    /// Auto-Collapse After Jump is on — folds the notch. That fold must not be
    /// confused with Skip: the question stays queued and answerable, in the
    /// terminal or back on the card.
    func testCollapsingAQuestionCardAfterAJumpKeepsItAnswerable() async throws {
        let appState = AppState()
        let event = try makeAskUserQuestionEvent(
            sessionId: "s-jump",
            questions: [question(header: "Mode", text: "Pick one", options: ["A", "B"])]
        )

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { continuation in
                appState.handleAskUserQuestion(event, continuation: continuation)
            }
        }

        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-jump"))

        // What a successful click-to-jump does to the panel.
        appState.surface = .collapsed

        XCTAssertEqual(appState.questionQueue.count, 1, "a jump must not dequeue the question")
        XCTAssertNotNil(appState.pendingQuestion(forSession: "s-jump"))

        appState.answerQuestionMulti([
            (question: "Pick one", answer: "A"),
        ])

        let answers = try extractAnswers(from: await responseTask.value)
        XCTAssertEqual(answers["Pick one"] as? String, "A")
    }

    // MARK: - Helpers

    private func makeAskUserQuestionEvent(
        sessionId: String,
        questions: [[String: Any]],
        source: String? = nil,
        piToolCallId: String? = nil,
        nativeAskRacing: Bool = false
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": questions
            ]
        ]
        if let source {
            payload["_source"] = source
        }
        if let piToolCallId {
            payload["_source"] = "pi"
            payload["_pi_tool_call_id"] = piToolCallId
        }
        if nativeAskRacing {
            payload["_codeisland_native_ask_racing"] = true
        }
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
