import XCTest
@testable import CodeIsland
@testable import CodeIslandCore

/// Locks in the wire-level pieces of MiniMax Code CLI (`mcode`) support —
/// the parts that don't need a live mcode install to verify, but where a typo
/// would silently break the whole integration: source normalization, the
/// process matcher, the plugin-pack installer, and the hook event list.
///
/// The upstream contract these tests encode was verified against a live mcode
/// install: hooks are only loadable through a local plugin
/// (`~/.minimax/plugins/<name>/`, auto-discovered by directory scan), the
/// hooks.json is Claude-compatible with second-based timeouts, and the hook
/// stdin carries hook_event_name/session_id/transcript_path/cwd.
final class MinimaxSupportTests: XCTestCase {
    private var savedDataDir: String?
    private var savedMavisDir: String?

    override func setUp() {
        super.setUp()
        savedDataDir = ProcessInfo.processInfo.environment["MINIMAX_DATA_DIR"]
        savedMavisDir = ProcessInfo.processInfo.environment["MAVIS_DATA_DIR"]
        unsetenv("MINIMAX_DATA_DIR")
        unsetenv("MAVIS_DATA_DIR")
    }

    override func tearDown() {
        if let savedDataDir { setenv("MINIMAX_DATA_DIR", savedDataDir, 1) } else { unsetenv("MINIMAX_DATA_DIR") }
        if let savedMavisDir { setenv("MAVIS_DATA_DIR", savedMavisDir, 1) } else { unsetenv("MAVIS_DATA_DIR") }
        super.tearDown()
    }

    // MARK: - SessionSnapshot supported source recognition

