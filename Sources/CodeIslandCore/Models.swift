import Foundation

public enum CLIProcessResolver {
    public static func sourceMatchesExecutablePath(_ path: String, source: String?) -> Bool {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(source) else { return false }
        let lowercasedPath = path.lowercased()

        switch normalizedSource {
        case "traecli":
            return lowercasedPath.hasSuffix("/coco")
                || lowercasedPath.hasSuffix("/traecli")
                || lowercasedPath.contains("/coco ")
                || lowercasedPath.contains("/traecli ")
        case "codex":
            return lowercasedPath.hasSuffix("/codex") || lowercasedPath.contains("/codex ")
        case "claude":
            return lowercasedPath.hasSuffix("/claude") || lowercasedPath.contains("/claude ")
        case "dsh":
            // DeepSeek Harness CLI ships a `dsh` binary. It has no shell hooks —
            // the dsh-island plugin forwards events over the socket directly.
            return lowercasedPath.hasSuffix("/dsh") || lowercasedPath.contains("/dsh ")
        case "qwen":
            return lowercasedPath.hasSuffix("/qwen")
                || lowercasedPath.hasSuffix("/qwen-code")
                || lowercasedPath.contains("/qwen ")
                || lowercasedPath.contains("/qwen-code ")
        case "gemini":
            return lowercasedPath.hasSuffix("/gemini") || lowercasedPath.contains("/gemini ")
        case "grok":
            // Managed Grok installs execute the versioned binary directly from
            // $GROK_HOME/downloads (e.g. grok-0.2.106-macos-aarch64), while
            // package-manager installs may expose a plain `.../bin/grok`.
            let basename = (lowercasedPath as NSString).lastPathComponent
            return basename == "grok"
                || (basename.hasPrefix("grok-")
                    && (lowercasedPath.contains("/.grok/downloads/")
                        || lowercasedPath.contains("/grok/downloads/")))
        case "cursor-cli":
            // Cursor's CLI agent installs to ~/.local/share/cursor-agent/versions/<v>/cursor-agent
            // and is also referenced by /cursor-agent/index.js when invoked via Node.
            return lowercasedPath.contains("/cursor-agent")
        case "qoder-cli":
            // npm @qoder-ai/qodercli installs as `qodercli` in PATH (Homebrew/npm-global).
            // The China build ships as a SEPARATE binary named `qoderclicn`, rooted at
            // ~/.qoder-cn instead of ~/.qoder, and its managed install execs a versioned
            // file (`qoderclicn-1.1.5`) rather than a bare name — so match the prefix,
            // not just the exact basename (#289).
            let basename = (lowercasedPath as NSString).lastPathComponent
            return lowercasedPath.hasSuffix("/qodercli")
                || lowercasedPath.contains("/qodercli ")
                || lowercasedPath.contains("/@qoder-ai/qodercli")
                || basename == "qoderclicn"
                || basename.hasPrefix("qoderclicn-")
                || lowercasedPath.contains("/qoderclicn/")
                || lowercasedPath.contains("/.qoder-cn/")
        case "google-antigravity":
            return lowercasedPath.hasSuffix("/agy")
                || lowercasedPath.contains("/agy ")
                || lowercasedPath.contains("/google-antigravity")
        default:
            return lowercasedPath.contains("/\(normalizedSource)")
        }
    }

    /// When the caller passed `--source cursor` or `--source qoder` but the
    /// process ancestry actually came from the CLI agent rather than the
    /// desktop IDE (both write to the same hooks file — see issue #134),
    /// promote the source to its `-cli` variant so CodeIsland renders it
    /// as "Cursor CLI" / "Qoder CLI" and routes terminal jumps correctly.
    public static func cliVariantOverride(
        declaredSource: String?,
        ancestry: [(pid: Int32, executablePath: String?)]
    ) -> String? {
        guard let normalized = SessionSnapshot.normalizedSupportedSource(declaredSource) else {
            return nil
        }
        switch normalized {
        case "cursor":
            if ancestry.contains(where: { sourceMatchesExecutablePath($0.executablePath ?? "", source: "cursor-cli") }) {
                return "cursor-cli"
            }
        case "qoder":
            if ancestry.contains(where: { sourceMatchesExecutablePath($0.executablePath ?? "", source: "qoder-cli") }) {
                return "qoder-cli"
            }
        default:
            break
        }
        return nil
    }

