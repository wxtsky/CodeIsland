import Foundation
import AppKit
import CodeIslandCore
import Yams

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
    /// Trae IDE / Trae CN (TraeCode desktop) style:
    /// {version, hooks: {event: [{matcher, loop_limit, hooks: [{type, command, timeout}]}]}}
    /// with Claude-style PascalCase event names.
    case traeIDE
    /// TraeCli style: YAML managed block in ~/.trae/traecli.yaml
    case traecli
    /// GitHub Copilot CLI style: [{type, bash, timeoutSec}] with top-level version
    case copilot
    /// Kimi Code CLI style: TOML [[hooks]] arrays in ~/.kimi-code/config.toml
    /// (legacy kimi-cli used ~/.kimi/config.toml).
    case kimi
    /// Kiro CLI style: per-agent JSON file at ~/.kiro/agents/<name>.json
    /// with hooks keyed by camelCase event names and `timeout_ms` (#127).
    case kiroAgent
    /// VSCode extension agents (e.g. Cline) that have no shell hook system.
    /// Detection is file-poll based; no config is written on enable.
    case none
    /// Cline: per-event executable files in ~/Documents/Cline/Hooks/<EventName>
    case cline
    /// Hermes (Nous Research) style: YAML managed block in ~/.hermes/config.yaml
    /// where `hooks:` is a MAP of snake_case event names -> list of
    /// {matcher?, command, timeout?}. Diverged from Claude — not a fork (#226).
    case hermes
    /// Google Antigravity (Gemini-based IDE/CLI) — a standalone
    /// ~/.gemini/config/hooks.json wrapped in a NAMED-CONFIG object:
    /// { "<name>": { "<Event>": [ {matcher?, hooks:[{type,command,timeout}]} ] } }.
    /// Differs from `.nested` only by the outer name wrapper (the inner entry is
    /// keyed directly under `root[configKey]` by `installExternalHooks`, so the
    /// configKey IS the wrapper name "codeisland"). Each command carries
    /// `--event <Event>` because Antigravity stdin lacks hook_event_name. Event
    /// names are Claude-style PascalCase (PreToolUse/PostToolUse/Stop), and a
    /// `matcher` is emitted only for the two tool events (#215).
    case antigravityNamed
    /// ZCode (Z.ai) Electron desktop app — user-level ~/.zcode/cli/config.json
    /// wrapping hooks in `{enabled: Bool, events: {EventName: [{hooks:[{type,
    /// command, timeout?}]}]}}`. Event names use a STRICT 7-name schema
    /// (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest,
    /// PostToolUse, PostToolUseFailure, Stop) — any other key silently drops
    /// the whole `hooks` config on load. `hooks.enabled` must be explicit; no
    /// hot-reload, so edits require a ZCode restart (#245). PermissionRequest
    /// is a blocking approval hook: its stdout decision resolves ZCode's
    /// permission dialog (#258).
    case zcode
    /// MiniMax Code CLI (`mcode`, npm @minimax-ai/code). The hook contract is
    /// Claude-compatible (same PascalCase events, same stdin/stdout JSON), but
    /// mcode has NO settings.json hooks key — shell hooks are only loadable
    /// through a Plugin. The installer writes a local plugin pack
    /// (~/.minimax/plugins/codeisland/ with .claude-plugin/plugin.json +
    /// hooks/hooks.json), which `mcode` auto-discovers by scanning the plugins
    /// directory. Verified against mcode 0.6.x: hook stdin carries
    /// hook_event_name/session_id/transcript_path/cwd like Claude, and the
    /// PermissionRequest stdout decision resolves mcode's approval prompt —
    /// but hook timeouts are capped at 10 s (see `defaultEvents`).
    case minimaxPlugin

    var storageValue: String {
        switch self {
        case .claude: return "claude"
        case .nested: return "nested"
        case .flat: return "flat"
        case .traeIDE: return "traeIDE"
        case .traecli: return "traecli"
        case .copilot: return "copilot"
        case .kimi: return "kimi"
        case .kiroAgent: return "kiroAgent"
        case .none: return "none"
        case .cline: return "cline"
        case .hermes: return "hermes"
        case .antigravityNamed: return "antigravityNamed"
        case .zcode: return "zcode"
        case .minimaxPlugin: return "minimaxPlugin"
        }
    }

    init?(storageValue: String) {
        switch storageValue.lowercased() {
        case "claude": self = .claude
        case "nested": self = .nested
        case "flat": self = .flat
        case "traeide": self = .traeIDE
        case "traecli": self = .traecli
        case "copilot": self = .copilot
        case "kimi": self = .kimi
        case "kiroagent": self = .kiroAgent
        case "none": self = .none
        case "cline": self = .cline
        case "hermes": self = .hermes
        case "antigravitynamed": self = .antigravityNamed
        case "zcode": self = .zcode
        case "minimaxplugin": self = .minimaxPlugin
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
    /// Optional override for the `--source` value passed to the bridge.
    var bridgeSourceOverride: String? = nil
    /// Set on the copies `ConfigInstaller.extraConfigDirCLI(for:)` makes of the
    /// Claude / Codex / Grok entries for an extra config root registered in
    /// Settings; `rootOverride` then points at that root. Nil for every
    /// built-in and custom entry.
    var extraConfigDir: String? = nil

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
    private static let hermesConfigPath = NSHomeDirectory() + "/.hermes/config.yaml"
    private static let zcodeConfigPath = NSHomeDirectory() + "/.zcode/cli/config.json"
    private static let piAgentDir = NSHomeDirectory() + "/.pi/agent"
    private static let piExtensionDir = NSHomeDirectory() + "/.pi/agent/extensions"
    private static let piExtensionPath = NSHomeDirectory() + "/.pi/agent/extensions/codeisland.ts"
    private static let ompAgentDir = NSHomeDirectory() + "/.omp/agent"
    private static let ompExtensionDir = NSHomeDirectory() + "/.omp/agent/extensions"
    private static let ompExtensionPath = NSHomeDirectory() + "/.omp/agent/extensions/codeisland.ts"
    // OpenClaw (openclaw.ai) — Gateway daemon. We install a local plugin pack
    // directory and register it in ~/.openclaw/openclaw.json via
    // plugins.load.paths + plugins.entries.codeisland.enabled.
    private static let openclawDir = NSHomeDirectory() + "/.openclaw"
    private static let openclawPluginDir = NSHomeDirectory() + "/.openclaw/codeisland-plugin"
    private static let openclawConfigPath = NSHomeDirectory() + "/.openclaw/openclaw.json"


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

    // MARK: - Kimi Code home resolution

    /// Modern Kimi Code CLI data root (`~/.kimi-code`). Prefer this over legacy
    /// kimi-cli (`~/.kimi`) per https://www.kimi.com/code/docs/kimi-code-cli/guides/migration.html
    static func kimiCodeHome() -> String { NSHomeDirectory() + "/.kimi-code" }

    /// Legacy kimi-cli data root (`~/.kimi`). Migration leaves this intact.
    static func kimiLegacyHome() -> String { NSHomeDirectory() + "/.kimi" }

    /// Resolve the Kimi config directory to use for hooks install/status.
    /// Prefers `~/.kimi-code` when present; falls back to `~/.kimi`; defaults to
    /// the modern path when neither exists (display / future install target).
    static func kimiHome(fm: FileManager = .default) -> String {
        let modern = kimiCodeHome()
        let legacy = kimiLegacyHome()
        if fm.fileExists(atPath: modern) { return modern }
        if fm.fileExists(atPath: legacy) { return legacy }
        return modern
    }

    /// Whether any Kimi Code / kimi-cli install footprint is on this machine.
    static func kimiPresenceDetected(fm: FileManager = .default) -> Bool {
        let modern = kimiCodeHome()
        let legacy = kimiLegacyHome()
        return fm.fileExists(atPath: modern)
            || fm.fileExists(atPath: legacy)
            || fm.isExecutableFile(atPath: modern + "/bin/kimi")
            || fm.fileExists(atPath: modern + "/config.toml")
            || fm.fileExists(atPath: legacy + "/config.toml")
    }

    static func displayKimiConfigPath(fm: FileManager = .default) -> String {
        let home = kimiHome(fm: fm)
        if home.hasSuffix("/.kimi-code") { return "~/.kimi-code/config.toml" }
        if home.hasSuffix("/.kimi") { return "~/.kimi/config.toml" }
        return "~/.kimi-code/config.toml"
    }

    // MARK: - Grok Build home resolution

    /// Resolve Grok Build's config/session root. Grok documents `GROK_HOME`
    /// as the override for the default `~/.grok` directory.
    static func grokHome() -> String {
        let raw = (ProcessInfo.processInfo.environment["GROK_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return NSHomeDirectory() + "/.grok" }
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
        return raw
    }

    static func displayGrokPath(filename: String) -> String {
        let raw = (ProcessInfo.processInfo.environment["GROK_HOME"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "~/.grok/\(filename)" : "$GROK_HOME/\(filename)"
    }

    // MARK: - MiniMax Code home resolution

    /// Resolve MiniMax Code CLI's data root. `MINIMAX_DATA_DIR` overrides the
    /// default `~/.minimax` (the docs list `MAVIS_DATA_DIR` as a compatibility
    /// fallback with lower priority). Whitespace-only values are treated as unset.
    static func minimaxHome() -> String {
        for key in ["MINIMAX_DATA_DIR", "MAVIS_DATA_DIR"] {
            let raw = (ProcessInfo.processInfo.environment[key] ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }
            if raw == "~" { return NSHomeDirectory() }
            if raw.hasPrefix("~/") { return NSHomeDirectory() + "/" + raw.dropFirst(2) }
            return raw
        }
        return NSHomeDirectory() + "/.minimax"
    }

    /// Local plugin pack the installer writes (hooks can only be declared
    /// through a plugin — mcode has no settings.json hooks key).
    static func minimaxPluginDir() -> String { minimaxHome() + "/plugins/codeisland" }

    /// User-visible form of a MiniMax config path (uses `$MINIMAX_DATA_DIR/…`
    /// when the env var is set, otherwise `~/.minimax/…`).
    static func displayMinimaxPath(filename: String) -> String {
        let raw = (ProcessInfo.processInfo.environment["MINIMAX_DATA_DIR"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? "~/.minimax/\(filename)" : "$MINIMAX_DATA_DIR/\(filename)"
    }

    /// Whether any MiniMax Code install footprint is on this machine. The
    /// installer must not create `~/.minimax` out of nowhere — a bare home
    /// directory would make `cliExists` report a phantom install (same rule
    /// as Kimi's presence gate).
    static func minimaxPresenceDetected(fm: FileManager = .default) -> Bool {
        fm.fileExists(atPath: minimaxHome())
    }

    // MARK: - All supported CLIs

    private static let builtInCLIs: [CLIConfig] = [
        // Claude Code — uses hook script (with bridge dispatcher + nc fallback)
        CLIConfig(
            name: "Claude Code", source: "claude",
            configPath: "settings.json", configKey: "hooks",
            format: .claude,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("PermissionRequest", 86400, false),
                ("Stop", 5, true),
                // Fires *instead of* Stop when the turn ends on an API error
                // (rate limit, overload, auth, billing…). It is the only
                // turn-level failure signal, so it owns the error sound.
                ("StopFailure", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("SessionStart", 5, false),
                ("SessionEnd", 5, true),
                ("Notification", 86400, false),
                ("PreCompact", 5, true),
            ],
            versionedEvents: [
                "PostToolUseFailure": "2.1.89",
                // Added in Claude Code 2.1.78 (CHANGELOG: "Added `StopFailure`
                // hook event…"); gated like PostToolUseFailure so an older
                // build never sees a hook key it does not know.
                "StopFailure": "2.1.78",
            ],
            rootOverride: { ClaudeConfigPaths.configDir() },
            displayPathOverride: { ClaudeConfigPaths.displayPath(ClaudeConfigPaths.settingsPath()) }
        ),
        // Codex — honors $CODEX_HOME (falls back to ~/.codex)
        CLIConfig(
            name: "Codex", source: "codex",
            configPath: "hooks.json", configKey: "hooks",
            format: .nested,
            events: [
                ("SessionStart", 5, false),
                ("SessionEnd", 3, true),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                // Codex fires PermissionRequest before shell escalation /
                // managed-network approvals. Without this hook the panel
                // stays in "running" and the approval sound never plays —
                // see issue #145 and developers.openai.com/codex/hooks.
                ("PermissionRequest", 86400, false),
                ("PreCompact", 5, false),
                ("PostCompact", 5, false),
                ("SubagentStart", 5, false),
                ("SubagentStop", 5, false),
                ("Stop", 5, false),
                ("Interrupt", 3, false),
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
                ("BeforeTool", 86400000, false),
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
            format: .traeIDE,
            events: defaultEvents(for: .traeIDE)
        ),
        // Trae CN
        CLIConfig(
            name: "Trae CN", source: "traecn",
            configPath: ".trae-cn/hooks.json", configKey: "hooks",
            format: .traeIDE,
            events: defaultEvents(for: .traeIDE)
        ),
        // TraeCli
        CLIConfig(
            name: "TraeCli", source: "traecli",
            configPath: ".trae/traecli.yaml", configKey: "hooks",
            format: .traecli,
            events: defaultEvents(for: .traecli)
        ),
        // Trae CLI Next — hooks.json moved under ~/.trae/cli and uses TraeX event names.
        CLIConfig(
            name: "Trae CLI Next", source: "traecli-next",
            configPath: ".trae/cli/hooks.json", configKey: "hooks",
            format: .nested,
            events: traecliNextEvents(),
            bridgeSourceOverride: "traecli"
        ),
        // Qoder — Claude Code fork with its own documented PermissionRequest hook.
        CLIConfig(
            name: "Qoder", source: "qoder",
            configPath: ".qoder/settings.json", configKey: "hooks",
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
        // Qoder CN (国行) — the China build ships as its own `qoderclicn` binary
        // with a separate config root ~/.qoder-cn, so the international entry
        // above never reaches it. The hook contract is identical, so events are
        // reported under the shared `qoder-cli` source (#289).
        CLIConfig(
            name: "Qoder CN", source: "qoder-cn",
            configPath: ".qoder-cn/settings.json", configKey: "hooks",
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
            bridgeSourceOverride: "qoder-cli"
        ),
        // QoderWork — Qoder's standalone desktop assistant app (not the IDE).
        // Claude-format hooks, but user-level ~/.qoderwork/settings.json ONLY
        // (no project-level config) and no hot reload: the user must restart
        // QoderWork after install/uninstall for hook changes to apply (#249).
        CLIConfig(
            name: "QoderWork", source: "qoderwork",
            configPath: ".qoderwork/settings.json", configKey: "hooks",
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
        // Google Antigravity (Gemini-based IDE/CLI) — NOT the Claude-fork above.
        // Reads a STANDALONE ~/.gemini/config/hooks.json (NOT Gemini-CLI's
        // settings.json "hooks" key) wrapped in a named-config object keyed by
        // "codeisland". Event names are Claude-style PascalCase; stdin carries no
        // hook_event_name, so each command needs --event <Event> (#215).
        CLIConfig(
            name: "Google Antigravity", source: "google-antigravity",
            configPath: ".gemini/config/hooks.json", configKey: "codeisland",
            format: .antigravityNamed,
            events: defaultEvents(for: .antigravityNamed),
            rootOverride: { NSHomeDirectory() }
        ),
        // WorkBuddy — Claude Code fork
        CLIConfig(
            name: "WorkBuddy", source: "workbuddy",
            configPath: ".workbuddy/settings.json", configKey: "hooks",
            format: .claude,
            events: defaultEvents(for: .claude)
        ),
        // Hermes (Nous Research) — NOT a Claude Code fork. Reads shell hooks from
        // ~/.hermes/config.yaml under a `hooks:` map keyed by snake_case event
        // names. Writing settings.json (the old behavior) meant Hermes never even
        // parsed the file, so events never fired (#226).
        CLIConfig(
            name: "Hermes", source: "hermes",
            configPath: ".hermes/config.yaml", configKey: "hooks",
            format: .hermes,
            events: defaultEvents(for: .hermes)
        ),
        // Grok Build CLI — native global hooks are standalone JSON files under
        // $GROK_HOME/hooks. Use `.nested` rather than the Claude format because
        // Grok rejects `matcher` on lifecycle events such as SessionStart/Stop.
        CLIConfig(
            name: "Grok CLI", source: "grok",
            configPath: "hooks/codeisland.json", configKey: "hooks",
            format: .nested,
            events: GrokHookForwardingPolicy.managedHookEvents.map { ($0, 5, false) },
            rootOverride: { ConfigInstaller.grokHome() },
            displayPathOverride: { ConfigInstaller.displayGrokPath(filename: "hooks/codeisland.json") }
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
        // Kimi Code CLI — TOML hooks in ~/.kimi-code/config.toml (legacy: ~/.kimi).
        // See https://www.kimi.com/code/docs/kimi-code-cli/customization/hooks.html
        CLIConfig(
            name: "Kimi Code CLI", source: "kimi",
            configPath: "config.toml", configKey: "hooks",
            format: .kimi,
            events: defaultEvents(for: .kimi),
            rootOverride: { ConfigInstaller.kimiHome() },
            displayPathOverride: { ConfigInstaller.displayKimiConfigPath() }
        ),
        // Kiro CLI — agent-scoped JSON at ~/.kiro/agents/codeisland.json.
        // User must launch with `kiro --agent codeisland` for hooks to fire (#127).
        CLIConfig(
            name: "Kiro", source: "kiro",
            configPath: ".kiro/agents/codeisland.json", configKey: "hooks",
            format: .kiroAgent,
            events: defaultEvents(for: .kiroAgent)
        ),
        // Cline — file-based hooks in ~/Documents/Cline/Hooks/<EventName>
        CLIConfig(
            name: "Cline", source: "cline",
            configPath: "Documents/Cline/Hooks",
            configKey: "",
            format: .cline,
            events: [
                ("UserPromptSubmit", 5, true),
                ("PreToolUse",       5, false),
                ("PostToolUse",      5, true),
                ("TaskStart",        5, false),
                ("TaskResume",       5, true),
                ("TaskCancel",       5, true),
                ("TaskComplete",     5, true),
                ("PreCompact",       5, true),
            ]
        ),
        // Pi — TypeScript extension auto-discovered from ~/.pi/agent/extensions.
        CLIConfig(
            name: "Pi",
            source: "pi",
            configPath: ".pi/agent/extensions/codeisland.ts", configKey: "",
            format: .none,
            events: []
        ),
        // Oh My Pi / OMP — TypeScript extension loaded from ~/.omp/agent/extensions.
        CLIConfig(
            name: "Oh My Pi",
            source: "omp",
            configPath: ".omp/agent/extensions/codeisland.ts",
            configKey: "",
            format: .none,
            events: []
        ),
        // OpenClaw — personal-assistant Gateway daemon (openclaw.ai). No shell
        // hooks: a TypeScript plugin pack is written to ~/.openclaw/codeisland-plugin
        // and registered in ~/.openclaw/openclaw.json. The user must restart the
        // Gateway afterwards for the plugin to load.
        CLIConfig(
            name: "OpenClaw",
            source: "openclaw",
            configPath: ".openclaw/codeisland-plugin/index.ts",
            configKey: "",
            format: .none,
            events: []
        ),
        // DSH (DeepSeek Harness) — cordis plugin runtime ("everything is a
        // plugin"). No shell hooks: the dsh-island plugin
        // (github:cdxiaodong/dsh-island) listens to DSH's built-in events and
        // forwards them over the CodeIsland socket directly. CodeIsland only
        // needs the source name so DSH events render as their own session card.
        CLIConfig(
            name: "DeepSeek Harness",
            source: "dsh",
            configPath: ".dsh",
            configKey: "",
            format: .none,
            events: []
        ),
        // ZCode (Z.ai) — Electron desktop app, NOT a Claude Code fork. Reads
        // hooks from ~/.zcode/cli/config.json (strict event whitelist, no
        // hot-reload — see `.zcode` HookFormat doc for details) (#245).
        CLIConfig(
            name: "ZCode", source: "zcode",
            configPath: ".zcode/cli/config.json", configKey: "hooks",
            format: .zcode,
            events: defaultEvents(for: .zcode)
        ),
        // MiniMax Code CLI (`mcode`) — hook contract is Claude-compatible, but
        // hooks are only loadable through a local Plugin. The dedicated
        // installer (see `.minimaxPlugin`) writes the whole plugin pack;
        // configPath below is the hooks file inside it, for display/repair.
        // mcode auto-discovers the plugin on the next session start.
        CLIConfig(
            name: "MiniMax Code CLI", source: "minimax",
            configPath: "plugins/codeisland/hooks/hooks.json", configKey: "hooks",
            format: .minimaxPlugin,
            events: defaultEvents(for: .minimaxPlugin),
            rootOverride: { ConfigInstaller.minimaxHome() },
            displayPathOverride: {
                ConfigInstaller.displayMinimaxPath(filename: "plugins/codeisland/hooks/hooks.json")
            }
        )
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
        case .traeIDE:
            // TraeCode (Trae / Trae CN desktop) fires exactly these six
            // Claude-style events; both editions document the same list
            // (docs.trae.ai/ide/hook-configuration-reference,
            // docs.trae.cn/ide_hook-configuration-reference). The Cursor-style
            // camelCase names we used to share with `.flat` never fire there.
            // Notification runs async and TRAE ignores its stdout, so it gets
            // the same short timeout as the status events.
            return [
                ("SessionStart", 5, false),
                ("UserPromptSubmit", 5, false),
                ("PreToolUse", 5, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
                ("Notification", 5, false),
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
        case .kiroAgent:
            // Kiro CLI hook events (camelCase). Timeouts are stored in seconds here
            // and converted to `timeout_ms` at install time.
            return [
                ("agentSpawn", 5, false),
                ("userPromptSubmit", 5, true),
                ("preToolUse", 5, false),
                ("postToolUse", 5, true),
                ("stop", 5, true),
            ]
        case .hermes:
            // Hermes event names (snake_case). Timeouts in seconds (Hermes default
            // 60, max 300). Keep status events lightweight; do NOT register a
            // long-timeout blocking permission event — Hermes uses
            // pre_approval_request/post_approval_response, not a Claude-style
            // PermissionRequest, so permission/question handling is left out of
            // v1 (#226).
            return [
                ("pre_tool_call", 5, false),
                ("post_tool_call", 5, false),
                // Turn start, with the prompt (`extra.user_message`): the card
                // shows what Hermes is working on before its first tool call.
                ("pre_llm_call", 5, false),
                // Turn end: the final reply, then on_session_end — which,
                // despite its name, fires after every turn (#303, #364).
                ("post_llm_call", 5, false),
                ("on_session_start", 5, false),
                ("on_session_end", 5, false),
                ("subagent_stop", 5, false),
            ]
        case .cline:
            return []
        case .none:
            return []
        case .antigravityNamed:
            // Antigravity hooks.json uses Claude-style PascalCase event names.
            // We install the three actionable events for status.
            // PreInvocation/PostInvocation are pass-through with no internal
            // meaning, so they're omitted. Timeout is in SECONDS (docs default 30).
            // PreToolUse no longer waits on an island card — the bridge answers
            // `ask` at once (#339) — and a hook Antigravity has to kill counts
            // as a denial, so it keeps the documented default rather than a
            // day-long ceiling nothing should ever reach.
            return [
                ("PreToolUse", 30, false),
                ("PostToolUse", 5, false),
                ("Stop", 5, false),
            ]
        case .zcode:
            // All 7 events of ZCode's strict schema, including PermissionRequest.
            // Its decision contract was confirmed against the shipped agent
            // kernel (ZCode.app/Contents/Resources/glm/zcode.cjs, #258):
            // stdout `{hookSpecificOutput: {hookEventName: "PermissionRequest",
            // decision: {behavior: "allow"|"deny", permissionUpdates?}}}`
            // resolves the approval; empty stdout, timeout, or schema failure
            // all fall back to ZCode's own permission dialog. Timeouts are in
            // seconds; only values above ZCode's 60s per-hook default are
            // written into config.json (see mergeZcodeHooks) so a pending
            // approval can wait on the island for as long as Claude's does.
            return [
                ("SessionStart", 5, false),
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PermissionRequest", 86400, false),
                ("PostToolUse", 5, true),
                ("PostToolUseFailure", 5, true),
                ("Stop", 5, true),
            ]
        case .minimaxPlugin:
            // The full event registry compiled into mcode: SessionStart,
            // SessionEnd, UserPromptSubmit, PreToolUse, PermissionRequest,
            // PostToolUse, SubagentStart, SubagentStop, Stop, PreCompact,
            // PostCompact (no Notification). Timeouts are in SECONDS and mcode
            // only accepts an integer from 1 to 10: anything else voids that
            // handler (HOOK_SCHEMA_INVALID), so Claude's day-long
            // PermissionRequest ceiling would silently drop approvals. A hook
            // that runs out fails open, so PermissionRequest takes the 10 s
            // maximum: the island can answer within that window, then mcode's
            // own prompt takes over (the bridge is killed and the card goes
            // with it). There is no PostToolUseFailure event to own the error
            // sound.
            return [
                ("SessionStart", 5, false),
                ("UserPromptSubmit", 5, true),
                ("PreToolUse", 5, false),
                ("PermissionRequest", 10, false),
                ("PostToolUse", 5, true),
                ("SubagentStart", 5, true),
                ("SubagentStop", 5, true),
                ("Stop", 5, true),
                ("PreCompact", 5, true),
                ("PostCompact", 5, true),
                ("SessionEnd", 5, true),
            ]
        }
    }

    private static func traecliNextEvents() -> [(String, Int, Bool)] {
        [
            ("SessionStart", 5, false),
            ("SessionEnd", 5, true),
            ("UserPromptSubmit", 5, true),
            ("PreToolUse", 5, false),
            ("PostToolUse", 5, true),
            ("PostToolUseFailure", 5, true),
            ("PermissionRequest", 86400, false),
            ("Notification", 86400, false),
            ("SubagentStart", 5, true),
            ("SubagentStop", 5, true),
            ("Stop", 5, true),
            ("PreCompact", 5, true),
            ("PostCompact", 5, true),
        ]
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
    // OpenCode recommends opencode.jsonc (with-comments). When the user already
    // has it we should merge our plugin entry there instead of resurrecting
    // opencode.json. See issue #132.
    private static let opencodeConfigPathJsonc = NSHomeDirectory() + "/.config/opencode/opencode.jsonc"

    // MARK: - Install / Uninstall

    static func install() -> Bool {
        let fm = FileManager.default

        // Ensure ~/.codeisland directory
        try? fm.createDirectory(atPath: codeislandDir, withIntermediateDirectories: true)

        // Clean up legacy paths at ~/.claude/hooks/ (#32)
        try? fm.removeItem(atPath: legacyBridgePath)
        try? fm.removeItem(atPath: legacyHookScriptPath)

        // A previous run may have created the Claude config dir after the resolution was
        // memoized, so re-resolve before installing into it.
        ClaudeConfigPaths.invalidateCache()

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
            } else if cli.format == .hermes {
                if !installHermesHooks(fm: fm) { ok = false }
            } else if cli.format == .zcode {
                if !installZcodeHooks(fm: fm) { ok = false }
            } else if cli.source == "pi" || cli.source == "omp" || cli.source == "openclaw" || cli.source == "dsh" {
                continue
            } else {
                if !installExternalHooks(cli: cli, fm: fm) { ok = false }
            }
        }

        // Extra config roots registered in Settings → Hooks. A root that is gone
        // or no longer looks like the CLI's is skipped (its row says why) and
        // does not fail the reinstall; only a failed write does.
        for cli in extraConfigDirCLIs() where isEnabled(source: cli.source) {
            if installHooks(inExtraDir: cli, fm: fm) == .failed { ok = false }
        }

        // Codex's required feature flag is installed by installExternalHooks;
        // its failure contributes to `ok` above, rather than reporting success.
        if isEnabled(source: "codex"),
           fm.fileExists(atPath: codexHome()) {
            repairCodexMCPApprovalTables(fm: fm)
        }

        // Install OpenCode plugin
        if isEnabled(source: "opencode") {
            if !installOpencodePlugin(fm: fm) { ok = false }
        }

        // MiMo Code / Xiaomi MiMo: the same plugin, labelled for MiMo
        if isEnabled(source: "mimo") {
            if !installMimoPlugin(fm: fm) { ok = false }
        }

        // Install pi extension
        if isEnabled(source: "pi") {
            if !installPiExtension(fm: fm) { ok = false }
        }

        // Install Oh My Pi / OMP extension
        if isEnabled(source: "omp") {
            if !installOmpExtension(fm: fm) { ok = false }
        }

        // Install OpenClaw plugin
        if isEnabled(source: "openclaw") {
            if !installOpenclawPlugin(fm: fm) { ok = false }
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
            } else if cli.format == .hermes {
                uninstallHermesHooks(fm: fm)
            } else if cli.format == .zcode {
                uninstallZcodeHooks(fm: fm)
            } else if cli.source == "pi" {
                uninstallPiExtension(fm: fm)
            } else if cli.source == "omp" {
                uninstallOmpExtension(fm: fm)
            } else if cli.source == "openclaw" {
                uninstallOpenclawPlugin(fm: fm)
            } else if cli.source == "dsh" {
                // DSH is bridged via the dsh-island plugin; no shell hooks to remove.
            } else {
                uninstallHooks(cli: cli, fm: fm)
            }
        }
        // Every registered extra root, paused ones included.
        for cli in extraConfigDirCLIs(includeDisabled: true) {
            uninstallHooks(cli: cli, fm: fm)
        }

        uninstallOpencodePlugin(fm: fm)
        uninstallMimoPlugin(fm: fm)
    }

    /// Check if Claude Code hooks are installed
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: hookScriptPath) else { return false }
        return isHooksInstalled(for: allCLIs[0], fm: fm)
    }

    /// Check if a specific CLI's hooks are installed
    static func isInstalled(source: String) -> Bool {
        if source == "aiwork" || source == "aiwork-cli" {
            // No hooks to install — "activated" means monitoring is enabled and
            // the matching AiWork surface is present on this machine.
            return isEnabled(source: source) && cliExists(source: source)
        }
        if source == "opencode" { return isOpencodePluginInstalled(fm: FileManager.default) }
        if source == "mimo" { return isMimoPluginInstalled(fm: FileManager.default) }
        if source == "pi" { return isPiExtensionInstalled(fm: FileManager.default) }
        if source == "omp" { return isOmpExtensionInstalled(fm: FileManager.default) }
        if source == "openclaw" { return isOpenclawPluginInstalled(fm: FileManager.default) }
        if source == "dsh" { return isDshInstalled() }
        if source == "traecli" { return isTraecliHooksInstalled(fm: FileManager.default) }
        if source == "hermes" { return isHermesHooksInstalled(fm: FileManager.default) }
        if source == "zcode" { return isZcodeHooksInstalled(fm: FileManager.default) }
        if source == "cline" {
            guard let cli = allCLIs.first(where: { $0.source == "cline" }) else { return false }
            return isClineHooksInstalled(cli: cli, fm: FileManager.default)
        }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return isHooksInstalled(for: cli, fm: FileManager.default)
    }

    /// Check if CLI directory exists (tool is installed on this machine)
    static func cliExists(source: String) -> Bool {
        if source == "aiwork" { return aiworkGuiIsPresent() }
        if source == "aiwork-cli" { return aiworkCliIsPresent() }
        if source == "opencode" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.config/opencode") }
        if source == "mimo" { return mimoPresenceDetected() }
        if source == "pi" { return FileManager.default.fileExists(atPath: piAgentDir) }
        if source == "omp" { return FileManager.default.fileExists(atPath: ompAgentDir) }
        if source == "openclaw" { return FileManager.default.fileExists(atPath: openclawDir) }
        if source == "dsh" {
            // DSH harness home defaults to ~/.dsh (override with $DSH_HOME).
            if let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty {
                return FileManager.default.fileExists(atPath: home)
            }
            return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.dsh")
        }
        if source == "grok" { return FileManager.default.fileExists(atPath: grokHome()) }
        if source == "copilot" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.copilot") }
        if source == "cline" {
            let fm = FileManager.default
            return fm.fileExists(atPath: NSHomeDirectory() + "/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev")
                || fm.fileExists(atPath: NSHomeDirectory() + "/Documents/Cline")
        }
        if source == "google-antigravity" {
            // Detect via Antigravity-specific markers, NOT bare ~/.gemini (which the
            // plain Gemini CLI also creates). See installExternalHooks gating (#215).
            let fm = FileManager.default
            return fm.fileExists(atPath: NSHomeDirectory() + "/.gemini/config")
                || fm.fileExists(atPath: NSHomeDirectory() + "/.gemini/antigravity-cli")
        }
        // ZCode's config lives one level below the app's real root (~/.zcode/cli/),
        // so detect against the root itself rather than cli.dirPath (#245).
        if source == "zcode" { return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.zcode") }
        // Kimi Code CLI moved from ~/.kimi (kimi-cli) to ~/.kimi-code.
        if source == "kimi" { return kimiPresenceDetected() }
        // MiniMax Code CLI: detect the data root (honors $MINIMAX_DATA_DIR) —
        // the plugin dir only exists AFTER we install hooks.
        if source == "minimax" { return minimaxPresenceDetected() }
        guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
        return FileManager.default.fileExists(atPath: cli.dirPath)
    }

    /// DSH (DeepSeek Harness) is bridged via the dsh-island plugin
    /// (`dsh plugin add github:cdxiaodong/dsh-island`). CodeIsland cannot
    /// introspect the cordis plugin store, so "installed" means the harness is
    /// present on this machine — its plugin wiring is the user's responsibility.
    static func isDshInstalled() -> Bool {
        if let home = ProcessInfo.processInfo.environment["DSH_HOME"], !home.isEmpty {
            return FileManager.default.fileExists(atPath: home)
        }
        return FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.dsh")
    }

    /// AiWork GUI (formerly DTCoder). Bundle id is still `com.alipay.dtcoder.ide`.
    static func aiworkGuiIsPresent(fileManager fm: FileManager = .default) -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.alipay.dtcoder.ide") != nil {
            return true
        }
        let names = ["AiWork.app", "DTCoder.app"]
        let roots = [NSHomeDirectory() + "/Applications", "/Applications"]
        return names.contains { name in
            roots.contains { root in
                fm.fileExists(atPath: (root as NSString).appendingPathComponent(name))
            }
        }
    }

    /// AiWork CLI (`aiwork` / legacy `dtcoder` on PATH, or Agentix state).
    static func aiworkCliIsPresent(fileManager fm: FileManager = .default) -> Bool {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let binaries = ["aiwork", "dtcoder"]
        for dir in pathDirs {
            for binary in binaries where fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(binary)) {
                return true
            }
        }
        // TUI brings up the Agentix daemon under ~/.agentix even without the GUI app.
        // A GUI-launched CodeIsland inherits launchd's minimal PATH, so this state
        // directory — the same root the watcher discovers sockets under — is the
        // check that actually decides in practice.
        return fm.fileExists(atPath: AiWorkWatchClient.defaultStateDir() + "/run")
    }

    /// Either GUI or CLI/TUI is available.
    static func aiworkIsPresent(fileManager fm: FileManager = .default) -> Bool {
        aiworkGuiIsPresent(fileManager: fm) || aiworkCliIsPresent(fileManager: fm)
    }

    /// Monitoring is on for GUI and/or CLI.
    static func isAnyAiWorkMonitoringEnabled() -> Bool {
        isEnabled(source: "aiwork") || isEnabled(source: "aiwork-cli")
    }

    static var aiworkDisplayConfigPath: String { "~/.agentix/run/coder/agent.sock" }
    static var aiworkCliDisplayConfigPath: String { "aiwork tui → agent.sock" }
    static var aiworkFullConfigPath: String {
        NSHomeDirectory() + "/.agentix/run/coder/agent.sock"
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
        // Claude / Codex / Grok: the switch covers the extra config roots too.
        applySourceToggleToExtraConfigDirs(source: source, enabled: enabled, fm: fm)
        if enabled {
            installHookScript(fm: fm)
            installBridgeBinary(fm: fm)
            if source == "aiwork" || source == "aiwork-cli" {
                // Daemon session watch — no hook files; AppState starts the watcher.
                return true
            }
            if source == "opencode" {
                return installOpencodePlugin(fm: fm)
            }
            if source == "mimo" {
                return installMimoPlugin(fm: fm)
            }
            if source == "pi" {
                return installPiExtension(fm: fm)
            }
            if source == "omp" {
                return installOmpExtension(fm: fm)
            }
            guard let cli = allCLIs.first(where: { $0.source == source }) else { return false }
            if cli.source == "claude" {
                return installClaudeHooks(cli: cli, fm: fm)
            } else if cli.source == "traecli" {
                return installTraecliHooks(fm: fm)
            } else if cli.format == .hermes {
                return installHermesHooks(fm: fm)
            } else if cli.format == .zcode {
                return installZcodeHooks(fm: fm)
            } else {
                guard installExternalHooks(cli: cli, fm: fm) else { return false }
                return isHooksInstalled(for: cli, fm: fm)
            }
        } else {
            if source == "aiwork" || source == "aiwork-cli" {
                return true
            } else if source == "opencode" {
                uninstallOpencodePlugin(fm: fm)
            } else if source == "mimo" {
                uninstallMimoPlugin(fm: fm)
            } else if source == "pi" {
                uninstallPiExtension(fm: fm)
            } else if source == "omp" {
                uninstallOmpExtension(fm: fm)
            } else if let cli = allCLIs.first(where: { $0.source == source }) {
                if cli.source == "traecli" {
                    uninstallTraecliHooks(fm: fm)
                } else if cli.format == .hermes {
                    uninstallHermesHooks(fm: fm)
                } else if cli.format == .zcode {
                    uninstallZcodeHooks(fm: fm)
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
            let dirExists: Bool
            if cli.format == .copilot {
                dirExists = fm.fileExists(atPath: NSHomeDirectory() + "/.copilot")
            } else if cli.source == "grok" {
                // The hooks directory does not exist on a fresh Grok install;
                // its parent $GROK_HOME is the installation marker.
                dirExists = fm.fileExists(atPath: grokHome())
            } else if cli.source == "pi" {
                dirExists = fm.fileExists(atPath: piAgentDir)
            } else if cli.source == "omp" {
                dirExists = fm.fileExists(atPath: ompAgentDir)
            } else if cli.format == .zcode {
                // Config lives one level below the app's real root (#245).
                dirExists = fm.fileExists(atPath: NSHomeDirectory() + "/.zcode")
            } else if cli.source == "minimax" {
                // The plugin pack lives two levels under the data root, so the
                // generic dirPath check would never exist pre-install; the
                // data root itself is the installation marker.
                dirExists = fm.fileExists(atPath: minimaxHome())
            } else {
                dirExists = fm.fileExists(atPath: cli.dirPath)
            }
            guard dirExists else { continue }
            if cli.source == "traecli" {
                if isTraecliHooksInstalled(fm: fm) { continue }
                if installTraecliHooks(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if cli.format == .hermes {
                if isHermesHooksInstalled(fm: fm) { continue }
                if installHermesHooks(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if cli.format == .zcode {
                if isZcodeHooksInstalled(fm: fm) { continue }
                if installZcodeHooks(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if cli.source == "pi" {
                if isPiExtensionInstalled(fm: fm) { continue }
                if installPiExtension(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if cli.source == "omp" {
                if isOmpExtensionInstalled(fm: fm) { continue }
                if installOmpExtension(fm: fm) {
                    repaired.append(cli.name)
                }
                continue
            }
            if isHooksInstalled(for: cli, fm: fm) { continue }
            // #182: respect a user who deleted some hook events by hand — don't
            // re-add them unless nothing of ours remains or a stale entry needs
            // cleanup.
            if shouldPreservePartialHooks(for: cli, fm: fm) { continue }
            if cli.source == "claude" {
                if installClaudeHooks(cli: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            } else {
                guard installExternalHooks(cli: cli, fm: fm) else { continue }
                if isHooksInstalled(for: cli, fm: fm) {
                    repaired.append(cli.name)
                }
            }
        }
        // Codex config.toml: ensure hooks = true
        if isEnabled(source: "codex"),
           fm.fileExists(atPath: codexHome()) {
            if !enableCodexHooksConfig(fm: fm) {
                repaired.removeAll { $0 == "Codex" }
            }
        }
        repaired.append(contentsOf: repairExtraConfigDirs(fm: fm))
        // OpenCode plugin
        if isEnabled(source: "opencode"),
           fm.fileExists(atPath: (opencodeConfigPath as NSString).deletingLastPathComponent),
           !isOpencodePluginInstalled(fm: fm) {
            if installOpencodePlugin(fm: fm) { repaired.append("OpenCode") }
        }
        // MiMo Code plugin
        if isEnabled(source: "mimo"),
           mimoPresenceDetected(fileManager: fm),
           !isMimoPluginInstalled(fm: fm) {
            if installMimoPlugin(fm: fm, present: true) { repaired.append("MiMo") }
        }
        // pi extension
        if isEnabled(source: "pi"),
           fm.fileExists(atPath: piAgentDir),
           !isPiExtensionInstalled(fm: fm) {
            if installPiExtension(fm: fm) { repaired.append("pi") }
        }
        // Oh My Pi / OMP extension
        if isEnabled(source: "omp"),
           fm.fileExists(atPath: ompAgentDir),
           !isOmpExtensionInstalled(fm: fm) {
            if installOmpExtension(fm: fm) { repaired.append("Oh My Pi") }
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

    /// How `compatibleEvents` learns the installed Claude Code's version.
    /// Detecting it starts the user's real `claude`, so a test process gets
    /// "unknown" — what a machine without Claude Code gets — unless a test
    /// installs a version of its own.
    static var claudeVersionProvider: () -> String? = {
        RuntimeEnvironment.isRunningTests ? nil : detectClaudeVersion()
    }

    /// Detect installed Claude Code version by running `claude --version`.
    /// Cache is guarded by a lock because `install()` and `verifyAndRepair()`
    /// can both call this from `Task.detached` since #139 (#103 review).
    private static var cachedClaudeVersion: String?
    private static let cachedClaudeVersionLock = NSLock()
    private static func detectClaudeVersion() -> String? {
        cachedClaudeVersionLock.lock()
        if let cached = cachedClaudeVersion {
            cachedClaudeVersionLock.unlock()
            return cached
        }
        cachedClaudeVersionLock.unlock()

        // Find claude binary — GUI apps don't inherit user's shell PATH
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        // 5s timeout: a stuck `claude --version` used to freeze app launch (#139).
        guard let data = ProcessRunner.run(path: claudePath, args: ["--version"], timeout: 5),
              let output = String(data: data, encoding: .utf8) else {
            return nil
        }
        // Parse "2.1.92 (Claude Code)" → "2.1.92"
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").first ?? ""
        guard !version.isEmpty else { return nil }
        cachedClaudeVersionLock.lock()
        cachedClaudeVersion = version
        cachedClaudeVersionLock.unlock()
        return version
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
        let version = claudeVersionProvider()

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
    /// A symlinked config file (dotfiles, a settings.json shared between
    /// accounts) is written at its target, so the link survives.
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
        return ConfigPathIdentity.write(Data(merged.utf8), to: cli.fullPath, fileManager: fm)
    }

    // MARK: - External CLIs (use bridge binary directly)

    @discardableResult
    static func installExternalHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        if cli.format == .cline { return installClineHooks(cli: cli, fm: fm) }
        if cli.format == .kimi {
            // Kimi: do not create ~/.kimi-code (or legacy ~/.kimi) unless there is
            // already evidence of an existing install. Prefer the modern root.
            guard kimiPresenceDetected(fm: fm) else { return true }
            let rootDir = kimiHome(fm: fm)
            if !fm.fileExists(atPath: rootDir) {
                try? fm.createDirectory(atPath: rootDir, withIntermediateDirectories: true)
            }
            return installKimiHooks(cli: cli, fm: fm)
        }
        if cli.format == .minimaxPlugin {
            // MiniMax: dedicated installer — hooks live in a local plugin pack,
            // not a settings.json hooks key (see the MiniMax MARK section).
            return installMinimaxHooks(cli: cli, fm: fm)
        }

        if cli.format == .copilot {
            // Copilot: check root ~/.copilot exists, create hooks subdir if needed
            let rootDir = NSHomeDirectory() + "/.copilot"
            guard fm.fileExists(atPath: rootDir) else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
        } else if cli.source == "grok" {
            // Grok discovers every JSON file in $GROK_HOME/hooks. A managed
            // install may not have created that subdirectory yet, so gate on
            // its existing root and create only the hooks child directory.
            let rootDir = (cli.dirPath as NSString).deletingLastPathComponent
            guard fm.fileExists(atPath: rootDir) else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
        } else if cli.format == .kiroAgent {
            // Kiro: check ~/.kiro exists; create agents/ subdir if needed.
            let kiroRoot = NSHomeDirectory() + "/.kiro"
            guard fm.fileExists(atPath: kiroRoot) else { return true }
            if !fm.fileExists(atPath: cli.dirPath) {
                try? fm.createDirectory(atPath: cli.dirPath, withIntermediateDirectories: true)
            }
        } else if cli.format == .antigravityNamed {
            // Google Antigravity shares the ~/.gemini root with the plain Gemini
            // CLI, so we must NOT install just because ~/.gemini exists — that
            // would write a stray hooks.json into a Gemini-only user's home.
            // Gate on an Antigravity-specific marker: the shared ~/.gemini/config
            // dir (where agy-cli writes per CHANGELOG v1.0.8) or the legacy
            // ~/.gemini/antigravity-cli dir.
            let geminiRoot = NSHomeDirectory() + "/.gemini"
            let configDir = cli.dirPath                       // ~/.gemini/config
            let antigravityDir = geminiRoot + "/antigravity-cli"
            let hasAntigravityPresence =
                fm.fileExists(atPath: configDir) || fm.fileExists(atPath: antigravityDir)
            guard hasAntigravityPresence else { return true }
            if !fm.fileExists(atPath: configDir) {
                try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
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
        if cli.source == "traecli-next" || cli.format == .traeIDE {
            // Clean up CodeIsland-managed entries written with the old
            // Cursor-style event names (beforeReadFile, stop, …): Trae CLI Next
            // rejects them, and TraeCode never fires them. The loop below only
            // replaces entries under the current event names, so without this
            // an upgraded install would keep the dead keys forever.
            hooks = removeManagedHookEntries(from: hooks)
        }
        // Quote the path in case home directory contains spaces or special characters
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        let bridgeSource = cli.bridgeSourceOverride ?? cli.source
        let baseCommand = "\(quotedBridge) --source \(bridgeSource)"

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
                let cmd = (cli.source == "gemini" || cli.source == "traecli-next")
                    ? "\(baseCommand) --event \(event)"
                    : baseCommand
                entry = ["hooks": [["type": "command", "command": cmd, "timeout": timeout] as [String: Any]]]
            case .flat:
                entry = ["command": "\(baseCommand) --event \(event)"]
            case .traeIDE:
                let traeCommand = "\(baseCommand) --event \(event)"
                entry = [
                    "matcher": "*",
                    "loop_limit": 5,
                    "hooks": [["type": "command", "command": traeCommand, "timeout": timeout] as [String: Any]],
                ]
            case .traecli:
                // Treat like flat for custom JSON hook configs; built-in TraeCli uses YAML install path.
                entry = ["command": "\(baseCommand) --event \(event)"]
            case .copilot:
                // Copilot CLI stdin lacks session_id/hook_event_name — pass event name via flag
                let copilotCommand = "\(baseCommand) --event \(event)"
                entry = ["type": "command", "bash": copilotCommand, "timeoutSec": timeout]
            case .kimi:
                // Handled earlier in the function; should never reach here
                return false
            case .minimaxPlugin:
                // MiniMax uses a dedicated installer (installMinimaxHooks) that
                // writes a whole plugin pack; never reaches this generic path.
                return false
            case .hermes:
                // Hermes uses a dedicated YAML installer (installHermesHooks);
                // never reaches the JSON external-hook path.
                return false
            case .zcode:
                // ZCode uses a dedicated installer (installZcodeHooks) for its
                // {enabled, events} wrapper; never reaches this generic path.
                return false
            case .kiroAgent:
                // Kiro entries: { command, matcher: "*", timeout_ms }. Caller declares
                // timeout in seconds for consistency with other CLIs; convert to ms here.
                entry = ["command": baseCommand, "matcher": "*", "timeout_ms": timeout * 1000]
            case .antigravityNamed:
                // Antigravity named-config entry. The outer wrapper name is the
                // configKey ("codeisland"), keyed here by installExternalHooks, so we
                // emit only the inner {matcher?, hooks:[{type,command,timeout}]} value.
                // stdin lacks hook_event_name -> the command must carry --event.
                //
                // The two event families take DIFFERENT shapes, and getting this
                // wrong is silent — Antigravity just never runs the handler:
                //   tool events  (PreToolUse/PostToolUse) → [{matcher, hooks:[…]}]
                //   model events (PreInvocation/PostInvocation/Stop) → [{type, command}]
                // We previously wrapped Stop in a `hooks` array too, so Stop never
                // fired and every Antigravity session sat on "thinking" forever (#297).
                let agyCommand = "\(baseCommand) --event \(event)"
                let handler: [String: Any] = ["type": "command", "command": agyCommand, "timeout": timeout]
                if event == "PreToolUse" || event == "PostToolUse" {
                    entry = ["matcher": "*", "hooks": [handler]]
                } else {
                    entry = handler
                }
            case .cline, .none:
                // Handled at the top of installExternalHooks; never reaches here
                return false
            }
            eventEntries.append(entry)
            hooks[event] = eventEntries
        }

        // Seed file if missing — ensure Copilot's required "version" key lands first so the key-order
        // for downstream readers stays stable across installs.
        var seeded = originalText
        if (cli.format == .copilot || cli.format == .traeIDE), (originalText == nil || originalText?.isEmpty == true) {
            seeded = "{\n  \"version\": 1\n}\n"
        } else if (cli.format == .copilot || cli.format == .traeIDE), root["version"] == nil {
            // Only insert `version` when the user hasn't set one themselves — don't clobber a
            // user-bumped schema version in case Copilot/Trae ships v2+ in the future.
            if let t = originalText, let withVer = JSONMinimalEditor.setTopLevelValue(in: t, key: "version", value: 1) {
                seeded = withVer
            }
        } else if cli.format == .kiroAgent, (originalText == nil || originalText?.isEmpty == true) {
            // Kiro agent JSON requires at minimum a "name" field. Seed a minimal agent
            // skeleton so the file is a valid Kiro agent the user can launch with
            // `kiro --agent codeisland`.
            seeded = """
            {
              "name": "codeisland",
              "description": "Auto-generated by CodeIsland — relays Kiro hook events to the macOS Dynamic Island. Launch with `kiro --agent codeisland`."
            }
            """
        }

        guard writeJSONWithKey(
            cli: cli,
            originalText: seeded,
            key: cli.configKey,
            value: hooks,
            fm: fm
        ) else { return false }
        // A hooks.json without the activation flag is not an installed Codex
        // integration. Extra roots perform their own shared-file ownership check
        // before activating; primary install/toggle/repair must propagate failure.
        return cli.source != "codex" || cli.extraConfigDir != nil
            || enableCodexHooksConfig(fm: fm, codexHome: cli.dirPath)
    }

    private static func managedTraecliHookObject(source: String = "traecli") -> [String: Any] {
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        let command = "\(quotedBridge) --source \(source)"

        let events = defaultEvents(for: .traecli)
        let timeout = events.map { $0.1 }.max() ?? 5

        let matchers: [[String: Any]] = events.map { (event, _, _) in
            ["event": event]
        }

        return [
            "type": "command",
            "command": command,
            "timeout": "\(timeout)s",
            "matchers": matchers,
        ]
    }

    /// Render the managed hook block as YAML text (2-space indent, list-item form).
    /// Used by the surgical merge path that preserves user comments/key order.
    private static func renderManagedTraecliHooksText(source: String = "traecli") -> String {
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

    private static func asStringKeyedDict(_ any: Any) -> [String: Any]? {
        if let d = any as? [String: Any] { return d }
        if let d = any as? [AnyHashable: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d {
                guard let ks = k as? String else { continue }
                out[ks] = v
            }
            return out
        }
        return nil
    }

    /// Best-effort repair for invalid YAML produced by mixed indentation under `hooks:`.
    ///
    /// This is only used as a recovery step when YAML parsing fails, to make the file
    /// parseable so it can be re-serialized via Yams.
    private static func normalizeTraecliHooksListIndentation(_ contents: String) -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let hooksIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line == trimmed else { return false } // top-level only
            return trimmed.hasPrefix("hooks:")
        }) else {
            return normalized
        }

        // Determine the intended indentation for *hook items* under hooks:
        // Only consider "- type:" / "- command:" so we don't confuse nested matcher lists.
        var hookIndent: Int?
        var i = hooksIndex + 1
        var indents: [Int] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            // Stop if we hit another top-level key.
            if line == trimmed, trimmed.contains(":"), !trimmed.hasPrefix("hooks:") {
                break
            }
            if trimmed.hasPrefix("- type:") || trimmed.hasPrefix("- command:") {
                indents.append(line.prefix { $0 == " " }.count)
            }
            i += 1
        }
        hookIndent = indents.min()
        guard let baseIndent = hookIndent else { return normalized }

        var out = lines
        i = hooksIndex + 1
        while i < out.count {
            let line = out[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                i += 1
                continue
            }
            // Stop when leaving hooks section (top-level key).
            if line == trimmed, trimmed.contains(":"), !trimmed.hasPrefix("hooks:") {
                break
            }

            if (trimmed.hasPrefix("- type:") || trimmed.hasPrefix("- command:")) {
                let indent = line.prefix { $0 == " " }.count
                if indent > baseIndent {
                    let delta = indent - baseIndent
                    // Shift the whole list item block left by delta spaces.
                    var j = i
                    while j < out.count {
                        let next = out[j]
                        let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                        let nextIndent = next.prefix { $0 == " " }.count

                        if j != i {
                            // Next item in the same list at the original indent ends the block.
                            if nextIndent == indent && nextTrimmed.hasPrefix("- ") {
                                break
                            }
                            // Leaving this list item (less indent + non-empty) ends the block.
                            if nextIndent < indent && !nextTrimmed.isEmpty {
                                break
                            }
                        }

                        if next.hasPrefix(String(repeating: " ", count: delta)) {
                            out[j] = String(next.dropFirst(delta))
                        }
                        j += 1
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }

        return out.joined(separator: "\n")
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

    private static func removeManagedTraecliHooksLegacy(from contents: String, source: String = "traecli") -> String {
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

    static func removeManagedTraecliHooks(from contents: String, source: String = "traecli") -> String {
        // Fast path: empty file.
        if contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return contents
        }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let parseInputs = [normalized, normalizeTraecliHooksListIndentation(normalized)]
        for input in parseInputs {
            do {
                guard let loaded = try Yams.load(yaml: input) else { continue }
                guard var root = asStringKeyedDict(loaded) else { continue }
                guard let hooksAny = root["hooks"] else { return contents }
                guard let hooks = hooksAny as? [Any] else { return contents }

                var didRemove = false
                var cleaned: [Any] = []
                cleaned.reserveCapacity(hooks.count)
                for item in hooks {
                    guard let hook = asStringKeyedDict(item),
                          let command = hook["command"] as? String,
                          isOurTraecliInjectedCommand(command, source: source)
                    else {
                        cleaned.append(item)
                        continue
                    }
                    didRemove = true
                }

                guard didRemove else { return contents }
                root["hooks"] = cleaned

                var dumped = try Yams.dump(object: root)
                if !dumped.hasSuffix("\n") { dumped.append("\n") }
                return dumped
            } catch {
                continue
            }
        }

        // YAML still unparseable — fall back to the legacy remover (best effort).
        return removeManagedTraecliHooksLegacy(from: contents, source: source)
    }

    static func mergeTraecliHooks(into contents: String, source: String = "traecli") -> String {
        // Path A — surgical string-level write. Preserves user comments + key
        // ordering. Validated by re-parsing through Yams; if the result is
        // invalid (e.g. user file has mixed indentation), fall through to B.
        if let surgical = trySurgicalMergeTraecliHooks(into: contents, source: source) {
            return surgical
        }

        // Path B — Yams round-trip. Re-serializes the whole file, so comments
        // and key order are lost, but the output is guaranteed to be valid YAML.
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let parseInputs = [normalized, normalizeTraecliHooksListIndentation(normalized)]

        for input in parseInputs {
            do {
                let loaded = try Yams.load(yaml: input)
                var root: [String: Any] = loaded.flatMap(asStringKeyedDict) ?? [:]

                let hooksAny = root["hooks"]
                var hooks: [Any] = []
                if let existing = hooksAny as? [Any] {
                    hooks = existing
                }

                // Remove existing managed hook(s) and then prepend the fresh one.
                hooks.removeAll { item in
                    guard let hook = asStringKeyedDict(item),
                          let command = hook["command"] as? String
                    else { return false }
                    return isOurTraecliInjectedCommand(command, source: source)
                }
                hooks.insert(managedTraecliHookObject(source: source), at: 0)
                root["hooks"] = hooks

                var dumped = try Yams.dump(object: root)
                if !dumped.hasSuffix("\n") { dumped.append("\n") }
                return dumped
            } catch {
                continue
            }
        }

        // Still unparseable: last resort, do not clobber user data.
        return contents.hasSuffix("\n") ? contents : (contents + "\n")
    }

    /// Surgical merge: drop existing managed block via string scan (preserves
    /// surrounding comments + key order), then insert a freshly-rendered one
    /// under the `hooks:` key. Returns `nil` if the result fails Yams validation,
    /// signaling the caller to fall back to the round-trip path.
    private static func trySurgicalMergeTraecliHooks(into contents: String, source: String) -> String? {
        let cleaned = removeManagedTraecliHooksLegacy(from: contents, source: source)
        let managedLines = renderManagedTraecliHooksText(source: source).components(separatedBy: "\n")
        var lines = cleaned.components(separatedBy: "\n")

        if let hooksIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard line == trimmed else { return false }  // top-level only
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
        if !merged.hasSuffix("\n") { merged.append("\n") }

        // Validate: must parse, and contain exactly one of our managed hooks.
        do {
            guard let loaded = try Yams.load(yaml: merged),
                  let root = asStringKeyedDict(loaded),
                  let hooks = root["hooks"] as? [Any] else { return nil }
            let managedCount = hooks.filter { item in
                guard let hook = asStringKeyedDict(item),
                      let command = hook["command"] as? String else { return false }
                return isOurTraecliInjectedCommand(command, source: source)
            }.count
            guard managedCount == 1 else { return nil }
        } catch {
            return nil
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

    // MARK: - Hermes config.yaml (#226)
    //
    // Hermes (Nous Research) is NOT a Claude Code fork. It reads shell hooks from
    // ~/.hermes/config.yaml under a `hooks:` MAP whose keys are snake_case event
    // names and whose values are lists of { matcher?, command, timeout? }. This is
    // a different shape than TraeCli (a flat list with `type: command` +
    // `matchers`), so it gets its own Yams-based merge/remove path.

    /// The bridge command we inject for Hermes hooks (path quoted if it has spaces).
    private static func hermesInjectedCommand() -> String {
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        return "\(quotedBridge) --source hermes"
    }

    /// Command-identity check that tolerates tilde vs. absolute path and quoting,
    /// mirroring `isOurTraecliInjectedCommand` but for the Hermes source.
    private static func isOurHermesInjectedCommand(_ command: String) -> Bool {
        let normalized = normalizeTraecliCommandForCompare(command)
        for candidate in expectedTraecliCommandCandidates(source: "hermes") {
            if normalized == normalizeTraecliCommandForCompare(candidate) {
                return true
            }
        }
        return false
    }

    /// Build the `hooks:` map (event -> [ {command, timeout} ]) merged into any
    /// existing Hermes hooks map, dropping prior managed entries first.
    static func mergeHermesHooks(into contents: String) -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        let command = hermesInjectedCommand()

        var root: [String: Any] = [:]
        if !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let loaded = try? Yams.load(yaml: normalized),
               let dict = asStringKeyedDict(loaded) {
                root = dict
            } else {
                // Never clobber an unparseable user file.
                return contents.hasSuffix("\n") ? contents : (contents + "\n")
            }
        }

        var hooks: [String: Any] = asStringKeyedDict(root["hooks"] ?? [:]) ?? [:]

        for (event, timeout, _) in defaultEvents(for: .hermes) {
            var entries: [Any] = (hooks[event] as? [Any]) ?? []
            entries.removeAll { item in
                guard let entry = asStringKeyedDict(item),
                      let cmd = entry["command"] as? String else { return false }
                return isOurHermesInjectedCommand(cmd)
            }
            let managed: [String: Any] = ["command": command, "timeout": timeout]
            entries.insert(managed, at: 0)
            hooks[event] = entries
        }

        root["hooks"] = hooks

        guard var dumped = try? Yams.dump(object: root) else {
            return contents.hasSuffix("\n") ? contents : (contents + "\n")
        }
        if !dumped.hasSuffix("\n") { dumped.append("\n") }
        return dumped
    }

    /// Remove only our managed entries from the Hermes hooks map; drop now-empty
    /// event keys and an emptied `hooks:` map so we don't leave noise behind.
    static func removeManagedHermesHooks(from contents: String) -> String {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return contents }

        guard let loaded = try? Yams.load(yaml: normalized),
              var root = asStringKeyedDict(loaded),
              var hooks = asStringKeyedDict(root["hooks"] ?? [:])
        else { return contents }

        var didRemove = false
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { continue }
            let cleaned = entries.filter { item in
                guard let entry = asStringKeyedDict(item),
                      let cmd = entry["command"] as? String else { return true }
                if isOurHermesInjectedCommand(cmd) {
                    didRemove = true
                    return false
                }
                return true
            }
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }

        guard didRemove else { return contents }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        guard var dumped = try? Yams.dump(object: root) else { return contents }
        if !dumped.hasSuffix("\n") { dumped.append("\n") }
        return dumped
    }

    @discardableResult
    private static func installHermesHooks(fm: FileManager) -> Bool {
        let configDir = (hermesConfigPath as NSString).deletingLastPathComponent
        // Only write when Hermes is actually present on this machine.
        guard fm.fileExists(atPath: configDir) else { return true }

        var original = ""
        if fm.fileExists(atPath: hermesConfigPath) {
            guard let data = fm.contents(atPath: hermesConfigPath) else { return false }
            // Never clobber existing file contents if decoding fails.
            guard let decoded = String(data: data, encoding: .utf8) else { return false }
            original = decoded
        }

        let merged = mergeHermesHooks(into: original)
        guard let data = merged.data(using: .utf8) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: hermesConfigPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func uninstallHermesHooks(fm: FileManager) {
        guard fm.fileExists(atPath: hermesConfigPath),
              let original = try? String(contentsOfFile: hermesConfigPath, encoding: .utf8)
        else { return }

        let cleaned = removeManagedHermesHooks(from: original)
        guard cleaned != original, let data = cleaned.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: hermesConfigPath), options: .atomic)
    }

    private static func isHermesHooksInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: hermesConfigPath),
              let contents = try? String(contentsOfFile: hermesConfigPath, encoding: .utf8)
        else { return false }

        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        return removeManagedHermesHooks(from: normalized) != normalized
    }

    // MARK: - ZCode config.json (#245, #258)
    //
    // ZCode (Z.ai) is an Electron desktop app — NOT a Claude Code fork. Hooks
    // live under `hooks: {enabled, events}`, where `events` maps event names
    // to Claude/nested-shaped entries ({hooks: [{type, command, timeout?}]}) —
    // the same shape `containsOurHook` / `removeManagedHookEntries` already
    // understand, so those generic helpers apply unchanged to the `events`
    // sub-dict. The event-name schema is STRICT: any key outside
    // `zcodeAllowedEvents` silently drops the WHOLE `hooks` config on load —
    // never write outside that whitelist. Hook OUTPUT is equally strict
    // (Zod .strict() in the kernel): a PermissionRequest decision must be
    // exactly {behavior, permissionUpdates?/updatedInput?} or
    // {behavior: "deny", interrupt?, message?} — Claude's
    // `updatedPermissions`/`destination` keys fail validation and the whole
    // decision is discarded (ZCode then shows its own dialog). See
    // AppState.zcodeAlwaysAllowResponse for the always-allow shape. No
    // hot-reload; a ZCode restart is required after any config.json edit.

    /// The only 7 event names ZCode's schema accepts. Writing anything else
    /// causes the entire `hooks` config to be silently discarded on load —
    /// always filter against this before writing an event key.
    static let zcodeAllowedEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PostToolUseFailure", "Stop",
    ]

    /// The bridge command we inject for ZCode hooks (path quoted if it has spaces).
    private static func zcodeInjectedCommand() -> String {
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        return "\(quotedBridge) --source zcode"
    }

    /// Parse a JSON/JSONC string directly (no filesystem access) — the string
    /// counterpart to `parseJSONFile`, used by the pure merge/remove functions
    /// below so they're testable without touching the real ~/.zcode path.
    private static func parseJSONString(_ text: String) -> [String: Any]? {
        guard let data = stripJSONComments(text).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Build the merged `hooks: {enabled, events}` document from raw file text
    /// (seeds a fresh `{}` document when `contents` is empty), dropping stale
    /// managed entries first so re-running is idempotent. Returns `contents`
    /// unchanged if it fails to parse as a JSON object — never clobber
    /// unparseable user data (#89).
    static func mergeZcodeHooks(into contents: String) -> String {
        let isEmpty = contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let baseText = isEmpty ? "{}\n" : contents
        guard let root = parseJSONString(baseText) else { return contents }

        var hooksRoot = root["hooks"] as? [String: Any] ?? [:]
        var events = removeManagedHookEntries(from: hooksRoot["events"] as? [String: Any] ?? [:])

        let command = zcodeInjectedCommand()
        for (event, timeout, _) in defaultEvents(for: .zcode) where zcodeAllowedEvents.contains(event) {
            var entries = events[event] as? [[String: Any]] ?? []
            var hook: [String: Any] = ["type": "command", "command": command]
            // ZCode's per-hook default timeout is 60s. Status hooks keep that
            // default (the bridge self-limits far below it); blocking hooks
            // (PermissionRequest) must override it or ZCode would abandon the
            // approval after a minute and pop its own dialog. `timeout` is
            // ZCode-native seconds (its kernel converts to ms internally).
            if timeout > 60 {
                hook["timeout"] = timeout
            }
            entries.append(["hooks": [hook]])
            events[event] = entries
        }

        // `enabled` is the user's master switch over ALL their hooks — never
        // flip an explicit false (that would silently re-arm every third-party
        // hook command they turned off). Our hooks stay dormant in that case.
        if hooksRoot["enabled"] == nil {
            hooksRoot["enabled"] = true
        }
        hooksRoot["events"] = events

        return JSONMinimalEditor.setTopLevelValue(in: baseText, key: "hooks", value: hooksRoot) ?? contents
    }

    /// Remove only our managed entries from the ZCode `hooks.events` map; drop
    /// now-empty event keys, and drop the whole `hooks` key if nothing but our
    /// own `enabled`/`events` scaffolding remains (never leave `{"enabled":
    /// true, "events": {}}` behind).
    static func removeManagedZcodeHooks(from contents: String) -> String {
        guard let root = parseJSONString(contents),
              var hooksRoot = root["hooks"] as? [String: Any]
        else { return contents }

        var events = hooksRoot["events"] as? [String: Any] ?? [:]
        var didRemove = false
        for (event, value) in events {
            guard let entries = value as? [[String: Any]] else { continue }
            let cleaned = entries.filter { !containsOurHook($0) }
            if cleaned.count != entries.count { didRemove = true }
            if cleaned.isEmpty {
                events.removeValue(forKey: event)
            } else {
                events[event] = cleaned
            }
        }
        guard didRemove else { return contents }
        hooksRoot["events"] = events

        // Nothing of ours — or the user's — left under `hooks`: drop the whole
        // key instead of leaving empty scaffolding behind.
        let hooksIsFullyOurs = events.isEmpty && hooksRoot.keys.allSatisfy { $0 == "enabled" || $0 == "events" }
        if hooksIsFullyOurs {
            return JSONMinimalEditor.deleteTopLevelKey(in: contents, key: "hooks") ?? contents
        }
        return JSONMinimalEditor.setTopLevelValue(in: contents, key: "hooks", value: hooksRoot) ?? contents
    }

    @discardableResult
    private static func installZcodeHooks(fm: FileManager) -> Bool {
        let zcodeRoot = NSHomeDirectory() + "/.zcode"
        // Only write when ZCode is actually present on this machine.
        guard fm.fileExists(atPath: zcodeRoot) else { return true }
        let configDir = (zcodeConfigPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: configDir) {
            try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        var original = ""
        if fm.fileExists(atPath: zcodeConfigPath) {
            guard let data = fm.contents(atPath: zcodeConfigPath),
                  let decoded = String(data: data, encoding: .utf8) else { return false }
            original = decoded
        }
        // Refuse to touch unparseable files (#89 safety guard).
        if !original.isEmpty, parseJSONString(original) == nil { return false }

        let merged = mergeZcodeHooks(into: original)
        guard let data = merged.data(using: .utf8) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: zcodeConfigPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func uninstallZcodeHooks(fm: FileManager) {
        guard fm.fileExists(atPath: zcodeConfigPath),
              let original = try? String(contentsOfFile: zcodeConfigPath, encoding: .utf8)
        else { return }

        let cleaned = removeManagedZcodeHooks(from: original)
        guard cleaned != original, let data = cleaned.data(using: .utf8) else { return }
        try? data.write(to: URL(fileURLWithPath: zcodeConfigPath), options: .atomic)
    }

    private static func isZcodeHooksInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: zcodeConfigPath),
              let contents = try? String(contentsOfFile: zcodeConfigPath, encoding: .utf8)
        else { return false }

        return removeManagedZcodeHooks(from: contents) != contents
    }

    // MARK: - MiniMax Code plugin pack
    //
    // mcode (npm @minimax-ai/code) has no settings.json "hooks" key — shell
    // hooks are only loadable through a Plugin. A local plugin is just a
    // directory under `~/.minimax/plugins/<name>/` that mcode discovers by
    // scanning (verified with `mcode plugin list`: a bare directory with a
    // manifest shows up as `<name>@local`). We write the Claude-compatible
    // layout, which mcode parses with sourceFormat CLAUDE:
    //
    //   <root>/plugins/codeisland/
    //   ├── .claude-plugin/plugin.json   {name, hooks: ["hooks/hooks.json"]}
    //   └── hooks/hooks.json             {hooks: {Event: [{hooks: [{…}]}]}}
    //
    // The hook contract itself is Claude-compatible: stdin carries
    // hook_event_name/session_id/transcript_path/cwd, and a PermissionRequest
    // stdout decision resolves mcode's approval prompt. No registration file,
    // no restart of any daemon — the plugin is picked up by the next mcode
    // session start.

    /// Marker written into the manifest so uninstall only ever removes OUR pack.
    private static let minimaxManifestMarker = "CodeIsland MiniMax Code plugin"

    /// The bridge command we inject for MiniMax hooks (path quoted if it has spaces).
    private static func minimaxInjectedCommand() -> String {
        let quotedBridge = bridgeCommand.contains(" ") ? "\"\(bridgeCommand)\"" : bridgeCommand
        return "\(quotedBridge) --source minimax"
    }

    /// Build the plugin manifest document — pure so tests can exercise it.
    static func minimaxManifestDocument() -> [String: Any] {
        [
            "name": "codeisland",
            "displayName": "CodeIsland",
            "version": "1.0.0",
            "description": minimaxManifestMarker,
            "hooks": ["hooks/hooks.json"],
        ]
    }

    /// Build the full hooks.json document for the plugin pack — pure so tests
    /// can exercise it. Claude-compatible entry shape, no `matcher`: mcode
    /// accepts an omitted matcher on every event (the parsing code only
    /// validates matcher when present), and both the shipped clawd-state
    /// plugin and our own probe fired with this shape.
    static func minimaxHooksDocument() -> [String: Any] {
        let command = minimaxInjectedCommand()
        var hooks: [String: Any] = [:]
        for (event, timeout, _) in defaultEvents(for: .minimaxPlugin) {
            hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": timeout]]]]
        }
        return ["hooks": hooks]
    }

    @discardableResult
    private static func installMinimaxHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        // Only engage machines that actually have MiniMax Code — creating
        // ~/.minimax out of nowhere would turn cliExists into a phantom yes
        // (same rule as Kimi's presence gate).
        guard minimaxPresenceDetected(fm: fm) else { return true }

        let hooksDir = (cli.fullPath as NSString).deletingLastPathComponent
        let manifestPath = minimaxManifestPath(cli: cli)
        // A plugin someone else put at plugins/codeisland is not ours to
        // overwrite (uninstall refuses to delete it for the same reason).
        if let existing = fm.contents(atPath: manifestPath), !minimaxManifestIsOurs(existing) {
            return false
        }
        let manifestDir = (manifestPath as NSString).deletingLastPathComponent
        for dir in [manifestDir, hooksDir] where !fm.fileExists(atPath: dir) {
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            } catch {
                return false
            }
        }

        guard let manifest = try? JSONSerialization.data(
                  withJSONObject: minimaxManifestDocument(),
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let hooksDoc = try? JSONSerialization.data(
                  withJSONObject: minimaxHooksDocument(),
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return false }

        // Runs on every launch: leave files that are already current alone.
        func writeIfChanged(_ data: Data, to path: String) -> Bool {
            fm.contents(atPath: path) == data || fm.createFile(atPath: path, contents: data)
        }
        return writeIfChanged(manifest, to: manifestPath)
            && writeIfChanged(hooksDoc, to: cli.fullPath)
    }

    private static func minimaxManifestPath(cli: CLIConfig) -> String {
        let hooksDir = (cli.fullPath as NSString).deletingLastPathComponent
        let pluginDir = (hooksDir as NSString).deletingLastPathComponent   // …/plugins/codeisland
        return pluginDir + "/.claude-plugin/plugin.json"
    }

    private static func minimaxManifestIsOurs(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.contains(minimaxManifestMarker) == true
    }

    /// The pack is installed when our manifest is in place and hooks.json is
    /// exactly the document we generate — so a stale bridge path, timeout or
    /// event list (or a deleted manifest) reads as drift and gets rewritten.
    static func isMinimaxPluginInstalled(cli: CLIConfig, fm: FileManager) -> Bool {
        guard let manifest = fm.contents(atPath: minimaxManifestPath(cli: cli)),
              minimaxManifestIsOurs(manifest),
              let hooks = parseJSONFile(at: cli.fullPath, fm: fm)
        else { return false }
        return NSDictionary(dictionary: hooks).isEqual(to: minimaxHooksDocument())
    }

    private static func uninstallMinimaxHooks(cli: CLIConfig, fm: FileManager) {
        let hooksPath = cli.fullPath
        let hooksDir = (hooksPath as NSString).deletingLastPathComponent
        let pluginDir = (hooksDir as NSString).deletingLastPathComponent

        // The pack directory is entirely ours — remove it wholesale when the
        // manifest proves it (never delete a foreign plugin that happens to
        // share the directory name).
        if let data = fm.contents(atPath: minimaxManifestPath(cli: cli)), minimaxManifestIsOurs(data) {
            try? fm.removeItem(atPath: pluginDir)
            return
        }

        // Manifest missing or foreign: still scrub managed entries from any
        // hooks.json we may have contributed to, leaving foreign content alone.
        guard fm.fileExists(atPath: hooksPath),
              let root = parseJSONFile(at: hooksPath, fm: fm),
              var hooks = root[cli.configKey] as? [String: Any],
              let originalText = fm.contents(atPath: hooksPath).flatMap({ String(data: $0, encoding: .utf8) })
        else { return }

        hooks = removeManagedHookEntries(from: hooks)
        let merged: String?
        if hooks.isEmpty {
            merged = JSONMinimalEditor.deleteTopLevelKey(in: originalText, key: cli.configKey)
        } else {
            merged = JSONMinimalEditor.setTopLevelValue(in: originalText, key: cli.configKey, value: hooks)
        }
        if let merged, let data = merged.data(using: .utf8) {
            ConfigPathIdentity.write(data, to: hooksPath, fileManager: fm)
        }
    }

    // MARK: - Codex config.toml

    /// Clears out the transport-less `[mcp_servers.*.tools.*]` tables an older
    /// CodeIsland could write, which make Codex reject the whole config.toml
    /// (#316). Runs at launch because the user has no reason to connect their
    /// broken Codex to an "Always Allow" they clicked days earlier — and the
    /// symptom (unrelated settings refusing to save) never points here.
    @discardableResult
    static func repairCodexMCPApprovalTables(fm: FileManager) -> Bool {
        let configPath = codexHome() + "/config.toml"
        guard fm.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8),
              let repaired = CodexPermissionRules.repairingOrphanedMCPToolTables(contents) else {
            return false
        }
        return ConfigPathIdentity.write(Data(repaired.utf8), to: configPath, fileManager: fm)
    }

    /// Ensure the Codex hooks feature flag is true in $CODEX_HOME/config.toml
    /// (or ~/.codex/config.toml when unset) so Codex actually fires hook events.
    /// The source editor recognizes quoted/bare keys and table scope without
    /// touching comments, unrelated flags or strings containing TOML examples.
    /// An unsupported/conflicting layout is left untouched and returns false.
    /// `codexHome` is overridden for extra Codex roots registered in Settings —
    /// each root has its own config.toml, and a hooks.json without the flag
    /// next to it is never read. A symlinked config.toml is edited at its
    /// target and stays a symlink.
    @discardableResult
    static func enableCodexHooksConfig(fm: FileManager, codexHome: String = ConfigInstaller.codexHome()) -> Bool {
        let configPath = codexHome + "/config.toml"
        try? fm.createDirectory(
            atPath: (configPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let contents: String
        if fm.fileExists(atPath: configPath) {
            guard let existing = try? String(contentsOfFile: configPath, encoding: .utf8) else { return false }
            contents = existing
        } else {
            contents = ""
        }
        guard let result = CodexHooksConfig.enablingHooks(in: contents) else { return false }
        if result == contents { return true }
        return ConfigPathIdentity.write(Data(result.utf8), to: configPath, fileManager: fm)
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

    /// Paths checked for Kimi hooks *status* (Settings installed badge).
    /// Exactly one path: the install target (`cli.fullPath` / `kimiHome()`).
    /// Must never OR modern + legacy — that false-positives migrated users.
    internal static func kimiHooksStatusConfigPaths(for cli: CLIConfig) -> [String] {
        [cli.fullPath]
    }

    /// Whether CodeIsland hooks are present in the config kimi-code (or legacy
    /// kimi-cli) will actually read. Matches install's `cli.fullPath` target —
    /// do not OR legacy when `~/.kimi-code` exists, or migrated users with hooks
    /// only under `~/.kimi` show a false "installed" while kimi-code ignores them.
    private static func isKimiHooksInstalled(cli: CLIConfig, fm: FileManager) -> Bool {
        kimiHooksStatusConfigPaths(for: cli).contains { path in
            guard fm.fileExists(atPath: path),
                  let data = fm.contents(atPath: path),
                  let contents = String(data: data, encoding: .utf8) else { return false }
            return cli.events.allSatisfy { (event, _, _) in
                contentsContainsKimiHook(contents, event: event)
            }
        }
    }

    /// Test seam: status for an explicit config path (hermetic fixtures).
    internal static func isKimiHooksInstalled(at configPath: String, cli: CLIConfig, fm: FileManager) -> Bool {
        let probe = CLIConfig(
            name: cli.name,
            source: cli.source,
            configPath: configPath,
            configKey: cli.configKey,
            format: cli.format,
            events: cli.events
        )
        return isKimiHooksInstalled(cli: probe, fm: fm)
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
        if cli.format == .cline {
            uninstallClineHooks(cli: cli, fm: fm)
            return
        }
        if cli.format == .minimaxPlugin {
            uninstallMinimaxHooks(cli: cli, fm: fm)
            return
        }
        if cli.format == .kimi {
            // Scrub modern + legacy homes; also honor absolute cli.fullPath
            // (hermetic tests / custom roots).
            var paths = [kimiCodeHome() + "/config.toml", kimiLegacyHome() + "/config.toml"]
            let resolved = cli.fullPath
            if !paths.contains(resolved) { paths.append(resolved) }
            for path in paths {
                guard fm.fileExists(atPath: path),
                      let data = fm.contents(atPath: path),
                      var contents = String(data: data, encoding: .utf8) else { continue }
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

                fm.createFile(atPath: path, contents: contents.data(using: .utf8))
            }
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
            // Through a symlinked config file, not over it.
            ConfigPathIdentity.write(data, to: cli.fullPath, fileManager: fm)
        }
    }

    // MARK: - Cline file-based hooks

    private static let clineHookMarker = "codeisland-bridge --source cline"

    // Cline requires valid JSON on stdout from every hook invocation.
    // Run the bridge in the background (forwarding stdin) so it can report
    // status to CodeIsland, then immediately return {"cancel":false} to Cline.
    private static let clineHookScript = """
        #!/bin/bash
        INPUT=$(cat)
        printf '%s' "$INPUT" | ~/.codeisland/codeisland-bridge --source cline "$@" >/dev/null 2>&1 &
        printf '{"cancel":false}'
        """

    @discardableResult
    private static func installClineHooks(cli: CLIConfig, fm: FileManager) -> Bool {
        let hooksDir = cli.fullPath
        if !fm.fileExists(atPath: hooksDir) {
            try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }
        var ok = true
        for (event, _, _) in cli.events {
            let filePath = "\(hooksDir)/\(event)"
            if !fm.createFile(atPath: filePath, contents: Data(clineHookScript.utf8)) {
                ok = false
            }
            chmod(filePath, 0o755)
        }
        return ok
    }

    private static func isClineHooksInstalled(cli: CLIConfig, fm: FileManager) -> Bool {
        let hooksDir = cli.fullPath
        return cli.events.allSatisfy { (event, _, _) in
            let filePath = "\(hooksDir)/\(event)"
            guard fm.fileExists(atPath: filePath),
                  let data = fm.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8)
            else { return false }
            return content.contains(clineHookMarker)
        }
    }

    private static func uninstallClineHooks(cli: CLIConfig, fm: FileManager) {
        let hooksDir = cli.fullPath
        for (event, _, _) in cli.events {
            let filePath = "\(hooksDir)/\(event)"
            guard fm.fileExists(atPath: filePath),
                  let data = fm.contents(atPath: filePath),
                  let content = String(data: data, encoding: .utf8),
                  content.contains(clineHookMarker)
            else { continue }
            try? fm.removeItem(atPath: filePath)
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
        if cli.format == .minimaxPlugin {
            return isMinimaxPluginInstalled(cli: cli, fm: fm)
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
        // Pre-#297 installs wrapped Antigravity's model events in a `hooks` array,
        // a shape Antigravity silently ignores. Report those as not-installed so
        // verifyAndRepair rewrites them into the flat handler form.
        if cli.format == .antigravityNamed, hasNestedAntigravityModelEvent(hooks) { return false }
        return true
    }

    /// Antigravity's `PreInvocation` / `PostInvocation` / `Stop` handlers are a
    /// direct `[{type, command}]` list; only `PreToolUse` / `PostToolUse` take the
    /// `[{matcher, hooks: […]}]` wrapper. A CodeIsland entry for a model event
    /// carrying a `hooks` array is the broken legacy shape. (#297)
    static func hasNestedAntigravityModelEvent(_ hooks: [String: Any]) -> Bool {
        let modelEvents = ["Stop", "PreInvocation", "PostInvocation"]
        for event in modelEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            if entries.contains(where: { containsOurHook($0) && $0["hooks"] != nil }) {
                return true
            }
        }
        return false
    }

    /// #182: tell apart a user who intentionally kept only some hook events
    /// from a config that was never installed, fully wiped, or corrupted.
    /// Returns true when at least one of our hook entries is present and
    /// nothing stale needs rewriting — meaning verifyAndRepair should leave the
    /// (incomplete) config untouched instead of re-adding the removed events.
    static func shouldPreservePartialHooks(hooks: [String: Any], events: [(String, Int, Bool)]) -> Bool {
        if hasStaleAsyncKey(hooks) { return false }
        return events.contains { (event, _, _) in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { containsOurHook($0) }
        }
    }

    private static func shouldPreservePartialHooks(for cli: CLIConfig, fm: FileManager) -> Bool {
        // Kimi stores hooks in TOML with its own all-or-nothing detection.
        if cli.format == .kimi { return false }
        // The MiniMax plugin pack is generated whole and holds nothing but
        // ours, so any drift is repaired rather than taken as a user's edit.
        if cli.format == .minimaxPlugin { return false }
        guard let root = parseJSONFile(at: cli.fullPath, fm: fm),
              let hooks = root[cli.configKey] as? [String: Any] else { return false }
        // A legacy-shaped Antigravity model event is broken, not "intentionally
        // pruned by the user" — it must be rewritten, not preserved. (#297)
        if cli.format == .antigravityNamed, hasNestedAntigravityModelEvent(hooks) { return false }
        return shouldPreservePartialHooks(hooks: hooks, events: cli.events)
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

    // MARK: - pi Extension

    /// Current pi extension version — bump when codeisland-pi.ts changes.
    private static let piExtensionVersion = "v4"

    /// Current omp extension version — bump when codeisland-omp.ts changes.
    /// Kept independent of pi (OMP reuses the "CodeIsland pi extension" banner
    /// but ships its own resource file), so a pi-only bump does not false-flag
    /// healthy OMP installs as needing repair.
    private static let ompExtensionVersion = "v8"

    private static func piExtensionSource() -> String? {
        if let url = Bundle.appModule.url(forResource: "codeisland-pi", withExtension: "ts", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) { return src }
        if let url = Bundle.appModule.url(forResource: "codeisland-pi", withExtension: "ts"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    @discardableResult
    static func installPiExtension(
        piAgentDir: String = piAgentDir,
        piExtensionDir: String = piExtensionDir,
        piExtensionPath: String = piExtensionPath,
        fm: FileManager
    ) -> Bool {
        guard fm.fileExists(atPath: piAgentDir) else { return true }
        guard let source = piExtensionSource() else { return false }
        try? fm.createDirectory(atPath: piExtensionDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: piExtensionPath) { try? fm.removeItem(atPath: piExtensionPath) }
        return fm.createFile(atPath: piExtensionPath, contents: Data(source.utf8))
    }

    static func uninstallPiExtension(
        piExtensionPath: String = piExtensionPath,
        fm: FileManager
    ) {
        guard fm.fileExists(atPath: piExtensionPath),
              let data = fm.contents(atPath: piExtensionPath),
              let content = String(data: data, encoding: .utf8),
              content.contains("CodeIsland pi extension")
        else { return }
        try? fm.removeItem(atPath: piExtensionPath)
    }

    static func isPiExtensionInstalled(
        piExtensionPath: String = piExtensionPath,
        fm: FileManager
    ) -> Bool {
        guard fm.fileExists(atPath: piExtensionPath),
              let data = fm.contents(atPath: piExtensionPath),
              let content = String(data: data, encoding: .utf8)
        else { return false }
        return content.contains("CodeIsland pi extension")
            && content.contains("// version: \(piExtensionVersion)")
    }

    private static func ompExtensionSource() -> String? {
        if let url = Bundle.appModule.url(forResource: "codeisland-omp", withExtension: "ts", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) { return src }
        if let url = Bundle.appModule.url(forResource: "codeisland-omp", withExtension: "ts"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    @discardableResult
    static func installOmpExtension(
        ompAgentDir: String = ompAgentDir,
        ompExtensionDir: String = ompExtensionDir,
        ompExtensionPath: String = ompExtensionPath,
        fm: FileManager
    ) -> Bool {
        guard fm.fileExists(atPath: ompAgentDir) else { return true }
        guard let source = ompExtensionSource() else { return false }
        try? fm.createDirectory(atPath: ompExtensionDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: ompExtensionPath) { try? fm.removeItem(atPath: ompExtensionPath) }
        return fm.createFile(atPath: ompExtensionPath, contents: Data(source.utf8))
    }

    static func uninstallOmpExtension(
        ompExtensionPath: String = ompExtensionPath,
        fm: FileManager
    ) {
        uninstallPiExtension(piExtensionPath: ompExtensionPath, fm: fm)
    }

    static func isOmpExtensionInstalled(
        ompExtensionPath: String = ompExtensionPath,
        fm: FileManager
    ) -> Bool {
        guard fm.fileExists(atPath: ompExtensionPath),
              let data = fm.contents(atPath: ompExtensionPath),
              let content = String(data: data, encoding: .utf8)
        else { return false }
        // OMP ships a separate resource; do not share piExtensionVersion or a
        // pi-only bump would force a false "needs repair" for healthy OMP installs.
        return content.contains("CodeIsland pi extension")
            && content.contains("// version: \(ompExtensionVersion)")
    }

    // MARK: - OpenClaw plugin (#235)

    private static let openclawPluginVersion = "v1"
    private static let openclawPluginFiles = ["index.ts", "openclaw.plugin.json", "package.json"]

    private static func openclawPluginSource(_ file: String) -> String? {
        let parts = file.split(separator: ".", maxSplits: 1).map(String.init)
        let name = parts[0]
        let ext = parts.count > 1 ? parts[1] : ""
        if let url = Bundle.appModule.url(forResource: name, withExtension: ext, subdirectory: "Resources/codeisland-openclaw"),
           let src = try? String(contentsOf: url) { return src }
        if let url = Bundle.appModule.url(forResource: name, withExtension: ext, subdirectory: "codeisland-openclaw"),
           let src = try? String(contentsOf: url) { return src }
        return nil
    }

    /// Install the OpenClaw plugin pack (#235): write the three plugin files to
    /// ~/.openclaw/codeisland-plugin/ and register the pack in
    /// ~/.openclaw/openclaw.json (plugins.load.paths + plugins.entries).
    ///
    /// openclaw.json is JSON5 — user files with comments/trailing commas won't
    /// parse with JSONSerialization. In that case we still install the plugin
    /// files but REFUSE to touch the config (#89: never clobber what we can't
    /// parse) and report failure so the UI shows the manual step.
    @discardableResult
    static func installOpenclawPlugin(
        openclawDir: String = openclawDir,
        openclawPluginDir: String = openclawPluginDir,
        openclawConfigPath: String = openclawConfigPath,
        fm: FileManager
    ) -> Bool {
        // Only engage for machines that actually have OpenClaw.
        guard fm.fileExists(atPath: openclawDir) else { return true }

        try? fm.createDirectory(atPath: openclawPluginDir, withIntermediateDirectories: true)
        for file in openclawPluginFiles {
            guard let source = openclawPluginSource(file) else { return false }
            let path = openclawPluginDir + "/" + file
            if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
            guard fm.createFile(atPath: path, contents: Data(source.utf8)) else { return false }
        }

        return registerOpenclawPlugin(
            openclawPluginDir: openclawPluginDir,
            openclawConfigPath: openclawConfigPath,
            fm: fm
        )
    }

    /// Merge our plugin registration into openclaw.json. Creates the file when
    /// missing; refuses to rewrite one that JSONSerialization can't parse.
    static func registerOpenclawPlugin(
        openclawPluginDir: String,
        openclawConfigPath: String,
        fm: FileManager
    ) -> Bool {
        var config: [String: Any] = [:]
        if let data = fm.contents(atPath: openclawConfigPath), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return false  // JSON5 / unparseable — hands off (#89)
            }
            config = parsed
        }

        var plugins = config["plugins"] as? [String: Any] ?? [:]
        var load = plugins["load"] as? [String: Any] ?? [:]
        var paths = load["paths"] as? [Any] ?? []
        if !paths.contains(where: { ($0 as? String) == openclawPluginDir }) {
            paths.append(openclawPluginDir)
        }
        load["paths"] = paths
        plugins["load"] = load

        var entries = plugins["entries"] as? [String: Any] ?? [:]
        var entry = entries["codeisland"] as? [String: Any] ?? [:]
        entry["enabled"] = true
        entries["codeisland"] = entry
        plugins["entries"] = entries
        config["plugins"] = plugins

        guard let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return fm.createFile(atPath: openclawConfigPath, contents: out)
    }

    static func uninstallOpenclawPlugin(
        openclawPluginDir: String = openclawPluginDir,
        openclawConfigPath: String = openclawConfigPath,
        fm: FileManager
    ) {
        // Remove only our plugin pack, never other extensions.
        if fm.fileExists(atPath: openclawPluginDir + "/index.ts"),
           let data = fm.contents(atPath: openclawPluginDir + "/index.ts"),
           String(data: data, encoding: .utf8)?.contains("CodeIsland OpenClaw plugin") == true {
            try? fm.removeItem(atPath: openclawPluginDir)
        }

        // De-register from a parseable config; leave JSON5 configs untouched.
        guard let data = fm.contents(atPath: openclawConfigPath),
              var config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var plugins = config["plugins"] as? [String: Any] else { return }

        if var load = plugins["load"] as? [String: Any], var paths = load["paths"] as? [Any] {
            paths.removeAll { ($0 as? String) == openclawPluginDir }
            load["paths"] = paths
            plugins["load"] = load
        }
        if var entries = plugins["entries"] as? [String: Any] {
            entries.removeValue(forKey: "codeisland")
            plugins["entries"] = entries
        }
        config["plugins"] = plugins
        if let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) {
            fm.createFile(atPath: openclawConfigPath, contents: out)
        }
    }

    static func isOpenclawPluginInstalled(
        openclawPluginDir: String = openclawPluginDir,
        fm: FileManager
    ) -> Bool {
        guard let data = fm.contents(atPath: openclawPluginDir + "/index.ts"),
              let content = String(data: data, encoding: .utf8) else { return false }
        return content.contains("CodeIsland OpenClaw plugin")
            && content.contains("// version: \(openclawPluginVersion)")
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

        // Pick the registration target. Order: .jsonc (OpenCode-recommended)
        // when present, else .json. We never create .json when the user
        // already has .jsonc — see issue #132.
        let pluginRef = "file://\(opencodePluginPath)"
        let targetPath: String = fm.fileExists(atPath: opencodeConfigPathJsonc)
            ? opencodeConfigPathJsonc
            : opencodeConfigPathNew
        let originalContents: String? = fm.contents(atPath: targetPath)
            .flatMap { String(data: $0, encoding: .utf8) }

        guard let merged = mergeOpencodePluginRef(
            originalContents: originalContents,
            pluginRef: pluginRef,
            identifier: HookId.current
        ) else {
            // Existing config is unparseable — refuse to overwrite user data.
            // Plugin JS is staged; the config file stays untouched until the user fixes it.
            return false
        }

        if let original = originalContents, !original.isEmpty {
            backupOpencodeConfig(at: targetPath, original: original, fm: fm)
        }
        fm.createFile(atPath: targetPath, contents: Data(merged.utf8))

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
        for configPath in [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath] {
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
    /// (the MiMo Code copy is the same file, so it follows this too).
    private static let opencodePluginVersion = "v9"

    private static func isOpencodePluginInstalled(fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: opencodePluginPath) else { return false }
        // If any config file exists but is unparseable, treat plugin as installed
        // to avoid a repair loop that would clobber the user's JSON (#89).
        for configPath in [opencodeConfigPathJsonc, opencodeConfigPathNew, opencodeConfigPath] {
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

    // MARK: - MiMo Code plugin

    /// MiMo Code's global config dir. Xiaomi MiMo desktop runs MiMo Code in its
    /// main process with no `MIMOCODE_HOME` / `XDG_CONFIG_HOME` of its own, so
    /// the app and the `mimo` CLI read the same one.
    static let mimoConfigDir = NSHomeDirectory() + "/.config/mimocode"
    /// Where the curl installer puts the `mimo` CLI (`~/.mimocode/bin/mimo`).
    private static let mimoInstallDir = NSHomeDirectory() + "/.mimocode"
    static let mimoDesktopBundleIds = ["com.xiaomi.mimo.desktop", "com.xiaomi.mimo.desktop-ai"]

    static func mimoPluginPath(configDir: String = mimoConfigDir) -> String {
        configDir + "/plugins/codeisland.js"
    }

    /// The line `mimoPluginSource(from:)` rewrites.
    static let mimoPluginSourceMarker = #"const SOURCE = "opencode";"#
    static let mimoPluginSourceLine = #"const SOURCE = "mimo";"#

    /// The OpenCode plugin, re-labelled for MiMo Code. MiMo Code kept OpenCode
    /// 1.x's plugin contract — `server()` entrypoint, `{type, properties}` bus
    /// events, `/permission|question/:requestID/reply` — so only the identity
    /// the events carry changes. nil when the marker is not there exactly once,
    /// rather than shipping a copy that would report as OpenCode.
    static func mimoPluginSource(from opencodeSource: String) -> String? {
        guard opencodeSource.components(separatedBy: mimoPluginSourceMarker).count == 2 else { return nil }
        return opencodeSource.replacingOccurrences(of: mimoPluginSourceMarker, with: mimoPluginSourceLine)
    }

    /// MiMo Code or Xiaomi MiMo is on this machine: its config dir exists, the
    /// CLI's install dir does, or either desktop edition is installed (the app
    /// only creates the config dir the first time its engine starts, and loads
    /// plugins at that very start).
    static func mimoPresenceDetected(fileManager fm: FileManager = .default) -> Bool {
        if fm.fileExists(atPath: mimoConfigDir) || fm.fileExists(atPath: mimoInstallDir) { return true }
        let appNames = ["Xiaomi MiMo.app", "Xiaomi MiMo AI.app"]
        let roots = ["/Applications", NSHomeDirectory() + "/Applications"]
        if appNames.contains(where: { name in roots.contains { fm.fileExists(atPath: "\($0)/\(name)") } }) {
            return true
        }
        return mimoDesktopBundleIds.contains {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    }

    /// Writes the plugin to `<configDir>/plugins/codeisland.js`. MiMo Code
    /// loads every `{plugin,plugins}/*.{js,ts}` under its config dir on its
    /// own, so — unlike OpenCode — no config file is touched. Skips (and
    /// reports success) when MiMo is not on this machine; fails rather than
    /// overwrite someone else's plugin of the same name.
    @discardableResult
    static func installMimoPlugin(
        fm: FileManager,
        configDir: String = mimoConfigDir,
        present: Bool? = nil
    ) -> Bool {
        guard present ?? mimoPresenceDetected(fileManager: fm) else { return true }
        guard let base = opencodePluginSource(), let source = mimoPluginSource(from: base) else { return false }
        let path = mimoPluginPath(configDir: configDir)
        if let existing = fm.contents(atPath: path), !isOwnMimoPluginFile(existing) { return false }
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return fm.createFile(atPath: path, contents: Data(source.utf8))
    }

    static func uninstallMimoPlugin(fm: FileManager, configDir: String = mimoConfigDir) {
        let path = mimoPluginPath(configDir: configDir)
        guard let data = fm.contents(atPath: path), isOwnMimoPluginFile(data) else { return }
        try? fm.removeItem(atPath: path)
    }

    /// `codeisland.js` is a generic enough name for a user's own plugin, so
    /// install and uninstall only touch a copy of ours (any version, either
    /// label) or an empty file.
    private static func isOwnMimoPluginFile(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("codeisland-opencode-plugin")
            || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Installed = the current version of our plugin, labelled for MiMo.
    static func isMimoPluginInstalled(fm: FileManager, configDir: String = mimoConfigDir) -> Bool {
        guard let data = fm.contents(atPath: mimoPluginPath(configDir: configDir)) else { return false }
        let source = String(decoding: data, as: UTF8.self)
        return source.contains("// version: \(opencodePluginVersion)")
            && source.contains(mimoPluginSourceLine)
    }
}

// MARK: - Extra config directories (Settings → Hooks)

/// Hook state of one registered extra config root, for the Hooks page.
struct ExtraConfigDirStatus: Identifiable, Equatable {
    let dir: ExtraConfigDir
    /// Whether the root is still there and still looks like the CLI's.
    let inspection: ConfigDirInspection
    let hooksInstalled: Bool
    /// The CLI's master switch (`cli_enabled_<source>`) — off pauses every root.
    let sourceEnabled: Bool
    /// The file the hooks live in, e.g. `~/.claude-work/settings.json`.
    let displayConfigPath: String
    let fullConfigPath: String
    /// The directory *is* the CLI's primary root under another spelling (the
    /// primary moved onto it, or a symlink). Nothing is managed through it.
    var sameAsPrimary: Bool = false
    /// Root whose hooks file is the very same file as this one's (a shared,
    /// symlinked `settings.json`, a linked Grok `hooks/`): the primary, or an
    /// extra root registered earlier. The hooks are managed through that root.
    var sharedHooksWith: String? = nil

    var id: String { dir.id }
}

enum ExtraConfigDirInstallOutcome: Equatable {
    case installed
    /// Nothing written; the inspection says why (missing, not the CLI's, …).
    case skipped(ConfigDirInspection)
    /// Nothing written: the hooks file is the same file on disk as that of
    /// the root given (the primary, or an extra root registered earlier),
    /// which gets the hooks itself.
    case shared(with: String)
    /// Registered, but the CLI's master switch is off — installed once it is on.
    case sourceDisabled
    /// The config file could not be written (e.g. unparseable JSON, #89 guard).
    case failed
}

extension ConfigInstaller {
    /// Primary `$CODEX_HOME` followed by the enabled extra Codex roots.
    static func codexHomes() -> [String] {
        ExtraConfigDirs.roots(primary: codexHome(), extras: ExtraConfigDirs.enabledPaths(for: .codex))
    }

    /// Primary `$GROK_HOME` followed by the enabled extra Grok roots.
    static func grokHomes() -> [String] {
        ExtraConfigDirs.roots(primary: grokHome(), extras: ExtraConfigDirs.enabledPaths(for: .grok))
    }

    static func primaryConfigRoot(for cli: ConfigDirCLI) -> String {
        switch cli {
        case .claude: return ClaudeConfigPaths.configDir()
        case .codex: return codexHome()
        case .grok: return grokHome()
        }
    }

    /// The built-in Claude / Codex / Grok entry, re-rooted at an extra root.
    ///
    /// Everything else — events, hook format, bridge source — is the built-in
    /// entry's, so the same install / detect / uninstall code serves every root
    /// and events from it arrive as ordinary Claude / Codex / Grok sessions.
    /// (A *custom CLI* is the other extension point, and the wrong one here: it
    /// registers a new source, so those sessions would not be Claude/Codex/Grok
    /// sessions at all — no transcripts, no usage, no Codex config.toml flag.)
    static func extraConfigDirCLI(for dir: ExtraConfigDir) -> CLIConfig? {
        guard var cli = builtInCLIs.first(where: { $0.source == dir.cli.source }) else { return nil }
        let root = dir.path
        let configPath = cli.configPath
        cli.rootOverride = { root }
        cli.displayPathOverride = { ClaudeConfigPaths.displayPath(root + "/" + configPath) }
        cli.extraConfigDir = root
        return cli
    }

    /// Hook entries for the registered extra roots. A root that is currently
    /// the CLI's primary root under another spelling is left out: its hooks
    /// are the primary's, and installing or removing them through the extra
    /// entry would act on the primary behind its own switch.
    static func extraConfigDirCLIs(
        in dirs: [ExtraConfigDir] = ExtraConfigDirs.load(),
        includeDisabled: Bool = false,
        primaryRoot: (ConfigDirCLI) -> String = primaryConfigRoot(for:)
    ) -> [CLIConfig] {
        dirs.filter { includeDisabled || $0.enabled }
            .filter { !ExtraConfigDirs.isSameDirectory($0.path, as: primaryRoot($0.cli)) }
            .compactMap(extraConfigDirCLI(for:))
    }

    /// Enabled extra roots of `cli` registered before `root` — when two roots
    /// share a hooks file, the earlier one manages it, so exactly one writes.
    static func earlierEnabledPeers(of root: String, cli: ConfigDirCLI, in dirs: [ExtraConfigDir]) -> [String] {
        let mine = dirs.filter { $0.cli == cli }
        let index = mine.firstIndex { $0.path == root } ?? mine.endIndex
        return mine[..<index].filter(\.enabled).map(\.path)
    }

    /// Install hooks into one extra root. Unlike the primary root, the directory
    /// is never created: one that has gone missing, or no longer looks like the
    /// CLI's root, is reported through `.skipped` instead of being written into.
    /// A hooks file that is the same file as the primary's (or an earlier
    /// root's) is left to that root — `.shared`. `primaryRoot` / `peers`
    /// default to the live configuration. Does not touch the shared hook
    /// script / bridge binary — callers do.
    @discardableResult
    static func installHooks(
        inExtraDir cli: CLIConfig,
        fm: FileManager,
        probe: (String) -> ConfigDirEntryKind = ConfigDirEntryKind.probe,
        primaryRoot: String? = nil,
        peers: [String]? = nil
    ) -> ExtraConfigDirInstallOutcome {
        guard let root = cli.extraConfigDir, let kind = ConfigDirCLI(rawValue: cli.source) else { return .failed }
        let inspection = ExtraConfigDirs.inspect(path: root, cli: kind, probe: probe)
        guard inspection == .ready else { return .skipped(inspection) }
        let primary = primaryRoot ?? primaryConfigRoot(for: kind)
        let others = peers ?? earlierEnabledPeers(of: root, cli: kind, in: ExtraConfigDirs.load())
        let hooksOwner = ExtraConfigDirs.sharedFileOwner(cli.configPath, root: root, primary: primary, peers: others)

        let ok: Bool
        switch kind {
        case .claude:
            if let hooksOwner { return .shared(with: hooksOwner) }
            ok = installClaudeHooks(cli: cli, fm: fm)
        case .codex:
            // Without `hooks = true` in *this* root's config.toml, Codex started
            // with CODEX_HOME=<root> never reads the hooks.json beside it — even
            // when that hooks.json is a shared one.
            if let hooksOwner {
                return enableCodexFeatureFlag(inExtraRoot: root, primaryRoot: primary, peers: others, fm: fm)
                    ? .shared(with: hooksOwner) : .failed
            }
            ok = installExternalHooks(cli: cli, fm: fm)
                && enableCodexFeatureFlag(inExtraRoot: root, primaryRoot: primary, peers: others, fm: fm)
        case .grok:
            if let hooksOwner { return .shared(with: hooksOwner) }
            ok = installExternalHooks(cli: cli, fm: fm)
        }
        return ok ? .installed : .failed
    }

    /// `hooks = true` in an extra Codex root's config.toml — unless that
    /// config.toml is the primary's (or an earlier root's) file, which its
    /// owner flags itself.
    @discardableResult
    static func enableCodexFeatureFlag(
        inExtraRoot root: String,
        primaryRoot: String,
        peers: [String],
        fm: FileManager
    ) -> Bool {
        if ExtraConfigDirs.sharedFileOwner("config.toml", root: root, primary: primaryRoot, peers: peers) != nil {
            return true
        }
        return enableCodexHooksConfig(fm: fm, codexHome: root)
    }

    /// Take CodeIsland's hooks out of one extra root — unless its hooks file
    /// is the same file as the primary root's or one of `peers` (roots that
    /// stay hooked), whose hooks would go with it. Returns whether anything
    /// was touched. The user's own entries always stay.
    @discardableResult
    static func uninstallHooks(
        inExtraDir cli: CLIConfig,
        fm: FileManager,
        primaryRoot: String,
        keeping peers: [String]
    ) -> Bool {
        guard let root = cli.extraConfigDir else { return false }
        if ExtraConfigDirs.sharedFileOwner(cli.configPath, root: root, primary: primaryRoot, peers: peers) != nil {
            return false
        }
        uninstallHooks(cli: cli, fm: fm)
        return true
    }

    /// Hook state of one extra root for the Hooks page.
    static func extraConfigDirStatus(
        for dir: ExtraConfigDir,
        in dirs: [ExtraConfigDir]? = nil,
        fm: FileManager = .default,
        probe: (String) -> ConfigDirEntryKind = ConfigDirEntryKind.probe,
        primaryRoot: String? = nil
    ) -> ExtraConfigDirStatus? {
        guard let cli = extraConfigDirCLI(for: dir) else { return nil }
        let inspection = ExtraConfigDirs.inspect(path: dir.path, cli: dir.cli, probe: probe)
        let primary = primaryRoot ?? primaryConfigRoot(for: dir.cli)
        let sameAsPrimary = ExtraConfigDirs.isSameDirectory(dir.path, as: primary)
        let sharedHooksWith = sameAsPrimary ? primary : ExtraConfigDirs.sharedFileOwner(
            cli.configPath,
            root: dir.path,
            primary: primary,
            peers: earlierEnabledPeers(of: dir.path, cli: dir.cli, in: dirs ?? ExtraConfigDirs.load())
        )
        return ExtraConfigDirStatus(
            dir: dir,
            inspection: inspection,
            hooksInstalled: inspection == .ready && isHooksInstalled(for: cli, fm: fm),
            sourceEnabled: isEnabled(source: dir.cli.source),
            displayConfigPath: cli.displayConfigPath,
            fullConfigPath: cli.fullPath,
            sameAsPrimary: sameAsPrimary,
            sharedHooksWith: sharedHooksWith
        )
    }

    static func extraConfigDirStatuses() -> [ExtraConfigDirStatus] {
        let dirs = ExtraConfigDirs.load()
        return dirs.compactMap { extraConfigDirStatus(for: $0, in: dirs) }
    }

    /// Register a root typed or picked in Settings and, if its CLI is being
    /// monitored, install the hooks right away.
    static func addExtraConfigDir(
        cli: ConfigDirCLI,
        rawPath: String
    ) -> Result<(dir: ExtraConfigDir, outcome: ExtraConfigDirInstallOutcome), ExtraConfigDirError> {
        var dirs = ExtraConfigDirs.load()
        let validated = ExtraConfigDirs.validateNew(
            rawPath: rawPath,
            cli: cli,
            primary: primaryConfigRoot(for: cli),
            existing: dirs,
            homeDir: NSHomeDirectory()
        )
        switch validated {
        case .failure(let error):
            return .failure(error)
        case .success(let dir):
            dirs.append(dir)
            ExtraConfigDirs.save(dirs)
            return .success((dir, installRegisteredExtraDir(dir, in: dirs)))
        }
    }

    /// Forget a root and take CodeIsland's hooks out of it (user entries stay)
    /// — unless its hooks file is the primary's or a still-enabled root's.
    @discardableResult
    static func removeExtraConfigDir(
        id: String,
        defaults: UserDefaults = .standard,
        primaryRoot: (ConfigDirCLI) -> String = primaryConfigRoot(for:)
    ) -> ExtraConfigDir? {
        var dirs = ExtraConfigDirs.load(from: defaults)
        guard let index = dirs.firstIndex(where: { $0.id == id }) else { return nil }
        let dir = dirs.remove(at: index)
        if let cli = extraConfigDirCLI(for: dir) {
            uninstallHooks(
                inExtraDir: cli,
                fm: .default,
                primaryRoot: primaryRoot(dir.cli),
                keeping: ExtraConfigDirs.enabledPaths(for: dir.cli, in: dirs)
            )
        }
        ExtraConfigDirs.save(dirs, to: defaults)
        return dir
    }

    /// Per-root monitoring switch: installs or removes that root's hooks only
    /// — never those of a hooks file it shares with the primary or another
    /// enabled root.
    @discardableResult
    static func setExtraConfigDirEnabled(
        id: String,
        enabled: Bool,
        defaults: UserDefaults = .standard,
        primaryRoot: (ConfigDirCLI) -> String = primaryConfigRoot(for:)
    ) -> ExtraConfigDirInstallOutcome? {
        var dirs = ExtraConfigDirs.load(from: defaults)
        guard let index = dirs.firstIndex(where: { $0.id == id }) else { return nil }
        dirs[index].enabled = enabled
        ExtraConfigDirs.save(dirs, to: defaults)
        let dir = dirs[index]
        if enabled { return installRegisteredExtraDir(dir, in: dirs, primaryRoot: primaryRoot(dir.cli)) }
        if let cli = extraConfigDirCLI(for: dir) {
            uninstallHooks(
                inExtraDir: cli,
                fm: .default,
                primaryRoot: primaryRoot(dir.cli),
                keeping: dirs.filter { $0.cli == dir.cli && $0.enabled && $0.id != dir.id }.map(\.path)
            )
        }
        return nil
    }

    private static func installRegisteredExtraDir(
        _ dir: ExtraConfigDir,
        in dirs: [ExtraConfigDir],
        primaryRoot: String? = nil
    ) -> ExtraConfigDirInstallOutcome {
        guard isEnabled(source: dir.cli.source) else { return .sourceDisabled }
        guard let cli = extraConfigDirCLI(for: dir) else { return .failed }
        let primary = primaryRoot ?? primaryConfigRoot(for: dir.cli)
        // The primary itself under another spelling: its own entry installs.
        if ExtraConfigDirs.isSameDirectory(dir.path, as: primary) { return .shared(with: primary) }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: codeislandDir, withIntermediateDirectories: true)
        installHookScript(fm: fm)
        installBridgeBinary(fm: fm)
        return installHooks(
            inExtraDir: cli,
            fm: fm,
            primaryRoot: primary,
            peers: earlierEnabledPeers(of: dir.path, cli: dir.cli, in: dirs)
        )
    }

    /// The master switch of Claude / Codex / Grok covers their extra roots too:
    /// turning it on installs into every enabled root, off removes from all.
    /// A hooks file shared with the primary is left to the primary's own
    /// entry, which the same switch installs into or removes from next.
    static func applySourceToggleToExtraConfigDirs(source: String, enabled: Bool, fm: FileManager) {
        guard let kind = ConfigDirCLI(rawValue: source) else { return }
        let dirs = ExtraConfigDirs.load().filter { $0.cli == kind }
        let primary = primaryConfigRoot(for: kind)
        for cli in extraConfigDirCLIs(in: dirs, includeDisabled: !enabled) {
            guard let root = cli.extraConfigDir else { continue }
            if enabled {
                installHooks(
                    inExtraDir: cli,
                    fm: fm,
                    primaryRoot: primary,
                    peers: earlierEnabledPeers(of: root, cli: kind, in: dirs)
                )
            } else {
                // Every root goes off together, so no peer keeps its hooks.
                uninstallHooks(inExtraDir: cli, fm: fm, primaryRoot: primary, keeping: [])
            }
        }
    }

    /// `verifyAndRepair` for extra roots: put back hooks that went missing in a
    /// root that is still there, with the same respect for hand-pruned events
    /// (#182) as the primary root. A hooks file shared with the primary (or an
    /// earlier root) is repaired through that root. Returns labels of the
    /// repaired roots.
    static func repairExtraConfigDirs(fm: FileManager) -> [String] {
        let dirs = ExtraConfigDirs.load()
        var repaired: [String] = []
        for cli in extraConfigDirCLIs(in: dirs) where isEnabled(source: cli.source) {
            guard let root = cli.extraConfigDir,
                  let kind = ConfigDirCLI(rawValue: cli.source),
                  ExtraConfigDirs.inspect(path: root, cli: kind) == .ready else { continue }
            let primary = primaryConfigRoot(for: kind)
            let peers = earlierEnabledPeers(of: root, cli: kind, in: dirs)
            if kind == .codex { enableCodexFeatureFlag(inExtraRoot: root, primaryRoot: primary, peers: peers, fm: fm) }
            if ExtraConfigDirs.sharedFileOwner(cli.configPath, root: root, primary: primary, peers: peers) != nil { continue }
            if isHooksInstalled(for: cli, fm: fm) { continue }
            if shouldPreservePartialHooks(for: cli, fm: fm) { continue }
            if installHooks(inExtraDir: cli, fm: fm, primaryRoot: primary, peers: peers) == .installed {
                repaired.append("\(cli.name) (\(ClaudeConfigPaths.displayPath(root)))")
            }
        }
        return repaired
    }
}
