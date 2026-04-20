import Foundation

public enum SessionTitleSource: String, Sendable, Codable {
    case codexThreadName
    case claudeCustomTitle
    case claudeAiTitle
}

public struct SessionSnapshot {
    public static let customCLIConfigsKey = "custom_cli_configs_v1"

    public static let supportedSources: Set<String> = [
        "claude",
        "codex",
        "gemini",
        "cursor",
        "trae",
        "traecn",
        "traecli",
        "copilot",
        "qoder",
        "droid",
        "codebuddy",
        "codybuddycn",
        "stepfun",
        "opencode",
        "antigravity",
        "workbuddy",
        "hermes",
        "qwen",
        "kimi",
        "pi",
    ]

    public var status: AgentStatus = .idle
    public var currentTool: String?
    public var toolDescription: String?
    public var lastActivity: Date = Date()
    public var cwd: String?
    public var model: String?
    public var permissionMode: String?
    public var toolHistory: [ToolHistoryEntry] = []
    public var subagents: [String: SubagentState] = [:]
    public var startTime: Date = Date()
    public var lastUserPrompt: String?
    public var lastAssistantMessage: String?
    /// Recent chat messages (max 3) for preview
    public var recentMessages: [ChatMessage] = []
    // Terminal info for window activation
    public var termApp: String?        // "iTerm.app", "Apple_Terminal", etc.
    public var itermSessionId: String?  // iTerm2 session ID for direct activation
    public var ttyPath: String?         // /dev/ttys00X
    public var kittyWindowId: String?   // Kitty window ID for precise focus
    public var tmuxPane: String?        // tmux pane identifier (%0, %1, etc.)
    public var tmuxClientTty: String?   // tmux client TTY for real terminal detection
    public var tmuxEnv: String?         // raw TMUX env var (socket info for non-default tmux server)
    public var termBundleId: String?    // __CFBundleIdentifier for precise terminal ID
    public var cmuxSurfaceId: String?   // cmux surface UUID (from CMUX_SURFACE_ID env var)
    public var cmuxWorkspaceId: String? // cmux workspace UUID (from CMUX_WORKSPACE_ID env var)
    public var cliPid: pid_t?            // CLI process PID (from bridge _ppid)
    public var cliStartTime: Date?       // Start time of the tracked CLI PID (guards PID reuse)
    public var source: String = "claude" // "claude" or "codex"
    public var interrupted: Bool = false
    public var sessionTitle: String?
    public var sessionTitleSource: SessionTitleSource?
    public var providerSessionId: String?
    public var remoteHostId: String?
    public var remoteHostName: String?
    /// nil = unchecked, false = not YOLO, true = YOLO
    public var isYoloMode: Bool?

    public init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    public static func normalizedSupportedSource(_ source: String?) -> String? {
        guard let source else { return nil }
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        let aliases: [String: String] = [
            "factory": "droid",
            "ag": "antigravity",
            "work-buddy": "workbuddy",
            "hermes-agent": "hermes",
            "qwen-code": "qwen",
            "qwencode": "qwen",
            "kimi-cli": "kimi",
            "kimicli": "kimi",
            "codebuddycn": "codybuddycn",
            "codybuddy-cn": "codybuddycn",
            "step-fun": "stepfun",
            "step fun": "stepfun",
            "trae-cn": "traecn",
            "trae_cn": "traecn",
            "trae cn": "traecn",
            "traecli": "traecli",
        ]
        let canonical = aliases[normalized] ?? normalized
        let dynamicSupportedSources = supportedSources.union(loadCustomSources())

        if dynamicSupportedSources.contains(canonical) { return canonical }
        if canonical.hasPrefix("antigravity") { return "antigravity" }
        if canonical.hasPrefix("workbuddy") { return "workbuddy" }
        if canonical.hasPrefix("hermes") { return "hermes" }
        if canonical.hasPrefix("qwen") { return "qwen" }
        if canonical.hasPrefix("kimi") { return "kimi" }
        if canonical.hasPrefix("codybuddycn") || canonical.hasPrefix("codebuddycn") { return "codybuddycn" }
        if canonical.hasPrefix("stepfun") { return "stepfun" }
        if canonical.hasPrefix("traecn") { return "traecn" }
        if canonical.hasPrefix("traecli") { return "traecli" }
        if canonical.hasPrefix("trae") { return "trae" }
        return nil
    }

