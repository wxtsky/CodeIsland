import Foundation

/// One hook delivery, interpreted: the event the island gets, whether the
/// hook waits for the island's answer, and how that answer reaches its agent.
///
/// Every edge delivers through this one interpretation. codeisland-bridge
/// gathers the facts itself — its argv, environment, stdin and process tree —
/// and runs it before it connects; an edge that cannot run Swift (the remote
/// hook) sends what it observed in `_edge` (``HookEdgeFacts``) and HookServer
/// runs it on arrival. A provider quirk such as Cursor running Claude Code's
/// hooks (#377) is then handled here once, not in every edge.
///
/// It reads nothing but the ``Facts`` it is handed. The ones that cost a
/// process lookup or a subprocess (an ancestor's argv, the tmux client) are
/// closures, asked only when the interpretation needs them.
///
/// Two steps, so the bridge can arm its deadline in between: `init` decides
/// what the event is (source, session, event name, whether it is held) and
/// may drop it; ``addTerminalContext()`` then records where it runs.
public struct HookIntake {
    /// One process above the hook, nearest first.
    public struct Ancestor {
        public let pid: Int32
        /// Resolved executable (`proc_pidpath`) — symlinks already followed.
        public let executablePath: String?
        /// argv, including argv[0]. Read only for Codex Desktop detection.
        public let arguments: () -> [String]
        /// CFBundleIdentifier of the outermost `.app` containing
        /// `executablePath`. Read only for Codex Desktop detection.
        public let bundleIdentifier: () -> String?

        public init(
            pid: Int32,
            executablePath: String?,
            arguments: @escaping () -> [String] = { [] },
            bundleIdentifier: @escaping () -> String? = { nil }
        ) {
            self.pid = pid
            self.executablePath = executablePath
            self.arguments = arguments
            self.bundleIdentifier = bundleIdentifier
        }
    }

    /// The machine an edge runs on when that is not this Mac.
    public struct EdgeHost: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// What an edge observed of one hook invocation. Facts only: nothing in
    /// here is derived from anything else in here.
    public struct Facts {
        /// `--source`: the agent the hook was installed for.
        public var sourceTag: String?
        /// `--event`: for agents whose stdin does not name the event.
        public var eventTag: String?
        /// The source to stamp when nothing declares or infers one and the
        /// payload has no `_source` of its own: the island defaults to Claude
        /// when a payload names no source, and drops one whose source it does
        /// not support. The bridge has none; see
        /// ``HookEdgeFacts/facts(from:)`` for an edge's.
        public var defaultSource: String?
        /// The hook's environment. Only ``HookIntake/environmentKeys`` are read.
        public var environment: [String: String]
        /// The hook's parent process. Nil for an edge on another machine,
        /// whose processes are not this Mac's to track.
        public var parentPID: Int32?
        /// Up to six processes above the hook, nearest first.
        public var ancestry: [Ancestor]
        /// The directory the hook runs in. Read only when the payload names none.
        public var workingDirectory: () -> String?
        /// The hook's controlling terminal.
        public var tty: () -> String?
        /// This Mac's home directory, for `~` in GROK_HOME. Nil for an edge on
        /// another machine.
        public var homeDirectory: () -> String?
        /// `~` in a path of this Mac, expanded (HERMES_HOME).
        public var expandingTildeInPath: (String) -> String
        /// Where an edge on another machine runs (an id or a name it did not
        /// send is empty); nil on this Mac.
        public var remoteHost: EdgeHost?
        /// SHA-256 of the hook's stdin exactly as the agent wrote it
        /// (``CursorHookPayload/deliveryDigest(of:)``).
        public var stdinDigest: () -> String?
        /// Whether the edge waits for the island's answer, when it decided that
        /// on its own (the remote hook does, from the event name, so no other
        /// hook pays a round trip). Nil: it waits whenever ``HookIntake``
        /// says so, as the bridge does. A hook nobody waits on is never held.
        public var edgeWaits: Bool?
        /// The tty of the tmux client showing `pane` (`tmux display-message`).
        public var tmuxClientTTY: (_ pane: String) -> String?
        /// Whether a file exists on this Mac.
        public var fileExists: (String) -> Bool

