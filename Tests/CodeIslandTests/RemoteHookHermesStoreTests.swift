import XCTest
@testable import CodeIsland

/// #364 — remote Hermes. The Mac can't open a remote host's
/// `~/.hermes/state.db`, so the remote hook reads the session's title and
/// newest prompt / reply there and attaches them as `_hermes_store`. These
/// tests run the shipped codeisland-remote-hook.py against a store built the
/// way Hermes lays it out, in a sandbox $HOME.
final class RemoteHookHermesStoreTests: XCTestCase {
    private var sandboxHome: URL!
    private var hookURL: URL!
    private let sessionId = "20261009_101151_eafbd0"

    override func setUpWithError() throws {
        sandboxHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-hermes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        let source = try XCTUnwrap(RemoteInstaller.remoteHookSource(), "remote hook resource missing")
        hookURL = sandboxHome.appendingPathComponent("codeisland-remote-hook.py")
        try Data(source.utf8).write(to: hookURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandboxHome)
    }

    /// Python that builds `<home>/state.db` the way Hermes does (WAL, trimmed columns).
    private func buildStore(home: String) -> String {
        """
        import os, sqlite3
        os.makedirs(\(pythonLiteral(home)), exist_ok=True)
        db = sqlite3.connect(os.path.join(\(pythonLiteral(home)), "state.db"))
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript('''
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL, title TEXT);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                role TEXT NOT NULL, content TEXT, timestamp REAL NOT NULL,
                _compressed_summary INTEGER NOT NULL DEFAULT 0, active INTEGER NOT NULL DEFAULT 1,
                display_kind TEXT);
        ''')
        db.execute("INSERT INTO sessions VALUES (?, 'cli', 1, 'Fix the login bug')", (SESSION_ID,))
        rows = [
            ("user", "Why does login fail?", 1, None),
            ("assistant", "Cookie expiry.", 1, None),
            ("user", "\\x00json:" + json.dumps([{"type": "text", "text": "Here is the trace"},
                                               {"type": "image_url", "image_url": {"url": "data:,"}}]), 1, None),
            ("assistant", "Fixed it.", 1, None),
            ("assistant", "rewound", 0, None),
            ("assistant", "scaffolding", 1, "hidden"),
        ]
        for role, content, active, kind in rows:
            db.execute("INSERT INTO messages (session_id, role, content, timestamp, active, display_kind) VALUES (?, ?, ?, 1, ?, ?)",
                       (SESSION_ID, role, content, active, kind))
        db.commit()
        """
    }

    private func pythonLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    /// Runs `code` with the hook imported as `hook` (CODEISLAND_SOURCE=hermes)
    /// and returns the JSON it prints.
    private func runDriver(_ code: String, stdin: String = "", environment extra: [String: String] = [:]) throws -> Any {
        let driver = """
        import importlib.util, json, sys
        SESSION_ID = sys.argv[2]
        spec = importlib.util.spec_from_file_location("hook", sys.argv[1])
        hook = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(hook)
        \(code)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", driver, hookURL.path, sessionId]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandboxHome.path
        environment["CODEISLAND_SOURCE"] = "hermes"
        environment.removeValue(forKey: "HERMES_HOME")
        for (key, value) in extra { environment[key] = value }
        process.environment = environment

        let input = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "hook driver failed: \(err)")
        return try JSONSerialization.jsonObject(with: out, options: [.fragmentsAllowed])
    }

    private var defaultHome: String { sandboxHome.appendingPathComponent(".hermes").path }

    func testScanReadsTitleAndNewestVisiblePromptAndReply() throws {
        let store = try XCTUnwrap(runDriver(buildStore(home: defaultHome) + """

            print(json.dumps(hook._scan_hermes_store(SESSION_ID)))
            """) as? [String: Any])

        XCTAssertEqual(store["title"] as? String, "Fix the login bug")
        let user = try XCTUnwrap(store["user"] as? [String: Any])
        let assistant = try XCTUnwrap(store["assistant"] as? [String: Any])
        XCTAssertEqual(user["text"] as? String, "Here is the trace", "structured content shows its text parts")
        XCTAssertEqual(assistant["text"] as? String, "Fixed it.", "rewound and hidden rows are not the reply")
        XCTAssertLessThan(try XCTUnwrap(user["id"] as? Int), try XCTUnwrap(assistant["id"] as? Int))
    }

    func testScanFollowsHermesHomeAndToleratesNoStore() throws {
        let profileHome = sandboxHome.appendingPathComponent("profiles/work").path
        let none = try runDriver("print(json.dumps(hook._scan_hermes_store(SESSION_ID)))")
        XCTAssertTrue(none is NSNull, "no store, nothing attached")

        let store = try XCTUnwrap(runDriver(buildStore(home: profileHome) + """

            print(json.dumps(hook._scan_hermes_store(SESSION_ID)))
            """, environment: ["HERMES_HOME": profileHome]) as? [String: Any])
        XCTAssertEqual(store["title"] as? String, "Fix the login bug")
    }

    /// End to end through `main()`: the event leaves with the store snapshot
    /// and without the conversation copy Hermes attaches to pre/post_llm_call.
    func testEventCarriesStoreSnapshotWithoutConversationHistory() throws {
        let capture = buildStore(home: defaultHome) + """

            sent = []
            hook._send_event = lambda payload, expects_response: sent.append(payload)
            hook._get_tty = lambda: None
            hook.main()
            print(json.dumps(sent[0]))
            """
        let stdin = """
            {"hook_event_name":"pre_llm_call","tool_name":null,"tool_input":null,"session_id":"\(sessionId)",\
            "cwd":"/work/proj","profile":"default","extra":{"user_message":"Next step?",\
            "conversation_history":[{"role":"user","content":"Why does login fail?"}],"model":"hermes-4"}}
            """
        let sent = try XCTUnwrap(runDriver(capture, stdin: stdin) as? [String: Any])

        let extra = try XCTUnwrap(sent["extra"] as? [String: Any])
        XCTAssertNil(extra["conversation_history"])
        XCTAssertEqual(extra["user_message"] as? String, "Next step?")
        let store = try XCTUnwrap(sent["_hermes_store"] as? [String: Any])
        XCTAssertEqual(store["title"] as? String, "Fix the login bug")
        XCTAssertEqual(sent["_source"] as? String, "hermes")
    }

    func testOnSessionEndNormalizesToStop() throws {
        let names = try XCTUnwrap(runDriver("""
            print(json.dumps([hook._normalize_event(n) for n in ("on_session_end", "post_llm_call", "pre_llm_call")]))
            """) as? [String])
        XCTAssertEqual(names, ["Stop", "AgentTurnSettled", "UserPromptSubmit"])
    }
}
