import XCTest
@testable import CodeIsland

final class CatPawInstallTests: XCTestCase {
    func testIntegrationsHaveIndependentPathsAndSwitches() throws {
        let ide = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "catpaw" })
        let plugin = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "catpaw-idekit" })
        XCTAssertNotEqual(ide.source, plugin.source)
        XCTAssertNotEqual(ide.fullPath, plugin.fullPath)
        XCTAssertEqual(plugin.fullPath, NSHomeDirectory() + "/.sankuai/idekit/config/settings/hooks.json")
        XCTAssertEqual(ide.events.map { $0.0 }, plugin.events.map { $0.0 })
        XCTAssertEqual(ConfigInstaller.allCLIs.first?.source, "claude")
    }

    func testBlockingConflictDoesNotRewriteUserHooks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hooks.json")
        let original = #"{"hooks":{"beforeShellExecution":[{"command":"/user/policy.sh"}]}}"#
        try original.write(to: path, atomically: true, encoding: .utf8)
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "catpaw" })
        let isolated = CLIConfig(name: cli.name, source: cli.source, configPath: path.path,
                                 configKey: cli.configKey, format: cli.format, events: cli.events)
        XCTAssertFalse(ConfigInstaller.installExternalHooks(cli: isolated, fm: fm, catpawScriptDirectory: dir.appendingPathComponent("helpers").path))
        XCTAssertEqual(try String(contentsOf: path), original)
    }

    func testInstallIsIdempotentAndPreservesAfterHooks() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let path = dir.appendingPathComponent("hooks.json")
        try #"{"other":true,"hooks":{"afterAgentResponse":[{"command":"/user/log.sh"}]}}"#
            .write(to: path, atomically: true, encoding: .utf8)
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "catpaw" })
        let isolated = CLIConfig(name: cli.name, source: cli.source, configPath: path.path,
                                 configKey: cli.configKey, format: cli.format, events: cli.events)
        XCTAssertEqual(cli.fullPath, NSHomeDirectory() + "/Library/Application Support/CatPaw IDE/User/globalStorage/mt-idekit.mt-idekit-code/settings/hooks.json")
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: isolated, fm: fm, catpawScriptDirectory: dir.appendingPathComponent("helpers").path))
        let first = try String(contentsOf: path)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: isolated, fm: fm, catpawScriptDirectory: dir.appendingPathComponent("helpers").path))
        // JSON object key order is not part of the hook contract. Preserve
        // array order and values, and verify reinstall does not duplicate hooks.
        let reinstalled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? NSDictionary)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        XCTAssertEqual(reinstalled, root as NSDictionary)
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        for (event, _, _) in cli.events where event != "afterAgentResponse" {
            XCTAssertEqual(hooks[event]?.count, 1, event)
        }
        XCTAssertEqual(hooks["afterAgentResponse"]?.count, 2)
        let scriptPath = ConfigInstaller.catpawHookScriptPath(source: cli.source, directory: dir.appendingPathComponent("helpers").path)
        for (event, _, _) in cli.events {
            XCTAssertEqual(hooks[event]?.last?["command"] as? String, scriptPath, event)
        }
        XCTAssertTrue(ConfigInstaller.isCatpawHookScriptInstalled(source: cli.source, fm: fm, directory: dir.appendingPathComponent("helpers").path))
        XCTAssertEqual(hooks["beforeSubmitPrompt"]?.count, 1)
        XCTAssertNil(hooks["afterAgentThought"])
        XCTAssertNil(hooks["beforeReadFile"])
        XCTAssertNil(hooks["afterFileEdit"])
        XCTAssertEqual(root["other"] as? Bool, true)
    }
    func testBothIntegrationsMigrateLegacyCommandsToScriptPaths() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let helpers = dir.appendingPathComponent("helpers with spaces")
        for source in ["catpaw", "catpaw-idekit"] {
            let original = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == source })
            let path = dir.appendingPathComponent(source + ".json")
            let old = ["hooks": ["stop": [["command": "/old/codeisland-bridge --source \(source) --event stop"]]]]
            try JSONSerialization.data(withJSONObject: old).write(to: path)
            let cli = CLIConfig(name: original.name, source: source, configPath: path.path,
                                configKey: original.configKey, format: original.format, events: original.events)
            XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm, catpawScriptDirectory: helpers.path))
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
            for (event, _, _) in cli.events {
                XCTAssertEqual(hooks[event]?.count, 1)
                XCTAssertEqual(hooks[event]?.first?["command"] as? String,
                               helpers.appendingPathComponent("codeisland-\(source)-hook.sh").path)
            }
        }
    }

    func testWrappersPreserveStdinAndSourceWithoutChangingClaudeScript() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("CatPaw scripts ' \(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let claude = dir.appendingPathComponent("codeisland-hook.sh")
        try "Claude sentinel".write(to: claude, atomically: true, encoding: .utf8)
        let bridge = dir.appendingPathComponent("codeisland-bridge")
        let fakeBridge = """
        #!/bin/sh
        printf '%s\\n' "$@" > "$CODEISLAND_TEST_ARGS"
        /bin/cat > "$CODEISLAND_TEST_INPUT"
        printf '{}\\n'
        """
        let input = Data(#"{"hook_event_name":"stop","conversation_id":"chat"}"#.utf8)
        for source in ["catpaw", "catpaw-idekit"] {
            XCTAssertTrue(ConfigInstaller.installCatpawHookScript(source: source, fm: fm, directory: dir.path))
            XCTAssertTrue(ConfigInstaller.isCatpawHookScriptInstalled(source: source, fm: fm, directory: dir.path))
            let wrapper = ConfigInstaller.catpawHookScriptPath(source: source, directory: dir.path)
            func run() throws -> String {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: wrapper)
                var env = ProcessInfo.processInfo.environment
                env["CODEISLAND_TEST_ARGS"] = dir.appendingPathComponent("args").path
                env["CODEISLAND_TEST_INPUT"] = dir.appendingPathComponent("input").path
                process.environment = env
                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                try process.run()
                stdin.fileHandleForWriting.write(input)
                try stdin.fileHandleForWriting.close()
                let result = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                return String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            // Missing bridge is a neutral result, never a dependency on nc/jq/Python.
            try? fm.removeItem(at: bridge)
            XCTAssertEqual(try run(), "{}")
            try fakeBridge.write(to: bridge, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bridge.path)
            XCTAssertEqual(try run(), "{}")
            XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("input")), input)
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("args")), "--source\n\(source)\n")
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wrapper)
            XCTAssertFalse(ConfigInstaller.isCatpawHookScriptInstalled(source: source, fm: fm, directory: dir.path))
            XCTAssertTrue(ConfigInstaller.installCatpawHookScript(source: source, fm: fm, directory: dir.path))
        }
        XCTAssertEqual(try String(contentsOf: claude), "Claude sentinel")
    }

}
