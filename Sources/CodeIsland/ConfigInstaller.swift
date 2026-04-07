import Foundation

// MARK: - CLI Definitions

/// Hook entry format variants
enum HookFormat {
    /// Claude Code style: [{matcher, hooks: [{type, command, timeout, async}]}]
    case claude
    /// Codex/Gemini style: [{hooks: [{type, command, timeout}]}]  (no matcher)
    case nested
    /// Cursor style: [{command: "..."}]
    case flat
}

/// A CLI tool that supports hooks
struct CLIConfig {
    let name: String           // display name
    let source: String         // --source flag value
    let configPath: String     // path to config file (relative to home)
    let configKey: String      // top-level JSON key containing hooks ("hooks" for most)
    let format: HookFormat
    let events: [(String, Int, Bool)]  // (eventName, timeout, async)

    var fullPath: String { NSHomeDirectory() + "/\(configPath)" }
    var dirPath: String { (fullPath as NSString).deletingLastPathComponent }
}

struct ConfigInstaller {
    private static let bridgePath = NSHomeDirectory() + "/.claude/hooks/codeisland-bridge"
    private static let hookScriptPath = NSHomeDirectory() + "/.claude/hooks/codeisland-hook.sh"
    private static let hookCommand = "~/.claude/hooks/codeisland-hook.sh"
    private static let bridgeCommand = "~/.claude/hooks/codeisland-bridge"

    // MARK: - All supported CLIs

