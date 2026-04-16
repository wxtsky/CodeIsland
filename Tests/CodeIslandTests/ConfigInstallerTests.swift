import XCTest
@testable import CodeIsland
import CodeIslandCore

final class ConfigInstallerTests: XCTestCase {
    func testRemoveManagedHookEntriesAlsoPrunesLegacyVibeIslandHooks() throws {
        let hooks: [String: Any] = [
            "SessionEnd": [
                [
                    "hooks": [
                        [
                            "command": "/Users/test/.vibe-island/bin/vibe-island-bridge --source claude",
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "command": "~/.claude/hooks/codeisland-hook.sh",
                            "timeout": 5,
                            "type": "command",
                        ],
                    ],
                ],
                [
                    "matcher": "",
                    "hooks": [
                        [
                            "async": true,
                            "command": "~/.claude/hooks/bark-notify.sh",
                            "timeout": 10,
                            "type": "command",
                        ],
                    ],
                ],
            ],
        ]

        let cleaned = ConfigInstaller.removeManagedHookEntries(from: hooks)
        let sessionEnd = try XCTUnwrap(cleaned["SessionEnd"] as? [[String: Any]])

        XCTAssertEqual(sessionEnd.count, 1)
        let remainingHooks = try XCTUnwrap(sessionEnd.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(remainingHooks.count, 1)
        XCTAssertEqual(remainingHooks.first?["command"] as? String, "~/.claude/hooks/bark-notify.sh")
    }

    // MARK: - Kimi Code CLI TOML hooks

    func testRemoveKimiHooksPreservesNonCodeIslandBlocks() {
        let toml = """
        default_model = "kimi-k2-5"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.codeisland/codeisland-bridge --source kimi"
        timeout = 5

        [[mcpServers]]
        name = "test"
        command = "npx"

        [[hooks]]
        event = "UserPromptSubmit"
        command = "echo hello"
        timeout = 1
        """

        let cleaned = ConfigInstaller.removeKimiHooks(from: toml)
        XCTAssertFalse(cleaned.contains("codeisland-bridge"))
        XCTAssertTrue(cleaned.contains("[[mcpServers]]"))
        XCTAssertTrue(cleaned.contains("echo hello"))
        XCTAssertTrue(cleaned.contains("default_model"))
    }

    func testContentsContainsKimiHookDetectsInstalledEvent() {
        let toml = """
        [[hooks]]
        event = "PreToolUse"
        command = "/Users/test/.codeisland/codeisland-bridge --source kimi"
        timeout = 5
        matcher = ".*"

        [[hooks]]
        event = "Stop"
        command = "/Users/test/.codeisland/codeisland-bridge --source kimi"
        timeout = 5
        """

        XCTAssertTrue(ConfigInstaller.contentsContainsKimiHook(toml, event: "PreToolUse"))
        XCTAssertTrue(ConfigInstaller.contentsContainsKimiHook(toml, event: "Stop"))
        XCTAssertFalse(ConfigInstaller.contentsContainsKimiHook(toml, event: "SessionStart"))
    }

    func testKimiHookFormatEvents() {
        let events = ConfigInstaller.defaultEvents(for: .kimi)
        let eventNames = events.map { $0.0 }
        XCTAssertTrue(eventNames.contains("UserPromptSubmit"))
        XCTAssertTrue(eventNames.contains("PreToolUse"))
        XCTAssertTrue(eventNames.contains("PostToolUse"))
        XCTAssertTrue(eventNames.contains("PostToolUseFailure"))
        XCTAssertFalse(eventNames.contains("PermissionRequest"), "Kimi does not support PermissionRequest")
        XCTAssertTrue(eventNames.contains("Stop"))
        XCTAssertTrue(eventNames.contains("SessionStart"))
        XCTAssertTrue(eventNames.contains("SessionEnd"))
        XCTAssertTrue(eventNames.contains("Notification"))
        XCTAssertTrue(eventNames.contains("PreCompact"))

        let notificationTimeout = events.first { $0.0 == "Notification" }?.1
        XCTAssertEqual(notificationTimeout, 600, "Kimi max timeout is 600")
    }

    /// Hermetic integration test: uses a temporary directory instead of touching ~/.kimi/config.toml.
    func testInstallKimiHooksIntegration() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let configPath = tempDir.appendingPathComponent("config.toml").path
        let originalScalar = "hooks = [\"UserPromptSubmit\"]\n"
        fm.createFile(atPath: configPath, contents: originalScalar.data(using: .utf8))

        let cli = CLIConfig(
            name: "Kimi Code CLI",
            source: "kimi",
            configPath: configPath,
            configKey: "hooks",
            format: .kimi,
            events: ConfigInstaller.defaultEvents(for: .kimi)
        )

        // Install hooks
        XCTAssertTrue(ConfigInstaller.installKimiHooks(cli: cli, fm: fm))

        // Verify file contents
        let data = try XCTUnwrap(fm.contents(atPath: configPath))
        let installed = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(installed.contains("[[hooks]]"))
        XCTAssertTrue(installed.contains("event = \"PreToolUse\""))
        XCTAssertTrue(installed.contains("event = \"Stop\""))
        XCTAssertTrue(installed.contains("codeisland-bridge --source kimi"))
        XCTAssertFalse(installed.contains("\nhooks = "), "Scalar hooks key should be commented out to avoid TOML duplicate key error")
        XCTAssertTrue(installed.contains("# hooks ="), "Legacy scalar hooks should be preserved as comments")

        // Uninstall and verify legacy hooks are restored
        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)
        let uninstalledData = try XCTUnwrap(fm.contents(atPath: configPath))
        let uninstalled = try XCTUnwrap(String(data: uninstalledData, encoding: .utf8))

