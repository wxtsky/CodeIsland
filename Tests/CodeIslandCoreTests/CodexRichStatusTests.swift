import XCTest
@testable import CodeIslandCore

final class CodexRichStatusTests: XCTestCase {
    func testCodexToolsMapToStableActivityCategories() throws {
        let cases: [(String, ToolActivityCategory, String)] = [
            ("read_file", .reading, "Reading"),
            ("grep_search", .searching, "Searching"),
            ("apply_patch", .editing, "Editing"),
            ("exec_command", .shell, "Running command"),
            ("browser_navigate", .browser, "Using browser"),
            ("mcp__github__get_issue", .mcp, "Calling MCP"),
            ("spawn_agent", .delegation, "Delegating"),
        ]

        for (toolName, category, label) in cases {
            let event = try decode([
                "hook_event_name": "PreToolUse",
                "session_id": "codex-rich-status",
                "_source": "codex",
                "tool_name": toolName,
                "tool_input": [:],
            ])

            XCTAssertEqual(event.activityCategory, category, toolName)
            XCTAssertEqual(event.activityLabel, label, toolName)
        }
    }

    func testOtherProvidersKeepTheirOriginalToolName() throws {
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "claude-session",
            "_source": "claude",
            "tool_name": "Read",
            "tool_input": ["file_path": "/tmp/example.swift"],
        ])

        XCTAssertEqual(event.activityCategory, .other)
        XCTAssertEqual(event.activityLabel, "Read")
        XCTAssertEqual(event.toolDescription, "example.swift")
    }

    func testCodexShellSummaryRedactsSecretsHomePathAndLongOutput() throws {
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "codex-rich-status",
            "_source": "codex",
            "tool_name": "exec_command",
            "tool_input": [
                "command": "curl -H 'Authorization: Bearer super-secret-token' 'https://example.com/run?token=private-value' --password hunter2 /Users/alice/work/project/" + String(repeating: "x", count: 180),
            ],
        ])

        let summary = try XCTUnwrap(event.toolDescription)
        XCTAssertFalse(summary.contains("super-secret-token"))
        XCTAssertFalse(summary.contains("private-value"))
        XCTAssertFalse(summary.contains("hunter2"))
        XCTAssertFalse(summary.contains("/Users/alice"))
        XCTAssertLessThanOrEqual(summary.count, 120)
        XCTAssertTrue(summary.contains("[REDACTED]"))
    }

    func testCodexFileActivitiesExposeOnlyBasename() throws {
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "codex-rich-status",
            "_source": "codex",
            "tool_name": "read_file",
            "tool_input": ["file_path": "/Users/alice/SecretProject/Sources/App.swift"],
        ])

        XCTAssertEqual(event.toolDescription, "App.swift")
    }

    func testCodexShellSummaryRedactsHeaderAndProviderTokens() throws {
        let githubToken = "ghp_123456789012345678901234567890123456"
        let openAIToken = "sk-123456789012345678901234567890"
        let awsAccessKey = "AKIA1234567890123456"
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "codex-rich-status",
            "_source": "codex",
            "tool_name": "exec_command",
            "tool_input": [
                "command": "curl -H 'X-Api-Key: \(githubToken)' -H 'X-Auth-Token: \(openAIToken)' https://example.com/\(awsAccessKey)",
            ],
        ])

        let summary = try XCTUnwrap(event.toolDescription)
        XCTAssertFalse(summary.contains(githubToken))
        XCTAssertFalse(summary.contains(openAIToken))
        XCTAssertFalse(summary.contains(awsAccessKey))
        XCTAssertTrue(summary.contains("[REDACTED]"))
    }

    func testCodexShellSummaryRedactsAWSCompoundCredentialNames() throws {
        let secretAccessKey = "1234567890abcdefghij1234567890ABCDEFGHIJ"
        let sessionToken = "session-token-shorter-than-generic-threshold"
        let event = try decode([
            "hook_event_name": "PreToolUse",
            "session_id": "codex-rich-status",
            "_source": "codex",
            "tool_name": "exec_command",
            "tool_input": [
                "command": "AWS_SECRET_ACCESS_KEY=\(secretAccessKey) curl -H 'X-Amz-Security-Token: \(sessionToken)' example.com",
            ],
        ])

        let summary = try XCTUnwrap(event.toolDescription)
        XCTAssertFalse(summary.contains(secretAccessKey))
        XCTAssertFalse(summary.contains(sessionToken))
        XCTAssertEqual(summary.components(separatedBy: "[REDACTED]").count - 1, 2)
    }

    func testCodexCompactAndInterruptLifecycleUpdatesSessionState() throws {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .running
        session.currentTool = "Running command"
        var sessions = ["codex-rich-status": session]

        _ = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "PreCompact",
                "session_id": "codex-rich-status",
                "_source": "codex",
            ]),
            maxHistory: 10
        )
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .processing)
        XCTAssertEqual(sessions["codex-rich-status"]?.currentTool, "Compacting")

        _ = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "PostCompact",
                "session_id": "codex-rich-status",
                "_source": "codex",
            ]),
            maxHistory: 10
        )
        XCTAssertNil(sessions["codex-rich-status"]?.currentTool)
        XCTAssertNil(sessions["codex-rich-status"]?.toolDescription)

        let effects = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "Interrupt",
                "session_id": "codex-rich-status",
                "_source": "codex",
            ]),
            maxHistory: 10
        )
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .idle)
        XCTAssertTrue(sessions["codex-rich-status"]?.interrupted == true)
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: "codex-rich-status")))

        let staleEffects = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "PostToolUse",
                "session_id": "codex-rich-status",
                "_source": "codex",
                "tool_name": "exec_command",
            ]),
            maxHistory: 10
        )
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .idle)
        XCTAssertTrue(sessions["codex-rich-status"]?.interrupted == true)
        XCTAssertTrue(staleEffects.isEmpty)
    }

    func testCodexSubagentLifecycleSurfacesActivity() throws {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        var sessions = ["codex-rich-status": session]

        _ = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "SubagentStart",
                "session_id": "codex-rich-status",
                "agent_id": "reviewer-1",
                "agent_type": "reviewer",
                "_source": "codex",
            ]),
            maxHistory: 10
        )
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .running)
        XCTAssertEqual(sessions["codex-rich-status"]?.currentTool, "Agent")
        XCTAssertEqual(sessions["codex-rich-status"]?.subagents["reviewer-1"]?.agentType, "reviewer")

        _ = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "PreToolUse",
                "session_id": "codex-rich-status",
                "agent_id": "reviewer-1",
                "_source": "codex",
                "tool_name": "read_file",
                "tool_input": ["file_path": "/tmp/Review.swift"],
            ]),
            maxHistory: 10
        )
        XCTAssertEqual(sessions["codex-rich-status"]?.subagents["reviewer-1"]?.currentTool, "Reading")

        _ = reduceEvent(
            sessions: &sessions,
            event: try decode([
                "hook_event_name": "SubagentStop",
                "session_id": "codex-rich-status",
                "agent_id": "reviewer-1",
                "_source": "codex",
            ]),
            maxHistory: 10
        )
        XCTAssertTrue(sessions["codex-rich-status"]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .processing)
    }

    /// Codex fires SubagentStop per child *turn* and reuses the child's thread
    /// id as agent_id for follow-up turns (send_message / followup_task) with
    /// no new SubagentStart. The second turn's hooks must still be processed.
    func testCodexSubagentSecondTurnAfterSubagentStopIsStillTracked() throws {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        var sessions = ["codex-rich-status": session]
        func send(_ payload: [String: Any]) throws {
            var payload = payload
            payload["session_id"] = "codex-rich-status"
            payload["_source"] = "codex"
            _ = reduceEvent(sessions: &sessions, event: try decode(payload), maxHistory: 10)
        }

        try send(["hook_event_name": "SubagentStart", "agent_id": "worker-1", "agent_type": "worker"])
        try send(["hook_event_name": "PreToolUse", "agent_id": "worker-1", "tool_name": "exec_command"])
        try send(["hook_event_name": "PostToolUse", "agent_id": "worker-1", "tool_name": "exec_command"])
        try send(["hook_event_name": "SubagentStop", "agent_id": "worker-1", "agent_type": "worker"])
        XCTAssertTrue(sessions["codex-rich-status"]?.subagents.isEmpty == true)
        XCTAssertFalse(sessions["codex-rich-status"]?.hasClosedSubagentId("worker-1") == true)

        // Follow-up turn on the same child thread.
        try send(["hook_event_name": "UserPromptSubmit", "agent_id": "worker-1", "agent_type": "worker", "prompt": "follow up"])
        try send([
            "hook_event_name": "PreToolUse", "agent_id": "worker-1", "agent_type": "worker",
            "tool_name": "read_file", "tool_input": ["file_path": "/tmp/Second.swift"],
        ])
        XCTAssertEqual(sessions["codex-rich-status"]?.subagents["worker-1"]?.status, .running)
        XCTAssertEqual(sessions["codex-rich-status"]?.subagents["worker-1"]?.currentTool, "Reading")
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .running)

        try send(["hook_event_name": "PostToolUse", "agent_id": "worker-1", "tool_name": "read_file"])
        try send(["hook_event_name": "SubagentStop", "agent_id": "worker-1", "agent_type": "worker"])
        try send(["hook_event_name": "Stop"])
        XCTAssertTrue(sessions["codex-rich-status"]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .idle)
    }

    /// Non-Codex providers keep the tombstone: a Claude Task agent_id is
    /// single-use, and late hooks after its SubagentStop must stay dropped.
    func testClaudeSubagentStopStillTombstonesAgentId() throws {
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .running
        var sessions = ["claude-session": session]
        for payload: [String: Any] in [
            ["hook_event_name": "SubagentStart", "agent_id": "task-1", "agent_type": "Explore"],
            ["hook_event_name": "SubagentStop", "agent_id": "task-1"],
            ["hook_event_name": "PreToolUse", "agent_id": "task-1", "tool_name": "Read"],
        ] {
            var payload = payload
            payload["session_id"] = "claude-session"
            payload["_source"] = "claude"
            _ = reduceEvent(sessions: &sessions, event: try decode(payload), maxHistory: 10)
        }

        XCTAssertTrue(sessions["claude-session"]?.hasClosedSubagentId("task-1") == true)
        XCTAssertNil(sessions["claude-session"]?.subagents["task-1"])
    }

    /// Interrupting the root turn leaves spawned Codex agents running. Their
    /// SubagentStop must still clear them, or the next root Stop treats the
    /// session as having active subagents and pins it to running/Agent.
    func testSubagentStopAfterRootInterruptStillClearsSubagent() throws {
        var session = SessionSnapshot()
        session.source = "codex"
        session.status = .processing
        var sessions = ["codex-rich-status": session]

        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "SubagentStart",
            "session_id": "codex-rich-status",
            "agent_id": "worker-1",
            "agent_type": "worker",
            "_source": "codex",
        ]), maxHistory: 10)
        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "Interrupt",
            "session_id": "codex-rich-status",
            "_source": "codex",
        ]), maxHistory: 10)
        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "SubagentStop",
            "session_id": "codex-rich-status",
            "agent_id": "worker-1",
            "agent_type": "worker",
            "_source": "codex",
        ]), maxHistory: 10)

        XCTAssertTrue(sessions["codex-rich-status"]?.subagents.isEmpty == true)
        XCTAssertEqual(sessions["codex-rich-status"]?.status, .idle)
        XCTAssertTrue(sessions["codex-rich-status"]?.interrupted == true)

        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "UserPromptSubmit",
            "session_id": "codex-rich-status",
            "_source": "codex",
            "prompt": "next",
        ]), maxHistory: 10)
        _ = reduceEvent(sessions: &sessions, event: try decode([
            "hook_event_name": "Stop",
            "session_id": "codex-rich-status",
            "_source": "codex",
        ]), maxHistory: 10)

        XCTAssertEqual(sessions["codex-rich-status"]?.status, .idle)
        XCTAssertNil(sessions["codex-rich-status"]?.currentTool)
    }

    private func decode(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let event = HookEvent(from: data) else {
            XCTFail("HookEvent should decode payload: \(payload)")
            throw NSError(domain: "CodexRichStatusTests", code: 1)
        }
        return event
    }
}
