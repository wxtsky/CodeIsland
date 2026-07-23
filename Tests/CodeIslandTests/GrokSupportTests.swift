import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

final class GrokSupportTests: XCTestCase {
    func testSourceNormalizationAndLabel() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("grok"), "grok")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("Grok CLI"), "grok")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("grok-build"), "grok")

        var snapshot = SessionSnapshot()
        snapshot.source = "grok"
        XCTAssertEqual(snapshot.sourceLabel, "Grok CLI")
    }

    func testGrokExecutableResolverAcceptsManagedAndPathInstalls() {
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/Users/test/.grok/downloads/grok-0.2.106-macos-aarch64",
            source: "grok"
        ))
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/opt/homebrew/bin/grok",
            source: "grok-cli"
        ))
        XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(
            "/Applications/Browser.app/Contents/MacOS/grok-helper",
            source: "grok"
        ))
    }

    func testGrokEventAliasesReachTerminalStates() {
        XCTAssertEqual(EventNormalizer.normalize("permission_denied"), "PermissionDenied")
        XCTAssertEqual(EventNormalizer.normalize("stop_failure"), "Stop")
        XCTAssertEqual(EventNormalizer.normalize("StopFailure"), "Stop")
    }

    func testGrokCLIUsesEveryManagedHookEvent() throws {
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "grok" })
        XCTAssertEqual(cli.events.map(\.0), GrokHookForwardingPolicy.managedHookEvents)
    }

    func testGrokEncodedCwdEscapesSlashesAndSpaces() {
        XCTAssertEqual(
            AppState.grokEncodedCwd("/Users/test/My Project"),
            "%2FUsers%2Ftest%2FMy%20Project"
        )
    }

    func testGrokProcessMatchingRejectsLateSessionFromOlderProcess() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldProcessStart = now.addingTimeInterval(-35 * 60)
        let newProcessStart = now.addingTimeInterval(-5)
        let sessionCreatedAt = now.addingTimeInterval(-4)

        XCTAssertNil(AppState.grokSessionProcessMatchScore(
            createdAt: sessionCreatedAt,
            activityAt: now,
            processStart: oldProcessStart,
            now: now
        ))
        XCTAssertNotNil(AppState.grokSessionProcessMatchScore(
            createdAt: sessionCreatedAt,
            activityAt: now,
            processStart: newProcessStart,
            now: now
        ))
    }

    func testGrokProcessMatchingIsOneToOneForParallelSameCwdSessions() {
        let base = Date(timeIntervalSince1970: 20_000)
        let mapping = AppState.matchGrokSessionsToProcesses(
            processes: [
                (pid: 101, startedAt: base),
                (pid: 202, startedAt: base.addingTimeInterval(30)),
            ],
            sessions: [
                (
                    id: "first",
                    createdAt: base.addingTimeInterval(2),
                    activityAt: base.addingTimeInterval(40)
                ),
                (
                    id: "second",
                    createdAt: base.addingTimeInterval(32),
                    activityAt: base.addingTimeInterval(50)
                ),
            ],
            now: base.addingTimeInterval(60)
        )

        XCTAssertEqual(mapping["first"], 101)
        XCTAssertEqual(mapping["second"], 202)
        XCTAssertEqual(Set(mapping.values).count, mapping.count)
    }

    func testGrokProcessMatchingUsesAugmentingPathToKeepEveryViableSession() {
        let base = Date(timeIntervalSince1970: 30_000)
        let mapping = AppState.matchGrokSessionsToProcesses(
            processes: [
                (pid: 101, startedAt: base),
                (pid: 202, startedAt: base.addingTimeInterval(100)),
            ],
            sessions: [
                (
                    id: "newer-resumed",
                    createdAt: base.addingTimeInterval(1),
                    activityAt: base.addingTimeInterval(110)
                ),
                (
                    id: "older-one-shot",
                    createdAt: base,
                    activityAt: base.addingTimeInterval(50)
                ),
            ],
            now: base.addingTimeInterval(110)
        )

        XCTAssertEqual(mapping["newer-resumed"], 202)
        XCTAssertEqual(mapping["older-one-shot"], 101)
        XCTAssertEqual(mapping.count, 2)
    }

    func testGrokProcessMatchingBreaksEqualScoresDeterministically() {
        let base = Date(timeIntervalSince1970: 40_000)
        let processes: [(pid: pid_t, startedAt: Date?)] = [
            (pid: 202, startedAt: base),
            (pid: 101, startedAt: base),
        ]
        let sessions: [(id: String, createdAt: Date?, activityAt: Date)] = [
            (id: "beta", createdAt: base, activityAt: base.addingTimeInterval(10)),
            (id: "alpha", createdAt: base, activityAt: base.addingTimeInterval(10)),
        ]

        let first = AppState.matchGrokSessionsToProcesses(
            processes: processes,
            sessions: sessions,
            now: base.addingTimeInterval(10)
        )
        let second = AppState.matchGrokSessionsToProcesses(
            processes: Array(processes.reversed()),
            sessions: Array(sessions.reversed()),
            now: base.addingTimeInterval(10)
        )

        XCTAssertEqual(first, ["alpha": 101, "beta": 202])
        XCTAssertEqual(second, first)
    }

    func testGrokNativeHookInstallIsNestedMatcherFreeAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cli = grokCLI(root: root)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))

        let data = try Data(contentsOf: root.appendingPathComponent("hooks/codeisland.json"))
        let rootJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(rootJSON["hooks"] as? [String: Any])

        for event in cli.events.map(\.0) {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertEqual(entries.count, 1)
            XCTAssertNil(entries[0]["matcher"], "Grok rejects matcher on lifecycle hooks")
            let commands = try XCTUnwrap(entries[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(commands.count, 1)
            XCTAssertTrue((commands[0]["command"] as? String)?.hasSuffix("--source grok") == true)
        }
    }

    func testGrokHookUninstallPreservesUserEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-hooks-uninstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cli = grokCLI(root: root)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: .default))
        let file = root.appendingPathComponent("hooks/codeisland.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [
            ["hooks": [["type": "command", "command": "/usr/bin/true"]]]
        ]
        json["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file)

        ConfigInstaller.uninstallHooks(cli: cli, fm: .default)

        let cleaned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let cleanedHooks = try XCTUnwrap(cleaned["hooks"] as? [String: Any])
        let stopEntries = try XCTUnwrap(cleanedHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopEntries.count, 1)
        let userCommands = try XCTUnwrap(stopEntries[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(userCommands[0]["command"] as? String, "/usr/bin/true")
    }

    private func grokCLI(root: URL) -> CLIConfig {
        CLIConfig(
            name: "Grok CLI",
            source: "grok",
            configPath: "hooks/codeisland.json",
            configKey: "hooks",
            format: .nested,
            events: GrokHookForwardingPolicy.managedHookEvents.map { ($0, 5, false) },
            rootOverride: { root.path }
        )
    }
}
