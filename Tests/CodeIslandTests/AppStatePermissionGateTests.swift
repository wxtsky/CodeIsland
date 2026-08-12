import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The enqueue gate decides whether an arriving permission raises a card. It has
/// two failure modes that the #309 tests alone do not reach: asking about the
/// whole queue when staleness is per-session, and letting a replayed request
/// resurrect a session the user dismissed.
@MainActor
final class AppStatePermissionGateTests: XCTestCase {

    /// A card can be left pointing at a session whose own request was drained
    /// (a question arriving for that session does this) while other sessions are
    /// still queued. A whole-queue test reads that as "a card is up" and queues
    /// every later request silently behind a card for a session that has nothing
    /// pending.
    func testCardForADrainedSessionDoesNotBlockLaterRequests() async throws {
        let appState = AppState()

        // Occupy the question queue first, so the question in step 3 does not
        // reassign the surface.
        let cTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(try! self.question("s-c"), continuation: $0) }
        }
        await Task.yield()

        let aTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-a", "Bash"), continuation: $0) }
        }
        await Task.yield()
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "s-a"))

        let bTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-b", "Read"), continuation: $0) }
        }
        await Task.yield()

        // A question for s-a drains s-a's permission; s-b's is untouched.
        let aQuestionTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handleQuestion(try! self.question("s-a"), continuation: $0) }
        }
        await Task.yield()
        _ = await aTask.value
        XCTAssertFalse(
            appState.permissionQueue.contains { $0.event.sessionId == "s-a" },
            "s-a has nothing queued"
        )
        XCTAssertFalse(appState.permissionQueue.isEmpty, "but the queue is not empty")

        let dTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-d", "Edit"), continuation: $0) }
        }
        await Task.yield()

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-b"),
            "the panel must move to a request that is actually waiting, not stay on the drained session's card"
        )

        appState.handlePeerDisconnect(sessionId: "s-b")
        appState.handlePeerDisconnect(sessionId: "s-d")
        appState.handlePeerDisconnect(sessionId: "s-c")
        appState.handlePeerDisconnect(sessionId: "s-a")
        _ = await bTask.value
        _ = await dTask.value
        _ = await cTask.value
        _ = await aQuestionTask.value
    }

    /// A replay of the same `tool_use_id` is the same decision arriving twice.
    /// Clearing the dismissal on a replay resurrects the request the user hid,
    /// which then takes the card the arriving session should have received.
    func testReplayOfADismissedRequestDoesNotStealTheNextSessionsCard() async throws {
        let appState = AppState()

        let originalTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(try! self.permWithToolUse("s-replay", "tool-1"), continuation: $0)
            }
        }
        await Task.yield()
        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)

        let replayTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(try! self.permWithToolUse("s-replay", "tool-1"), continuation: $0)
            }
        }
        await Task.yield()
        _ = await originalTask.value  // the replay denies the previous waiter
        XCTAssertEqual(appState.permissionQueue.count, 1, "a replay swaps in place, it does not enqueue")
        XCTAssertEqual(appState.surface, .collapsed, "a replay must not resurrect the dismissed card")

        let otherTask = Task<Data, Never> {
            await withCheckedContinuation { appState.handlePermissionRequest(try! self.perm("s-other", "Read"), continuation: $0) }
        }
        await Task.yield()

        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-other"),
            "the arriving session must get the card, not the replayed-and-resurrected one"
        )
        // Stop on failure. Under the bug the resurrected session leads the queue,
        // so the approve below resolves that one instead and the await never
        // returns — the test would hang rather than report by name.
        guard appState.permissionQueue.first?.event.sessionId == "s-other" else {
            appState.handlePeerDisconnect(sessionId: "s-replay")
            appState.handlePeerDisconnect(sessionId: "s-other")
            _ = await replayTask.value
            _ = await otherTask.value
            return
        }

        appState.approvePermission()
        let otherResponse = await otherTask.value
        XCTAssertEqual(try extractBehavior(from: otherResponse), "allow")

        appState.handlePeerDisconnect(sessionId: "s-replay")
        _ = await replayTask.value
    }

    /// The other side of that move: `mergeDuplicatePermissionRequest` returns
    /// false when the tool inputs differ (#169 — parallel calls can share an id),
    /// so such a request does enqueue and must still clear the dismissal.
    func testSameToolUseIdWithDifferentInputStillClearsTheDismissal() async throws {
        let appState = AppState()

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(try! self.permWithToolUse("s-parallel", "tool-9"), continuation: $0)
            }
        }
        await Task.yield()
        appState.dismissPermissionPrompt()
        XCTAssertEqual(appState.surface, .collapsed)

        let secondTask = Task<Data, Never> {
            await withCheckedContinuation {
                appState.handlePermissionRequest(
                    try! self.permWithToolUse("s-parallel", "tool-9", command: "echo different"),
                    continuation: $0
                )
            }
        }
        await Task.yield()

        XCTAssertEqual(appState.permissionQueue.count, 2, "differing inputs must enqueue, not merge")
        XCTAssertEqual(
            appState.surface,
            .approvalCard(sessionId: "s-parallel"),
            "a genuinely new request must clear the dismissal and bring the card back"
        )

        appState.handlePeerDisconnect(sessionId: "s-parallel")
        _ = await firstTask.value
        _ = await secondTask.value
    }

    // MARK: - Helpers

    private func perm(_ sessionId: String, _ toolName: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": toolName,
            "tool_input": ["command": "echo test"],
        ])))
    }

    private func permWithToolUse(
        _ sessionId: String,
        _ toolUseId: String,
        command: String = "echo test"
    ) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "tool_name": "Bash",
            "tool_use_id": toolUseId,
            "tool_input": ["command": command],
        ])))
    }

    private func question(_ sessionId: String) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": sessionId,
            "question": "Pick?",
            "options": ["A", "B"],
        ])))
    }

    private func extractBehavior(from data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(output["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
