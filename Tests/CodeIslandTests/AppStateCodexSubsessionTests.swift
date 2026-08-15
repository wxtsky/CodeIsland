import XCTest
@testable import CodeIsland
import CodeIslandCore
import SQLite3
import Darwin

@MainActor
final class AppStateCodexSubsessionTests: XCTestCase {
    func testDistinctCodexDesktopProviderThreadsAreNotDeduplicated() {
        XCTAssertFalse(AppState.providerSessionIdentifiersMayRepresentSameSession(
            existing: "root-thread",
            discovered: "child-thread"
        ))
    }

    func testDesktopProviderThreadRequiresAnExactExistingIdentifier() {
        XCTAssertFalse(AppState.providerSessionIdentifiersMayRepresentSameSession(
            existing: nil,
            discovered: "desktop-thread"
        ))
        XCTAssertTrue(AppState.providerSessionIdentifiersMayRepresentSameSession(
            existing: "desktop-thread",
            discovered: "desktop-thread"
        ))
    }

    func testCodexDesktopAndCLIDiscoveriesAreNotDeduplicated() {
        XCTAssertFalse(AppState.discoveryAppModesMayRepresentSameSession(
            existingIsNativeAppMode: true,
            discoveredTermBundleId: nil
        ))
        XCTAssertFalse(AppState.discoveryAppModesMayRepresentSameSession(
            existingIsNativeAppMode: false,
            discoveredTermBundleId: AppState.codexAppBundleId
        ))
        XCTAssertTrue(AppState.discoveryAppModesMayRepresentSameSession(
            existingIsNativeAppMode: true,
            discoveredTermBundleId: AppState.codexAppBundleId
        ))
        XCTAssertTrue(AppState.discoveryAppModesMayRepresentSameSession(
            existingIsNativeAppMode: false,
            discoveredTermBundleId: nil
        ))
    }

