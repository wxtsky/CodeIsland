import Foundation
import SQLite3

/// A Hermes Agent session as Hermes itself stores it: `$HERMES_HOME/state.db`
/// (SQLite in WAL mode; tables `sessions` and `messages`, hermes_state_common.py).
///
/// No hook carries the session title — Hermes generates it in the background
/// after the first prompt and writes it to `sessions.title` — and the prompt
/// and reply ride only on hooks the user approved (pre_llm_call /
/// post_llm_call). The store has all three. Hermes keeps the database open and
/// writing while it runs, so a read opens it read-only (`mode=ro`; never
/// `immutable`, which would skip the WAL), waits on a lock only briefly,
/// closes at once, and takes a missing table or column as "nothing here".
public enum HermesSessionStore {
    public struct Message: Equatable, Sendable {
        /// `messages.id`; grows with every row Hermes writes.
        public let rowId: Int64
        public let text: String

        public init(rowId: Int64, text: String) {
            self.rowId = rowId
            self.text = text
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var title: String?
        public var latestUserMessage: Message?
        public var latestAssistantMessage: Message?

        public init(title: String? = nil, latestUserMessage: Message? = nil, latestAssistantMessage: Message? = nil) {
            self.title = title
            self.latestUserMessage = latestUserMessage
            self.latestAssistantMessage = latestAssistantMessage
        }

        /// The `_hermes_store` object a remote hook reads from the store on its
        /// own host: `{"title", "user": {"id", "text"}, "assistant": {"id", "text"}}`.
        public init?(payload: Any?) {
            guard let object = payload as? [String: Any] else { return nil }
            func message(_ key: String) -> Message? {
                guard let row = object[key] as? [String: Any],
                      let id = (row["id"] as? NSNumber)?.int64Value,
                      let text = HermesSessionStore.visibleText(row["text"]) else { return nil }
                return Message(rowId: id, text: text)
            }
            self.init(
                title: HermesSessionStore.visibleText(object["title"]),
                latestUserMessage: message("user"),
                latestAssistantMessage: message("assistant")
            )
        }
    }

    public static func databasePath(hermesHome: String) -> String {
        (hermesHome as NSString).appendingPathComponent("state.db")
    }

    /// Bytes kept from one stored message: enough for a long reply, and a
    /// bound on what one read pulls into memory.
    static let maxMessageBytes = 64 * 1024

    /// Messages a person saw. `hidden` / `internal_notification` rows are
    /// model-facing scaffolding Hermes never paints, and compression summaries
    /// are Hermes's own recap, not something said in the conversation.
    private static let hiddenDisplayKinds = "'hidden', 'internal_notification'"

    /// Title and newest visible prompt / reply of `sessionId`, or nil when the
    /// store can't be read (absent, not a database, locked past the timeout).
    /// A database without Hermes's tables or columns reads as empty.
    /// Blocking I/O: call it off the main actor.
    public static func read(databasePath: String, sessionId: String) -> Snapshot? {
        guard !sessionId.isEmpty, FileManager.default.fileExists(atPath: databasePath) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(WarpPaneResolver.fileURI(for: databasePath), &db, flags, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 150)

        // The first statement is where an unreadable file or a held lock shows.
        guard let sessionColumns = columns(of: "sessions", in: db),
              let messageColumns = columns(of: "messages", in: db) else { return nil }
        var snapshot = Snapshot()
        if sessionColumns.isSuperset(of: ["id", "title"]) {
            snapshot.title = queryTitle(db: db, sessionId: sessionId)
        }
        guard messageColumns.isSuperset(of: ["id", "session_id", "role", "content"]) else { return snapshot }
        var filters = ""
        if messageColumns.contains("active") { filters += " AND active = 1" }
        if messageColumns.contains("display_kind") {
            filters += " AND COALESCE(display_kind, '') NOT IN (\(hiddenDisplayKinds))"
        }
        if messageColumns.contains("_compressed_summary") { filters += " AND _compressed_summary = 0" }
        snapshot.latestUserMessage = queryLatestMessage(db: db, sessionId: sessionId, role: "user", filters: filters)
        snapshot.latestAssistantMessage = queryLatestMessage(
            db: db, sessionId: sessionId, role: "assistant", filters: filters
        )
        return snapshot
    }

    /// Text of a stored `messages.content`. Hermes stores structured
    /// (multimodal) content as `"\u{0}json:"` + JSON; only its text parts are
    /// shown, the way Hermes's own `flatten_message_text` reads them.
    static func text(fromStoredContent content: String) -> String? {
        let prefix = "\u{0}json:"
        guard content.hasPrefix(prefix) else { return visibleText(content) }
        guard let data = content.dropFirst(prefix.count).data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return visibleText(flattenedText(decoded))
    }

    private static func flattenedText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if let parts = value as? [Any] {
            let texts = parts.compactMap { textPart($0) }.filter { !$0.isEmpty }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return textPart(value)
    }