    public static func resolvedTrackedPID(
        immediateParentPID: Int32,
        source: String?,
        ancestry: [(pid: Int32, executablePath: String?)]
    ) -> Int32 {
        guard immediateParentPID > 0 else { return immediateParentPID }

        if let directMatch = ancestry.first(where: {
            sourceMatchesExecutablePath($0.executablePath ?? "", source: source)
        }) {
            return directMatch.pid
        }

        return immediateParentPID
    }

    /// Stable per-session PID for fallback session_id generation. Walks the
    /// ancestry from root downward and picks the *highest* binary matching
    /// the source, so sub-agent processes spawned by the same parent CLI
    /// (e.g. Cursor IDE running multiple parallel agent subprocesses, #148)
    /// collapse onto a single session card instead of fanning out into one
    /// card per sub-agent ppid.
    ///
    /// Falls back to `immediateParentPID` when no source-matching binary is
    /// in the ancestry — preserves prior behavior for everything else.
    public static func resolvedSessionPID(
        immediateParentPID: Int32,
        source: String?,
        ancestry: [(pid: Int32, executablePath: String?)]
    ) -> Int32 {
        guard immediateParentPID > 0 else { return immediateParentPID }

        if let rootMatch = ancestry.last(where: {
            sourceMatchesExecutablePath($0.executablePath ?? "", source: source)
        }) {
            return rootMatch.pid
        }

        return immediateParentPID
    }

    /// Walk the process ancestry and return the first known CLI source whose binary
    /// appears along the chain. Used when a hook event reaches the bridge without a
    /// `--source` tag (e.g. omo plugin firing Claude hooks from inside OpenCode), so
    /// we can recover the real source instead of letting the event default to Claude.
    public static func inferSource(ancestry: [(pid: Int32, executablePath: String?)]) -> String? {
        // Try `-cli` variants first so `cursor-agent` doesn't get mis-attributed
        // to the desktop `cursor` source (see issue #134).
        //
        // Exclude desktop-IDE *host* sources entirely: their GUI host/helper
        // processes appear in the ancestry of any CLI run from the IDE's
        // integrated terminal and would be greedily matched by the loose
        // `/<source>` substring rule, mis-attributing e.g. Claude Code run in
        // Cursor's terminal to "cursor". Desktop IDEs always report themselves
        // via `--source`, so they never need ancestry inference. (#220)
        let all = SessionSnapshot.supportedSources.subtracting(SessionSnapshot.ideHostSources)
        let cliFirst = all.filter { $0.hasSuffix("-cli") }.sorted()
            + all.filter { !$0.hasSuffix("-cli") }.sorted()
        for entry in ancestry {
            guard let path = entry.executablePath, !path.isEmpty else { continue }
            for source in cliFirst {
                if sourceMatchesExecutablePath(path, source: source) {
                    return source
                }
            }
        }
        return nil
    }
}

public enum AgentStatus: Sendable, Equatable {
    case idle
    case processing
    case running
    case waitingApproval
    case waitingQuestion
}

/// Stable activity groups used for compact status text. The raw tool name stays
/// on ``HookEvent`` for permission routing and provider-specific behavior.
public enum ToolActivityCategory: String, Sendable {
    case reading
    case searching
    case editing
    case shell
    case browser
    case mcp
    case delegation
    case question
    case other
}

public struct HookEvent {
    public let eventName: String
    public let sessionId: String?
    public let toolName: String?
    public let toolUseId: String?
    public let agentId: String?
    public let toolInput: [String: Any]?
    public let rawJSON: [String: Any]  // Full payload for event-specific fields

