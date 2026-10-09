import Foundation

/// Hermes Agent's shell-hook payload. Every event arrives as
/// `{hook_event_name, tool_name, tool_input, session_id, cwd, profile, extra}`,
/// with all event-specific fields under `extra` (agent/shell_hooks.py):
///
/// - `pre_llm_call` (turn start): `user_message`, `conversation_history`, `model`, `platform`, …
/// - `post_llm_call` (turn end, when there is a reply): `user_message`, `assistant_response`,
///   `conversation_history`, `model`, `platform`
/// - `on_session_end` (end of every turn, whatever the outcome): `completed`, `failed`,
///   `interrupted`, `model`, `platform`
/// - `on_session_start` (first turn of a new session): `model`, `platform`
/// - `on_session_finalize` (the session really ends: `/new`, quitting the CLI,
///   closing a desktop / TUI session, the gateway's `/new` or shutdown): `platform`, `reason`
public enum HermesHookPayload {
    /// `extra` keys nothing in CodeIsland reads that grow with the conversation:
    /// `conversation_history` is the whole transcript, sent again on every
    /// pre/post_llm_call.
    static let unforwardedExtraKeys: Set<String> = ["conversation_history"]

    /// The payload as the bridge forwards it. Without the transcript copy a
    /// long Hermes session's turn-boundary hooks stay a few hundred bytes
    /// instead of megabytes that the island would parse on its main thread.
    public static func trimmedForForwarding(_ json: [String: Any]) -> [String: Any] {
        guard var extra = json["extra"] as? [String: Any],
              !unforwardedExtraKeys.isDisjoint(with: extra.keys) else { return json }
        for key in unforwardedExtraKeys { extra.removeValue(forKey: key) }
        var trimmed = json
        trimmed["extra"] = extra
        return trimmed
    }

    /// The model a Hermes hook reports (`extra.model`).
    public static func model(in rawJSON: [String: Any]) -> String? {
        guard let model = extra(rawJSON)?["model"] as? String,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return model
    }

    /// `on_session_end` of a turn the user stopped (or quit Hermes during).
    static func endsInterruptedTurn(_ event: HookEvent) -> Bool {
        event.eventName == "on_session_end" && extra(event.rawJSON)?["interrupted"] as? Bool == true
    }

    /// Platforms whose session is a single turn under its own id: a
    /// `delegate_task` child (tools/delegate_tool.py), a scheduled job's run
    /// (`cron_<job>_<time>`, cron/scheduler.py) and a skill-curation pass
    /// (agent/curator.py).
    static let oneShotPlatforms: Set<String> = ["subagent", "cron", "curator"]

    /// `on_session_end` of a one-shot run: the end of its only turn is the end
    /// of its card, with no completion for a conversation nobody is in.
    static func endsOneShotRun(_ event: HookEvent) -> Bool {
        guard event.eventName == "on_session_end", let platform = platform(of: event) else { return false }
        return oneShotPlatforms.contains(platform)
    }

    /// Platforms where someone is driving Hermes at this Mac: the CLI (also
    /// what the gateway's local adapter reports), the TUI and the desktop
    /// app's terminal pane (`tui`), the desktop app's chat (`desktop`;
    /// tui_gateway/server.py `_resolve_session_platform`) and an editor over
    /// ACP. Every other value is a conversation held somewhere else — a
    /// messaging gateway (Telegram, Discord, Slack, WhatsApp, Signal, email,
    /// …: gateway/config.py `Platform`, plus plugin platforms), the API
    /// server, a webhook — or a background run (`oneShotPlatforms`).
    static let localPlatforms: Set<String> = ["cli", "tui", "desktop", "acp"]

    /// Hooks that carry `extra.platform`. Tool hooks don't.
    private static let platformHooks: Set<String> = [
        "on_session_start", "pre_llm_call", "post_llm_call", "on_session_end",
    ]

    /// The platform a Hermes turn hook names, or nil when it names none (a
    /// tool hook, or an empty value).
    static func platform(of event: HookEvent) -> String? {
        guard platformHooks.contains(event.eventName),
              let platform = extra(event.rawJSON)?["platform"] as? String else { return nil }
        let normalized = platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// A hook from a conversation nobody is having at this Mac: a gateway
    /// chat, the API server, a background run. Its card follows along, but it
    /// plays no sound and pops no completion — a bot answering on Telegram
    /// isn't news at the desk (#364). A hook that names no platform is local.
    public static func isQuiet(_ event: HookEvent) -> Bool {
        guard let platform = platform(of: event) else { return false }
        return !localPlatforms.contains(platform)
    }

    private static func extra(_ rawJSON: [String: Any]) -> [String: Any]? {
        rawJSON["extra"] as? [String: Any]
    }
}
