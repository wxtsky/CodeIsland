import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class AppStateToolUseCacheTests: XCTestCase {

    // MARK: - Cache lifecycle

    func testPreToolUseCachesRecord() throws {
        let appState = AppState()
        let event = try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_1",
            toolInput: ["command": "ls"]
        )

        appState.handleEvent(event)

        let cached = try XCTUnwrap(appState.pendingToolUses["toolu_1"])
        XCTAssertEqual(cached.sessionId, "s1")
        XCTAssertEqual(cached.toolName, "Bash")
    }

    func testPostToolUseClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))
        XCTAssertNotNil(appState.pendingToolUses["toolu_1"])

        appState.handleEvent(try makeHookEvent(name: "PostToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses["toolu_1"])
    }

    func testPostToolUseFailureAlsoClearsCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(name: "PreToolUse", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        appState.handleEvent(try makeHookEvent(name: "PostToolUseFailure", sessionId: "s1", toolName: "Bash", toolUseId: "toolu_1"))

        XCTAssertNil(appState.pendingToolUses["toolu_1"])
    }

    func testPruneRemovesExpiredRecords() throws {
        let appState = AppState()
        appState.pendingToolUses["ancient"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date(timeIntervalSinceNow: -(AppState.pendingToolUseTTL + 60))
        )
        appState.pendingToolUses["fresh"] = PreToolUseRecord(
            sessionId: "s1",
            toolName: "Bash",
            toolDescription: nil,
            toolInput: nil,
            receivedAt: Date()
        )

        appState.prunePendingToolUses()

        XCTAssertNil(appState.pendingToolUses["ancient"])
        XCTAssertNotNil(appState.pendingToolUses["fresh"])
    }

    // MARK: - Duplicate PermissionRequest replay

    func testDuplicatePermissionRequestReplacesContinuationAndDeniesOld() async throws {
        let appState = AppState()
        let first = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")
        let second = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "dup_1")

        let firstTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(first, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        let secondTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(second, continuation: cont)
            }
        }

        // The old continuation should be denied immediately; queue length stays 1.
        let firstResponse = await firstTask.value
        XCTAssertEqual(try behavior(firstResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Second (replacement) continuation still waits for user decision.
        appState.approvePermission()
        let secondResponse = await secondTask.value
        XCTAssertEqual(try behavior(secondResponse), "allow")
    }

    // MARK: - Stale queue drain via PostToolUse

    func testPostToolUseDrainsQueuedPermissionForSameId() async throws {
        let appState = AppState()
        let pending = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "toolu_drain")

        let responseTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(pending, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 1)

        // Agent moved on — emits PostToolUse for the same tool_use_id.
        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_drain"
        ))

        let response = await responseTask.value
        XCTAssertEqual(try behavior(response), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 0)
    }

    func testPostToolUseDoesNotAffectUnrelatedQueueEntries() async throws {
        let appState = AppState()
        let kept = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "keep_me")
        let drained = try makePermissionEvent(sessionId: "s1", toolName: "Bash", toolUseId: "drop_me")

        let keptTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(kept, continuation: cont)
            }
        }
        let drainedTask = Task<Data, Never> {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(drained, continuation: cont)
            }
        }
        await Task.yield()
        XCTAssertEqual(appState.permissionQueue.count, 2)

        appState.handleEvent(try makeHookEvent(
            name: "PostToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "drop_me"
        ))

        let drainedResponse = await drainedTask.value
        XCTAssertEqual(try behavior(drainedResponse), "deny")
        XCTAssertEqual(appState.permissionQueue.count, 1)
        XCTAssertEqual(appState.permissionQueue.first?.toolUseId, "keep_me")

        appState.approvePermission()
        let keptResponse = await keptTask.value
        XCTAssertEqual(try behavior(keptResponse), "allow")
    }

    // MARK: - Backfill from cache

    func testEnrichBackfillsMissingToolNameFromCache() throws {
        let appState = AppState()
        appState.handleEvent(try makeHookEvent(
            name: "PreToolUse",
            sessionId: "s1",
            toolName: "Bash",
            toolUseId: "toolu_enrich",
            toolInput: ["command": "ls"]
        ))

        // PermissionRequest payload omits tool_name (simulates a thin third-party re-emit).
        let thin = try makeRawHookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_use_id": "toolu_enrich"
        ])

        Task {
            await withCheckedContinuation { cont in
                appState.handlePermissionRequest(thin, continuation: cont)
            }
        }

        // Give the main actor a tick to execute the synchronous path.
        let session = appState.sessions["s1"]
        XCTAssertEqual(session?.currentTool, "Bash")
    }

    // MARK: - Helpers

    private func makeHookEvent(
        name: String,
        sessionId: String,
        toolName: String?,
        toolUseId: String?,
        toolInput: [String: Any]? = nil
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId
        ]
        if let toolName { payload["tool_name"] = toolName }
        if let toolUseId { payload["tool_use_id"] = toolUseId }
        if let toolInput { payload["tool_input"] = toolInput }
        return try makeRawHookEvent(payload)
    }

    private func makePermissionEvent(sessionId: String, toolName: String, toolUseId: String) throws -> HookEvent {
        try makeHookEvent(
            name: "PermissionRequest",
            sessionId: sessionId,
            toolName: toolName,
            toolUseId: toolUseId,
            toolInput: ["command": "echo hi"]
        )
    }

    private func makeRawHookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "AppStateToolUseCacheTests", code: 1)
        }
        return event
    }

    private func behavior(_ data: Data) throws -> String {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hookSpecific = try XCTUnwrap(json["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(hookSpecific["decision"] as? [String: Any])
        return try XCTUnwrap(decision["behavior"] as? String)
    }
}
