import XCTest
@testable import CodeIsland
import CodeIslandCore

/// "Dismiss" on a question card closes it without answering: the agent keeps
/// waiting, nothing reopens the card by itself, and the collapsed bar's
/// question badge brings it back. Skip, by contrast, answers (it denies an
/// AskUserQuestion), so it is no way to just get the card out of the way.
@MainActor
final class AppStateQuestionDismissTests: XCTestCase {
    private var appState: AppState!
    private var responses: [String: Task<Data, Never>] = [:]
    private var saved: [String: Any?] = [:]
    private let keys = [
        SettingsKey.autoExpandOnPermission, SettingsKey.autoExpandOnQuestion,
        SettingsKey.smartSuppress, SettingsKey.followUpReminderMinutes,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for k in keys { saved[k] = UserDefaults.standard.object(forKey: k) }
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(0, forKey: SettingsKey.followUpReminderMinutes)
        responses = [:]
        appState = AppState()
    }

    override func tearDown() async throws {
        for event in appState.questionQueue.map(\.event) {
            appState.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        for t in responses.values { _ = try? await awaitValue(of: t) }
        appState = nil
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
        }
        try await super.tearDown()
    }

    func testDismissClosesTheCardWithoutAnsweringIt() async throws {
        try await ask("s1")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s1"))

        appState.dismissQuestion(expectedSessionId: "s1")

        XCTAssertNotEqual(appState.surface, .questionCard(sessionId: "s1"))
        XCTAssertEqual(appState.questionQueue.map(\.event.sessionId), ["s1"], "dismiss hides, it must not dequeue")
        await assertStillPending(try XCTUnwrap(responses["s1"]), "the agent must keep waiting for an answer")
        XCTAssertEqual(appState.hiddenPendingQuestionSessionId, "s1", "the badge must offer the closed question")
    }

    func testDismissedQuestionDoesNotReopenByItselfOrRemind() async throws {
        try await ask("s1")
        appState.dismissQuestion(expectedSessionId: "s1")

        // Anything else finishing re-evaluates the queue — the closed card
        // must not come back on its own.
        appState.showNextPending()

        XCTAssertNotEqual(appState.surface, .questionCard(sessionId: "s1"))
        XCTAssertNil(appState.pendingQuestionRequestIds["s1"], "follow-up reminders stop for a closed card")
    }

    func testBadgeClickReopensTheClosedQuestion() async throws {
        try await ask("s1")
        appState.dismissQuestion(expectedSessionId: "s1")

        appState.openPendingQuestionCard()

        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s1"))
        XCTAssertNotNil(appState.pendingQuestionRequestIds["s1"], "reopened, it waits and reminds like any other")
        // And it is no longer closed: re-evaluating keeps it up.
        appState.showNextPending()
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s1"))
    }

    func testDismissHandsThePanelToTheNextVisibleQuestion() async throws {
        try await ask("s1")
        try await ask("s2")
        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s1"))

        appState.dismissQuestion(expectedSessionId: "s1")

        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s2"))
        XCTAssertEqual(appState.questionQueue.map(\.event.sessionId), ["s1", "s2"])
        await assertStillPending(try XCTUnwrap(responses["s1"]))
    }

    func testSkipShortcutLeavesAClosedQuestionHidden() async throws {
        try await ask("s1")
        appState.dismissQuestion(expectedSessionId: "s1")

        XCTAssertEqual(appState.performCardShortcut(.skipQuestion), .ignored,
                       "a closed question is not skipped, or opened, from a shortcut")
        await assertStillPending(try XCTUnwrap(responses["s1"]))
    }

    func testANewQuestionFromTheSameSessionIsNotHidden() async throws {
        try await ask("s1")
        appState.dismissQuestion(expectedSessionId: "s1")
        // The closed one is answered in the terminal and a follow-up arrives.
        appState.handlePeerDisconnect(sessionId: "s1", agentId: nil)
        _ = try await awaitValue(of: try XCTUnwrap(responses.removeValue(forKey: "s1")))

        try await ask("s1")

        XCTAssertEqual(appState.surface, .questionCard(sessionId: "s1"),
                       "closing is per request: the next question opens as usual")
    }

    // MARK: - Helpers

    private func ask(_ sessionId: String) async throws {
        let event = try makeAskUserQuestionEvent(sessionId: sessionId)
        responses[sessionId] = await startHookRequest { [appState] in
            appState!.handleAskUserQuestion(event, continuation: $0)
        }
    }

    private func makeAskUserQuestionEvent(sessionId: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": "Deploy \(sessionId)?",
                    "header": "Pick",
                    "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]],
                ]]
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data))
    }
}