        public init(
            sourceTag: String? = nil,
            eventTag: String? = nil,
            defaultSource: String? = nil,
            environment: [String: String] = [:],
            parentPID: Int32? = nil,
            ancestry: [Ancestor] = [],
            workingDirectory: @escaping () -> String? = { nil },
            tty: @escaping () -> String? = { nil },
            homeDirectory: @escaping () -> String? = { nil },
            expandingTildeInPath: @escaping (String) -> String = { ($0 as NSString).expandingTildeInPath },
            remoteHost: EdgeHost? = nil,
            stdinDigest: @escaping () -> String? = { nil },
            edgeWaits: Bool? = nil,
            tmuxClientTTY: @escaping (_ pane: String) -> String? = { _ in nil },
            fileExists: @escaping (String) -> Bool = { _ in false }
        ) {
            self.sourceTag = sourceTag
            self.eventTag = eventTag
            self.defaultSource = defaultSource
            self.environment = environment
            self.parentPID = parentPID
            self.ancestry = ancestry
            self.workingDirectory = workingDirectory
            self.tty = tty
            self.homeDirectory = homeDirectory
            self.expandingTildeInPath = expandingTildeInPath
            self.remoteHost = remoteHost
            self.stdinDigest = stdinDigest
            self.edgeWaits = edgeWaits
            self.tmuxClientTTY = tmuxClientTTY
            self.fileExists = fileExists
        }
    }

    /// How the hook hands the island's answer to its agent.
    public enum AnswerFormat: Equatable, Sendable {
        /// As the island wrote it: Claude Code's `hookSpecificOutput`, which
        /// the other agents read too.
        case verbatim
        /// Gemini CLI and Google Antigravity read `{"decision":"allow"|"deny"}`.
        case geminiDecision
    }

    /// The environment variables the interpretation reads. An edge sends no
    /// others, and the bridge hands over no others.
    public static let environmentKeys: Set<String> = [
        "CODEISLAND_SKIP",
        "GROK_SESSION_ID", "GROK_HOOK_EVENT", "GROK_WORKSPACE_ROOT", "GROK_HOME",
        "HERMES_HOME",
        "TERM_PROGRAM", "__CFBundleIdentifier", "ITERM_SESSION_ID", "KITTY_WINDOW_ID",
        // kitty's remote-control socket: the only address a process outside
        // kitty can drive one instance at. See TerminalActivator.activateKitty.
        "KITTY_LISTEN_ON",
        "TMUX", "TMUX_PANE",
        "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID",
        "ZELLIJ", "ZELLIJ_PANE_ID", "ZELLIJ_SESSION_NAME",
        "WEZTERM_PANE",
        "HERDR_ENV", "HERDR_PANE_ID", "HERDR_SOCKET_PATH", "HERDR_BIN_PATH",
        "SUPERSET_WORKSPACE_ID", "SUPERSET_PANE_ID", "SUPERSET_TERMINAL_ID",
        "ORCA_TERMINAL_HANDLE", "ORCA_WORKTREE_ID",
        ClaudeDesktopCodeSession.hostSessionEnvKey,
    ]

    /// The payload to forward.
    public private(set) var payload: [String: Any]
    /// The facts it was read from.
    public let facts: Facts
    /// The event as the agent named it.
    public let eventName: String
    /// ``eventName`` in the island's terms (``EventNormalizer``).
    public let normalizedEventName: String
    public let sessionId: String
    /// Whether the session id was made up from the agent's process: it sent none.
    public let sessionIdIsFallback: Bool
    /// The source stamped as `_source`.
    public let source: String?
    public let isPermission: Bool
    public let isQuestion: Bool
    /// Whether the hook waits for the island's answer and hands it to the agent.
    public let waitsForAnswer: Bool
    public let answerFormat: AnswerFormat
    /// How long the bridge holds the event before delivering it.
    public let deliveryDelay: TimeInterval

    // MARK: - Before stdin

