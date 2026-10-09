import XCTest
import SQLite3
@testable import CodeIsland
import CodeIslandCore

/// Hermes runs behind a long-lived daemon, so process exit never ends a turn
/// (#303). Its turn boundaries are hooks: pre_llm_call at the start,
/// post_llm_call (the reply) and on_session_end at the end (#364).
final class HermesTurnSettleTests: XCTestCase {

    func testTurnHooksNormalizeToTurnEvents() {
        // post_llm_call carries the reply; on_session_end, right behind it,
        // ends the turn — despite its name it fires after every turn.
        XCTAssertEqual(EventNormalizer.normalize("post_llm_call"), "AgentTurnSettled")
        XCTAssertEqual(EventNormalizer.normalize("pre_llm_call"), "UserPromptSubmit")
        XCTAssertEqual(EventNormalizer.normalize("on_session_end"), "Stop")
    }

    @MainActor
    func testPostLLMCallClearsToolChromeAndKeepsTheAssistantReply() throws {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "hermes"
        session.status = .running
        session.currentTool = "Bash"
        session.toolDescription = "npm test"
        appState.sessions["hermes-1"] = session

        appState.handleEvent(try makePostLLMCall(sessionId: "hermes-1", response: "All tests pass."))

        let updated = try XCTUnwrap(appState.sessions["hermes-1"])
        XCTAssertNil(updated.currentTool, "the model spoke — no tool is in flight anymore")
        XCTAssertNil(updated.toolDescription)
        XCTAssertEqual(updated.status, .processing)
        XCTAssertEqual(updated.lastAssistantMessage, "All tests pass.")
    }

    @MainActor
    func testAssistantResponseIsReadFromHermesExtraEnvelope() throws {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "hermes"
        session.status = .processing
        appState.sessions["hermes-extra"] = session

        appState.handleEvent(try makePostLLMCall(sessionId: "hermes-extra", response: "Done."))

        XCTAssertEqual(appState.sessions["hermes-extra"]?.lastAssistantMessage, "Done.")
    }

    /// on_session_end used to map to SessionEnd, which deleted the card the
    /// moment a reply arrived; the next turn started a blank one (#364).
    @MainActor
    func testTurnEndSettlesTheCardInsteadOfRemovingIt() throws {
        let appState = AppState()
        appState.handleEvent(try makeEvent("pre_llm_call", sessionId: "hermes-turn", extra: ["user_message": "Fix the login bug"]))
        appState.handleEvent(try makePostLLMCall(sessionId: "hermes-turn", response: "Fixed."))
        appState.handleEvent(try makeEvent("on_session_end", sessionId: "hermes-turn", extra: [
            "completed": true, "failed": false, "interrupted": false, "platform": "cli",
        ]))

        let session = try XCTUnwrap(appState.sessions["hermes-turn"], "the card must survive the end of a turn")
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.lastUserPrompt, "Fix the login bug")
        XCTAssertEqual(session.lastAssistantMessage, "Fixed.")

