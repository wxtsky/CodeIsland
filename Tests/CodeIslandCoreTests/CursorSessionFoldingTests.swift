import XCTest
@testable import CodeIslandCore

final class CursorSessionFoldingTests: XCTestCase {

    func testParentIdFromParentTranscriptPath() {
        let path = "/Users/u/.cursor/projects/Users-u-Code-Reelay/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl"
        XCTAssertEqual(
            CursorSessionFolding.parentConversationId(fromTranscriptPath: path),
            "e1247fd5-d9a0-48ef-8457-0304606b1833"
        )
    }

    func testParentIdFromSubagentsTranscriptPath() {
        let path = "/Users/u/.cursor/projects/Users-u-Code-Reelay/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/subagents/2528cb91-6379-48f2-aff8-40f4b804dafa.jsonl"
        XCTAssertEqual(
            CursorSessionFolding.parentConversationId(fromTranscriptPath: path),
            "e1247fd5-d9a0-48ef-8457-0304606b1833"
        )
    }

    func testFoldTargetWhenChildSessionDiffersFromTranscriptParent() {
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl"
        XCTAssertEqual(
            CursorSessionFolding.foldTarget(
                childSessionId: "2528cb91-6379-48f2-aff8-40f4b804dafa",
                transcriptPath: path
            ),
            "e1247fd5-d9a0-48ef-8457-0304606b1833"
        )
    }

    func testFoldTargetNilWhenSessionMatchesParent() {
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl"
        XCTAssertNil(
            CursorSessionFolding.foldTarget(
                childSessionId: "e1247fd5-d9a0-48ef-8457-0304606b1833",
                transcriptPath: path
            )
        )
    }

    func testFoldTargetNilWithoutTranscriptPath() {
        XCTAssertNil(
            CursorSessionFolding.foldTarget(
                childSessionId: "2528cb91-6379-48f2-aff8-40f4b804dafa",
                transcriptPath: nil
            )
        )
    }

    func testRouterLeavesCursorChildWhenModeIsSeparate() {
        let raw: [String: Any] = [
            "_source": "cursor",
            "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl",
            "hook_event_name": "beforeReadFile",
        ]
        XCTAssertEqual(CursorSubsessionRouter.decide(raw: raw, mode: "separate"), .leave)
    }

    func testRouterMergesCursorChildWhenModeIsMerge() {
        let raw: [String: Any] = [
            "_source": "cursor",
            "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl",
            "hook_event_name": "beforeReadFile",
        ]
        XCTAssertEqual(
            CursorSubsessionRouter.decide(raw: raw, mode: "merge"),
            .merge(
                parentSessionId: "e1247fd5-d9a0-48ef-8457-0304606b1833",
                childSessionId: "2528cb91-6379-48f2-aff8-40f4b804dafa"
            )
        )
    }

    func testRouterHidesCursorChildWhenModeIsHide() {
        let raw: [String: Any] = [
            "_source": "cursor",
            "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl",
        ]
        XCTAssertEqual(CursorSubsessionRouter.decide(raw: raw, mode: "hide"), .hide)
    }

    func testRouterLeavesUnrelatedCursorSession() {
        let raw: [String: Any] = [
            "_source": "cursor",
            "session_id": "e1247fd5-d9a0-48ef-8457-0304606b1833",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/e1247fd5-d9a0-48ef-8457-0304606b1833.jsonl",
        ]
        XCTAssertEqual(CursorSubsessionRouter.decide(raw: raw, mode: "merge"), .leave)
    }

    func testRouterLeavesNonCursorSourcesWithoutCursorTranscript() {
        let raw: [String: Any] = [
            "_source": "codex",
            "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa",
            "transcript_path": "/Users/u/.cursor/projects/x/agent-transcripts/e1247fd5-d9a0-48ef-8457-0304606b1833/subagents/2528cb91-6379-48f2-aff8-40f4b804dafa.jsonl",
        ]
        XCTAssertEqual(CursorSubsessionRouter.decide(raw: raw, mode: "merge"), .leave)

        let claudeElsewhere: [String: Any] = [
            "_source": "claude",
            "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa",
            "transcript_path": "/Users/u/.claude/projects/-tmp/2528cb91-6379-48f2-aff8-40f4b804dafa.jsonl",
        ]
        XCTAssertEqual(CursorSubsessionRouter.decide(raw: claudeElsewhere, mode: "merge"), .leave)
    }

