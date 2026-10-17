import Foundation

/// Shared observational protocol for CatPaw IDE and IDEKit.
public enum CatPawHookPayload {
    public static func isSource(_ source: String?) -> Bool {
        source == "catpaw" || source == "catpaw-idekit"
    }

    /// An ancestor must be IDEA's main executable AND identify itself as IDEA.
    /// Helpers, arbitrary Java processes and other JetBrains products are excluded.
    public static func isIDEKitHost(executablePath: String?, bundleIdentifier: String?) -> Bool {
        guard let path = executablePath?.lowercased(),
              let bundle = bundleIdentifier?.lowercased() else { return false }
        return path.hasSuffix(".app/contents/macos/idea")
            && (bundle == "com.jetbrains.intellij" || bundle.hasPrefix("com.jetbrains.intellij."))
    }

    public static let events = [
        "beforeSubmitPrompt", "beforeShellExecution", "afterShellExecution",
        "beforeMCPExecution", "afterMCPExecution", "afterAgentResponse", "stop",
    ]

    public static func normalized(_ raw: [String: Any], source: String = "catpaw") -> [String: Any]? {
        guard isSource(source),
              let event = raw["hook_event_name"] as? String,
              events.contains(event),
              let id = raw["conversation_id"] as? String,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Start from metadata, never from the complete provider payload. Unknown
        // future content fields must not silently reintroduce full-text transport.
        let metadata: Set<String> = ["conversation_id", "suggest_uuid", "model", "agent_name",
            "is_sub_agent", "catpaw_version", "workspace_roots", "cwd", "status", "loop_count", "duration"]
        var result = raw.filter { metadata.contains($0.key) }
        // Preserve trusted transport context when an already-enriched event is
        // sanitized again inside the app. Provider content is never copied.
        for key in ["_ppid", "_term_bundle", "_remote_host_id"] {
            result[key] = raw[key]
        }
        result["_source"] = source
        result["session_id"] = "\(source):\(id)"
        result["hook_event_name"] = event
        // suggest_uuid identifies a model request, never a tool invocation.
        let child = raw["is_sub_agent"] as? Bool == true
        switch event {
        case "beforeSubmitPrompt":
            if !child { result["prompt"] = preview(raw["prompt"] as? String) }
        case "beforeShellExecution", "afterShellExecution":
            result["tool_name"] = "Bash"
            if !child {
                let command = preview(raw["command"] as? String) ?? ""
                result["command"] = command
                result["tool_input"] = ["command": command]
            }
        case "beforeMCPExecution", "afterMCPExecution":
            // Tool name is enough to indicate activity. Do not deserialize or
            // forward arbitrary parameter/result trees, URLs or attachments.
            if !child { result["tool_name"] = raw["tool_name"] as? String }
        case "stop":
            result["hook_event_name"] = "CatPawStop"
        case "afterAgentResponse":
            result["hook_event_name"] = "CatPawResponse"
            if !child { result["text"] = preview(raw["text"] as? String) }
        default: break
        }
        if result["cwd"] == nil, let roots = raw["workspace_roots"] as? [String] {
            result["cwd"] = roots.first(where: { !$0.isEmpty })
        }
        return result
    }

    /// Unicode Character boundaries, with bounded work on long replies.
    /// Already shortened previews remain unchanged on save/restore.
    public static func preview(_ text: String?) -> String? {
        guard let text else { return nil }
        let sample = text.prefix(31)
        return sample.count > 30 ? String(sample.prefix(30)) + "…" : text
    }

}
