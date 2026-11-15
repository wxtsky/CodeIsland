import XCTest
@testable import CodeIsland
import CodeIslandCore

/// "Auto-expand on question": questions used to open their card no matter
/// what, even for users who had turned off auto-expand for approvals (#292).
@MainActor
final class AppStateQuestionAutoExpandTests: XCTestCase {
    private var savedAutoExpandOnQuestion: Any?
    private var savedSmartSuppress: Any?
    private var savedPermissionOnlyMode: Any?

    override func setUp() {
        super.setUp()
        savedAutoExpandOnQuestion = UserDefaults.standard.object(forKey: SettingsKey.autoExpandOnQuestion)
        savedSmartSuppress = UserDefaults.standard.object(forKey: SettingsKey.smartSuppress)
        savedPermissionOnlyMode = UserDefaults.standard.object(forKey: SettingsKey.permissionOnlyMode)
        // Keep Smart Suppress out of the way: these tests are about the new switch.
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
    }

    override func tearDown() {
        restore(savedAutoExpandOnQuestion, forKey: SettingsKey.autoExpandOnQuestion)
        restore(savedSmartSuppress, forKey: SettingsKey.smartSuppress)
        restore(savedPermissionOnlyMode, forKey: SettingsKey.permissionOnlyMode)
        super.tearDown()
    }

    /// Permission-only mode: a question's card is the island's only signal,
    /// so Smart Suppress doesn't keep it collapsed while the terminal is in
    /// front. Off, Smart Suppress still folds it. (An OMP ask racing its own
    /// terminal dialog is the question Smart Suppress weighs.)
    func testPermissionOnlyModeOpensTheQuestionCardPastSmartSuppress() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)

        func ask(permissionOnly: Bool, sessionId: String) async throws -> IslandSurface {
            UserDefaults.standard.set(permissionOnly, forKey: SettingsKey.permissionOnlyMode)
            let appState = AppState()
            appState.questionTerminalFrontmostDetector = { _ in true }
            let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PermissionRequest",
                "session_id": sessionId,
                "tool_name": "AskUserQuestion",
                "tool_input": [
                    "questions": [[
                        "question": "Which approach?",
                        "header": "Approach",
                        "options": [["label": "A", "description": ""], ["label": "B", "description": ""]],
                    ]]
                ],
                "_source": "pi",
                "_pi_tool_call_id": "racing-\(sessionId)",
                "_term_app": "Ghostty",
                "_codeisland_native_ask_racing": true,
            ] as [String: Any])))
            let task = await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
            let surface = appState.surface
            appState.skipQuestion(expectedSessionId: sessionId)
            _ = try await awaitValue(of: task)
            return surface
        }

        let on = try await ask(permissionOnly: true, sessionId: "s-po-on")
        XCTAssertEqual(on, .questionCard(sessionId: "s-po-on"))
        let off = try await ask(permissionOnly: false, sessionId: "s-po-off")
        XCTAssertEqual(off, .collapsed)
    }

    func testDefaultIsOnSoNothingChangesUnlessAsked() {
        let suite = "AppStateQuestionAutoExpandTests.default"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(AppState.autoExpandOnQuestion(defaults))
        defaults.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        XCTAssertFalse(AppState.autoExpandOnQuestion(defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    func testAskUserQuestionStillOpensItsCardWhenOn() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let task = try await startAskUserQuestion(on: appState, sessionId: "s-on")

        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-on"))
        XCTAssertNil(appState.hiddenPendingQuestionSessionId, "nothing hidden while the card is up")
        appState.skipQuestion(expectedSessionId: "s-on")
        _ = try await awaitValue(of: task)
    }

    func testOffKeepsTheIslandCollapsedAndAdvertisesTheQuestion() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let task = try await startAskUserQuestion(on: appState, sessionId: "s-off")

        XCTAssertEqual(appState.surface, .collapsed, "the card must not open by itself")
        XCTAssertEqual(appState.questionQueue.count, 1, "the question still waits for an answer")
        XCTAssertEqual(appState.sessions["s-off"]?.status, .waitingQuestion)
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "s-off", "the collapsed bar shows the badge")

        // One click opens it.
        appState.openPendingQuestionCard()
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-off"))
        XCTAssertNil(appState.hiddenPendingQuestionSessionId)

        appState.skipQuestion(expectedSessionId: "s-off")
        _ = try await awaitValue(of: task)
    }

    func testOffAlsoCoversNotificationStyleQuestions() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": "s-notify",
            "question": "Continue?",
            "options": ["Yes", "No"],
        ] as [String: Any])))
        let task = await startHookRequest { appState.handleQuestion(event, continuation: $0) }

        XCTAssertEqual(appState.surface, .collapsed)
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "s-notify")
        appState.skipQuestion(expectedSessionId: "s-notify")
        _ = try await awaitValue(of: task)
    }

    /// A card the user opened with a click must survive the queue being
    /// re-evaluated (another request resolving, a completion timer firing):
    /// "off" means nothing opens by itself, not that the user's card closes.
    func testCardOpenedByClickSurvivesShowNextPending() async throws {
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        let appState = AppState()
        let task = try await startAskUserQuestion(on: appState, sessionId: "s-click")

        appState.openPendingQuestionCard(sessionId: "s-click")
        XCTAssertTrue(appState.showNextPending())
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s-click"))

        appState.skipQuestion(expectedSessionId: "s-click")
        _ = try await awaitValue(of: task)
    }

    func testOpeningWithoutAPendingQuestionIsANoOp() {
        let appState = AppState()
        appState.openPendingQuestionCard()
        XCTAssertEqual(appState.surface, .collapsed)
        appState.openPendingQuestionCard(sessionId: "no-such-session")
        XCTAssertEqual(appState.surface, .collapsed)
    }

    // MARK: - Helpers

    private func startAskUserQuestion(on appState: AppState, sessionId: String) async throws -> Task<Data, Never> {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": "Which approach?",
                    "header": "Approach",
                    "options": [
                        ["label": "A", "description": ""],
                        ["label": "B", "description": ""],
                    ],
                ] as [String: Any]],
            ],
        ]
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
        return await startHookRequest { appState.handleAskUserQuestion(event, continuation: $0) }
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