        // `/new`, quitting, closing the conversation: now the card goes.
        appState.handleEvent(try makeEvent("on_session_finalize", sessionId: "hermes-turn", extra: [
            "platform": "cli", "reason": "session_boundary",
        ]))
        XCTAssertNil(appState.sessions["hermes-turn"])
    }

    /// A gateway chat's card is monitored through the gateway daemon, which
    /// never exits: without this, every chat a bot ever answered would keep
    /// an idle card on the island.
    func testIdleGatewayChatCardIsSweptLikeAHookOnlyCard() {
        let stale = AppState.defaultStaleIdleMinutes
        func sweeps(idle: Int, userTimeout: Int = 0, monitor: Bool, elsewhere: Bool) -> Bool {
            AppState.isStaleIdleSession(
                idleMinutes: idle, userTimeoutMinutes: userTimeout, hasMonitor: monitor, hermesChatElsewhere: elsewhere
            )
        }
        XCTAssertTrue(sweeps(idle: stale, monitor: true, elsewhere: true))
        XCTAssertFalse(sweeps(idle: stale - 1, monitor: true, elsewhere: true))
        // A CLI card still lives as long as its process; hook-only cards and
        // the user's timeout are unchanged.
        XCTAssertFalse(sweeps(idle: stale * 6, monitor: true, elsewhere: false))
        XCTAssertTrue(sweeps(idle: stale, monitor: false, elsewhere: false))
        XCTAssertTrue(sweeps(idle: 3, userTimeout: 3, monitor: true, elsewhere: false))
    }

    func testHermesIsTreatedAsDaemonBackedAndOtherAgentsAreNot() {
        XCTAssertTrue(AppState.isDaemonBackedSource("hermes"))
        XCTAssertTrue(AppState.isDaemonBackedSource("hermes-agent"), "alias must resolve too")
        XCTAssertFalse(AppState.isDaemonBackedSource("claude"))
        XCTAssertFalse(AppState.isDaemonBackedSource(nil))
    }

    @MainActor
    func testInstallerRegistersTheTurnHooks() throws {
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "hermes" })
        XCTAssertTrue(
            cli.events.contains { $0.0 == "post_llm_call" },
            "without this hook a Hermes card can only ever be settled by a timeout"
        )
        XCTAssertTrue(
            cli.events.contains { $0.0 == "pre_llm_call" },
            "the prompt only rides on pre_llm_call before the turn ends"
        )
        XCTAssertTrue(
            cli.events.contains { $0.0 == "on_session_finalize" },
            "the only signal that a gateway or desktop session is over"
        )
    }

    // MARK: - Hermes's own store (#364)

    /// The title is in no hook at all: it comes from `$HERMES_HOME/state.db`,
    /// read off the main actor. The bridge names the home (`_hermes_home`).
    @MainActor
    func testLocalSessionGetsItsTitleFromTheStore() async throws {
        let home = try makeHermesHome(title: "Fix the login bug", prompt: "why does login fail?", reply: "Cookie expiry.")
        let appState = AppState()

        appState.handleEvent(try makeEvent("pre_tool_call", sessionId: storeSessionId, extra: [:], top: [
            "tool_name": "read_file", "_hermes_home": home.path,
        ]))

        await waitUntil("store title never arrived") {
            appState.sessions[storeSessionId]?.sessionTitle == "Fix the login bug"
        }
        let session = try XCTUnwrap(appState.sessions[storeSessionId])
        XCTAssertEqual(session.lastUserPrompt, "why does login fail?", "no pre_llm_call yet: the store has the prompt")
        XCTAssertEqual(session.lastAssistantMessage, "Cookie expiry.")
        await waitUntil("the read never finished") { appState.hermesStoreReads[storeSessionId]?.inFlight == false }
    }

    /// A remote session's store is on the remote host; its hook reads it there.
    /// Nothing on this Mac is opened for it, whatever path the event names.
    @MainActor
    func testRemoteSessionNeverReadsALocalStore() async throws {
        let home = try makeHermesHome(title: "Local title", prompt: "local prompt", reply: "local reply")
        let appState = AppState()

        appState.handleEvent(try makeEvent("pre_tool_call", sessionId: storeSessionId, extra: [:], top: [
            "tool_name": "read_file", "_hermes_home": home.path,
            "_remote_host_id": "devbox", "_remote_host_name": "devbox",
        ]))

        let sessionId = "remote:devbox:\(storeSessionId)"
        XCTAssertNotNil(appState.sessions[sessionId])
        XCTAssertNil(appState.hermesStoreReads[sessionId])
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(appState.sessions[sessionId]?.sessionTitle)
    }

    /// Under tests there is no default home: an event that names none never
    /// reaches for the developer's real ~/.hermes.
    @MainActor
    func testNoStoreReadWithoutANamedHomeUnderTests() throws {
        XCTAssertNil(AppState.defaultHermesHome)
        let appState = AppState()
        appState.handleEvent(try makeEvent("pre_tool_call", sessionId: "hermes-nohome", extra: [:], top: ["tool_name": "terminal"]))
        XCTAssertNil(appState.hermesStoreReads["hermes-nohome"])
    }

    // MARK: - Helpers

    private let storeSessionId = "20261009_101151_eafbd0"

    private func makeEvent(
        _ name: String,
        sessionId: String,
        extra: [String: Any],
        top: [String: Any] = [:]
    ) throws -> HookEvent {
        var payload: [String: Any] = [
            "hook_event_name": name,
            "session_id": sessionId,
            "_source": "hermes",
            "cwd": "/tmp/project",
            "profile": "default",
            "extra": extra,
        ]
        payload.merge(top) { _, new in new }
        return try XCTUnwrap(HookEvent(from: JSONSerialization.data(withJSONObject: payload)))
    }

    private func makePostLLMCall(sessionId: String, response: String) throws -> HookEvent {
        try makeEvent("post_llm_call", sessionId: sessionId, extra: [
            "assistant_response": response,
            "model": "hermes-4",
        ])
    }

    /// A temporary HERMES_HOME whose state.db holds one session, laid out the
    /// way Hermes writes it (WAL mode; columns trimmed to what's read).
    private func makeHermesHome(title: String, prompt: String, reply: String) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        var db: OpaquePointer?
        let path = home.appendingPathComponent("state.db").path
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close_v2(handle) }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        let sql = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT,
                started_at REAL NOT NULL, title TEXT);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT, timestamp REAL NOT NULL,
                _compressed_summary INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1,
                display_kind TEXT);
            INSERT INTO sessions (id, source, started_at, title) VALUES (\(quoted(storeSessionId)), 'cli', 1, \(quoted(title)));
            INSERT INTO messages (session_id, role, content, timestamp) VALUES (\(quoted(storeSessionId)), 'user', \(quoted(prompt)), 1);
            INSERT INTO messages (session_id, role, content, timestamp) VALUES (\(quoted(storeSessionId)), 'assistant', \(quoted(reply)), 2);
            """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        return home
    }
}
