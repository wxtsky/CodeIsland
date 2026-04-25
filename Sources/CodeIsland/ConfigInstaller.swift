import Foundation
import CodeIslandCore

// MARK: - Hook Identifiers

private enum HookId {
    static let current = "codeisland"
    static let legacyNames = ["vibenotch", "vibe-island", "vibeisland"]
    static func isOurs(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.contains(current) || legacyNames.contains(where: lower.contains)
    }
}

// MARK: - CLI Definitions

/// Hook entry format variants
enum HookFormat {
    /// Claude Code style: [{matcher, hooks: [{type, command, timeout, async}]}]
    case claude
    /// Codex/Gemini style: [{hooks: [{type, command, timeout}]}]  (no matcher)
    case nested
    /// Cursor style: [{command: "..."}]
    case flat
    /// TraeCli style: YAML managed block in ~/.trae/traecli.yaml
    case traecli
    /// GitHub Copilot CLI style: [{type, bash, timeoutSec}] with top-level version
    case copilot
    /// Kimi Code CLI style: TOML [[hooks]] arrays in ~/.kimi/config.toml
    case kimi

    var storageValue: String {
        switch self {
        case .claude: return "claude"
        case .nested: return "nested"
        case .flat: return "flat"
        case .traecli: return "traecli"
        case .copilot: return "copilot"
        case .kimi: return "kimi"
        }
    }

    init?(storageValue: String) {
        switch storageValue.lowercased() {
        case "claude": self = .claude
        case "nested": self = .nested
        case "flat": self = .flat
        case "traecli": self = .traecli
        case "copilot": self = .copilot
        case "kimi": self = .kimi
        default: return nil
        }
    }
}

/// A CLI tool that supports hooks
struct CLIConfig {
    let name: String           // display name
    let source: String         // --source flag value
    let configPath: String     // path to config file (relative to home, or to rootOverride if set)
    let configKey: String      // top-level JSON key containing hooks ("hooks" for most)
    let format: HookFormat
    let events: [(String, Int, Bool)]  // (eventName, timeout, async)
    /// Events that require a minimum CLI version (eventName → minVersion like "2.1.89")
    var versionedEvents: [String: String] = [:]
    /// Optional root directory override. When set, `configPath` is resolved relative to this
    /// directory instead of the user's home (used by Codex to honor $CODEX_HOME).
    var rootOverride: (@Sendable () -> String)? = nil
    /// Optional override for the user-visible config path (e.g. "$CODEX_HOME/hooks.json").
    var displayPathOverride: (@Sendable () -> String)? = nil

    var fullPath: String {
        if let override = rootOverride {
            return override() + "/" + configPath
        }
        if configPath.hasPrefix("/") { return configPath }
        if configPath.hasPrefix("~/") {
            return NSHomeDirectory() + "/" + configPath.dropFirst(2)
        }
        return NSHomeDirectory() + "/\(configPath)"
    }
    var dirPath: String { (fullPath as NSString).deletingLastPathComponent }
    var displayConfigPath: String {
        if let override = displayPathOverride { return override() }
        if configPath.hasPrefix("/") || configPath.hasPrefix("~/") { return configPath }
        return "~/\(configPath)"
    }
}

struct CustomCLIConfig: Codable, Identifiable, Equatable {
    var id: String { source }
    let name: String
    let source: String
    let configPath: String
    let format: String
    let configKey: String
}

struct ConfigInstaller {
    private static let codeislandDir = NSHomeDirectory() + "/.codeisland"
    private static let bridgePath = codeislandDir + "/codeisland-bridge"
    private static let hookScriptPath = codeislandDir + "/codeisland-hook.sh"
    private static let hookCommand = "~/.codeisland/codeisland-hook.sh"
    private static let customCLIConfigsKey = SessionSnapshot.customCLIConfigsKey
    /// Absolute path for external CLI hooks — avoids tilde expansion issues in IDE environments
    private static let bridgeCommand = codeislandDir + "/codeisland-bridge"
    private static let traecliConfigPath = NSHomeDirectory() + "/.trae/traecli.yaml"

    // Legacy paths for migration cleanup (#32)
    private static let legacyBridgePath = NSHomeDirectory() + "/.claude/hooks/codeisland-bridge"
    private static let legacyHookScriptPath = NSHomeDirectory() + "/.claude/hooks/codeisland-hook.sh"

    // MARK: - Codex home resolution