    func testShouldAttemptPpidFallbackOnlyWithoutParseableTranscriptParent() {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let mainPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"

        // Main chat: parent UUID parsed == session_id → never ppid-fallback.
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": parentId,
                "transcript_path": mainPath,
            ])
        )

        // Foldable Task path: parent UUID parses → decide handles merge; no ppid.
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
                "transcript_path": mainPath,
            ])
        )

        // No transcript_path → ppid fallback allowed.
        XCTAssertTrue(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": 42,
            ])
        )

        // Unparseable path (no agent-transcripts UUID) → ppid fallback allowed.
        XCTAssertTrue(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
                "transcript_path": "/tmp/other.jsonl",
                "_ppid": 42,
            ])
        )

        // Missing _ppid → no fallback.
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
            ])
        )

        // Invalid / zero ppid → no fallback.
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": 0,
            ])
        )
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": -1,
            ])
        )
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "session_id": childId,
                "_ppid": "nope",
            ])
        )

        // String / camelCase sessionId + positive ppid still qualify.
        XCTAssertTrue(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor-cli",
                "sessionId": childId,
                "_ppid": "7",
            ])
        )
        XCTAssertTrue(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor-cli",
                "sessionId": childId,
                "_ppid": NSNumber(value: 7),
            ])
        )

        // Missing session id → no fallback.
        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "cursor",
                "_ppid": 42,
            ])
        )

        XCTAssertFalse(
            CursorSubsessionRouter.shouldAttemptPpidParentFallback(raw: [
                "_source": "claude",
                "session_id": childId,
                "_ppid": 42,
            ])
        )
    }

    func testChoosePpidFallbackParentPrefersMainOverRunningTask() {
        let older = Date().addingTimeInterval(-600)
        let newer = Date().addingTimeInterval(-30)
        let chosen = CursorSubsessionRouter.choosePpidFallbackParentId(candidates: [
            (sessionId: "main", status: .idle, startTime: older, isMain: true, isTask: false),
            (sessionId: "task", status: .running, startTime: newer, isMain: false, isTask: false),
        ])
        XCTAssertEqual(chosen, "main")
    }

    func testChoosePpidFallbackParentExcludesTaskCards() {
        let chosen = CursorSubsessionRouter.choosePpidFallbackParentId(candidates: [
            (sessionId: "main", status: .idle, startTime: Date().addingTimeInterval(-600), isMain: false, isTask: false),
            (sessionId: "task", status: .running, startTime: Date(), isMain: false, isTask: true),
        ])
        XCTAssertEqual(chosen, "main")
    }

    func testChoosePpidFallbackParentRejectsTwoLiveChats() {
        let chosen = CursorSubsessionRouter.choosePpidFallbackParentId(candidates: [
            (sessionId: "a", status: .running, startTime: Date().addingTimeInterval(-100), isMain: false, isTask: false),
            (sessionId: "b", status: .running, startTime: Date(), isMain: false, isTask: false),
        ])
        XCTAssertNil(chosen)
    }

    func testIsLikelyCursorMainAndTaskCardFromTranscript() {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let mainPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
        let taskPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/subagents/\(childId).jsonl"

        XCTAssertTrue(
            CursorSubsessionRouter.isLikelyCursorMainCard(
                sessionId: parentId,
                providerSessionId: parentId,
                transcriptPath: mainPath,
                hasSubagents: false
            )
        )
        XCTAssertTrue(
            CursorSubsessionRouter.isLikelyCursorTaskCard(
                sessionId: childId,
                providerSessionId: nil,
                transcriptPath: taskPath
            )
        )
        XCTAssertFalse(
            CursorSubsessionRouter.isLikelyCursorTaskCard(
                sessionId: parentId,
                providerSessionId: parentId,
                transcriptPath: mainPath
            )
        )
    }

    func testRouterMergesMisbrandedClaudeDefaultCursorTask() {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/subagents/\(childId).jsonl"
        let raw: [String: Any] = [
            "_source": "claude",
            "session_id": childId,
            "transcript_path": path,
        ]
        XCTAssertEqual(
            CursorSubsessionRouter.decide(raw: raw, mode: "merge"),
            .merge(parentSessionId: parentId, childSessionId: childId)
        )
        var rewritten = raw
        CursorSubsessionRouter.applyMerge(
            to: &rewritten,
            parentSessionId: parentId,
            childSessionId: childId
        )
        XCTAssertEqual(rewritten["_source"] as? String, "cursor")
        XCTAssertEqual(rewritten["_cursor_subagent"] as? Bool, true)
    }

    func testShouldTreatAsCursorFamilyForMisbrandedClaudePath() {
        let path = "/Users/u/.cursor/projects/x/agent-transcripts/p/subagents/c.jsonl"
        XCTAssertTrue(
            CursorSubsessionRouter.shouldTreatAsCursorFamily(
                declaredSource: "claude",
                transcriptPath: path
            )
        )
        XCTAssertTrue(CursorSessionFolding.isCursorAgentTranscriptPath(path))
        XCTAssertFalse(
            CursorSubsessionRouter.shouldTreatAsCursorFamily(
                declaredSource: "claude",
                transcriptPath: nil
            )
        )
    }

    func testApplyMergeRewritesSessionAndSetsAgentId() {
        var raw: [String: Any] = [
            "session_id": "2528cb91-6379-48f2-aff8-40f4b804dafa",
            "hook_event_name": "beforeShellExecution",
        ]
        CursorSubsessionRouter.applyMerge(
            to: &raw,
            parentSessionId: "e1247fd5-d9a0-48ef-8457-0304606b1833",
            childSessionId: "2528cb91-6379-48f2-aff8-40f4b804dafa"
        )
        XCTAssertEqual(raw["session_id"] as? String, "e1247fd5-d9a0-48ef-8457-0304606b1833")
        XCTAssertEqual(raw["agent_id"] as? String, "2528cb91-6379-48f2-aff8-40f4b804dafa")
        XCTAssertEqual(raw["agent_type"] as? String, "cursor-subagent")
        XCTAssertEqual(raw["_cursor_subagent"] as? Bool, true)
        XCTAssertNil(raw["_cursor_subagent_session_id"])
        XCTAssertNil(raw["_cursor_subagent_event"])
    }

    func testMergedCursorSubagentAfterAgentResponseUpdatesParentChatWithoutCompleting() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.lastUserPrompt = "main prompt"
        parent.lastAssistantMessage = "parent reply"
        parent.subagents[childId] = SubagentState(agentId: childId, agentType: "cursor-subagent")

        var sessions = [parentId: parent]
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "afterAgentResponse",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
            "text": "child-only reply",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        // Merge-into-main: surface the folded reply on the parent card…
        XCTAssertEqual(sessions[parentId]?.lastAssistantMessage, "child-only reply")
        XCTAssertEqual(sessions[parentId]?.recentMessages.last?.text, "child-only reply")
        XCTAssertEqual(sessions[parentId]?.recentMessages.last?.isUser, false)
        // …but never treat a Task response as parent-turn completion.
        XCTAssertEqual(sessions[parentId]?.status, .running)
        XCTAssertFalse(effects.contains(where: {
            if case .enqueueCompletion = $0 { return true }
            return false
        }))
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .processing)
    }

    func testMergedCursorUserPromptSubmitUpdatesParentChat() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.lastUserPrompt = "old prompt"
        parent.addRecentMessage(ChatMessage(isUser: true, text: "old prompt"))
        parent.subagents[childId] = SubagentState(agentId: childId, agentType: "cursor-subagent")
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "beforeSubmitPrompt",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "_cursor_subagent": true,
            "prompt": "continue after the root cause",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.lastUserPrompt, "continue after the root cause")
        XCTAssertEqual(sessions[parentId]?.recentMessages.last?.text, "continue after the root cause")
        XCTAssertEqual(sessions[parentId]?.recentMessages.last?.isUser, true)
        XCTAssertEqual(sessions[parentId]?.status, .running)
        XCTAssertEqual(sessions[parentId]?.currentTool, "Agent")
    }

    func testCodexSubagentUserPromptSubmitDoesNotOverwriteParentChat() throws {
        let parentId = "thread-parent"
        let childId = "thread-child"
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.lastUserPrompt = "parent prompt"
        parent.addRecentMessage(ChatMessage(isUser: true, text: "parent prompt"))
        parent.subagents[childId] = SubagentState(agentId: childId, agentType: "worker")
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "session_id": parentId,
            "_source": "codex",
            "agent_id": childId,
            "prompt": "child-only prompt must not replace parent",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.lastUserPrompt, "parent prompt")
        XCTAssertEqual(sessions[parentId]?.recentMessages.last?.text, "parent prompt")
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .processing)
    }

    func testCodexSubagentAfterAgentResponseDoesNotOverwriteParentChat() throws {
        let parentId = "thread-parent"
        let childId = "thread-child"
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.lastAssistantMessage = "parent reply"
        parent.addRecentMessage(ChatMessage(isUser: false, text: "parent reply"))
        parent.subagents[childId] = SubagentState(agentId: childId, agentType: "worker")
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "AfterAgentResponse",
            "session_id": parentId,
            "_source": "codex",
            "agent_id": childId,
            "text": "child-only reply must not replace parent",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.lastAssistantMessage, "parent reply")
        XCTAssertEqual(sessions[parentId]?.recentMessages.filter { !$0.isUser }.count, 1)
        XCTAssertEqual(sessions[parentId]?.recentMessages.last?.text, "parent reply")
        XCTAssertFalse(effects.contains(where: {
            if case .enqueueCompletion = $0 { return true }
            return false
        }))
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .processing)
    }

    func testSubagentStopRecordsClosedTombstoneAndClearsOnRestart() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.subagents[childId] = SubagentState(agentId: childId, agentType: "cursor-subagent")
        var sessions = [parentId: parent]

        let stopData = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "stop",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
        ] as [String: Any])
        let stopEvent = try XCTUnwrap(HookEvent(from: stopData))
        _ = reduceEvent(sessions: &sessions, event: stopEvent, maxHistory: 10)

        XCTAssertNil(sessions[parentId]?.subagents[childId])
        XCTAssertEqual(sessions[parentId]?.closedSubagentIds, [childId])

        let startData = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SubagentStart",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
        ] as [String: Any])
        let startEvent = try XCTUnwrap(HookEvent(from: startData))
        _ = reduceEvent(sessions: &sessions, event: startEvent, maxHistory: 10)

        XCTAssertNotNil(sessions[parentId]?.subagents[childId])
        XCTAssertTrue(sessions[parentId]?.closedSubagentIds.isEmpty == true)
    }

    func testLateAfterAgentResponseDoesNotClearStopTombstone() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .processing
        parent.recordClosedSubagentId(childId)
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "afterAgentResponse",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
            "text": "late child reply",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertNil(sessions[parentId]?.subagents[childId])
        XCTAssertEqual(sessions[parentId]?.closedSubagentIds, [childId])
        XCTAssertEqual(sessions[parentId]?.status, .processing)
    }

    func testSeparateCursorStopSelfTombstonesSessionId() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
        var child = SessionSnapshot()
        child.source = "cursor"
        child.status = .running
        child.transcriptPath = transcriptPath
        child.cliPid = 12_345
        child.cliStartTime = Date(timeIntervalSince1970: 1_700_000_000)
        var sessions = [childId: child]

        let stopData = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "stop",
            "session_id": childId,
            "_source": "cursor",
        ] as [String: Any])
        let stopEvent = try XCTUnwrap(HookEvent(from: stopData))
        _ = reduceEvent(sessions: &sessions, event: stopEvent, maxHistory: 10)

        XCTAssertEqual(sessions[childId]?.status, .idle)
        XCTAssertEqual(sessions[childId]?.closedSubagentIds, [childId])
        XCTAssertNil(sessions[childId]?.cliPid)
        XCTAssertNil(sessions[childId]?.cliStartTime)
    }

    func testParentCursorStopDoesNotSelfTombstoneOrClearCliPid() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.transcriptPath = transcriptPath
        parent.cliPid = 98_765
        parent.cliStartTime = Date(timeIntervalSince1970: 1_700_000_000)
        var sessions = [parentId: parent]

        let stopData = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "stop",
            "session_id": parentId,
            "_source": "cursor",
        ] as [String: Any])
        let stopEvent = try XCTUnwrap(HookEvent(from: stopData))
        _ = reduceEvent(sessions: &sessions, event: stopEvent, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.status, .idle)
        XCTAssertTrue(sessions[parentId]?.closedSubagentIds.isEmpty == true)
        XCTAssertEqual(sessions[parentId]?.cliPid, 98_765)
        XCTAssertEqual(sessions[parentId]?.cliStartTime, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testParentAfterAgentResponseKeepsActiveWhileFoldedTaskRunning() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.currentTool = "Agent"
        parent.toolDescription = "cursor-subagent"
        var sub = SubagentState(agentId: childId, agentType: "cursor-subagent")
        sub.status = .running
        parent.subagents[childId] = sub
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "afterAgentResponse",
            "session_id": parentId,
            "_source": "cursor",
            "text": "parent turn done; task still working",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(
            sessions[parentId]?.lastAssistantMessage,
            "parent turn done; task still working"
        )
        XCTAssertEqual(sessions[parentId]?.status, .running)
        XCTAssertEqual(sessions[parentId]?.currentTool, "Agent")
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .running)
        XCTAssertFalse(effects.contains(where: {
            if case .enqueueCompletion = $0 { return true }
            return false
        }))
    }

    func testUserPromptSubmitClearsCursorSelfTombstone() throws {
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var child = SessionSnapshot()
        child.source = "cursor"
        child.status = .idle
        child.recordClosedSubagentId(childId)
        var sessions = [childId: child]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "beforeSubmitPrompt",
            "session_id": childId,
            "_source": "cursor",
            "prompt": "retry",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(sessions[childId]?.closedSubagentIds.isEmpty == true)
        XCTAssertEqual(sessions[childId]?.status, .processing)
    }

    func testMergedCursorNotificationWithQuestionSetsWaitingQuestion() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.subagents[childId] = SubagentState(agentId: childId, agentType: "cursor-subagent")
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Notification",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
            "question": "Which approach should we take?",
            "options": ["A", "B"],
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.status, .waitingQuestion)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .waitingQuestion)
        XCTAssertTrue(effects.contains(where: {
            if case .setActiveSession(let id) = $0 { return id == parentId }
            return false
        }))
    }

    func testParentStopKeepsActiveWhileFoldedTaskRunning() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.currentTool = "Agent"
        var sub = SubagentState(agentId: childId, agentType: "cursor-subagent")
        sub.status = .running
        parent.subagents[childId] = sub
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "stop",
            "session_id": parentId,
            "_source": "cursor",
            "stop_reason": "user",
            "last_assistant_message": "main turn ended",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.status, .running)
        XCTAssertEqual(sessions[parentId]?.currentTool, "Agent")
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .running)
        XCTAssertFalse(sessions[parentId]?.interrupted == true)
        XCTAssertFalse(sessions[parentId]?.closedSubagentIds.contains(parentId) == true)
        XCTAssertFalse(effects.contains(where: {
            if case .enqueueCompletion = $0 { return true }
            return false
        }))
    }

    func testMergeFirstTaskHookFillsParentSourceAndTranscript() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
        var sessions: [String: SessionSnapshot] = [:]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "beforeReadFile",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
            "_cursor_subagent": true,
            "transcript_path": transcriptPath,
            "_ppid": 42_424,
            "tool_name": "Read",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.source, "cursor")
        XCTAssertEqual(sessions[parentId]?.transcriptPath, transcriptPath)
        XCTAssertEqual(sessions[parentId]?.cliPid, 42_424)
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.currentTool, "Read")
    }

    func testMergeFirstTaskHookDoesNotOverwriteKnownParentSource() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.cwd = "/tmp/known"
        parent.transcriptPath = "/known.jsonl"
        parent.cliPid = 7
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "beforeReadFile",
            "session_id": parentId,
            "_source": "cursor-cli",
            "agent_id": childId,
            "cwd": "/tmp/child-only",
            "transcript_path": "/child.jsonl",
            "_ppid": 99,
            "tool_name": "Read",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertEqual(sessions[parentId]?.source, "cursor")
        XCTAssertEqual(sessions[parentId]?.cwd, "/tmp/known")
        XCTAssertEqual(sessions[parentId]?.transcriptPath, "/known.jsonl")
        XCTAssertEqual(sessions[parentId]?.cliPid, 7)
    }

    func testCursorUserPromptSubmitClearsMergedTombstoneAndReopens() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .processing
        parent.recordClosedSubagentId(childId)
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "beforeSubmitPrompt",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "agent_type": "cursor-subagent",
            "_cursor_subagent": true,
            "prompt": "retry the task",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertTrue(sessions[parentId]?.closedSubagentIds.isEmpty == true)
        XCTAssertNotNil(sessions[parentId]?.subagents[childId])
        XCTAssertEqual(sessions[parentId]?.subagents[childId]?.status, .processing)
        XCTAssertEqual(sessions[parentId]?.status, .running)
    }

    func testLatePreToolUseStillBlockedByClosedTombstone() throws {
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .processing
        parent.recordClosedSubagentId(childId)
        var sessions = [parentId: parent]

        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "beforeReadFile",
            "session_id": parentId,
            "_source": "cursor",
            "agent_id": childId,
            "tool_name": "Read",
        ] as [String: Any])
        let event = try XCTUnwrap(HookEvent(from: data))
        _ = reduceEvent(sessions: &sessions, event: event, maxHistory: 10)

        XCTAssertNil(sessions[parentId]?.subagents[childId])
        XCTAssertEqual(sessions[parentId]?.closedSubagentIds, [childId])
    }
}
