import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

@MainActor
final class AppStateAiWorkWatchTests: XCTestCase {

    func testSessionPrefixKeepsNamespaceDisjoint() {
        XCTAssertEqual(AppState.aiworkSessionPrefix, "aiwork:")
    }

    func testApplyStreamEventToolCallSetsRunningAndTool() {
        var snapshot = SessionSnapshot()
        snapshot.status = .idle

        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.tool_call",
            data: [
                "name": .string("exec"),
                "input": .object(["command": .string("ls -la")])
            ],
            status: .running
        )

        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.currentTool, "exec")
        XCTAssertEqual(snapshot.toolDescription, "ls -la")
    }

    func testApplyStreamEventProgressFillsProcessRow() {
        var snapshot = SessionSnapshot()
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.progress",
            data: [
                "phase": .string("llm_streaming"),
                "text": .string("正在流式推理…")
            ],
            status: .processing
        )
        XCTAssertEqual(snapshot.status, .processing)
        XCTAssertEqual(snapshot.currentTool, "llm")
        XCTAssertEqual(snapshot.toolDescription, "正在流式推理…")
    }

    func testApplyStreamEventThinkingFillsProcessRow() {
        var snapshot = SessionSnapshot()
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.thinking_delta",
            data: ["text": .string("先检查目录结构")],
            status: .processing
        )
        XCTAssertEqual(snapshot.currentTool, "thinking")
        XCTAssertEqual(snapshot.toolDescription, "先检查目录结构")
        XCTAssertEqual(snapshot.lastAssistantMessage, "先检查目录结构")
    }

    func testApplyStreamEventTextDeltasShowAccumulatedPreviewNotRawChunk() {
        var snapshot = SessionSnapshot()
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.text_delta",
            data: ["text": .string("深度分析")],
            status: .processing
        )
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.text_delta",
            data: ["text": .string("这个框架")],
            status: .processing
        )
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.text_delta",
            data: ["text": .string("的问题")],
            status: .processing
        )

        XCTAssertEqual(snapshot.currentTool, "reply")
        XCTAssertEqual(snapshot.lastAssistantMessage, "深度分析这个框架的问题")
        // `$` row must show the readable accumulated preview, not the last fragment.
        XCTAssertEqual(snapshot.toolDescription, "深度分析这个框架的问题")
    }

    func testApplyStreamEventTerminalClearsToolAndIdles() {
        var snapshot = SessionSnapshot()
        snapshot.status = .running
        snapshot.currentTool = "exec"
        snapshot.lastUserPrompt = "列出目录"
        snapshot.addRecentMessage(ChatMessage(isUser: true, text: "列出目录"))

        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.completed",
            data: ["final_text": .string("目录如下：src/ tests/")],
            status: .idle
        )

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertNil(snapshot.currentTool)
        XCTAssertNil(snapshot.toolDescription)
        XCTAssertEqual(snapshot.recentMessages.count, 2)
        XCTAssertEqual(snapshot.recentMessages[0].isUser, true)
        XCTAssertEqual(snapshot.recentMessages[0].text, "列出目录")
        XCTAssertEqual(snapshot.recentMessages[1].isUser, false)
        XCTAssertEqual(snapshot.recentMessages[1].text, "目录如下：src/ tests/")
    }

    func testApplyStreamEventStartedRecordsUserPrompt() {
        var snapshot = SessionSnapshot()
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.started",
            data: ["display_text": .string("帮我看下这个仓库")],
            status: .processing
        )
        XCTAssertEqual(snapshot.lastUserPrompt, "帮我看下这个仓库")
        XCTAssertEqual(snapshot.recentMessages.count, 1)
        XCTAssertTrue(snapshot.recentMessages[0].isUser)
        XCTAssertEqual(snapshot.recentMessages[0].text, "帮我看下这个仓库")
    }

    func testApplyStreamEventTerminalKeepsIdleChatPreviewWithoutFinalText() {
        var snapshot = SessionSnapshot()
        snapshot.addRecentMessage(ChatMessage(isUser: true, text: "跑一下测试"))
        AppState.applyAiWorkStreamEvent(
            &snapshot,
            eventName: "stream.completed",
            data: nil,
            status: .idle
        )
        XCTAssertEqual(snapshot.recentMessages.count, 2)
        XCTAssertEqual(
            snapshot.recentMessages[1].text,
            L10n.shared["reply_complete_placeholder"]
        )
    }

    /// #322 removed a hardcoded Chinese "reply complete" placeholder; these three
    /// must stay routed through L10n and unbracketed, matching L10nTests' guard.
    func testTerminalPlaceholdersAreLocalizedAndUnbracketed() {
        for event in ["stream.completed", "stream.failed", "stream.aborted"] {
            let value = AppState.aiworkTerminalPlaceholder(eventName: event)
            XCTAssertFalse(value.isEmpty, "\(event) placeholder must resolve")
            XCTAssertFalse(value.hasPrefix("["), "\(event) placeholder must not start with '['")
            XCTAssertFalse(value.hasSuffix("]"), "\(event) placeholder must not end with ']'")
        }
        XCTAssertEqual(
            AppState.aiworkTerminalPlaceholder(eventName: "stream.failed"),
            L10n.shared["reply_failed_placeholder"]
        )
        XCTAssertEqual(
            AppState.aiworkTerminalPlaceholder(eventName: "stream.aborted"),
            L10n.shared["reply_aborted_placeholder"]
        )
    }

    func testHandleStreamEventCreatesPrefixedSession() {
        let appState = AppState()
        let frame = AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"stream.started","phase":"start"},"data":{"session":{"session_id":"acp:coder:abc","cwd":"/tmp/proj","title":"Hello"}},"meta":{"session_id":"acp:coder:abc"}}
        """#.utf8))!

        appState.handleAiWorkStreamEvent(name: "stream.started", frame: frame, agentId: "coder")

        let key = "aiwork:acp:coder:abc"
        let session = appState.sessions[key]
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.source, "aiwork")
        XCTAssertEqual(session?.providerSessionId, "acp:coder:abc")
        XCTAssertEqual(session?.cwd, "/tmp/proj")
        XCTAssertEqual(session?.sessionTitle, "Hello")
        XCTAssertEqual(session?.status, .processing)
        XCTAssertEqual(session?.sourceLabel, "AiWork")
        XCTAssertEqual(session?.termBundleId, AppState.aiworkAppBundleId)
        XCTAssertEqual(session?.terminalName, "AiWork")
        XCTAssertEqual(session?.termApp, "AiWork")
    }

    func testSessionInfoChangedUpdatesTitleWithoutStatusMapper() {
        let appState = AppState()
        appState.sessions["aiwork:acp:coder:abc"] = {
            var s = SessionSnapshot()
            s.source = "aiwork"
            s.providerSessionId = "acp:coder:abc"
            s.status = .processing
            return s
        }()

        let frame = AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"stream.session_info_changed","phase":"info"},"data":{"session":{"session_id":"acp:coder:abc","title":"Renamed Chat","cwd":"/work/repo"}},"meta":{"session_id":"acp:coder:abc"}}
        """#.utf8))!
        appState.handleAiWorkStreamEvent(name: "stream.session_info_changed", frame: frame, agentId: "coder")

        let session = appState.sessions["aiwork:acp:coder:abc"]
        XCTAssertEqual(session?.sessionTitle, "Renamed Chat")
        XCTAssertEqual(session?.cwd, "/work/repo")
        XCTAssertEqual(session?.status, .processing)
        XCTAssertEqual(session?.sessionLabel, "Renamed Chat")
    }

    /// The GUI/TUI decision itself. Asserting `SessionSnapshot.sourceLabel` cannot
    /// test this: that property dispatches on `source` alone, so it stays green even
    /// if the client_type-over-prefix priority breaks. Exercise the mapper directly.
    func testSourceLabelPrefersClientTypeOverSessionIdPrefix() {
        // Modern `aiwork tui` also attaches over ACP, so the acp: prefix must lose
        // to an explicit TUI client_type.
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "acp:coder:2", clientType: "DTCoderTUI"),
            "AiWork CLI"
        )
        // And the reverse: a cli: prefix must lose to an explicit GUI client_type.
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "cli:coder:9", clientType: "DTCoderGUI"),
            "AiWork"
        )
        // Post-rename spellings resolve the same way.
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "acp:coder:3", clientType: "AiWorkCLI"),
            "AiWork CLI"
        )
        // The prefix decides only when client_type is absent or unrecognised.
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "cli:coder:1", clientType: nil),
            "AiWork CLI"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.sourceLabel(forDaemonSessionId: "acp:coder:1", clientType: "   "),
            "AiWork"
        )
    }

    /// Separate and genuinely about the snapshot: badge/label text per source key.
    func testSnapshotLabelsPerSourceKey() {
        var gui = SessionSnapshot()
        gui.source = "aiwork"
        XCTAssertEqual(gui.sourceLabel, "AiWork")

        var tui = SessionSnapshot()
        tui.source = "aiwork-cli"
        XCTAssertEqual(tui.sourceLabel, "AiWork CLI")
        XCTAssertEqual(tui.terminalName, "AiWork CLI")
    }

    func testApplyListEntryReadsClientType() {
        var snapshot = SessionSnapshot()
        AppState.applyAiWorkListEntry(
            &snapshot,
            daemonSessionId: "acp:coder:bnb",
            entry: [
                "session_id": .string("acp:coder:bnb"),
                "title": .string("BNB-eval 架构分析"),
                "client_type": .string("DTCoderTUI"),
                "status": .string("active")
            ]
        )
        XCTAssertEqual(snapshot.aiworkClientType, "DTCoderTUI")
        XCTAssertEqual(snapshot.source, "aiwork-cli")
        XCTAssertEqual(snapshot.terminalName, "AiWork CLI")
        XCTAssertEqual(snapshot.sourceLabel, "AiWork CLI")
    }

    func testRemoveAiWorkSessionsByAgent() {
        let appState = AppState()
        appState.sessions["aiwork:acp:coder:1"] = {
            var s = SessionSnapshot(); s.source = "aiwork"; s.providerSessionId = "acp:coder:1"; return s
        }()
        appState.sessions["aiwork:cli:coder:2"] = {
            var s = SessionSnapshot(); s.source = "aiwork"; s.providerSessionId = "cli:coder:2"; return s
        }()
        appState.sessions["aiwork:acp:default:3"] = {
            var s = SessionSnapshot(); s.source = "aiwork"; s.providerSessionId = "acp:default:3"; return s
        }()
        appState.sessions["claude-other"] = SessionSnapshot()

        appState.removeAiWorkSessions(agentId: "coder")

        XCTAssertNil(appState.sessions["aiwork:acp:coder:1"])
        XCTAssertNil(appState.sessions["aiwork:cli:coder:2"])
        XCTAssertNotNil(appState.sessions["aiwork:acp:default:3"])
        XCTAssertNotNil(appState.sessions["claude-other"])
    }

    func testApplyListEntryBackfillFilterHelpers() {
        var snapshot = SessionSnapshot()
        let entry: [String: AnyCodableLike] = [
            "session_id": .string("cli:coder:xyz"),
            "status": .string("waiting_approval"),
            "cwd": .string("/work"),
            "title": .string("Need approve")
        ]
        XCTAssertTrue(AiWorkStatusMapper.isActiveListEntry(entry))
        AppState.applyAiWorkListEntry(&snapshot, daemonSessionId: "cli:coder:xyz", entry: entry)
        XCTAssertEqual(snapshot.source, "aiwork-cli")
        XCTAssertEqual(snapshot.status, .waitingApproval)
        XCTAssertEqual(snapshot.cwd, "/work")
        XCTAssertEqual(snapshot.sessionTitle, "Need approve")
        XCTAssertEqual(snapshot.sourceLabel, "AiWork CLI")
        XCTAssertEqual(snapshot.termBundleId, AppState.aiworkAppBundleId)
        XCTAssertEqual(snapshot.terminalName, "AiWork CLI")
        // TUI uses the IDE bundle for badging but is not native-app mode.
        XCTAssertFalse(snapshot.isNativeAppMode)
    }

    func testGUISessionShowsAiWorkAppBadge() {
        var snapshot = SessionSnapshot()
        snapshot.source = "aiwork"
        snapshot.providerSessionId = "acp:coder:1"
        snapshot.aiworkClientType = "DTCoderGUI"
        AppState.applyAiWorkAppIdentity(&snapshot)
        XCTAssertEqual(snapshot.terminalName, "AiWork")
        XCTAssertEqual(snapshot.termBundleId, "com.alipay.dtcoder.ide")
        XCTAssertTrue(snapshot.isNativeAppMode)
    }

    func testCodeIslandSourceMapsClientType() {
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: "DTCoderGUI"),
            "aiwork"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: "DTCoderTUI"),
            "aiwork-cli"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: "AiWorkGUI"),
            "aiwork"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: "AiWorkTUI"),
            "aiwork-cli"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: nil, daemonSessionId: "cli:coder:1"),
            "aiwork-cli"
        )
        XCTAssertEqual(
            AiWorkStatusMapper.codeIslandSource(clientType: nil, daemonSessionId: "acp:coder:1"),
            "aiwork"
        )
    }

    func testSupportedSourcesIncludesAiWorkAndCLI() {
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("aiwork"))
        XCTAssertTrue(SessionSnapshot.supportedSources.contains("aiwork-cli"))
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("aiwork"), "aiwork")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("aiwork-cli"), "aiwork-cli")
    }

    func testIgnoresEventsWithoutSessionId() {
        let appState = AppState()
        let frame = AiWorkWatchClient.parseFrame(Data(#"""
        {"kind":"event","category":"session","operation":"sessions.watch","event":{"name":"stream.started","phase":"start"},"data":{},"meta":{}}
        """#.utf8))!
        appState.handleAiWorkStreamEvent(name: "stream.started", frame: frame, agentId: "coder")
        XCTAssertTrue(appState.sessions.keys.filter { $0.hasPrefix("aiwork:") }.isEmpty)
    }

    func testShouldForceIdleWhenDaemonNoLongerBusy() {
        let now = Date()
        XCTAssertTrue(
            AiWorkStatusMapper.shouldForceIdleSession(
                daemonSessionId: "acp:coder:cc8c",
                lastActivity: now.addingTimeInterval(-20),
                busyDaemonIds: [],
                now: now,
                grace: 8
            )
        )
        XCTAssertFalse(
            AiWorkStatusMapper.shouldForceIdleSession(
                daemonSessionId: "acp:coder:cc8c",
                lastActivity: now.addingTimeInterval(-20),
                busyDaemonIds: ["acp:coder:cc8c"],
                now: now,
                grace: 8
            ),
            "still-busy sessions must not be force-idled"
        )
        XCTAssertFalse(
            AiWorkStatusMapper.shouldForceIdleSession(
                daemonSessionId: "acp:coder:cc8c",
                lastActivity: now.addingTimeInterval(-3),
                busyDaemonIds: [],
                now: now,
                grace: 8
            ),
            "grace window avoids racing a just-started turn"
        )
    }

    func testApplyBusyReconcileClearsStuckRunningSession() {
        let appState = AppState()
        let key = "aiwork:acp:coder:cc8c"
        appState.sessions[key] = {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-120))
            s.source = "aiwork"
            s.providerSessionId = "acp:coder:cc8c"
            s.status = .running
            s.currentTool = "exec"
            s.toolDescription = "exec: cd /tmp && echo hi"
            s.lastActivity = Date().addingTimeInterval(-30)
            return s
        }()

        appState.applyAiWorkBusyReconcile(
            localSessions: [(key, "acp:coder:cc8c", Date().addingTimeInterval(-30))],
            busyDaemonIds: [],
            now: Date(),
            grace: 8
        )

        XCTAssertEqual(appState.sessions[key]?.status, .idle)
        XCTAssertNil(appState.sessions[key]?.currentTool)
        XCTAssertNil(appState.sessions[key]?.toolDescription)
    }

    func testApplyBusyReconcileKeepsTrulyBusySession() {
        let appState = AppState()
        let key = "aiwork:acp:coder:busy"
        appState.sessions[key] = {
            var s = SessionSnapshot()
            s.source = "aiwork"
            s.providerSessionId = "acp:coder:busy"
            s.status = .running
            s.currentTool = "exec"
            s.lastActivity = Date().addingTimeInterval(-30)
            return s
        }()

        appState.applyAiWorkBusyReconcile(
            localSessions: [(key, "acp:coder:busy", Date().addingTimeInterval(-30))],
            busyDaemonIds: ["acp:coder:busy"],
            now: Date(),
            grace: 8
        )

        XCTAssertEqual(appState.sessions[key]?.status, .running)
        XCTAssertEqual(appState.sessions[key]?.currentTool, "exec")
    }
}