    private static func textPart(_ part: Any) -> String? {
        if let text = part as? String { return text }
        guard let part = part as? [String: Any] else { return nil }
        let nonText: Set<String> = ["image", "image_url", "input_image", "audio", "input_audio"]
        if let type = (part["type"] as? String)?.lowercased(), nonText.contains(type) { return nil }
        for key in ["text", "content", "input_text", "output_text", "summary_text"] {
            if let text = part[key] as? String { return text }
        }
        return nil
    }

    static func visibleText(_ value: Any?) -> String? {
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // MARK: - SQLite

    /// Column names of `table` (empty when there's no such table), or nil when
    /// the database can't be read at all.
    private static func columns(of table: String, in db: OpaquePointer) -> Set<String>? {
        guard let statement = prepare(db, "PRAGMA table_info(\(table));") else { return nil }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = sqlite3_column_text(statement, 1) {
                    names.insert(String(cString: name))
                }
            case SQLITE_DONE:
                return names
            default:
                return nil
            }
        }
    }

    private static func queryTitle(db: OpaquePointer, sessionId: String) -> String? {
        guard let statement = prepare(db, "SELECT title FROM sessions WHERE id = ? LIMIT 1;") else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(sessionId, to: statement, index: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return columnText(statement, index: 0).flatMap { visibleText($0) }
    }

    /// Newest row of `role` with content. Only that row: when it holds no
    /// readable text, an older one would put a stale message on the card.
    private static func queryLatestMessage(
        db: OpaquePointer,
        sessionId: String,
        role: String,
        filters: String
    ) -> Message? {
        // Content is read as a byte prefix: a TEXT column may start with a NUL
        // (the structured-content marker), and a multimodal row can be large.
        let sql = """
            SELECT id, substr(CAST(content AS BLOB), 1, \(maxMessageBytes))
            FROM messages
            WHERE session_id = ? AND role = ? AND content IS NOT NULL AND content <> ''\(filters)
            ORDER BY id DESC
            LIMIT 1;
            """
        guard let statement = prepare(db, sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(sessionId, to: statement, index: 1)
        bind(role, to: statement, index: 2)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let content = columnText(statement, index: 1),
              let text = text(fromStoredContent: content) else { return nil }
        return Message(rowId: sqlite3_column_int64(statement, 0), text: text)
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private static func bind(_ text: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
    }

    /// Column bytes as UTF-8, NULs included (`String(cString:)` would stop at
    /// the first one).
    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        var text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
        // The byte cap can cut the last multi-byte character in two.
        if count >= maxMessageBytes, text.last == "\u{FFFD}" { text.removeLast() }
        return text
    }
}

extension SessionSnapshot {
    /// Merge what Hermes's store says about this session into the card.
    ///
    /// The title always comes from the store. A prompt or reply comes from it
    /// only while the matching hook hasn't reported one (the hook isn't
    /// approved on the Hermes side, or the card was rebuilt mid-session): the
    /// store gets the prompt only after `pre_llm_call` has fired, so an older
    /// row must not replace what a hook just said. A reply goes on the card
    /// only where it belongs — after the prompt it answers, never after a newer
    /// one — and replaces the trailing reply instead of stacking, so a turn
    /// shows its latest text rather than every interim line before a tool call.
    /// Returns whether anything on the card changed.
    @discardableResult
    public mutating func applyHermesStore(_ store: HermesSessionStore.Snapshot) -> Bool {
        var changed = false
        if let title = store.title, title != sessionTitle {
            sessionTitle = title
            changed = true
        }

        let prompt = store.latestUserMessage
        let takePrompt = prompt.map { !hermesHooksReportPrompts && $0.text != lastUserPrompt } ?? false
        var reply: HermesSessionStore.Message?
        if !hermesHooksReportReplies, let candidate = store.latestAssistantMessage,
           candidate.text != lastAssistantMessage {
            if let prompt {
                // Newer than the store's prompt: the answer to it, so the card's
                // turn only if that prompt is (or now becomes) the card's prompt.
                // Older: it goes ahead of that prompt, which only works when the
                // prompt lands now too.
                let answersStorePrompt = candidate.rowId > prompt.rowId
                if takePrompt || (answersStorePrompt && prompt.text == lastUserPrompt) {
                    reply = candidate
                }
            } else {
                reply = candidate
            }
        }

        // Oldest first, so a prompt and the reply to it land in written order.
        var rows: [(message: HermesSessionStore.Message, isUser: Bool)] = []
        if takePrompt, let prompt { rows.append((prompt, true)) }
        if let reply { rows.append((reply, false)) }
        for (message, isUser) in rows.sorted(by: { $0.message.rowId < $1.message.rowId }) {
            if isUser {
                lastUserPrompt = message.text
                if recentMessages.last?.isUser == true { recentMessages.removeLast() }
            } else {
                lastAssistantMessage = message.text
                if let last = recentMessages.last, !last.isUser { recentMessages.removeLast() }
            }
            addRecentMessage(ChatMessage(isUser: isUser, text: message.text))
            changed = true
        }
        return changed
    }
}
