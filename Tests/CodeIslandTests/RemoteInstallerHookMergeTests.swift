import XCTest
@testable import CodeIsland

/// #242 — the remote install script must MERGE our hooks into existing config
/// files, never replace whole event keys. Every SSH connect re-runs the script,
/// so a replace would wipe user-authored hooks (e.g. a custom SessionStart) on
/// each connection. These tests execute the real embedded Python script against
/// a sandbox $HOME and a sandbox PATH; the same harness also covers where the
/// script looks for config dirs (#342 custom CLIs).
final class RemoteInstallerHookMergeTests: XCTestCase {
    private var sandboxHome: URL!
    /// The only directory on the script's PATH. Empty unless a test drops a fake
    /// executable in it, so `shutil.which` never sees the developer's own CLIs.
    private var sandboxBin: URL!

    override func setUpWithError() throws {
        sandboxHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeisland-remote-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandboxHome, withIntermediateDirectories: true)
        sandboxBin = sandboxHome.appendingPathComponent(".test-bin")
        try FileManager.default.createDirectory(at: sandboxBin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandboxHome)
    }

    /// Runs the real embedded install script against the sandbox $HOME and returns
    /// its status line (the text Settings → Remote shows for the host).
    @discardableResult
    private func runConfigureScript(
        customCLIs: [CLIConfig] = [],
        environment overrides: [String: String] = [:]
    ) throws -> String {
        let host = RemoteHost(name: "test-host", host: "example.invalid")
        let script = RemoteInstaller.configureRemoteHooksScript(host: host, remoteSocketPath: "/tmp/ci-test.sock", customCLIs: customCLIs)

        let process = Process()
        // Absolute interpreter so PATH can be pinned to the sandbox bin dir.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = sandboxHome.path
        environment["PATH"] = sandboxBin.path
        // Keep the script away from any real Codex / Claude config dir configured in
        // the caller env — it would otherwise write hooks there.
        environment.removeValue(forKey: "CODEX_HOME")
        environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        for (key, value) in overrides { environment[key] = value }
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "configure script failed: \(err)")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Puts a fake executable on the script's PATH, as if the CLI were installed.
    private func installFakeBinary(_ name: String) throws {
        let url = sandboxBin.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: sandboxHome.appendingPathComponent(relativePath).path)
    }

    private func writeJSON(_ object: [String: Any], to relativePath: String) throws {
        let url = sandboxHome.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func readJSON(_ relativePath: String) throws -> [String: Any] {
        let url = sandboxHome.appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func commands(in entries: [[String: Any]]) -> [String] {
        entries.flatMap { entry -> [String] in
            ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testClaudeInstallPreservesUserSessionStartHooks() throws {
        let userEntry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": "echo my-custom-session-start", "timeout": 5]],
        ]
        try writeJSON(["hooks": ["SessionStart": [userEntry]]], to: ".claude/settings.json")

        try runConfigureScript()

        let settings = try readJSON(".claude/settings.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let cmds = commands(in: sessionStart)
        XCTAssertTrue(cmds.contains { $0.contains("my-custom-session-start") }, "user hook was wiped: \(cmds)")
        XCTAssertTrue(cmds.contains { $0.contains("codeisland-remote-hook.py") }, "our hook missing: \(cmds)")
        // User entry stays first — we append after it.
        XCTAssertTrue(commands(in: [sessionStart[0]]).contains { $0.contains("my-custom-session-start") })
    }

    func testClaudeInstallIsIdempotentAcrossReconnects() throws {
        let userEntry: [String: Any] = [
            "hooks": [["type": "command", "command": "echo keep-me", "timeout": 5]],
        ]
        try writeJSON(["hooks": ["Stop": [userEntry]]], to: ".claude/settings.json")

        // Simulate three SSH reconnects.
        try runConfigureScript()
        try runConfigureScript()
        try runConfigureScript()

        let settings = try readJSON(".claude/settings.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let cmds = commands(in: stop)
        XCTAssertEqual(cmds.filter { $0.contains("keep-me") }.count, 1, "user hook duplicated or lost: \(cmds)")
        XCTAssertEqual(cmds.filter { $0.contains("codeisland-remote-hook.py") }.count, 1, "our hook not deduped: \(cmds)")
    }

    func testCodexInstallPreservesUserHooks() throws {
        let userEntry: [String: Any] = [
            "hooks": [["type": "command", "command": "echo codex-user-hook", "timeout": 5]],
        ]
        try writeJSON(["hooks": ["SessionStart": [userEntry]]], to: ".codex/hooks.json")

        try runConfigureScript()

        let settings = try readJSON(".codex/hooks.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let cmds = commands(in: sessionStart)
        XCTAssertTrue(cmds.contains { $0.contains("codex-user-hook") }, "user hook was wiped: \(cmds)")
        XCTAssertTrue(cmds.contains { $0.contains("codeisland-remote-hook.py") }, "our hook missing: \(cmds)")
    }

    func testCodexConfigFailureIsReportedWithoutChangingConfig() throws {
        let root = sandboxHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        let original = "features = { hooks = false }\n"
        try original.write(to: config, atomically: true, encoding: .utf8)

        let status = try runConfigureScript()

        XCTAssertTrue(status.contains("Codex config update failed"), status)
        XCTAssertFalse(status.contains("Codex ok"), status)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    func testCodeBuddyInstallPreservesUserHooks() throws {
        let userEntry: [String: Any] = [
            "matcher": "*",
            "hooks": [["type": "command", "command": "echo buddy-user-hook", "timeout": 5]],
        ]
        try writeJSON(["hooks": ["PermissionRequest": [userEntry]]], to: ".codebuddy/settings.json")

        try runConfigureScript()

        let settings = try readJSON(".codebuddy/settings.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let permission = try XCTUnwrap(hooks["PermissionRequest"] as? [[String: Any]])
        let cmds = commands(in: permission)
        XCTAssertTrue(cmds.contains { $0.contains("buddy-user-hook") }, "user hook was wiped: \(cmds)")
        XCTAssertTrue(cmds.contains { $0.contains("codeisland-remote-hook.py") }, "our hook missing: \(cmds)")
    }

    func testQoderInstallPreservesUserHooks() throws {
        let userEntry: [String: Any] = [
            "hooks": [["type": "command", "command": "echo qoder-user-hook", "timeout": 5]],
        ]
        try writeJSON(["hooks": ["SessionStart": [userEntry]]], to: ".qoder/settings.json")

        try runConfigureScript()

        let settings = try readJSON(".qoder/settings.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let cmds = commands(in: sessionStart)
        XCTAssertTrue(cmds.contains { $0.contains("qoder-user-hook") }, "user hook was wiped: \(cmds)")
        XCTAssertTrue(cmds.contains { $0.contains("CODEISLAND_SOURCE=qoder") }, "Qoder source missing: \(cmds)")
        XCTAssertTrue(cmds.contains { $0.contains("codeisland-remote-hook.py") }, "our hook missing: \(cmds)")
    }

    /// #306 — remote Codex registered only SessionStart / UserPromptSubmit /
    /// Stop, so an approval never left the remote terminal even though remote
    /// Claude, on the same host and the same tunnel, worked. The blocking event
    /// needs the long timeout too: the wait is on a human.
    func testCodexInstallRegistersBlockingPermissionRequest() throws {
        try writeJSON(["hooks": [:]], to: ".codex/hooks.json")

        try runConfigureScript()

        let settings = try readJSON(".codex/hooks.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let permission = try XCTUnwrap(
            hooks["PermissionRequest"] as? [[String: Any]],
            "no PermissionRequest hook — the approval can only be answered in the remote terminal"
        )
        XCTAssertTrue(commands(in: permission).contains { $0.contains("CODEISLAND_SOURCE=codex") })

        let timeouts = permission.flatMap { entry -> [Int] in
            ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["timeout"] as? Int }
        }
        XCTAssertTrue(
            timeouts.contains(86400),
            "a permission prompt waits on a person; a 60s timeout would abandon it: \(timeouts)"
        )

        // Remote Codex must mirror every officially supported local lifecycle
        // event or remote cards lose status detail that local cards retain.
        let expectedEvents: Set<String> = [
            "PreToolUse", "PermissionRequest", "PostToolUse", "PreCompact",
            "PostCompact", "SessionStart", "SessionEnd", "SubagentStart",
            "SubagentStop", "UserPromptSubmit", "Stop", "Interrupt",
        ]
        XCTAssertEqual(Set(hooks.keys), expectedEvents)
    }

    /// Codex clamps SessionEnd / Interrupt hooks to 3 s and warns about any
    /// longer timeout; a reconnect must also replace a stale 60 s entry.
    func testCodexTeardownHooksStayWithinCodexTimeoutCap() throws {
        let stale: [String: Any] = ["hooks": [[
            "type": "command", "timeout": 60,
            "command": "CODEISLAND_SOURCE=codex python3 ~/.codeisland/codeisland-remote-hook.py",
        ]]]
        try writeJSON(["hooks": ["Interrupt": [stale]]], to: ".codex/hooks.json")

        try runConfigureScript()

        let hooks = try XCTUnwrap(readJSON(".codex/hooks.json")["hooks"] as? [String: Any])
        func timeouts(_ event: String) -> [Int] {
            ((hooks[event] as? [[String: Any]]) ?? []).flatMap { entry in
                ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["timeout"] as? Int }
            }
        }
        XCTAssertEqual(timeouts("SessionEnd"), [3])
        XCTAssertEqual(timeouts("Interrupt"), [3])
        XCTAssertEqual(timeouts("Stop"), [60])
    }

    func testQoderInstallIsIdempotentAcrossReconnects() throws {
        let userEntry: [String: Any] = [
            "hooks": [["type": "command", "command": "echo keep-qoder", "timeout": 5]],
        ]
        try writeJSON(["hooks": ["Stop": [userEntry]]], to: ".qoder/settings.json")

        try runConfigureScript()
        try runConfigureScript()
        try runConfigureScript()

        let settings = try readJSON(".qoder/settings.json")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let cmds = commands(in: stop)
        XCTAssertEqual(cmds.filter { $0.contains("keep-qoder") }.count, 1, "user hook duplicated or lost: \(cmds)")
        XCTAssertEqual(cmds.filter { $0.contains("CODEISLAND_SOURCE=qoder") }.count, 1, "our hook not deduped: \(cmds)")
    }

    // MARK: - $CLAUDE_CONFIG_DIR on the remote host (#271)

    private func assertOurClaudeHooks(in settingsPath: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let settings = try readJSON(settingsPath)
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any], file: file, line: line)
        let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]], file: file, line: line)
        XCTAssertTrue(
            commands(in: stop).contains { $0.contains("CODEISLAND_SOURCE=claude") },
            "our Claude hook missing from \(settingsPath)", file: file, line: line
        )
    }

    /// Claude Code reads hooks from $CLAUDE_CONFIG_DIR/settings.json, so that is
    /// where they must go — a write to ~/.claude would never fire.
    func testClaudeInstallHonoursClaudeConfigDir() throws {
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent("claude-work"),
            withIntermediateDirectories: true
        )

        let status = try runConfigureScript(environment: [
            "CLAUDE_CONFIG_DIR": sandboxHome.appendingPathComponent("claude-work").path,
        ])

        try assertOurClaudeHooks(in: "claude-work/settings.json")
        XCTAssertFalse(fileExists(".claude"), "hooks leaked into ~/.claude, which Claude Code does not read")
        XCTAssertTrue(status.contains("Claude ok (~/claude-work)"), status)
    }

    func testClaudeConfigDirWithTildeExpandsAgainstRemoteHome() throws {
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent("claude-work"),
            withIntermediateDirectories: true
        )

        try runConfigureScript(environment: ["CLAUDE_CONFIG_DIR": "~/claude-work/"])

        try assertOurClaudeHooks(in: "claude-work/settings.json")
        XCTAssertFalse(fileExists("~"))
    }

    /// Unset (or unusable) keeps today's behaviour exactly, status text included.
    func testClaudeInstallWithoutClaudeConfigDirUsesDotClaude() throws {
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )

        let status = try runConfigureScript()

        try assertOurClaudeHooks(in: ".claude/settings.json")
        XCTAssertTrue(status.hasPrefix("Claude ok · "), status)
    }

    func testRelativeClaudeConfigDirFallsBackToDotClaude() throws {
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )

        let status = try runConfigureScript(environment: ["CLAUDE_CONFIG_DIR": "claude-work"])

        try assertOurClaudeHooks(in: ".claude/settings.json")
        XCTAssertFalse(fileExists("claude-work"))
        XCTAssertTrue(status.hasPrefix("Claude ok · "), status)
    }

    /// The trap from the #270 attempt: Claude Code on PATH but never run with the
    /// custom dir, so the dir does not exist yet. An early return on the missing
    /// dir made the `which claude` check unreachable and installed nothing.
    func testClaudeConfigDirAbsentButClaudeOnPathStillInstalls() throws {
        try installFakeBinary("claude")

        let status = try runConfigureScript(environment: [
            "CLAUDE_CONFIG_DIR": sandboxHome.appendingPathComponent("claude-work").path,
        ])

        try assertOurClaudeHooks(in: "claude-work/settings.json")
        XCTAssertFalse(fileExists(".claude"))
        XCTAssertTrue(status.contains("Claude ok (~/claude-work)"), status)
    }

    /// Same direction without the variable: a fresh host with Claude Code on PATH
    /// still gets ~/.claude hooks.
    func testNoConfigDirButClaudeOnPathInstallsIntoDotClaude() throws {
        try installFakeBinary("claude")

        try runConfigureScript()

        try assertOurClaudeHooks(in: ".claude/settings.json")
    }

    func testClaudeSkippedWhenNeitherConfigDirNorBinaryExists() throws {
        let withVar = try runConfigureScript(environment: [
            "CLAUDE_CONFIG_DIR": sandboxHome.appendingPathComponent("claude-work").path,
        ])
        XCTAssertTrue(withVar.hasPrefix("Claude skipped (config dir not found: ~/claude-work) · "), withVar)
        XCTAssertFalse(fileExists("claude-work"))
        XCTAssertFalse(fileExists(".claude"))

        let withoutVar = try runConfigureScript()
        XCTAssertTrue(withoutVar.hasPrefix("Claude skipped · "), withoutVar)
        XCTAssertFalse(fileExists(".claude"))
    }

    /// ext4/xfs are byte-preserving: the path must be used exactly as given. A
    /// decomposed name normalized to NFC (as the macOS-side resolver does) would be
    /// a different, non-existent directory on Linux. APFS lookups can't observe the
    /// difference, so compare the bytes the script reports.
    func testClaudeConfigDirIsNotUnicodeNormalized() throws {
        let decomposed = "cafe\u{0301}-claude"
        XCTAssertNotEqual(Array(decomposed.utf8), Array(decomposed.precomposedStringWithCanonicalMapping.utf8))
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent(decomposed),
            withIntermediateDirectories: true
        )

        let status = try runConfigureScript(environment: [
            "CLAUDE_CONFIG_DIR": sandboxHome.path + "/" + decomposed,
        ])

        XCTAssertNotNil(
            Data(status.utf8).range(of: Data("Claude ok (~/\(decomposed))".utf8)),
            "config dir was not used byte-for-byte: \(status)"
        )
    }

    // MARK: - Custom CLIs on the remote host (#342)

    private func corpCodex(configPath: String) -> CLIConfig {
        CLIConfig(
            name: "corp_codex", source: "corp_codex",
            configPath: configPath, configKey: "hooks",
            format: .nested,
            events: ConfigInstaller.defaultEvents(for: .nested)
        )
    }

    /// #342 — a custom CLI whose config path was typed as `~/…` (how Settings
    /// displays every path) was joined onto the remote $HOME verbatim, giving
    /// `$HOME/~/…`. That dir never exists, so the CLI was always "skipped" even
    /// though its real config dir was right there.
    func testCustomCLITildeConfigPathResolvesAgainstRemoteHome() throws {
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent(".corp/engine/codex"),
            withIntermediateDirectories: true
        )

        let status = try runConfigureScript(customCLIs: [corpCodex(configPath: "~/.corp/engine/codex/hooks.json")])

        XCTAssertTrue(status.contains("corp_codex ok"), status)
        let config = try readJSON(".corp/engine/codex/hooks.json")
        let hooks = try XCTUnwrap(config["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        XCTAssertTrue(commands(in: sessionStart).contains { $0.contains("CODEISLAND_SOURCE=corp_codex") })
        XCTAssertFalse(fileExists("~"), "a literal ~ directory was created under the remote home")
    }

    /// The same path spelled with the Mac's own home prefix must land under the
    /// remote home too — `/Users/<me>/…` does not exist on a Linux host.
    func testCustomCLIMacHomeConfigPathResolvesAgainstRemoteHome() throws {
        // Unique name: a regression must not be able to write into the real home.
        let dir = ".corp-\(UUID().uuidString)/engine/codex"
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent(dir),
            withIntermediateDirectories: true
        )
        let macPath = NSHomeDirectory() + "/\(dir)/hooks.json"
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath(macPath), "\(dir)/hooks.json")

        let status = try runConfigureScript(customCLIs: [corpCodex(configPath: macPath)])

        XCTAssertTrue(status.contains("corp_codex ok"), status)
        XCTAssertTrue(fileExists("\(dir)/hooks.json"))
    }

    func testRemoteCustomConfigPathNormalization() {
        let home = "/Users/me"
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath("~/.x/hooks.json", localHome: home), ".x/hooks.json")
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath("~//.x/hooks.json", localHome: home), ".x/hooks.json")
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath(".x/hooks.json", localHome: home), ".x/hooks.json")
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath("/Users/me/.x/hooks.json", localHome: home), ".x/hooks.json")
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath("  ~/.x/hooks.json ", localHome: home), ".x/hooks.json")
        // Absolute paths outside the Mac home are meant literally.
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath("/opt/tool/hooks.json", localHome: home), "/opt/tool/hooks.json")
        // Only a whole path component counts as the home prefix.
        XCTAssertEqual(RemoteInstaller.remoteCustomConfigPath("/Users/meg/.x/hooks.json", localHome: home), "/Users/meg/.x/hooks.json")
    }

    /// "skipped" alone gave the user nothing to act on: the status line now names
    /// the directory that was looked for on the remote host.
    func testCustomCLISkipNamesTheMissingConfigDir() throws {
        let status = try runConfigureScript(customCLIs: [corpCodex(configPath: "~/.corp/engine/codex/hooks.json")])

        XCTAssertTrue(
            status.contains("corp_codex skipped (config dir not found: ~/.corp/engine/codex)"),
            status
        )
        XCTAssertFalse(fileExists(".corp"), "a skipped CLI must not get a config dir created")
    }

    /// The other half of the guard still holds: with the CLI's binary on PATH the
    /// install goes ahead and creates the config dir.
    func testCustomCLIWithBinaryOnPathInstallsWithoutConfigDir() throws {
        try installFakeBinary("corp_codex")

        let status = try runConfigureScript(customCLIs: [corpCodex(configPath: "~/.corp/engine/codex/hooks.json")])

        XCTAssertTrue(status.contains("corp_codex ok"), status)
        XCTAssertTrue(fileExists(".corp/engine/codex/hooks.json"))
    }

    /// Templates the remote hook cannot drive used to vanish from the status line
    /// entirely; they are now reported, and still never installed.
    func testUnsupportedCustomTemplateIsReportedNotInstalled() throws {
        try FileManager.default.createDirectory(
            at: sandboxHome.appendingPathComponent(".cl"),
            withIntermediateDirectories: true
        )
        let flat = CLIConfig(
            name: "CursorLike", source: "cursorlike",
            configPath: ".cl/hooks.json", configKey: "hooks",
            format: .flat,
            events: [("beforeSubmitPrompt", 5, false)]
        )

        let status = try runConfigureScript(customCLIs: [flat])

        XCTAssertTrue(status.contains("CursorLike skipped (template not supported remotely)"), status)
        XCTAssertFalse(fileExists(".cl/hooks.json"))
    }

    /// Hermes runs a hook command without a shell — `shlex.split`, then exec
    /// (agent/shell_hooks.py). The `VAR=value python3 ~/…` form other CLIs get
    /// was taken for a program named `CODEISLAND_SOCKET_PATH=…`, so remote
    /// Hermes hooks never ran. A reconnect replaces those entries, keeps the
    /// user's own, and registers every turn hook (#364).
    func testHermesHooksRunWithoutAShellAndReplaceTheShellForm() throws {
        let staleCommand = "CODEISLAND_SOCKET_PATH=/tmp/ci-test.sock CODEISLAND_REMOTE_HOST_ID=\"old\" "
            + "CODEISLAND_REMOTE_HOST_NAME=\"old\" CODEISLAND_SOURCE=hermes python3 ~/.codeisland/codeisland-remote-hook.py"
        let config = """
            model: hermes-4
            hooks:
              pre_tool_call:
                - command: '\(staleCommand)'
                  timeout: 5
                - command: ~/.hermes/agent-hooks/audit.sh
                  timeout: 10
              on_session_end:
                - command: '\(staleCommand)'
                  timeout: 5
            """
        let configURL = sandboxHome.appendingPathComponent(".hermes/config.yaml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(config.utf8).write(to: configURL)

        let status = try runConfigureScript()
        XCTAssertTrue(status.contains("Hermes ok"), status)
        try assertHermesHooksRunnable(configURL: configURL)

        // A reconnect (here also under a new host id) replaces ours again
        // rather than stacking a second copy.
        try runConfigureScript()
        try assertHermesHooksRunnable(configURL: configURL)
    }

    private func assertHermesHooksRunnable(configURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        // Read back the way Hermes does: yaml, then shlex.split on each command.
        let commandsByEvent = try runPython("""
            import json, shlex, sys
            hooks, event = {}, None
            for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
                s = line.strip()
                if line.startswith("  ") and not line.startswith("    ") and s.endswith(":"):
                    event = s[:-1]
                    hooks[event] = []
                elif s.startswith("- command:") and event:
                    raw = s[len("- command:"):].strip()
                    if raw.startswith("'") and raw.endswith("'"):
                        raw = raw[1:-1].replace("''", "'")
                    hooks[event].append(shlex.split(raw))
            print(json.dumps(hooks))
            """, arguments: [configURL.path]) as? [String: [[String]]]
        let hooks = try XCTUnwrap(commandsByEvent, file: file, line: line)

        let hookScript = sandboxHome.appendingPathComponent(".codeisland/codeisland-remote-hook.py").path
        for event in ["pre_tool_call", "post_tool_call", "pre_llm_call", "post_llm_call",
                      "on_session_start", "on_session_end", "on_session_finalize", "subagent_stop"] {
            let ours = (hooks[event] ?? []).filter { $0.joined().contains("codeisland-remote-hook") }
            XCTAssertEqual(ours.count, 1, "\(event): \(hooks[event] ?? [])", file: file, line: line)
            let argv = try XCTUnwrap(ours.first, file: file, line: line)
            XCTAssertEqual(argv.first, "env", "\(event) must start with a program, not a VAR=value: \(argv)",
                           file: file, line: line)
            XCTAssertEqual(Array(argv.suffix(2)), ["python3", hookScript], "absolute path: Hermes never expands ~",
                           file: file, line: line)
            XCTAssertTrue(argv.contains("CODEISLAND_SOURCE=hermes"), file: file, line: line)
            XCTAssertTrue(argv.contains("CODEISLAND_SOCKET_PATH=/tmp/ci-test.sock"), file: file, line: line)
        }
        XCTAssertTrue(
            (hooks["pre_tool_call"] ?? []).contains(["~/.hermes/agent-hooks/audit.sh"]),
            "the user's own hook survives", file: file, line: line
        )
        XCTAssertTrue(try String(contentsOf: configURL, encoding: .utf8).contains("model: hermes-4"), file: file, line: line)
    }

    private func runPython(_ code: String, arguments: [String]) throws -> Any {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", code] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONSerialization.jsonObject(with: out)
    }
}
