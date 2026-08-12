import XCTest
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

        let answers = try extractAnswers(from: await secondResponse.value)
        XCTAssertEqual(answers["Delete the branch?"] as? String, "Yes")

        XCTAssertEqual(appState.questionQueue.count, 1, "the untouched session must stay queued")
        XCTAssertEqual(appState.questionQueue[0].event.sessionId, "gitops-ansible")
        XCTAssertFalse(firstResponse.isCancelled)
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
        appState.answerQuestionMulti(
            [(question: "Deploy which env?", answer: "staging")],
            expectedSessionId: "gitops-ansible"
        )

        XCTAssertEqual(appState.questionQueue.count, 1, "surviving session must still be waiting")
        XCTAssertEqual(appState.questionQueue[0].event.sessionId, "liverpool-cleanup")
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

        let behavior = try extractPermissionBehavior(from: await secondResponse.value)
        XCTAssertEqual(behavior, "deny")
        XCTAssertEqual(appState.questionQueue.map { $0.event.sessionId }, ["s-first"])
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

        let response = await secondResponse.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertEqual(appState.permissionQueue.map { $0.event.sessionId }, ["s-first"])
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

        appState.denyPermission(expectedSessionId: "s-stale")

        XCTAssertEqual(
            appState.permissionQueue.map { $0.event.sessionId },
            ["s-other"],
            "the surviving session's approval must remain pending"
        )
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
    }

    // MARK: - Head-of-queue behaviour is preserved for surfaces that mirror it

    func testOmittedSessionStillResolvesTheHead() async throws {
        let appState = AppState()
        let first = try makePermissionRequestEvent(sessionId: "s-first", command: "echo 1")

        let firstResponse = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(first, continuation: $0) }
        }
        await Task.yield()

        appState.approvePermission()

        let response = await firstResponse.value
        XCTAssertEqual(try extractPermissionBehavior(from: response), "allow")
        XCTAssertTrue(appState.permissionQueue.isEmpty)
    }

    // MARK: - Helpers

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