    static let allCLIs: [CLIConfig] = [
        // Claude Code — uses hook script (with bridge dispatcher + nc fallback)
        CLIConfig(
            name: "Claude Code", source: "claude",
            configPath: ".claude/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("PermissionRequest", 86400, false),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ]
        ),
        // Codex
        CLIConfig(
            name: "Codex", source: "codex",
            configPath: ".codex/hooks.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 5, false),
                ("UserPromptSubmit", 5, false),
                ("Stop", 5, false),
            ]
        ),
        // Gemini CLI — timeout in milliseconds
        CLIConfig(
            name: "Gemini", source: "gemini",
            configPath: ".gemini/settings.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 5000, false),
                ("SessionEnd", 5000, false),
                ("BeforeTool", 5000, false),
                ("AfterTool", 5000, false),
                ("BeforeAgent", 5000, false),
                ("AfterAgent", 5000, false),
            ]
        ),
        // Cursor
        CLIConfig(
            name: "Cursor", source: "cursor",
            configPath: ".cursor/hooks.json", configKey: "hooks",
            format: .flat,
            events: [
                ("beforeSubmitPrompt", 5, false),
                ("beforeShellExecution", 5, false),
                ("afterShellExecution", 5, false),
                ("beforeReadFile", 5, false),
                ("afterFileEdit", 5, false),
                ("beforeMCPExecution", 5, false),
                ("afterMCPExecution", 5, false),
                ("afterAgentThought", 5, false),
                ("afterAgentResponse", 5, false),
                ("stop", 5, false),
            ]
        ),
        // Qoder — Claude Code fork
        CLIConfig(
            name: "Qoder", source: "qoder",
            configPath: ".qoder/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ]
        ),
        // Factory — Claude Code fork (uses "droid" as source identifier)
        CLIConfig(
            name: "Factory", source: "droid",
            configPath: ".factory/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ]
        ),
        // CodeBuddy — Claude Code fork
        CLIConfig(
            name: "CodeBuddy", source: "codebuddy",
            configPath: ".codebuddy/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ]
        ),
    ]

    /// Non-Claude CLIs (installed via bridge binary directly)
    private static var externalCLIs: [CLIConfig] {
        allCLIs.filter { $0.source != "claude" }
    }

    /// Hook script version — bump this when the script template changes
    private static let hookScriptVersion = 2

    /// Hook script for Claude Code (dispatcher: bridge binary → nc fallback)
    private static let hookScript = """
        #!/bin/bash
        # CodeIsland hook v\(hookScriptVersion) — native bridge with shell fallback
        BRIDGE="$HOME/.claude/hooks/codeisland-bridge"
        [ -x "$BRIDGE" ] && exec "$BRIDGE"
        # Fallback: original shell approach (no binary installed yet)
        SOCK="/tmp/codeisland-$(id -u).sock"
        [ -S "$SOCK" ] || exit 0
        INPUT=$(cat)
        _ITERM_GUID="${ITERM_SESSION_ID##*:}"
        TERM_INFO="\\"_term_app\\":\\"${TERM_PROGRAM:-}\\",\\"_iterm_session\\":\\"${_ITERM_GUID:-}\\",\\"_tty\\":\\"$(tty 2>/dev/null || true)\\",\\"_ppid\\":$PPID"
        PATCHED="${INPUT%\\}},${TERM_INFO}}"
        if echo "$INPUT" | grep -q '"PermissionRequest"'; then
          echo "$PATCHED" | nc -U -w 120 "$SOCK" 2>/dev/null || true
        else
          echo "$PATCHED" | nc -U -w 2 "$SOCK" 2>/dev/null || true
        fi
        """

    // MARK: - OpenCode plugin paths

    private static let opencodePluginDir = NSHomeDirectory() + "/.config/opencode/plugins"
    private static let opencodePluginPath = NSHomeDirectory() + "/.config/opencode/plugins/codeisland.js"
    private static let opencodeConfigPath = NSHomeDirectory() + "/.config/opencode/config.json"

    // MARK: - Install / Uninstall

    static func install() -> Bool {
        let fm = FileManager.default

        // Ensure hooks directory
        let hookDir = (hookScriptPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: hookDir, withIntermediateDirectories: true)

        // Install hook script + bridge binary (shared by all CLIs)
        installHookScript(fm: fm)
        installBridgeBinary(fm: fm)

        // Install hooks for each enabled CLI
        var ok = true
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            if cli.source == "claude" {
                if !installClaudeHooks(cli: cli, fm: fm) { ok = false }
            } else {
                if !installExternalHooks(cli: cli, fm: fm) { ok = false }
            }
        }

        // Install OpenCode plugin
        if isEnabled(source: "opencode") {
            if !installOpencodePlugin(fm: fm) { ok = false }
        }

        return ok
    }

    static func uninstall() {
        let fm = FileManager.default
        try? fm.removeItem(atPath: hookScriptPath)
        try? fm.removeItem(atPath: bridgePath)

        for cli in allCLIs {
            uninstallHooks(cli: cli, fm: fm)
        }

        uninstallOpencodePlugin(fm: fm)
    }

    /// Check if Claude Code hooks are installed
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hookScriptPath) else { return false }
        return isHooksInstalled(for: allCLIs[0], fm: fm)
    }

    /// Check if a specific CLI's hooks are installed
    static func isInstalled(source: String) -> Bool {
        if source == "opencode" { return isOpencodePluginInstalled(fm: FileManager.default) }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return isHooksInstalled(for: cli, fm: FileManager.default)
    }

    /// Check if CLI directory exists (tool is installed on this machine)
    static func cliExists(source: String) -> Bool {
        if source == "opencode" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/opencode") }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return FileManager.default.fileExists(atPath: cli.dirPath)
    }

    // Keep backward compat
    static func isCodexInstalled() -> Bool { isInstalled(source: "codex") }

    /// Whether a CLI is enabled by user (UserDefaults). Default: true.
    static func isEnabled(source: String) -> Bool {
        let key = "cli_enabled_\(source)"
        if UserDefaults.standard.object(forKey: key) == nil { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// Toggle a single CLI on/off: installs or uninstalls its hooks.
    @discardableResult
    static func setEnabled(source: String, enabled: Bool) -> Bool {
        UserDefaults.standard.set(enabled, forKey: "cli_enabled_\(source)")
        let fm = FileManager.default
        if enabled {
            installHookScript(fm: fm)
            installBridgeBinary(fm: fm)
            if source == "opencode" {
                return installOpencodePlugin(fm: fm)
            }
            guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
            if cli.source == "claude" {
                return installClaudeHooks(cli: cli, fm: fm)
            } else {
                installExternalHooks(cli: cli, fm: fm)
                return isHooksInstalled(for: cli, fm: fm)
            }
        } else {
            if source == "opencode" {
                uninstallOpencodePlugin(fm: fm)
            } else if let cli = allCLIs.first(where: { $0.source == source }) {
                uninstallHooks(cli: cli, fm: fm)
            }
            return true
        }
    }

    /// Check all installed CLIs and repair missing hooks. Returns names of repaired CLIs.
    static func verifyAndRepair() -> [String] {
        let fm = FileManager.default
        // Ensure bridge binary and hook script are current
        installBridgeBinary(fm: fm)
        installHookScript(fm: fm)

        var repaired: [String] = []
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            guard fm.fileExists(atPath: cli.dirPath) else { continue }
            if isHooksInstalled(for: cli, fm: fm) { continue }
            if cli.source == "claude" {
                if installClaudeHooks(cli: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            } else {
                installExternalHooks(cli: cli, fm: fm)
                if isHooksInstalled(for: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            }
        }
        // OpenCode plugin
        if isEnabled(source: "opencode"),
           fm.fileExists(atPath: (opencodeConfigPath as NSString).deletingLastPathComponent),
           !isOpencodePluginInstalled(fm: fm) {
            if installOpencodePlugin(fm: fm) { repaired.append("OpenCode") }
        }
        return repaired
    }

    // MARK: - JSONC Support

    /// Strip // and /* */ comments from JSONC, preserving strings
    static func stripJSONComments(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var i = input.startIndex
        let end = input.endIndex

        while i < end {
            let c = input[i]
            if c == "\"" {
                result.append(c)
                i = input.index(after: i)
                while i < end {
                    let sc = input[i]
                    result.append(sc)
                    if sc == "\\" {
                        i = input.index(after: i)
                        if i < end { result.append(input[i]) }
                    } else if sc == "\"" {
                        break
                    }
                    i = input.index(after: i)
                }
                if i < end { i = input.index(after: i) }
                continue
            }
            let next = input.index(after: i)
            if c == "/" && next < end {
                let nc = input[next]
                if nc == "/" {
                    i = input.index(after: next)
                    while i < end && input[i] != "\n" { i = input.index(after: i) }
                    continue
                } else if nc == "*" {
                    i = input.index(after: next)
                    while i < end {
                        let bi = input.index(after: i)
                        if input[i] == "*" && bi < end && input[bi] == "/" {
                            i = input.index(after: bi)
                            break
                        }
                        i = input.index(after: i)
                    }
                    continue
                }
            }
            result.append(c)
            i = input.index(after: i)
        }
        return result
    }

    /// Parse a JSON file, stripping JSONC comments first
    private static func parseJSONFile(at path: String, fm: FileManager) -> [String: Any]? {
        guard fm.fileExists(atPath: path),
              let data = fm.contents(atPath: path),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let stripped = stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return nil }
        return json
    }

    // MARK: - Claude Code (special: uses hook script)

    private static func installClaudeHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        let dir = cli.dirPath
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        var settings: [String: Any] = [:]
        if let json = parseJSONFile(at: cli.fullPath, fm: fm) {
            settings = json
        }

        var hooks = settings[cli.configKey] as? [String: Any] ?? [:]

        let alreadyInstalled = cli.events.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String) == hookCommand }
            }
        }
        if alreadyInstalled && !hasStaleAsyncKey(hooks) { return true }

        for (event, timeout, isAsync) in cli.events {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            eventHooks.removeAll { containsOurHook($0) }

            let hookEntry: [String: Any] = [
                "type": "command", "command": hookCommand, "timeout": timeout,
            ]
            eventHooks.append(["matcher": "", "hooks": [hookEntry]])
            hooks[event] = eventHooks
        }
        settings[cli.configKey] = hooks

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return fm.createFile(atPath: cli.fullPath, contents: data)
    }

    // MARK: - External CLIs (use bridge binary directly)

    @discardableResult
    private static func installExternalHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: cli.dirPath) else { return true } // CLI not installed, skip OK

        var root: [String: Any] = [:]
        if let json = parseJSONFile(at: cli.fullPath, fm: fm) {
            root = json
        }

        var hooks = root[cli.configKey] as? [String: Any] ?? [:]
        let command = "\(bridgeCommand) --source \(cli.source)"

        for (event, timeout, _) in cli.events {
            var eventEntries = hooks[event] as? [[String: Any]] ?? []
            // Remove old hooks before adding fresh ones (ensures reinstall works)
            eventEntries.removeAll { containsOurHook($0) }

            let entry: [String: Any]
            switch cli.format {
            case .claude:
                entry = ["matcher": "*", "hooks": [["type": "command", "command": command] as [String: Any]]]
            case .nested:
                entry = ["hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]]]
            case .flat:
                entry = ["command": command]
            }
            eventEntries.append(entry)
            hooks[event] = eventEntries
        }

        root[cli.configKey] = hooks
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return fm.createFile(atPath: cli.fullPath, contents: data)
    }

    // MARK: - Uninstall (generic)

    private static func uninstallHooks(cli: CLIConfig, fm: FileManager) {
        guard var root = parseJSONFile(at: cli.fullPath, fm: fm),
              var hooks = root[cli.configKey] as? [String: Any] else { return }

        for (event, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { containsOurHook($0) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        root[cli.configKey] = hooks.isEmpty ? nil : hooks
        if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: cli.fullPath, contents: data)
        }
    }

    // MARK: - Detection helpers

    private static func isHooksInstalled(for cli: CLIConfig, fm: FileManager) -> Bool {
        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              let hooks = root[cli.configKey] as? [String: Any] else { return false }
        // Check that ALL required events have our hook installed, not just any one
        let allPresent = cli.events.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { containsOurHook($0) }
        }
        guard allPresent else { return false }
        // Also check for stale "async" keys that need cleanup
        if hasStaleAsyncKey(hooks) { return false }
        return true
    }

    /// Detect legacy hook entries with invalid "async" key
    private static func hasStaleAsyncKey(_ hooks: [String: Any]) -> Bool {
        for (_, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries where containsOurHook(entry) {
                if let hookList = entry["hooks"] as? [[String: Any]] {
                    if hookList.contains(where: { $0["async"] != nil }) { return true }
                }
            }
        }
        return false
    }

    /// Check if a hook entry contains our hook command
    private static func containsOurHook(_ entry: [String: Any]) -> Bool {
        // Claude/nested format: entry.hooks[].command
        if let hookList = entry["hooks"] as? [[String: Any]] {
            return hookList.contains {
                let cmd = $0["command"] as? String ?? ""
                return cmd.contains("codeisland") || cmd.contains("vibenotch")
            }
        }
        // Flat format: entry.command
        if let cmd = entry["command"] as? String,
           (cmd.contains("codeisland") || cmd.contains("vibenotch")) { return true }
        return false
    }

    // MARK: - Bridge & Hook Script

    private static func installHookScript(fm: FileManager) {
        let needsUpdate: Bool
        if fm.fileExists(atPath: hookScriptPath) {
            if let existing = fm.contents(atPath: hookScriptPath),
               let str = String(data: existing, encoding: .utf8) {
                // Update if script doesn't contain bridge dispatcher OR version is outdated
                let hasCurrentVersion = str.contains("# CodeIsland hook v\(hookScriptVersion)")
                needsUpdate = !hasCurrentVersion
            } else {
                needsUpdate = true
            }
        } else {
            needsUpdate = true
        }
        if needsUpdate {
            fm.createFile(atPath: hookScriptPath, contents: Data(hookScript.utf8))
            chmod(hookScriptPath, 0o755)
        }
    }

    private static func installBridgeBinary(fm: FileManager) {
        guard let execPath = Bundle.main.executablePath else { return }
        let execDir = (execPath as NSString).deletingLastPathComponent
        let contentsDir = (execDir as NSString).deletingLastPathComponent
        var srcPath = contentsDir + "/Helpers/codeisland-bridge"
        if !fm.fileExists(atPath: srcPath) { srcPath = execDir + "/codeisland-bridge" }
        guard fm.fileExists(atPath: srcPath) else { return }

        // Atomic replace: copy to temp file first, then rename (overwrites atomically)
        let tmpPath = bridgePath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try? fm.removeItem(atPath: tmpPath)
            try fm.copyItem(atPath: srcPath, toPath: tmpPath)
            chmod(tmpPath, 0o755)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: bridgePath), withItemAt: URL(fileURLWithPath: tmpPath))
        } catch {
            // replaceItemAt fails if destination doesn't exist yet — fall back to rename
            try? fm.moveItem(atPath: tmpPath, toPath: bridgePath)
            chmod(bridgePath, 0o755)
        }
    }

    // MARK: - OpenCode Plugin

    /// The JS plugin source — embedded as resource or bundled alongside
    private static func opencodePluginSource() -> String? {
        // Try SPM resource bundle (where build actually places it)
        if let url = Bundle.module.url(forResource: "codeisland-opencode", withExtension: "js", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) { return src }
        // Fallback: try without subdirectory
        if let url = Bundle.module.url(forResource: "codeisland-opencode", withExtension: "js"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    @discardableResult
    private static func installOpencodePlugin(fm: FileManager) -> Bool {
        // Only install if opencode config dir exists
        let configDir = (opencodeConfigPath as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: configDir) else { return true } // not installed, skip silently

        // Clean up old vibe-island plugin
        let oldPlugin = opencodePluginDir + "/vibe-island.js"
        if fm.fileExists(atPath: oldPlugin) { try? fm.removeItem(atPath: oldPlugin) }

        // Write plugin JS
        guard let source = opencodePluginSource() else { return false }
        try? fm.createDirectory(atPath: opencodePluginDir, withIntermediateDirectories: true)
        guard fm.createFile(atPath: opencodePluginPath, contents: Data(source.utf8)) else { return false }

        // Register in opencode config.json
        let pluginRef = "file://\(opencodePluginPath)"
        var config: [String: Any] = [:]
        if let data = fm.contents(atPath: opencodeConfigPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        }
        var plugins = config["plugin"] as? [String] ?? []
        // Remove old vibe-island entries and any stale codeisland entries
        plugins.removeAll { $0.contains("vibe-island") || $0.contains("codeisland") }
        plugins.append(pluginRef)
        config["plugin"] = plugins
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: opencodeConfigPath, contents: data)
        }
        return true
    }

    private static func uninstallOpencodePlugin(fm: FileManager) {
        try? fm.removeItem(atPath: opencodePluginPath)
        // Remove from config
        guard let data = fm.contents(atPath: opencodeConfigPath),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var plugins = config["plugin"] as? [String] else { return }
        plugins.removeAll { $0.contains("codeisland") }
        config["plugin"] = plugins.isEmpty ? nil : plugins
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: opencodeConfigPath, contents: data)
        }
    }

    /// Current OpenCode plugin version — bump when codeisland-opencode.js changes
    private static let opencodePluginVersion = "v2"

    private static func isOpencodePluginInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: opencodePluginPath),
              let data = fm.contents(atPath: opencodeConfigPath),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = config["plugin"] as? [String] else { return false }
        guard plugins.contains(where: { $0.contains("codeisland") }) else { return false }
        // Check version: if installed plugin is outdated, report as not installed to trigger update
        if let existing = fm.contents(atPath: opencodePluginPath),
           let str = String(data: existing, encoding: .utf8) {
            return str.contains("// version: \(opencodePluginVersion)")
        }
        return false
    }
}