    /// Resolve Codex's config directory. Honors $CODEX_HOME (with a leading `~` expanded);
    /// falls back to `~/.codex`. Whitespace-only or empty values are treated as unset.
    static func codexHome() -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() + "/.codex" }
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
        return raw
    }

    /// User-visible form of a Codex config path (uses `$CODEX_HOME/...` when the env var
    /// is set, otherwise `~/.codex/...`).
    static func displayCodexPath(filename: String) -> String {
        let raw = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "~/.codex/\(filename)" : "$CODEX_HOME/\(filename)"
    }

    // MARK: - All supported CLIs

    private static let builtInCLIs: [CLIConfig] = [
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
            ],
            versionedEvents: [
                "PostToolUseFailure": "2.1.89",
            ]
        ),
        // Codex — honors $CODEX_HOME (falls back to ~/.codex)
        CLIConfig(
            name: "Codex", source: "codex",
            configPath: "hooks.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
            ],
            rootOverride: { ConfigInstaller.codexHome() },
            displayPathOverride: { ConfigInstaller.displayCodexPath(filename: "hooks.json") }
        ),
        // Gemini CLI — timeout in milliseconds
        CLIConfig(
            name: "Gemini", source: "gemini",
            configPath: ".gemini/settings.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 10000, false),
                ("SessionEnd", 10000, false),
                ("BeforeTool", 10000, false),
                ("AfterTool", 10000, false),
                ("BeforeAgent", 10000, false),
                ("AfterAgent", 10000, false),
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
        // Trae
        CLIConfig(
            name: "Trae", source: "trae",
            configPath: ".trae/hooks.json", configKey: "hooks",
            format: .flat,
            events: defaultEvents(for: .flat)
        ),
        // Trae CN
        CLIConfig(
            name: "Trae CN", source: "traecn",
            configPath: ".trae-cn/hooks.json", configKey: "hooks",
            format: .flat,
            events: defaultEvents(for: .flat)
        ),
        // TraeCli
        CLIConfig(
            name: "TraeCli", source: "traecli",
            configPath: ".trae/traecli.yaml", configKey: "hooks",
            format: .traecli,
            events: defaultEvents(for: .traecli)
        ),
        // Qoder — Claude Code fork
        CLIConfig(
            name: "Qoder", source: "qoder",
            configPath: ".qoder/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Factory — Claude Code fork (uses "droid" as source identifier)
        CLIConfig(
            name: "Factory", source: "droid",
            configPath: ".factory/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // CodeBuddy — Claude Code fork
        CLIConfig(
            name: "CodeBuddy", source: "codebuddy",
            configPath: ".codebuddy/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // CodyBuddyCN — CodeBuddy CN variant
        CLIConfig(
            name: "CodyBuddyCN", source: "codybuddycn",
            configPath: ".codybuddycn/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // StepFun — Claude Code fork
        CLIConfig(
            name: "StepFun", source: "stepfun",
            configPath: ".stepfun/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // AntiGravity — Claude Code fork
        CLIConfig(
            name: "AntiGravity", source: "antigravity",
            configPath: ".antigravity/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // WorkBuddy — Claude Code fork
        CLIConfig(
            name: "WorkBuddy", source: "workbuddy",
            configPath: ".workbuddy/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Hermes — Claude Code fork
        CLIConfig(
            name: "Hermes", source: "hermes",
            configPath: ".hermes/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Qwen Code — timeout in milliseconds
        CLIConfig(
            name: "Qwen Code", source: "qwen",
            configPath: ".qwen/settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5000, true),
                ("PreToolUse", 5000, false),
                ("PostToolUse", 5000, true),
                ("PostToolUseFailure", 5000, true),
                ("PermissionRequest", 86400000, false),
                ("Stop", 5000, true),
                ("SubagentStart", 5000, true),
                ("SubagentStop", 5000, true),
                ("SessionStart", 5000, false),
                ("SessionEnd", 5000, true),
                ("Notification", 86400000, false),
                ("PreCompact", 5000, true),
            ]
        ),
        // GitHub Copilot CLI
        CLIConfig(
            name: "Copilot", source: "copilot",
            configPath: ".copilot/hooks/codeisland.json", configKey: "hooks",
            format: .copilot,
            events: [
                ("sessionStart", 5, false),
                ("sessionEnd", 5, true),
                ("userPromptSubmitted", 5, false),
                ("preToolUse", 5, false),
                ("postToolUse", 5, true),
                ("errorOccurred", 5, true),
            ]
        ),
        // Kimi Code CLI — TOML hooks in ~/.kimi/config.toml
        CLIConfig(
            name: "Kimi Code CLI", source: "kimi",
            configPath: ".kimi/config.toml", configKey: "hooks",
            format: .kimi,
            events: defaultEvents(for: .kimi)
        ),
    ]

    static var allCLIs: [CLIConfig] {
        builtInCLIs + customCLIs()
    }

    /// Non-Claude CLIs (installed via bridge binary directly)
    private static var externalCLIs: [CLIConfig] {
        allCLIs.filter { $0.source != "claude" }
    }

    static func defaultEvents(for format: HookFormat) -> [(String, Int, Bool)] {
        switch format {
        case .claude:
            return [
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
        case .nested:
            return [
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
            ]
        case .flat:
            return [
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
        case .traecli:
            return [
                ("session_start", 5, false),
                ("session_end", 5, true),
                ("user_prompt_submit", 5, true),
                ("pre_tool_use", 5, false),
                ("post_tool_use", 5, true),
                ("post_tool_use_failure", 5, true),
                ("permission_request", 86400, false),
                ("notification", 86400, false),
                ("subagent_start", 5, true),
                ("subagent_stop", 5, true),
                ("stop", 5, true),
                ("pre_compact", 5, true),
                ("post_compact", 5, true),
            ]
        case .copilot:
            return [
                ("sessionStart", 5, false),
                ("sessionEnd", 5, true),
                ("userPromptSubmitted", 5, false),
                ("preToolUse", 5, false),
                ("postToolUse", 5, true),
                ("errorOccurred", 5, true),
            ]
        case .kimi:
            // Kimi Code CLI limits: max timeout 600, no PermissionRequest event
            return [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("Stop", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Notification", 600, false),
                ("PreCompact", 5, true),
            ]
        }
    }

    static func customCLIConfigs() -> [CustomCLIConfig] {
        guard let data = UserDefaults.standard.data(forKey: customCLIConfigsKey),
              let items = try? JSONDecoder().decode([CustomCLIConfig].self, from: data) else {
            return []
        }
        return items
    }

    private static func saveCustomCLIConfigs(_ items: [CustomCLIConfig]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: customCLIConfigsKey)
    }

    static func customCLIs() -> [CLIConfig] {
        customCLIConfigs().compactMap { item in
            guard let format = HookFormat(storageValue: item.format) else { return nil }
            return CLIConfig(
                name: item.name,
                source: item.source,
                configPath: item.configPath,
                configKey: item.configKey,
                format: format,
                events: defaultEvents(for: format)
            )
        }
    }

    static func addCustomCLI(
        name: String,
        source: String,
        configPath: String,
        format: HookFormat,
        configKey: String = "hooks"
    ) -> (ok: Bool, message: String) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedConfigPath = configPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedConfigKey = configKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedName.isEmpty else { return (false, "Name cannot be empty") }
        guard !normalizedSource.isEmpty else { return (false, "Source cannot be empty") }
        guard normalizedSource.range(of: #"^[a-z0-9_-]+$"#, options: .regularExpression) != nil else {
            return (false, "Source must use [a-z0-9_-]")
        }
        guard !normalizedConfigPath.isEmpty else { return (false, "Config path cannot be empty") }
        guard !normalizedConfigKey.isEmpty else { return (false, "Config key cannot be empty") }

        let builtInSources = Set(builtInCLIs.map(\.source))
        guard !builtInSources.contains(normalizedSource) else {
            return (false, "Source '\(normalizedSource)' is already built-in")
        }

        var items = customCLIConfigs()
        let entry = CustomCLIConfig(
            name: normalizedName,
            source: normalizedSource,
            configPath: normalizedConfigPath,
            format: format.storageValue,
            configKey: normalizedConfigKey
        )
        if let idx = items.firstIndex(where: { $0.source == normalizedSource }) {
            items[idx] = entry
        } else {
            items.append(entry)
        }
        saveCustomCLIConfigs(items)
        return (true, "Custom CLI saved")
    }

    @discardableResult
    static func removeCustomCLI(source: String) -> Bool {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = customCLIConfigs()
        let originalCount = items.count
        items.removeAll { $0.source == normalizedSource }
        guard items.count != originalCount else { return false }
        saveCustomCLIConfigs(items)
        return true
    }

    /// Hook script version — bump this when the script template changes
    private static let hookScriptVersion = 5

    /// Hook script for Claude Code (dispatcher: bridge binary → nc fallback)
    private static let hookScript = """
        #!/bin/bash
        # CodeIsland hook v\(hookScriptVersion) — native bridge with shell fallback
        BRIDGE="$HOME/.codeisland/codeisland-bridge"
        if [ -x "$BRIDGE" ]; then
          exec "$BRIDGE" "$@"
        fi
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
    private static let opencodeConfigPathNew = NSHomeDirectory() + "/.config/opencode/opencode.json"

    // MARK: - Install / Uninstall

    static func install() -> Bool {
        let fm = FileManager.default

        // Ensure ~/.codeisland directory
        try? fm.createDirectory(atPath: codeislandDir, withIntermediateDirectories: true)

        // Clean up legacy paths at ~/.claude/hooks/ (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        // Install hook script + bridge binary (shared by all CLIs)
        installHookScript(fm: fm)
        installBridgeBinary(fm: fm)

        // Install hooks for each enabled CLI
        var ok = true
        for cli in allCLIs {
            guard isEnabled(source: cli.source) else { continue }
            if cli.source == "claude" {
                if !installClaudeHooks(cli: cli, fm: fm) { ok = false }
            } else if cli.source == "traecli" {
                if !installTraecliHooks(fm: fm) { ok = false }
            } else {
                if !installExternalHooks(cli: cli, fm: fm) { ok = false }
            }
        }

        // Codex requires codex_hooks = true in config.toml
        if isEnabled(source: "codex"),
           fm.fileExists(atPath: codexHome()) {
            enableCodexHooksConfig(fm: fm)
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
        // Also clean up legacy paths (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        for cli in allCLIs {
            if cli.source == "traecli" {
                uninstallTraecliHooks(fm: fm)
            } else {
                uninstallHooks(cli: cli, fm: fm)
            }
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
        if source == "traecli" { return isTraecliHooksInstalled(fm: FileManager.default) }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return isHooksInstalled(for: cli, fm: FileManager.default)
    }

    /// Check if CLI directory exists (tool is installed on this machine)
    static func cliExists(source: String) -> Bool {
        if source == "opencode" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/opencode") }
        if source == "copilot" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.copilot") }
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
            } else if cli.source == "traecli" {
                return installTraecliHooks(fm: fm)
            } else {
                installExternalHooks(cli: cli, fm: fm)
                if cli.source == "codex" { enableCodexHooksConfig(fm: fm) }
                return isHooksInstalled(for: cli, fm: fm)
            }
        } else {
            if source == "opencode" {
                uninstallOpencodePlugin(fm: fm)
            } else if let cli = allCLIs.first(where: { $0.source == source }) {
                if cli.source == "traecli" {
                    uninstallTraecliHooks(fm: fm)
                } else {
                    uninstallHooks(cli: cli, fm: fm)
                }
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
            let dirExists = cli.format == .copilot
                ? fm.fileExists(atPath: NSHomeDirectory() + "/.copilot")
                : fm.fileExists(atPath: cli.dirPath)
            guard dirExists else { continue }
            if cli.source == "traecli" {
                if isTraecliHooksInstalled(fm: fm) { continue }
                if installTraecliHooks(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if isHooksInstalled(for: cli, fm: fm) { continue }
            if cli.source == "claude" {
                if installClaudeHooks(cli: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            } else {
                installExternalHooks(cli: cli, fm: fm)
                if cli.source == "codex" { enableCodexHooksConfig(fm: fm) }
                if isHooksInstalled(for: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            }
        }
        // Codex config.toml: ensure codex_hooks = true
        if isEnabled(source: "codex"),
           fm.fileExists(atPath: codexHome()) {
            enableCodexHooksConfig(fm: fm)
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

    // MARK: - CLI Version Detection

    /// Detect installed Claude Code version by running `claude --version`
    private static var cachedClaudeVersion: String?
    private static func detectClaudeVersion() -> String? {
        if let cached = cachedClaudeVersion { return cached }
        // Find claude binary — GUI apps don't inherit user's shell PATH
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                // Parse "2.1.92 (Claude Code)" → "2.1.92"
                let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: " ").first ?? ""
                if !version.isEmpty { cachedClaudeVersion = version }
                return cachedClaudeVersion
            }
        } catch {}
        return nil
    }

    /// Compare semver strings: returns true if `installed` >= `required`
    static func versionAtLeast(_ installed: String, _ required: String) -> Bool {
        let i = installed.split(separator: ".").compactMap { Int($0) }
        let r = required.split(separator: ".").compactMap { Int($0) }
        for idx in 0..<max(i.count, r.count) {
            let iv = idx < i.count ? i[idx] : 0
            let rv = idx < r.count ? r[idx] : 0
            if iv > rv { return true }
            if iv < rv { return false }
        }
        return true // equal
    }

    /// Filter events based on installed CLI version
    private static func compatibleEvents(for cli: CLIConfig) -> [(String, Int, Bool)] {
        guard !cli.versionedEvents.isEmpty else { return cli.events }

        // Only Claude Code needs version checking for now
        guard cli.source == "claude" else { return cli.events }
        let version = detectClaudeVersion()

        return cli.events.filter { (event, _, _) in
            guard let minVer = cli.versionedEvents[event] else { return true }
            guard let version else { return false } // can't detect version → skip risky events
            return versionAtLeast(version, minVer)
        }
    }

    // MARK: - Claude Code (special: uses hook script)

    private static func installClaudeHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        let dir = cli.dirPath
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // Read raw text (preserved verbatim for minimal-diff write-back).
        let originalText: String? = fm.contents(atPath: cli.fullPath).flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (#89 — protect user data).
        if let text = originalText, !text.isEmpty, parseJSONFile(at: cli.fullPath, fm: fm) == nil {
            return false
        }

        let settings = parseJSONFile(at: cli.fullPath, fm: fm) ?? [:]
        var hooks = settings[cli.configKey] as? [String: Any] ?? [:]
        let events = compatibleEvents(for: cli)

        let alreadyInstalled = events.allSatisfy { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let hookList = entry["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { ($0["command"] as? String) == hookCommand }
            }
        }
        if alreadyInstalled && !hasStaleAsyncKey(hooks) { return true }

        // Remove all managed hooks first, including legacy Vibe Island entries.
        hooks = removeManagedHookEntries(from: hooks)

        // Re-install only compatible events
        for (event, timeout, _) in events {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            let hookEntry: [String: Any] = [
                "type": "command", "command": hookCommand, "timeout": timeout,
            ]
            eventHooks.append(["matcher": "", "hooks": [hookEntry]])
            hooks[event] = eventHooks
        }

        return writeJSONWithKey(
            cli: cli,
            originalText: originalText,
            key: cli.configKey,
            value: hooks,
            fm: fm
        )
    }

    /// Minimal-diff write of a single top-level key, preserving user comments / key order / escaping.
    /// Creates the file fresh if `originalText` is nil. Returns false on any failure (caller-side #89 guard).
    private static func writeJSONWithKey(
        cli: CLIConfig,
        originalText: String?,
        key: String,
        value: Any,
        fm: FileManager
    ) -> Bool {
        let source: String = {
            if let t = originalText, !t.isEmpty { return t }
            return "{}\n"
        }()
        guard let merged = JSONMinimalEditor.setTopLevelValue(in: source, key: key, value: value) else {
            return false
        }
        return fm.createFile(atPath: cli.fullPath, contents: Data(merged.utf8))
    }

    // MARK: - External CLIs (use bridge binary directly)

    @discardableResult
    private static func installExternalHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .kimi {
            // Kimi: do not create ~/.kimi or config files unless there is already
            // evidence of an existing Kimi installation/configuration.
            let rootDir = NSHomeDirectory() + "/.kimi"
            let sessionsDir = rootDir + "/sessions"
            let hasKimiPresence =
                fm.fileExists(atPath: cli.dirPath) ||
                fm.fileExists(atPath: rootDir) ||
                fm.fileExists(atPath: sessionsDir)
            guard hasKimiPresence else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
            return installKimiHooks(cli: cli, fm: fm)
        }

        if cli.format == .copilot {
            // Copilot: check root ~/.copilot exists, create hooks subdir if needed
            let rootDir = NSHomeDirectory() + "/.copilot"
            guard fm.fileExists(atPath: rootDir) else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
        } else {
            guard fm.fileExists(atPath: cli.dirPath) else { return true } // CLI not installed, skip OK
        }

        // Read raw text for minimal-diff write-back.
        let originalText: String? = fm.contents(atPath: cli.fullPath).flatMap { String(data: $0, encoding: .utf8) }
        // Refuse to touch unparseable files (#89 safety guard).
        if let text = originalText, !text.isEmpty, parseJSONFile(at: cli.fullPath, fm: fm) == nil {
            return false
        }

        let root = parseJSONFile(at: cli.fullPath, fm: fm) ?? [:]
        var hooks = root[cli.configKey] as? [String: Any] ?? [:]
        // Quote the path in case home directory contains spaces or special characters
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        let baseCommand = "\(quotedBridge) --source \(cli.source)"

        for (event, timeout, _) in cli.events {
            var eventEntries = hooks[event] as? [[String: Any]] ?? []
            // Remove old hooks before adding fresh ones (ensures reinstall works)
            eventEntries.removeAll { containsOurHook($0) }

            let entry: [String: Any]
            switch cli.format {
            case .claude:
                // Qwen Code (a Claude fork) reuses this format and NEEDS timeout per entry
                // — otherwise long-running PermissionRequest hooks hang the agent (#103).
                entry = ["matcher": "*", "hooks": [["type": "command", "command": baseCommand, "timeout": timeout] as [String: Any]]]
            case .nested:
                entry = ["hooks": [["type": "command", "command": baseCommand, "timeout": timeout] as [String: Any]]]
            case .flat:
                entry = ["command": baseCommand]
            case .traecli:
                // Treat like flat for custom JSON hook configs; built-in TraeCli uses YAML install path.
                entry = ["command": baseCommand]
            case .copilot:
                // Copilot CLI stdin lacks session_id/hook_event_name — pass event name via flag
                let copilotCommand = "\(baseCommand) --event \(event)"
                entry = ["type": "command", "bash": copilotCommand, "timeoutSec": timeout]
            case .kimi:
                // Handled earlier in the function; should never reach here
                return false
            }
            eventEntries.append(entry)
            hooks[event] = eventEntries
        }

        // Seed file if missing — ensure Copilot's required "version" key lands first so the key-order
        // for downstream readers stays stable across installs.
        var seeded = originalText
        if cli.format == .copilot, (originalText == nil || originalText?.isEmpty == true) {
            seeded = "{\n  \"version\": 1\n}\n"
        } else if cli.format == .copilot, root["version"] == nil {
            // Only insert `version` when the user hasn't set one themselves — don't clobber a
            // user-bumped schema version in case Copilot ships v2+ in the future.
            if let t = originalText, let withVer = JSONMinimalEditor.setTopLevelValue(in: t, key: "version", value: 1) {
                seeded = withVer
            }
        }

        return writeJSONWithKey(
            cli: cli,
            originalText: seeded,
            key: cli.configKey,
            value: hooks,
            fm: fm
        )
    }

    private static func renderManagedTraecliHooks(source: String = "traecli") -> String {
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        let escapedCommand = "\(quotedBridge) --source \(source)".replacingOccurrences(of: "'", with: "''")

        let events = defaultEvents(for: .traecli)
        let timeout = events.map { $0.1 }.max() ?? 5

        var lines: [String] = ["  - type: command"]
        lines.append("    command: '\(escapedCommand)'")
        lines.append("    timeout: '\(timeout)s'")
        lines.append("    matchers:")
        for (event, _, _) in events {
            lines.append("      - event: \(event)")
        }
        return lines.joined(separator: "\n")
    }

    private static func isTraecliCommandListItemStart(_ trimmed: String) -> Bool {
        // Accept exact "- type: command" and variants with trailing whitespace/comments.
        let prefix = "- type: command"
        guard trimmed.hasPrefix(prefix) else { return false }
        let rest = trimmed.dropFirst(prefix.count)
        if rest.isEmpty { return true }
        guard let c = rest.first else { return true }
        return c == " " || c == "\t" || c == "#"
    }

    private static func parseYAMLScalar(_ raw: String) -> String {
        // Handles simple single-line YAML scalars used by TraeCli config.
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            // Minimal escape handling
            return inner
                .replacingOccurrences(of: "\\\\", with: "\\")
                .replacingOccurrences(of: "\\\"", with: "\"")
        }
        return s
    }

    private static func extractTraecliCommand(from blockLines: ArraySlice<String>) -> String? {
        for line in blockLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("command:") else { continue }
            let raw = trimmed.dropFirst("command:".count)
            return parseYAMLScalar(String(raw))
        }
        return nil
    }

    private static func normalizeTraecliCommandForCompare(_ command: String) -> String {
        var s = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse whitespace
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !s.isEmpty else { return s }

        // Parse first token, allowing quoted path with spaces.
        var first = ""
        var rest = ""
        if s.hasPrefix("\"") {
            let afterQuote = s.index(after: s.startIndex)
            if let endQuote = s[afterQuote...].firstIndex(of: "\"") {
                first = String(s[afterQuote..<endQuote])
                rest = String(s[s.index(after: endQuote)...])
            } else {
                first = s
                rest = ""
            }
        } else {
            if let space = s.firstIndex(of: " ") {
                first = String(s[..<space])
                rest = String(s[space...])
            } else {
                first = s
                rest = ""
            }
        }

        first = first.trimmingCharacters(in: .whitespaces)
        rest = rest.trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("~/") {
            first = NSHomeDirectory() + "/" + first.dropFirst(2)
        }
        // Normalize home prefix
        let home = NSHomeDirectory()
        if first.hasPrefix(home + "/") {
            // Keep absolute; just ensure no double slashes
            first = first.replacingOccurrences(of: "//", with: "/")
        }
        if !rest.isEmpty {
            rest = rest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            return "\(first) \(rest)"
        }
        return first
    }

    private static func expectedTraecliCommandCandidates(source: String) -> [String] {
        let base = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        let abs = "\(bridgeCommand) --source \(source)"
        let absQuoted = "\"\(bridgeCommand)\" --source \(source)"
        let tilde = "~/.codeisland/codeisland-bridge --source \(source)"
        let tildeQuoted = "\"~/.codeisland/codeisland-bridge\" --source \(source)"
        let actualRendered = "\(base) --source \(source)"
        return [actualRendered, abs, absQuoted, tilde, tildeQuoted]
    }

    private static func isOurTraecliInjectedCommand(_ command: String, source: String) -> Bool {
        let normalized = normalizeTraecliCommandForCompare(command)
        for candidate in expectedTraecliCommandCandidates(source: source) {
            if normalized == normalizeTraecliCommandForCompare(candidate) {
                return true
            }
        }
        return false
    }

    static func removeManagedTraecliHooks(from contents: String, source: String = "traecli") -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var result: [String] = []
        result.reserveCapacity(lines.count)

        // Legacy compatibility: previous versions could leave extra comment lines around our hook.
        // We do NOT key off any marker token. Instead, when removing a hook by command match,
        // we also remove contiguous same-indent comment lines adjacent to that hook.

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect a YAML list item start like "  - type: command" (indent may vary).
            if isTraecliCommandListItemStart(trimmed) {
                let indent = line.prefix { $0 == " " }.count

                var j = i + 1
                while j < lines.count {
                    let next = lines[j]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    let nextIndent = next.prefix { $0 == " " }.count

                    // Next item in the same list (same indent + "- ") => current block ends.
                    if nextIndent == indent && nextTrimmed.hasPrefix("- ") {
                        break
                    }
                    // Leaving the list block (less indent + non-empty) => current block ends.
                    if nextIndent < indent && !nextTrimmed.isEmpty {
                        break
                    }
                    j += 1
                }

                // Remove only if the command matches what we inject.
                if let cmd = extractTraecliCommand(from: lines[i..<j]), isOurTraecliInjectedCommand(cmd, source: source) {
                    // Expand deletion to include adjacent same-indent comment lines.
                    var start = i
                    while start > 0 {
                        let prev = lines[start - 1]
                        let prevTrimmed = prev.trimmingCharacters(in: .whitespaces)
                        let prevIndent = prev.prefix { $0 == " " }.count
                        if prevIndent == indent && prevTrimmed.hasPrefix("#") {
                            start -= 1
                            continue
                        }
                        break
                    }

                    var end = j
                    while end < lines.count {
                        let next = lines[end]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        let nextIndent = next.prefix { $0 == " " }.count
                        if nextIndent == indent && nextTrimmed.hasPrefix("#") {
                            end += 1
                            continue
                        }
                        break
                    }

                    // Remove the already-appended leading comment lines (if any).
                    let removeCount = i - start
                    if removeCount > 0, result.count >= removeCount {
                        result.removeLast(removeCount)
                    }
                    i = end
                    continue
                }
                result.append(contentsOf: lines[i..<j])
                i = j
                continue
            }

            result.append(line)
            i += 1
        }

        while result.count >= 2 && result.suffix(2).allSatisfy({ $0.isEmpty }) {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    static func mergeTraecliHooks(into contents: String, source: String = "traecli") -> String {
        let cleaned = removeManagedTraecliHooks(from: contents, source: source)
        let managedLines = renderManagedTraecliHooks(source: source).components(separatedBy: "\n")
        var lines = cleaned.components(separatedBy: "\n")

        // Find a top-level hooks key. Handle common scalar/empty forms like "hooks: []" to
        // avoid producing invalid YAML by appending block items to a flow sequence.
        if let hooksIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line == trimmed else { return false } // top-level only
            return trimmed.range(of: #"^hooks:\s*(\[\s*\]|\{\s*\}|null|~)?\s*(#.*)?$"#, options: .regularExpression) != nil
        }) {
            let trimmed = lines[hooksIndex].trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: #"^hooks:\s*(\[\s*\]|\{\s*\}|null|~)\s*(#.*)?$"#, options: .regularExpression) != nil {
                lines[hooksIndex] = "hooks:"
            }
            lines.insert(contentsOf: managedLines, at: hooksIndex + 1)
        } else {
            while !lines.isEmpty && lines.last == "" {
                lines.removeLast()
            }
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("hooks:")
            lines.append(contentsOf: managedLines)
        }

        var merged = lines.joined(separator: "\n")
        if !merged.hasSuffix("\n") {
            merged.append("\n")
        }
        return merged
    }

    @discardableResult
    private static func installTraecliHooks(fm: FileManager) -> Bool {
        let configDir = (traecliConfigPath as NSString).deletingLastPathComponent
        guard fm.fileExists(atPath: configDir) else { return true }

        var original = ""
        if fm.fileExists(atPath: traecliConfigPath) {
            guard let data = fm.contents(atPath: traecliConfigPath) else { return false }
            // Never clobber existing file contents if decoding fails.
            guard let decoded = String(data: data, encoding: .utf8) else { return false }
            original = decoded
        }

        let merged = mergeTraecliHooks(into: original)
        guard let data = merged.data(using: .utf8) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: traecliConfigPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func uninstallTraecliHooks(fm: FileManager) {
        guard fm.fileExists(atPath: traecliConfigPath),
              let original = try? String(contentsOfFile: traecliConfigPath, encoding: .utf8)
        else { return }

        let cleaned = removeManagedTraecliHooks(from: original, source: "traecli")
        guard cleaned != original, let data = cleaned.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: traecliConfigPath), options: .atomic)
    }

    private static func isTraecliHooksInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: traecliConfigPath),
              let contents = try? String(contentsOfFile: traecliConfigPath, encoding: .utf8)
        else { return false }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        return removeManagedTraecliHooks(from: normalized, source: "traecli") != normalized
    }

    // MARK: - Codex config.toml

    /// Ensure codex_hooks = true under [features] in $CODEX_HOME/config.toml
    /// (or ~/.codex/config.toml when unset) so Codex actually fires hook events.
    @discardableResult
    private static func enableCodexHooksConfig(fm: FileManager) -> Bool {
        let configPath = codexHome() + "/config.toml"
        var contents = ""
        if fm.fileExists(atPath: configPath) {
            contents = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        }

        // Already set to true (non-commented) — don't touch
        if contents.range(of: #"(?m)^\s*codex_hooks\s*=\s*true"#, options: .regularExpression) != nil {
            return true
        }

        // Set to false (non-commented) — flip it to true in place
        if contents.range(of: #"(?m)^\s*codex_hooks\s*=\s*false"#, options: .regularExpression) != nil {
            contents = contents.replacingOccurrences(
                of: #"(?m)^\s*codex_hooks\s*=\s*false"#,
                with: "codex_hooks = true",
                options: .regularExpression
            )
            return fm.createFile(atPath: configPath, contents: contents.data(using: .utf8))
        }

        // Not present — insert into [features] section or create it
        var lines = contents.components(separatedBy: "\n")
        if let featIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            // Insert after [features] line
            lines.insert("codex_hooks = true", at: featIdx + 1)
        } else {
            // No [features] section — append one
            if !(lines.last ?? "").isEmpty { lines.append("") }
            lines.append("[features]")
            lines.append("codex_hooks = true")
        }
        let result = lines.joined(separator: "\n")
        return fm.createFile(atPath: configPath, contents: result.data(using: .utf8))
    }

    // MARK: - Kimi Code CLI (TOML hooks)

    internal static func installKimiHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        let path = cli.fullPath
        var contents = ""
        if fm.fileExists(atPath: path) {
            contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        }

        contents = removeKimiHooks(from: contents)
        // Comment out legacy scalar `hooks = ...` assignments that conflict with TOML array-of-tables
        // so they can be restored on uninstall instead of being permanently lost.
        contents = contents
            .components(separatedBy: "\n")
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("hooks =") {
                    return "# [CodeIsland] commented out legacy scalar hooks to avoid TOML conflict\n# \(line)"
                }
                return line
            }
            .joined(separator: "\n")

        let quotedBridge = bridgeCommand.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            ? "\"\(bridgeCommand)\""
            : bridgeCommand
        let baseCommand = "\(quotedBridge) --source \(cli.source)"

        var hookBlocks: [String] = []
        for (event, timeout, _) in cli.events {
            var block = "[[hooks]]\nevent = \"\(event)\"\ncommand = \"\(baseCommand)\"\ntimeout = \(timeout)"
            if event == "PreToolUse" || event == "PostToolUse" || event == "PostToolUseFailure" {
                block += "\nmatcher = \".*\""
            }
            hookBlocks.append(block)
        }

        if !contents.isEmpty && !contents.hasSuffix("\n") {
            contents += "\n"
        }
        if !contents.isEmpty {
            contents += "\n"
        }
        contents += hookBlocks.joined(separator: "\n\n") + "\n"

        return fm.createFile(atPath: path, contents: contents.data(using: .utf8))
    }

    static func removeKimiHooks(from contents: String) -> String {
        let lines = contents.components(separatedBy: "\n")
        var result: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "[[hooks]]" {
                var blockLines: [String] = [line]
                var j = i + 1
                while j < lines.count {
                    let nextLine = lines[j]
                    let trimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("[[") || trimmed.hasPrefix("[") {
                        break
                    }
                    blockLines.append(nextLine)
                    j += 1
                }
                let blockText = blockLines.joined(separator: "\n")
                if !blockText.contains("codeisland-bridge") {
                    result.append(contentsOf: blockLines)
                }
                i = j
            } else {
                result.append(line)
                i += 1
            }
        }
        // Trim trailing blank lines
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    private static func isKimiHooksInstalled(cli: CLIConfig, fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: cli.fullPath),
              let data = fm.contents(atPath: cli.fullPath),
              let contents = String(data: data, encoding: .utf8) else { return false }

        return cli.events.allSatisfy { (event, _, _) in
            contentsContainsKimiHook(contents, event: event)
        }
    }

    static func contentsContainsKimiHook(_ contents: String, event: String) -> Bool {
        let lines = contents.components(separatedBy: "\n")
        var inHookBlock = false
        var currentEvent: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "[[hooks]]" {
                inHookBlock = true
                currentEvent = nil
                continue
            }
            if inHookBlock && (trimmed.hasPrefix("[[") || trimmed.hasPrefix("[")) {
                inHookBlock = false
                currentEvent = nil
                continue
            }
            if inHookBlock {
                if trimmed.hasPrefix("event = ") {
                    let val = trimmed.dropFirst("event = ".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    currentEvent = val
                }
                if currentEvent == event && trimmed.contains("codeisland-bridge") {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Uninstall (generic)

    internal static func uninstallHooks(cli: CLIConfig, fm: FileManager) {
        if cli.format == .kimi {
            guard fm.fileExists(atPath: cli.fullPath),
                  let data = fm.contents(atPath: cli.fullPath),
                  var contents = String(data: data, encoding: .utf8) else { return }
            contents = removeKimiHooks(from: contents)

            // Restore commented-out legacy scalar hooks
            let lines = contents.components(separatedBy: "\n")
            var restored: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "# [CodeIsland] commented out legacy scalar hooks to avoid TOML conflict" {
                    continue
                }
                if trimmed.range(of: #"^#\s*hooks\s*="#, options: .regularExpression) != nil {
                    restored.append(line.replacingOccurrences(of: #"^#\s*"#, with: "", options: .regularExpression))
                } else {
                    restored.append(line)
                }
            }
            while let last = restored.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                restored.removeLast()
            }
            contents = restored.joined(separator: "\n")

            fm.createFile(atPath: cli.fullPath, contents: contents.data(using: .utf8))
            return
        }

        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              var hooks = root[cli.configKey] as? [String: Any],
              let originalText = fm.contents(atPath: cli.fullPath).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        hooks = removeManagedHookEntries(from: hooks)

        let merged: String?
        if hooks.isEmpty {
            merged = JSONMinimalEditor.deleteTopLevelKey(in: originalText, key: cli.configKey)
        } else {
            merged = JSONMinimalEditor.setTopLevelValue(in: originalText, key: cli.configKey, value: hooks)
        }
        if let merged, let data = merged.data(using: .utf8) {
            fm.createFile(atPath: cli.fullPath, contents: data)
        }
    }

    // MARK: - Detection helpers

    static func removeManagedHookEntries(from hooks: [String: Any]) -> [String: Any] {
        var cleaned = hooks
        for (event, value) in cleaned {
            guard var entries = value as? [[String: Any]] else { continue }
            entries.removeAll { containsOurHook($0) }
            if entries.isEmpty {
                cleaned.removeValue(forKey: event)
            } else {
                cleaned[event] = entries
            }
        }
        return cleaned
    }

    private static func isHooksInstalled(for cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .kimi {
            return isKimiHooksInstalled(cli: cli, fm: fm)
        }

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
                return HookId.isOurs(cmd)
            }
        }
        // Flat format: entry.command
        if let cmd = entry["command"] as? String, HookId.isOurs(cmd) { return true }
        // Copilot format: entry.bash
        if let cmd = entry["bash"] as? String, HookId.isOurs(cmd) { return true }
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
            // Strip quarantine xattr so Gatekeeper won't block the binary
            stripQuarantine(tmpPath)
            _ = try fm.replaceItemAt(URL(fileURLWithPath: bridgePath), withItemAt: URL(fileURLWithPath: tmpPath))
        } catch {
            // replaceItemAt fails if destination doesn't exist yet — fall back to rename
            try? fm.moveItem(atPath: tmpPath, toPath: bridgePath)
            chmod(bridgePath, 0o755)
        }
        // Ensure final binary is free of quarantine (covers both paths above)
        stripQuarantine(bridgePath)
    }

    /// Remove com.apple.quarantine xattr so Gatekeeper won't block the binary.
    /// Copied binaries inherit quarantine from the source app bundle.
    private static func stripQuarantine(_ path: String) {
        removexattr(path, "com.apple.quarantine", 0)
    }

    // MARK: - OpenCode Plugin

    /// The JS plugin source — embedded as resource or bundled alongside
    private static func opencodePluginSource() -> String? {
        // Try SPM resource bundle (where build actually places it)
        if let url = Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) { return src }
        // Fallback: try without subdirectory
        if let url = Bundle.appModule.url(forResource: "codeisland-opencode", withExtension: "js"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    /// Merge our plugin reference into an opencode.json file's contents.
    ///
    /// Returns the new file contents to write, or `nil` when the original contents
    /// are present but unparseable / not a JSON object — in that case the caller
    /// MUST NOT overwrite the file (see issue #89). Uses minimal-diff editing so
    /// user comments, key order, and whitespace are preserved (#105/#106).
    static func mergeOpencodePluginRef(
        originalContents: String?,
        pluginRef: String,
        identifier: String
    ) -> String? {
        // Brand-new file — emit a minimal canonical document.
        guard let contents = originalContents, !contents.isEmpty else {
            let config: [String: Any] = [
                "$schema": "https://opencode.ai/config.json",
                "plugin": [pluginRef],
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .withoutEscapingSlashes]
            ), var merged = String(data: data, encoding: .utf8) else { return nil }
            if !merged.hasSuffix("\n") { merged += "\n" }
            return merged
        }

        // Verify parseable and dedup plugin entries against the parsed view.
        let stripped = stripJSONComments(contents)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var plugins = parsed["plugin"] as? [String] ?? []
        plugins.removeAll { $0.contains("vibe-island") || $0.contains(identifier) }
        plugins.append(pluginRef)

        // Replace the plugin array in-place, preserving surrounding text exactly.
        guard var merged = JSONMinimalEditor.setTopLevelValue(in: contents, key: "plugin", value: plugins) else {
            return nil
        }
        // Add $schema if missing — minimal-diff insertion at end of object.
        if parsed["$schema"] == nil {
            guard let withSchema = JSONMinimalEditor.setTopLevelValue(
                in: merged, key: "$schema", value: "https://opencode.ai/config.json"
            ) else { return merged }
            merged = withSchema
        }
        return merged
    }

    /// Remove our plugin reference from an opencode.json file's contents.
    ///
    /// Returns the new file contents to write, or `nil` when the file is absent,
    /// unparseable, or does not currently reference us (nothing to do).
    static func removeOpencodePluginRef(
        originalContents: String?,
        identifier: String
    ) -> String? {
        guard let contents = originalContents else { return nil }
        let stripped = stripJSONComments(contents)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard var plugins = parsed["plugin"] as? [String],
              plugins.contains(where: { $0.contains(identifier) }) else {
            return nil
        }
        plugins.removeAll { $0.contains(identifier) }
        if plugins.isEmpty {
            return JSONMinimalEditor.deleteTopLevelKey(in: contents, key: "plugin")
        }
        return JSONMinimalEditor.setTopLevelValue(in: contents, key: "plugin", value: plugins)
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

        // Register in opencode.json only (v1.4+ reads this; config.json causes double-load)
        let pluginRef = "file://\(opencodePluginPath)"
        let originalContents: String? = fm.contents(atPath: opencodeConfigPathNew)
            .flatMap { String(data: $0, encoding: .utf8) }

        guard let merged = mergeOpencodePluginRef(
            originalContents: originalContents,
            pluginRef: pluginRef,
            identifier: HookId.current
        ) else {
            // Existing config is unparseable — refuse to overwrite user data.
            // Plugin JS is staged; opencode.json stays untouched until the user fixes it.
            return false
        }

        if let original = originalContents, !original.isEmpty {
            backupOpencodeConfig(at: opencodeConfigPathNew, original: original, fm: fm)
        }
        fm.createFile(atPath: opencodeConfigPathNew, contents: Data(merged.utf8))

        // Clean up legacy config.json registration to prevent double-load.
        if let legacyContents = fm.contents(atPath: opencodeConfigPath)
            .flatMap({ String(data: $0, encoding: .utf8) }),
           let cleaned = removeOpencodePluginRef(originalContents: legacyContents, identifier: HookId.current) {
            backupOpencodeConfig(at: opencodeConfigPath, original: legacyContents, fm: fm)
            fm.createFile(atPath: opencodeConfigPath, contents: Data(cleaned.utf8))
        }
        return true
    }

    private static func uninstallOpencodePlugin(fm: FileManager) {
        try? fm.removeItem(atPath: opencodePluginPath)
        for configPath in [opencodeConfigPathNew, opencodeConfigPath] {
            guard let contents = fm.contents(atPath: configPath)
                .flatMap({ String(data: $0, encoding: .utf8) }),
                  let cleaned = removeOpencodePluginRef(originalContents: contents, identifier: HookId.current)
            else { continue }
            backupOpencodeConfig(at: configPath, original: contents, fm: fm)
            fm.createFile(atPath: configPath, contents: Data(cleaned.utf8))
        }
    }

    /// Write a timestamped backup next to the original config file the first
    /// time we mutate it. Subsequent writes skip backup if one already exists
    /// for the same path to avoid spamming the directory.
    private static func backupOpencodeConfig(at path: String, original: String, fm: FileManager) {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        // Skip if any previous codeisland backup exists for this file.
        if let entries = try? fm.contentsOfDirectory(atPath: dir),
           entries.contains(where: { $0.hasPrefix(name + ".codeisland.bak.") }) {
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupPath = "\(path).codeisland.bak.\(stamp)"
        fm.createFile(atPath: backupPath, contents: Data(original.utf8))
    }

    /// Current OpenCode plugin version — bump when codeisland-opencode.js changes
    private static let opencodePluginVersion = "v4"

    private static func isOpencodePluginInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: opencodePluginPath) else { return false }
        // If any config file exists but is unparseable, treat plugin as installed
        // to avoid a repair loop that would clobber the user's JSON (#89).
        for configPath in [opencodeConfigPathNew, opencodeConfigPath] {
            guard fm.fileExists(atPath: configPath) else { continue }
            guard let data = fm.contents(atPath: configPath),
                  let stripped = String(data: data, encoding: .utf8).map(stripJSONComments),
                  let parsed = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
                return true
            }
            if let plugins = parsed["plugin"] as? [String],
               plugins.contains(where: { $0.contains(HookId.current) }) {
                // Check version; outdated plugin triggers re-install.
                if let existing = fm.contents(atPath: opencodePluginPath),
                   let str = String(data: existing, encoding: .utf8) {
                    return str.contains("// version: \(opencodePluginVersion)")
                }
                return false
            }
        }
        return false
    }
}