    public init?(from data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = HookEvent.firstString(in: json, keys: ["hook_event_name", "hookEventName", "event_name", "eventName"]) else {
            return nil
        }
        self.eventName = eventName
        let rawSessionId = HookEvent.firstString(in: json, keys: ["session_id", "sessionId"])
        if let rawSessionId,
           let remoteHostId = json["_remote_host_id"] as? String,
           !remoteHostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.sessionId = "remote:\(remoteHostId):\(rawSessionId)"
        } else if let rawSessionId,
                  (json["_source"] as? String)?.lowercased() == "codex",
                  json["_term_bundle"] as? String == "com.openai.codex" {
            // Codex Desktop hooks, app-server notifications, rollout discovery,
            // and state-DB polling must all address one card. Keep the provider's
            // raw id in rawJSON for title lookup and persisted providerSessionId.
            self.sessionId = rawSessionId.hasPrefix("codexapp:")
                ? rawSessionId
                : "codexapp:\(rawSessionId)"
        } else {
            self.sessionId = rawSessionId
        }
        self.toolName = HookEvent.firstString(in: json, keys: ["tool_name", "toolName", "tool", "name"])
            ?? HookEvent.firstString(inNestedDictionary: json, containerKeys: ["tool", "payload", "data"], keys: ["name", "tool_name", "toolName"])
            ?? HookEvent.firstString(inNestedDictionary: json, containerKeys: ["toolCall"], keys: ["name"])
        // `toolCallId` is ZCode's flat spelling of the same invocation id (its
        // kernel emits {toolCallId, toolName, toolInput} on every tool event).
        // Parsing it keeps zcode permission requests correlated by id so they
        // are never mistaken for orphans and auto-resolved on session activity.
        // `_pi_tool_call_id` is the pi/OMP extension's spelling of the same id.
        self.toolUseId = HookEvent.firstString(
            in: json,
            keys: ["tool_use_id", "toolUseId", "toolCallId", "_pi_tool_call_id"]
        )
            ?? HookEvent.firstString(inNestedDictionary: json, containerKeys: ["tool", "tool_use", "toolUse", "payload", "data"], keys: ["id", "tool_use_id", "toolUseId"])
        self.toolInput = HookEvent.firstDictionary(in: json, keys: ["tool_input", "toolInput", "input", "arguments", "args", "params"])
            ?? HookEvent.firstDictionary(inNestedDictionary: json, containerKeys: ["tool", "payload", "data"], keys: ["input", "tool_input", "toolInput", "arguments", "args", "params"])
            ?? HookEvent.firstDictionary(inNestedDictionary: json, containerKeys: ["toolCall"], keys: ["args"])
        self.agentId = json["agent_id"] as? String
        self.rawJSON = json
    }

    public var toolDescription: String? {
        if isCodexEvent {
            return codexToolDescription
        }
        if let input = toolInput {
            switch toolName {
            case "Bash", "execute_command", "run_command":
                let desc = HookEvent.normalizedMultilineString(input["description"])
                let cmd = HookEvent.normalizedMultilineString(input["CommandLine"] ?? input["command"])
                if let desc, let cmd {
                    if desc == cmd || desc.contains(cmd) {
                        return desc
                    }
                    return "\(desc)\nCommand:\n\(cmd)"
                }
                if let desc { return desc }
                if let cmd { return cmd }
            case "Read", "read_file", "view_file":
                if let fp = (input["AbsolutePath"] ?? input["file_path"]) as? String {
                    let name = (fp as NSString).lastPathComponent
                    if let start = input["StartLine"] as? Int, let end = input["EndLine"] as? Int {
                        return "\(name):\(start)-\(end)"
                    }
                    if let offset = input["offset"] as? Int {
                        return "\(name):\(offset)"
                    }
                    return name
                }
            case "Edit", "apply_diff", "replace_file_content", "multi_replace_file_content":
                if let fp = (input["TargetFile"] ?? input["file_path"]) as? String {
                    return (fp as NSString).lastPathComponent
                }
            case "Write", "write_to_file":
                if let fp = (input["TargetFile"] ?? input["file_path"]) as? String {
                    return (fp as NSString).lastPathComponent
                }
            case "Grep", "search_files", "grep_search":
                if let pattern = (input["Query"] ?? input["pattern"]) as? String {
                    let path = ((input["SearchPath"] ?? input["path"]) as? String).map { " in \(($0 as NSString).lastPathComponent)" } ?? ""
                    return "\(pattern)\(path)"
                }
            case "Glob":
                if let pattern = input["pattern"] as? String { return pattern }
            case "WebSearch":
                if let query = input["query"] as? String { return query }
            case "WebFetch":
                if let url = input["url"] as? String {
                    // Show domain only
                    if let host = URL(string: url)?.host { return host }
                    return String(url.prefix(40))
                }
            case "Task", "Agent":
                if let desc = input["description"] as? String, !desc.isEmpty { return desc }
                if let prompt = input["prompt"] as? String { return String(prompt.prefix(40)) }
            case "TodoWrite":
                return "Updating tasks"
            default:
                // Generic: try common fields
                if let fp = input["file_path"] as? String { return (fp as NSString).lastPathComponent }
                if let pattern = input["pattern"] as? String { return pattern }
                if let command = input["command"] as? String { return String(command.prefix(60)) }
                if let prompt = input["prompt"] as? String { return String(prompt.prefix(40)) }
            }
        }
        // Fall back to top-level fields
        if let msg = HookEvent.firstString(in: rawJSON, keys: ["message", "text", "summary", "status", "detail", "content"]) {
            return msg
        }
        if let msg = HookEvent.firstString(inNestedDictionary: rawJSON, containerKeys: ["payload", "data"], keys: ["message", "text", "summary", "status", "detail", "content"]) {
            return msg
        }
        if let agentType = rawJSON["agent_type"] as? String { return agentType }
        if let prompt = rawJSON["prompt"] as? String { return String(prompt.prefix(40)) }
        return nil
    }

    /// A concise, provider-neutral label for the current Codex action. Other
    /// providers retain their original tool names to avoid changing established
    /// display, color, permission, or history behavior.
    public var activityLabel: String? {
        guard let toolName else { return nil }
        guard isCodexEvent else { return toolName }

        switch activityCategory {
        case .reading: return "Reading"
        case .searching: return "Searching"
        case .editing: return "Editing"
        case .shell: return "Running command"
        case .browser: return "Using browser"
        case .mcp: return "Calling MCP"
        case .delegation: return "Delegating"
        case .question: return "Asking user"
        case .other: return HookEvent.sanitizedSummary(toolName, limit: 48)
        }
    }

    public var activityCategory: ToolActivityCategory {
        guard isCodexEvent, let rawName = toolName?.lowercased() else { return .other }
        let name = rawName.replacingOccurrences(of: "-", with: "_")

        if name.hasPrefix("mcp__")
            || name.contains("mcp_resource")
            || name == "list_mcp_resources"
            || name == "list_mcp_resource_templates" {
            return .mcp
        }
        if name.contains("spawn_agent")
            || name.contains("send_message")
            || name.contains("followup_task")
            || name.contains("wait_agent")
            || name.contains("subagent")
            || name == "task"
            || name == "agent" {
            return .delegation
        }
        if name.contains("request_user_input") || name.contains("ask_user") {
            return .question
        }
        if name.contains("browser")
            || name.contains("playwright")
            || name.contains("navigate")
            || name == "web_search"
            || name == "web_fetch" {
            return .browser
        }
        if name.contains("apply_patch")
            || name.contains("edit_file")
            || name.contains("write_file")
            || name.contains("delete_file")
            || name.contains("move_file")
            || name.contains("replace_file") {
            return .editing
        }
        if name.contains("grep")
            || name.contains("glob")
            || name.contains("search")
            || name == "find"
            || name.hasPrefix("rg_") {
            return .searching
        }
        if name.contains("read_file")
            || name.contains("view_file")
            || name.contains("view_image")
            || name.contains("list_dir") {
            return .reading
        }
        if name.contains("exec_command")
            || name.contains("write_stdin")
            || name.contains("shell")
            || name == "bash"
            || name == "command"
            || name == "run_command" {
            return .shell
        }
        return .other
    }

    private var isCodexEvent: Bool {
        (rawJSON["_source"] as? String)?.lowercased() == "codex"
    }

    private var codexToolDescription: String? {
        let input = toolInput ?? [:]
        switch activityCategory {
        case .reading, .editing:
            if let path = HookEvent.firstString(
                in: input,
                keys: ["file_path", "path", "filename", "AbsolutePath", "TargetFile"]
            ) {
                return HookEvent.sanitizedFilename(path)
            }
            return activityCategory == .editing ? "Applying changes" : nil
        case .searching:
            guard let query = HookEvent.firstString(in: input, keys: ["query", "pattern", "Query"]) else {
                return nil
            }
            return HookEvent.sanitizedSummary(query, limit: 80)
        case .shell:
            guard let command = HookEvent.firstString(
                in: input,
                keys: ["command", "cmd", "CommandLine"]
            ) else { return nil }
            return HookEvent.sanitizedSummary(command, limit: 120)
        case .browser:
            if let rawURL = HookEvent.firstString(in: input, keys: ["url", "uri"]),
               let host = URL(string: rawURL)?.host,
               !host.isEmpty {
                return host
            }
            if let query = HookEvent.firstString(in: input, keys: ["query", "search_query"]) {
                return HookEvent.sanitizedSummary(query, limit: 72)
            }
            return nil
        case .mcp:
            guard let toolName else { return nil }
            let pieces = toolName.components(separatedBy: "__").filter { !$0.isEmpty }
            if pieces.count >= 3 {
                return HookEvent.sanitizedSummary(pieces.dropFirst().joined(separator: " / "), limit: 72)
            }
            return nil
        case .delegation:
            if let detail = HookEvent.firstString(in: input, keys: ["task_name", "description", "agent_type"]) {
                return HookEvent.sanitizedSummary(detail, limit: 72)
            }
            return nil
        case .question:
            return "Waiting for input"
        case .other:
            if let path = HookEvent.firstString(in: input, keys: ["file_path", "path"]) {
                return HookEvent.sanitizedFilename(path)
            }
            if let detail = HookEvent.firstString(in: input, keys: ["description", "summary"]) {
                return HookEvent.sanitizedSummary(detail, limit: 80)
            }
            return nil
        }
    }

    private static func sanitizedFilename(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return sanitizedSummary((trimmed as NSString).lastPathComponent, limit: 80)
    }

    /// Credential / home-path redactions applied by ``sanitizedSummary(_:limit:)``,
    /// compiled once — the summary runs on every Codex PreToolUse and approval.
    private static let summaryRedactions: [(regex: NSRegularExpression, template: String)] = [
        (#"(?i)(authorization\s*[:=]\s*(?:bearer\s+)?)([\"']?)[^\"'\s]+"#, "$1[REDACTED]"),
        (#"(?i)((?:aws[-_]?secret[-_]?access[-_]?key|aws[-_]?(?:session|security)[-_]?token|x[-_]amz[-_]security[-_]token)\s*[:=]\s*)([\"']?)[^\"'\s]+"#, "$1[REDACTED]"),
        (#"(?i)((?:x[-_])?(?:api[-_]?key|auth[-_]?token|access[-_]?token|secret|password)\s*:\s*)([\"']?)[^\"'\s]+"#, "$1[REDACTED]"),
        (#"(?i)((?:--)?(?:api[-_]?key|token|secret|password|passwd|auth)(?:\s+|=))([^\s]+)"#, "$1[REDACTED]"),
        (#"(?i)([?&](?:api[-_]?key|token|secret|signature|sig|password)=)[^&\s\"']+"#, "$1[REDACTED]"),
        (#"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b"#, "[REDACTED]"),
        (#"/(?:Users|home)/[^/\s]+"#, "~"),
        (#"\b[A-Za-z0-9_\-+/=]{48,}\b"#, "[REDACTED]"),
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            assertionFailure("invalid redaction pattern: \(pattern)")
            return nil
        }
        return (regex, template)
    }

    /// Removes common credential shapes and home-directory usernames before a
    /// bounded detail string reaches the notch, companion payloads, or history.
    private static func sanitizedSummary(_ value: String, limit: Int) -> String? {
        var result = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !result.isEmpty else { return nil }

        for (regex, template) in summaryRedactions {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: template
            )
        }

        guard result.count > limit, limit > 3 else { return result }
        return String(result.prefix(limit - 3)) + "..."
    }

    private static func normalizedMultilineString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func firstDictionary(in dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            if let value = dict[key] as? [String: Any] { return value }
        }
        return nil
    }

    private static func firstString(
        inNestedDictionary dict: [String: Any],
        containerKeys: [String],
        keys: [String]
    ) -> String? {
        for containerKey in containerKeys {
            if let nested = dict[containerKey] as? [String: Any],
               let value = firstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func firstDictionary(
        inNestedDictionary dict: [String: Any],
        containerKeys: [String],
        keys: [String]
    ) -> [String: Any]? {
        for containerKey in containerKeys {
            if let nested = dict[containerKey] as? [String: Any],
               let value = firstDictionary(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }
}

public struct SubagentState: Sendable {
    public let agentId: String
    public let agentType: String
    public var status: AgentStatus = .running
    public var currentTool: String?
    public var toolDescription: String?
    public var startTime: Date = Date()
    public var lastActivity: Date = Date()

    public init(agentId: String, agentType: String) {
        self.agentId = agentId
        self.agentType = agentType
    }
}

public struct ToolHistoryEntry: Identifiable, Sendable {
    public let id = UUID()
    public let tool: String
    public let description: String?
    public let timestamp: Date
    public let success: Bool
    public let agentType: String?  // nil = main thread

    public init(tool: String, description: String?, timestamp: Date, success: Bool, agentType: String?) {
        self.tool = tool
        self.description = description
        self.timestamp = timestamp
        self.success = success
        self.agentType = agentType
    }
}

public struct ChatMessage: Identifiable, Sendable {
    public let id = UUID()
    public let isUser: Bool
    public let text: String

    public init(isUser: Bool, text: String) {
        self.isUser = isUser
        self.text = text
    }
}

public struct QuestionPayload {
    public let question: String
    public let options: [String]?
    public let descriptions: [String]?
    public let header: String?
    /// When true the answer is sensitive (e.g. a Codex `isSecret` plan-mode
    /// prompt). Remote peripherals (companion / ESP32) must not stream the
    /// question text or options to avoid leaking secrets off-device.
    public let isSecret: Bool

    public init(
        question: String,
        options: [String]?,
        descriptions: [String]? = nil,
        header: String? = nil,
        isSecret: Bool = false
    ) {
        self.question = question
        self.options = options
        self.descriptions = descriptions
        self.header = header
        self.isSecret = isSecret
    }

    /// Try to extract question from a Notification hook event
    public static func from(event: HookEvent) -> QuestionPayload? {
        if let question = event.rawJSON["question"] as? String {
            let options = event.rawJSON["options"] as? [String]
            return QuestionPayload(question: question, options: options)
        }
        // Don't use "?" heuristic — normal status text like "Should I update tests?"
        // would be misclassified as a blocking question, stalling the hook.
        return nil
    }
}