    func testCodexDesktopDiscoveryPollingRequiresRunningAppAndElapsedInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(AppState.shouldPollCodexDesktopDiscovery(
            runningBundleIdentifiers: [],
            lastPollAt: nil,
            now: now
        ))
        XCTAssertTrue(AppState.shouldPollCodexDesktopDiscovery(
            runningBundleIdentifiers: [AppState.codexAppBundleId],
            lastPollAt: nil,
            now: now
        ))
        XCTAssertFalse(AppState.shouldPollCodexDesktopDiscovery(
            runningBundleIdentifiers: [AppState.codexAppBundleId],
            lastPollAt: now.addingTimeInterval(-5),
            now: now
        ))
        XCTAssertTrue(AppState.shouldPollCodexDesktopDiscovery(
            runningBundleIdentifiers: [AppState.codexAppBundleId],
            lastPollAt: now.addingTimeInterval(-6),
            now: now
        ))
    }

    func testCodexDesktopDiscoveryChannelsShareOneIdentityWhileCLIStaysRaw() {
        let rawId = "desktop-thread"
        let desktop = AppState.codexDiscoveryIdentity(rawSessionId: rawId, isDesktop: true)
        let cli = AppState.codexDiscoveryIdentity(rawSessionId: rawId, isDesktop: false)

        XCTAssertEqual(desktop.sessionId, "codexapp:\(rawId)")
        XCTAssertEqual(desktop.providerSessionId, rawId)
        XCTAssertEqual(desktop.termBundleId, AppState.codexAppBundleId)
        XCTAssertEqual(cli.sessionId, rawId)
        XCTAssertNil(cli.providerSessionId)
        XCTAssertNil(cli.termBundleId)
    }

    func testLegacyDesktopRestoreCanonicalizesWithoutChangingCLIKey() {
        XCTAssertEqual(
            AppState.canonicalRestoredCodexSessionId(
                sessionId: "legacy-thread",
                source: "codex",
                providerSessionId: "legacy-thread",
                termBundleId: AppState.codexAppBundleId
            ),
            "codexapp:legacy-thread"
        )
        XCTAssertEqual(
            AppState.canonicalRestoredCodexSessionId(
                sessionId: "cli-thread",
                source: "codex",
                providerSessionId: "cli-thread",
                termBundleId: nil
            ),
            "cli-thread"
        )
    }

    func testSequentialDesktopRolloutAndDatabaseScansKeepOneCardAndRejectStaleStatus() {
        let appState = AppState()
        let rawId = "same-provider-thread"
        let identity = AppState.codexDiscoveryIdentity(rawSessionId: rawId, isDesktop: true)
        let firstActivity = Date()
        let newerActivity = firstActivity.addingTimeInterval(2)

        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: identity.sessionId,
            cwd: "/fallback/repo",
            tty: nil,
            model: "gpt-test",
            pid: nil,
            modifiedAt: firstActivity,
            recentMessages: [],
            source: "codex",
            transcriptPath: "/tmp/fallback-rollout.jsonl",
            status: .processing,
            termBundleId: identity.termBundleId,
            providerSessionId: identity.providerSessionId
        )])
        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: identity.sessionId,
            cwd: "/database/repo",
            tty: nil,
            model: "gpt-test",
            pid: nil,
            modifiedAt: newerActivity,
            recentMessages: [],
            source: "codex",
            transcriptPath: "/tmp/database-rollout.jsonl",
            status: .idle,
            termBundleId: identity.termBundleId,
            providerSessionId: identity.providerSessionId
        )])

        XCTAssertEqual(appState.sessions.count, 1)
        XCTAssertEqual(appState.sessions[identity.sessionId]?.status, .idle)
        XCTAssertEqual(appState.sessions[identity.sessionId]?.lastActivity, newerActivity)

        // Simulate the slower generic FSEvent scan arriving after the DB poll.
        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: identity.sessionId,
            cwd: "/stale/repo",
            tty: nil,
            model: "gpt-test",
            pid: nil,
            modifiedAt: firstActivity.addingTimeInterval(1),
            recentMessages: [],
            source: "codex",
            transcriptPath: "/tmp/stale-rollout.jsonl",
            status: .processing,
            termBundleId: "com.example.stale",
            providerSessionId: identity.providerSessionId
        )])

        XCTAssertEqual(appState.sessions.count, 1)
        XCTAssertEqual(appState.sessions[identity.sessionId]?.status, .idle)
        XCTAssertEqual(appState.sessions[identity.sessionId]?.lastActivity, newerActivity)
        XCTAssertEqual(appState.sessions[identity.sessionId]?.cwd, "/database/repo")
        XCTAssertEqual(
            appState.sessions[identity.sessionId]?.transcriptPath,
            "/tmp/database-rollout.jsonl"
        )
        XCTAssertEqual(appState.sessions[identity.sessionId]?.termBundleId, AppState.codexAppBundleId)
    }

    func testDesktopAndCLIWithSameCwdRemainSeparateCards() {
        let appState = AppState()
        let rawId = "desktop-thread"
        let desktop = AppState.codexDiscoveryIdentity(rawSessionId: rawId, isDesktop: true)
        let now = Date()

        appState.integrateDiscovered([
            AppState.DiscoveredSession(
                sessionId: desktop.sessionId,
                cwd: "/same/repo",
                tty: nil,
                model: nil,
                pid: nil,
                modifiedAt: now,
                recentMessages: [],
                source: "codex",
                status: .processing,
                termBundleId: desktop.termBundleId,
                providerSessionId: desktop.providerSessionId
            ),
            AppState.DiscoveredSession(
                sessionId: "cli-thread",
                cwd: "/same/repo",
                tty: nil,
                model: nil,
                pid: nil,
                modifiedAt: now,
                recentMessages: [],
                source: "codex",
                status: .processing
            ),
        ])

        XCTAssertEqual(Set(appState.sessions.keys), ["codexapp:\(rawId)", "cli-thread"])
        XCTAssertTrue(appState.sessions["codexapp:\(rawId)"]?.isNativeAppMode == true)
        XCTAssertFalse(appState.sessions["cli-thread"]?.isNativeAppMode == true)
    }

    func testCodexSubagentsChooseParentInTheirOwnDesktopOrCLINamespace() {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let appState = AppState()
        var desktopParent = SessionSnapshot()
        desktopParent.source = "codex"
        desktopParent.providerSessionId = "parent-thread"
        desktopParent.termBundleId = AppState.codexAppBundleId
        var cliParent = SessionSnapshot()
        cliParent.source = "codex"
        cliParent.providerSessionId = "parent-thread"
        appState.sessions["codexapp:parent-thread"] = desktopParent
        appState.sessions["parent-thread"] = cliParent

        appState.integrateDiscovered([
            AppState.DiscoveredSession(
                sessionId: "codexapp:desktop-child",
                cwd: "/repo",
                tty: nil,
                model: nil,
                pid: nil,
                modifiedAt: Date(),
                recentMessages: [],
                source: "codex",
                parentSessionId: "parent-thread",
                agentType: "desktop-worker",
                status: .processing,
                termBundleId: AppState.codexAppBundleId,
                providerSessionId: "desktop-child"
            ),
            AppState.DiscoveredSession(
                sessionId: "cli-child",
                cwd: "/repo",
                tty: nil,
                model: nil,
                pid: nil,
                modifiedAt: Date(),
                recentMessages: [],
                source: "codex",
                parentSessionId: "parent-thread",
                agentType: "cli-worker",
                status: .processing,
                providerSessionId: "cli-child"
            ),
        ])

        XCTAssertNotNil(appState.sessions["codexapp:parent-thread"]?.subagents["desktop-child"])
        XCTAssertNil(appState.sessions["codexapp:parent-thread"]?.subagents["cli-child"])
        XCTAssertNotNil(appState.sessions["parent-thread"]?.subagents["cli-child"])
        XCTAssertNil(appState.sessions["parent-thread"]?.subagents["desktop-child"])
    }

    func testCodexHookSubagentChoosesParentInItsDesktopNamespace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-hook-parent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("child.jsonl")
        try (#"{"type":"session_meta","payload":{"id":"child","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread"}}}}}"# + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let appState = AppState()
        var desktopParent = SessionSnapshot()
        desktopParent.source = "codex"
        desktopParent.providerSessionId = "parent-thread"
        desktopParent.termBundleId = AppState.codexAppBundleId
        var cliParent = SessionSnapshot()
        cliParent.source = "codex"
        cliParent.providerSessionId = "parent-thread"
        appState.sessions["codexapp:parent-thread"] = desktopParent
        appState.sessions["parent-thread"] = cliParent

        let server = HookServer(appState: appState)
        XCTAssertEqual(server.codexNativeSubsessionParentId(from: [
            "session_id": "child",
            "_source": "codex",
            "_term_bundle": AppState.codexAppBundleId,
            "transcript_path": transcript.path,
        ]), "codexapp:parent-thread")
        XCTAssertEqual(server.codexNativeSubsessionParentId(from: [
            "session_id": "child",
            "_source": "codex",
            "transcript_path": transcript.path,
        ]), "parent-thread")
    }

    func testCodexDesktopDoesNotRetainSharedHelperPidButOtherSessionsDo() {
        let appState = AppState()
        let now = Date()
        let currentPid = getpid()

        appState.integrateDiscovered([
            AppState.DiscoveredSession(
                sessionId: "codexapp:desktop",
                cwd: "/same/repo",
                tty: nil,
                model: nil,
                pid: currentPid,
                modifiedAt: now,
                recentMessages: [],
                source: "codex",
                termBundleId: AppState.codexAppBundleId,
                providerSessionId: "desktop"
            ),
            AppState.DiscoveredSession(
                sessionId: "codex-cli",
                cwd: "/same/repo",
                tty: nil,
                model: nil,
                pid: currentPid,
                modifiedAt: now,
                recentMessages: [],
                source: "codex"
            ),
            AppState.DiscoveredSession(
                sessionId: "other-native",
                cwd: "/same/repo",
                tty: nil,
                model: nil,
                pid: currentPid,
                modifiedAt: now,
                recentMessages: [],
                source: "cursor",
                termBundleId: "com.todesktop.230313mzl4w4u92"
            ),
        ])

        XCTAssertNil(appState.sessions["codexapp:desktop"]?.cliPid)
        XCTAssertEqual(appState.sessions["codex-cli"]?.cliPid, currentPid)
        XCTAssertEqual(appState.sessions["other-native"]?.cliPid, currentPid)
    }

    func testCompletedLastCodexSubagentClearsParentProjection() {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = "parent-thread"
        // Parent lookup is Desktop/CLI-namespace aware, and the child below is
        // discovered with the Codex app bundle — so the parent card has to be in
        // APP mode, which is what a real `codexapp:` card always carries.
        parent.termBundleId = AppState.codexAppBundleId
        parent.status = .running
        parent.currentTool = "Agent"
        parent.toolDescription = "worker"
        parent.subagents["child-thread"] = SubagentState(
            agentId: "child-thread",
            agentType: "worker"
        )
        appState.sessions["codexapp:parent-thread"] = parent

        appState.integrateDiscovered([AppState.DiscoveredSession(
            sessionId: "codexapp:child-thread",
            cwd: "/same/repo",
            tty: nil,
            model: nil,
            pid: nil,
            modifiedAt: Date(),
            recentMessages: [],
            source: "codex",
            parentSessionId: "parent-thread",
            status: .idle,
            termBundleId: AppState.codexAppBundleId,
            providerSessionId: "child-thread"
        )])

        let updatedParent = appState.sessions["codexapp:parent-thread"]
        XCTAssertTrue(updatedParent?.subagents.isEmpty == true)
        XCTAssertEqual(updatedParent?.status, .processing)
        XCTAssertNil(updatedParent?.currentTool)
        XCTAssertNil(updatedParent?.toolDescription)
    }

    func testCompletedCodexSubagentDiscoveryIsTransient() {
        XCTAssertTrue(AppState.isCompletedCodexSubagentDiscovery(
            source: "codex",
            parentSessionId: "parent-thread",
            status: .idle
        ))
        XCTAssertFalse(AppState.isCompletedCodexSubagentDiscovery(
            source: "codex",
            parentSessionId: nil,
            status: .idle
        ))
        XCTAssertFalse(AppState.isCompletedCodexSubagentDiscovery(
            source: "codex",
            parentSessionId: "parent-thread",
            status: .processing
        ))
    }

    func testCodexSubagentMetadataParsesParentThreadFromRolloutSessionMeta() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-subagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rollout.jsonl")
        let line = """
        {"timestamp":"2026-05-01T00:00:00Z","type":"session_meta","payload":{"id":"child","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1,"agent_nickname":"Galileo","agent_role":"worker"}}},"base_instructions":{"text":"large payload follows"}}}
        """
        try (line + "\n").write(to: file, atomically: true, encoding: .utf8)

        let metadata = try XCTUnwrap(AppState.codexSubagentMetadata(inTranscriptPath: file.path))

        XCTAssertEqual(metadata.parentThreadId, "parent")
        XCTAssertEqual(metadata.agentType, "worker")
        XCTAssertEqual(metadata.agentNickname, "Galileo")
    }

    func testCodexSubagentMetadataFallsBackToThreadSpawnEdgesDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-subagent-db-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let statePath = dir.appendingPathComponent("state_5.sqlite").path

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        let sql = """
        CREATE TABLE thread_spawn_edges (
            parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL PRIMARY KEY,
            status TEXT NOT NULL
        );
        CREATE TABLE threads (
            id TEXT PRIMARY KEY,
            agent_role TEXT,
            agent_nickname TEXT,
            source TEXT
        );
        INSERT INTO thread_spawn_edges VALUES ('parent-thread', 'child-thread', 'running');
        INSERT INTO threads VALUES ('child-thread', 'worker', 'Ohm', '{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread"}}}');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let metadata = try XCTUnwrap(AppState.codexSubagentMetadata(
            threadId: "child-thread",
            transcriptPath: nil,
            statePath: statePath
        ))

        XCTAssertEqual(metadata.parentThreadId, "parent-thread")
        XCTAssertEqual(metadata.agentType, "worker")
        XCTAssertEqual(metadata.agentNickname, "Ohm")
    }

    func testReadableRootTranscriptDoesNotFallBackToStaleSpawnEdge() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-root-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("root.jsonl")
        try (#"{"type":"session_meta","payload":{"id":"root-thread","cwd":"/repo","source":"vscode"}}"# + "\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let statePath = dir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            INSERT INTO thread_spawn_edges VALUES ('stale-parent', 'root-thread', 'open');
            """, nil, nil, nil), SQLITE_OK)

        XCTAssertNil(AppState.codexSubagentMetadata(
            threadId: "root-thread",
            transcriptPath: transcript.path,
            statePath: statePath
        ))
    }

    func testKnownCodexSubagentSessionMergesIntoParentFromTranscriptMetadata() throws {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-subagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let childTranscript = dir.appendingPathComponent("child.jsonl")
        let line = """
        {"type":"session_meta","payload":{"id":"child-thread","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","agent_nickname":"Ohm","agent_role":"worker"}}}}}
        """
        try (line + "\n").write(to: childTranscript, atomically: true, encoding: .utf8)

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = "parent-thread"
        parent.status = .running

        var child = SessionSnapshot()
        child.source = "codex"
        child.providerSessionId = "child-thread"
        child.status = .running
        child.currentTool = "sleep"
        child.transcriptPath = childTranscript.path
        child.lastActivity = Date()

        appState.sessions["parent"] = parent
        appState.sessions["child"] = child

        XCTAssertTrue(appState.applyCodexSubsessionModeToKnownSessions())

        XCTAssertNil(appState.sessions["child"])
        XCTAssertEqual(appState.sessions["parent"]?.subagents["child-thread"]?.agentType, "worker")
        XCTAssertEqual(appState.sessions["parent"]?.subagents["child-thread"]?.toolDescription, "Ohm")
        XCTAssertEqual(appState.activeSessionId, "parent")
    }

    func testKnownIdleCodexSubagentClearsParentEvenWhenSpawnEdgeRemainsOpen() throws {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("merge", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-codex-idle-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let childTranscript = dir.appendingPathComponent("child.jsonl")
        try (#"{"type":"session_meta","payload":{"id":"child-thread","cwd":"/repo","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread","agent_role":"worker"}}}}}"# + "\n")
            .write(to: childTranscript, atomically: true, encoding: .utf8)

        let statePath = dir.appendingPathComponent("state_5.sqlite").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(statePath, &db), SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE TABLE thread_spawn_edges (
                parent_thread_id TEXT NOT NULL,
                child_thread_id TEXT NOT NULL PRIMARY KEY,
                status TEXT NOT NULL
            );
            INSERT INTO thread_spawn_edges VALUES ('parent-thread', 'child-thread', 'open');
            """, nil, nil, nil), SQLITE_OK)

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = "parent-thread"
        parent.status = .running
        parent.currentTool = "Agent"
        parent.toolDescription = "worker"
        parent.subagents["child-thread"] = SubagentState(
            agentId: "child-thread",
            agentType: "worker"
        )
        var child = SessionSnapshot()
        child.source = "codex"
        child.providerSessionId = "child-thread"
        child.transcriptPath = childTranscript.path
        child.status = .idle
        appState.sessions["parent"] = parent
        appState.sessions["child"] = child

        XCTAssertTrue(appState.applyCodexSubsessionModeToKnownSessions(statePath: statePath))
        XCTAssertNil(appState.sessions["child"])
        XCTAssertTrue(appState.sessions["parent"]?.subagents.isEmpty == true)
        XCTAssertEqual(appState.sessions["parent"]?.status, .processing)
        XCTAssertNil(appState.sessions["parent"]?.currentTool)
        XCTAssertNil(appState.sessions["parent"]?.toolDescription)
    }

    func testCurrentPluginSessionModeSeparateSplitsMergedCodexSubagent() {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("separate", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = "parent-thread"
        parent.status = .running
        parent.currentTool = "Agent"
        parent.toolDescription = "Hypatia"
        parent.cwd = "/repo"
        parent.model = "gpt-test"
        parent.remoteHostId = "test-remote"
        parent.remoteHostName = "Test Remote"
        var subagent = SubagentState(agentId: "child-thread", agentType: "worker")
        subagent.currentTool = "sleep"
        subagent.toolDescription = "sleep 45"
        parent.subagents["child-thread"] = subagent
        appState.sessions["parent"] = parent

        appState.applyCurrentPluginSessionMode(persist: false)

        XCTAssertTrue(appState.sessions["parent"]?.subagents.isEmpty == true)
        XCTAssertNil(appState.sessions["parent"]?.currentTool)
        XCTAssertEqual(appState.sessions["child-thread"]?.source, "codex")
        XCTAssertEqual(appState.sessions["child-thread"]?.providerSessionId, "child-thread")
        XCTAssertEqual(appState.sessions["child-thread"]?.cwd, "/repo")
        XCTAssertEqual(appState.sessions["child-thread"]?.model, "gpt-test")
        XCTAssertEqual(appState.sessions["child-thread"]?.remoteHostId, "test-remote")
        XCTAssertEqual(appState.sessions["child-thread"]?.remoteHostName, "Test Remote")
        XCTAssertEqual(appState.sessions["child-thread"]?.currentTool, "sleep")
        XCTAssertEqual(appState.activeSessionId, "child-thread")
    }

    func testSeparateDesktopSubagentDoesNotOverwriteSameProviderCLIChild() {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("separate", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.providerSessionId = "desktop-parent"
        parent.termBundleId = AppState.codexAppBundleId
        parent.subagents["shared-child"] = SubagentState(
            agentId: "shared-child",
            agentType: "desktop-worker"
        )
        var cliChild = SessionSnapshot()
        cliChild.source = "codex"
        cliChild.providerSessionId = "shared-child"
        cliChild.cwd = "/cli/repo"
        appState.sessions["codexapp:desktop-parent"] = parent
        appState.sessions["shared-child"] = cliChild

        appState.applyCurrentPluginSessionMode(persist: false)

        XCTAssertEqual(appState.sessions["shared-child"]?.cwd, "/cli/repo")
        XCTAssertNil(appState.sessions["shared-child"]?.termBundleId)
        XCTAssertEqual(
            appState.sessions["codexapp:shared-child"]?.termBundleId,
            AppState.codexAppBundleId
        )
        XCTAssertEqual(
            appState.sessions["codexapp:shared-child"]?.providerSessionId,
            "shared-child"
        )
    }

    func testCurrentPluginSessionModeHideClearsMergedCodexSubagent() {
        let previousMode = UserDefaults.standard.object(forKey: SettingsKey.pluginSessionMode)
        UserDefaults.standard.set("hide", forKey: SettingsKey.pluginSessionMode)
        defer {
            if let previousMode {
                UserDefaults.standard.set(previousMode, forKey: SettingsKey.pluginSessionMode)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.pluginSessionMode)
            }
        }

        let appState = AppState()
        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.currentTool = "Agent"
        parent.toolDescription = "Hypatia"
        parent.subagents["child-thread"] = SubagentState(agentId: "child-thread", agentType: "worker")
        appState.sessions["parent"] = parent

        appState.applyCurrentPluginSessionMode(persist: false)

        XCTAssertTrue(appState.sessions["parent"]?.subagents.isEmpty == true)
        XCTAssertNil(appState.sessions["parent"]?.currentTool)
        XCTAssertNil(appState.sessions["child-thread"])
    }

    func testFindSessionIdCanExcludeChildSessionAndRequireActiveParent() {
        let appState = AppState()

        var parent = SessionSnapshot()
        parent.source = "codex"
        parent.status = .running
        parent.cliPid = 1234
        parent.startTime = Date(timeIntervalSince1970: 100)
        parent.lastActivity = Date()

        var child = SessionSnapshot()
        child.source = "codex"
        child.status = .running
        child.cliPid = 1234
        child.startTime = Date(timeIntervalSince1970: 200)
        child.lastActivity = Date()

        appState.sessions["parent"] = parent
        appState.sessions["child"] = child

        XCTAssertEqual(
            appState.findSessionId(forSource: "codex", ppid: 1234, excluding: "child", requireActive: true),
            "parent"
        )
    }

    func testFindSessionIdDoesNotTreatIdleCodexThreadAsNativeSubsessionParent() {
        let appState = AppState()

        var idle = SessionSnapshot()
        idle.source = "codex"
        idle.status = .idle
        idle.cliPid = 1234
        idle.lastActivity = Date()

        appState.sessions["idle"] = idle

        XCTAssertNil(
            appState.findSessionId(forSource: "codex", ppid: 1234, excluding: "new-thread", requireActive: true)
        )
    }
}
