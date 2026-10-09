import XCTest
import SQLite3
@testable import CodeIslandCore

/// Hermes keeps every session in `$HERMES_HOME/state.db`; the island reads the
/// title (which no hook carries) and the newest prompt / reply from it. These
/// tests build the database the way Hermes lays it out (hermes_state_common.py,
/// trimmed to the columns that matter) in a temp dir — never the real ~/.hermes.
final class HermesSessionStoreTests: XCTestCase {
    private var directory: URL!
    private var databasePath: String { directory.appendingPathComponent("state.db").path }
    private let sessionId = "20261009_101151_eafbd0"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Reading the store

    func testReadsTitleAndNewestVisiblePromptAndReply() throws {
        let db = try openHermesDatabase()
        defer { sqlite3_close_v2(db) }
        try exec(db, "INSERT INTO sessions (id, source, model, started_at, title) VALUES ('\(sessionId)', 'cli', 'anthropic/claude-opus-5.5', 1, 'Fix the login bug');")
        try insert(db, role: "user", content: "Why does login fail?")
        try insert(db, role: "assistant", content: "The cookie expires early.")
        // Multimodal prompt: Hermes stores it as "\0json:" + the parts.
        try insert(db, role: "user", content: "\u{0}json:[{\"type\":\"text\",\"text\":\"Here is the trace\"},{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,AAAA\"}},{\"type\":\"text\",\"text\":\"and the log\"}]")
        try insert(db, role: "assistant", content: "Let me read the handler.", toolCalls: #"[{"id":"c1"}]"#)
        try insert(db, role: "tool", content: "def login(): ...")
        try insert(db, role: "assistant", content: "", toolCalls: #"[{"id":"c2"}]"#)
        try insert(db, role: "assistant", content: "Fixed: the cookie is refreshed on login.")
        // None of these is something the person saw in the conversation.
        try insert(db, role: "assistant", content: "rewound reply", active: 0)
        try insert(db, role: "assistant", content: "model-facing scaffolding", displayKind: "hidden")
        try insert(db, role: "user", content: "[CONTEXT SUMMARY] earlier turns…", compressedSummary: 1)
        // Another session's rows stay out.
        try insert(db, session: "20261009_090000_other0", role: "user", content: "other session prompt")

        let snapshot = try XCTUnwrap(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId))

        XCTAssertEqual(snapshot.title, "Fix the login bug")
        XCTAssertEqual(snapshot.latestUserMessage?.text, "Here is the trace\nand the log")
        XCTAssertEqual(snapshot.latestAssistantMessage?.text, "Fixed: the cookie is refreshed on login.")
        XCTAssertLessThan(
            try XCTUnwrap(snapshot.latestUserMessage?.rowId),
            try XCTUnwrap(snapshot.latestAssistantMessage?.rowId)
        )
    }

    /// Hermes writes in WAL mode and keeps its connection open. Rows still in
    /// the WAL must be read (an `immutable` open would miss them), and a write
    /// transaction Hermes holds must neither block the read nor leak into it.
    func testReadsCommittedWALRowsWhileHermesHoldsAWriteTransaction() throws {
        let writer = try openHermesDatabase()
        defer { sqlite3_close_v2(writer) }
        try exec(writer, "INSERT INTO sessions (id, source, started_at, title) VALUES ('\(sessionId)', 'cli', 1, 'WAL title');")
        try insert(writer, role: "user", content: "committed prompt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath + "-wal"), "rows should still sit in the WAL")

        try exec(writer, "BEGIN IMMEDIATE;")
        try insert(writer, role: "user", content: "uncommitted prompt")

        let started = Date()
        let snapshot = try XCTUnwrap(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a WAL reader must not wait on the writer")
        XCTAssertEqual(snapshot.title, "WAL title")
        XCTAssertEqual(snapshot.latestUserMessage?.text, "committed prompt")
        try exec(writer, "ROLLBACK;")
    }

    func testOlderSchemaWithoutFilterColumnsStillReads() throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close_v2(handle) }
        try exec(handle, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL, title TEXT);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT, timestamp REAL NOT NULL);
            INSERT INTO sessions VALUES ('\(sessionId)', 'cli', 1, NULL);
            INSERT INTO messages (session_id, role, content, timestamp) VALUES ('\(sessionId)', 'user', 'hello', 1);
            INSERT INTO messages (session_id, role, content, timestamp) VALUES ('\(sessionId)', 'assistant', 'hi there', 2);
            """)

        let snapshot = try XCTUnwrap(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId))

        XCTAssertNil(snapshot.title, "not titled yet")
        XCTAssertEqual(snapshot.latestUserMessage?.text, "hello")
        XCTAssertEqual(snapshot.latestAssistantMessage?.text, "hi there")
    }

    func testUnreadableOrForeignStoresYieldNothing() throws {
        XCTAssertNil(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId), "no file")

        try Data("not a database".utf8).write(to: URL(fileURLWithPath: databasePath))
        XCTAssertNil(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId), "garbage file")
        try FileManager.default.removeItem(atPath: databasePath)

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let handle = try XCTUnwrap(db)
        defer { sqlite3_close_v2(handle) }
        try exec(handle, "CREATE TABLE unrelated (x INTEGER);")
        let snapshot = try XCTUnwrap(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId))
        XCTAssertEqual(snapshot, HermesSessionStore.Snapshot(), "an unknown schema is read as empty, not guessed at")
    }

    /// Only the newest row counts: an unreadable newest prompt must not let an
    /// older one back onto the card.
    func testUnreadableNewestRowIsNotReplacedByAnOlderOne() throws {
        let db = try openHermesDatabase()
        defer { sqlite3_close_v2(db) }
        try insert(db, role: "user", content: "older prompt")
        try insert(db, role: "user", content: "\u{0}json:[{\"type\":\"image_url\",\"image_url\":{\"url\":\"x\"}}]")

        let snapshot = try XCTUnwrap(HermesSessionStore.read(databasePath: databasePath, sessionId: sessionId))

        XCTAssertNil(snapshot.latestUserMessage)
    }

    func testStoredContentDecoding() {
        XCTAssertEqual(HermesSessionStore.text(fromStoredContent: "plain"), "plain")
        XCTAssertNil(HermesSessionStore.text(fromStoredContent: "  \n"))
        XCTAssertEqual(
            HermesSessionStore.text(fromStoredContent: "\u{0}json:[\"a\",{\"type\":\"input_text\",\"input_text\":\"b\"},{\"type\":\"audio\",\"text\":\"no\"}]"),
            "a\nb"
        )
        // A literal string that happened to start with the marker is stored double-encoded.
        XCTAssertEqual(HermesSessionStore.text(fromStoredContent: "\u{0}json:\"\\u0000json: literal\""), "\u{0}json: literal")
        XCTAssertNil(HermesSessionStore.text(fromStoredContent: "\u{0}json:[{\"type\":\"text\""), "truncated JSON")
    }

    // MARK: - Remote payload

    func testSnapshotFromRemoteHookPayload() throws {
        let payload: [String: Any] = [
            "title": "Remote title",
            "user": ["id": 12, "text": "remote prompt"],
            "assistant": ["id": 15, "text": "   "],
        ]
        let snapshot = try XCTUnwrap(HermesSessionStore.Snapshot(payload: payload))
        XCTAssertEqual(snapshot.title, "Remote title")
        XCTAssertEqual(snapshot.latestUserMessage, HermesSessionStore.Message(rowId: 12, text: "remote prompt"))
        XCTAssertNil(snapshot.latestAssistantMessage, "blank text is no message")
        XCTAssertNil(HermesSessionStore.Snapshot(payload: "nope"))
        XCTAssertNil(HermesSessionStore.Snapshot(payload: nil))
    }

    // MARK: - Merging into the card

    func testMergeFillsTitlePromptAndReplyInWrittenOrder() {
        var session = SessionSnapshot()
        session.source = "hermes"

        let changed = session.applyHermesStore(.init(
            title: "Fix the login bug",
            latestUserMessage: .init(rowId: 12, text: "fix it"),
            latestAssistantMessage: .init(rowId: 9, text: "previous reply")
        ))

        XCTAssertTrue(changed)
        XCTAssertEqual(session.sessionTitle, "Fix the login bug")
        XCTAssertEqual(session.lastUserPrompt, "fix it")
        XCTAssertEqual(session.lastAssistantMessage, "previous reply")
        XCTAssertEqual(session.recentMessages.map(\.text), ["previous reply", "fix it"])
        XCTAssertEqual(session.recentMessages.map(\.isUser), [false, true])
    }

    func testMergeReplacesTheTrailingReplyAndIsANoOpWhenNothingMoved() {
        var session = SessionSnapshot()
        session.applyHermesStore(.init(latestUserMessage: .init(rowId: 1, text: "prompt")))
        session.applyHermesStore(.init(
            latestUserMessage: .init(rowId: 1, text: "prompt"),
            latestAssistantMessage: .init(rowId: 2, text: "Let me look.")
        ))
        session.applyHermesStore(.init(
            latestUserMessage: .init(rowId: 1, text: "prompt"),
            latestAssistantMessage: .init(rowId: 5, text: "Done.")
        ))

        XCTAssertEqual(session.recentMessages.map(\.text), ["prompt", "Done."], "one reply per turn, the newest")
        XCTAssertFalse(session.applyHermesStore(.init(
            latestUserMessage: .init(rowId: 1, text: "prompt"),
            latestAssistantMessage: .init(rowId: 5, text: "Done.")
        )))
    }

    /// The store gets the prompt only after pre_llm_call fired, so once hooks
    /// report prompts/replies, an older store row must not undo them.
    func testHookReportedMessagesWinOverTheStoreButTheTitleStillComes() {
        var session = SessionSnapshot()
        session.lastUserPrompt = "new prompt"
        session.lastAssistantMessage = "new reply"
        session.recentMessages = [ChatMessage(isUser: true, text: "new prompt"), ChatMessage(isUser: false, text: "new reply")]
        session.hermesHooksReportPrompts = true
        session.hermesHooksReportReplies = true

        session.applyHermesStore(.init(
            title: "Titled later",
            latestUserMessage: .init(rowId: 5, text: "old prompt"),
            latestAssistantMessage: .init(rowId: 7, text: "old reply")
        ))

        XCTAssertEqual(session.sessionTitle, "Titled later")
        XCTAssertEqual(session.lastUserPrompt, "new prompt")
        XCTAssertEqual(session.lastAssistantMessage, "new reply")
        XCTAssertEqual(session.recentMessages.map(\.text), ["new prompt", "new reply"])
    }

    // MARK: - Hook payload

    func testForwardedPayloadDropsTheConversationCopyOnly() {
        let payload: [String: Any] = [
            "hook_event_name": "post_llm_call",
            "session_id": sessionId,
            "extra": [
                "user_message": "fix it",
                "assistant_response": "Done.",
                "conversation_history": [["role": "user", "content": String(repeating: "x", count: 10_000)]],
                "model": "hermes-4",
            ] as [String: Any],
        ]

        let trimmed = HermesHookPayload.trimmedForForwarding(payload)

        let extra = trimmed["extra"] as? [String: Any]
        XCTAssertNil(extra?["conversation_history"])
        XCTAssertEqual(extra?["user_message"] as? String, "fix it")
        XCTAssertEqual(extra?["assistant_response"] as? String, "Done.")
        XCTAssertEqual(extra?["model"] as? String, "hermes-4")
        XCTAssertEqual(trimmed["session_id"] as? String, sessionId)

        let untouched: [String: Any] = ["hook_event_name": "pre_tool_call", "extra": ["task_id": "t"]]
        XCTAssertEqual((HermesHookPayload.trimmedForForwarding(untouched)["extra"] as? [String: Any])?["task_id"] as? String, "t")
    }

    // MARK: - Helpers

    /// The Hermes layout (trimmed), in WAL mode like Hermes opens it.
    private func openHermesDatabase() throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            throw XCTSkip("cannot create a test database")
        }
        try exec(db, """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT, started_at REAL NOT NULL,
                ended_at REAL, cwd TEXT, title TEXT, title_source TEXT, last_activity_at REAL
            );
            CREATE TABLE messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id),
                role TEXT NOT NULL, content TEXT, tool_call_id TEXT, tool_calls TEXT, tool_name TEXT,
                timestamp REAL NOT NULL, finish_reason TEXT,
                _compressed_summary INTEGER NOT NULL DEFAULT 0,
                active INTEGER NOT NULL DEFAULT 1, compacted INTEGER NOT NULL DEFAULT 0,
                display_kind TEXT
            );
            CREATE INDEX idx_messages_session_id ON messages(session_id, id);
            """)
        return db
    }

    private func insert(
        _ db: OpaquePointer,
        session: String? = nil,
        role: String,
        content: String,
        toolCalls: String? = nil,
        active: Int32 = 1,
        displayKind: String? = nil,
        compressedSummary: Int32 = 0
    ) throws {
        var statement: OpaquePointer?
        let sql = """
            INSERT INTO messages (session_id, role, content, tool_calls, timestamp, active, display_kind, _compressed_summary)
            VALUES (?, ?, ?, ?, 1, ?, ?, ?);
            """
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        let handle = try XCTUnwrap(statement)
        defer { sqlite3_finalize(handle) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        func bind(_ value: String?, _ index: Int32) {
            guard let value else { sqlite3_bind_null(handle, index); return }
            // Explicit length: the structured-content marker starts with a NUL.
            let bytes = Array(value.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                    _ = sqlite3_bind_text(handle, index, $0, Int32(bytes.count), transient)
                }
            }
        }
        bind(session ?? sessionId, 1)
        bind(role, 2)
        bind(content, 3)
        bind(toolCalls, 4)
        sqlite3_bind_int(handle, 5, active)
        bind(displayKind, 6)
        sqlite3_bind_int(handle, 7, compressedSummary)
        XCTAssertEqual(sqlite3_step(handle), SQLITE_DONE)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        if status != SQLITE_OK {
            XCTFail("sqlite: \(error.map { String(cString: $0) } ?? "code \(status)")")
        }
    }
}
