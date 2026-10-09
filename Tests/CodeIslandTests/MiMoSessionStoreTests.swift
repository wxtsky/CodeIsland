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

    func testStorePaths() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AppState.mimoDatabasePath(), home + "/.local/share/mimocode/mimocode.db")
        XCTAssertEqual(AppState.openCodeDatabasePath(), home + "/.local/share/opencode/opencode.db")
    }
}
