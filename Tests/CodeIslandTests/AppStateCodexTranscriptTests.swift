import XCTest
@testable import CodeIsland
import CodeIslandCore
import SQLite3

@MainActor
final class AppStateCodexTranscriptTests: XCTestCase {
    func testDelayedDeltaFromDetachedGenerationCannotMutateRecreatedSession() throws {
        let appState = AppState()
        let sessionId = "codexapp:reused-thread"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-generation-\(UUID().uuidString)")
        let oldTranscript = directory.appendingPathComponent("old.jsonl")
        let newTranscript = directory.appendingPathComponent("new.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: oldTranscript)
        try Data().write(to: newTranscript)
        defer {
            appState.detachTranscriptTailer(sessionId: sessionId)
            try? FileManager.default.removeItem(at: directory)
        }

        var oldSession = SessionSnapshot()
        oldSession.source = "codex"
        oldSession.termBundleId = AppState.codexAppBundleId
        oldSession.transcriptPath = oldTranscript.path
        oldSession.status = .processing
        appState.sessions[sessionId] = oldSession
        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)
        let oldToken = try XCTUnwrap(appState.attachedTranscriptTokens[sessionId])

        // Model a delta that has left JSONLTailer's serial queue but whose
        // MainActor hop is delayed until after close + same-id recreation.
        let delayedOldDelta = ConversationTailDelta(
            sessionId: sessionId,
            lastUserPrompt: nil,
            lastAssistantMessage: "stale reply",
            turnStatus: .idle,
            hasActivity: true,
            attachmentToken: oldToken,
            filePath: oldTranscript.path
        )

        appState.removeSession(sessionId)
        XCTAssertNil(appState.attachedTranscriptTokens[sessionId])

        var recreated = SessionSnapshot()
        recreated.source = "codex"
        recreated.termBundleId = AppState.codexAppBundleId
        recreated.transcriptPath = newTranscript.path
        recreated.status = .processing
        recreated.lastAssistantMessage = "fresh reply"
        appState.sessions[sessionId] = recreated
        appState.attachTranscriptTailerIfNeeded(sessionId: sessionId)
        let newToken = try XCTUnwrap(appState.attachedTranscriptTokens[sessionId])
        XCTAssertNotEqual(newToken, oldToken)

        appState.applyTranscriptDelta(delayedOldDelta)

        XCTAssertEqual(appState.sessions[sessionId]?.status, .processing)
        XCTAssertEqual(appState.sessions[sessionId]?.lastAssistantMessage, "fresh reply")
        XCTAssertEqual(appState.attachedTranscriptPaths[sessionId], newTranscript.path)
        XCTAssertEqual(appState.attachedTranscriptTokens[sessionId], newToken)
    }

    func testRecentCodexDesktopRecordsFindSameCwdThreadsBeyondFixedTailWindow() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-desktop-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let hugePayload = String(repeating: "x", count: 200_000)
        let activeRoot = tempDir.appendingPathComponent("root.jsonl")
        let activeSibling = tempDir.appendingPathComponent("sibling.jsonl")
        let completed = tempDir.appendingPathComponent("completed.jsonl")
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let toolOutput = #"{"type":"response_item","payload":{"type":"function_call_output","output":"\#(hugePayload)"}}"#
        let finished = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#

