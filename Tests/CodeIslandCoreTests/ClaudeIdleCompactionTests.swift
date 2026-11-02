import XCTest
@testable import CodeIslandCore

/// Claude Code compacts a finished session while it sits idle: PreCompact
/// (trigger "auto"), then the SubagentStop of the agent that wrote the
/// summary, and no Stop after — or, where it applies the summary at once,
/// a SessionStart (source "compact") too. The card must read as it did before.
final class ClaudeIdleCompactionTests: XCTestCase {
    private let sessionId = "idle-claude-session"

    private func hookEvent(_ payload: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws -> HookEvent {
        var payload = payload
        payload["session_id"] = sessionId
        payload["_source"] = payload["_source"] ?? "claude"
        payload["cwd"] = "/tmp/project"
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), file: file, line: line)
    }

    private func reduce(
        _ payload: [String: Any],
        _ sessions: inout [String: SessionSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        _ = reduceEvent(sessions: &sessions, event: try hookEvent(payload, file: file, line: line), maxHistory: 20)
    }

    private let preCompact: [String: Any] = [
        "hook_event_name": "PreCompact",
        "trigger": "auto",
        "custom_instructions": NSNull(),
    ]

    private let compactorStop: [String: Any] = [
        "hook_event_name": "SubagentStop",
        "agent_id": "compactor-agent",
        "stop_hook_active": false,
    ]

    private let restartFromSummary: [String: Any] = [
        "hook_event_name": "SessionStart",
        "source": "compact",
    ]

    private func finishedTurn() throws -> [String: SessionSnapshot] {
        var sessions: [String: SessionSnapshot] = [:]
        try reduce(["hook_event_name": "UserPromptSubmit", "prompt": "upgrade the engine"], &sessions)
        try reduce(["hook_event_name": "Stop", "last_assistant_message": "Upgrade done."], &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        return sessions
    }

    func testBackgroundCompactionLeavesAFinishedCardIdle() throws {
        var sessions = try finishedTurn()
        let lastActivity = try XCTUnwrap(sessions[sessionId]?.lastActivity)

        try reduce(preCompact, &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertNil(sessions[sessionId]?.toolDescription, "no \"Compacting context…\" on a finished card")
        XCTAssertEqual(sessions[sessionId]?.lastActivity, lastActivity, "background work is not activity")

        try reduce(compactorStop, &sessions)
        XCTAssertEqual(sessions[sessionId]?.status, .idle)
        XCTAssertNil(sessions[sessionId]?.currentTool)
    }

    func testBackgroundCompactionDoesNotBringBackARemovedCardAsThinking() throws {
        // The idle sweep removed the card long before the compaction ran.
        var sessions: [String: SessionSnapshot] = [:]

        try reduce(preCompact, &sessions)
        XCTAssertNil(sessions[sessionId])
    }

    func testCompactionMidTurnStillShows() throws {
        var sessions: [String: SessionSnapshot] = [:]
        try reduce(["hook_event_name": "UserPromptSubmit", "prompt": "keep going"], &sessions)

        try reduce(preCompact, &sessions)

        XCTAssertEqual(sessions[sessionId]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.toolDescription, "Compacting context\u{2026}")
    }

    func testManualCompactOnAFinishedCardStillShows() throws {
        var sessions = try finishedTurn()
        var manual = preCompact
        manual["trigger"] = "manual"

        try reduce(manual, &sessions)

        XCTAssertEqual(sessions[sessionId]?.status, .processing)
        XCTAssertEqual(sessions[sessionId]?.toolDescription, "Compacting context\u{2026}")
    }

    /// Only Claude Code compacts a session nobody is working in. Codex's
    /// PreCompact belongs to a turn (it names one), and the other agents'
    /// compactions run in a turn too: their cards still say so.
    func testOtherAgentsCompactingAFinishedCardStillShows() throws {
        for source in ["codex", "qwen", "droid"] {
            var sessions: [String: SessionSnapshot] = [:]
            try reduce(["hook_event_name": "UserPromptSubmit", "prompt": "go", "_source": source], &sessions)
            try reduce(["hook_event_name": "Stop", "_source": source], &sessions)
            XCTAssertEqual(sessions[sessionId]?.status, .idle, source)

            var compact = preCompact
            compact["_source"] = source
            var filter = BackgroundCompactionFilter()
            XCTAssertFalse(filter.absorbs(try hookEvent(compact), session: sessions[sessionId], now: Date()), source)
            try reduce(compact, &sessions)

            XCTAssertEqual(sessions[sessionId]?.status, .processing, source)
            XCTAssertEqual(sessions[sessionId]?.toolDescription, "Compacting context\u{2026}", source)
        }
    }

    // MARK: - The compaction's other hooks (BackgroundCompactionFilter)

    /// The idle sweep removed the card: neither the compaction's PreCompact,
    /// the stop of the agent writing the summary, nor the conversation
    /// restarting from it brings the card back.
    func testNoHookOfABackgroundCompactionBringsBackARemovedCard() throws {
        var filter = BackgroundCompactionFilter()
        let now = Date()
        for payload in [preCompact, compactorStop, restartFromSummary] {
            XCTAssertTrue(filter.absorbs(try hookEvent(payload), session: nil, now: now), "\(payload)")
        }
    }

    /// On a finished card, the summary's stop no longer keeps the card from
    /// the idle sweep, and the restart from the summary no longer wipes the
    /// last reply or rings the session-start sound: none of them gets to the
    /// card. The restart ends the compaction.
    func testABackgroundCompactionsOwnHooksLeaveAFinishedCardAsItWas() throws {
        let sessions = try finishedTurn()
        var filter = BackgroundCompactionFilter()
        let now = Date()

        for payload in [preCompact, compactorStop, restartFromSummary] {
            XCTAssertTrue(filter.absorbs(try hookEvent(payload), session: sessions[sessionId], now: now), "\(payload)")
        }
        XCTAssertFalse(filter.absorbs(try hookEvent(compactorStop), session: sessions[sessionId], now: now),
                       "the compaction ended with its restart")
    }

    /// The user's next prompt is the session's own, and so is everything
    /// after it: a stop under an id the card never saw counts as before.
    func testThePromptAfterABackgroundCompactionEndsIt() throws {
        var sessions = try finishedTurn()
        var filter = BackgroundCompactionFilter()
        let now = Date()
        XCTAssertTrue(filter.absorbs(try hookEvent(preCompact), session: sessions[sessionId], now: now))

        let prompt: [String: Any] = ["hook_event_name": "UserPromptSubmit", "prompt": "now the docs"]
        XCTAssertFalse(filter.absorbs(try hookEvent(prompt), session: sessions[sessionId], now: now))
        try reduce(prompt, &sessions)
        try reduce(["hook_event_name": "Stop"], &sessions)

        XCTAssertFalse(filter.absorbs(try hookEvent(compactorStop), session: sessions[sessionId], now: now))
        XCTAssertFalse(filter.absorbs(try hookEvent(restartFromSummary), session: sessions[sessionId], now: now))
    }

    /// A card with work again — a turn under way, a request on screen — is
    /// the session's: its hooks are not the compaction's.
    func testACardWithWorkAgainIsNotTheCompactions() throws {
        var sessions = try finishedTurn()
        var filter = BackgroundCompactionFilter()
        let now = Date()
        XCTAssertTrue(filter.absorbs(try hookEvent(preCompact), session: sessions[sessionId], now: now))

        sessions[sessionId]?.status = .waitingApproval
        XCTAssertFalse(filter.absorbs(try hookEvent(compactorStop), session: sessions[sessionId], now: now))
        sessions[sessionId]?.status = .idle
        XCTAssertFalse(filter.absorbs(try hookEvent(compactorStop), session: sessions[sessionId], now: now),
                       "the compaction ended when the card had work")
    }

    /// A subagent the card knows is the session's own, finishing work of its
    /// own, even while a compaction runs.
    func testAKnownSubagentsStopIsNotTheCompactions() throws {
        var sessions = try finishedTurn()
        sessions[sessionId]?.subagents["agent-bg"] = SubagentState(agentId: "agent-bg", agentType: "Explore")
        var filter = BackgroundCompactionFilter()
        let now = Date()
        XCTAssertTrue(filter.absorbs(try hookEvent(preCompact), session: sessions[sessionId], now: now))

        let ownStop: [String: Any] = ["hook_event_name": "SubagentStop", "agent_id": "agent-bg"]
        XCTAssertFalse(filter.absorbs(try hookEvent(ownStop), session: sessions[sessionId], now: now))
        XCTAssertTrue(filter.absorbs(try hookEvent(compactorStop), session: sessions[sessionId], now: now))
    }

    /// A hook arriving long after the compaction began is not part of it.
    func testAStopLongAfterTheCompactionBeganIsNotItsOwn() throws {
        var filter = BackgroundCompactionFilter(window: 600)
        let began = Date()
        XCTAssertTrue(filter.absorbs(try hookEvent(preCompact), session: nil, now: began))

        XCTAssertTrue(filter.absorbs(try hookEvent(compactorStop), session: nil, now: began.addingTimeInterval(599)))
        XCTAssertFalse(filter.absorbs(try hookEvent(compactorStop), session: nil, now: began.addingTimeInterval(601)))
    }

    /// Nothing is taken for a compaction's without one: a stop under an id
    /// the card never saw, or a restart from a summary, after a manual
    /// /compact or a compaction mid-turn counts as it always did.
    func testOnlyABackgroundCompactionsHooksAreTakenForItsOwn() throws {
        let sessions = try finishedTurn()
        var filter = BackgroundCompactionFilter()
        let now = Date()
        XCTAssertFalse(filter.absorbs(try hookEvent(compactorStop), session: sessions[sessionId], now: now))
        XCTAssertFalse(filter.absorbs(try hookEvent(restartFromSummary), session: nil, now: now))

        var manual = preCompact
        manual["trigger"] = "manual"
        XCTAssertFalse(filter.absorbs(try hookEvent(manual), session: sessions[sessionId], now: now))
        XCTAssertFalse(filter.absorbs(try hookEvent(restartFromSummary), session: sessions[sessionId], now: now))
    }
}