    private static func loadCustomSources() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: customCLIConfigsKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Set(raw.compactMap { item in
            (item["source"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }.filter { !$0.isEmpty })
    }

    private static func loadCustomSourceNames() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: customCLIConfigsKey),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        var names: [String: String] = [:]
        for item in raw {
            guard let source = (item["source"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !source.isEmpty else { continue }
            let display = (item["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let display, !display.isEmpty {
                names[source] = display
            }
        }
        return names
    }

    public var activeSubagentCount: Int {
        subagents.values.filter { $0.status != .idle }.count
    }

    public mutating func addRecentMessage(_ msg: ChatMessage, maxCount: Int = 3) {
        recentMessages.append(msg)
        if recentMessages.count > maxCount {
            recentMessages.removeFirst(recentMessages.count - maxCount)
        }
    }

    public mutating func insertRecentMessage(_ msg: ChatMessage, at index: Int, maxCount: Int = 3) {
        recentMessages.insert(msg, at: index)
        if recentMessages.count > maxCount {
            recentMessages.removeFirst(recentMessages.count - maxCount)
        }
    }

    public mutating func recordTool(_ tool: String, description: String?, success: Bool, agentType: String?, maxHistory: Int) {
        let entry = ToolHistoryEntry(tool: tool, description: description, timestamp: Date(), success: success, agentType: agentType)
        toolHistory.append(entry)
        if toolHistory.count > maxHistory {
            toolHistory.removeFirst()
        }
    }

    /// Display name: project folder, or short session ID
    public var displayName: String {
        if let cwd = cwd {
            let last = (cwd as NSString).lastPathComponent
            // If last component is a timestamp/numeric ID (e.g. CodeBuddy "20260406010126"),
            // show the parent directory name instead
            if last.count >= 8 && last.allSatisfy(\.isNumber) {
                let parent = ((cwd as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !parent.isEmpty && parent != "/" { return parent }
            }
            return last
        }
        return "Session"
    }

    public func displayTitle(sessionId: String) -> String {
        sessionLabel ?? sessionId
    }

    public func displaySessionId(sessionId: String) -> String {
        if let providerSessionId {
            let trimmed = providerSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return sessionId
    }

    public var projectDisplayName: String {
        displayName
    }

    public var isRemote: Bool {
        guard let remoteHostId else { return false }
        return !remoteHostId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var remoteDisplayName: String? {
        guard let remoteHostName else { return nil }
        let trimmed = remoteHostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var sessionLabel: String? {
        guard let sessionTitle else { return nil }
        let trimmed = sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shortened model name: "claude-opus-4-6" → "opus"
    public var shortModelName: String? {
        guard let model = model else { return nil }
        let lower = model.lowercased()
        if lower.contains("opus") { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku") { return "haiku" }
        if lower.contains("gemini") { return "gemini" }
        if let last = model.split(separator: "-").last, last.count <= 8 {
            return String(last)
        }
        return String(model.prefix(8))
    }

    /// Source label for display
    public var sourceLabel: String {
        switch source {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "cursor": return "Cursor"
        case "trae": return "Trae"
        case "traecn": return "Trae CN"
        case "traecli": return "Traecli"
        case "qoder": return "Qoder"
        case "droid": return "Factory"
        case "codebuddy": return "CodeBuddy"
        case "codybuddycn": return "CodyBuddyCN"
        case "stepfun": return "StepFun"
        case "opencode": return "OpenCode"
        case "antigravity": return "AntiGravity"
        case "workbuddy": return "WorkBuddy"
        case "hermes": return "Hermes"
        case "qwen": return "Qwen Code"
        case "kimi": return "Kimi Code CLI"
        case "pi": return "pi"
        default:
            if let customName = Self.loadCustomSourceNames()[source] {
                return customName
            }
            return source.capitalized
        }
    }

    public var isCodex: Bool { source == "codex" }
    public var isClaude: Bool { source == "claude" }

    /// True when the session runs inside a native app in APP mode (Cursor agent, Codex APP, etc.)
    /// — the app IS the agent, not just a terminal hosting a CLI.
    /// Requires both bundle ID AND source to match (Claude CLI in Cursor terminal ≠ native app mode).
    public var isNativeAppMode: Bool {
        guard let bid = termBundleId else { return false }
        guard let expectedSource = Self.appBundleSources[bid] else { return false }
        return source == expectedSource
    }

    /// True when the session runs inside an IDE's integrated terminal.
    /// We can't query IDE tab/pane state, so notification suppression should be skipped.
    public var isIDETerminal: Bool {
        guard let bid = termBundleId else { return false }
        if isNativeAppMode { return false }
        // Known apps used as terminal (e.g., Claude CLI in Cursor's integrated terminal)
        if Self.appBundleNames[bid] != nil { return true }
        let lower = bid.lowercased()
        return lower.contains("vscode") || lower.contains("vscodium")
            || lower == "com.trae.app"
            || lower.contains("windsurf") || lower.contains("codeium")
            || lower.contains("jetbrains")
            || lower.contains("zed")
            || lower.contains("xcode") || lower == "com.apple.dt.xcode"
            || lower.contains("panic.nova")
            || lower.contains("android.studio")
            || lower.contains("antigravity")
    }

    /// Bundle IDs of native apps (not terminals)
    private static let appBundleNames: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.trae.app": "Trae",
        "com.qoder.ide": "Qoder",
        "com.factory.app": "Factory",
        "com.tencent.codebuddy": "CodeBuddy",
        "com.tencent.codebuddy.cn": "CodyBuddyCN",
        "com.stepfun.app": "StepFun",
        "com.openai.codex": "Codex",
        "ai.opencode.desktop": "OpenCode",
    ]

    /// Maps native app bundle IDs to their expected source identifier.
    /// Used by isNativeAppMode to distinguish "Cursor agent" from "Claude CLI in Cursor terminal".
    private static let appBundleSources: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.trae.app": "trae",
        "com.qoder.ide": "qoder",
        "com.factory.app": "droid",
        "com.tencent.codebuddy": "codebuddy",
        "com.tencent.codebuddy.cn": "codybuddycn",
        "com.stepfun.app": "stepfun",
        "com.openai.codex": "codex",
        "ai.opencode.desktop": "opencode",
    ]

    /// Short terminal/app name for display tag
    public var terminalName: String? {
        if isRemote {
            return remoteDisplayName ?? "Remote"
        }
        // If termBundleId is a known app, show app name (APP mode)
        if let bid = termBundleId, let name = Self.appBundleNames[bid] {
            return name
        }
        // Check bundle ID for terminal identification (more reliable than TERM_PROGRAM)
        if let bid = termBundleId {
            let lower = bid.lowercased()
            if lower.contains("cmux") { return "cmux" }
            if lower.contains("warp") { return "Warp" }
            if lower == "com.mitchellh.ghostty" { return "Ghostty" }
            if lower.contains("iterm2") { return "iTerm2" }
            if lower.contains("kitty") { return "Kitty" }
            if lower.contains("alacritty") { return "Alacritty" }
            if lower.contains("wezterm") { return "WezTerm" }
            // IDE integrated terminals
            if lower.contains("vscode") || lower.contains("vscodium") { return "VS Code" }
            if lower == "com.trae.app" { return "Trae" }
            if lower.contains("windsurf") { return "Windsurf" }
            if lower.contains("jetbrains") {
                if lower.contains("intellij") { return "IDEA" }
                if lower.contains("pycharm") { return "PyCharm" }
                if lower.contains("webstorm") { return "WebStorm" }
                if lower.contains("goland") { return "GoLand" }
                if lower.contains("clion") { return "CLion" }
                if lower.contains("rider") { return "Rider" }
                if lower.contains("rubymine") { return "RubyMine" }
                if lower.contains("phpstorm") { return "PhpStorm" }
                if lower.contains("datagrip") { return "DataGrip" }
                return "JetBrains"
            }
            if lower.contains("zed") { return "Zed" }
            if lower.contains("xcode") || lower == "com.apple.dt.xcode" { return "Xcode" }
            if lower.contains("panic.nova") { return "Nova" }
            if lower.contains("android.studio") { return "Android Studio" }
            if lower.contains("antigravity") { return "Antigravity" }
        }
        // Fallback to TERM_PROGRAM
        guard let app = termApp else { return nil }
        let lower = app.lowercased()
        if lower.contains("cmux") { return "cmux" }
        if lower == "ghostty" { return "Ghostty" }
        if lower.contains("iterm") { return "iTerm2" }
        if lower.contains("warp") { return "Warp" }
        if lower.contains("alacritty") { return "Alacritty" }
        if lower.contains("kitty") { return "Kitty" }
        if lower.contains("terminal") { return "Terminal" }
        return app
    }

    /// Subtitle: cwd path or model info
    public var subtitle: String? {
        if let cwd = cwd {
            // Show parent/folder instead of just folder
            let parts = cwd.split(separator: "/")
            let pathText: String
            if parts.count >= 2 {
                pathText = "\(parts[parts.count - 2])/\(parts[parts.count - 1])"
            } else {
                pathText = cwd
            }
            if let remote = remoteDisplayName {
                return "\(pathText) · \(remote)"
            }
            return pathText
        }
        if let remote = remoteDisplayName {
            return remote
        }
        return model
    }
}

public struct SessionSummary {
    public let status: AgentStatus
    public let primarySource: String
    public let activeSessionCount: Int
    public let totalSessionCount: Int

    public init(status: AgentStatus, primarySource: String, activeSessionCount: Int, totalSessionCount: Int) {
        self.status = status
        self.primarySource = primarySource
        self.activeSessionCount = activeSessionCount
        self.totalSessionCount = totalSessionCount
    }
}

public func deriveSessionSummary(from sessions: [String: SessionSnapshot]) -> SessionSummary {
    var highestStatus: AgentStatus = .idle
    var source = "claude"
    var active = 0
    var mostRecentIdleSource: (source: String, time: Date)?

    for session in sessions.values {
        if session.status != .idle {
            active += 1
        } else if mostRecentIdleSource == nil || session.lastActivity > mostRecentIdleSource!.time {
            mostRecentIdleSource = (session.source, session.lastActivity)
        }

        switch session.status {
        case .waitingApproval:
            highestStatus = .waitingApproval
            source = session.source
        case .waitingQuestion:
            if highestStatus != .waitingApproval {
                highestStatus = .waitingQuestion
                source = session.source
            }
        case .running:
            if highestStatus == .idle || highestStatus == .processing {
                highestStatus = .running
                source = session.source
            }
        case .processing:
            if highestStatus == .idle {
                highestStatus = .processing
                source = session.source
            }
        case .idle:
            break
        }
    }

    if highestStatus == .idle, let idleSource = mostRecentIdleSource?.source {
        source = idleSource
    }

    return SessionSummary(
        status: highestStatus,
        primarySource: source,
        activeSessionCount: active,
        totalSessionCount: sessions.count
    )
}

// MARK: - Side Effects

public enum SideEffect: Equatable {
    case playSound(String)
    case tryMonitorSession(sessionId: String)
    case stopMonitor(sessionId: String)
    case removeSession(sessionId: String)
    case enqueueCompletion(sessionId: String)
    case setActiveSession(sessionId: String?)
}

// MARK: - Pure Reducer

/// Pure reducer: mutates sessions, returns side effects for the caller to execute.
public func reduceEvent(
    sessions: inout [String: SessionSnapshot],
    event: HookEvent,
    maxHistory: Int
) -> [SideEffect] {
    let sessionId = event.sessionId ?? "default"
    let eventName = EventNormalizer.normalize(event.eventName)
    var effects: [SideEffect] = []

    // Ensure session exists
    if sessions[sessionId] == nil {
        sessions[sessionId] = SessionSnapshot()
    }

    // Always update metadata from every event
    extractMetadata(into: &sessions, sessionId: sessionId, event: event)
    let isRemote = sessions[sessionId]?.isRemote == true

    // Route subagent-specific events
    if let agentId = event.agentId {
        let handled = handleSubagentEvent(
            sessions: &sessions,
            sessionId: sessionId,
            agentId: agentId,
            eventName: eventName,
            event: event,
            maxHistory: maxHistory,
            effects: &effects
        )
        if handled { return effects }
    }

    // Preserve actionable states: don't let activity updates overwrite waiting states
    let isWaiting = sessions[sessionId]?.status == .waitingApproval
        || sessions[sessionId]?.status == .waitingQuestion

    // Update this session's state
    switch eventName {
    case "UserPromptSubmit":
        sessions[sessionId]?.interrupted = false
        sessions[sessionId]?.status = .processing
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        // Try multiple possible field names for user prompt
        let prompt = event.rawJSON["prompt"] as? String
            ?? event.rawJSON["user_prompt"] as? String
            ?? event.rawJSON["message"] as? String
            ?? event.rawJSON["input"] as? String
            ?? event.rawJSON["content"] as? String
        if let prompt {
            sessions[sessionId]?.lastUserPrompt = prompt
            if sessions[sessionId]?.recentMessages.last?.isUser == true {
                sessions[sessionId]?.recentMessages.removeLast()
            }
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
    case "PreToolUse":
        if !isWaiting {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = event.toolName
            sessions[sessionId]?.toolDescription = event.toolDescription
        }
    case "PostToolUse":
        if let tool = sessions[sessionId]?.currentTool {
            let desc = sessions[sessionId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: true, agentType: nil, maxHistory: maxHistory)
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "PostToolUseFailure":
        if let tool = sessions[sessionId]?.currentTool {
            let desc = sessions[sessionId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: false, agentType: nil, maxHistory: maxHistory)
        }
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "PermissionDenied":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "SubagentStart":
        if !isWaiting {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = event.rawJSON["agent_type"] as? String
        }
    case "SubagentStop":
        if !isWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    case "AfterAgentResponse":
        // Cursor-specific: AI reply arrives here (in "text" field), not in Stop
        let responseText = firstStringFromEvent(
            event,
            keys: ["text", "message"],
            includeNested: true
        )
        if let text = responseText, !text.isEmpty {
            sessions[sessionId]?.lastAssistantMessage = text
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: text))
        }
        sessions[sessionId]?.status = .processing
    case "Stop":
        // Detect ESC/Ctrl+C interruption
        let stopReason = event.rawJSON["stop_reason"] as? String ?? ""
        sessions[sessionId]?.interrupted = (stopReason == "user" || stopReason == "interrupted")
        sessions[sessionId]?.status = .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        let assistantMsg = firstStringFromEvent(
            event,
            keys: ["last_assistant_message", "text", "message", "summary"],
            includeNested: true
        )
        if let msg = assistantMsg {
            sessions[sessionId]?.lastAssistantMessage = msg
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: msg))
        } else if sessions[sessionId]?.lastAssistantMessage == nil,
                  sessions[sessionId]?.recentMessages.last?.isUser == true {
            // No reply content from hook (e.g. CodeBuddy) -- add placeholder
            sessions[sessionId]?.addRecentMessage(ChatMessage(isUser: false, text: "[回复完成]"))
        }
        // Try to capture user prompt from Stop event if not already set
        if sessions[sessionId]?.lastUserPrompt == nil {
            if let prompt = event.rawJSON["last_user_message"] as? String {
                sessions[sessionId]?.lastUserPrompt = prompt
                let insertAt = max(0, (sessions[sessionId]?.recentMessages.count ?? 1) - 1)
                sessions[sessionId]?.insertRecentMessage(ChatMessage(isUser: true, text: prompt), at: insertAt)
            }
        }
        effects.append(.enqueueCompletion(sessionId: sessionId))
    case "SessionStart":
        effects.append(.stopMonitor(sessionId: sessionId))
        sessions[sessionId] = SessionSnapshot(startTime: Date())
        // Re-apply metadata from this event (common extraction above wrote to the old session)
        if let cwd = event.rawJSON["cwd"] as? String, !cwd.isEmpty { sessions[sessionId]?.cwd = cwd }
        if let model = event.rawJSON["model"] as? String, !model.isEmpty { sessions[sessionId]?.model = model }
        if let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
            sessions[sessionId]?.cliPid = pid_t(ppid)
            sessions[sessionId]?.cliStartTime = nil
        }
        if let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
            sessions[sessionId]?.source = source
        }
        if let app = event.rawJSON["_term_app"] as? String, !app.isEmpty { sessions[sessionId]?.termApp = app }
        if let bundle = event.rawJSON["_term_bundle"] as? String, !bundle.isEmpty { sessions[sessionId]?.termBundleId = bundle }
        if let ses = event.rawJSON["_iterm_session"] as? String, !ses.isEmpty { sessions[sessionId]?.itermSessionId = ses }
        if let tty = event.rawJSON["_tty"] as? String, !tty.isEmpty { sessions[sessionId]?.ttyPath = tty }
        if let kitty = event.rawJSON["_kitty_window"] as? String, !kitty.isEmpty { sessions[sessionId]?.kittyWindowId = kitty }
        if let pane = event.rawJSON["_tmux_pane"] as? String, !pane.isEmpty { sessions[sessionId]?.tmuxPane = pane }
        if let tmuxTty = event.rawJSON["_tmux_client_tty"] as? String, !tmuxTty.isEmpty { sessions[sessionId]?.tmuxClientTty = tmuxTty }
        if let tmux = event.rawJSON["_tmux"] as? String, !tmux.isEmpty { sessions[sessionId]?.tmuxEnv = tmux }
        if let mode = event.rawJSON["permission_mode"] as? String { sessions[sessionId]?.permissionMode = mode }
        if let roots = event.rawJSON["workspace_roots"] as? [String], let first = roots.first, !first.isEmpty {
            sessions[sessionId]?.cwd = first
        }
        // cmux surface / workspace (restore directly from payload on SessionStart to avoid extractMetadata ordering dependency)
        if let surface = event.rawJSON["_cmux_surface_id"] as? String, !surface.isEmpty {
            sessions[sessionId]?.cmuxSurfaceId = surface
        }
        if let workspace = event.rawJSON["_cmux_workspace_id"] as? String, !workspace.isEmpty {
            sessions[sessionId]?.cmuxWorkspaceId = workspace
        }
        if let remoteHostId = event.rawJSON["_remote_host_id"] as? String, !remoteHostId.isEmpty {
            sessions[sessionId]?.remoteHostId = remoteHostId
        }
        if let remoteHostName = event.rawJSON["_remote_host_name"] as? String, !remoteHostName.isEmpty {
            sessions[sessionId]?.remoteHostName = remoteHostName
        }
        if let providerSessionId = event.rawJSON["session_id"] as? String, !providerSessionId.isEmpty,
           sessions[sessionId]?.isRemote == true {
            sessions[sessionId]?.providerSessionId = providerSessionId
        }
        if let sessionTitle = event.rawJSON["session_title"] as? String,
           !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.sessionTitle = sessionTitle
        }
        if !isRemote {
            effects.append(.tryMonitorSession(sessionId: sessionId))
        }
    case "SessionEnd":
        // Side effect: AppState handles pending permission deny before removal
        effects.append(.removeSession(sessionId: sessionId))
        return effects
    case "Notification":
        let notificationText = firstStringFromEvent(
            event,
            keys: ["message", "text", "summary", "status", "detail"],
            includeNested: true
        )
        if let msg = notificationText, !msg.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            sessions[sessionId]?.toolDescription = msg
        }
        if QuestionPayload.from(event: event) != nil {
            sessions[sessionId]?.status = .waitingQuestion
        }
    case "PreCompact":
        sessions[sessionId]?.status = .processing
        sessions[sessionId]?.toolDescription = "Compacting context\u{2026}"
    default:
        break
    }

    sessions[sessionId]?.lastActivity = Date()

    // Ensure process monitor is set up (covers sessions created implicitly)
    if sessions[sessionId]?.cwd != nil, !isRemote {
        effects.append(.tryMonitorSession(sessionId: sessionId))
    }

    // Trigger sound for this event
    effects.append(.playSound(eventName))

    // Switch display to the session that just had activity
    if eventName == "Stop" {
        // Stop event: keep activeSessionId on completed session (set by enqueueCompletion)
    } else if sessions[sessionId]?.status != .idle {
        effects.append(.setActiveSession(sessionId: sessionId))
    }
    // Note: the "else if activeSessionId == sessionId → mostActive" case
    // is handled by AppState since it needs to check current activeSessionId

    return effects
}

// MARK: - Private Helpers

public func extractMetadata(into sessions: inout [String: SessionSnapshot], sessionId: String, event: HookEvent) {
    if let cwd = event.rawJSON["cwd"] as? String, !cwd.isEmpty {
        sessions[sessionId]?.cwd = cwd
    } else if sessions[sessionId]?.cwd == nil,
              let roots = event.rawJSON["workspace_roots"] as? [String],
              let first = roots.first, !first.isEmpty {
        sessions[sessionId]?.cwd = first
    } else if sessions[sessionId]?.cwd == nil,
              let tp = event.rawJSON["transcript_path"] as? String, !tp.isEmpty {
        // Cursor: extract project dir from transcript_path
        // e.g. ~/.cursor/projects/<project>/agent-transcripts/... → ~/.cursor/projects/<project>
        let parts = tp.split(separator: "/")
        if let idx = parts.firstIndex(of: "projects"), idx + 1 < parts.count {
            let projectName = String(parts[idx + 1])
            sessions[sessionId]?.cwd = "/\(parts[...idx].joined(separator: "/"))/\(projectName)"
        }
    }
    if let model = event.rawJSON["model"] as? String, !model.isEmpty {
        sessions[sessionId]?.model = model
    }
    if let mode = event.rawJSON["permission_mode"] as? String {
        sessions[sessionId]?.permissionMode = mode
    }
    // Terminal info (injected by hook script)
    if let app = event.rawJSON["_term_app"] as? String, !app.isEmpty, app != "unknown" {
        sessions[sessionId]?.termApp = app
    }
    if let ses = event.rawJSON["_iterm_session"] as? String, !ses.isEmpty {
        sessions[sessionId]?.itermSessionId = ses
    }
    if let tty = event.rawJSON["_tty"] as? String, !tty.isEmpty {
        sessions[sessionId]?.ttyPath = tty
    }
    // Extended terminal info (from native bridge binary)
    if let kitty = event.rawJSON["_kitty_window"] as? String, !kitty.isEmpty {
        sessions[sessionId]?.kittyWindowId = kitty
    }
    if let pane = event.rawJSON["_tmux_pane"] as? String, !pane.isEmpty {
        sessions[sessionId]?.tmuxPane = pane
    }
    if let tmuxTty = event.rawJSON["_tmux_client_tty"] as? String, !tmuxTty.isEmpty {
        sessions[sessionId]?.tmuxClientTty = tmuxTty
    }
    if let tmux = event.rawJSON["_tmux"] as? String, !tmux.isEmpty {
        sessions[sessionId]?.tmuxEnv = tmux
    }
    if let bundle = event.rawJSON["_term_bundle"] as? String, !bundle.isEmpty {
        sessions[sessionId]?.termBundleId = bundle
    }
    // Fallback: extract terminal info from _env sub-object (OpenCode plugin format)
    if let env = event.rawJSON["_env"] as? [String: String] {
        if sessions[sessionId]?.termApp == nil,
           let app = env["TERM_PROGRAM"], !app.isEmpty {
            sessions[sessionId]?.termApp = app
        }
        if sessions[sessionId]?.termBundleId == nil,
           let bundle = env["__CFBundleIdentifier"], !bundle.isEmpty {
            sessions[sessionId]?.termBundleId = bundle
        }
        if sessions[sessionId]?.itermSessionId == nil,
           let ses = env["ITERM_SESSION_ID"], !ses.isEmpty {
            // Extract GUID after "w0t0p0:" prefix
            if let colonIdx = ses.firstIndex(of: ":") {
                sessions[sessionId]?.itermSessionId = String(ses[ses.index(after: colonIdx)...])
            } else {
                sessions[sessionId]?.itermSessionId = ses
            }
        }
        if sessions[sessionId]?.kittyWindowId == nil,
           let kitty = env["KITTY_WINDOW_ID"], !kitty.isEmpty {
            sessions[sessionId]?.kittyWindowId = kitty
        }
        if sessions[sessionId]?.tmuxPane == nil,
           let pane = env["TMUX_PANE"], !pane.isEmpty {
            sessions[sessionId]?.tmuxPane = pane
        }
    }
    if let ppid = event.rawJSON["_ppid"] as? Int, ppid > 0 {
        sessions[sessionId]?.cliPid = pid_t(ppid)
        sessions[sessionId]?.cliStartTime = nil
    }
    if let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) {
        sessions[sessionId]?.source = source
    }
    // cmux surface / workspace (injected by bridge from CMUX_SURFACE_ID / CMUX_WORKSPACE_ID env vars)
    if let surface = event.rawJSON["_cmux_surface_id"] as? String, !surface.isEmpty {
        sessions[sessionId]?.cmuxSurfaceId = surface
    }
    if let workspace = event.rawJSON["_cmux_workspace_id"] as? String, !workspace.isEmpty {
        sessions[sessionId]?.cmuxWorkspaceId = workspace
    }
    if let remoteHostId = event.rawJSON["_remote_host_id"] as? String, !remoteHostId.isEmpty {
        sessions[sessionId]?.remoteHostId = remoteHostId
    }
    if let remoteHostName = event.rawJSON["_remote_host_name"] as? String, !remoteHostName.isEmpty {
        sessions[sessionId]?.remoteHostName = remoteHostName
    }
    if sessions[sessionId]?.isRemote == true,
       let providerSessionId = event.rawJSON["session_id"] as? String,
       !providerSessionId.isEmpty {
        sessions[sessionId]?.providerSessionId = providerSessionId
    }
    if let sessionTitle = event.rawJSON["session_title"] as? String,
       !sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sessions[sessionId]?.sessionTitle = sessionTitle
    }
}

