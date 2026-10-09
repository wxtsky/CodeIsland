import XCTest
@testable import CodeIslandCore

/// #364 — a Hermes card showed only its status and session id: no prompt, no
/// reply, no title. Payloads below are the shapes Hermes's shell hooks write
/// to stdin (agent/shell_hooks.py `_serialize_payload`): the four common fields
/// at the top, every event-specific kwarg under `extra`, with the
/// `conversation_history` the bridge strips already gone.
final class HermesHookFlowTests: XCTestCase {
    private let sessionId = "20261009_101151_eafbd0"

    @discardableResult
    private func send(
        _ event: String,
        _ extra: [String: Any] = [:],
        top: [String: Any] = [:],
        to sessions: inout [String: SessionSnapshot]
    ) throws -> [SideEffect] {
        var json: [String: Any] = [
            "hook_event_name": event,
            "tool_name": NSNull(),
            "tool_input": NSNull(),
            "session_id": sessionId,
            "cwd": "/Users/dev/project",
            "profile": "default",
            "extra": extra,
            "_source": "hermes",
        ]
        json.merge(top) { _, new in new }
        let event = try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: json)))
        return reduceEvent(sessions: &sessions, event: event, maxHistory: 20)
    }

    private func turnEnd(interrupted: Bool = false, platform: String = "cli") -> [String: Any] {
        [
            "task_id": "t1", "turn_id": "turn-1", "completed": !interrupted, "failed": false,
            "interrupted": interrupted, "turn_exit_reason": interrupted ? "interrupted" : "text_response",
            "model": "anthropic/claude-opus-5.5", "platform": platform,
        ]
    }

    func testEventNamesFollowHermesTurnTiming() {
        XCTAssertEqual(EventNormalizer.normalize("pre_llm_call"), "UserPromptSubmit")
        XCTAssertEqual(EventNormalizer.normalize("post_llm_call"), "AgentTurnSettled")
        // Fired after EVERY turn (agent/turn_finalizer.py); it used to delete the card.
        XCTAssertEqual(EventNormalizer.normalize("on_session_end"), "Stop")
        XCTAssertEqual(EventNormalizer.normalize("on_session_reset"), "SessionEnd")
    }

    /// A whole turn with every hook approved: the prompt shows from the start,
    /// the reply at the end, and the turn's end settles the card and pops a
    /// completion instead of removing the card.
    func testFullTurnKeepsPromptAndReplyOnTheCard() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try send("on_session_start", ["model": "anthropic/claude-opus-5.5", "platform": "cli"], to: &sessions)
        try send("pre_llm_call", [
            "task_id": "t1", "turn_id": "turn-1", "user_message": "Why does login fail?",
            "is_first_turn": true, "model": "anthropic/claude-opus-5.5", "platform": "cli",
            "parent_session_id": "", "sender_id": "",
        ], to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.lastUserPrompt, "Why does login fail?")

        try send("pre_tool_call", ["task_id": "t1", "tool_call_id": "c1"],
                 top: ["tool_name": "read_file", "tool_input": ["path": "login.py"]], to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .running)
        try send("post_tool_call", ["task_id": "t1", "tool_call_id": "c1", "status": "ok"],
                 top: ["tool_name": "read_file", "tool_input": ["path": "login.py"]], to: &sessions)
        try send("post_llm_call", [
            "task_id": "t1", "turn_id": "turn-1", "user_message": "Why does login fail?",
            "assistant_response": "The session cookie expires early.", "model": "anthropic/claude-opus-5.5",
            "platform": "cli",
        ], to: &sessions)
        let effects = try send("on_session_end", turnEnd(), to: &sessions)

        let session = try XCTUnwrap(sessions[sessionId], "the end of a turn is not the end of the session")
        XCTAssertFalse(effects.contains(.removeSession(sessionId: sessionId)))
        XCTAssertTrue(effects.contains(.enqueueCompletion(sessionId: sessionId)))
        XCTAssertEqual(session.status, .idle)
        XCTAssertFalse(session.interrupted)
        XCTAssertEqual(session.lastAssistantMessage, "The session cookie expires early.")
        XCTAssertEqual(session.recentMessages.map(\.text), ["Why does login fail?", "The session cookie expires early."])
        XCTAssertEqual(session.model, "anthropic/claude-opus-5.5", "Hermes reports the model in extra")
        XCTAssertTrue(session.hermesHooksReportPrompts)
        XCTAssertTrue(session.hermesHooksReportReplies)
    }

    /// Hermes asks before running a newly added hook. Until pre_llm_call is
    /// approved, post_llm_call is the first the card hears of the prompt.
    func testReplyHookAloneStillPutsThePromptAheadOfTheReply() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try send("pre_tool_call", [:], top: ["tool_name": "terminal", "tool_input": ["command": "ls"]], to: &sessions)
        try send("post_llm_call", ["user_message": "list files", "assistant_response": "Three files."], to: &sessions)

        let session = try XCTUnwrap(sessions[sessionId])
        XCTAssertEqual(session.lastUserPrompt, "list files")
        XCTAssertEqual(session.recentMessages.map(\.text), ["list files", "Three files."])
        XCTAssertFalse(session.hermesHooksReportPrompts, "only pre_llm_call says prompts arrive on time")

        // Same prompt again from pre_llm_call: no duplicate row.
        try send("pre_llm_call", ["user_message": "list files"], to: &sessions)
        try send("post_llm_call", ["user_message": "list files", "assistant_response": "Three files."], to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.recentMessages.map(\.text), ["Three files.", "list files", "Three files."])
    }

    func testMultimodalPromptShowsItsTextParts() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try send("pre_llm_call", ["user_message": [
            ["type": "text", "text": "What's wrong here?"],
            ["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]],
        ]], to: &sessions)

        XCTAssertEqual(sessions[sessionId]?.lastUserPrompt, "What's wrong here?")
    }

    func testInterruptedTurnSettlesAsInterrupted() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try send("pre_llm_call", ["user_message": "long task"], to: &sessions)
        try send("on_session_end", turnEnd(interrupted: true), to: &sessions)

        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertEqual(sessions[sessionId]?.interrupted, true)
    }

    /// A delegate_task child and a scheduled job's run are one turn under
    /// their own session id; when it ends, the card goes, as it did before —
    /// no completion for a conversation nobody is in.
    func testOneShotRunEndRemovesItsCard() throws {
        for platform in ["subagent", "cron", "curator"] {
            var sessions: [String: SessionSnapshot] = [:]
            try send("pre_tool_call", [:], top: ["tool_name": "terminal"], to: &sessions)
            let effects = try send("on_session_end", turnEnd(platform: platform), to: &sessions)

            XCTAssertEqual(effects, [.removeSession(sessionId: sessionId)], platform)
        }
    }

    /// A chat held through Hermes's gateway (or its API server) is not a
    /// conversation at this Mac: the card follows the turn — prompt, reply,
    /// back to idle — but nothing rings and no completion card pops.
    func testGatewayTurnUpdatesTheCardQuietly() throws {
        for platform in ["telegram", "discord", "slack", "whatsapp", "signal", "email", "api_server", "irc"] {
            var sessions: [String: SessionSnapshot] = [:]
            let start = try send("on_session_start", ["model": "hermes-4", "platform": platform], to: &sessions)
            let prompt = try send("pre_llm_call", ["user_message": "status?", "platform": platform], to: &sessions)
            try send("post_llm_call", [
                "user_message": "status?", "assistant_response": "All green.", "platform": platform,
            ], to: &sessions)
            let end = try send("on_session_end", turnEnd(platform: platform), to: &sessions)

            for effects in [start, prompt, end] {
                XCTAssertFalse(effects.contains(where: Self.isSound), "\(platform): \(effects)")
            }
            XCTAssertFalse(end.contains(.enqueueCompletion(sessionId: sessionId)), platform)
            let session = try XCTUnwrap(sessions[sessionId], platform)
            XCTAssertEqual(session.status, .idle, platform)
            XCTAssertEqual(session.recentMessages.map(\.text), ["status?", "All green."], platform)
            XCTAssertTrue(session.hermesChatElsewhere, platform)
        }
    }

    /// The CLI, the TUI, the desktop app and an ACP editor are used at this
    /// Mac and behave like every other agent; so does a hook that names no
    /// platform (older Hermes).
    func testLocalTurnRingsAndPopsACompletion() throws {
        for platform in ["cli", "tui", "desktop", "acp", ""] {
            var sessions: [String: SessionSnapshot] = [:]
            let prompt = try send("pre_llm_call", ["user_message": "status?", "platform": platform], to: &sessions)
            let end = try send("on_session_end", turnEnd(platform: platform), to: &sessions)

            XCTAssertTrue(prompt.contains(.playSound("UserPromptSubmit")), platform)
            XCTAssertTrue(end.contains(.playSound("Stop")), platform)
            XCTAssertTrue(end.contains(.enqueueCompletion(sessionId: sessionId)), platform)
            XCTAssertEqual(sessions[sessionId]?.hermesChatElsewhere, false, platform)
        }
    }

    /// A gateway session picked up in the desktop app is local from then on.
    func testCardFollowsTheLatestTurnsPlatform() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try send("on_session_end", turnEnd(platform: "telegram"), to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.hermesChatElsewhere, true)
        // Tool hooks name no platform and change nothing.
        try send("pre_tool_call", [:], top: ["tool_name": "terminal"], to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.hermesChatElsewhere, true)

        let end = try send("on_session_end", turnEnd(platform: "desktop"), to: &sessions)
        XCTAssertEqual(sessions[sessionId]?.hermesChatElsewhere, false)
        XCTAssertTrue(end.contains(.enqueueCompletion(sessionId: sessionId)))
    }

    private static func isSound(_ effect: SideEffect) -> Bool {
        if case .playSound = effect { return true }
        return false
    }

    /// A remote hook attaches what it read from the store on its host. The
    /// title lands; an older prompt from the store never replaces the one the
    /// same pre_llm_call reported (Hermes stores the prompt after the hook).
    func testRemoteStoreSnapshotFillsTheTitleWithoutUndoingTheHookPrompt() throws {
        var sessions: [String: SessionSnapshot] = [:]
        let remote: [String: Any] = ["_remote_host_id": "devbox", "_remote_host_name": "devbox"]
        try send("pre_llm_call", ["user_message": "second prompt"], top: remote.merging([
            "_hermes_store": [
                "title": "Login bug",
                "user": ["id": 3, "text": "first prompt"],
                "assistant": ["id": 4, "text": "first reply"],
            ],
        ]) { _, new in new }, to: &sessions)

        let session = try XCTUnwrap(sessions["remote:devbox:\(sessionId)"])
        XCTAssertEqual(session.sessionTitle, "Login bug")
        XCTAssertEqual(session.lastUserPrompt, "second prompt")
        // The store's reply answers the previous prompt: it must not sit
        // under the new one as if it were its answer.
        XCTAssertNil(session.lastAssistantMessage)
        XCTAssertEqual(session.recentMessages.map(\.text), ["second prompt"])

        // Once the store has caught up, the reply to the current prompt comes through.
        try send("pre_tool_call", [:], top: remote.merging([
            "tool_name": "terminal",
            "_hermes_store": [
                "title": "Login bug",
                "user": ["id": 7, "text": "second prompt"],
                "assistant": ["id": 8, "text": "Checking the handler."],
            ],
        ]) { _, new in new }, to: &sessions)
        XCTAssertEqual(
            sessions["remote:devbox:\(sessionId)"]?.recentMessages.map(\.text),
            ["second prompt", "Checking the handler."]
        )
    }

    /// Restarted mid-session, a card's first sight of the conversation is the
    /// store: the previous reply goes ahead of the prompt being worked on.
    func testFreshCardTakesPromptAndEarlierReplyInOrder() {
        var session = SessionSnapshot()
        session.applyHermesStore(.init(
            latestUserMessage: .init(rowId: 12, text: "current prompt"),
            latestAssistantMessage: .init(rowId: 9, text: "previous reply")
        ))
        XCTAssertEqual(session.recentMessages.map(\.text), ["previous reply", "current prompt"])

        // A card that already shows the current prompt doesn't get the older
        // reply appended under it.
        var shown = SessionSnapshot()
        shown.lastUserPrompt = "current prompt"
        shown.recentMessages = [ChatMessage(isUser: true, text: "current prompt")]
        XCTAssertFalse(shown.applyHermesStore(.init(
            latestUserMessage: .init(rowId: 12, text: "current prompt"),
            latestAssistantMessage: .init(rowId: 9, text: "previous reply")
        )))
    }
}