    /// Whether the hook is forwarded at all: not with CODEISLAND_SKIP set, and
    /// inside Grok only its own `--source grok` hook (``GrokHookForwardingPolicy``).
    public static func admits(sourceTag: String?, environment: [String: String]) -> Bool {
        guard environment["CODEISLAND_SKIP"] == nil else { return false }
        // Grok Build imports ~/.claude and ~/.cursor hooks for compatibility in
        // addition to its own $GROK_HOME/hooks files. Once the dedicated CodeIsland
        // Grok hook is installed, forwarding those imported copies would deliver every
        // lifecycle event two or three times (and can mislabel it as Claude/Cursor).
        // Grok injects these variables for every hook subprocess, so keep only the
        // explicitly managed `--source grok` invocation in that runtime.
        return GrokHookForwardingPolicy.shouldForward(source: sourceTag, environment: environment)
    }

    /// What the hook must print before anything else can end it, whatever the
    /// island does: Google Antigravity refuses the tool call when its
    /// PreToolUse hook prints no decision (#339). The island only observes
    /// Antigravity tool calls; the decision stays with Antigravity.
    public static func immediateStdout(sourceTag: String?, eventName: String?) -> String? {
        AntigravityHookContract.hookStdout(source: sourceTag, eventName: eventName)
    }

