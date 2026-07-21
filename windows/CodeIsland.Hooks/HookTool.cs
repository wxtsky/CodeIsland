using CodeIsland.Core;

namespace CodeIsland.Hooks;

public sealed record HookTool(
    AgentKind Agent,
    string DisplayName,
    IReadOnlyList<string> ExecutableNames,
    IReadOnlyList<string> ConfigPaths,
    string HookMarker,
    IReadOnlyList<string> Events,
    HookConfigurationFormat Format,
    int CommandTimeout,
    string? SourceTag = null);

public enum HookConfigurationFormat { Claude, EventMap, Cursor }

public sealed record ToolInstallation(
    HookTool Tool,
    string? ExecutablePath,
    string? ConfigPath,
    bool HookInstalled,
    bool IsHealthy,
    string? Problem);

public static class KnownTools
{
    public static IReadOnlyList<HookTool> All { get; } =
    [
        new(AgentKind.Claude, "Claude Code", ["claude.exe", "claude.cmd", "claude"],
            [@".claude\settings.json", @".claude.json"], "codeisland-claude",
            ["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"], HookConfigurationFormat.Claude, 5),
        new(AgentKind.Codex, "Codex", ["codex.exe", "codex.cmd", "codex"],
            [@".codex\hooks.json", @".codex\config.json"], "codeisland-codex",
            ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"],
            HookConfigurationFormat.EventMap, 5),
        new(AgentKind.Gemini, "Gemini CLI", ["gemini.exe", "gemini.cmd", "gemini"],
            [@".gemini\settings.json", @".gemini\hooks.json"], "codeisland-gemini",
            ["SessionStart", "BeforeTool", "AfterTool", "Notification", "SessionEnd"], HookConfigurationFormat.EventMap, 10000),
        new(AgentKind.Cursor, "Cursor", ["Cursor.exe", "cursor.exe", "cursor.cmd"],
            [@".cursor\hooks.json"], "codeisland-cursor",
            ["sessionStart", "preToolUse", "postToolUse", "sessionEnd"], HookConfigurationFormat.Cursor, 5),
        new(AgentKind.Qoder, "Qoder", ["Qoder.exe", "qoder.exe", "qoder.cmd"],
            [@".qoder\settings.json"], "codeisland-qoder",
            ["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"], HookConfigurationFormat.Claude, 5),
        new(AgentKind.Factory, "Factory Droid", ["droid.exe", "droid.cmd", "droid"],
            [@".factory\settings.json"], "codeisland-droid",
            ["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"], HookConfigurationFormat.Claude, 5, "droid"),
        new(AgentKind.CodeBuddy, "CodeBuddy", ["CodeBuddy.exe", "codebuddy.exe", "codebuddy.cmd"],
            [@".codebuddy\settings.json"], "codeisland-codebuddy",
            ["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop"], HookConfigurationFormat.Claude, 5),
        new(AgentKind.Copilot, "GitHub Copilot CLI", ["copilot.exe", "copilot.cmd", "copilot"],
            [@".copilot\hooks\codeisland.json"], "codeisland-copilot",
            ["sessionStart", "preToolUse", "postToolUse", "sessionEnd"], HookConfigurationFormat.EventMap, 5)
    ];

    public static int TimeoutFor(HookTool tool, string eventName) =>
        tool.Agent == AgentKind.Codex && eventName == "PermissionRequest" ? 86400 : tool.CommandTimeout;
}
