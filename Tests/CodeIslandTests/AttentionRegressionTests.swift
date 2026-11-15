import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Records nothing and answers every push with success: nothing here reaches
/// a real push service.
private final class AcceptingTransport: PushTransport, @unchecked Sendable {
    func send(_ request: PushHTTPRequest) async -> PushTransportResponse {
        PushTransportResponse(statusCode: 200, body: Data(#"{"code":200,"message":"success"}"#.utf8))
    }
}

/// Attention bugs that predate `AttentionPolicy` and were fixed in it, end to
/// end through AppState: sounds into a sink, pushes into a private suite with
/// one Bark channel, follow-ups on an injected clock.
@MainActor
final class AttentionRegressionTests: XCTestCase {
    private var played: [String] = []
    private var saved: [String: Any?] = [:]
    private let suiteName = "AttentionRegressionTests"
    private var suite: UserDefaults!
    private var now = Date(timeIntervalSinceReferenceDate: 50_000)
    private var pending: [Task<Data, Never>] = []

    private let keys = [
        SettingsKey.soundEnabled, SettingsKey.soundTaskComplete, SettingsKey.soundTaskError,
        SettingsKey.soundApprovalNeeded, SettingsKey.soundPromptSubmit, SettingsKey.soundSessionStart,
        SettingsKey.quietHoursEnabled, SettingsKey.autoMuteWhenAway, SettingsKey.completionNotificationStyle,
        SettingsKey.smartSuppress, SettingsKey.autoExpandOnPermission, SettingsKey.pluginSessionMode,
        SettingsKey.permissionOnlyMode,
    ]

    override func setUp() async throws {
        try await super.setUp()
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        played = []
        now = Date(timeIntervalSinceReferenceDate: 50_000)
        pending = []
        SoundManager.shared.playSink = { [weak self] in self?.played.append($0) }
        for key in [SettingsKey.soundEnabled, SettingsKey.soundTaskComplete, SettingsKey.soundTaskError,
                    SettingsKey.soundApprovalNeeded, SettingsKey.soundPromptSubmit, SettingsKey.soundSessionStart] {
            UserDefaults.standard.set(true, forKey: key)
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.quietHoursEnabled)
        UserDefaults.standard.set(false, forKey: SettingsKey.autoMuteWhenAway)
        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(true, forKey: SettingsKey.autoExpandOnPermission)

        // Push settings live in a private suite, never in `.standard`.
        suite = UserDefaults(suiteName: suiteName)
        suite.removePersistentDomain(forName: suiteName)
        suite.set(true, forKey: SettingsKey.pushEnabled)
        var bark = PushChannelConfig(kind: .bark)
        bark.enabled = true
        bark.target = "TESTKEY"
        bark.events = PushEventKind.defaultSelection
        suite.set(PushChannelConfig.encodeList([bark]), forKey: SettingsKey.pushChannels)
        let notifier = PushNotifier.shared
        notifier.resetForTesting()
        notifier.defaults = suite
        notifier.transport = AcceptingTransport()
        notifier.presence = { PushPresenceSnapshot(screenLocked: true) }
        notifier.armsCatchUpTimer = false
    }

    override func tearDown() async throws {
        for task in pending { task.cancel() }
        SoundManager.shared.playSink = nil
        SceneMuteMonitor.shared.resetForTesting()
        TerminalVisibilityDetector.probe = .unknown
        let notifier = PushNotifier.shared
        notifier.transport = URLSessionPushTransport.shared
        notifier.presence = { PushPresence.current() }
        notifier.armsCatchUpTimer = true
        notifier.clock = Date.init
        notifier.defaults = .standard
        notifier.resetForTesting()
        suite.removePersistentDomain(forName: suiteName)
        for key in keys {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try await super.tearDown()
    }

    private func event(_ payload: [String: Any]) throws -> HookEvent {
        try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
    }

    private func appStateWithFollowUps() -> AppState {
        let appState = AppState()
        appState.completionAutoCollapseDelay = 600
        let followUps = appState.followUps
        followUps.armsTimer = false
        followUps.clock = { [unowned self] in self.now }
        followUps.intervalProvider = { 60 }
        followUps.isPointerOverPanel = { false }
        followUps.terminalFrontmost = { _ in false }
        followUps.tabVisible = { _ in false }
        return appState
    }

    /// A subagent's StopFailure is filed under its parent's session. Its
    /// error used to be pushed under the parent's name, and the push dedupe's
    /// error shadow (60 s) then swallowed the parent's own completion — the
    /// phone heard "error" and never "done" for a turn that finished fine.
    func testASubagentsFailureDoesNotSwallowItsParentsCompletionPush() throws {
        PushNotifier.shared.clock = { [unowned self] in self.now }
        let appState = appStateWithFollowUps()
        appState.handleEvent(try event(["hook_event_name": "SessionStart", "session_id": "P"]))
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "P", "prompt": "fan out"]))
        appState.handleEvent(try event(["hook_event_name": "SubagentStart", "session_id": "P", "agent_id": "a1", "agent_type": "Explore"]))
        appState.handleEvent(try event(["hook_event_name": "StopFailure", "session_id": "P", "agent_id": "a1", "error": "overloaded"]))
        XCTAssertNil(PushNotifier.shared.lastDecision, "the subagent's failure is not pushed as the parent's")

        now = now.addingTimeInterval(20)
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "P", "last_assistant_message": "all done"]))
        XCTAssertEqual(appState.sessions["P"]?.lastTurnFailed, false, "the parent's turn finished fine")
        XCTAssertEqual(PushNotifier.shared.lastDecision, .sent([.bark]), "the parent's completion is pushed")
    }

    /// Merge mode: a Cursor Task fires Claude Code's hooks (no `--source`, no
    /// transcript), the index knows its transcript, and the Cursor fold in
    /// `handleEvent` rebrands and drops the card within the same event. Its
    /// Stop is a Task's turn end, yet it used to ring "done", push a
    /// completion as the user's own turn (isSubagent false), pop a completion
    /// card for a session that no longer exists, and start a follow-up for it.
    func testAFoldedCursorTasksStopIsNotAnnouncedAsTheUsersTurn() async throws {
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        let parentId = "e1247fd5-d9a0-48ef-8457-0304606b1833"
        let childId = "2528cb91-6379-48f2-aff8-40f4b804dafa"
        let childTranscript = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/subagents/\(childId).jsonl"
        let cursorIndexScanner: @Sendable () -> CursorSubagentTranscriptIndex = {
            CursorSubagentTranscriptIndex(pathsBySessionId: [childId: [childTranscript]], builtAt: Date())
        }
        let appState = appStateWithFollowUps()
        appState.discovery.scanners.cursorSubagentIndex = cursorIndexScanner
        var parent = SessionSnapshot()
        parent.source = "cursor"
        parent.status = .running
        parent.providerSessionId = parentId
        parent.transcriptPath = "/Users/u/.cursor/projects/x/agent-transcripts/\(parentId)/\(parentId).jsonl"
        appState.sessions[parentId] = parent
        var ghost = SessionSnapshot()
        ghost.source = "claude"
        ghost.status = .running
        appState.sessions[childId] = ghost
        appState.applyCursorSubsessionModeToKnownSessions()
        await waitUntil("index never folded the ghost") { appState.sessions[childId] == nil }

        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": childId, "prompt": "task"]))
        XCTAssertEqual(played, [], "a Task starting is its parent's business too")
        PushNotifier.shared.resetForTesting()
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": childId, "last_assistant_message": "task done"]))

        XCTAssertNil(appState.sessions[childId], "precondition: the fold dropped the Task card in the same event")
        XCTAssertNil(appState.justCompletedSessionId, "no completion card for a card that no longer exists")
        XCTAssertNil(PushNotifier.shared.lastDecision, "a Task's turn end is not pushed as the user's")
        XCTAssertTrue(appState.followUps.scheduler.trackedKeys.isEmpty, "nothing to follow up")
        XCTAssertEqual(played, [], "a Task finishing is its parent's business")
    }

    /// Main-thread cost: with sounds on and "mute when away" on (its default),
    /// every hook event whose cue has no sound at all (PreToolUse,
    /// PostToolUse, …) used to read the session lock flag — in production
    /// `CGSessionCopyCurrentDictionary`, a WindowServer round trip — because
    /// the hold was checked before the cue's own switch.
    func testSilentToolHooksDoNotReadTheLockFlag() throws {
        UserDefaults.standard.removeObject(forKey: SettingsKey.autoMuteWhenAway)
        var probes = 0
        SceneMuteMonitor.shared.resetForTesting()
        SceneMuteMonitor.shared.lockProbe = { probes += 1; return false }
        let appState = appStateWithFollowUps()
        for n in 0..<10 {
            appState.handleEvent(try event(["hook_event_name": "PreToolUse", "session_id": "p", "tool_name": "Read", "tool_use_id": "t\(n)"]))
            appState.handleEvent(try event(["hook_event_name": "PostToolUse", "session_id": "p", "tool_name": "Read", "tool_use_id": "t\(n)"]))
        }
        XCTAssertEqual(played, [])
        XCTAssertEqual(probes, 0, "20 silent tool hooks, \(probes) lock-flag reads")

        // A cue the user would hear still asks.
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "p"]))
        XCTAssertEqual(played, ["8bit_complete"])
        XCTAssertGreaterThan(probes, 0, "a sound that may play still checks the lock")
    }

    /// A completion that arrived while another card was up used to be queued
    /// with its Smart Suppress answer thrown away, and later popped with no
    /// look at the session's tab at all.
    func testAQueuedCompletionStillHonoursSmartSuppress() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        // The user is looking at session A's own iTerm tab; B runs elsewhere.
        TerminalVisibilityDetector.probe = TerminalVisibilityDetector.Probe(
            isTerminalFrontmost: { $0.termApp == "iTerm.app" },
            isSessionTabVisible: { $0.termApp == "iTerm.app" }
        )
        let appState = appStateWithFollowUps()
        let request = try event([
            "hook_event_name": "PermissionRequest", "session_id": "B", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "tool_use_id": "b1", "_term_app": "Terminal.app",
        ])
        pending.append(await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) })
        XCTAssertEqual(appState.surface, .approvalCard(sessionId: "B"))

        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "A", "_term_app": "iTerm.app", "prompt": "go"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "A", "_term_app": "iTerm.app", "last_assistant_message": "done"]))
        appState.approvePermission(expectedSessionId: "B")
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotEqual(appState.surface, .completionCard(sessionId: "A"),
                          "A's tab is the one showing: its card must stay suppressed, queued or not")
        XCTAssertEqual(appState.surface, .collapsed)
    }

    /// The same queued card pops once the user has moved to another tab of
    /// the same terminal.
    func testAQueuedCompletionPopsWhenItsTabIsNotShowing() async throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.smartSuppress)
        TerminalVisibilityDetector.probe = TerminalVisibilityDetector.Probe(
            isTerminalFrontmost: { $0.termApp == "iTerm.app" },
            isSessionTabVisible: { _ in false }
        )
        let appState = appStateWithFollowUps()
        let request = try event([
            "hook_event_name": "PermissionRequest", "session_id": "B", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "tool_use_id": "b1", "_term_app": "Terminal.app",
        ])
        pending.append(await startHookRequest { appState.handlePermissionRequest(request, continuation: $0) })
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "A", "_term_app": "iTerm.app", "prompt": "go"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "A", "_term_app": "iTerm.app", "last_assistant_message": "done"]))
        appState.approvePermission(expectedSessionId: "B")

        await waitUntil("the queued card never popped") {
            appState.surface == .completionCard(sessionId: "A")
        }
    }

    /// Follow-up jingles used to go through the turn-failure debounce with no
    /// session, so every failed-turn reminder shared one bucket (a 60 s
    /// sliding window): a second session's failed-turn reminder was silent.
    func testFailedTurnRemindersOfTwoSessionsBothRing() async throws {
        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
        let appState = appStateWithFollowUps()
        appState.handleEvent(try event(["hook_event_name": "StopFailure", "session_id": "X-\(UUID().uuidString)", "error": "rate_limit"]))
        now = now.addingTimeInterval(30)
        appState.handleEvent(try event(["hook_event_name": "StopFailure", "session_id": "Y-\(UUID().uuidString)", "error": "rate_limit"]))
        XCTAssertEqual(played, ["8bit_error", "8bit_error"], "each session's own failure rings")

        played = []
        now = now.addingTimeInterval(31)
        await appState.followUps.tick(now: now)   // X's reminder
        now = now.addingTimeInterval(30)
        await appState.followUps.tick(now: now)   // Y's reminder
        XCTAssertEqual(played, ["8bit_error", "8bit_error"], "one reminder per failed turn, each audible")
    }

    /// A turn the user stopped did not complete, and the user knows: an Esc'd
    /// Stop and Cline's TaskCancel used to ring the "task complete" jingle.
    /// Their cards still pop, reading interrupted.
    func testAnInterruptedTurnPopsItsCardWithoutTheDoneChime() throws {
        let appState = appStateWithFollowUps()
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "esc", "prompt": "go"]))
        played = []
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "esc", "stop_reason": "user"]))
        XCTAssertEqual(played, [])
        XCTAssertEqual(appState.justCompletedSessionId, "esc", "its card still pops")
        XCTAssertEqual(appState.sessions["esc"]?.interrupted, true)

        appState.cancelCompletionQueue()
        appState.surface = .collapsed
        appState.handleEvent(try event(["hook_event_name": "TaskResume", "session_id": "cline", "_source": "cline", "prompt": "go"]))
        played = []
        appState.handleEvent(try event(["hook_event_name": "TaskCancel", "session_id": "cline", "_source": "cline"]))
        XCTAssertEqual(played, [])
        XCTAssertEqual(appState.justCompletedSessionId, "cline", "its card still pops")

        // A turn that did complete still rings.
        appState.surface = .collapsed
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "esc", "prompt": "again"]))
        played = []
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "esc"]))
        XCTAssertEqual(played, ["8bit_complete"])
    }

    /// A Stop keeps its session in the island's spot for the completion card
    /// it pops. A turn end that pops none — announced only by the glance dot,
    /// or a Hermes gateway chat's — used to hold the spot on an idle session
    /// while others were at work. (With at most one other session at work,
    /// rotation hands the spot over anyway; it shows with two.)
    func testATurnEndThatPopsNoCardHandsTheSpotOn() throws {
        let appState = appStateWithFollowUps()
        for busy in ["busy-1", "busy-2"] {
            appState.handleEvent(try event(["hook_event_name": "PreToolUse", "session_id": busy, "tool_name": "Bash"]))
        }

        UserDefaults.standard.set("glance", forKey: SettingsKey.completionNotificationStyle)
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "glance", "prompt": "go"]))
        XCTAssertEqual(appState.activeSessionId, "glance")
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "glance"]))
        XCTAssertTrue(appState.activeSessionId?.hasPrefix("busy-") == true, "the dot pops no card to keep the spot for")

        func hermes(_ name: String, _ extra: [String: Any]) throws -> HookEvent {
            try event(["hook_event_name": name, "session_id": "telegram", "_source": "hermes", "extra": extra])
        }
        appState.handleEvent(try hermes("pre_llm_call", ["user_message": "status?", "platform": "telegram"]))
        XCTAssertEqual(appState.activeSessionId, "telegram")
        appState.handleEvent(try hermes("on_session_end", ["completed": true, "platform": "telegram"]))
        XCTAssertTrue(appState.activeSessionId?.hasPrefix("busy-") == true, "a gateway chat's turn end pops nothing")

        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "card", "prompt": "go"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "card"]))
        XCTAssertEqual(appState.justCompletedSessionId, "card")
        XCTAssertEqual(appState.activeSessionId, "card", "a Stop keeps its session up for the card it popped")
    }

    /// Permission-only mode: a finished turn pops neither the card nor the
    /// glance dot, chases no follow-up, and hands the island's spot on. The
    /// session still goes idle and the done chime still plays. Off, the same
    /// turn pops its card as before.
    func testPermissionOnlyModePopsNothingForAFinishedTurn() throws {
        UserDefaults.standard.set(true, forKey: SettingsKey.permissionOnlyMode)
        let appState = appStateWithFollowUps()
        for busy in ["busy-1", "busy-2"] {
            appState.handleEvent(try event(["hook_event_name": "PreToolUse", "session_id": busy, "tool_name": "Bash"]))
        }

        for style in ["expand", "glance"] {
            UserDefaults.standard.set(style, forKey: SettingsKey.completionNotificationStyle)
            let sid = "po-\(style)"
            appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": sid, "prompt": "go"]))
            played = []
            appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": sid]))
            XCTAssertEqual(played, ["8bit_complete"], "\(style): the sound is not the island opening")
            XCTAssertNil(appState.justCompletedSessionId, "\(style): no completion card")
            XCTAssertEqual(appState.surface, .collapsed, "\(style)")
            XCTAssertFalse(appState.glanceCompletionActive, "\(style): no glance dot")
            XCTAssertEqual(appState.sessions[sid]?.status, .idle)
            XCTAssertTrue(appState.activeSessionId?.hasPrefix("busy-") == true, "\(style): no card keeps the spot")
        }

        UserDefaults.standard.set(false, forKey: SettingsKey.permissionOnlyMode)
        UserDefaults.standard.set("expand", forKey: SettingsKey.completionNotificationStyle)
        appState.handleEvent(try event(["hook_event_name": "UserPromptSubmit", "session_id": "card", "prompt": "go"]))
        appState.handleEvent(try event(["hook_event_name": "Stop", "session_id": "card"]))
        XCTAssertEqual(appState.justCompletedSessionId, "card", "off, the card pops as before")
    }
}