    /// The hook's stdin as an object, without what is never forwarded: Hermes
    /// sends the whole conversation (`extra.conversation_history`) with every
    /// pre/post_llm_call, and nothing reads it. Nil when stdin is not a JSON
    /// object.
    public static func stdinObject(_ stdin: Data, sourceTag: String?) -> [String: Any]? {
        guard let parsed = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any] else { return nil }
        return dropsPartsOfStdin(sourceTag: sourceTag) ? HermesHookPayload.trimmedForForwarding(parsed) : parsed
    }

    /// Whether ``stdinObject(_:sourceTag:)`` leaves parts of the stdin out,
    /// which must then stay out of logs too.
    public static func dropsPartsOfStdin(sourceTag: String?) -> Bool {
        sourceTag == "hermes"
    }

    // MARK: - Interpretation

    /// What the event is, from the agent's stdin object and the edge's facts.
    /// Nil when it names no session and none can be made up: it is dropped.
    public init?(stdin: [String: Any], facts: Facts) {
        var json = Self.dropsPartsOfStdin(sourceTag: facts.sourceTag)
            ? HermesHookPayload.trimmedForForwarding(stdin)
            : stdin
        // Facts are not part of the event. The bridge reads its own and drops
        // any piped in with the stdin, so nothing interprets a hook twice.
        json.removeValue(forKey: HookEdgeFacts.key)
        let env = facts.environment
        let sourceTag = facts.sourceTag
        let eventTag = facts.eventTag

        // Cursor also runs CodeIsland's Claude Code hook (it imports Claude Code
        // hooks) with its own payload, so a source-less event may be Cursor's (#377).
        // A step CodeIsland is wired to in both configs reaches the bridge twice with
        // the same stdin; its digest lets the island keep one of the two.
        let isCursorPayload = CursorHookPayload.isCursorHook(json)
        if isCursorPayload, let digest = facts.stdinDigest() {
            json[CursorHookPayload.digestKey] = digest
        }

        // Hermes runs each hook with the firing profile's HERMES_HOME; the island reads
        // that session's title and messages from the store there (`state.db`). Only
        // on this Mac: a remote edge reads the store itself (`_hermes_store`).
        if sourceTag == "hermes", facts.remoteHost == nil,
           let hermesHome = Self.nonEmptyString(env["HERMES_HOME"]) {
            json["_hermes_home"] = facts.expandingTildeInPath(hermesHome)
        }

        // Grok normally includes these camelCase fields on stdin. The environment
        // fallbacks cover hook variants and make the bridge resilient to truncated
        // passive payloads without inventing a PID-based session identifier.
        let isGrokRuntime = GrokHookForwardingPolicy.isGrokRuntime(environment: env)
        if isGrokRuntime {
            if json["hookEventName"] == nil,
               let event = Self.nonEmptyString(env["GROK_HOOK_EVENT"]) {
                json["hookEventName"] = event
            }
            if json["sessionId"] == nil,
               let sessionId = Self.nonEmptyString(env["GROK_SESSION_ID"]) {
                json["sessionId"] = sessionId
            }
            if json["cwd"] == nil,
               let workspaceRoot = Self.nonEmptyString(json["workspaceRoot"])
                    ?? Self.nonEmptyString(env["GROK_WORKSPACE_ROOT"]) {
                json["cwd"] = workspaceRoot
            }
        }

        // Generic compatibility: accept common camelCase aliases from third-party forks
        if Self.namesNoEvent(json) {
            if let event = Self.nonEmptyString(json["hookEventName"]) {
                json["hook_event_name"] = event
            } else if let event = Self.nonEmptyString(json["eventName"]) {
                json["hook_event_name"] = event
            } else if let event = Self.nonEmptyString(json["event"]) {
                json["hook_event_name"] = event
            } else if let event = eventTag {
                json["hook_event_name"] = event
            }
        }
        if json["session_id"] == nil {
            if let sessionId = Self.nonEmptyString(json["sessionId"]) {
                json["session_id"] = sessionId
            } else if let payload = json["payload"] as? [String: Any],
                      let sessionId = Self.nonEmptyString(payload["session_id"]) ?? Self.nonEmptyString(payload["sessionId"]) {
                json["session_id"] = sessionId
            } else if let data = json["data"] as? [String: Any],
                      let sessionId = Self.nonEmptyString(data["session_id"]) ?? Self.nonEmptyString(data["sessionId"]) {
                json["session_id"] = sessionId
            } else if let conversationId = Self.nonEmptyString(json["conversationId"]) {
                // Google Antigravity (Gemini-based) stdin carries no session_id; it uses
                // `conversationId` as the stable per-conversation key (#215).
                json["session_id"] = conversationId
            }
        }

        // Google Antigravity sends the transcript path as camelCase `transcriptPath`;
        // the rest of CodeIsland reads snake_case `transcript_path` (used by the JSONL
        // tailer + cwd inference). Bridge the alias when only the camelCase form exists.
        if json["transcript_path"] == nil, let tp = Self.nonEmptyString(json["transcriptPath"]) {
            json["transcript_path"] = tp
        }

        // Grok's hook payload does not carry a transcript path. Its documented session
        // layout is deterministic, and chat_history.jsonl uses the user/assistant row
        // shapes already understood by CodeIsland's incremental tailer. The path is
        // only forwarded once the file exists (see GrokSessionPaths) — on this Mac.
        if isGrokRuntime,
           json["transcript_path"] == nil,
           let sessionId = Self.nonEmptyString(json["session_id"]),
           let cwd = Self.nonEmptyString(json["cwd"]),
           let home = facts.homeDirectory() {
            let rawHome = Self.nonEmptyString(env["GROK_HOME"])
            let grokHome: String
            if let rawHome {
                if rawHome == "~" {
                    grokHome = home
                } else if rawHome.hasPrefix("~/") {
                    grokHome = home + "/" + rawHome.dropFirst(2)
                } else {
                    grokHome = rawHome
                }
            } else {
                grokHome = (home as NSString).appendingPathComponent(".grok")
            }
            if let path = GrokSessionPaths.existingChatHistoryPath(
                grokHome: grokHome,
                cwd: cwd,
                sessionId: sessionId,
                fileExists: facts.fileExists
            ) {
                json["transcript_path"] = path
            }
        }

        // Copilot CLI adaptation: its stdin JSON lacks session_id and hook_event_name.
        // Normalize Copilot's camelCase payload and pass through sessionId when present.
        if sourceTag == "copilot" {
            if Self.namesNoEvent(json), let event = eventTag {
                json["hook_event_name"] = event
            }
            if json["session_id"] == nil, let sessionId = Self.nonEmptyString(json["sessionId"]) {
                json["session_id"] = sessionId
            }
            // Map Copilot-specific field names to internal conventions
            if let toolName = json["toolName"] as? String {
                json["tool_name"] = toolName
            }
            if let toolArgsStr = json["toolArgs"] as? String,
               let argsData = toolArgsStr.data(using: .utf8),
               let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                json["tool_input"] = argsObj
            }
        }

        // Cline adaptation: sends hookName and taskId instead of hook_event_name and session_id.
        if sourceTag == "cline" {
            if Self.namesNoEvent(json), let name = Self.nonEmptyString(json["hookName"]) {
                json["hook_event_name"] = name
            }
            if json["session_id"] == nil, let taskId = Self.nonEmptyString(json["taskId"]) {
                json["session_id"] = taskId
            }
            // Cline structures tool info as flat fields inside preToolUse/postToolUse objects:
            // PreToolUse:  { preToolUse:  { toolName: "execute_command", parameters: { ... } } }
            // PostToolUse: { postToolUse: { toolName: "execute_command", parameters: { ... }, result: ..., success: bool } }
            if json["tool_name"] == nil {
                if let preToolUse = json["preToolUse"] as? [String: Any],
                   let toolName = Self.nonEmptyString(preToolUse["toolName"] as? String) {
                    json["tool_name"] = toolName
                    if json["tool_input"] == nil, let parameters = preToolUse["parameters"] as? [String: Any] {
                        json["tool_input"] = parameters
                    }
                } else if let postToolUse = json["postToolUse"] as? [String: Any],
                          let toolName = Self.nonEmptyString(postToolUse["toolName"] as? String) {
                    json["tool_name"] = toolName
                }
            }
        }

        // Source tag (e.g. "codex" when called via --source codex). If the caller did not pass
        // one (e.g. the omo OpenCode plugin triggering Claude hooks without --source), infer
        // the real source from the process ancestry so we don't misattribute the event to
        // whichever hook path fired it. See issue #95.
        // In addition, the cursor-agent / qodercli CLIs share their hooks file with
        // the matching desktop IDE, so a `--source cursor` tag from a hook fired by
        // cursor-agent should be promoted to "cursor-cli" (#134). The override only
        // applies when ancestry actually shows a CLI binary.
        // Events that arrived via a plugin proxy (no declared source but ancestry
        // inferred a real source — e.g. the omo OpenCode plugin firing Claude hooks)
        // are marked `_via_plugin` so the host app can route them per
        // pluginSessionMode (#123). A direct plugin's own `_source` counts as declared,
        // and Claude Code firing its own (source-less) hook is not a proxy. Neither is
        // Cursor firing it: Cursor's payload declares Cursor (#377).
        let coreAncestry = facts.ancestry.map { (pid: $0.pid, executablePath: $0.executablePath) }
        let bridgeSource = CLIProcessResolver.bridgeSource(
            sourceTag: sourceTag,
            payloadSource: json["_source"] as? String,
            cursorPayload: isCursorPayload,
            ancestry: coreAncestry
        )
        // A `_source` the payload names but the island does not support stays,
        // as the bridge leaves it, and the island drops the event.
        let effectiveSource = bridgeSource.source ?? (json["_source"] == nil ? facts.defaultSource : nil)
        if let source = effectiveSource {
            json["_source"] = source
        }
        if bridgeSource.viaPlugin {
            json["_via_plugin"] = true
        }

        // The process the island tracks for the session. Some CLIs execute hooks
        // through `sh -c`, so the parent is a transient shell rather than the
        // long-lived CLI process. An edge on another machine has none to track.
        if let immediateParentPID = facts.parentPID {
            let resolvedTrackedPID = CLIProcessResolver.resolvedTrackedPID(
                immediateParentPID: immediateParentPID,
                source: effectiveSource,
                ancestry: coreAncestry
            )
            json["_ppid"] = resolvedTrackedPID
            if resolvedTrackedPID != immediateParentPID {
                json["_hook_ppid"] = immediateParentPID
            }
            // Cline hooks are shell scripts spawned by a VSCode extension — the immediate
            // parent is a transient shell, not a persistent agent process. Tracking this
            // short-lived PID as cliPid causes cleanupIdleSessions to detect it as dead
            // within seconds and remove the session. Clear it so no PID is tracked.
            if effectiveSource == "cline" {
                json["_ppid"] = 0
            }
            // Callers that know their process is not the agent's lifetime opt out. OpenCode 2
            // runs plugins in a shared background service that outlives the client that
            // spawned it: tracked as the CLI, it would be SIGTERMed as a "reparented orphan"
            // the moment that first client quits, taking every session with it (#332).
            if json["_untracked_process"] as? Bool == true {
                json["_ppid"] = 0
                json.removeValue(forKey: "_hook_ppid")
            }
        } else if facts.remoteHost != nil {
            // Nor is a pid an edge there forwards (the remote OpenCode plugin's
            // before v6) one of this Mac's processes.
            json.removeValue(forKey: "_ppid")
            json.removeValue(forKey: "_hook_ppid")
        }

        // Validate: must have non-empty session_id
        var sessionIdIsFallback = false
        if json["session_id"] == nil,
           let source = sourceTag,
           !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let immediateParentPID = facts.parentPID {
            // Fallback for third-party providers that don't include a stable session ID.
            // Use the root same-source binary in the ancestry so sub-agent processes
            // (e.g. Cursor IDE spawning multiple parallel agent subprocesses, #148)
            // collapse onto a single session card instead of fanning into N cards
            // (one per sub-agent ppid).
            let sessionPID = CLIProcessResolver.resolvedSessionPID(
                immediateParentPID: immediateParentPID,
                source: effectiveSource ?? source,
                ancestry: coreAncestry
            )
            json["session_id"] = "\(source)-ppid-\(sessionPID)"
            sessionIdIsFallback = true
        }
        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
            return nil
        }

        // Event type detection
        let eventName = json["hook_event_name"] as? String ?? ""
        let normalizedEventName = EventNormalizer.normalize(eventName)
        let isGeminiBasedSource = sourceTag == "google-antigravity" || sourceTag == "gemini"
            || effectiveSource == "google-antigravity" || effectiveSource == "gemini"
        // Antigravity's PreToolUse is NOT a blocking approval: it was already answered
        // (``immediateStdout``), and holding it for an island card only stacked a
        // second prompt in front of Antigravity's own (#339).
        let isPermission = normalizedEventName == "PermissionRequest"
        let isQuestion = (normalizedEventName == "Notification" || eventName == "afterAgentThought")
            && json["question"] as? String != nil
        // A hook Cursor runs never waits on the island. Cursor does not import Claude
        // Code's PermissionRequest or Notification hook, and it reads a hook's stdout
        // against its own schema for the step: an answer in the island's format is not
        // one it acts on, and on a permission step (`preToolUse` among them) an answer
        // it cannot use blocks the tool. Printing nothing leaves the call to Cursor.
        // Nor does a hook whose edge does not wait (``Facts/edgeWaits``).
        let waitsForAnswer = (isPermission || isQuestion) && !isCursorPayload && facts.edgeWaits != false

        self.payload = json
        self.facts = facts
        self.eventName = eventName
        self.normalizedEventName = normalizedEventName
        self.sessionId = sessionId
        self.sessionIdIsFallback = sessionIdIsFallback
        self.source = effectiveSource
        self.isPermission = isPermission
        self.isQuestion = isQuestion
        self.waitsForAnswer = waitsForAnswer
        self.answerFormat = isGeminiBasedSource ? .geminiDecision : .verbatim
        // Gemini prints its own approval prompt in the terminal; give it a moment
        // to show before the island's card does.
        self.deliveryDelay = isGeminiBasedSource && isPermission ? 0.25 : 0
    }

    /// What the hook must print now that its event is known (see
    /// ``immediateStdout(sourceTag:eventName:)``): Antigravity wired through
    /// Gemini-style hooks names the event on stdin, not in `--event`.
    public var immediateStdout: String? {
        Self.immediateStdout(sourceTag: facts.sourceTag, eventName: eventName)
    }

    // MARK: - Terminal context

    /// Records where the hook runs: terminal app, multiplexer panes, tty,
    /// working directory — and, for an edge on another machine, which one.
    public mutating func addTerminalContext() {
        var json = payload
        let env = facts.environment

        // Terminal app identification (only include when present)
        if let termApp = env["TERM_PROGRAM"], !termApp.isEmpty {
            json["_term_app"] = termApp
        }
        if let termBundle = env["__CFBundleIdentifier"], !termBundle.isEmpty {
            json["_term_bundle"] = termBundle
        }
        // ChatGPT starts Codex Desktop's app-server without __CFBundleIdentifier.
        // Without a bundle its hooks were keyed as a CLI thread, a second card next
        // to the `codexapp:` one discovery makes for the same Desktop thread.
        if Self.nonEmptyString(json["_term_bundle"]) == nil, source == "codex" {
            let ancestors = facts.ancestry.map {
                ProcessAncestor(
                    pid: $0.pid,
                    executablePath: $0.executablePath,
                    arguments: $0.arguments(),
                    bundleIdentifier: $0.bundleIdentifier()
                )
            }
            if let desktopBundle = CLIProcessResolver.codexDesktopTermBundle(ancestry: ancestors) {
                json["_term_bundle"] = desktopBundle
            }
        }

        // iTerm2 session — extract GUID after "w0t0p0:" prefix for AppleScript matching
        if let iterm = env["ITERM_SESSION_ID"], !iterm.isEmpty {
            if let colonIdx = iterm.firstIndex(of: ":") {
                json["_iterm_session"] = String(iterm[iterm.index(after: colonIdx)...])
            } else {
                json["_iterm_session"] = iterm
            }
        }

        // Kitty window
        if let kitty = env["KITTY_WINDOW_ID"], !kitty.isEmpty {
            json["_kitty_window"] = kitty
        }
        // kitty's remote-control socket (KITTY_LISTEN_ON), set only when the user
        // enabled listen_on. `kitten @` without `--to` needs a controlling tty,
        // which a GUI app does not have, so without this address the jump can
        // only raise the app instead of switching to the session's tab.
        if let listenOn = env["KITTY_LISTEN_ON"], !listenOn.isEmpty {
            json["_kitty_listen_on"] = listenOn
        }

        // tmux detection — deep info collection
        if let tmux = env["TMUX"], !tmux.isEmpty {
            json["_tmux"] = tmux
            if let pane = env["TMUX_PANE"], !pane.isEmpty {
                json["_tmux_pane"] = pane
                // The client tty tells which terminal window shows the pane.
                if let clientTTY = facts.tmuxClientTTY(pane) {
                    json["_tmux_client_tty"] = clientTTY
                }
            }
        }

        // TTY path
        if let tty = facts.tty(), !tty.isEmpty {
            json["_tty"] = tty
        }

        // cmux surface / workspace (env vars injected by cmux)
        // cmux auto-injects CMUX_SURFACE_ID and CMUX_WORKSPACE_ID into each terminal on launch
        // Bridge simply carries them into the payload during env collection; no extra process calls needed
        if let cmuxSurface = env["CMUX_SURFACE_ID"], !cmuxSurface.isEmpty {
            json["_cmux_surface_id"] = cmuxSurface
        }
        if let cmuxWorkspace = env["CMUX_WORKSPACE_ID"], !cmuxWorkspace.isEmpty {
            json["_cmux_workspace_id"] = cmuxWorkspace
        }

        // Zellij multiplexer detection — pane id + optional session name for precise tab focus
        if let zellij = env["ZELLIJ"], !zellij.isEmpty {
            json["_zellij"] = zellij
            if let pane = env["ZELLIJ_PANE_ID"], !pane.isEmpty {
                json["_zellij_pane_id"] = pane
            }
            if let session = env["ZELLIJ_SESSION_NAME"], !session.isEmpty {
                json["_zellij_session_name"] = session
            }
        }

        // WezTerm / Kaku pane id — both forks set WEZTERM_PANE; Kaku is a WezTerm fork (bundle id fun.tw93.kaku)
        if let weztermPane = env["WEZTERM_PANE"], !weztermPane.isEmpty {
            json["_wezterm_pane"] = weztermPane
        }

        // Herdr injects an exact pane plus owning server socket into every managed pane.
        // Require the complete pair so a pane id is never sent to Herdr's default server.
        if env["HERDR_ENV"] == "1",
           let pane = env["HERDR_PANE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines), !pane.isEmpty,
           let socket = env["HERDR_SOCKET_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !socket.isEmpty {
            json["_herdr_pane_id"] = pane
            json["_herdr_socket_path"] = socket
            if let binary = env["HERDR_BIN_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines), !binary.isEmpty {
                json["_herdr_bin_path"] = binary
            }
        }

        // Superset (Electron agent-orchestration terminal) — TERM_PROGRAM is spoofed to "kitty"
        // and __CFBundleIdentifier is stripped from the PTY env, so the only reliable Superset
        // signal is its own SUPERSET_* env vars (which survive Superset's env allowlist). The mere
        // presence of any SUPERSET_* var uniquely means "running inside Superset"; the activator
        // uses that to route to com.superset.desktop instead of the real kitty app. (#213)
        if let supersetWs = env["SUPERSET_WORKSPACE_ID"], !supersetWs.isEmpty {
            json["_superset_workspace_id"] = supersetWs
        }
        // Pane / terminal id — captured for future pane-precision if Superset ever ships a focus CLI;
        // either var's presence is also a reliable Superset signal on its own.
        if let supersetPane = env["SUPERSET_PANE_ID"] ?? env["SUPERSET_TERMINAL_ID"], !supersetPane.isEmpty {
            json["_superset_pane_id"] = supersetPane
        }

        // Orca (Electron ADE that runs each task in its own git worktree + terminal).
        // TERM_PROGRAM is normally "Orca", but Orca deletes it for Claude Agent Teams
        // sessions — with no __CFBundleIdentifier in the PTY env either, click-to-jump
        // then fell all the way through to `bringToFront("Terminal")` and opened a blank
        // Terminal.app window. ORCA_TERMINAL_HANDLE is also the handle
        // `orca terminal switch --terminal` takes, which is the only way to tell two
        // worktrees of the same repo apart. (#302)
        if let orcaHandle = env["ORCA_TERMINAL_HANDLE"], !orcaHandle.isEmpty {
            json["_orca_terminal_handle"] = orcaHandle
        }
        if let orcaWorktree = env["ORCA_WORKTREE_ID"], !orcaWorktree.isEmpty {
            json["_orca_worktree_id"] = orcaWorktree
        }

        // Claude Desktop Code tab: Claude Desktop's own id for this session. The hook's
        // session_id is the CLI's id, which Claude Desktop's `claude://code/continue`
        // link does not accept; this one opens that exact session on click.
        if let host = env[ClaudeDesktopCodeSession.hostSessionEnvKey], !host.isEmpty {
            json["_claude_desktop_session"] = host
        }

        // Inject cwd if not already present. Gemini CLI / Google Antigravity hooks do not
        // include a `cwd` field, so CodeIsland cannot resolve the project name and falls back
        // to "Session". Populating it here lets the approval card show the actual folder name.
        if json["cwd"] == nil, let workingDirectory = facts.workingDirectory() {
            json["cwd"] = workingDirectory
        }

        // An edge on another machine: which one. A payload that names its host
        // already (the remote OpenCode plugin's) keeps it.
        if let host = facts.remoteHost {
            if Self.nonEmptyString(json["_remote_host_id"]) == nil, Self.nonEmptyString(host.id) != nil {
                json["_remote_host_id"] = host.id
            }
            if Self.nonEmptyString(json["_remote_host_name"]) == nil, Self.nonEmptyString(host.name) != nil {
                json["_remote_host_name"] = host.name
            }
        }

        payload = json
    }

    // MARK: - The answer

    /// What the hook prints for the island's `response`: nil when it prints
    /// nothing (it does not wait for an answer, or there is none).
    public func stdout(forAnswer response: Data) -> Data? {
        guard waitsForAnswer, !response.isEmpty else { return nil }
        switch answerFormat {
        case .verbatim:
            return response
        case .geminiDecision:
            if let jsonObj = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
               let hookOutput = jsonObj["hookSpecificOutput"] as? [String: Any],
               let decisionObj = hookOutput["decision"] as? [String: Any],
               let behavior = decisionObj["behavior"] as? String {
                let translatedBehavior = (behavior == "allow" || behavior == "always") ? "allow" : "deny"
                let responseDict = ["decision": translatedBehavior]
                return (try? JSONSerialization.data(withJSONObject: responseDict)) ?? response
            }
            // Fallback: search for "allow" or "deny" in raw string to be resilient
            let responseStr = String(data: response, encoding: .utf8) ?? ""
            if responseStr.contains("\"behavior\":\"allow\"") || responseStr.contains("\"behavior\":\"always\"") {
                return Data("{\"decision\":\"allow\"}".utf8)
            } else if responseStr.contains("\"behavior\":\"deny\"") {
                return Data("{\"decision\":\"deny\"}".utf8)
            }
            return response
        }
    }

    // MARK: - Helpers

    /// Whether the payload names no event: no `hook_event_name`, or an empty
    /// one — as the remote hook reads it when it decides to wait.
    static func namesNoEvent(_ json: [String: Any]) -> Bool {
        guard let name = json["hook_event_name"] else { return true }
        return name as? String == ""
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
