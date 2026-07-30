import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Coverage for merge/hide `_ppid` parent fallback when Cursor Task hooks omit
/// a foldable `transcript_path` (safe path: never ppid-fold a parseable main chat).
@MainActor
final class HookServerCursorPpidFallbackTests: XCTestCase {
    private let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
    private let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
    private let otherId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private func withPluginSessionMode(_ mode: String, _ body: () throws -> Void) rethrows {
        let previous = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set(mode, forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }
        try body()
    }

    private func makeRunningCursorSession(
        source: String = "cursor",
        cliPid: Int,
        lastActivity: Date = Date(),
        startTime: Date = Date(),
        providerSessionId: String? = nil
    ) -> SessionSnapshot {
        var snap = SessionSnapshot(startTime: startTime)
        snap.source = source
        snap.status = .running
        snap.cliPid = pid_t(cliPid)
        snap.lastActivity = lastActivity
        snap.providerSessionId = providerSessionId
        return snap
    }

    private func route(
        appState: AppState,
        payload: [String: Any]
    ) throws -> (processedData: Data, responseData: Data?, raw: [String: Any]) {
        let server = HookServer(appState: appState)
        let data = try JSONSerialization.data(withJSONObject: payload)
        let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
        let raw = try XCTUnwrap(
            JSONSerialization.jsonObject(with: routed.processedData) as? [String: Any]
        )
        return (routed.processedData, routed.responseData, raw)
    }

    // MARK: - Happy paths

