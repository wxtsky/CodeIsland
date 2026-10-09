import XCTest
import SQLite3
@testable import CodeIsland

/// MiMo Code keeps OpenCode's SQLite layout (`session` / `message` / `part`)
/// in `~/.local/share/mimocode/mimocode.db`. Discovery reads it like
/// OpenCode's, except that subagent sessions — which MiMo spawns in the same
/// directory — are never taken for the CLI's own session. Temp DB only.
final class MiMoSessionStoreTests: XCTestCase {
    private var dbPath: String!

    override func setUpWithError() throws {
        dbPath = NSTemporaryDirectory() + "codeisland-mimo-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL,
                                  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
                                  time_archived INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
                                  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
                                  data TEXT NOT NULL);
            INSERT INTO session VALUES ('ses_root', NULL, '/Users/u/proj', 1000, 2000, NULL);
            INSERT INTO session VALUES ('ses_child', 'ses_root', '/Users/u/proj', 1500, 3000, NULL);
            INSERT INTO session VALUES ('ses_other', NULL, '/Users/u/proj', 1200, 1900, NULL);
            INSERT INTO message VALUES ('msg_root', 'ses_root', 1000, 2000,
                                        '{"role":"assistant","modelID":"mimo-v2-pro"}');
            INSERT INTO message VALUES ('msg_child', 'ses_child', 1500, 3000,
                                        '{"role":"assistant","modelID":"mimo-v2-flash"}');
            INSERT INTO message VALUES ('msg_other', 'ses_other', 1200, 1900,
                                        '{"role":"assistant","model":{"modelID":"mimo-v2-omni"}}');
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func recent(rootSessionsOnly: Bool) -> String? {
        AppState.withSQLiteDatabase(at: dbPath) { db in
            AppState.findRecentOpenCodeSession(
                in: db, cwd: "/Users/u/proj", after: nil, rootSessionsOnly: rootSessionsOnly
            )?.sessionId
        }
    }

    func testMimoDiscoverySkipsTheBusierSubagentSession() {
        XCTAssertEqual(recent(rootSessionsOnly: true), "ses_root")
    }

    func testOpenCodeLookupIsUnchanged() {
        XCTAssertEqual(recent(rootSessionsOnly: false), "ses_child")
    }

    /// A card keyed `mimo-<id>` reads that row's model — another conversation
    /// in the same folder (the desktop runs several) or a subagent's child row
    /// must not lend it theirs. Without a known row, the cwd match decides.
    func testModelComesFromTheCardsOwnStoreRow() {
        func model(_ storeSessionId: String?) -> String? {
            AppState.readModelFromOpenCodeStore(
                cwd: "/Users/u/proj", processStart: nil, dbPath: dbPath,
                rootSessionsOnly: true, storeSessionId: storeSessionId
            )
        }
        XCTAssertEqual(model("ses_other"), "mimo-v2-omni")
        XCTAssertEqual(model("ses_child"), "mimo-v2-flash")
        XCTAssertEqual(model(nil), "mimo-v2-pro")
        XCTAssertEqual(model("ses_unknown"), "mimo-v2-pro")
    }

    func testStorePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AppState.mimoDatabasePath(), home + "/.local/share/mimocode/mimocode.db")
        XCTAssertEqual(AppState.openCodeDatabasePath(), home + "/.local/share/opencode/opencode.db")
    }
}
