import XCTest
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// Answers must reach the session whose card the user acted on, not whatever
/// request happens to sit at the head of the queue. (#308)
@MainActor
final class AppStateAnswerRoutingTests: XCTestCase {

    // MARK: - Questions

    func testAnswerGoesToTheCardsSessionWhenAnotherSessionIsQueuedFirst() async throws {
        let appState = AppState()
        let first = try makeAskUserQuestionEvent(sessionId: "gitops-ansible", text: "Deploy which env?")
        let second = try makeAskUserQuestionEvent(sessionId: "liverpool-cleanup", text: "Delete the branch?")

        let firstResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(first, continuation: $0) }
        }
        await Task.yield()
        let secondResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(second, continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 2)

        // The user is looking at the second session's card.
        appState.answerQuestionMulti(
            [(question: "Delete the branch?", answer: "Yes")],
            expectedSessionId: "liverpool-cleanup"
        )

        // Assert on the queue BEFORE awaiting, and stop on failure: a routing
        // regression resolves the wrong continuation, so the await below would
        // hang forever and report as a CI timeout instead of a named failure.
        guard assertQueue(
            appState.questionQueue.map { $0.event.sessionId },
            ["gitops-ansible"],
            "the addressed session must be the one dequeued, and the other must stay queued"
        ) else { return }

        let answers = try extractAnswers(from: await secondResponse.value)
        XCTAssertEqual(answers["Delete the branch?"] as? String, "Yes")

        firstResponse.cancel()
    }

    func testAnswerIsDroppedWhenTheCardsRequestIsNoLongerQueued() async throws {
        let appState = AppState()
        let stale = try makeAskUserQuestionEvent(sessionId: "gitops-ansible", text: "Deploy which env?")
        let other = try makeAskUserQuestionEvent(sessionId: "liverpool-cleanup", text: "Delete the branch?")

        let staleResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(stale, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(other, continuation: $0) }
        }
        await Task.yield()

        // The first session answered in its own terminal and dropped its socket,
        // which drains its queue entry and promotes the other session to head.
        appState.handlePeerDisconnect(sessionId: "gitops-ansible")
        _ = await staleResponse.value
        XCTAssertEqual(appState.questionQueue.count, 1)
        XCTAssertEqual(appState.questionQueue[0].event.sessionId, "liverpool-cleanup")

        // A click on the now-stale card must not answer the surviving session.
        appState.surface = .questionCard(sessionId: "gitops-ansible")
        appState.answerQuestionMulti(
            [(question: "Deploy which env?", answer: "staging")],
            expectedSessionId: "gitops-ansible"
        )

        XCTAssertEqual(appState.questionQueue.count, 1, "surviving session must still be waiting")
        XCTAssertEqual(appState.questionQueue[0].event.sessionId, "liverpool-cleanup")
        XCTAssertNotEqual(
            appState.surface,
            .questionCard(sessionId: "gitops-ansible"),
            "a card with no queued request must not stay on screen — it would sit expanded and empty"
        )
    }

    /// The case the empty-panel bug actually needs: another session is still
    /// waiting (so the queue is not empty), but Smart Suppress declines to
    /// auto-open its card. `showNextPending` used to leave the old card's
    /// surface untouched, and with the card rendering only its own session's
    /// request that means an expanded, blank notch. (#308)
    func testStaleCardCollapsesWhenAutoOpenIsSuppressed() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress) }

        let appState = AppState()
        var suppressed = SessionSnapshot()
        suppressed.termApp = "Ghostty"
        suppressed.termBundleId = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        appState.sessions["s-other"] = suppressed
        XCTAssertFalse(
            appState.shouldAutoOpenPendingSurface(for: "s-other"),
            "test setup must model Smart Suppress declining to auto-open this session"
        )

        let stale = try makePermissionRequestEvent(sessionId: "s-stale", command: "echo 1")
        let other = try makePermissionRequestEvent(sessionId: "s-other", command: "echo 2")

        let staleResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(stale, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(other, continuation: $0) }
        }
        await Task.yield()

        appState.surface = .approvalCard(sessionId: "s-stale")
        appState.handlePeerDisconnect(sessionId: "s-stale")
        _ = await staleResponse.value

        XCTAssertEqual(appState.permissionQueue.map { $0.event.sessionId }, ["s-other"])
        XCTAssertEqual(
            appState.surface,
            .collapsed,
            "the drained card must not stay up — it has no request left to render"
        )
    }

    func testStaleCardCollapsesWhenItsRequestIsDrained() async throws {
        let appState = AppState()
        let only = try makeAskUserQuestionEvent(sessionId: "s-only", text: "Proceed?")

        let response = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(only, continuation: $0) }
        }
        await Task.yield()
        appState.surface = .questionCard(sessionId: "s-only")

        // Answered in the terminal instead: the socket drops and the entry drains.
        appState.handlePeerDisconnect(sessionId: "s-only")
        _ = await response.value

        XCTAssertEqual(
            appState.surface,
            .collapsed,
            "nothing is queued, so the panel must collapse rather than render an empty card"
        )
    }

    func testSkipTargetsTheCardsSession() async throws {
        let appState = AppState()
        let first = try makeAskUserQuestionEvent(sessionId: "s-first", text: "First?")
        let second = try makeAskUserQuestionEvent(sessionId: "s-second", text: "Second?")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(first, continuation: $0) }
        }
        await Task.yield()
        let secondResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(second, continuation: $0) }
        }
        await Task.yield()

        appState.skipQuestion(expectedSessionId: "s-second")

        guard assertQueue(
            appState.questionQueue.map { $0.event.sessionId },
            ["s-first"],
            "skip must dequeue the addressed session"
        ) else { return }
        let behavior = try extractPermissionBehavior(from: await secondResponse.value)
        XCTAssertEqual(behavior, "deny")
    }

    // MARK: - Permissions

    func testApproveGoesToTheCardsSessionWhenAnotherSessionIsQueuedFirst() async throws {
        let appState = AppState()
        let first = try makePermissionRequestEvent(sessionId: "s-first", command: "echo 1")
        let second = try makePermissionRequestEvent(sessionId: "s-second", command: "echo 2")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(first, continuation: $0) }
        }
        await Task.yield()
        let secondResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(second, continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.approvePermission(expectedSessionId: "s-second")

        // Queue first — see the note in the question-routing test above.
        guard assertQueue(
            appState.permissionQueue.map { $0.event.sessionId },
            ["s-first"],
            "approve must dequeue the addressed session"
        ) else { return }
        let response = await secondResponse.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
    }

    func testDenyIsDroppedWhenTheCardsRequestIsNoLongerQueued() async throws {
        let appState = AppState()
        let stale = try makePermissionRequestEvent(sessionId: "s-stale", command: "echo 1")
        let other = try makePermissionRequestEvent(sessionId: "s-other", command: "echo 2")

        let staleResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(stale, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(other, continuation: $0) }
        }
        await Task.yield()

        appState.handlePeerDisconnect(sessionId: "s-stale")
        _ = await staleResponse.value
        XCTAssertEqual(appState.permissionQueue.map { $0.event.sessionId }, ["s-other"])

        appState.surface = .approvalCard(sessionId: "s-stale")
        appState.denyPermission(expectedSessionId: "s-stale")

        XCTAssertEqual(
            appState.permissionQueue.map { $0.event.sessionId },
            ["s-other"],
            "the surviving session's approval must remain pending"
        )
        XCTAssertNotEqual(appState.surface, .approvalCard(sessionId: "s-stale"))
    }

    func testDismissTargetsTheCardsSession() async throws {
        let appState = AppState()
        let first = try makePermissionRequestEvent(sessionId: "s-first", command: "echo 1")
        let second = try makePermissionRequestEvent(sessionId: "s-second", command: "echo 2")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(first, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(second, continuation: $0) }
        }
        await Task.yield()

        appState.surface = .approvalCard(sessionId: "s-second")
        appState.dismissPermissionPrompt(expectedSessionId: "s-second")

        // Dismissing hides that session's prompt and hands the panel to the
        // session that is still visible. Had it dismissed the head instead, the
        // panel would have swung to the session the user just dismissed.
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-first"))
        XCTAssertEqual(appState.permissionQueue.count, 2, "dismiss hides, it must not resolve")
    }

    // MARK: - Card rendering

    func testCardLookupReturnsTheAddressedSessionsRequest() async throws {
        let appState = AppState()
        let first = try makePermissionRequestEvent(sessionId: "s-first", command: "echo 1")
        let second = try makePermissionRequestEvent(sessionId: "s-second", command: "echo 2")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(first, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(second, continuation: $0) }
        }
        await Task.yield()

        XCTAssertEqual(appState.pendingPermission(forSession: "s-second")?.event.sessionId, "s-second")
        XCTAssertNil(appState.pendingPermission(forSession: "s-missing"))
        XCTAssertEqual(appState.permissionQueuePosition(forSession: "s-second"), 2)
    }

    func testQuestionCardLookupReturnsTheAddressedSessionsRequest() async throws {
        let appState = AppState()
        let first = try makeAskUserQuestionEvent(sessionId: "s-first", text: "First?")
        let second = try makeAskUserQuestionEvent(sessionId: "s-second", text: "Second?")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(first, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handleAskUserQuestion(second, continuation: $0) }
        }
        await Task.yield()

        XCTAssertEqual(appState.pendingQuestion(forSession: "s-second")?.question.question, "Second?")
        XCTAssertNil(appState.pendingQuestion(forSession: "s-missing"))
        XCTAssertEqual(appState.questionQueuePosition(forSession: "s-second"), 2)
    }

    // MARK: - Head-of-queue behaviour is preserved for surfaces that mirror it

    func testOmittedSessionStillResolvesTheHead() async throws {
        let appState = AppState()
        let first = try makePermissionRequestEvent(sessionId: "s-first", command: "echo 1")
        let second = try makePermissionRequestEvent(sessionId: "s-second", command: "echo 2")

        let firstResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(first, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(second, continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 2, "a one-element queue could not detect a change here")

        // Buddy/companion surfaces mirror the head and pass no session.
        appState.approvePermission()

        guard assertQueue(
            appState.permissionQueue.map { $0.event.sessionId },
            ["s-second"],
            "with no session passed, the head must be the one resolved"
        ) else { return }
        let response = await firstResponse.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
    }

    /// The single-answer path (`Notification` questions, not the AskUserQuestion
    /// wizard) routes by session too.
    func testSingleAnswerQuestionTargetsTheCardsSession() async throws {
        let appState = AppState()
        let first = try makeNotificationQuestionEvent(sessionId: "s-first", text: "First?")
        let second = try makeNotificationQuestionEvent(sessionId: "s-second", text: "Second?")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(first, continuation: $0) }
        }
        await Task.yield()
        let secondResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(second, continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.questionQueue.count, 2)

        appState.answerQuestion("B", expectedSessionId: "s-second")

        guard assertQueue(
            appState.questionQueue.map { $0.event.sessionId },
            ["s-first"],
            "the single-answer path must dequeue the addressed session"
        ) else { return }
        let responseData = await secondResponse.value
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["answer"] as? String, "B")
    }

    /// A dismissed approval is hidden but stays queued, so a liveness check based
    /// on queue membership alone would keep its card on screen — re-rendering the
    /// request the user just dismissed.
    func testDismissedCardDoesNotStayOnScreenWhenAutoOpenIsSuppressed() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        defer { UserDefaults.standard.removeObject(forKey: SettingsKey.smartSuppress) }

        let appState = AppState()
        var suppressed = SessionSnapshot()
        suppressed.termApp = "Ghostty"
        suppressed.termBundleId = try XCTUnwrap(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        appState.sessions["s-other"] = suppressed
        XCTAssertFalse(appState.shouldAutoOpenPendingSurface(for: "s-other"))

        let dismissed = try makePermissionRequestEvent(sessionId: "s-dismissed", command: "echo 1")
        let other = try makePermissionRequestEvent(sessionId: "s-other", command: "echo 2")

        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(dismissed, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(other, continuation: $0) }
        }
        await Task.yield()

        appState.surface = .approvalCard(sessionId: "s-dismissed")
        appState.dismissPermissionPrompt(expectedSessionId: "s-dismissed")

        XCTAssertNotEqual(
            appState.surface,
            .approvalCard(sessionId: "s-dismissed"),
            "a dismissed card must not stay up just because its request is still queued"
        )
        XCTAssertEqual(appState.permissionQueue.count, 2, "dismiss hides, it must not resolve")
    }

    func testDismissIsDroppedWhenTheCardsRequestIsNoLongerQueued() async throws {
        let appState = AppState()
        let stale = try makePermissionRequestEvent(sessionId: "s-stale", command: "echo 1")
        let other = try makePermissionRequestEvent(sessionId: "s-other", command: "echo 2")

        let staleResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(stale, continuation: $0) }
        }
        await Task.yield()
        _ = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(other, continuation: $0) }
        }
        await Task.yield()

        appState.handlePeerDisconnect(sessionId: "s-stale")
        _ = await staleResponse.value

        appState.surface = .approvalCard(sessionId: "s-stale")
        appState.dismissPermissionPrompt(expectedSessionId: "s-stale")

        XCTAssertEqual(
            appState.permissionQueue.map { $0.event.sessionId },
            ["s-other"],
            "dismissing a card whose request is gone must not hide a different session's prompt"
        )
        XCTAssertNotEqual(appState.surface, .approvalCard(sessionId: "s-stale"))

        // The queue assertions above cannot see the damage a head-based dismiss
        // would do: dismissing hides without dequeuing, so the queue looks the
        // same either way. Whether s-other was wrongly marked dismissed only
        // shows up in whether the panel will still offer its card.
        appState.showNextPending()
        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-other"),
            "s-other must remain offerable — a wrongly-dismissed session is filtered out and the panel stays collapsed"
        )
    }

    // MARK: - Surface accessors

    func testSurfaceSessionAccessorsAreKindMatched() {
        XCTAssertEqual(IslandSurface.approvalCard(sessionId: "a").approvalSessionId, "a")
        XCTAssertNil(IslandSurface.questionCard(sessionId: "q").approvalSessionId)
        XCTAssertEqual(IslandSurface.questionCard(sessionId: "q").questionSessionId, "q")
        XCTAssertNil(IslandSurface.approvalCard(sessionId: "a").questionSessionId)
        // A completion card is neither: a shortcut fired over it addresses nothing.
        XCTAssertNil(IslandSurface.completionCard(sessionId: "c").approvalSessionId)
        XCTAssertNil(IslandSurface.completionCard(sessionId: "c").questionSessionId)
    }

    // MARK: - Helpers

    /// Assert the post-action queue, and report whether it held. Every await in
    /// this suite only completes when the *right* continuation was resolved, so
    /// a test that keeps going after this fails hangs instead of reporting.
    private func assertQueue(
        _ actual: [String?],
        _ expected: [String],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let expectedOptionals = expected.map { Optional($0) }
        XCTAssertEqual(actual, expectedOptionals, message, file: file, line: line)
        return actual == expectedOptionals
    }

    private func makeAskUserQuestionEvent(sessionId: String, text: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": [[
                    "question": text,
                    "header": "Pick",
                    "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]],
                ]]
            ],
        ]
        return try makeEvent(payload)
    }

    private func makeNotificationQuestionEvent(sessionId: String, text: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": sessionId,
            "question": text,
            "options": ["A", "B"],
        ]
        return try makeEvent(payload)
    }

    private func makePermissionRequestEvent(sessionId: String, command: String) throws -> HookEvent {
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_input": ["command": command, "description": command],
        ]
        return try makeEvent(payload)
    }

    private func makeEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("Failed to parse HookEvent")
            throw NSError(domain: "AppStateAnswerRoutingTests", code: 1)
        }
        return event
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