    func testMergeModePpidFallbackRewritesChildOntoActiveParent() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_001
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
                "tool_name": "Read",
            ])
            XCTAssertNil(routed.responseData)
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["agent_type"] as? String, "cursor-subagent")
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    func testMergeModePpidFallbackAcceptsCamelCaseSessionIdAndNSNumberPpid() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_002
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "sessionId": childId,
                "_ppid": NSNumber(value: ppid),
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
        }
    }

    func testMergeModePpidFallbackWithUnparseableTranscriptPath() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_003
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "transcript_path": "/tmp/not-an-agent-transcript.jsonl",
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    func testHideModePpidFallbackSuppressesChildWithoutTranscript() throws {
        try withPluginSessionMode("hide") {
            let ppid = 56_004
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let server = HookServer(appState: appState)
            let payload: [String: Any] = [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let routed = server.routeSubsessionPayloadIfNeededForTesting(data: data)
            XCTAssertNotNil(routed.responseData)
            XCTAssertEqual(routed.processedData, data)
        }
    }

    // MARK: - Parent selection

    func testMergeModePpidFallbackLeavesChildWhenMultipleSameSourceParents() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_005
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(-120)
            )
            appState.sessions[otherId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date()
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            // Ambiguous IDE process — do not guess which chat owns the Task.
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    func testMergeModePpidFallbackAcceptsUniqueIdleParent() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_006
            let appState = AppState()
            var idle = makeRunningCursorSession(cliPid: ppid)
            idle.status = .idle
            appState.sessions[parentId] = idle

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            // Unique same-pid card — idle main is still a valid fold target.
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    /// Idle main + running orphan Task sharing the IDE pid: must fold onto the
    /// main card, never treat the orphan Task as parent.
    func testMergeModePpidFallbackPrefersIdleMainOverRunningOrphanTask() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_022
            let orphanTaskId = otherId
            let newTaskId = childId
            let appState = AppState()

            var idleMain = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(-60),
                startTime: Date().addingTimeInterval(-600)
            )
            idleMain.status = .idle
            idleMain.transcriptPath =
                "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
            idleMain.providerSessionId = parentId
            appState.sessions[parentId] = idleMain

            // Orphan Task card still running under the same IDE process.
            appState.sessions[orphanTaskId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date(),
                startTime: Date().addingTimeInterval(-30)
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": newTaskId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, newTaskId)
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    /// Foldable Task transcript must never win `_ppid` parent selection over a
    /// same-pid main chat, even when the Task is the only non-idle card.
    func testMergeModePpidFallbackExcludesFoldableTaskCardAsParent() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_023
            let orphanTaskId = otherId
            let appState = AppState()

            var idleMain = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(-90),
                startTime: Date().addingTimeInterval(-600)
            )
            idleMain.status = .idle
            appState.sessions[parentId] = idleMain

            var orphanTask = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date(),
                startTime: Date().addingTimeInterval(-20)
            )
            orphanTask.transcriptPath =
                "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/subagents/\(orphanTaskId).jsonl"
            appState.sessions[orphanTaskId] = orphanTask

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
        }
    }

    func testMergeModePpidFallbackSkipsStaleParentActivity() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_007
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(-400)
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    func testMergeModePpidFallbackCursorCliPrefersExactSourceThenSibling() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_008
            let appState = AppState()
            // Only IDE cursor parent — cursor-cli child should still find sibling.
            appState.sessions[parentId] = makeRunningCursorSession(source: "cursor", cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor-cli",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    func testMergeModePpidFallbackPrefersExactSourceOverSibling() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_009
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(
                source: "cursor",
                cliPid: ppid,
                lastActivity: Date()
            )
            appState.sessions[otherId] = makeRunningCursorSession(
                source: "cursor-cli",
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(10)
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            // Exact source wins even if sibling is slightly more recent.
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
        }
    }

    // MARK: - Safety: must not ppid-fold main chat / separate mode

    func testMergeModeDoesNotPpidFoldMainChatWithTranscriptParent() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_010
            let path = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)
            appState.sessions[otherId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(5)
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": parentId,
                "transcript_path": path,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    /// Main chat hooks sometimes omit `transcript_path`. If a sibling Task card
    /// shares the IDE pid, naive `_ppid` fallback would rewrite the main session
    /// onto the Task (or tag it as a subagent) and freeze parent chat text.
    func testMergeModeDoesNotPpidFoldEstablishedMainChatWithoutTranscriptOntoSibling() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_020
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)
            appState.sessions[otherId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(5)
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": parentId,
                "_ppid": ppid,
                "hook_event_name": "beforeSubmitPrompt",
                "prompt": "continue the investigation",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertNil(routed.raw["agent_id"])
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    /// Unknown Task id (no card yet) must still fold onto the unique parent.
    func testMergeModeStillPpidFoldsUnknownChildWhenMainCardExists() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_021
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    func testSeparateModeDoesNotApplyPpidFallback() throws {
        try withPluginSessionMode("separate") {
            let ppid = 56_011
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
            XCTAssertNil(routed.responseData)
        }
    }

    func testMergeModeWithoutMatchingParentLeavesChildUnchanged() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            // Wrong pid / no sessions.
            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": 56_012,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    // MARK: - Transcript fold still preferred when path is foldable

    func testMergeModeTranscriptFoldPreferredOverPpid() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_013
            let path = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
            let appState = AppState()
            // More recent "distractor" same pid — transcript fold must still win.
            appState.sessions[parentId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date().addingTimeInterval(-30)
            )
            appState.sessions[otherId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: Date()
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "transcript_path": path,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
            XCTAssertEqual(routed.raw["_cursor_subagent"] as? Bool, true)
        }
    }

    func testMergeModeTranscriptFoldResolvesProviderSessionIdToAppStateKey() throws {
        try withPluginSessionMode("merge") {
            let providerUUID = parentId
            let appKey = "cursor-app:\(providerUUID)"
            let path = "/Users/u/.cursor/projects/x/agent-transcripts/\(providerUUID)/\(providerUUID).jsonl"
            let appState = AppState()
            appState.sessions[appKey] = makeRunningCursorSession(
                cliPid: 56_014,
                providerSessionId: providerUUID
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "transcript_path": path,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, appKey)
            XCTAssertEqual(routed.raw["agent_id"] as? String, childId)
        }
    }

    func testMergeModePpidFallbackAcceptsStringPpid() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_015
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(cliPid: ppid)

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": "\(ppid)",
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
        }
    }

    func testMergeModePpidFallbackRejectsZeroPpid() throws {
        try withPluginSessionMode("merge") {
            let appState = AppState()
            var weird = makeRunningCursorSession(cliPid: 0)
            weird.cliPid = 0
            appState.sessions[parentId] = weird

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": 0,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    func testMergeModePpidFallbackAllowsWaitingApprovalParent() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_016
            let appState = AppState()
            var waiting = makeRunningCursorSession(cliPid: ppid)
            waiting.status = .waitingApproval
            appState.sessions[parentId] = waiting

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, parentId)
        }
    }

    func testMergeModePpidFallbackLeavesChildWhenEqualActivityAmbiguous() throws {
        try withPluginSessionMode("merge") {
            let ppid = 56_017
            let sharedActivity = Date()
            let appState = AppState()
            appState.sessions[parentId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: sharedActivity
            )
            appState.sessions[otherId] = makeRunningCursorSession(
                cliPid: ppid,
                lastActivity: sharedActivity
            )

            let routed = try route(appState: appState, payload: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": ppid,
                "hook_event_name": "PostToolUse",
            ])
            XCTAssertEqual(routed.raw["session_id"] as? String, childId)
            XCTAssertNil(routed.raw["_cursor_subagent"])
        }
    }

    func testMergeModeWithoutPpidKeyDoesNotForceCursorParseForSourceOnlyPayload() throws {
        try withPluginSessionMode("merge") {
            // No agent-transcripts and no _ppid key → ppid fallback probe must stay cold.
            let data = Data(#"{"_source":"cursor","session_id":"abc","hook_event_name":"PostToolUse"}"#.utf8)
            XCTAssertFalse(HookServer.mayNeedCursorSubsessionRouting(data: data))
            XCTAssertTrue(HookServer.mayBeCursorHookSource(data: data))
            // Gate used by routeSubsessionPayloadIfNeeded: source alone is not enough.
            XCTAssertNil(data.range(of: Data(#""_ppid""#.utf8)))
        }
    }
}