private func firstStringFromDict(_ dict: [String: Any], keys: [String]) -> String? {
    for key in keys {
        if let value = dict[key] as? String {
            let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
    }
    return nil
}

private func firstStringFromEvent(_ event: HookEvent, keys: [String], includeNested: Bool) -> String? {
    if let value = firstStringFromDict(event.rawJSON, keys: keys) {
        return value
    }
    if includeNested {
        for containerKey in ["payload", "data"] {
            if let nested = event.rawJSON[containerKey] as? [String: Any],
               let value = firstStringFromDict(nested, keys: keys) {
                return value
            }
        }
    }
    return nil
}

/// Handle subagent events. Returns true if the event was consumed.
private func handleSubagentEvent(
    sessions: inout [String: SessionSnapshot],
    sessionId: String,
    agentId: String,
    eventName: String,
    event: HookEvent,
    maxHistory: Int,
    effects: inout [SideEffect]
) -> Bool {
    switch eventName {
    case "SubagentStart":
        let agentType = event.rawJSON["agent_type"] as? String ?? "Agent"
        sessions[sessionId]?.subagents[agentId] = SubagentState(
            agentId: agentId,
            agentType: agentType
        )
        // Subagent spawned — parent session is actively processing
        if sessions[sessionId]?.status == .idle || sessions[sessionId]?.status == .processing {
            sessions[sessionId]?.status = .running
            sessions[sessionId]?.currentTool = "Agent"
            sessions[sessionId]?.toolDescription = agentType
        }
        sessions[sessionId]?.lastActivity = Date()
        effects.append(.setActiveSession(sessionId: sessionId))
        return true

    case "SubagentStop":
        sessions[sessionId]?.subagents.removeValue(forKey: agentId)
        // If no more subagents, revert parent to processing (waiting for main thread to continue)
        if sessions[sessionId]?.subagents.isEmpty == true {
            if sessions[sessionId]?.status == .running && sessions[sessionId]?.currentTool == "Agent" {
                sessions[sessionId]?.status = .processing
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.toolDescription = nil
            }
        }
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PreToolUse":
        sessions[sessionId]?.subagents[agentId]?.status = .running
        sessions[sessionId]?.subagents[agentId]?.currentTool = event.toolName
        sessions[sessionId]?.subagents[agentId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        // Keep parent session showing as active while subagents work
        if sessions[sessionId]?.status != .waitingApproval && sessions[sessionId]?.status != .waitingQuestion {
            sessions[sessionId]?.status = .running
        }
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PostToolUse":
        if let tool = sessions[sessionId]?.subagents[agentId]?.currentTool {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            let desc = sessions[sessionId]?.subagents[agentId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: true, agentType: agentType, maxHistory: maxHistory)
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.currentTool = nil
        sessions[sessionId]?.subagents[agentId]?.toolDescription = nil
        sessions[sessionId]?.subagents[agentId]?.lastActivity = Date()
        sessions[sessionId]?.lastActivity = Date()
        return true

    case "PostToolUseFailure":
        if let tool = sessions[sessionId]?.subagents[agentId]?.currentTool {
            let agentType = sessions[sessionId]?.subagents[agentId]?.agentType
            let desc = sessions[sessionId]?.subagents[agentId]?.toolDescription
            sessions[sessionId]?.recordTool(tool, description: desc, success: false, agentType: agentType, maxHistory: maxHistory)
        }
        sessions[sessionId]?.subagents[agentId]?.status = .processing
        sessions[sessionId]?.subagents[agentId]?.currentTool = nil
        sessions[sessionId]?.subagents[agentId]?.toolDescription = nil
        sessions[sessionId]?.lastActivity = Date()
        return true

    default:
        return false  // Fall through to normal session handling
    }
}