    func testMinimaxIsRecognizedAsSupportedSource() {
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("minimax"), "minimax")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("MiniMax Code CLI"), "minimax")
    }

    func testMinimaxAliasesNormalizeToMinimax() {
        // The executable is `mcode` and the Node runtime renames the process
        // title to `minimax-code` — both spellings must land on `minimax`.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("mcode"), "minimax")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("minimax-code"), "minimax")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("minimaxcode"), "minimax")
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("minimax-cli"), "minimax")
        // Prefix-match path (via the hasPrefix("minimax") clause) — covers any
        // future "minimax-something" sub-brand without enumerating it.
        XCTAssertEqual(SessionSnapshot.normalizedSupportedSource("minimax-pro"), "minimax")
    }

    func testMinimaxDisplayName() {
        var snapshot = SessionSnapshot()
        snapshot.source = "minimax"
        XCTAssertEqual(snapshot.sourceLabel, "MiniMax Code CLI")
    }

    // MARK: - CLIProcessResolver

    func testMinimaxExecutableResolverAcceptsKnownLaunchShapes() {
        // Renamed process title (what ps shows for a running mcode).
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "minimax-code",
            source: "minimax"
        ))
        // PATH symlink and npm-global script launches.
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/opt/homebrew/bin/mcode",
            source: "minimax"
        ))
        XCTAssertTrue(CLIProcessResolver.sourceMatchesExecutablePath(
            "/opt/homebrew/lib/node_modules/@minimax-ai/code/cli.js",
            source: "minimax"
        ))
        XCTAssertFalse(CLIProcessResolver.sourceMatchesExecutablePath(
            "/Applications/MiniMax.app/Contents/MacOS/helper",
            source: "minimax"
        ))
    }

    // MARK: - ConfigInstaller — CLIConfig + hook events

    func testMinimaxDefaultEventsMatchMcodeRegistry() {
        // The full event registry compiled into mcode (verified against the
        // shipped CLI): no Notification, but PermissionRequest + PostCompact.
        let names = ConfigInstaller.defaultEvents(for: .minimaxPlugin).map { $0.0 }
        XCTAssertEqual(names, [
            "SessionStart",
            "UserPromptSubmit",
            "PreToolUse",
            "PermissionRequest",
            "PostToolUse",
            "SubagentStart",
            "SubagentStop",
            "Stop",
            "PreCompact",
            "PostCompact",
            "SessionEnd",
        ])
    }

    func testMinimaxHookTimeoutsStayInsideMcodesAcceptedRange() {
        // mcode (0.6.x) rejects a handler whose timeout is not an integer
        // from 1 to 10 seconds — Claude's 86400 s PermissionRequest ceiling
        // would drop the approval hook entirely. PermissionRequest takes the
        // maximum so the island gets the longest window mcode allows.
        let events = ConfigInstaller.defaultEvents(for: .minimaxPlugin)
        for (event, timeout, _) in events {
            XCTAssertTrue((1...10).contains(timeout), "\(event) timeout \(timeout) is outside 1…10")
        }
        XCTAssertEqual(events.first { $0.0 == "PermissionRequest" }?.1, 10)
    }

    func testHookFormatMinimaxPluginRoundTripsThroughStorageValue() {
        // `HookFormat.storageValue` is what we persist for custom CLIs in
        // UserDefaults; missing a case here would silently demote MiniMax
        // custom configs to a different format on load.
        XCTAssertEqual(HookFormat.minimaxPlugin.storageValue, "minimaxPlugin")
        XCTAssertEqual(HookFormat(storageValue: "minimaxPlugin"), .minimaxPlugin)
        XCTAssertEqual(HookFormat(storageValue: "minimaxplugin"), .minimaxPlugin)  // case-insensitive
    }

    func testMinimaxCLIEntryPointsAtThePluginHooksFile() throws {
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })
        XCTAssertEqual(cli.name, "MiniMax Code CLI")
        XCTAssertEqual(cli.format, .minimaxPlugin)
        XCTAssertEqual(cli.configPath, "plugins/codeisland/hooks/hooks.json")
        XCTAssertEqual(cli.configKey, "hooks")
        // fullPath resolves under the (overridable) MiniMax home, not ~/.minimax.
        XCTAssertEqual(cli.fullPath, ConfigInstaller.minimaxHome() + "/plugins/codeisland/hooks/hooks.json")
    }

    // MARK: - Home resolution

    func testMinimaxHomeHonorsEnvOverrides() {
        setenv("MINIMAX_DATA_DIR", "/tmp/minimax-custom", 1)
        XCTAssertEqual(ConfigInstaller.minimaxHome(), "/tmp/minimax-custom")
        unsetenv("MINIMAX_DATA_DIR")

        // MAVIS_DATA_DIR is the documented lower-priority fallback.
        setenv("MAVIS_DATA_DIR", "/tmp/mavis-custom", 1)
        XCTAssertEqual(ConfigInstaller.minimaxHome(), "/tmp/mavis-custom")
        unsetenv("MAVIS_DATA_DIR")

        XCTAssertEqual(ConfigInstaller.minimaxHome(), NSHomeDirectory() + "/.minimax")
    }

    // MARK: - Plugin pack documents

    func testMinimaxHooksDocumentInjectsBridgeForEveryEvent() throws {
        let doc = try XCTUnwrap(ConfigInstaller.minimaxHooksDocument() as? [String: Any])
        let hooks = try XCTUnwrap(doc["hooks"] as? [String: [[String: Any]]])
        let events = ConfigInstaller.defaultEvents(for: .minimaxPlugin)

        // Every event carries our bridge command with the minimax source tag.
        for (event, timeout, _) in events {
            let entries = try XCTUnwrap(hooks[event], "missing \(event)")
            let hookList = try XCTUnwrap(entries.first?["hooks"] as? [[String: Any]])
            let command = try XCTUnwrap(hookList.first?["command"] as? String)
            XCTAssertTrue(command.contains("codeisland-bridge --source minimax"), command)
            // mcode reads timeouts in seconds (clawd-state ships `timeout: 2`).
            XCTAssertEqual(hookList.first?["timeout"] as? Int, timeout, "timeout for \(event)")
            // No matcher: mcode treats an omitted matcher as match-all.
            XCTAssertNil(entries.first?["matcher"])
        }
        XCTAssertEqual(Set(hooks.keys), Set(events.map { $0.0 }))
    }

    func testMinimaxManifestDocumentCarriesUninstallMarker() throws {
        let doc = try XCTUnwrap(ConfigInstaller.minimaxManifestDocument() as? [String: Any])
        XCTAssertEqual(doc["name"] as? String, "codeisland")
        let hookRefs = try XCTUnwrap(doc["hooks"] as? [String])
        XCTAssertEqual(hookRefs, ["hooks/hooks.json"])
    }

    // MARK: - Install / uninstall round trip (hermetic, via $MINIMAX_DATA_DIR)

    func testMinimaxPluginInstallRoundTrip() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "minimax-tests-\(UUID().uuidString)"
        setenv("MINIMAX_DATA_DIR", home, 1)
        defer {
            unsetenv("MINIMAX_DATA_DIR")
            try? fm.removeItem(atPath: home)
        }
        try fm.createDirectory(atPath: home, withIntermediateDirectories: true)

        // No mcode present (empty home dir is the data root itself, so it counts
        // as present — use a subdir-less home marker: presence IS the root).
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertTrue(ConfigInstaller.isInstalled(source: "minimax"))

        let manifestPath = home + "/plugins/codeisland/.claude-plugin/plugin.json"
        let hooksPath = home + "/plugins/codeisland/hooks/hooks.json"
        XCTAssertTrue(fm.fileExists(atPath: manifestPath))
        let manifest = try String(contentsOfFile: manifestPath, encoding: .utf8)
        XCTAssertTrue(manifest.contains("CodeIsland"), "manifest must carry the uninstall marker")

        // The generated hooks.json must parse back as installed (generic
        // detection reads it through the CLIConfig's rootOverride).
        let hooksData = try Data(contentsOf: URL(fileURLWithPath: hooksPath))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
        XCTAssertNotNil(parsed["hooks"])

        // Uninstall removes the whole pack (the manifest is ours)…
        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)
        XCTAssertFalse(fm.fileExists(atPath: home + "/plugins/codeisland"))
        XCTAssertFalse(ConfigInstaller.isInstalled(source: "minimax"))
    }

    func testMinimaxInstallerSkipsMachinesWithoutMiniMax() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "minimax-absent-\(UUID().uuidString)"
        setenv("MINIMAX_DATA_DIR", home, 1)
        defer {
            unsetenv("MINIMAX_DATA_DIR")
            try? fm.removeItem(atPath: home)
        }
        // Do NOT create the root — mcode has never run on this machine.

        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })
        // Skip is reported as success (same rule as Kimi/Copilot), but nothing
        // may be written and cliExists must stay false.
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertFalse(fm.fileExists(atPath: home))
        XCTAssertFalse(ConfigInstaller.cliExists(source: "minimax"))
    }

    func testMinimaxUninstallPreservesForeignPluginPack() throws {
        let fm = FileManager.default
        let home = NSTemporaryDirectory() + "minimax-foreign-\(UUID().uuidString)"
        setenv("MINIMAX_DATA_DIR", home, 1)
        defer {
            unsetenv("MINIMAX_DATA_DIR")
            try? fm.removeItem(atPath: home)
        }
        let pluginDir = home + "/plugins/codeisland"
        try fm.createDirectory(atPath: pluginDir + "/.claude-plugin", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: pluginDir + "/hooks", withIntermediateDirectories: true)
        // A foreign plugin that happens to squat the directory name.
        let foreignManifest = "{\"name\":\"codeisland\",\"description\":\"not ours\"}"
        try foreignManifest.write(toFile: pluginDir + "/.claude-plugin/plugin.json", atomically: true, encoding: .utf8)
        let hooksPath = pluginDir + "/hooks/hooks.json"
        try "{\"hooks\":{}}".write(toFile: hooksPath, atomically: true, encoding: .utf8)

        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })
        ConfigInstaller.uninstallHooks(cli: cli, fm: fm)

        // No marker → the pack survives; only our (zero) entries would have
        // been scrubbed from hooks.json.
        XCTAssertTrue(fm.fileExists(atPath: pluginDir))
        XCTAssertTrue(fm.fileExists(atPath: hooksPath))
    }

    func testMinimaxInstallRefusesToOverwriteForeignPluginPack() throws {
        let fm = FileManager.default
        let home = try makeMinimaxHome("minimax-foreign-install")
        let pluginDir = home + "/plugins/codeisland"
        try fm.createDirectory(atPath: pluginDir + "/.claude-plugin", withIntermediateDirectories: true)
        let manifestPath = pluginDir + "/.claude-plugin/plugin.json"
        let foreignManifest = "{\"name\":\"codeisland\",\"description\":\"not ours\"}"
        try foreignManifest.write(toFile: manifestPath, atomically: true, encoding: .utf8)

        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })
        XCTAssertFalse(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertEqual(try String(contentsOfFile: manifestPath, encoding: .utf8), foreignManifest)
        XCTAssertFalse(fm.fileExists(atPath: pluginDir + "/hooks/hooks.json"))
        XCTAssertFalse(ConfigInstaller.isInstalled(source: "minimax"))
    }

    func testMinimaxDriftedPackReadsAsNotInstalledAndReinstallRestoresIt() throws {
        let fm = FileManager.default
        let home = try makeMinimaxHome("minimax-drift")
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertTrue(ConfigInstaller.isInstalled(source: "minimax"))

        // A pack written by an earlier build: every event is still ours, but
        // PermissionRequest carries a timeout mcode rejects. All-events-present
        // detection would call that installed and never repair it.
        let hooksPath = home + "/plugins/codeisland/hooks/hooks.json"
        let current = try String(contentsOfFile: hooksPath, encoding: .utf8)
        let stale = current.replacingOccurrences(of: "\"timeout\" : 10", with: "\"timeout\" : 86400")
        XCTAssertNotEqual(stale, current)
        try stale.write(toFile: hooksPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(ConfigInstaller.isInstalled(source: "minimax"))

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        XCTAssertTrue(ConfigInstaller.isInstalled(source: "minimax"))

        // A missing manifest is drift too: mcode can't load the pack without it.
        try fm.removeItem(atPath: home + "/plugins/codeisland/.claude-plugin/plugin.json")
        XCTAssertFalse(ConfigInstaller.isInstalled(source: "minimax"))
    }

    func testMinimaxReinstallLeavesCurrentPackUntouched() throws {
        let fm = FileManager.default
        let home = try makeMinimaxHome("minimax-idempotent")
        let cli = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "minimax" })
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))

        // Launch-time install runs every time; a current pack is not rewritten.
        let hooksPath = home + "/plugins/codeisland/hooks/hooks.json"
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: hooksPath)
        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: cli, fm: fm))
        let modified = try fm.attributesOfItem(atPath: hooksPath)[.modificationDate] as? Date
        XCTAssertEqual(modified, past)
    }

    /// A MiniMax data root under the temp dir, wired through
    /// `$MINIMAX_DATA_DIR` and removed when the test ends.
    private func makeMinimaxHome(_ prefix: String) throws -> String {
        let home = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        setenv("MINIMAX_DATA_DIR", home, 1)
        addTeardownBlock {
            unsetenv("MINIMAX_DATA_DIR")
            try? FileManager.default.removeItem(atPath: home)
        }
        return home
    }
}