        XCTAssertTrue(uninstalled.contains("hooks = [\"UserPromptSubmit\"]"), "Legacy scalar hooks should be restored after uninstall")
        XCTAssertFalse(uninstalled.contains("codeisland-bridge"), "CodeIsland hooks should be removed after uninstall")
    }

    func testMergeCocoHooksAppendsHooksSectionWhenMissing() {
        let original = "model:\n    name: GPT-5.4\n"

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        XCTAssertTrue(merged.contains("hooks:\n"))
        XCTAssertTrue(merged.contains("command: '"))
        XCTAssertTrue(merged.contains("codeisland-bridge --source traecli"))
        XCTAssertTrue(merged.contains("event: permission_request"))

        // Managed block should be a SINGLE hook with multiple matchers. TraeCli may de-dup by
        // (type + command), so emitting one hook per event can drop most events.
        XCTAssertEqual(merged.components(separatedBy: "- type: command").count - 1, 1)
        XCTAssertTrue(merged.contains("event: pre_tool_use"))
        XCTAssertTrue(merged.contains("event: post_tool_use"))
        XCTAssertTrue(merged.contains("event: stop"))
    }

    func testMergeCocoHooksReplacesExistingManagedBlockWithoutTouchingUserHooks() {
        let original = """
hooks:
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: stop
  - type: command
    command: '\(NSHomeDirectory())/.codeisland/codeisland-bridge --source traecli'
    timeout: '86400s'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: subagent_start
      - event: subagent_stop
      - event: stop
      - event: pre_compact
      - event: post_compact
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        XCTAssertTrue(merged.contains("command: 'echo user-hook'"))
        XCTAssertFalse(merged.contains("CODEISLAND_MANAGED_TRAECLI_HOOK"))

        // New managed block should still contain a traecli bridge command.
        XCTAssertEqual(merged.components(separatedBy: "codeisland-bridge --source traecli").count - 1, 1)
        XCTAssertEqual(merged.components(separatedBy: "- type: command").count - 1, 2)
    }

    func testMergeTraecliHooksRemovesQuotedBridgeCommandToAvoidDuplicates() {
        let bridge = "\(NSHomeDirectory())/.codeisland/codeisland-bridge"
        let original = """
hooks:
  - type: command
    command: '\"\(bridge)\" --source traecli'
    timeout: '86400s'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: subagent_start
      - event: subagent_stop
      - event: stop
      - event: pre_compact
      - event: post_compact
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        // Old quoted command should be removed, and the new managed block inserted once.
        XCTAssertEqual(merged.components(separatedBy: "codeisland-bridge").count - 1, 1)
        XCTAssertEqual(merged.components(separatedBy: "--source traecli").count - 1, 1)
    }

    func testMergeTraecliHooksHandlesHooksFlowSequenceWithoutBreakingYAML() {
        let original = "model: GPT-5.4\nhooks: []\n"
        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        // Should rewrite hooks into a block list and inject our managed hook.
        XCTAssertTrue(merged.contains("hooks:\n"))
        XCTAssertFalse(merged.contains("hooks: []"))
        XCTAssertEqual(merged.components(separatedBy: "--source traecli").count - 1, 1)
    }

    func testMergeTraecliHooksIsIdempotent() {
        let original = "model: GPT-5.4\n"
        let once = ConfigInstaller.mergeTraecliHooks(into: original)
        let twice = ConfigInstaller.mergeTraecliHooks(into: once)
        XCTAssertEqual(once, twice)
    }

    func testMergeTraecliHooksRemovesManagedBlockEvenWithTrailingComments() {
        let original = """
hooks:
  - type: command # keep
    command: '\(NSHomeDirectory())/.codeisland/codeisland-bridge --source traecli'
    timeout: '86400s'
    matchers:
      - event: session_start
      - event: session_end
      - event: user_prompt_submit
      - event: pre_tool_use
      - event: post_tool_use
      - event: post_tool_use_failure
      - event: permission_request
      - event: notification
      - event: subagent_start
      - event: subagent_stop
      - event: stop
      - event: pre_compact
      - event: post_compact
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: stop
"""

        let merged = ConfigInstaller.mergeTraecliHooks(into: original)

        XCTAssertTrue(merged.contains("command: 'echo user-hook'"))
        XCTAssertEqual(merged.components(separatedBy: "--source traecli").count - 1, 1)
    }

    func testRemoveManagedTraecliHooksDeletesHookWhenCommandMatches() {
        let original = """
hooks:
  # any legacy marker/comment line should be removed with the hook
  # CODEISLAND_MANAGED_TRAECLI_HOOK_BEGIN
  - type: command
    command: '\(NSHomeDirectory())/.codeisland/codeisland-bridge --source traecli'
    matchers:
      - event: stop
  # CODEISLAND_MANAGED_TRAECLI_HOOK_END
  # trailing comment should also be removed
"""

        let cleaned = ConfigInstaller.removeManagedTraecliHooks(from: original)

        XCTAssertFalse(cleaned.contains("codeisland-bridge --source traecli"))
        XCTAssertFalse(cleaned.contains("CODEISLAND_MANAGED_TRAECLI_HOOK"))
        XCTAssertFalse(cleaned.contains("trailing comment"))
    }

    func testRemoveManagedTraecliHooksDoesNotDeleteOtherCommands() {
        let original = """
hooks:
  - type: command
    command: 'echo user-hook'
    matchers:
      - event: stop
"""

        let cleaned = ConfigInstaller.removeManagedTraecliHooks(from: original)
        XCTAssertEqual(cleaned, original)
    }

    func testRemoteInstallerConfigureScriptDoesNotContainTraecliTypos() {
        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")

        let script = RemoteInstaller.configureRemoteHooksScript(host: host)

        // Ensure the Trae CLI hook block is present and contains session lifecycle events.
        XCTAssertTrue(script.contains("TRAECLI_EVENTS"))
        XCTAssertTrue(script.contains("\"session_start\""))
        XCTAssertTrue(script.contains("\"session_end\""))
    }

    func testRemoteTraecliPermissionRequestRoutesAsPermissionAndUsesRemoteSessionNamespace() async throws {
        let payload: [String: Any] = [
            "hook_event_name": "permission_request",
            "session_id": "sess-123",
            "_source": "traecli",
            "_remote_host_id": "host-1",
            "_remote_host_name": "devbox",
            "tool_name": "Bash",
            "tool_input": [
                "command": "ls",
                "description": "List files"
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let event = try XCTUnwrap(HookEvent(from: data))

        XCTAssertEqual(event.sessionId, "remote:host-1:sess-123")
        let kind = await MainActor.run { HookServer.routeKind(for: event) }
        XCTAssertEqual(kind, .permission)
    }

    func testRemoteInstallerConfigureScriptKeepsPythonNewlineEscapesAndCompiles() throws {
        let host = RemoteHost(id: "host-1", name: "devbox", host: "example.com")

        let script = RemoteInstaller.configureRemoteHooksScript(host: host)

        XCTAssertTrue(script.contains("return \"\\n\".join(lines)"))
        XCTAssertTrue(script.contains("normalized = contents.replace(\"\\r\\n\", \"\\n\")"))
        XCTAssertTrue(script.contains("if not merged.endswith(\"\\n\"):"))
        try assertPythonCompiles(script)
    }

    private func assertPythonCompiles(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; compile(sys.stdin.read(), '<stdin>', 'exec')"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, errorOutput, file: file, line: line)
    }
}
