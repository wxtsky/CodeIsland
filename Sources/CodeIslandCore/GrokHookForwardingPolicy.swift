import Foundation

/// Keeps CodeIsland's dedicated Grok hook while suppressing duplicate hooks
/// imported by Grok from Claude Code and Cursor configurations.
public enum GrokHookForwardingPolicy {
    /// Hook events installed in `$GROK_HOME/hooks/codeisland.json`.
    public static let managedHookEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionDenied",
        "Stop",
        "StopFailure",
        "Notification",
        "SubagentStart",
        "SubagentStop",
        "PreCompact",
        "PostCompact",
        "SessionEnd",
    ]

    /// Grok sets at least one of these variables for hook subprocesses.
    /// Whitespace-only values are treated as absent.
    public static func isGrokRuntime(environment: [String: String]) -> Bool {
        isNonEmpty(environment["GROK_SESSION_ID"])
            || isNonEmpty(environment["GROK_HOOK_EVENT"])
    }

    /// Outside Grok, all existing hook sources keep their original behavior.
    /// Inside Grok, only CodeIsland's explicitly managed `--source grok` hook
    /// is forwarded; imported Claude/Cursor hooks are duplicate deliveries.
    public static func shouldForward(
        source: String?,
        environment: [String: String]
    ) -> Bool {
        !isGrokRuntime(environment: environment) || source == "grok"
    }

    private static func isNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