        try ([started, toolOutput].joined(separator: "\n") + "\n")
            .write(to: activeRoot, atomically: true, encoding: .utf8)
        try (started + "\n").write(to: activeSibling, atomically: true, encoding: .utf8)
        try ([started, finished].joined(separator: "\n") + "\n")
            .write(to: completed, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: completed.path
        )

        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }

        let current = Int64(now.timeIntervalSince1970)
        let laggingDesktopUpdate = current - 1_800
        let old = current - 60
        let sql = """
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            rollout_path TEXT NOT NULL,
            cwd TEXT NOT NULL,
            updated_at INTEGER NOT NULL,
            model TEXT,
            archived INTEGER NOT NULL,
            has_user_event INTEGER NOT NULL,
            source TEXT NOT NULL
        );
        INSERT INTO threads VALUES ('root-thread', '\(activeRoot.path)', '/same/repo', \(laggingDesktopUpdate), 'gpt-test', 0, 0, 'vscode');
        INSERT INTO threads VALUES ('sibling-thread', '\(activeSibling.path)', '/same/repo', \(current), 'gpt-test', 0, 1, 'appServer');
        INSERT INTO threads VALUES ('completed-thread', '\(completed.path)', '/same/repo', \(old), 'gpt-test', 0, 1, 'vscode');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let records = AppState.recentCodexDesktopThreadRecords(
            statePath: statePath,
            now: now,
            freshnessWindow: 600,
            completionSettleWindow: 30,
            fileManager: fm
        )

        XCTAssertEqual(Set(records.map(\.sessionId)), ["root-thread", "sibling-thread"])
        XCTAssertTrue(records.allSatisfy { $0.cwd == "/same/repo" })
        XCTAssertTrue(records.allSatisfy { $0.status == .processing })
    }

    func testCodexDesktopStateScanFindsThreadCreatedAfterInitialEmptyScan() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-desktop-poll-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                model TEXT,
                archived INTEGER NOT NULL,
                has_user_event INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(AppState.recentCodexDesktopThreadRecords(
            statePath: statePath,
            now: now,
            fileManager: fm
        ).isEmpty)

        let rollout = tempDir.appendingPathComponent("new-thread.jsonl")
        try (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        let insert = """
            INSERT INTO threads VALUES (
                'new-thread', '\(rollout.path)', '/new/repo',
                \(Int64(now.timeIntervalSince1970)), 'gpt-test', 0, 0, 'appServer'
            );
            """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)

        let records = AppState.recentCodexDesktopThreadRecords(
            statePath: statePath,
            now: now,
            fileManager: fm
        )
        XCTAssertEqual(records.map(\.sessionId), ["new-thread"])
        XCTAssertEqual(records.first?.status, .processing)
        XCTAssertEqual(records.first?.cwd, "/new/repo")
    }

    func testCodexDesktopStateScanTreatsMissingAndIncompatibleDatabasesAsEmpty() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-db-fallback-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let missingPath = tempDir.appendingPathComponent("missing.sqlite").path
        XCTAssertTrue(AppState.recentCodexDesktopThreadRecords(
            statePath: missingPath,
            fileManager: fm
        ).isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: missingPath))

        let incompatiblePath = tempDir.appendingPathComponent("incompatible.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(incompatiblePath, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            db,
            "CREATE TABLE threads (id TEXT PRIMARY KEY, unexpected_column TEXT);",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        sqlite3_close_v2(db)

        XCTAssertTrue(AppState.recentCodexDesktopThreadRecords(
            statePath: incompatiblePath,
            fileManager: fm
        ).isEmpty)
    }

    func testCodexDesktopStateScanPrefersMillisecondTimestampWhenBothColumnsExist() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-db-ms-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rollout = tempDir.appendingPathComponent("millisecond-thread.jsonl")
        try (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n")
            .write(to: rollout, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: now.addingTimeInterval(-7_200)],
            ofItemAtPath: rollout.path
        )

        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let staleSeconds = Int64(now.addingTimeInterval(-7_200).timeIntervalSince1970)
        let currentMilliseconds = Int64(now.timeIntervalSince1970 * 1_000)
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                updated_at_ms INTEGER,
                model TEXT,
                archived INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            INSERT INTO threads VALUES (
                'millisecond-thread', '\(rollout.path)', '/ms/repo',
                \(staleSeconds), \(currentMilliseconds), 'gpt-test', 0, 'vscode'
            );
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let records = AppState.recentCodexDesktopThreadRecords(
            statePath: statePath,
            now: now,
            fileManager: fm
        )
        XCTAssertEqual(records.map(\.sessionId), ["millisecond-thread"])
        XCTAssertEqual(records.first?.status, .processing)
    }

    func testCodexDesktopStateScanRejectsCorruptNullAndMissingTranscriptRows() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-db-invalid-rows-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let corruptPath = tempDir.appendingPathComponent("corrupt.sqlite").path
        try Data("not-a-sqlite-database".utf8).write(to: URL(fileURLWithPath: corruptPath))
        XCTAssertTrue(AppState.recentCodexDesktopThreadRecords(
            statePath: corruptPath,
            fileManager: fm
        ).isEmpty)

        let statePath = tempDir.appendingPathComponent("nullable.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let now = Int64(Date().timeIntervalSince1970)
        let missingTranscript = tempDir.appendingPathComponent("missing.jsonl").path
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT,
                cwd TEXT,
                updated_at INTEGER,
                model TEXT,
                archived INTEGER,
                source TEXT
            );
            INSERT INTO threads VALUES ('null-path', NULL, '/repo', \(now), NULL, 0, 'vscode');
            INSERT INTO threads VALUES ('null-cwd', '\(missingTranscript)', NULL, \(now), NULL, 0, 'vscode');
            INSERT INTO threads VALUES ('missing-file', '\(missingTranscript)', '/repo', \(now), NULL, 0, 'vscode');
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(AppState.recentCodexDesktopThreadRecords(
            statePath: statePath,
            fileManager: fm
        ).isEmpty)
    }

    func testCodexDesktopStateScanExcludesExplicitCLISubagentRollout() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-db-origin-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let cliRollout = tempDir.appendingPathComponent("cli-child.jsonl")
        let desktopRollout = tempDir.appendingPathComponent("desktop-child.jsonl")
        let unknownRollout = tempDir.appendingPathComponent("unknown-child.jsonl")
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        try ([
            #"{"type":"session_meta","payload":{"id":"cli-child","cwd":"/repo","originator":"Codex CLI","source":"cli"}}"#,
            started,
        ].joined(separator: "\n") + "\n").write(
            to: cliRollout,
            atomically: true,
            encoding: .utf8
        )
        try ([
            #"{"type":"session_meta","payload":{"id":"desktop-child","cwd":"/repo","originator":"Codex Desktop","source":"vscode"}}"#,
            started,
        ].joined(separator: "\n") + "\n").write(
            to: desktopRollout,
            atomically: true,
            encoding: .utf8
        )
        try (["truncated-session-meta", started].joined(separator: "\n") + "\n").write(
            to: unknownRollout,
            atomically: true,
            encoding: .utf8
        )

        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let now = Int64(Date().timeIntervalSince1970)
        let subagentSource = #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent"}}}"#
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                model TEXT,
                archived INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            INSERT INTO threads VALUES (
                'cli-child', '\(cliRollout.path)', '/repo', \(now), NULL, 0, '\(subagentSource)'
            );
            INSERT INTO threads VALUES (
                'desktop-child', '\(desktopRollout.path)', '/repo', \(now), NULL, 0, '\(subagentSource)'
            );
            INSERT INTO threads VALUES (
                'unknown-child', '\(unknownRollout.path)', '/repo', \(now), NULL, 0, '\(subagentSource)'
            );
            """, nil, nil, nil), SQLITE_OK)

        let records = AppState.recentCodexDesktopThreadRecords(
            statePath: statePath,
            fileManager: fm
        )
        XCTAssertEqual(records.map(\.sessionId), ["desktop-child"])
    }

    func testReverseLifecycleScanSkipsOversizedUnterminatedTailLine() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-oversized-tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data(
            (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n").utf8
        )
        data.append(Data(repeating: 0x78, count: 512 * 1024))
        try data.write(to: file)

        XCTAssertEqual(
            AppState.latestCodexTurnStatus(
                path: file.path,
                chunkSize: 16 * 1024,
                maxBytesToScan: 1024 * 1024,
                maxLineBytes: 64 * 1024
            ),
            .processing
        )
    }

    func testReverseLifecycleScanHonorsExplicitTotalByteBudget() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-scan-budget-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data(
            (#"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n").utf8
        )
        data.append(Data(repeating: 0x78, count: 256 * 1024))
        try data.write(to: file)

        XCTAssertNil(AppState.latestCodexTurnStatus(
            path: file.path,
            chunkSize: 16 * 1024,
            maxBytesToScan: 64 * 1024,
            maxLineBytes: 32 * 1024
        ))
    }

    func testRootCwdDesktopRolloutSurvivesMissingStateDatabase() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-root-fallback-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "11111111-2222-4333-8444-555555555555"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/fallback/repo",
            now: now
        )

        let discovered = AppState.discoverCodexSessions(
            processes: [CodexProcessDiscoveryCandidate(
                pid: 123,
                cwd: "/",
                startTime: now.addingTimeInterval(-60),
                isDesktop: true
            )],
            sessionsBase: sessionsBase.path,
            statePath: tempDir.appendingPathComponent("missing.sqlite").path,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(discovered.map(\.sessionId), ["codexapp:\(rawSessionId)"])
        XCTAssertEqual(discovered.first?.providerSessionId, rawSessionId)
        XCTAssertEqual(discovered.first?.termBundleId, AppState.codexAppBundleId)
        XCTAssertEqual(discovered.first?.cwd, "/fallback/repo")
    }

    func testSameRawThreadOpenInDesktopAndCLIRemainsTwoDiscoveries() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-dual-mode-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "12345678-1234-4234-8234-123456789abc"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "Codex Desktop",
            source: "vscode",
            filenameTimestamp: "2000-01-01T00-00-00"
        )
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "Codex CLI",
            source: "cli",
            filenameTimestamp: "2000-01-01T00-00-01"
        )

        let discovered = AppState.discoverCodexSessions(
            processes: [
                CodexProcessDiscoveryCandidate(
                    pid: 100,
                    cwd: "/",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: true
                ),
                CodexProcessDiscoveryCandidate(
                    pid: 101,
                    cwd: "/shared/repo",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: false
                ),
            ],
            sessionsBase: sessionsBase.path,
            statePath: tempDir.appendingPathComponent("missing.sqlite").path,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(Set(discovered.map(\.sessionId)), [
            rawSessionId,
            "codexapp:\(rawSessionId)",
        ])
        XCTAssertEqual(
            discovered.first(where: { $0.sessionId == rawSessionId })?.termBundleId,
            nil
        )
        XCTAssertEqual(
            discovered.first(where: { $0.sessionId.hasPrefix("codexapp:") })?.termBundleId,
            AppState.codexAppBundleId
        )
    }

    func testUnknownOriginRolloutIsClaimedOnlyByPreferredDesktopProcess() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-unknown-mode-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "99999999-8888-4777-8666-555555555555"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        _ = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: "/shared/repo",
            now: now,
            originator: "future-surface",
            source: "future-source"
        )

        let discovered = AppState.discoverCodexSessions(
            processes: [
                CodexProcessDiscoveryCandidate(
                    pid: 100,
                    cwd: "/",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: true
                ),
                CodexProcessDiscoveryCandidate(
                    pid: 101,
                    cwd: "/shared/repo",
                    startTime: now.addingTimeInterval(-60),
                    isDesktop: false
                ),
            ],
            sessionsBase: sessionsBase.path,
            statePath: tempDir.appendingPathComponent("missing.sqlite").path,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(discovered.map(\.sessionId), ["codexapp:\(rawSessionId)"])
    }

    func testRejectedRootRolloutDoesNotExcludeValidDatabaseRecord() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("codeisland-codex-rejected-fallback-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let now = Date()
        let rawSessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let sessionsBase = tempDir.appendingPathComponent("sessions")
        let rollout = try makeCodexRollout(
            sessionsBase: sessionsBase,
            sessionId: rawSessionId,
            cwd: nil,
            now: now
        )

        let statePath = tempDir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                cwd TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                model TEXT,
                archived INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            INSERT INTO threads VALUES (
                '\(rawSessionId)', '\(rollout.path)', '/database/repo',
                \(Int64(now.timeIntervalSince1970)), 'gpt-test', 0, 'vscode'
            );
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let discovered = AppState.discoverCodexSessions(
            processes: [CodexProcessDiscoveryCandidate(
                pid: 123,
                cwd: "/",
                startTime: now.addingTimeInterval(-60),
                isDesktop: true
            )],
            sessionsBase: sessionsBase.path,
            statePath: statePath,
            now: now,
            fileManager: fm
        )

        XCTAssertEqual(discovered.map(\.sessionId), ["codexapp:\(rawSessionId)"])
        XCTAssertEqual(discovered.first?.cwd, "/database/repo")
        XCTAssertEqual(discovered.first?.status, .processing)
    }

    func testCodexLatestTerminalTurnTimestampPrefersNewestTerminalEvent() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:18.000Z","type":"event_msg","payload":{"type":"agent_message","message":"still working"}}"#,
            #"{"timestamp":"2026-04-09T03:17:20.500Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-2"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:20.500Z"))
    }

    func testCodexLatestTerminalTurnTimestampTreatsAbortedAndFailedTurnsAsTerminal() throws {
        let transcript = [
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
            #"{"timestamp":"2026-04-09T03:17:21Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#,
            #"{"timestamp":"2026-04-09T03:17:19.000Z","type":"event_msg","payload":{"type":"turn_failed","reason":"tool_error"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codexLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:17:21Z"))
    }

    func testCodexLatestTerminalTurnTimestampIgnoresMalformedAndNonTerminalEvents() {
        let transcript = [
            "not-json",
            #"{"timestamp":"2026-04-09T03:17:16.000Z","type":"event_msg","payload":{"type":"agent_message","message":"done"}}"#,
            #"{"timestamp":"2026-04-09T03:17:17.000Z","type":"response_item","payload":{"type":"message"}}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codexLatestTerminalTurnTimestamp(in: transcript))
    }

    func testQoderLatestTerminalTurnTimestampPrefersExplicitStopEvent() throws {
        let transcript = [
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:31.309452Z","message":{"role":"assistant","content":[{"text":"hello","type":"text"}]}}"#,
            #"{"type":"progress","timestamp":"2026-04-09T03:59:31.332585Z","data":{"hookEvent":"Stop","hookName":"Stop","type":"hook_progress"}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.qoderLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:59:31.332585Z"))
    }

    func testQoderLatestTerminalTurnTimestampFallsBackToAssistantTextWhenStopMissing() throws {
        let transcript = [
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:30.000000Z","message":{"role":"assistant","content":[{"thinking":"let me think","type":"thinking"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-04-09T03:59:31.309452Z","message":{"role":"assistant","content":[{"text":"hello","type":"text"}]}}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.qoderLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, try timestampFrom("2026-04-09T03:59:31.309452Z"))
    }

    func testCodeBuddyLatestTerminalTurnTimestampUsesCompletedAssistantMessage() throws {
        let transcript = [
            #"{"timestamp":1775408759547,"type":"function_call","status":"completed","role":"assistant","content":[{"type":"output_text","text":"tool"}]}"#,
            #"{"timestamp":1775408774216,"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"final"}]}"#
        ].joined(separator: "\n")

        let timestamp = try XCTUnwrap(AppState.codeBuddyLatestTerminalTurnTimestamp(in: transcript))

        XCTAssertEqual(timestamp, Date(timeIntervalSince1970: 1775408774.216))
    }

    func testCodeBuddyLatestTerminalTurnTimestampIgnoresNonCompletedAssistantEntries() {
        let transcript = [
            #"{"timestamp":1775408759547,"type":"message","role":"assistant","status":"streaming","content":[{"type":"output_text","text":"partial"}]}"#,
            #"{"timestamp":1775408774216,"type":"message","role":"user","status":"completed","content":[{"type":"input_text","text":"next"}]}"#
        ].joined(separator: "\n")

        XCTAssertNil(AppState.codeBuddyLatestTerminalTurnTimestamp(in: transcript))
    }

    private func timestampFrom(_ raw: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let timestamp = fractional.date(from: raw) {
            return timestamp
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(plain.date(from: raw))
    }

    private func makeCodexRollout(
        sessionsBase: URL,
        sessionId: String,
        cwd: String?,
        now: Date,
        originator: String = "Codex Desktop",
        source: String = "vscode",
        filenameTimestamp: String = "2000-01-01T00-00-00"
    ) throws -> URL {
        let calendar = Calendar.current
        let dayDirectory = sessionsBase
            .appendingPathComponent(String(format: "%04d", calendar.component(.year, from: now)))
            .appendingPathComponent(String(format: "%02d", calendar.component(.month, from: now)))
            .appendingPathComponent(String(format: "%02d", calendar.component(.day, from: now)))
        try FileManager.default.createDirectory(at: dayDirectory, withIntermediateDirectories: true)

        var payload: [String: Any] = [
            "id": sessionId,
            "originator": originator,
            "source": source,
        ]
        if let cwd {
            payload["cwd"] = cwd
        }
        let sessionMeta = try JSONSerialization.data(withJSONObject: [
            "type": "session_meta",
            "payload": payload,
        ])
        let started = Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8)
        var contents = sessionMeta
        contents.append(0x0A)
        contents.append(started)
        contents.append(0x0A)

        let rollout = dayDirectory
            .appendingPathComponent("rollout-\(filenameTimestamp)-\(sessionId).jsonl")
        try contents.write(to: rollout)
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: rollout.path
        )
        return rollout
    }
}
