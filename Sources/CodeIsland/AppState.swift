import SwiftUI
import CoreServices
import os.log
import SQLite3
import CryptoKit
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

/// FSEventStream context target. Callbacks hold an unretained pointer to this
/// box (not `AppState`), and reach the owner only through `weak`, so queued
/// main-queue deliveries stay safe if `AppState` tears down off the main actor.
private final class ProjectsWatcherBox: @unchecked Sendable {
    weak var appState: AppState?
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func handleChange() {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        guard !isCancelled else { return }
        appState?.handleProjectsDirChange()
    }
}

struct CodexSubagentMetadata: Equatable, Sendable {
    let parentThreadId: String
    let agentType: String?
    let agentNickname: String?
}

private struct CodexSpawnEdgeRecord {
    let metadata: CodexSubagentMetadata
    let status: String?
    let transcriptPath: String?
}

private enum CodexTranscriptSubagentInspection {
    /// The first line could not be established as a valid `session_meta`.
    case unavailable
    /// A valid root `session_meta` explicitly contains no subagent relation.
    case root
    case subagent(CodexSubagentMetadata)
}

struct ProcessIdentity: Equatable {
    let pid: pid_t
    let startTime: Date?
}

struct CodexDiscoveryIdentity: Equatable, Sendable {
    let sessionId: String
    let providerSessionId: String?
    let termBundleId: String?
}

struct CodexProcessDiscoveryCandidate: Sendable {
    let pid: pid_t
    let cwd: String?
    let startTime: Date?
    let isDesktop: Bool
}

enum CodexTranscriptOrigin: Equatable, Sendable {
    case desktop
    case cli
    case unknown
}

/// A Codex Desktop thread recovered from Codex's local state database.
///
/// Recent Codex Desktop builds run their app-server with `/` as the process CWD,
/// so the CLI discovery path cannot map that process back to a project. Keeping
/// this small value type separate lets discovery hydrate native-app sessions from
/// the authoritative state DB without exposing the private `DiscoveredSession`.
struct CodexDesktopThreadRecord: Sendable {
    let sessionId: String
    let cwd: String
    let model: String?
    let modifiedAt: Date
    let recentMessages: [ChatMessage]
    let transcriptPath: String
    let status: AgentStatus
    let subagentMetadata: CodexSubagentMetadata?
    let subagentStatus: String?
}

@MainActor
@Observable
final class AppState {
    /// Snapshot of a hook event accepted by HookServer, kept for diagnostics
    /// export (#103). Stored in a fixed-size ring so we can attach the recent
    /// hook stream to bug reports without pulling in full payloads.
    ///
    /// `payloadKeys` lists the top-level JSON field names the hook arrived
    /// with (sorted, no values), and `promptPreview` is a 80-char prefix of
    /// any extracted user prompt. Together those let us tell at a glance
    /// whether a hook fired with an empty / missing prompt vs. fired with a
    /// prompt that the UI then dropped.
    struct DiagnosticHookEvent: Sendable {
        let timestamp: Date
        let source: String?
        let sessionId: String?
        let eventName: String
        let toolName: String?
        let viaPlugin: Bool
        let payloadKeys: [String]
        let promptPreview: String?
    }

    var sessions: [String: SessionSnapshot] = [:]
    var activeSessionId: String?
    var permissionQueue: [PermissionRequest] = []
    var questionQueue: [QuestionRequest] = []

    @ObservationIgnored
    private(set) var recentHookEvents: [DiagnosticHookEvent] = []
    @ObservationIgnored
    private let maxRecentHookEvents = 100
    @ObservationIgnored
    var questionTerminalFrontmostDetector: (SessionSnapshot) -> Bool =
        TerminalVisibilityDetector.isTerminalFrontmostForSession

    func recordHookEvent(
        source: String?,
        sessionId: String?,
        eventName: String,
        toolName: String?,
        viaPlugin: Bool,
        payloadKeys: [String],
        promptPreview: String?
    ) {
        recentHookEvents.append(DiagnosticHookEvent(
            timestamp: Date(),
            source: source,
            sessionId: sessionId,
            eventName: eventName,
            toolName: toolName,
            viaPlugin: viaPlugin,
            payloadKeys: payloadKeys,
            promptPreview: promptPreview
        ))
        if recentHookEvents.count > maxRecentHookEvents {
            recentHookEvents.removeFirst(recentHookEvents.count - maxRecentHookEvents)
        }
    }
    /// Cache of in-flight PreToolUse records keyed by tool_use_id. Used to correlate
    /// permission requests back to their originating tool call. See AppState+ToolUseCache.
    @ObservationIgnored
    var pendingToolUses: [String: PreToolUseRecord] = [:]
    /// Records the transcript path currently watched for each session so we only
    /// reattach when the path actually changes. See AppState+TranscriptTailer.
    @ObservationIgnored
    var attachedTranscriptPaths: [String: String] = [:]
    /// Token for the exact JSONLTailer attachment currently owned by a session.
    /// A queued delta from an older attachment must not mutate a same-id session
    /// that was closed and subsequently re-created.
    @ObservationIgnored
    var attachedTranscriptTokens: [String: UUID] = [:]
    /// Watches active session transcripts for appended assistant lines. Lazily
    /// constructed so the delta handler can safely capture `self`.
    @ObservationIgnored
    lazy var transcriptTailer: JSONLTailer = JSONLTailer { [weak self] delta in
        Task { @MainActor in
            self?.applyTranscriptDelta(delta)
        }
    }
    /// Active JSON-RPC client connected to `codex app-server`, or nil when
    /// Codex Desktop isn't running. See AppState+CodexAppServer.
    @ObservationIgnored
    var codexAppServerClient: CodexAppServerClient?
    /// NSWorkspace launch/terminate observers tracking Codex Desktop.
    @ObservationIgnored
    var codexAppServerObservers: [NSObjectProtocol]?
    /// Backoff loop used when the auxiliary app-server exits while the Desktop
    /// host remains open.
    @ObservationIgnored
    nonisolated(unsafe) var codexAppServerReconnectTask: Task<Void, Never>?
    /// Prevent an in-flight/stale state-DB scan from recreating a thread after
    /// app-server delivered `thread/closed`.
    @ObservationIgnored
    var closedCodexAppThreads: [String: Date] = [:]

    /// Computed: first item in permission queue (backward compat for UI reads)
    var pendingPermission: PermissionRequest? { permissionQueue.first }
    /// Computed: first item in question queue
    var pendingQuestion: QuestionRequest? { questionQueue.first }

    /// The queued request belonging to a specific session. A card is addressed
    /// by session, so it must render (and resolve) that session's request
    /// rather than whatever currently sits at the head of the queue. (#308)
    func pendingPermission(forSession sessionId: String) -> PermissionRequest? {
        permissionQueue.first { ($0.event.sessionId ?? "default") == sessionId }
    }

    func pendingQuestion(forSession sessionId: String) -> QuestionRequest? {
        questionQueue.first { ($0.event.sessionId ?? "default") == sessionId }
    }

    /// 1-based position for a card's "N of M" label. The card may be showing a
    /// request that is not the head, so the position has to be looked up. (#308)
    func permissionQueuePosition(forSession sessionId: String) -> Int {
        (permissionQueue.firstIndex { ($0.event.sessionId ?? "default") == sessionId } ?? 0) + 1
    }

    func questionQueuePosition(forSession sessionId: String) -> Int {
        (questionQueue.firstIndex { ($0.event.sessionId ?? "default") == sessionId } ?? 0) + 1
    }
    /// Preview-only: mock question payload for DebugHarness (no continuation needed)
    var previewQuestionPayload: QuestionPayload?
    var surface: IslandSurface = .collapsed {
        didSet {
            // Any expansion counts as "seen" for the glance completion dot.
            if surface.isExpanded, glanceCompletionActive {
                glanceDismissTask?.cancel()
                glanceCompletionActive = false
            }
            if surface.isExpanded {
                refreshClaudeUsageIfStale()
            }
        }
    }

    /// Local-transcript token usage shown in the session-list footer.
    /// Refreshed lazily on panel expansion (no resident timer, no API calls).
    var claudeUsage: ClaudeUsageScanner.Snapshot?
    private var usageScanInFlight = false
    /// Incremental parse state — round-trips through each detached scan so
    /// growing transcripts are only read past their last consumed offset.
    private var usageFileCache = ClaudeUsageScanner.FileCache()

    /// Glance completion mode: an agent finished while the pill was collapsed —
    /// light the dot instead of expanding. Cleared when the user expands the
    /// panel, with a long failsafe so a missed dot never lingers forever.
    var glanceCompletionActive = false
    private var glanceDismissTask: Task<Void, Never>?

    var justCompletedSessionId: String? {
        if case .completionCard(let id) = surface { return id }
        return nil
    }

    private var maxHistory: Int { SettingsManager.shared.maxToolHistory }
    /// Torn down from `deinit`, which may run off the main actor (e.g. async
    /// XCTest ARC). Only mutated on the main actor while `self` is alive.
    @ObservationIgnored
    nonisolated(unsafe) private var cleanupTimer: Timer?
    private var autoCollapseTask: Task<Void, Never>?
    private var completionQueue: [String] = []
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false
    /// Auto-collapse timer fired but mouse is inside panel — defer collapse until mouse leaves
    var deferCollapseOnMouseLeave = false
    /// `attachParentPid` is the monitored process's ppid captured when the monitor was
    /// attached. Processes that already had ppid <= 1 at attach time are launchd-managed
    /// daemons (e.g. a Hermes gateway with KeepAlive=true), NOT orphans of a closed
    /// terminal — they must never be terminated by orphan cleanup (#243).
    /// Cancelled from `deinit` off the main actor.
    @ObservationIgnored
    nonisolated(unsafe) private var processMonitors: [String: (source: DispatchSourceProcess, process: ProcessIdentity, attachParentPid: pid_t?)] = [:]
    private var exitingSessions: [String: ProcessIdentity] = [:]
    @ObservationIgnored
    nonisolated(unsafe) private var saveTimer: Timer?
    @ObservationIgnored
    nonisolated(unsafe) private var fsEventStream: FSEventStreamRef?
    @ObservationIgnored
    nonisolated(unsafe) private var projectsWatcherBox: ProjectsWatcherBox?
    private var lastFSScanTime: Date = .distantPast
    @ObservationIgnored
    nonisolated(unsafe) private var discoveryScanTask: Task<Void, Never>?
    private var pendingDiscoveryRescan = false
    @ObservationIgnored
    nonisolated(unsafe) private var codexDesktopDiscoveryScanTask: Task<Void, Never>?
    private var lastCodexDesktopDiscoveryPollAt: Date?
    private var isShowingCompletion: Bool {
        if case .completionCard = surface { return true }
        return false
    }
    /// True when an interactive card (approval or question) is visible — completions must queue.
    private var isShowingInteractive: Bool {
        switch surface {
        case .approvalCard, .questionCard: return true
        default: return false
        }
    }
    private var modelReadRetryAt: [String: Date] = [:]

    private var dismissedPermissionSessionIds: Set<String> = []
    private func nextVisiblePermissionIndex() -> Int? {
        permissionQueue.firstIndex { request in
            let sid = request.event.sessionId ?? "default"
            return !dismissedPermissionSessionIds.contains(sid)
        }
    }

    var rotatingSessionId: String?
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }
    @ObservationIgnored
    nonisolated(unsafe) private var rotationTimer: Timer?

    private func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupIdleSessions()
            }
        }
    }

    /// Agents whose tracked process is a long-lived daemon rather than a
    /// per-turn CLI. For these, neither process exit nor SessionEnd marks the
    /// end of a reply, so a card that has gone quiet with no tool in flight is
    /// the only evidence the turn is over. (#303)
    nonisolated static let daemonBackedSources: Set<String> = ["hermes"]

    /// How long a daemon-backed session may sit on bare "thinking" with no tool
    /// and no new events before it settles. Long enough that a mid-turn
    /// `post_llm_call` (followed within a second or two by the next
    /// `pre_tool_call`) never flickers the card to idle.
    nonisolated static let daemonTurnSettleTimeout: TimeInterval = 20

    nonisolated static func isDaemonBackedSource(_ source: String?) -> Bool {
        guard let normalized = SessionSnapshot.normalizedSupportedSource(source) else { return false }
        return daemonBackedSources.contains(normalized)
    }

    private func cleanupIdleSessions() {
        // 1. Verify monitored PIDs are still alive (DispatchSource can silently miss exits)
        //    Also kill orphaned processes (ppid <= 1, terminal closed but process survived).
        var deadMonitors: [(String, ProcessIdentity)] = []
        var orphaned: [(String, pid_t)] = []
        for (sessionId, monitor) in processMonitors {
            let process = monitor.process
            let pid = process.pid
            // Check if the monitored process is still the same live process.
            if !Self.isLiveProcess(process) {
                deadMonitors.append((sessionId, process))
                continue
            }
            // Check for orphaned processes: ppid <= 1 now, but only if the process had a
            // real parent when we attached. A process whose ppid was already <= 1 at attach
            // time is a launchd-managed daemon, not a terminal orphan — killing it puts
            // KeepAlive daemons into a SIGTERM/restart loop (#243).
            if Self.isReparentedOrphan(currentParentPid: Self.parentPid(of: pid), attachParentPid: monitor.attachParentPid)
                && shouldTerminateOrphanedProcess(sessionId: sessionId, pid: pid) {
                orphaned.append((sessionId, pid))
            }
        }
        for (sessionId, process) in deadMonitors {
            // PID gone but monitor didn't fire — treat as process exit so session is removed
            // promptly (after 5s grace) instead of lingering for 10 minutes.
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
        for (sessionId, pid) in orphaned {
            log.notice("⚠️ terminating reparented orphan pid=\(pid, privacy: .public) session=\(sessionId, privacy: .public)")
            kill(pid, SIGTERM)
            removeSession(sessionId)
        }

        // 2. Reset likely-stuck sessions only when we have no process monitor.
        //    If the process is still monitored/alive, trust explicit Stop/SessionEnd or
        //    process exit instead of synthesizing idle and risking false-idle mid-thought.
        //    - No tool + no monitor: 300s (agents can think for several minutes)
        //    - Has tool + no monitor: 180s (long build / deep thinking with missed exit)
        //    - waitingApproval/Question + no monitor: 300s (connection likely dropped)
        //
        //    Skip remote sessions: they NEVER have a local process monitor (the CLI runs
        //    on the remote host), and a long-running remote task that doesn't fire hook
        //    events for >180s shouldn't be force-flipped to idle here — it'll then be
        //    swept by Section 4. Remote session lifecycle is driven by remote-end hooks
        //    and SSH connection state in RemoteManager, not by local timeouts. (#121)
        for (key, session) in sessions
            where processMonitors[key] == nil
            && session.status != .idle
            && !session.isRemote {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            let threshold: TimeInterval
            switch session.status {
            case .waitingApproval, .waitingQuestion: threshold = 300
            default: threshold = session.currentTool != nil ? 180 : 300
            }
            if elapsed > threshold {
                sessions[key]?.status = .idle
                sessions[key]?.currentTool = nil
                sessions[key]?.toolDescription = nil
            }
        }

        // 2b. Some CLIs keep their parent process alive across requests, so a missed Stop hook
        // can leave the UI stuck in bare "thinking" forever after an interrupt. If we've had no
        // follow-up hook activity for a long time and there isn't even a live tool/description,
        // reset that silent processing state back to idle.
        let monitoredThinkingTimeout: TimeInterval = 300
        let nativeAppThinkingTimeout: TimeInterval = 30
        let codexTerminalTurnSettleTime: TimeInterval = 3
        for (key, session) in sessions
            where session.status == .processing
            && session.currentTool == nil
            && session.toolDescription == nil {
            let elapsed = -session.lastActivity.timeIntervalSinceNow
            // Daemon-backed agents settle on a short timeout whether or not we
            // hold a process monitor: their backend never exits, so a live PID
            // says nothing about whether the turn is over (#303).
            if Self.isDaemonBackedSource(session.source) {
                if elapsed > Self.daemonTurnSettleTimeout {
                    sessions[key]?.status = .idle
                }
                continue
            }
            guard processMonitors[key] != nil else { continue }
            if session.isNativeAppMode,
               elapsed >= codexTerminalTurnSettleTime,
               let finishedAt = Self.nativeAppFinishedTurnTimestamp(sessionId: key, session: session),
               finishedAt >= session.lastActivity.addingTimeInterval(-1) {
                sessions[key]?.status = .idle
                continue
            }
            // Native apps write transcripts synchronously — if the transcript check above
            // didn't find a stop marker after 30s, the session is almost certainly idle.
            if session.isNativeAppMode, elapsed > nativeAppThinkingTimeout {
                sessions[key]?.status = .idle
                continue
            }
            if elapsed > monitoredThinkingTimeout {
                sessions[key]?.status = .idle
            }
        }

        // 3. Verify PID liveness for sessions without monitors but with a known PID.
        //    If the process died: idle sessions are removed directly (no grace needed),
        //    non-idle sessions go through handleProcessExit for the 5s grace period.
        for (key, session) in sessions where processMonitors[key] == nil {
            guard let process = resolvedSessionProcessIdentity(for: key) else { continue }
            if !Self.isLiveProcess(process) {
                if exitingSessions[key] == process { continue }
                if session.status == .idle {
                    removeSession(key)
                } else {
                    handleProcessExit(sessionId: key, exitedProcess: process)
                }
            }
        }

        // 3b. Native app sessions (OpenCode desktop, Codex app, etc.) whose app is no longer
        //     running should be cleaned up — these apps can't send SessionEnd when force-quit.
        //     Don't check PID liveness here: the dedup in integrateDiscovered may have
        //     reattached a CLI PID to the old native app session, keeping it alive incorrectly.
        // `NSWorkspace.runningApplications` is not a cheap array read: touching
        // `bundleIdentifier` on each entry goes out to LaunchServices over XPC,
        // and this timer fires every 3 seconds forever. Only two things below
        // need it, and on an idle Mac neither does — so build it lazily and, in
        // the common case, never at all (#299).
        var cachedRunningBundleIds: Set<String>?
        func runningBundleIds() -> Set<String> {
            if let cachedRunningBundleIds { return cachedRunningBundleIds }
            let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            cachedRunningBundleIds = ids
            return ids
        }

        if sessions.values.contains(where: { $0.isNativeAppMode }) {
            let running = runningBundleIds()
            for (key, session) in sessions {
                guard session.isNativeAppMode,
                      let bundleId = session.termBundleId,
                      !running.contains(bundleId) else { continue }
                removeSession(key)
            }
        }
        let discoveryPollNow = Date()
        // Check the cheap clock predicate before the expensive app list: the poll
        // is rate-limited to every 6s, so five of every six ticks can skip it.
        let codexPollIntervalElapsed = lastCodexDesktopDiscoveryPollAt.map {
            discoveryPollNow.timeIntervalSince($0) >= 6
        } ?? true
        if codexPollIntervalElapsed, Self.shouldPollCodexDesktopDiscovery(
            runningBundleIdentifiers: runningBundleIds(),
            lastPollAt: lastCodexDesktopDiscoveryPollAt,
            now: discoveryPollNow
        ) {
            lastCodexDesktopDiscoveryPollAt = discoveryPollNow
            requestCodexDesktopDiscoveryScan()
        }

        // 4. Remove idle sessions past timeout (user setting, or 10 min default for no-monitor sessions)
        let userTimeout = SettingsManager.shared.sessionTimeout
        let defaultStaleMinutes = 10  // for sessions without process monitor
        for (key, session) in sessions where session.status == .idle {
            let idleMinutes = Int(-session.lastActivity.timeIntervalSinceNow / 60)
            let hasMonitor = processMonitors[key] != nil
            if userTimeout > 0 && idleMinutes >= userTimeout {
                // User-configured timeout applies to all sessions
                removeSession(key)
            } else if !hasMonitor && idleMinutes >= defaultStaleMinutes {
                // No process monitor (hook-only sessions): clean up after 10 min idle
                removeSession(key)
            }
        }

        // 5. Reclaim memory for abandoned tool_use_id cache entries.
        prunePendingToolUses()

        refreshDerivedState()
    }

    private nonisolated static func currentPluginSessionMode() -> String {
        UserDefaults.standard.string(forKey: SettingsKey.pluginSessionMode)
            ?? SettingsDefaults.pluginSessionMode
    }

    // MARK: - Process Monitoring (DispatchSource)

    private func currentSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let pid = sessions[sessionId]?.cliPid, pid > 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: sessions[sessionId]?.cliStartTime)
    }

    private func resolvedSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let process = currentSessionProcessIdentity(for: sessionId) else { return nil }
        if let resolved = Self.trackedProcessIdentity(for: process.pid, source: sessions[sessionId]?.source) {
            if resolved != process {
                setSessionProcessIdentity(resolved, for: sessionId)
            }
            return resolved
        }
        if process.startTime != nil { return process }
        guard let refreshed = Self.liveProcessIdentity(for: process.pid) else { return process }
        setSessionProcessIdentity(refreshed, for: sessionId)
        return refreshed
    }

    private func setSessionProcessIdentity(_ process: ProcessIdentity, for sessionId: String) {
        sessions[sessionId]?.cliPid = process.pid
        sessions[sessionId]?.cliStartTime = process.startTime
    }

    private func shouldTerminateOrphanedProcess(sessionId: String, pid: pid_t) -> Bool {
        guard let session = sessions[sessionId] else { return true }
        if session.isNativeAppMode { return false }
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return true }
        return !Self.isNativeAppProcess(pid, source: source)
    }

    /// Current ppid of `pid`, or nil if the process is gone / info is unavailable.
    nonisolated static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// A process counts as a terminal orphan only when it USED to have a real parent
    /// (attachParentPid > 1) and has since been reparented to launchd/init (ppid <= 1).
    /// Daemons started by launchd have ppid <= 1 from the beginning and are never
    /// orphans, no matter how long they run (#243). Unknown attach ppid stays safe: no kill.
    nonisolated static func isReparentedOrphan(currentParentPid: pid_t?, attachParentPid: pid_t?) -> Bool {
        guard let currentParentPid, currentParentPid <= 1 else { return false }
        guard let attachParentPid, attachParentPid > 1 else { return false }
        return true
    }

    private nonisolated static func liveProcessIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: getProcessStartTime(pid))
    }

    private nonisolated static func isLiveProcess(_ process: ProcessIdentity) -> Bool {
        guard process.pid > 0, kill(process.pid, 0) == 0 else { return false }
        guard let expectedStart = process.startTime else { return true }
        return getProcessStartTime(process.pid) == expectedStart
    }

    private nonisolated static func trackedProcessIdentity(for pid: pid_t, source: String?) -> ProcessIdentity? {
        guard pid > 0 else { return nil }

        var currentPid: pid_t? = pid
        var visited = Set<pid_t>()
        var firstLiveProcess: ProcessIdentity?

        for _ in 0..<6 {
            guard let candidatePid = currentPid,
                  candidatePid > 0,
                  !visited.contains(candidatePid),
                  let process = liveProcessIdentity(for: candidatePid) else {
                break
            }

            visited.insert(candidatePid)
            if firstLiveProcess == nil {
                firstLiveProcess = process
            }
            if let path = executablePath(for: candidatePid),
               CLIProcessResolver.sourceMatchesExecutablePath(path, source: source) {
                return process
            }
            currentPid = parentPID(for: candidatePid)
        }

        return firstLiveProcess
    }

    private nonisolated static func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0, info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private nonisolated static func isNativeAppProcess(_ pid: pid_t, source: String) -> Bool {
        guard let executable = executablePath(for: pid) else { return false }
        let path = executable.lowercased()
        switch source {
        case "cursor":     return path.contains("/cursor.app/contents/")
        case "trae":       return path.contains("/trae.app/contents/")
        case "traecn":     return path.contains("/trae.app/contents/") || path.contains("/traecn.app/contents/")
        case "qoder":      return path.contains("/qoder.app/contents/")
        // QoderWork desktop app (#249) — bundle id undocumented; the standard
        // /Applications/QoderWork.app layout is assumed, pending real-install
        // verification.
        case "qoderwork":  return path.contains("/qoderwork.app/contents/")
        case "droid":      return path.contains("/factory.app/contents/")
        case "codebuddy":  return path.contains("/codebuddy.app/contents/")
        case "codybuddycn": return path.contains("/codebuddycn.app/contents/") || path.contains("/codebuddy.app/contents/")
        case "stepfun":    return path.contains("/stepfun.app/contents/")
        case "codex":      return isCodexExecutablePath(executable)
        case "opencode":   return path.contains("/opencode.app/contents/")
        case "antigravity": return path.contains("/antigravity.app/contents/")
        // Google Antigravity IDE — host app is Antigravity.app. Same .app path as
        // the fork, but the check is per-source so a "google-antigravity" session
        // (whose host genuinely IS Antigravity.app) never collides with the fork's
        // "antigravity" CLI sessions (#215).
        case "google-antigravity": return path.contains("/antigravity.app/contents/")
        case "workbuddy":   return path.contains("/workbuddy.app/contents/")
        case "hermes":      return path.contains("/hermes.app/contents/")
        // Claude Code Desktop (#211): local Code-tab sessions live inside Claude.app.
        case "claude":      return path.contains("/claude.app/contents/")
        case "zcode":       return path.contains("/zcode.app/contents/")
        default:           return false
        }
    }

    /// Watch a Claude process for exit — waits a grace period before removing, in case the
    /// process restarts (e.g. auto-update) or a new hook event re-activates the session.
    private func monitorProcess(sessionId: String, pid: pid_t) {
        guard let process = Self.liveProcessIdentity(for: pid) else {
            handleProcessExit(sessionId: sessionId, exitedProcess: ProcessIdentity(pid: pid, startTime: nil))
            return
        }
        monitorProcess(sessionId: sessionId, process: process)
    }

    private func monitorProcess(sessionId: String, process: ProcessIdentity) {
        guard processMonitors[sessionId] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                guard let self = self, self.sessions[sessionId] != nil else { return }
                self.handleProcessExit(sessionId: sessionId, exitedProcess: process)
            }
        }
        source.resume()
        processMonitors[sessionId] = (source: source, process: process, attachParentPid: Self.parentPid(of: process.pid))
        exitingSessions.removeValue(forKey: sessionId)

        // Keep cliPid aligned with the monitored process unless we already have a different
        // live PID from a stronger source (hooks beat heuristic discovery).
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId) {
            if !Self.isLiveProcess(currentProcess) || currentProcess.pid == process.pid {
                setSessionProcessIdentity(process, for: sessionId)
            }
        } else {
            setSessionProcessIdentity(process, for: sessionId)
        }

        // Safety: if process already exited before monitor started
        if !Self.isLiveProcess(process) {
            handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
    }

    /// Grace period after process exit — gives 5s for a replacement process or fresh hook event
    /// to claim the session before removal. Prevents flicker during agent restarts.
    private func handleProcessExit(sessionId: String, exitedProcess: ProcessIdentity) {
        // Tear down the dead monitor immediately
        stopMonitor(sessionId)

        // If the session already moved to a replacement live PID, reattach immediately and
        // avoid flashing idle because a stale/wrong monitor exited.
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId),
           currentProcess != exitedProcess, Self.isLiveProcess(currentProcess) {
            monitorProcess(sessionId: sessionId, process: currentProcess)
            return
        }

        if exitingSessions[sessionId] == exitedProcess {
            return
        }
        exitingSessions[sessionId] = exitedProcess

        // If session was actively doing something, reset state right away so the UI
        // doesn't show a stale "running Edit" while we wait through the grace period.
        if let status = sessions[sessionId]?.status, status != .idle {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
            // Drain any pending permissions/questions — the process is gone
            drainPermissions(forSession: sessionId, reason: "process-exited")
            drainQuestions(forSession: sessionId, reason: "process-exited")
            refreshDerivedState()
        }

        let exitTime = Date()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self = self, self.sessions[sessionId] != nil else { return }
            guard self.exitingSessions[sessionId] == exitedProcess else { return }

            // A new monitor was attached during the grace period (new process took over)
            if self.processMonitors[sessionId] != nil { return }

            // Session was taken over by a different process (e.g. auto-update/restart):
            // cliPid changed to a new PID that's still alive → attach monitor, don't remove.
            if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
               currentProcess != exitedProcess, Self.isLiveProcess(currentProcess) {
                self.monitorProcess(sessionId: sessionId, process: currentProcess)
                return
            }

            // Original process confirmed dead — remove regardless of lastActivity.
            // This prevents a race where an in-flight hook event (e.g. "Stop") updates
            // lastActivity after exitTime, causing the session to linger for 10+ minutes.
            if !Self.isLiveProcess(exitedProcess) {
                self.removeSession(sessionId)
                return
            }

            // Session received fresh activity during the grace period and the original PID is
            // still alive — the exit signal was stale/spurious, so restore monitoring.
            if let lastActivity = self.sessions[sessionId]?.lastActivity,
               lastActivity > exitTime {
                self.monitorProcess(sessionId: sessionId, process: exitedProcess)
                return
            }

            self.removeSession(sessionId)
        }
    }

    private func stopMonitor(_ sessionId: String) {
        processMonitors[sessionId]?.source.cancel()
        processMonitors.removeValue(forKey: sessionId)
    }

    /// Remove a session, clean up its monitor, and resume any pending continuations.
    /// Every removal path (cleanup timer, process exit, reducer effect) goes through here
    /// so leaked continuations / connections are impossible.
    func removeSession(_ sessionId: String) {
        // Resume ALL pending continuations for this session
        drainPermissions(forSession: sessionId, reason: "removeSession")
        drainQuestions(forSession: sessionId, reason: "removeSession")

        if surface.sessionId == sessionId {
            autoCollapseTask?.cancel()
            if case .completionCard = surface {
                if !showNextPending() {
                    showNextCompletionOrCollapse()
                }
            } else {
                _ = showNextPending()
            }
        }
        sessions.removeValue(forKey: sessionId)
        stopMonitor(sessionId)
        detachTranscriptTailer(sessionId: sessionId)
        exitingSessions.removeValue(forKey: sessionId)
        modelReadRetryAt.removeValue(forKey: sessionId)
        completionQueue.removeAll { $0 == sessionId }
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        startRotationIfNeeded()
        refreshDerivedState()
        scheduleSave()
    }

    // MARK: - Compact bar mascot rotation

    /// Cached sorted active session IDs — refreshed by refreshActiveIds()
    private var cachedActiveIds: [String] = []

    private func refreshActiveIds() {
        cachedActiveIds = sessions
            .filter { $0.value.status != .idle }
            .sorted { a, b in
                let pa = statusPriority(a.value.status)
                let pb = statusPriority(b.value.status)
                if pa != pb { return pa > pb }
                // Same priority — most recently active first
                return a.value.lastActivity > b.value.lastActivity
            }
            .map(\.key)
    }

    /// Higher = more urgent, shown first in rotation
    private func statusPriority(_ status: AgentStatus) -> Int {
        switch status {
        case .waitingApproval: return 5
        case .waitingQuestion: return 4
        case .running:         return 3
        case .processing:      return 2
        case .idle:            return 0
        }
    }

    private func startRotationIfNeeded() {
        refreshActiveIds()
        if cachedActiveIds.count > 1 {
            // If the most urgent session changed, snap to it immediately
            if let top = cachedActiveIds.first, top != rotatingSessionId {
                let topStatus = sessions[top]?.status ?? .idle
                let currentStatus = rotatingSessionId.flatMap { sessions[$0]?.status } ?? .idle
                if statusPriority(topStatus) > statusPriority(currentStatus) {
                    rotatingSessionId = top
                }
            }
            if rotatingSessionId == nil || !cachedActiveIds.contains(rotatingSessionId!) {
                rotatingSessionId = cachedActiveIds.first
            }
            if rotationTimer == nil {
                let interval = TimeInterval(max(1, SettingsManager.shared.rotationInterval))
                rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                    Task { @MainActor in
                        self?.rotateToNextSession()
                    }
                }
            }
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            rotatingSessionId = nil
            // When rotation stops, ensure activeSessionId points to the remaining
            // active session (if any) so the collapsed bar doesn't stick on an idle one.
            if let active = cachedActiveIds.first,
               activeSessionId != active {
                activeSessionId = active
            }
        }
    }

    private func rotateToNextSession() {
        guard cachedActiveIds.count > 1 else {
            rotatingSessionId = nil
            return
        }
        if let current = rotatingSessionId, let idx = cachedActiveIds.firstIndex(of: current) {
            rotatingSessionId = cachedActiveIds[(idx + 1) % cachedActiveIds.count]
        } else {
            rotatingSessionId = cachedActiveIds.first
        }
        ESP32StatePublisher.shared.notifyDirty()
        AppleCompanionPublisher.shared.notifyDirty()
    }

    /// Start monitoring the CLI process for a session.
    /// Prefers the PID captured by the bridge (_ppid), falls back to source-aware process scans by CWD.
    private func tryMonitorSession(_ sessionId: String) {
        guard sessions[sessionId]?.isRemote != true else { return }
        // Codex Desktop cards are owned by NSWorkspace/app-server lifecycle. A
        // CWD lookup can only find an unrelated Codex CLI process (or the
        // shared Desktop helper), and binding either PID would remove every
        // Desktop thread when that one process exits. Other native providers
        // keep their existing monitor behavior.
        if sessions[sessionId]?.source == "codex",
           sessions[sessionId]?.termBundleId == Self.codexAppBundleId {
            stopMonitor(sessionId)
            sessions[sessionId]?.cliPid = nil
            sessions[sessionId]?.cliStartTime = nil
            exitingSessions.removeValue(forKey: sessionId)
            return
        }
        let currentMonitor = processMonitors[sessionId]?.process

        // Primary: use PID from bridge (works for any CLI)
        if let sessionProcess = resolvedSessionProcessIdentity(for: sessionId),
           Self.isLiveProcess(sessionProcess) {
            if currentMonitor == sessionProcess { return }
            if currentMonitor != nil {
                stopMonitor(sessionId)
            }
            monitorProcess(sessionId: sessionId, process: sessionProcess)
            return
        }

        if let currentMonitor, Self.isLiveProcess(currentMonitor) {
            setSessionProcessIdentity(currentMonitor, for: sessionId)
            return
        }

        // Fallback: scan for matching processes by CWD (source-aware)
        guard let cwd = sessions[sessionId]?.cwd else { return }
        let source = sessions[sessionId]?.source
        Task.detached {
            let pid = Self.findPidForCwd(cwd, source: source)
            await MainActor.run { [weak self] in
                guard let self = self, let pid = pid,
                      self.sessions[sessionId] != nil else { return }
                guard let discoveredProcess = Self.liveProcessIdentity(for: pid) else { return }

                let preferredProcess: ProcessIdentity
                if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
                   Self.isLiveProcess(currentProcess) {
                    preferredProcess = currentProcess
                } else {
                    preferredProcess = discoveredProcess
                    self.setSessionProcessIdentity(discoveredProcess, for: sessionId)
                }

                if let monitorProcess = self.processMonitors[sessionId]?.process,
                   monitorProcess == preferredProcess, Self.isLiveProcess(monitorProcess) {
                    return
                }

                if self.processMonitors[sessionId] != nil {
                    self.stopMonitor(sessionId)
                }
                self.monitorProcess(sessionId: sessionId, process: preferredProcess)
            }
        }
    }

    /// Find a CLI process PID by matching CWD, scoped to the correct source.
    /// Never guesses across sources: a missing/unknown source returns no PID instead of
    /// accidentally binding a session to the wrong process family.
    private nonisolated static func findPidForCwd(_ cwd: String, source: String? = nil) -> pid_t? {
        guard let normalizedSource = SessionSnapshot.normalizedSupportedSource(source) else { return nil }
        let pids = findPids(forSource: normalizedSource)
        for pid in pids {
            if getCwd(for: pid) == cwd { return pid }
        }
        return nil
    }

    private nonisolated static func findPids(forSource source: String, candidatePids: [pid_t]? = nil) -> [pid_t] {
        switch source {
        case "claude":     return findClaudePids(candidatePids: candidatePids)
        case "codex":      return findCodexPids(candidatePids: candidatePids)
        case "gemini":     return findGeminiPids(candidatePids: candidatePids)
        case "cursor":     return findCursorPids(candidatePids: candidatePids)
        case "cursor-cli": return findCursorCliPids(candidatePids: candidatePids)
        case "trae":       return findTraePids(candidatePids: candidatePids)
        case "traecn":     return findTraeCNPids(candidatePids: candidatePids)
        case "traecli":   return findTraeCliPids(candidatePids: candidatePids)
        case "copilot":    return findCopilotPids(candidatePids: candidatePids)
        case "qoder":      return findQoderPids(candidatePids: candidatePids)
        case "qoder-cli":  return findQoderCliPids(candidatePids: candidatePids)
        case "qoderwork":  return findQoderWorkPids(candidatePids: candidatePids)
        case "droid":      return findFactoryPids(candidatePids: candidatePids)
        case "codebuddy":  return findCodeBuddyPids(candidatePids: candidatePids)
        case "codybuddycn": return findCodyBuddyCNPids(candidatePids: candidatePids)
        case "stepfun":    return findStepFunPids(candidatePids: candidatePids)
        case "opencode":   return findOpenCodePids(candidatePids: candidatePids)
        case "antigravity": return findAntiGravityPids(candidatePids: candidatePids)
        case "google-antigravity": return findGoogleAntigravityPids(candidatePids: candidatePids)
        case "workbuddy":  return findWorkBuddyPids(candidatePids: candidatePids)
        case "hermes":     return findHermesPids(candidatePids: candidatePids)
        case "grok":       return findGrokPids(candidatePids: candidatePids)
        case "qwen":       return findQwenPids(candidatePids: candidatePids)
        case "kimi":       return findKimiPids(candidatePids: candidatePids)
        case "pi":         return findPiPids(candidatePids: candidatePids)
        case "cline":      return findClinePids(candidatePids: candidatePids)
        case "zcode":      return findZcodePids(candidatePids: candidatePids)
        default:           return []
        }
    }

    enum CompletionStyle: String {
        case expand, glance, off
    }

    /// Three-way completion notification style. Migration: the pre-glance
    /// boolean `autoExpandOnCompletion` (#146) maps false → .off; anything
    /// else (including "never set", which registers as true) → .expand.
    nonisolated static func completionStyle(defaults: UserDefaults = .standard) -> CompletionStyle {
        if let raw = defaults.string(forKey: SettingsKey.completionNotificationStyle),
           let style = CompletionStyle(rawValue: raw) {
            return style
        }
        if defaults.object(forKey: SettingsKey.autoExpandOnCompletion) != nil,
           defaults.bool(forKey: SettingsKey.autoExpandOnCompletion) == false {
            return .off
        }
        return .expand
    }

    private func enqueueCompletion(_ sessionId: String) {
        switch Self.completionStyle() {
        case .off:
            // Panel stays compact — status indicators still update, but no
            // completion card pops down (#146).
            return
        case .glance:
            flashGlanceCompletionIndicator()
            return
        case .expand:
            break
        }

        // Don't queue duplicates
        if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

        if isShowingCompletion || isShowingInteractive {
            // Already showing one — queue this for later
            completionQueue.append(sessionId)
        } else {
            // Show immediately
            showCompletion(sessionId)
        }
    }

    /// Prewarm at launch so the footer doesn't pop in (and shift panel height)
    /// on the first expansion.
    func refreshClaudeUsageIfStale() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showUsageStats) else { return }
        guard !usageScanInFlight else { return }
        if let scannedAt = claudeUsage?.scannedAt, Date().timeIntervalSince(scannedAt) < 120 { return }
        usageScanInFlight = true
        let cacheCopy = usageFileCache
        Task.detached(priority: .utility) {
            var cache = cacheCopy
            let snapshot = ClaudeUsageScanner.scan(cache: &cache)
            await MainActor.run { [weak self] in
                self?.claudeUsage = snapshot
                self?.usageFileCache = cache
                self?.usageScanInFlight = false
            }
        }
    }

    /// Last unresolved-branch probe per session — keeps `gitBranch == nil`
    /// (non-repo cwds, SessionStart snapshot rebuilds) from probing on every event.
    private var gitBranchCheckedAt: [String: Date] = [:]

    /// Branch resolution runs detached: .git probing on a dead network mount
    /// must never beachball the main actor. Triggers on cwd changes, at Stop
    /// (the turn may have switched branches), and while unresolved (throttled).
    private func maybeRefreshGitBranch(for sessionId: String, cwdBefore: String?, normalizedEventName: String) {
        guard let session = sessions[sessionId],
              session.remoteHostId == nil,
              let cwd = session.cwd else { return }
        let unresolvedDue = session.gitBranch == nil
            && Date().timeIntervalSince(gitBranchCheckedAt[sessionId] ?? .distantPast) > 60
        guard cwd != cwdBefore || normalizedEventName == "Stop" || unresolvedDue else { return }
        gitBranchCheckedAt[sessionId] = Date()
        Task.detached(priority: .utility) {
            let info = GitBranchReader.read(cwd: cwd)
            await MainActor.run { [weak self] in
                guard let self, var s = self.sessions[sessionId], s.cwd == cwd else { return }
                s.gitBranch = info?.branch
                s.gitIsWorktree = info?.isWorktree ?? false
                self.sessions[sessionId] = s
            }
        }
    }

    private func flashGlanceCompletionIndicator() {
        guard !surface.isExpanded else { return }  // user is already looking
        glanceCompletionActive = true
        glanceDismissTask?.cancel()
        glanceDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            guard !Task.isCancelled else { return }
            glanceCompletionActive = false
        }
    }

    /// Fast app-level suppress check (main-thread safe, no blocking).
    private func shouldSuppressAppLevel(for sessionId: String) -> Bool {
        !shouldAutoOpenPendingSurface(for: sessionId)
    }

    /// Notification kinds that describe the *account*, not the conversation.
    /// CodeBuddy's documented `notification_type` set is `permission_prompt`,
    /// `idle_prompt`, `auth_success`; only the last is boot-time auth chatter,
    /// and it arrives before `SessionStart` with its own session id. Matching by
    /// prefix so a future `auth_failed`/`auth_expired` behaves the same. (#288)
    nonisolated static func isAccountNotification(_ event: HookEvent) -> Bool {
        guard let kind = notificationKind(from: event) else { return false }
        return kind.hasPrefix("auth")
    }

    /// Whether a permission request may expand the island on its own. Smart
    /// Suppress only covers "the agent's own terminal is in front"; users who
    /// work in a *different* app still got the panel thrown in their face on
    /// every approval. With this off the sound and the session-list badge still
    /// fire and the card is one click away, but focus is never stolen. (#292)
    static func autoExpandOnPermission(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.autoExpandOnPermission) != nil else {
            return SettingsDefaults.autoExpandOnPermission
        }
        return defaults.bool(forKey: SettingsKey.autoExpandOnPermission)
    }

    func shouldAutoOpenPendingSurface(
        for sessionId: String,
        isTerminalFrontmost: (SessionSnapshot) -> Bool = TerminalVisibilityDetector.isTerminalFrontmostForSession
    ) -> Bool {
        guard UserDefaults.standard.bool(forKey: SettingsKey.smartSuppress) else { return true }
        guard let session = sessions[sessionId],
              (session.termApp != nil || session.termBundleId != nil) else { return true }
        return !isTerminalFrontmost(session)
    }

    private func shouldAutoOpenQuestionSurface(for event: HookEvent) -> Bool {
        let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        let nativeAskIsRacing = event.rawJSON["_codeisland_native_ask_racing"] as? Bool == true
        // Marker-enabled OMP explicitly guarantees that its native ask dialog
        // races CodeIsland. Pi and legacy OMP block here, so hiding their card deadlocks.
        if event.toolName == "AskUserQuestion",
           (source != "pi" || !nativeAskIsRacing) {
            return true
        }
        return shouldAutoOpenPendingSurface(
            for: event.sessionId ?? "default",
            isTerminalFrontmost: questionTerminalFrontmostDetector
        )
    }

    private func showCompletion(_ sessionId: String) {
        // Fast path: terminal not even frontmost — show immediately
        guard shouldSuppressAppLevel(for: sessionId) else {
            doShowCompletion(sessionId)
            return
        }

        // Terminal IS frontmost — check tab-level on background thread
        guard let session = sessions[sessionId] else { return }
        let sessionCopy = session
        Task.detached {
            let tabVisible = TerminalVisibilityDetector.isSessionTabVisible(sessionCopy)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Verify state hasn't changed while we were checking
                // (e.g. approval/question card popped up, session was removed)
                guard self.sessions[sessionId] != nil else { return }
                switch self.surface {
                case .approvalCard, .questionCard: return  // don't overwrite higher-priority surfaces
                default: break
                }
                if !tabVisible {
                    withAnimation(NotchAnimation.pop) {
                        self.doShowCompletion(sessionId)
                    }
                }
            }
        }
    }

    private func doShowCompletion(_ sessionId: String) {
        activeSessionId = sessionId
        surface = .completionCard(sessionId: sessionId)
        completionHasBeenEntered = false
        deferCollapseOnMouseLeave = false

        autoCollapseTask?.cancel()
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
        deferCollapseOnMouseLeave = false
    }

    private func showNextCompletionOrCollapse() {
        // Once the mouse has entered the completion card, defer collapse until it leaves
        if completionHasBeenEntered {
            deferCollapseOnMouseLeave = true
            return
        }
        // showNextPending handles: interactive items first, then completionQueue, then collapse
        if showNextPending() { return }
        withAnimation(NotchAnimation.close) {
            surface = .collapsed
        }
    }

    // Cached derived state (refreshed by refreshDerivedState after session mutations)
    private(set) var status: AgentStatus = .idle
    private(set) var primarySource: String = "claude"
    private(set) var activeSessionCount: Int = 0
    private(set) var totalSessionCount: Int = 0

    var currentTool: String? {
        // When approvals/questions are pending, always reflect the *front of the queue*.
        // Otherwise a second incoming request can overwrite session.currentTool and make
        // the first pending item appear to “disappear” in compact UI.
        if let pending = pendingPermission {
            return pending.event.toolName
        }
        if pendingQuestion != nil {
            // AskUserQuestion arrives via PermissionRequest tool.
            return "AskUserQuestion"
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.currentTool
    }

    var toolDescription: String? {
        if let pending = pendingPermission {
            let sessionId = pending.event.sessionId ?? activeSessionId ?? "default"
            return pending.event.toolDescription ?? sessions[sessionId]?.toolDescription
        }
        if let q = pendingQuestion {
            return q.question.question
        }
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.toolDescription
    }

    var activeDisplayName: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        let displaySessionId = s.displaySessionId(sessionId: id)
        return s.displayTitle(sessionId: displaySessionId)
    }

    var activeModel: String? {
        guard let id = activeSessionId, let s = sessions[id] else { return nil }
        return s.model
    }

    /// Recompute cached status/source/counts from sessions in a single O(n) pass.
    /// Call after any mutation to `sessions` or session status.
    func refreshDerivedState() {
        let summary = deriveSessionSummary(from: sessions)
        // Whenever no session is actively working, honor the user-configured
        // default mascot. Covers both "no sessions at all" (#102) and "all
        // sessions idle" (#149) — without this, a user who sets the default
        // to Codex still sees Claude every time their last session goes idle
        // because deriveSessionSummary echoes the most recently active source.
        // Active work always wins (running / processing / waiting* status).
        let effectiveSource: String
        if summary.status == .idle {
            effectiveSource = SettingsManager.shared.defaultSource
        } else {
            effectiveSource = summary.primarySource
        }
        // Only assign when changed (avoids unnecessary @Observable notifications)
        if status != summary.status { status = summary.status }
        if primarySource != effectiveSource { primarySource = effectiveSource }
        if activeSessionCount != summary.activeSessionCount { activeSessionCount = summary.activeSessionCount }
        if totalSessionCount != summary.totalSessionCount { totalSessionCount = summary.totalSessionCount }
        ESP32StatePublisher.shared.notifyDirty()
        AppleCompanionPublisher.shared.notifyDirty()
    }

    private func refreshProviderTitle(for trackedSessionId: String, providerSessionId: String? = nil) {
        guard let session = sessions[trackedSessionId] else { return }
        guard !session.isRemote else { return }

        let lookupSessionId = providerSessionId ?? session.providerSessionId ?? trackedSessionId
        if let providerSessionId {
            sessions[trackedSessionId]?.providerSessionId = providerSessionId
        } else if SessionTitleStore.supports(provider: session.source) {
            sessions[trackedSessionId]?.providerSessionId = lookupSessionId
        }

        guard SessionTitleStore.supports(provider: session.source) else { return }

        if let resolved = SessionTitleStore.title(for: lookupSessionId, provider: session.source, cwd: session.cwd) {
            sessions[trackedSessionId]?.sessionTitle = resolved.title
            sessions[trackedSessionId]?.sessionTitleSource = resolved.source
        } else {
            sessions[trackedSessionId]?.sessionTitle = nil
            sessions[trackedSessionId]?.sessionTitleSource = nil
        }
    }

    func handleEvent(_ event: HookEvent) {
        // Skip events from subagent worktrees — tracked via parent's SubagentStart/Stop
        if let cwd = event.rawJSON["cwd"] as? String,
           cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
            return
        }

        let source = event.rawJSON["_source"] as? String
        let hasTranscriptPath = (event.rawJSON["transcript_path"] as? String)
            .map { !$0.isEmpty } ?? false
        if Self.isCodexPlaceholderHook(
            source: source,
            cwd: event.rawJSON["cwd"] as? String,
            hasTranscriptPath: hasTranscriptPath
        ) {
            return
        }

        let sessionId = event.sessionId ?? "default"
        let normalizedEventName = EventNormalizer.normalize(event.eventName)

        // Account chatter, not session activity. CodeBuddy fires
        // Notification(auth_success) as the CLI boots — before SessionStart and
        // under a different session id — which minted a second card that then
        // never updated (#288).
        if normalizedEventName == "Notification",
           Self.isAccountNotification(event) {
            return
        }

        if source?.lowercased() == "codex",
           event.rawJSON["_term_bundle"] as? String == Self.codexAppBundleId,
           let rawProviderSessionId = event.rawJSON["session_id"] as? String {
            let providerSessionId = rawProviderSessionId.hasPrefix(Self.codexAppSessionPrefix)
                ? String(rawProviderSessionId.dropFirst(Self.codexAppSessionPrefix.count))
                : rawProviderSessionId
            if closedCodexAppThreads[providerSessionId] != nil {
                // Tool/notification/terminal hooks can trail app-server
                // `thread/closed`. Only explicit generation-start activity may
                // reopen; `thread/started` clears the same tombstone directly.
                if normalizedEventName == "SessionStart"
                    || normalizedEventName == "UserPromptSubmit" {
                    closedCodexAppThreads.removeValue(forKey: providerSessionId)
                } else {
                    return
                }
            }
        }

        // Skip Codex APP internal sessions (title generation, etc.) — they have no transcript
        if (event.rawJSON["_source"] as? String) == "codex"
            && sessions[sessionId] == nil
            && event.rawJSON["transcript_path"] is NSNull {
            return
        }

        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }

        let prevStatus = sessions[sessionId]?.status
        let wasWaiting = prevStatus == .waitingApproval || prevStatus == .waitingQuestion
        let cwdBeforeReduce = sessions[sessionId]?.cwd

        // Cache PreToolUse payloads so downstream events sharing tool_use_id can be
        // correlated, and drain queue entries whose agent already moved on.
        cachePreToolUseIfApplicable(event)
        resolveToolUseIfCompleted(event)
        // #216: permission requests with no correlatable tool_use_id can't be drained by
        // resolveToolUseIfCompleted. A follow-up activity event means the user already
        // approved in the terminal — resume those (and only those) as approved.
        resolveOrphanPermissionsOnActivity(event)

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: maxHistory,
                                  replyCompletePlaceholder: L10n.shared["reply_complete_placeholder"])

        // Cursor Agent Tasks often fire Claude-format hooks without `--source`,
        // leaving ghost Claude cards. Rebrand + fold before the rest of the
        // pipeline treats them as standalone Claude sessions.
        if sessions.contains(where: {
            let source = SessionSnapshot.normalizedSupportedSource($0.value.source)
            return source == nil || source == "claude"
        }) {
            _ = applyCursorSubsessionModeToKnownSessions()
        }

        // After reduce: remoteHostId is authoritative (extractMetadata just ran),
        // so a remote session can never probe the local filesystem here.
        maybeRefreshGitBranch(for: sessionId, cwdBefore: cwdBeforeReduce, normalizedEventName: normalizedEventName)

        // Backfill model after metadata extraction. Hooks are inconsistent across providers,
        // so retry with a cooldown instead of giving up permanently on the first miss.
        if sessions[sessionId]?.isRemote != true {
            maybeBackfillModel(for: sessionId)
        }

        // Session was waiting and got an activity event. Historically we'd
        // blanket-drain the whole queue here, assuming the user answered in the
        // terminal. That heuristic misfires for parallel MCP / plugin tool calls:
        // an unrelated PostToolUse / Stop / etc. would deny pending permissions
        // for *other* in-flight tools (#147).
        //
        // The right signal that a specific permission is moot is its tool_use_id
        // showing up in PostToolUse / PostToolUseFailure / PermissionDenied —
        // resolveToolUseIfCompleted already does that surgically above. We keep
        // the question-queue drain (questions don't carry tool_use_id reliably
        // and are rare enough that a blanket sweep is acceptable) and refresh
        // session status, but never drain unrelated permission requests.
        if wasWaiting {
            let keepWaiting: Set<String> = ["Notification", "SessionStart", "SessionEnd", "PreCompact"]
            if !keepWaiting.contains(normalizedEventName) {
                drainQuestions(forSession: sessionId, reason: "wasWaiting-blanket-drain-event=\(normalizedEventName)")
                let stillHasPermission = permissionQueue.contains { $0.event.sessionId == sessionId }
                let stillHasQuestion = questionQueue.contains { $0.event.sessionId == sessionId }
                if !stillHasPermission && !stillHasQuestion,
                   sessions[sessionId]?.status == .waitingApproval
                    || sessions[sessionId]?.status == .waitingQuestion {
                    sessions[sessionId]?.status = (normalizedEventName == "Stop") ? .idle : .processing
                    sessions[sessionId]?.currentTool = nil
                    sessions[sessionId]?.toolDescription = nil
                }
                showNextPending()
            }
        }

        // Detect Cursor YOLO mode once per session (nil = unchecked)
        if let source = event.rawJSON["_source"] as? String,
           (source == "cursor" || source == "cursor-cli"),
           sessions[sessionId]?.isYoloMode == nil {
            sessions[sessionId]?.isYoloMode = Self.detectCursorYoloMode()
        }

        for effect in effects {
            executeEffect(effect, sessionId: sessionId)
        }

        if let provider = sessions[sessionId]?.source,
           sessions[sessionId]?.isRemote != true,
           SessionTitleStore.supports(provider: provider) {
            refreshProviderTitle(for: sessionId)
        }

        // If a hook just supplied (or changed) this session's transcript path, attach
        // the tailer so the next assistant append shows up in the panel immediately.
        if sessions[sessionId]?.isRemote != true {
            attachTranscriptTailerIfNeeded(sessionId: sessionId)
        }

        // Handle the "else if activeSessionId == sessionId → mostActive" edge case
        // (reducer can't check activeSessionId since it's AppState-local)
        if sessions[sessionId]?.status == .idle && activeSessionId == sessionId {
            if normalizedEventName != "Stop" {
                activeSessionId = mostActiveSessionId()
            }
        }

        scheduleSave()
        startRotationIfNeeded()
        refreshDerivedState()
    }

    func removeRemoteSessions(hostId: String) {
        let ids = sessions.compactMap { key, session in
            session.remoteHostId == hostId ? key : nil
        }
        for id in ids {
            removeSession(id)
        }
        refreshDerivedState()
    }

    private func executeEffect(_ effect: SideEffect, sessionId: String) {
        switch effect {
        case .playSound(let eventName):
            SoundManager.shared.handleEvent(eventName)
        case .tryMonitorSession(let sid):
            tryMonitorSession(sid)
        case .stopMonitor(let sid):
            stopMonitor(sid)
        case .removeSession(let sid):
            removeSession(sid)
        case .enqueueCompletion(let sid):
            enqueueCompletion(sid)
        case .setActiveSession(let sid):
            activeSessionId = sid
        }
    }

    private func maybeBackfillModel(for sessionId: String) {
        guard let session = sessions[sessionId], session.model == nil else { return }
        let now = Date()
        if let retryAt = modelReadRetryAt[sessionId], retryAt > now {
            return
        }

        if let model = Self.readModelForSession(sessionId: sessionId, session: session) {
            sessions[sessionId]?.model = model
            modelReadRetryAt.removeValue(forKey: sessionId)
        } else {
            modelReadRetryAt[sessionId] = now.addingTimeInterval(5)
        }
    }

    func handlePermissionRequest(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        // Extract metadata so blocking-first parent sessions have cwd/source/PID.
        // Subagent events are routed through the parent session ID; their full metadata
        // can describe the child session and should not overwrite the parent — only fill gaps.
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        // Closed Task/subagent ids must not surface new permission UI (parity with
        // ensureSubagent refusing late tool hooks after Stop).
        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            let denyResponse = Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            )
            continuation.resume(returning: denyResponse)
            return
        }

        // Clear any pending questions for THIS session (mutually exclusive within a session)
        drainQuestions(forSession: sessionId, reason: "newPermissionRequest")

        sessions[sessionId]?.status = .waitingApproval
        sessions[sessionId]?.currentTool = event.toolName
        sessions[sessionId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, agentId: event.agentId, status: .waitingApproval)
        // Backfill tool name/description from cached PreToolUse when the payload is thin.
        enrichPermissionRequestFromCache(sessionId: sessionId, event: event)

        let request = PermissionRequest(event: event, continuation: continuation)

        // Replay deduplication: if the same tool_use_id is already queued, swap the
        // continuation in place and deny the previous waiter. Preserves card order.
        if mergeDuplicatePermissionRequest(request) {
            refreshDerivedState()
            return
        }

        // A genuinely new request means this session needs a user decision again,
        // so it stops being dismissed. This must come AFTER the replay-dedup
        // return above: a replay is the same decision arriving twice, not a new
        // one, and un-dismissing on a replay resurrects the request the user
        // hid — which then takes the card the arriving session should have got
        // and, counting as a burst already in progress, silences its sound too.
        // (A same-id request with different tool inputs is a distinct request,
        // not a replay — merge returns false for those, so they still land here.)
        dismissedPermissionSessionIds.remove(sessionId)

        // Dismissing hides a request but deliberately leaves it queued, so the
        // CLI stays blocked and the prompt stays recoverable. Gating on
        // `permissionQueue.count == 1` therefore swallowed every later request —
        // from any session — for as long as a dismissed one sat in the queue.
        //
        // The gate's real question is "is an approval card on screen", so ask
        // the surface. Queue-derived proxies do not survive the un-dismiss
        // above: a session's own next request clears its dismissal, which makes
        // its still-queued earlier request count as visible again while nothing
        // is displayed — silencing every later request all over again. (#309)
        //
        // ponytail: a card suppressed by Smart Suppress also leaves a visible
        // request undisplayed, so a second session's request still waits behind
        // it. That is pre-existing (`main` behaves the same) and needs
        // showNextPending to skip un-openable entries; tracked separately.
        //
        // The surface alone is not enough either: `drainPermissions` empties one
        // SESSION's requests without clearing `surface`, so a card can be left
        // pointing at a session that has nothing queued. Ask per session, not
        // per queue — a whole-queue test (`!permissionQueue.isEmpty`) reads as
        // "a card is up" whenever some other session is still waiting, which
        // leaves the panel showing a card for a session with no pending request
        // while later requests queue silently behind it.
        let approvalCardOnScreen: Bool
        if case .approvalCard(let shownSessionId) = surface,
           permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == shownSessionId }) {
            approvalCardOnScreen = true
        } else {
            approvalCardOnScreen = false
        }

        // Card and sound answer different questions and must not share a gate.
        // The sound marks the start of a burst of approvals, which is what
        // `count == 1` used to approximate; within a burst it stays quiet, and
        // a dismissed request sitting in the queue must not count as a burst
        // already in progress.
        let burstAlreadyInProgress = nextVisiblePermissionIndex() != nil
        permissionQueue.append(request)

        // Show UI only when no approval card is already up to be stolen from.
        // showNextPending picks the first *visible* request, promotes it to the
        // head and applies the session-list / Smart Suppress rules — pointing
        // the card at this session by hand would show the dismissed request's
        // content whenever a dismissed entry still leads the queue.
        if !approvalCardOnScreen {
            showNextPending()
        }
        if !burstAlreadyInProgress {
            SoundManager.shared.handleEvent("PermissionRequest")
        }
        refreshDerivedState()
    }

    /// Index of the queued request the user actually acted on.
    ///
    /// The card on screen is identified by its session, but the answer used to
    /// be applied to `queue.removeFirst()`. Anything that mutates the head
    /// while a card is open — a peer disconnect draining another session, a
    /// stale tool-use eviction, the reorder in `showNextPending()` — would then
    /// resolve whichever request happened to be first, delivering the answer to
    /// the wrong CLI. Callers that know which session the card belongs to pass
    /// it in; `nil` keeps the head-of-queue behaviour for surfaces that only
    /// ever mirror the head (keyboard shortcuts, iPhone/Watch Buddy). (#308)
    private func permissionIndex(expecting expected: String?) -> Int? {
        guard let expected else { return permissionQueue.isEmpty ? nil : 0 }
        return permissionQueue.firstIndex { ($0.event.sessionId ?? "default") == expected }
    }

    /// Question-queue counterpart of `permissionIndex(expecting:)`. (#308)
    private func questionIndex(expecting expected: String?) -> Int? {
        guard let expected else { return questionQueue.isEmpty ? nil : 0 }
        return questionQueue.firstIndex { ($0.event.sessionId ?? "default") == expected }
    }

    /// The request the card was showing is no longer queued (answered in the
    /// terminal, drained on disconnect). `showNextPending()` drops the dead card
    /// and re-opens whatever is genuinely waiting. (#308)
    private func discardStalePanelAction(expected: String, kind: String) {
        log.notice("⚠️ ignored \(kind, privacy: .public) for session=\(expected, privacy: .public) — request no longer queued")
        showNextPending()
        refreshDerivedState()
    }

    func approvePermission(always: Bool = false, expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "approve")
            }
            return
        }
        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)
        let responseData: Data
        if always, CodexPermissionRules.isCodexEvent(pending.event) {
            _ = CodexPermissionRules().persistAlwaysAllowRule(for: pending.event)
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        } else if always, Self.isZcodeEvent(pending.event) {
            responseData = Self.zcodeAlwaysAllowResponse(toolName: pending.event.toolName)
        } else if always {
            let toolName = pending.event.toolName ?? ""
            // MCP tools (`mcp__server__tool`) don't accept a rule specifier — the
            // rule must be the bare tool name. Sending `ruleContent: "*"` makes
            // Claude Code assemble `mcp__server__tool(*)`, which never matches an
            // actual MCP call, so the "always allow" rule silently fails to
            // persist and the same approval keeps re-prompting. Non-MCP tools
            // (Bash/Read/Edit/…) keep the `*` specifier. (#224)
            var rule: [String: Any] = ["toolName": toolName]
            if !toolName.hasPrefix("mcp__") {
                rule["ruleContent"] = "*"
            }
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedPermissions": [[
                            "type": "addRules",
                            "rules": [rule],
                            "behavior": "allow",
                            "destination": "session"
                        ]]
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
            responseData = Data(response.utf8)
        }
        pending.continuation.resume(returning: responseData)
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: pending.event.toolName,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    nonisolated static func isZcodeEvent(_ event: HookEvent) -> Bool {
        SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "zcode"
    }

    nonisolated static func isQoderEvent(_ event: HookEvent) -> Bool {
        guard let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) else { return false }
        return source == "qoder" || source == "qoder-cli"
    }

    /// "Always allow" response for a ZCode PermissionRequest hook (#258).
    ///
    /// ZCode validates hook stdout with a STRICT schema (unknown keys void the
    /// whole decision, and ZCode falls back to its own dialog). Persistent
    /// rules therefore go in `permissionUpdates` — NOT Claude's
    /// `updatedPermissions` — and there is no `destination` key. A rule with a
    /// bare `toolName` (no `ruleContent`) matches every future call of that
    /// tool, which is exactly the "always allow this tool" semantic; a
    /// `ruleContent` of "*" would instead be compared against the call's
    /// command/path subject and never match. Events without a tool name can't
    /// form a valid rule (toolName must be non-empty), so they degrade to a
    /// plain one-time allow.
    nonisolated static func zcodeAlwaysAllowResponse(toolName: String?) -> Data {
        let plainAllow = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        guard let toolName, !toolName.isEmpty else { return plainAllow }
        let obj: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": [
                    "behavior": "allow",
                    "permissionUpdates": [[
                        "type": "addRules",
                        "behavior": "allow",
                        "rules": [["toolName": toolName]],
                    ] as [String: Any]]
                ] as [String: Any]
            ] as [String: Any]
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? plainAllow
    }

    func handleBuddyControlCommand(_ command: BuddyControlCommand) {
        switch command {
        case .approveCurrentPermission:
            if !permissionQueue.isEmpty {
                approvePermission()
            } else {
                log.info("Ignored Buddy approve command because permission queue is empty")
            }
        case .denyCurrentPermission:
            if !permissionQueue.isEmpty {
                denyPermission()
            } else {
                log.info("Ignored Buddy deny command because permission queue is empty")
            }
        case .skipCurrentQuestion:
            if !questionQueue.isEmpty {
                skipQuestion()
            } else {
                log.info("Ignored Buddy skip command because question queue is empty")
            }
        }
    }

    func answerCompanionQuestion(_ answer: String) {
        guard !questionQueue.isEmpty else {
            log.info("Ignored companion question answer because question queue is empty")
            return
        }

        if questionQueue[0].isFromPermission,
           var askState = questionQueue[0].askUserQuestionState {
            guard let index = askState.items.firstIndex(where: { askState.answers[$0.answerKey] == nil }) else {
                answerQuestionMulti(askState.items.map {
                    (question: $0.payload.question, answer: askState.answers[$0.answerKey] ?? "")
                })
                return
            }

            let item = askState.items[index]
            askState.answers[item.answerKey] = answer
            questionQueue[0].askUserQuestionState = askState

            if askState.canConfirm {
                answerQuestionMulti(askState.items.map {
                    (question: $0.payload.question, answer: askState.answers[$0.answerKey] ?? "")
                })
            } else {
                refreshDerivedState()
            }
            return
        }

        answerQuestion(answer)
    }

    /// Find an existing session whose source matches and whose CLI PID equals
    /// the supplied ppid. Used by HookServer to merge plugin-proxied events
    /// (e.g. omo) into their main session when pluginSessionMode == "merge". (#123)
    ///
    /// We additionally require the candidate session to have been active in
    /// the last 5 minutes. This guards against macOS PID reuse — a stale
    /// session whose CLI long since exited could otherwise still match the
    /// plugin event's `_ppid` if the OS recycled that PID for an unrelated
    /// process. Live sessions update `lastActivity` on every event so the
    /// window is generous; stale ones get skipped. (#123 review)
    func findSessionId(
        forSource source: String,
        ppid: Int,
        excluding excludedSessionId: String? = nil,
        requireActive: Bool = false
    ) -> String? {
        let normalized = SessionSnapshot.normalizedSupportedSource(source)
        let cutoff = Date().addingTimeInterval(-300)
        return sessions
            .filter { sessionId, snap in
                let snapSource = SessionSnapshot.normalizedSupportedSource(snap.source)
                return snapSource == normalized
                    && snap.cliPid == pid_t(ppid)
                    && snap.lastActivity >= cutoff
                    && sessionId != excludedSessionId
                    && (!requireActive || snap.status != .idle)
            }
            .sorted { lhs, rhs in
                let lhsActive = lhs.value.status != .idle
                let rhsActive = rhs.value.status != .idle
                if lhsActive != rhsActive { return lhsActive }
                return lhs.value.startTime < rhs.value.startTime
            }
            .first?.key
    }

    func findSessionId(providerSessionId: String) -> String? {
        if sessions[providerSessionId] != nil {
            return providerSessionId
        }
        let codexAppId = AppState.codexAppSessionPrefix + providerSessionId
        if sessions[codexAppId] != nil {
            return codexAppId
        }
        return sessions.first(where: { _, snap in
            snap.providerSessionId == providerSessionId
        })?.key
    }

    /// Resolve a Codex parent in the same Desktop/CLI namespace as its child.
    /// Raw and `codexapp:` cards may legitimately share a provider thread id
    /// when a user resumes the same thread in both surfaces.
    func findCodexParentSessionId(
        providerSessionId: String,
        childTermBundleId: String?
    ) -> String? {
        let childIsDesktop = childTermBundleId == Self.codexAppBundleId
        let canonicalId = childIsDesktop
            ? Self.codexAppSessionPrefix + providerSessionId
            : providerSessionId
        if let session = sessions[canonicalId],
           session.source == "codex",
           session.isNativeAppMode == childIsDesktop {
            return canonicalId
        }
        return sessions.first(where: { _, snapshot in
            snapshot.source == "codex"
                && snapshot.providerSessionId == providerSessionId
                && snapshot.isNativeAppMode == childIsDesktop
        })?.key
    }

    func denyPermission(expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "deny")
            }
            return
        }
        let pending = permissionQueue.remove(at: index)
        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.remove(sessionId)
        let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        pending.continuation.resume(returning: Data(response.utf8))
        // Folded Task deny must not idle the whole parent chat card.
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .processing,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: true
        )

        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }

        showNextPending()
        refreshDerivedState()
    }

    func dismissPermissionPrompt(expectedSessionId: String? = nil) {
        guard let index = permissionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "dismiss")
            }
            return
        }
        let pending = permissionQueue[index]

        let sessionId = pending.event.sessionId ?? "default"
        dismissedPermissionSessionIds.insert(sessionId)

        if nextVisiblePermissionIndex() != nil {
            showNextPending()
        } else {
            if case .approvalCard = surface {
                withAnimation(NotchAnimation.close) {
                    surface = .collapsed
                }
            }
        }
        refreshDerivedState()
    }

    func handleQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            continuation.resume(returning: Data("{}".utf8))
            return
        }

        guard let question = QuestionPayload.from(event: event) else {
            continuation.resume(returning: Data("{}".utf8))
            return
        }
        drainPermissions(forSession: sessionId, reason: "handleQuestion(Notification)")

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, agentId: event.agentId, status: .waitingQuestion)

        let request = QuestionRequest(event: event, question: question, continuation: continuation)
        questionQueue.append(request)

        if questionQueue.count == 1 {
            activeSessionId = sessionId
            if shouldAutoOpenPendingSurface(for: sessionId) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
            SoundManager.shared.handleEvent("PermissionRequest")
        }
        refreshDerivedState()
    }

    func handleAskUserQuestion(_ event: HookEvent, continuation: CheckedContinuation<Data, Never>) {
        let sessionId = event.sessionId ?? "default"
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            let denyResponse = Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            )
            continuation.resume(returning: denyResponse)
            return
        }

        let originalQuestions = event.toolInput?["questions"] as? [[String: Any]]
        var askItems: [AskUserQuestionItem] = []
        if let questions = originalQuestions {
            var usedAnswerKeys = Set<String>()
            askItems = questions.enumerated().compactMap { index, item in
                let questionText = item["question"] as? String ?? "Question"
                let header = item["header"] as? String
                let multiSelect = item["multiSelect"] as? Bool ?? false
                var optionLabels: [String]?
                var optionDescs: [String]?
                if let opts = item["options"] as? [[String: Any]] {
                    optionLabels = opts.compactMap { $0["label"] as? String }
                    optionDescs = opts.compactMap { $0["description"] as? String }
                }
                if optionLabels?.isEmpty == true { optionLabels = nil }
                if optionDescs?.isEmpty == true { optionDescs = nil }
                let payload = QuestionPayload(
                    question: questionText,
                    options: optionLabels,
                    descriptions: optionDescs,
                    header: header
                )
                // Claude Code's mapToolResultToToolResultBlockParam looks up answers by
                // question text: `answers[question.question]`. Using header as the key
                // causes a mismatch and all answers arrive as empty strings.
                let baseKey = questionText
                var answerKey = baseKey
                if usedAnswerKeys.contains(answerKey) {
                    var suffix = 2
                    while usedAnswerKeys.contains("\(baseKey)_\(suffix)") {
                        suffix += 1
                    }
                    answerKey = "\(baseKey)_\(suffix)"
                }
                usedAnswerKeys.insert(answerKey)
                return AskUserQuestionItem(payload: payload, answerKey: answerKey, multiSelect: multiSelect)
            }
        }

        if askItems.isEmpty {
            let questionText = event.toolInput?["question"] as? String ?? "Question"
            var options: [String]?
            if let stringOpts = event.toolInput?["options"] as? [String] {
                options = stringOpts
            } else if let dictOpts = event.toolInput?["options"] as? [[String: Any]] {
                options = dictOpts.compactMap { $0["label"] as? String }
            }
            if !questionText.isEmpty {
                let payload = QuestionPayload(question: questionText, options: options)
                askItems = [AskUserQuestionItem(payload: payload, answerKey: "answer", multiSelect: false)]
            }
        }

        guard !askItems.isEmpty else {
            let updatedInput = askUserQuestionUpdatedInput(
                event: event,
                answers: [:],
                answer: nil,
                originalQuestions: originalQuestions
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            let responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            continuation.resume(returning: responseData)
            sessions[sessionId]?.status = .processing
            refreshDerivedState()
            return
        }

        drainPermissions(forSession: sessionId, reason: "handleAskUserQuestion")
        drainQuestions(forSession: sessionId, reason: "handleAskUserQuestion")

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, agentId: event.agentId, status: .waitingQuestion)

        let askState = AskUserQuestionState(items: askItems, answers: [:])
        let request = QuestionRequest(
            event: event,
            question: askItems[0].payload,
            continuation: continuation,
            isFromPermission: true,
            askUserQuestionState: askState
        )
        questionQueue.append(request)

        if questionQueue.count == 1 {
            activeSessionId = sessionId
            if shouldAutoOpenQuestionSurface(for: event) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
            SoundManager.shared.handleEvent("PermissionRequest")
        }
        refreshDerivedState()
    }

    func answerQuestion(_ answer: String, expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "answer")
            }
            return
        }
        // Multi-question wizards (AskUserQuestion, Codex app-server) use the batch
        // path — direct single answers are not processed.
        if questionQueue[index].askUserQuestionState != nil,
           (questionQueue[index].isFromPermission || questionQueue[index].isCodexAppServer) {
            return
        }
        // Codex app-server questions reply over the JSON-RPC client, not a hook.
        if questionQueue[index].isCodexAppServer {
            let pending = questionQueue.remove(at: index)
            let answerKey = pending.askUserQuestionState?.items.first?.answerKey
                ?? pending.question.header ?? "answer"
            pending.resolveCodexAppServer([answerKey: [answer]])
            let sessionId = pending.event.sessionId ?? "default"
            sessions[sessionId]?.status = .processing
            showNextPending()
            refreshDerivedState()
            return
        }
        let pending = questionQueue.remove(at: index)
        let responseData: Data
        if pending.isFromPermission {
            let answerKey = pending.question.header ?? "answer"
            let updatedInput = askUserQuestionUpdatedInput(
                event: pending.event,
                answers: [answerKey: answer],
                answer: answer,
                originalQuestions: pending.event.toolInput?["questions"] as? [[String: Any]]
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answer
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.resolution.resumeHook(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    func answerQuestionMulti(
        _ answers: [(question: String, answer: String)],
        expectedSessionId: String? = nil
    ) {
        answerQuestionMulti(
            answers.map {
                AskUserQuestionAnswer(
                    question: $0.question,
                    answer: $0.answer,
                    selectedOptions: [],
                    customInput: nil
                )
            },
            expectedSessionId: expectedSessionId
        )
    }

    func answerQuestionMulti(
        _ answers: [AskUserQuestionAnswer],
        expectedSessionId: String? = nil
    ) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "answer")
            }
            return
        }
        // Codex app-server questions reply over the JSON-RPC client, not a hook.
        if questionQueue[index].isCodexAppServer {
            let pending = questionQueue.remove(at: index)
            var answersByKey: [String: [String]] = [:]
            if let askState = pending.askUserQuestionState {
                // Match by position — the wizard collects answers in item order.
                for (index, item) in askState.items.enumerated() where index < answers.count {
                    answersByKey[item.answerKey] = [answers[index].answer]
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                answersByKey[answerKey] = [answers.first?.answer ?? ""]
            }
            pending.resolveCodexAppServer(answersByKey)
            let sessionId = pending.event.sessionId ?? "default"
            sessions[sessionId]?.status = .processing
            showNextPending()
            refreshDerivedState()
            return
        }
        let pending = questionQueue.remove(at: index)
        let responseData: Data
        if pending.isFromPermission {
            var answersDict: [String: String] = [:]
            var answerDetails: [String: [String: Any]] = [:]
            if let askState = pending.askUserQuestionState {
                // Match by position — wizard collects answers in the same order as items
                for (index, item) in askState.items.enumerated() {
                    if index < answers.count {
                        let submitted = answers[index]
                        answersDict[item.answerKey] = submitted.answer
                        var details: [String: Any] = [:]
                        if !submitted.selectedOptions.isEmpty {
                            details["selectedOptions"] = submitted.selectedOptions
                        }
                        if let customInput = submitted.customInput {
                            details["customInput"] = customInput
                        }
                        if !details.isEmpty {
                            answerDetails[item.answerKey] = details
                        }
                    }
                }
            } else {
                let answerKey = pending.question.header ?? "answer"
                answersDict[answerKey] = answers.first?.answer ?? ""
            }
            let updatedInput = askUserQuestionUpdatedInput(
                event: pending.event,
                answers: answersDict,
                answer: answers.first?.answer,
                originalQuestions: pending.event.toolInput?["questions"] as? [[String: Any]],
                answerDetails: answerDetails
            )
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PermissionRequest",
                    "decision": [
                        "behavior": "allow",
                        "updatedInput": updatedInput
                    ] as [String: Any]
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        } else {
            let obj: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "Notification",
                    "answer": answers.first?.answer ?? ""
                ] as [String: Any]
            ]
            responseData = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        }
        pending.resolution.resumeHook(returning: responseData)
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    private func askUserQuestionUpdatedInput(
        event: HookEvent,
        answers: [String: String],
        answer: String?,
        originalQuestions: [[String: Any]]?,
        answerDetails: [String: [String: Any]] = [:]
    ) -> [String: Any] {
        var updatedInput = event.toolInput ?? [:]
        // `questions` must always be present in updatedInput. Claude Code's
        // mapToolResultToToolResultBlockParam calls H.map() on it directly;
        // if the key is absent H is undefined and the call crashes with
        // "undefined is not an object (evaluating 'H.map')".
        // Fall back to the raw toolInput value when the [[String:Any]] cast fails.
        updatedInput["questions"] = originalQuestions ?? (event.toolInput?["questions"] ?? [] as [[String: Any]])
        updatedInput["answers"] = answers
        // Qoder CLI validates updatedInput against the AskUserQuestion schema
        // (additionalProperties: false, only questions/answers/annotations/
        // metadata). The scalar `answer` key fails that validation with
        // "params must NOT have additional properties", so omit it there.
        if let answer, !Self.isQoderEvent(event) {
            updatedInput["answer"] = answer
        }
        if !answerDetails.isEmpty,
           SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "pi",
           event.toolUseId != nil {
            updatedInput["_codeislandAnswerDetails"] = answerDetails
        }
        return updatedInput
    }

    func skipQuestion(expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "skip")
            }
            return
        }
        let pending = questionQueue.remove(at: index)
        if pending.isCodexAppServer {
            // No "skip" verb in the Codex protocol — abandon the request so the
            // server stops waiting (it will re-prompt or fall back to its TUI).
            pending.resolveCodexAppServer(nil)
        } else {
            let responseData: Data
            if pending.isFromPermission {
                responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
            } else {
                responseData = Data(#"{"hookSpecificOutput":{"hookEventName":"Notification"}}"#.utf8)
            }
            pending.resolution.resumeHook(returning: responseData)
        }
        let sessionId = pending.event.sessionId ?? "default"
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .processing,
            keepSubagentTool: nil,
            idleParentWhenNoAgent: false
        )

        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued permissions for a specific session, resuming their continuations with deny
    private func drainPermissions(forSession sessionId: String, reason: String = "unknown") {
        dismissedPermissionSessionIds.remove(sessionId)
        let denyResponse = Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        permissionQueue.removeAll { item in
            guard item.event.sessionId == sessionId else { return false }
            log.notice("⚠️ permission deny reason=drainPermissions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) toolUseId=\(item.toolUseId ?? "nil", privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public)")
            item.continuation.resume(returning: denyResponse)
            return true
        }
    }

    /// Called when the bridge socket disconnects — the question/permission was answered externally (e.g. user replied in terminal)
    func handlePeerDisconnect(sessionId: String) {
        let hadPending = questionQueue.contains(where: { $0.event.sessionId == sessionId })
            || permissionQueue.contains(where: { $0.event.sessionId == sessionId })
        guard hadPending else { return }

        drainQuestions(forSession: sessionId, reason: "peer-disconnect")
        drainPermissions(forSession: sessionId, reason: "peer-disconnect")
        let currentStatus = sessions[sessionId]?.status
        if currentStatus == .waitingApproval || currentStatus == .waitingQuestion {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued questions for a specific session.
    /// AskUserQuestion-derived requests are denied; notification questions return empty.
    private func drainQuestions(forSession sessionId: String, reason: String = "unknown") {
        questionQueue.removeAll { item in
            guard item.event.sessionId == sessionId else { return false }
            if item.isCodexAppServer {
                // Abandon the Codex app-server request so the server stops waiting.
                item.resolveCodexAppServer(nil)
            } else if item.isFromPermission {
                log.notice("⚠️ permission deny reason=drainQuestions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) tool=AskUserQuestion")
                let denyData = Data(
                    #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
                item.resolution.resumeHook(returning: denyData)
            } else {
                item.resolution.resumeHook(returning: Data("{}".utf8))
            }
            return true
        }
    }

    /// A card the user can no longer act on must never stay on screen: the panel
    /// would sit expanded showing a request that is gone or dismissed, and any
    /// click landing on it can only be discarded. Auto-open suppression decides
    /// whether to open a *new* card, not whether to keep a dead one, so this
    /// runs unconditionally. (#308)
    ///
    /// "Dead" is the same predicate `nextVisiblePermissionIndex()` applies:
    /// dismissed counts as not visible. Testing queue membership alone would
    /// keep a dismissed card up, because dismissing hides without dequeuing.
    private func collapseStaleCardSurface() {
        switch surface {
        case .approvalCard(let sid)
            where pendingPermission(forSession: sid) == nil
                || dismissedPermissionSessionIds.contains(sid):
            surface = .collapsed
        case .questionCard(let sid) where pendingQuestion(forSession: sid) == nil:
            surface = .collapsed
        default:
            break
        }
    }

    /// After dequeuing, show next pending item or collapse
    @discardableResult
    func showNextPending() -> Bool {
        collapseStaleCardSurface()
        if let idx = nextVisiblePermissionIndex() {
            let next = permissionQueue.remove(at: idx)
            permissionQueue.insert(next, at: 0)
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            // When the session list is open, keep it open; approvals can be handled inline.
            if surface != .sessionList,
               Self.autoExpandOnPermission(),
               shouldAutoOpenPendingSurface(for: sid) {
                surface = .approvalCard(sessionId: sid)
            }
            return true
        } else if let next = questionQueue.first {
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if shouldAutoOpenQuestionSurface(for: next.event) {
                surface = .questionCard(sessionId: sid)
            } else if case .questionCard = surface {
                // Smart Suppress wants this card collapsed (e.g. an OMP ask
                // whose terminal dialog is racing). Fold an inherited
                // question-card surface so the promoted card does not render
                // expanded on top of the previous question's surface.
                surface = .collapsed
            }
            return true
        } else if !completionQueue.isEmpty {
            while let next = completionQueue.first {
                completionQueue.removeFirst()
                if sessions[next] != nil {
                    withAnimation(NotchAnimation.pop) { doShowCompletion(next) }
                    return true
                }
            }
            return false
        } else if case .approvalCard = surface {
            surface = .collapsed
        } else if case .questionCard = surface {
            surface = .collapsed
        }
        return false
    }

    /// Find the most recently active non-idle session
    private func mostActiveSessionId() -> String? {
        // Pick the most urgent session: highest status priority, then most recent activity
        sessions.max { a, b in
            let pa = statusPriority(a.value.status)
            let pb = statusPriority(b.value.status)
            if pa != pb { return pa < pb }
            return a.value.lastActivity < b.value.lastActivity
        }?.key
    }

    /// Check if Cursor is in YOLO mode by reading its settings
    private static func detectCursorYoloMode() -> Bool {
        let settingsPath = NSHomeDirectory() + "/Library/Application Support/Cursor/User/settings.json"
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsPath),
              let data = fm.contents(atPath: settingsPath),
              let str = String(data: data, encoding: .utf8) else { return false }
        let stripped = ConfigInstaller.stripJSONComments(str)
        guard let strippedData = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: strippedData) as? [String: Any] else { return false }
        if json["cursor.general.yoloMode"] as? Bool == true { return true }
        if json["cursor.agent.enableYoloMode"] as? Bool == true { return true }
        return false
    }

    /// Read Claude model from a session transcript file.
    private nonisolated static func readModelFromTranscript(sessionId: String, cwd: String?) -> String? {
        guard let cwd = cwd else { return nil }
        let projectDir = cwd.claudeProjectDirEncoded()
        let path = "\(ClaudeConfigPaths.projectsDir())/\(projectDir)/\(sessionId).jsonl"
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        let chunk = handle.readData(ofLength: 32768)
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty
            else { continue }
            return model
        }
        return nil
    }

    private nonisolated static func readModelForSession(sessionId: String, session: SessionSnapshot) -> String? {
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return nil }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { liveProcessIdentity(for: $0)?.startTime }

        switch source {
        case "claude":
            return readModelFromTranscript(sessionId: sessionId, cwd: session.cwd)
        case "qoder", "qoder-cli":
            // ~/.qoder for the international build, ~/.qoder-cn for 国行 (#289).
            return qoderConfigRoots.lazy.compactMap { root in
                readModelFromProjectTranscript(
                    sessionId: sessionId,
                    cwd: session.cwd,
                    basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/\(root)/projects",
                    projectEncoder: { $0.claudeProjectDirEncoded() },
                    reader: readRecentFromTranscript(path:)
                )
            }.first

        case "droid":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.factory/sessions",
                projectEncoder: { $0.claudeProjectDirEncoded() },
                reader: readRecentFromFactoryTranscript(path:)
            )
        case "codebuddy":
            return readModelFromProjectTranscript(
                sessionId: sessionId,
                cwd: session.cwd,
                basePath: FileManager.default.homeDirectoryForCurrentUser.path + "/.codebuddy/projects",
                projectEncoder: { $0.appProjectDirEncoded() },
                reader: readRecentFromCodeBuddyTranscript(path:)
            )
        case "codex":
            return readModelFromCodexStore(cwd: session.cwd, processStart: processStart)
        case "gemini":
            return readModelFromGeminiStore(cwd: session.cwd, processStart: processStart)
        case "cursor", "cursor-cli":
            return readModelFromCursorStore(cwd: session.cwd, processStart: processStart)
        case "copilot":
            return readModelFromCopilotStore(cwd: session.cwd, processStart: processStart)
        case "opencode":
            return readModelFromOpenCodeStore(cwd: session.cwd, processStart: processStart)
        case "grok":
            return readModelFromGrokStore(cwd: session.cwd, processStart: processStart)
        default:
            return nil
        }
    }

    private nonisolated static func readModelFromProjectTranscript(
        sessionId: String,
        cwd: String?,
        basePath: String,
        projectEncoder: (String) -> String,
        reader: (String) -> (String?, [ChatMessage])
    ) -> String? {
        guard let cwd else { return nil }
        let path = "\(basePath)/\(projectEncoder(cwd))/\(sessionId).jsonl"
        return reader(path).0
    }

    private nonisolated static func readModelFromCodexStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = "\(home)/.codex/sessions"
        let fm = FileManager.default
        guard let path = findRecentCodexSession(base: base, cwd: cwd, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCodexTranscript(path: path).0
    }

    private nonisolated static func codexLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        let effectiveSessionId: String
        if let providerSessionId = session.providerSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !providerSessionId.isEmpty {
            effectiveSessionId = providerSessionId
        } else {
            effectiveSessionId = sessionId
        }
        let processStart = session.cliStartTime ?? session.cliPid.flatMap { liveProcessIdentity(for: $0)?.startTime }

        guard let transcriptPath = codexTranscriptPath(
            sessionId: effectiveSessionId,
            cwd: session.cwd,
            processStart: processStart
        ),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }

        return codexLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func qoderLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        guard let transcriptPath = qoderTranscriptPath(sessionId: sessionId, cwd: session.cwd),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }
        return qoderLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func codeBuddyLatestFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        guard let transcriptPath = codeBuddyTranscriptPath(sessionId: sessionId, cwd: session.cwd),
              let tail = readTranscriptTail(path: transcriptPath, maxBytes: 131072) else {
            return nil
        }
        return codeBuddyLatestTerminalTurnTimestamp(in: tail)
    }

    private nonisolated static func nativeAppFinishedTurnTimestamp(
        sessionId: String,
        session: SessionSnapshot
    ) -> Date? {
        switch session.source {
        case "codex":
            return codexLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        case "qoder", "qoder-cli":
            return qoderLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        case "codebuddy":
            return codeBuddyLatestFinishedTurnTimestamp(sessionId: sessionId, session: session)
        default:
            return nil
        }
    }

    private nonisolated static func codexTranscriptPath(
        sessionId: String,
        cwd: String?,
        processStart: Date?
    ) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let statePath = "\(home)/.codex/state_5.sqlite"

        if let path: String = withSQLiteDatabase(at: statePath, body: { db in
            guard let statement = prepareSQLiteStatement(
                db: db,
                sql: """
                    SELECT rollout_path
                    FROM threads
                    WHERE id = ?
                    LIMIT 1;
                    """
            ) else {
                return nil
            }
            defer { sqlite3_finalize(statement) }

            bindSQLiteText(sessionId, to: statement, index: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqliteColumnString(statement, index: 0)
        }),
           FileManager.default.fileExists(atPath: path) {
            return path
        }

        guard let cwd else { return nil }
        let base = "\(home)/.codex/sessions"
        return findRecentCodexSession(base: base, cwd: cwd, after: processStart, fm: .default)
    }

    /// Config roots a Qoder session's transcript can live under: the international
    /// build uses ~/.qoder, the China build (`qoderclicn`) uses ~/.qoder-cn (#289).
    private nonisolated static let qoderConfigRoots = [".qoder", ".qoder-cn"]

    private nonisolated static func qoderTranscriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = qoderConfigRoots.flatMap { root -> [String] in
            let projectPath = home
                .appendingPathComponent("\(root)/projects/\(cwd.claudeProjectDirEncoded())")
            return [
                projectPath.appendingPathComponent("\(sessionId).jsonl").path,
                projectPath.appendingPathComponent("transcript/\(sessionId).jsonl").path,
            ]
        }

        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private nonisolated static func codeBuddyTranscriptPath(sessionId: String, cwd: String?) -> String? {
        guard let cwd else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy/projects/\(cwd.appProjectDirEncoded())/\(sessionId).jsonl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private nonisolated static func readModelFromGeminiStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let tmpBase = "\(home)/.gemini/tmp"
        guard let projectDir = findGeminiProjectDirectory(
            for: cwd,
            tmpBase: tmpBase,
            projects: readGeminiProjectsMap(path: "\(home)/.gemini/projects.json"),
            fm: fm
        ) else {
            return nil
        }
        let chatsBase = "\(tmpBase)/\(projectDir)/chats"
        guard let best = findMostRecentGeminiSession(in: chatsBase, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromGeminiTranscript(path: best.path).1
    }

    private nonisolated static func readModelFromCursorStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let transcriptBase = "\(home)/.cursor/projects/\(cwd.appProjectDirEncoded())/agent-transcripts"
        guard let best = findMostRecentCursorTranscript(in: transcriptBase, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCursorTranscript(path: best.path).0
    }

    private nonisolated static func readModelFromCopilotStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.copilot/session-state"
        guard let best = findRecentCopilotSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
            return nil
        }
        return readRecentFromCopilotTranscript(path: best.path).0
    }

    private nonisolated static func readModelFromOpenCodeStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
        return withSQLiteDatabase(at: dbPath) { db in
            guard let session = findRecentOpenCodeSession(in: db, cwd: cwd, after: processStart) else {
                return nil
            }
            return readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId).0
        }
    }

    private nonisolated static func readModelFromGrokStore(cwd: String?, processStart: Date?) -> String? {
        guard let cwd else { return nil }
        return findRecentGrokSession(cwd: cwd, after: processStart)?.model
    }

    // MARK: - Session Discovery (FSEventStream + process scan)
    // MARK: - Session Persistence

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.saveSessions()
            }
        }
    }

    func saveSessions() {
        SessionPersistence.save(sessions)
    }

    private func restoreSessions() {
        let persisted = SessionPersistence.load()
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        for p in persisted where p.lastActivity > cutoff {
            guard let source = SessionSnapshot.normalizedSupportedSource(p.source) else { continue }
            let restoredSessionId = Self.canonicalRestoredCodexSessionId(
                sessionId: p.sessionId,
                source: source,
                providerSessionId: p.providerSessionId,
                termBundleId: p.termBundleId
            )
            guard sessions[restoredSessionId] == nil else { continue }
            var snapshot = SessionSnapshot(startTime: p.startTime)
            snapshot.cwd = p.cwd
            snapshot.source = source
            snapshot.model = p.model
            snapshot.sessionTitle = p.sessionTitle
            snapshot.sessionTitleSource = p.sessionTitleSource
            snapshot.providerSessionId = p.providerSessionId
            snapshot.lastUserPrompt = p.lastUserPrompt
            snapshot.lastAssistantMessage = p.lastAssistantMessage
            if let prompt = p.lastUserPrompt {
                snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
            }
            if let reply = p.lastAssistantMessage {
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
            snapshot.termApp = p.termApp
            snapshot.itermSessionId = p.itermSessionId
            snapshot.ttyPath = p.ttyPath
            snapshot.kittyWindowId = p.kittyWindowId
            snapshot.tmuxPane = p.tmuxPane
            snapshot.tmuxClientTty = p.tmuxClientTty
            snapshot.tmuxEnv = p.tmuxEnv
            snapshot.termBundleId = p.termBundleId
            snapshot.cmuxSurfaceId = p.cmuxSurfaceId
            snapshot.cmuxWorkspaceId = p.cmuxWorkspaceId
            snapshot.zellijPaneId = p.zellijPaneId
            snapshot.zellijSessionName = p.zellijSessionName
            snapshot.weztermPaneId = p.weztermPaneId
            snapshot.lastActivity = p.lastActivity
            snapshot.transcriptPath = p.transcriptPath
            if let closed = p.closedSubagentIds, !closed.isEmpty {
                snapshot.restoreClosedSubagentIds(closed)
            }
            // Restore persisted cliPid only if the process is still alive — avoids
            // stale sessions reappearing briefly after the app or IDE restarts (#46).
            if let pid = p.cliPid, pid > 0 {
                let identity = ProcessIdentity(pid: pid, startTime: p.cliStartTime)
                if Self.isLiveProcess(identity) {
                    snapshot.cliPid = pid
                    snapshot.cliStartTime = p.cliStartTime
                }
            }
            // Skip sessions whose process is dead and status was idle — nothing to show.
            // Keep Cursor Task tombstones / foldable orphans so applyCursor… can still
            // honor closedSubagentIds after relaunch (otherwise merge can revive them).
            if snapshot.cliPid == nil && snapshot.status == .idle && snapshot.lastUserPrompt == nil,
               !Self.shouldKeepRestoredIdleCursorSession(
                source: source,
                sessionId: restoredSessionId,
                providerSessionId: snapshot.providerSessionId,
                transcriptPath: snapshot.transcriptPath,
                closedSubagentIds: snapshot.closedSubagentIds
               ) {
                continue
            }
            sessions[restoredSessionId] = snapshot
            refreshProviderTitle(for: restoredSessionId)
            // Branch is re-read, not persisted — it may have changed between runs.
            maybeRefreshGitBranch(
                for: restoredSessionId,
                cwdBefore: nil,
                normalizedEventName: "SessionStart"
            )
            // Reattach exit monitoring without changing the restored idle/running snapshot.
            tryMonitorSession(restoredSessionId)
        }
        SessionPersistence.clear()
        _ = applyCodexSubsessionModeToKnownSessions()
        _ = applyCursorSubsessionModeToKnownSessions()
        if activeSessionId == nil {
            activeSessionId = sessions.first(where: { $0.value.status != .idle })?.key
                ?? sessions.keys.sorted().first
        }
        refreshDerivedState()
    }

    /// Idle snapshots with no live process are usually discarded on restore.
    /// Keep Cursor Task cards that carry a Stop tombstone so merge can still
    /// honor `closedSubagentIds` after relaunch. A foldable transcript alone is
    /// not enough — that would rehydrate finished Tasks when Stop was missed.
    nonisolated static func shouldKeepRestoredIdleCursorSession(
        source: String,
        sessionId: String,
        providerSessionId: String?,
        transcriptPath: String?,
        closedSubagentIds: [String]
    ) -> Bool {
        guard source == "cursor" || source == "cursor-cli" else { return false }
        return !closedSubagentIds.isEmpty
    }

    private nonisolated static func findDiscoveredSessions() -> [DiscoveredSession] {
        let candidatePids = allProcessIds()
        var discovered: [DiscoveredSession] = []
        if ConfigInstaller.isEnabled(source: "claude") {
            discovered.append(contentsOf: findActiveClaudeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codex") {
            discovered.append(contentsOf: findActiveCodexSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "gemini") {
            discovered.append(contentsOf: findActiveGeminiSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "qoder") {
            discovered.append(contentsOf: findActiveQoderSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "codebuddy") {
            discovered.append(contentsOf: findActiveCodeBuddySessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "droid") {
            discovered.append(contentsOf: findActiveFactorySessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "cursor") {
            discovered.append(contentsOf: findActiveCursorSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "copilot") {
            discovered.append(contentsOf: findActiveCopilotSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "opencode") {
            discovered.append(contentsOf: findActiveOpenCodeSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "kimi") {
            discovered.append(contentsOf: findActiveKimiSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "grok") {
            discovered.append(contentsOf: findActiveGrokSessions(candidatePids: candidatePids))
        }
        if ConfigInstaller.isEnabled(source: "cline") {
            discovered.append(contentsOf: findActiveClineSessions(candidatePids: candidatePids))
        }
        return discovered
    }

    private nonisolated static func discoveryWatchRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [(String, String)] = [
            ("claude", ClaudeConfigPaths.projectsDir()),
            ("codex", "\(home)/.codex/sessions"),
            ("gemini", "\(home)/.gemini/tmp"),
            ("qoder", "\(home)/.qoder/projects"),
            ("codebuddy", "\(home)/.codebuddy/projects"),
            ("droid", "\(home)/.factory/sessions"),
            ("cursor", "\(home)/.cursor/projects"),
            ("copilot", "\(home)/.copilot/session-state"),
            ("opencode", "\(home)/.local/share/opencode"),
            ("kimi", "\(home)/.kimi-code/sessions"),
            ("kimi", "\(home)/.kimi/sessions"),
            ("grok", "\(ConfigInstaller.grokHome())/sessions"),
        ]
        let fm = FileManager.default
        var roots = candidates.compactMap { source, path -> String? in
            guard ConfigInstaller.isEnabled(source: source), fm.fileExists(atPath: path) else { return nil }
            return path
        }
        if ConfigInstaller.isEnabled(source: "cline") {
            let clineBase = Self.clineStorageRoot()
            for sub in ["state", "tasks"] {
                let p = "\(clineBase)/\(sub)"
                if fm.fileExists(atPath: p) { roots.append(p) }
            }
        }
        return roots
    }

    private func requestDiscoveryScan() {
        if discoveryScanTask != nil {
            pendingDiscoveryRescan = true
            return
        }

        pendingDiscoveryRescan = false
        discoveryScanTask = Task.detached { [weak self] in
            let discovered = Self.findDiscoveredSessions()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.discoveryScanTask = nil
                    return
                }
                self.integrateDiscovered(discovered)
                self.discoveryScanTask = nil
                if self.pendingDiscoveryRescan {
                    self.pendingDiscoveryRescan = false
                    self.requestDiscoveryScan()
                }
            }
        }
    }

    /// FSEvents is not guaranteed to report every append below
    /// `~/.codex/sessions` on all macOS/filesystem combinations. Reuse the
    /// cleanup tick as a low-frequency fallback, but only while Codex Desktop
    /// is running and only after the polling interval has elapsed.
    nonisolated static func shouldPollCodexDesktopDiscovery(
        runningBundleIdentifiers: Set<String>,
        lastPollAt: Date?,
        now: Date,
        interval: TimeInterval = 6
    ) -> Bool {
        guard runningBundleIdentifiers.contains(codexAppBundleId) else { return false }
        guard let lastPollAt else { return true }
        return now.timeIntervalSince(lastPollAt) >= interval
    }

    func requestCodexDesktopDiscoveryScan() {
        guard codexDesktopDiscoveryScanTask == nil else { return }
        codexDesktopDiscoveryScanTask = Task.detached { [weak self] in
            let discovered = ConfigInstaller.isEnabled(source: "codex")
                ? Self.findRecentCodexDesktopSessions()
                : []
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard !Task.isCancelled else {
                    self.codexDesktopDiscoveryScanTask = nil
                    return
                }
                self.integrateDiscovered(discovered)
                self.codexDesktopDiscoveryScanTask = nil
            }
        }
    }

    func startSessionDiscovery() {
        startCleanupTimer()
        // Restore persisted sessions before process scan (deduped by scan)
        restoreSessions()

        // Initial scan for already-running sessions, respecting per-source toggles.
        requestDiscoveryScan()
        // Watch all known session-store roots so discovery keeps working when hooks are missed.
        startProjectsWatcher()
    }

    /// FSEventStream on known session-store roots — fires when transcript/event files change.
    private func startProjectsWatcher() {
        guard fsEventStream == nil else { return }
        let watchRoots = Self.discoveryWatchRoots()
        guard !watchRoots.isEmpty else { return }

        let box = ProjectsWatcherBox()
        box.appState = self

        var context = FSEventStreamContext()
        // Unretained box is owned by `projectsWatcherBox` until
        // `tearDownProjectsWatcher()`; the weak back-pointer keeps callbacks
        // safe across off-main `AppState` deinit.
        context.info = Unmanaged.passUnretained(box).toOpaque()

        let stream = FSEventStreamCreate(
            nil,
            { (_, info, _, _, _, _) in
                guard let info = info else { return }
                let box = Unmanaged<ProjectsWatcherBox>.fromOpaque(info).takeUnretainedValue()
                box.handleChange()
            },
            &context,
            watchRoots as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,  // 2-second latency (coalesces rapid writes)
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagFileEvents
            )
        )

        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.projectsWatcherBox = box
        self.fsEventStream = stream
        log.info("Discovery watcher started on \(watchRoots.joined(separator: ", "))")
    }

    /// Called by FSEventStream when a known session-store directory changes.
    nonisolated fileprivate func handleProjectsDirChange() {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // FSEvents already coalesces writes with a two-second latency, and
            // requestDiscoveryScan() coalesces events that arrive during a scan.
            // Dropping events in an additional time window can miss the final
            // lifecycle write and leave the island showing stale state.
            self.requestDiscoveryScan()
        }
    }

    /// Provider thread IDs are authoritative when both sides have one. Two
    /// native Codex Desktop threads can legitimately share a source and CWD
    /// while having no PID, so they must not be collapsed into one card merely
    /// because the generic discovery heuristic sees the same project path.
    nonisolated static func providerSessionIdentifiersMayRepresentSameSession(
        existing: String?,
        discovered: String?
    ) -> Bool {
        guard let discovered, !discovered.isEmpty else { return true }
        guard let existing, !existing.isEmpty else { return false }
        return existing == discovered
    }

    /// Native-app and CLI discoveries are separate namespaces even when they
    /// share the same provider and working directory. In particular, a Codex
    /// CLI rollout has no native host bundle and must not be folded into a
    /// Codex Desktop card left by state-database discovery.
    nonisolated static func discoveryAppModesMayRepresentSameSession(
        existingIsNativeAppMode: Bool,
        discoveredTermBundleId: String?
    ) -> Bool {
        existingIsNativeAppMode == (discoveredTermBundleId != nil)
    }

    /// Completed Codex subagents are transient workers, not idle top-level
    /// sessions. Their spawn-edge row may remain `open`, so transcript lifecycle
    /// is the reliable signal for removing them from the island.
    nonisolated static func isCompletedCodexSubagentDiscovery(
        source: String,
        parentSessionId: String?,
        status: AgentStatus?
    ) -> Bool {
        source == "codex"
            && parentSessionId?.isEmpty == false
            && status == .idle
    }

    /// Update existing session's messages from discovered transcript data.
    private func backfillSessionMessages(sessionId: String, from info: DiscoveredSession) -> Bool {
        guard var session = sessions[sessionId], !info.recentMessages.isEmpty else { return false }
        guard info.modifiedAt >= session.lastActivity || session.recentMessages.isEmpty else {
            return false
        }
        var mutated = false
        let messagesChanged = session.recentMessages.count != info.recentMessages.count ||
            zip(session.recentMessages, info.recentMessages).contains { $0.isUser != $1.isUser || $0.text != $1.text }
        if messagesChanged {
            session.recentMessages = info.recentMessages
            mutated = true
        }
        if let lastUser = info.recentMessages.last(where: { $0.isUser }),
           session.lastUserPrompt != lastUser.text {
            session.lastUserPrompt = lastUser.text
            mutated = true
        }
        if let lastAssistant = info.recentMessages.last(where: { !$0.isUser }),
           session.lastAssistantMessage != lastAssistant.text {
            session.lastAssistantMessage = lastAssistant.text
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// Merge discovered sessions into current state (skip already-known ones)
    func integrateDiscovered(_ discovered: [DiscoveredSession]) {
        var didMutate = false
        for info in discovered {
            if shouldSuppressClosedCodexDesktopDiscovery(info) {
                continue
            }
            if routeDiscoveredSubsessionIfNeeded(info) {
                didMutate = true
                continue
            }

            if Self.isCompletedCodexSubagentDiscovery(
                source: info.source,
                parentSessionId: info.parentSessionId,
                status: info.status
            ) {
                if sessions[info.sessionId] != nil {
                    removeSession(info.sessionId)
                    didMutate = true
                }
                continue
            }

            // Session already known — try to update PID and attach monitor.
            // Discovery PIDs are heuristic (matched by CWD), so when the session already
            // has a known-good alive PID that differs from discovery, we trust the existing
            // one for both cliPid and monitor to avoid cross-session contamination.
            if sessions[info.sessionId] != nil {
                if applyDiscoveredRuntimeState(info, to: info.sessionId) {
                    didMutate = true
                }
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[info.sessionId]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: info.sessionId)
                    let existingAlive = existingProcess.map(Self.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                        // Existing PID is alive and different — discovery PID is unreliable.
                    } else {
                        // No existing PID, or it's dead, or it matches — safe to use discovery PID.
                        if !existingAlive, let process = Self.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: info.sessionId)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: info.sessionId, from: info) {
                    didMutate = true
                }
                if applyDiscoveredMetadata(info, to: info.sessionId) {
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
                tryMonitorSession(info.sessionId)
                refreshProviderTitle(
                    for: info.sessionId,
                    providerSessionId: info.providerSessionId ?? info.sessionId
                )
                continue
            }

            // Dedup: if a hook-created session already exists with same source + cwd + pid,
            // skip the discovered one to avoid duplicate entries (e.g. Codex hooks vs
            // file-based discovery produce different session IDs for the same process).
            // Only dedup when PID matches (or discovered has no PID), so concurrent
            // sessions in the same repo aren't incorrectly merged.
            // Never merge a discovery (CLI) session with an existing native app session —
            // they're fundamentally different even if they share source + cwd.
            let duplicateKey = sessions.first(where: { (_, existing) in
                guard existing.source == info.source,
                      existing.cwd != nil, existing.cwd == info.cwd else { return false }
                guard Self.discoveryAppModesMayRepresentSameSession(
                    existingIsNativeAppMode: existing.isNativeAppMode,
                    discoveredTermBundleId: info.termBundleId
                ) else { return false }
                guard Self.providerSessionIdentifiersMayRepresentSameSession(
                    existing: existing.providerSessionId,
                    discovered: info.providerSessionId
                ) else { return false }
                // Don't merge CLI discovery into a stale native app session whose app has quit —
                // the PID was likely reattached incorrectly. If the native app IS running, allow merge.
                if existing.isNativeAppMode,
                   let bid = existing.termBundleId,
                   !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid }) {
                    return false
                }
                // If we have PIDs for both and the existing one is still alive, they must match.
                // Dead persisted PIDs should not block dedup / reattachment.
                if let discoveredPid = info.pid, let existingPid = existing.cliPid,
                   discoveredPid != existingPid,
                   Self.isLiveProcess(ProcessIdentity(pid: existingPid, startTime: existing.cliStartTime)) { return false }
                return true
            })?.key

            if let existingKey = duplicateKey {
                if applyDiscoveredRuntimeState(info, to: existingKey) {
                    didMutate = true
                }
                // Same guard as above: don't let unreliable discovery PID contaminate
                // an existing session that has a known-good alive PID.
                if let pid = info.pid, pid > 0 {
                    let existingPid = sessions[existingKey]?.cliPid ?? 0
                    let existingProcess = resolvedSessionProcessIdentity(for: existingKey)
                    let existingAlive = existingProcess.map(Self.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                    } else {
                        if !existingAlive, let process = Self.liveProcessIdentity(for: pid) {
                            setSessionProcessIdentity(process, for: existingKey)
                            didMutate = true
                        }
                    }
                }
                if backfillSessionMessages(sessionId: existingKey, from: info) {
                    didMutate = true
                }
                if applyDiscoveredMetadata(info, to: existingKey) {
                    didMutate = true
                }
                attachTranscriptTailerIfNeeded(sessionId: existingKey)
                tryMonitorSession(existingKey)
                refreshProviderTitle(
                    for: existingKey,
                    providerSessionId: info.providerSessionId ?? info.sessionId
                )
                continue
            }

            var session = SessionSnapshot(startTime: info.modifiedAt)
            session.cwd = info.cwd
            session.model = info.model
            session.ttyPath = info.tty
            session.recentMessages = info.recentMessages
            session.source = info.source
            session.status = info.status ?? .idle
            session.lastActivity = info.modifiedAt
            session.termBundleId = info.termBundleId
            if let pid = info.pid, let process = Self.liveProcessIdentity(for: pid) {
                session.cliPid = process.pid
                session.cliStartTime = process.startTime
            } else {
                session.cliPid = info.pid
            }
            session.providerSessionId = SessionTitleStore.supports(provider: info.source)
                ? (info.providerSessionId ?? info.sessionId)
                : nil
            if let last = info.recentMessages.last(where: { $0.isUser }) {
                session.lastUserPrompt = last.text
            }
            if let last = info.recentMessages.last(where: { !$0.isUser }) {
                session.lastAssistantMessage = last.text
            }
            session.transcriptPath = info.transcriptPath
            sessions[info.sessionId] = session
            refreshProviderTitle(
                for: info.sessionId,
                providerSessionId: info.providerSessionId ?? info.sessionId
            )
            tryMonitorSession(info.sessionId)
            attachTranscriptTailerIfNeeded(sessionId: info.sessionId)
            didMutate = true
        }
        if applyCodexSubsessionModeToKnownSessions() {
            didMutate = true
        }
        if applyCursorSubsessionModeToKnownSessions() {
            didMutate = true
        }
        if didMutate && activeSessionId == nil {
            activeSessionId = sessions.keys.sorted().first
        }
        if didMutate {
            scheduleSave()
        }
        refreshDerivedState()
    }

    private func shouldSuppressClosedCodexDesktopDiscovery(_ info: DiscoveredSession) -> Bool {
        guard info.source == "codex",
              info.termBundleId == Self.codexAppBundleId,
              let providerSessionId = info.providerSessionId,
              let closedAt = closedCodexAppThreads[providerSessionId] else {
            return false
        }
        if info.modifiedAt <= closedAt {
            return true
        }
        // A terminal flush may land just after `thread/closed`; only a newer
        // processing lifecycle is evidence that the thread genuinely resumed.
        guard info.status == .processing else { return true }
        closedCodexAppThreads.removeValue(forKey: providerSessionId)
        return false
    }

    /// Apply runtime fields that filesystem/state-DB discovery can know more
    /// accurately than a stale restored snapshot. Interactive approval/question
    /// states remain authoritative until their owning channel resolves them.
    @discardableResult
    private func applyDiscoveredRuntimeState(_ info: DiscoveredSession, to sessionId: String) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        var mutated = false
        let canApplyStatus = info.modifiedAt >= session.lastActivity

        if info.modifiedAt > session.lastActivity {
            session.lastActivity = info.modifiedAt
            mutated = true
        }
        if let bundleId = info.termBundleId,
           (canApplyStatus || session.termBundleId == nil),
           session.termBundleId != bundleId {
            session.termBundleId = bundleId
            mutated = true
        }
        if let discoveredStatus = info.status,
           canApplyStatus,
           session.status != .waitingApproval,
           session.status != .waitingQuestion,
           session.status != discoveredStatus {
            session.status = discoveredStatus
            if discoveredStatus == .idle {
                session.currentTool = nil
                session.toolDescription = nil
            }
            mutated = true
        }

        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    /// CWD and transcript path participate in tailer/process routing, so an old
    /// asynchronous scan must not rewind them after a newer DB result. Missing
    /// restored fields may still be filled regardless of timestamp.
    @discardableResult
    private func applyDiscoveredMetadata(_ info: DiscoveredSession, to sessionId: String) -> Bool {
        guard var session = sessions[sessionId] else { return false }
        let canReplace = info.modifiedAt >= session.lastActivity
        var mutated = false

        if (canReplace || session.cwd?.isEmpty != false), session.cwd != info.cwd {
            session.cwd = info.cwd
            mutated = true
        }
        if let path = info.transcriptPath,
           (canReplace || session.transcriptPath == nil),
           session.transcriptPath != path {
            session.transcriptPath = path
            mutated = true
        }
        if mutated {
            sessions[sessionId] = session
        }
        return mutated
    }

    @discardableResult
    func applyCodexSubsessionModeToKnownSessions(statePath: String? = nil) -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == "hide" || mode == "merge" else {
            return false
        }

        let candidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        var transcriptMetadata: [String: CodexSubagentMetadata] = [:]
        var databaseLookupIds: Set<String> = []

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            if let transcriptPath = candidate.session.transcriptPath {
                switch Self.inspectCodexSubagentMetadata(inTranscriptPath: transcriptPath) {
                case .subagent(let metadata):
                    transcriptMetadata[candidate.sessionId] = metadata
                    databaseLookupIds.insert(providerSessionId)
                case .root:
                    // A readable root session_meta is definitive. Falling back
                    // to SQLite here turns every root card into a separate DB
                    // open and can also resurrect stale spawn-edge relations.
                    continue
                case .unavailable:
                    databaseLookupIds.insert(providerSessionId)
                }
            } else {
                databaseLookupIds.insert(providerSessionId)
            }
        }
        // One read-only DB connection for all candidates that genuinely need
        // relation/status fallback. Root transcripts never enter this query.
        let databaseRecords = Self.codexSpawnEdgeRecords(
            threadIds: databaseLookupIds,
            statePath: statePath
        )
        var didMutate = false

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            guard let metadata = transcriptMetadata[candidate.sessionId]
                    ?? databaseRecords[providerSessionId]?.metadata,
                  metadata.parentThreadId != providerSessionId else {
                continue
            }

            if mode == "hide" {
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            guard let parentKey = findCodexParentSessionId(
                providerSessionId: metadata.parentThreadId,
                childTermBundleId: candidate.session.termBundleId
            ),
                  parentKey != candidate.sessionId else {
                continue
            }

            // Preserve the terminal snapshot before removeSession tears down the
            // child card. Transcript lifecycle is authoritative even when the
            // spawn edge is missing or remains "open".
            let completedByTranscript = candidate.session.status == .idle
            if sessions[candidate.sessionId] != nil {
                removeSession(candidate.sessionId)
                didMutate = true
            }

            if completedByTranscript
                || databaseRecords[providerSessionId]?.status?.lowercased() == "closed" {
                if sessions[parentKey]?.subagents.removeValue(forKey: providerSessionId) != nil {
                    if sessions[parentKey]?.subagents.isEmpty == true {
                        clearSubagentProjection(fromParentSession: parentKey)
                    }
                    didMutate = true
                }
                continue
            }

            let agentType = metadata.agentType ?? metadata.agentNickname ?? "Agent"
            var subagent = sessions[parentKey]?.subagents[providerSessionId]
                ?? SubagentState(agentId: providerSessionId, agentType: agentType)
            subagent.status = candidate.session.status
            subagent.currentTool = candidate.session.currentTool
            subagent.toolDescription = candidate.session.toolDescription ?? metadata.agentNickname
            if candidate.session.lastActivity > subagent.lastActivity {
                subagent.lastActivity = candidate.session.lastActivity
            }
            sessions[parentKey]?.subagents[providerSessionId] = subagent

            if sessions[parentKey]?.status != .waitingApproval && sessions[parentKey]?.status != .waitingQuestion {
                sessions[parentKey]?.status = .running
                sessions[parentKey]?.currentTool = "Agent"
                sessions[parentKey]?.toolDescription = metadata.agentNickname ?? agentType
            }
            if candidate.session.lastActivity > (sessions[parentKey]?.lastActivity ?? .distantPast) {
                sessions[parentKey]?.lastActivity = candidate.session.lastActivity
            }
            activeSessionId = parentKey
            didMutate = true
        }

        return didMutate
    }

    /// Apply Agent Sub-Sessions to known Cursor Task/subagent cards
    /// (`transcriptPath` is the parent chat; `session_id` is the child).
    /// `merge` / `hide` only; `separate` is handled by `separateMergedCursorSubagents()`.
    @discardableResult
    func applyCursorSubsessionModeToKnownSessions() -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == "hide" || mode == "merge" else {
            return false
        }

        // Cursor Agent Tasks that fired Claude-format hooks keep default
        // source=claude and never enter the fold loop — rebrand first.
        var didMutate = rebrandMisattributedCursorTaskCards()

        // Refresh after rebrand so newly tagged cursor cards are included.
        let candidates = sessions.map { (sessionId: $0.key, session: $0.value) }

        if mode == "hide" {
            for candidate in candidates {
                let source = candidate.session.source
                guard source == "cursor" || source == "cursor-cli" else { continue }
                guard cursorFoldIdentity(for: candidate) != nil else { continue }
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
            }
            return hideMergedCursorSubagents() || didMutate
        }

        for candidate in candidates {
            let source = candidate.session.source
            guard source == "cursor" || source == "cursor-cli" else { continue }
            guard let fold = cursorFoldIdentity(for: candidate) else { continue }
            let parentId = fold.parentId
            let childId = fold.childId

            // If fold identity collides with this card, prefer the real parent id
            // (child wrongly reused the parent's providerSessionId).
            var parentKey = findSessionId(providerSessionId: parentId) ?? parentId
            if parentKey == candidate.sessionId {
                parentKey = parentId
            }
            if parentKey == candidate.sessionId { continue }

            // Closed ids may sit on the parent (merge Stop) or the child card
            // (separate Stop). Parent tombstone always wins over a late-running
            // orphan card — relaunch clears via UserPromptSubmit on the hook path.
            let candidateCarriesClosed = candidate.session.hasClosedSubagentId(childId)
                || candidate.session.hasClosedSubagentId(candidate.sessionId)
            let parentHoldsTombstone = sessions[parentKey]?.hasClosedSubagentId(childId) == true

            if candidateCarriesClosed || parentHoldsTombstone {
                if sessions[parentKey] == nil {
                    var parent = SessionSnapshot(startTime: candidate.session.startTime)
                    parent.source = source
                    parent.cwd = candidate.session.cwd
                    parent.model = candidate.session.model
                    parent.termApp = candidate.session.termApp
                    parent.termBundleId = candidate.session.termBundleId
                    parent.transcriptPath = candidate.session.transcriptPath
                    parent.providerSessionId = parentId
                    // Closed ids only — parent is not actively working.
                    parent.status = .idle
                    parent.lastActivity = candidate.session.lastActivity
                    sessions[parentKey] = parent
                }
                promoteCursorClosedIds(
                    onto: parentKey,
                    childId: childId,
                    candidateSessionId: candidate.sessionId,
                    childClosed: candidate.session.closedSubagentIds
                )
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            // Idle orphan: always drop — never overwrite a live merged Task slot
            // with an AfterAgentResponse→idle discovery card. Tombstones were
            // already handled above; plain idle must not invent parents either.
            if candidate.session.status == .idle {
                if sessions[candidate.sessionId] != nil {
                    removeSession(candidate.sessionId)
                    didMutate = true
                }
                continue
            }

            if sessions[parentKey] == nil {
                var parent = SessionSnapshot(startTime: candidate.session.startTime)
                parent.source = source
                parent.cwd = candidate.session.cwd
                parent.model = candidate.session.model
                parent.termApp = candidate.session.termApp
                parent.termBundleId = candidate.session.termBundleId
                parent.transcriptPath = candidate.session.transcriptPath
                // Do not copy the Task/subagent process identity onto the parent chat.
                parent.providerSessionId = parentId
                parent.status = candidate.session.status == .idle ? .processing : candidate.session.status
                parent.lastActivity = candidate.session.lastActivity
                sessions[parentKey] = parent
            } else if sessions[parentKey]?.transcriptPath == nil,
                      let path = candidate.session.transcriptPath {
                sessions[parentKey]?.transcriptPath = path
            }

            if sessions[candidate.sessionId] != nil {
                removeSession(candidate.sessionId)
                didMutate = true
            }

            // Prefer an existing parent monitor; skip if we only synthesized metadata.
            if sessions[parentKey]?.cliPid != nil || sessions[parentKey]?.transcriptPath != nil {
                if sessions[parentKey]?.transcriptPath != nil {
                    attachTranscriptTailerIfNeeded(sessionId: parentKey)
                }
                if sessions[parentKey]?.cliPid != nil {
                    tryMonitorSession(parentKey)
                }
            }

            var subagent = sessions[parentKey]?.subagents[childId]
                ?? SubagentState(agentId: childId, agentType: "cursor-subagent")
            subagent.status = candidate.session.status
            subagent.currentTool = candidate.session.currentTool
            subagent.toolDescription = candidate.session.toolDescription
            if candidate.session.lastActivity > subagent.lastActivity {
                subagent.lastActivity = candidate.session.lastActivity
            }
            sessions[parentKey]?.subagents[childId] = subagent

            if sessions[parentKey]?.status != .waitingApproval
                && sessions[parentKey]?.status != .waitingQuestion {
                sessions[parentKey]?.status = .running
                if sessions[parentKey]?.currentTool == nil {
                    sessions[parentKey]?.currentTool = "Agent"
                    sessions[parentKey]?.toolDescription = "cursor-subagent"
                }
            }
            if candidate.session.lastActivity > (sessions[parentKey]?.lastActivity ?? .distantPast) {
                sessions[parentKey]?.lastActivity = candidate.session.lastActivity
            }
            activeSessionId = parentKey
            didMutate = true
        }

        return didMutate
    }

    /// Record the foldable child id(s) on the parent — not an arbitrary union of
    /// whatever closed set the orphan card carried.
    private func promoteCursorClosedIds(
        onto parentKey: String,
        childId: String,
        candidateSessionId: String,
        childClosed: [String]
    ) {
        sessions[parentKey]?.recordClosedSubagentId(childId)
        if candidateSessionId != childId {
            sessions[parentKey]?.recordClosedSubagentId(candidateSessionId)
        }
        for id in childClosed where id == childId || id == candidateSessionId {
            sessions[parentKey]?.recordClosedSubagentId(id)
        }
    }

    private func markMergedSubagentWaiting(
        sessionId: String,
        agentId: String?,
        status: AgentStatus
    ) {
        guard let agentId else { return }
        guard var session = sessions[sessionId] else { return }
        var subagent = session.subagents[agentId]
            ?? SubagentState(agentId: agentId, agentType: "cursor-subagent")
        subagent.status = status
        subagent.lastActivity = Date()
        session.subagents[agentId] = subagent
        sessions[sessionId] = session
    }

    /// After Permission/Question UI resolves for a possibly folded Task.
    /// With `agent_id`, never idle the parent — even if the subagent slot was
    /// already removed (Stop race). Uses local copies to avoid exclusivity traps
    /// when mutating nested `sessions[id].subagents[id]` fields.
    private func resolveMergedSubagentAfterUI(
        sessionId: String,
        agentId: String?,
        subagentStatus: AgentStatus,
        keepSubagentTool: String?,
        idleParentWhenNoAgent: Bool
    ) {
        if let agentId {
            guard var session = sessions[sessionId] else { return }
            if var subagent = session.subagents[agentId] {
                subagent.status = subagentStatus
                if subagentStatus == .processing {
                    subagent.currentTool = nil
                    subagent.toolDescription = nil
                } else if let keepSubagentTool {
                    subagent.currentTool = keepSubagentTool
                }
                session.subagents[agentId] = subagent
            }
            let hasNonIdleSubagents = session.subagents.values.contains { $0.status != .idle }
            if hasNonIdleSubagents {
                let agentType = session.subagents[agentId]?.agentType ?? "cursor-subagent"
                session.status = .running
                session.currentTool = "Agent"
                if session.toolDescription == nil {
                    session.toolDescription = agentType
                }
            } else {
                session.status = .processing
                session.currentTool = nil
                session.toolDescription = nil
            }
            sessions[sessionId] = session
            return
        }

        if idleParentWhenNoAgent {
            sessions[sessionId]?.status = .idle
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        } else {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
    }

    /// Suppress Permission/Question UI for Stop'd Tasks: merged `agent_id` tombstones
    /// or separate-mode self-tombstones (card id recorded in ``closedSubagentIds``).
    private func shouldSuppressClosedSubagentUI(sessionId: String, agentId: String?) -> Bool {
        if let agentId, sessions[sessionId]?.hasClosedSubagentId(agentId) == true { return true }
        if agentId == nil, sessions[sessionId]?.hasClosedSubagentId(sessionId) == true { return true }
        return false
    }

    /// Parent/child ids when this card's transcript belongs to another Cursor chat.
    private func cursorFoldIdentity(
        for candidate: (sessionId: String, session: SessionSnapshot)
    ) -> (parentId: String, childId: String)? {
        // Prefer providerSessionId if it folds; else the card key (used as agent_id).
        let primaryId = candidate.session.providerSessionId ?? candidate.sessionId
        let parentFromPrimary = CursorSessionFolding.foldTarget(
            childSessionId: primaryId,
            transcriptPath: candidate.session.transcriptPath
        )
        let parentFromCard = candidate.sessionId == primaryId
            ? nil
            : CursorSessionFolding.foldTarget(
                childSessionId: candidate.sessionId,
                transcriptPath: candidate.session.transcriptPath
            )
        if let parentFromPrimary {
            return (parentFromPrimary, primaryId)
        }
        if let parentFromCard {
            return (parentFromCard, candidate.sessionId)
        }
        return nil
    }

    /// Rebrand default-Claude cards that are actually Cursor Agent Tasks
    /// (`~/.cursor/.../agent-transcripts/.../subagents/<id>.jsonl`).
    @discardableResult
    func rebrandMisattributedCursorTaskCards() -> Bool {
        var didMutate = false
        for (sessionId, snap) in sessions {
            let normalized = SessionSnapshot.normalizedSupportedSource(snap.source)
            guard normalized == nil || normalized == "claude" else { continue }

            if let path = snap.transcriptPath,
               CursorSessionFolding.isCursorAgentTranscriptPath(path) {
                sessions[sessionId]?.source = "cursor"
                didMutate = true
                continue
            }

            guard let found = Self.findCursorSubagentTranscriptPath(
                sessionId: sessionId,
                cwd: snap.cwd
            ) else {
                continue
            }
            sessions[sessionId]?.source = "cursor"
            if sessions[sessionId]?.transcriptPath == nil {
                sessions[sessionId]?.transcriptPath = found
            }
            didMutate = true
        }
        return didMutate
    }

    /// Locate `…/agent-transcripts/<parent>/subagents/<sessionId>.jsonl` under
    /// `~/.cursor/projects`. Prefers the cwd-encoded project when available.
    nonisolated static func findCursorSubagentTranscriptPath(
        sessionId: String,
        cwd: String?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        fm: FileManager = .default
    ) -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let projectsRoot = "\(home)/.cursor/projects"

        var searchRoots: [String] = []
        if let cwd, !cwd.isEmpty {
            searchRoots.append("\(projectsRoot)/\(cwd.appProjectDirEncoded())/agent-transcripts")
        }
        // Prefer cwd project; fall back to scanning other Cursor projects.
        var found: String?
        for base in searchRoots {
            if let path = Self.firstSubagentTranscript(in: base, sessionId: trimmed, fm: fm) {
                found = path
                break
            }
        }
        if found == nil {
            if let projects = try? fm.contentsOfDirectory(atPath: projectsRoot) {
                for project in projects {
                    let base = "\(projectsRoot)/\(project)/agent-transcripts"
                    if searchRoots.contains(base) { continue }
                    if let path = Self.firstSubagentTranscript(in: base, sessionId: trimmed, fm: fm) {
                        found = path
                        break
                    }
                }
            }
        }
        return found
    }

    private nonisolated static func firstSubagentTranscript(
        in transcriptBase: String,
        sessionId: String,
        fm: FileManager
    ) -> String? {
        let suffix = "/subagents/\(sessionId).jsonl"
        guard let enumerator = fm.enumerator(atPath: transcriptBase) else { return nil }
        while let rel = enumerator.nextObject() as? String {
            if rel.hasSuffix(suffix) || rel == String(suffix.dropFirst()) {
                return "\(transcriptBase)/\(rel)"
            }
        }
        return nil
    }

    func applyCurrentPluginSessionMode(persist: Bool = true) {
        let mode = Self.currentPluginSessionMode()
        var didMutate = false

        switch mode {
        case "separate":
            didMutate = separateMergedCodexSubagents()
            didMutate = separateMergedCursorSubagents() || didMutate
        case "merge":
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = applyCursorSubsessionModeToKnownSessions() || didMutate
        case "hide":
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = hideMergedCodexSubagents() || didMutate
            didMutate = applyCursorSubsessionModeToKnownSessions() || didMutate
        default:
            return
        }

        if didMutate {
            if persist {
                scheduleSave()
                startRotationIfNeeded()
            }
            refreshDerivedState()
        }
    }

    @discardableResult
    private func separateMergedCodexSubagents() -> Bool {
        let parentCandidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        let childIds = Set(parentCandidates.flatMap { $0.session.subagents.keys })
        // One DB connection for the whole mode transition; never open SQLite
        // once per child (each open carries a busy timeout).
        let databaseRecords = Self.codexSpawnEdgeRecords(threadIds: childIds)
        var didMutate = false

        for parent in parentCandidates where parent.session.source == "codex" && !parent.session.subagents.isEmpty {
            for (agentId, subagent) in parent.session.subagents {
                let childIsDesktop = parent.session.termBundleId == Self.codexAppBundleId
                let childKey = findCodexParentSessionId(
                    providerSessionId: agentId,
                    childTermBundleId: parent.session.termBundleId
                ) ?? Self.codexDiscoveryIdentity(
                    rawSessionId: agentId,
                    isDesktop: childIsDesktop
                ).sessionId
                guard childKey != parent.sessionId else { continue }

                var child = sessions[childKey] ?? SessionSnapshot(startTime: subagent.startTime)
                child.source = "codex"
                child.providerSessionId = agentId
                child.cwd = child.cwd ?? parent.session.cwd
                child.model = child.model ?? parent.session.model
                child.permissionMode = child.permissionMode ?? parent.session.permissionMode
                child.termApp = child.termApp ?? parent.session.termApp
                child.itermSessionId = child.itermSessionId ?? parent.session.itermSessionId
                child.ttyPath = child.ttyPath ?? parent.session.ttyPath
                child.kittyWindowId = child.kittyWindowId ?? parent.session.kittyWindowId
                child.tmuxPane = child.tmuxPane ?? parent.session.tmuxPane
                child.tmuxClientTty = child.tmuxClientTty ?? parent.session.tmuxClientTty
                child.tmuxEnv = child.tmuxEnv ?? parent.session.tmuxEnv
                child.termBundleId = child.termBundleId ?? parent.session.termBundleId
                child.remoteHostId = child.remoteHostId ?? parent.session.remoteHostId
                child.remoteHostName = child.remoteHostName ?? parent.session.remoteHostName
                child.cliPid = child.cliPid ?? parent.session.cliPid
                child.cliStartTime = child.cliStartTime ?? parent.session.cliStartTime
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity

                let transcriptMetadata = child.transcriptPath.flatMap {
                    Self.codexSubagentMetadata(inTranscriptPath: $0)
                }
                let metadata = transcriptMetadata ?? databaseRecords[agentId]?.metadata
                if child.sessionTitle == nil {
                    child.sessionTitle = metadata?.agentNickname ?? subagent.toolDescription ?? subagent.agentType
                }
                if child.transcriptPath == nil {
                    if let statePath = databaseRecords[agentId]?.transcriptPath,
                       FileManager.default.fileExists(atPath: statePath) {
                        child.transcriptPath = statePath
                    } else if let cwd = parent.session.cwd {
                        let base = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".codex/sessions").path
                        child.transcriptPath = Self.findRecentCodexSession(
                            base: base,
                            cwd: cwd,
                            after: parent.session.cliStartTime,
                            fm: .default
                        )
                    }
                }
                if let transcriptPath = child.transcriptPath {
                    let (model, messages) = Self.readRecentFromCodexTranscript(path: transcriptPath)
                    child.model = child.model ?? model
                    if !messages.isEmpty {
                        child.recentMessages = messages
                        child.lastUserPrompt = messages.last(where: \.isUser)?.text
                        child.lastAssistantMessage = messages.last(where: { !$0.isUser })?.text
                    }
                }

                sessions[childKey] = child
                refreshProviderTitle(for: childKey, providerSessionId: agentId)
                attachTranscriptTailerIfNeeded(sessionId: childKey)
                tryMonitorSession(childKey)
                sessions[parent.sessionId]?.subagents.removeValue(forKey: agentId)
                if subagent.status != .idle {
                    activeSessionId = childKey
                }
                didMutate = true
            }
            if sessions[parent.sessionId]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parent.sessionId)
            }
        }

        return didMutate
    }

    @discardableResult
    private func hideMergedCodexSubagents() -> Bool {
        var didMutate = false
        for (sessionId, session) in sessions where session.source == "codex" && !session.subagents.isEmpty {
            sessions[sessionId]?.subagents.removeAll()
            clearSubagentProjection(fromParentSession: sessionId)
            didMutate = true
        }
        return didMutate
    }

    /// Split Cursor parent.subagents into standalone cards (Agent Sub-Sessions: separate).
    @discardableResult
    private func separateMergedCursorSubagents() -> Bool {
        let parentCandidates = sessions.map { (sessionId: $0.key, session: $0.value) }
        var didMutate = false

        for parent in parentCandidates
        where (parent.session.source == "cursor" || parent.session.source == "cursor-cli")
            && !parent.session.subagents.isEmpty {
            for (agentId, subagent) in parent.session.subagents {
                let childKey = findSessionId(providerSessionId: agentId) ?? agentId
                guard childKey != parent.sessionId else { continue }

                var child = sessions[childKey] ?? SessionSnapshot(startTime: subagent.startTime)
                child.source = parent.session.source
                child.providerSessionId = agentId
                child.cwd = child.cwd ?? parent.session.cwd
                child.model = child.model ?? parent.session.model
                child.permissionMode = child.permissionMode ?? parent.session.permissionMode
                child.termApp = child.termApp ?? parent.session.termApp
                child.itermSessionId = child.itermSessionId ?? parent.session.itermSessionId
                child.ttyPath = child.ttyPath ?? parent.session.ttyPath
                child.kittyWindowId = child.kittyWindowId ?? parent.session.kittyWindowId
                child.tmuxPane = child.tmuxPane ?? parent.session.tmuxPane
                child.tmuxClientTty = child.tmuxClientTty ?? parent.session.tmuxClientTty
                child.tmuxEnv = child.tmuxEnv ?? parent.session.tmuxEnv
                child.termBundleId = child.termBundleId ?? parent.session.termBundleId
                child.cmuxSurfaceId = child.cmuxSurfaceId ?? parent.session.cmuxSurfaceId
                child.cmuxWorkspaceId = child.cmuxWorkspaceId ?? parent.session.cmuxWorkspaceId
                child.zellijPaneId = child.zellijPaneId ?? parent.session.zellijPaneId
                child.zellijSessionName = child.zellijSessionName ?? parent.session.zellijSessionName
                child.weztermPaneId = child.weztermPaneId ?? parent.session.weztermPaneId
                child.remoteHostId = child.remoteHostId ?? parent.session.remoteHostId
                child.remoteHostName = child.remoteHostName ?? parent.session.remoteHostName
                // Keep the child's own process identity only — the parent Cursor chat
                // often shares the IDE process, which must not be attributed to Tasks.
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity
                if child.sessionTitle == nil {
                    child.sessionTitle = subagent.toolDescription ?? subagent.agentType
                }
                // Keep parent transcriptPath for later fold identity, but do not
                // attach a second JSONLTailer on the same parent file (steals the
                // parent's live tail). Prefer a child-specific path when present.
                let parentTranscript = parent.session.transcriptPath
                if child.transcriptPath == nil {
                    child.transcriptPath = parentTranscript
                }
                let shouldTailChildTranscript =
                    child.transcriptPath != nil && child.transcriptPath != parentTranscript

                sessions[childKey] = child
                refreshProviderTitle(for: childKey, providerSessionId: agentId)
                if shouldTailChildTranscript {
                    attachTranscriptTailerIfNeeded(sessionId: childKey)
                }
                if child.cliPid != nil {
                    tryMonitorSession(childKey)
                }
                sessions[parent.sessionId]?.subagents.removeValue(forKey: agentId)
                if subagent.status != .idle {
                    activeSessionId = childKey
                }
                didMutate = true
            }
            if sessions[parent.sessionId]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parent.sessionId)
            }
        }

        return didMutate
    }

    /// Clear Cursor parent.subagents (Agent Sub-Sessions: hide).
    @discardableResult
    private func hideMergedCursorSubagents() -> Bool {
        var didMutate = false
        for (sessionId, session) in sessions
        where (session.source == "cursor" || session.source == "cursor-cli") && !session.subagents.isEmpty {
            sessions[sessionId]?.subagents.removeAll()
            clearSubagentProjection(fromParentSession: sessionId)
            didMutate = true
        }
        return didMutate
    }

    private func clearSubagentProjection(fromParentSession sessionId: String) {
        guard sessions[sessionId]?.currentTool == "Agent" else { return }
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.toolDescription = nil
        if sessions[sessionId]?.status == .running {
            sessions[sessionId]?.status = .processing
        }
    }

    private func routeDiscoveredSubsessionIfNeeded(_ info: DiscoveredSession) -> Bool {
        guard info.source == "codex",
              let parentSessionId = info.parentSessionId,
              !parentSessionId.isEmpty else {
            return false
        }

        let mode = Self.currentPluginSessionMode()
        guard mode == "hide" || mode == "merge" else {
            return false
        }

        if mode == "hide" {
            if sessions[info.sessionId] != nil {
                removeSession(info.sessionId)
            }
            return true
        }

        guard let parentKey = findCodexParentSessionId(
            providerSessionId: parentSessionId,
            childTermBundleId: info.termBundleId
        ) else {
            return false
        }

        if sessions[info.sessionId] != nil {
            removeSession(info.sessionId)
        }

        let providerSessionId = info.providerSessionId ?? info.sessionId

        if info.subagentStatus?.lowercased() == "closed" || info.status == .idle {
            if sessions[parentKey]?.subagents.removeValue(forKey: providerSessionId) != nil,
               sessions[parentKey]?.subagents.isEmpty == true {
                clearSubagentProjection(fromParentSession: parentKey)
            }
            return true
        }

        let agentType = info.agentType ?? info.agentNickname ?? "Agent"
        var subagent = sessions[parentKey]?.subagents[providerSessionId]
            ?? SubagentState(agentId: providerSessionId, agentType: agentType)
        subagent.status = .running
        subagent.toolDescription = info.agentNickname
        subagent.lastActivity = info.modifiedAt
        sessions[parentKey]?.subagents[providerSessionId] = subagent

        if sessions[parentKey]?.status != .waitingApproval && sessions[parentKey]?.status != .waitingQuestion {
            sessions[parentKey]?.status = .running
            sessions[parentKey]?.currentTool = "Agent"
            sessions[parentKey]?.toolDescription = info.agentNickname ?? agentType
        }
        // Read before the assignment: writing `sessions[...]` while the RHS also
        // reads it overlaps a modify with a read access and traps at runtime.
        let previousParentActivity = sessions[parentKey]?.lastActivity ?? .distantPast
        sessions[parentKey]?.lastActivity = max(previousParentActivity, info.modifiedAt)
        activeSessionId = parentKey
        return true
    }

    func stopSessionDiscovery() {
        tearDownProjectsWatcher()
        rotationTimer?.invalidate()
        rotationTimer = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        discoveryScanTask?.cancel()
        discoveryScanTask = nil
        pendingDiscoveryRescan = false
        codexDesktopDiscoveryScanTask?.cancel()
        codexDesktopDiscoveryScanTask = nil
        lastCodexDesktopDiscoveryPollAt = nil
        for key in Array(processMonitors.keys) { stopMonitor(key) }
    }

    /// Stops the FSEvents watcher on the main queue so Stop/Invalidate cannot
    /// race a queued callback. Safe to call from `deinit` (any thread).
    nonisolated private func tearDownProjectsWatcher() {
        let run = { [self] in tearDownProjectsWatcherAssumingMain() }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.sync(execute: run)
        }
    }

    /// FSEvents teardown; caller must already be on the main queue.
    nonisolated private func tearDownProjectsWatcherAssumingMain() {
        // Flip cancel before stopping so any already-queued callback no-ops
        // instead of touching a dying AppState / freed box.
        projectsWatcherBox?.cancel()
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }
        let box = projectsWatcherBox
        projectsWatcherBox = nil
        // Keep the box alive until after previously queued main-queue
        // callbacks drain (Invalidate does not flush them).
        if let box {
            DispatchQueue.main.async { _ = box }
        }
    }

    deinit {
        // Must not use MainActor.assumeIsolated: async callers (notably XCTest)
        // can release AppState off the main actor via ARC. Weak-boxed FSEvents
        // + main-synced Timer/FSEvents teardown keep discovery crash-free.
        tearDownMainThreadResources()
        discoveryScanTask?.cancel()
        codexDesktopDiscoveryScanTask?.cancel()
        codexAppServerReconnectTask?.cancel()
        for (_, monitor) in processMonitors {
            monitor.source.cancel()
        }
    }

    /// Invalidates main-run-loop Timers and the FSEvents watcher in one main-queue
    /// hop. Safe from any thread so `deinit` stays uniformly main-safe.
    nonisolated private func tearDownMainThreadResources() {
        let teardown = { [self] in
            rotationTimer?.invalidate()
            rotationTimer = nil
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            saveTimer?.invalidate()
            saveTimer = nil
            tearDownProjectsWatcherAssumingMain()
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }

    struct DiscoveredSession {
        let sessionId: String
        let cwd: String
        let tty: String?
        let model: String?
        let pid: pid_t?
        let modifiedAt: Date
        let recentMessages: [ChatMessage]
        var source: String = "claude"
        /// Absolute path to the JSONL transcript this session was discovered from.
        /// When non-nil and the session is still live, AppState registers a JSONLTailer
        /// so incremental assistant appends reach the UI without another full scan.
        var transcriptPath: String? = nil
        var parentSessionId: String? = nil
        var subagentStatus: String? = nil
        var agentType: String? = nil
        var agentNickname: String? = nil
        /// Optional status inferred by a provider-specific discovery path.
        var status: AgentStatus? = nil
        /// Native host bundle when discovery represents an app session.
        var termBundleId: String? = nil
        /// Provider's raw thread ID when the tracking key uses a namespace prefix.
        var providerSessionId: String? = nil
    }

    /// Find running `claude` processes, match to transcript files, extract recent messages
    private nonisolated static func findActiveClaudeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        // Step 1: find running claude processes using native APIs
        let claudePids = findClaudePids(candidatePids: candidatePids)
        guard !claudePids.isEmpty else { return [] }

        let fm = FileManager.default
        let claudeProjects = ClaudeConfigPaths.projectsDir()
        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        // Each claude process → its CWD → the single most recent .jsonl
        for pid in claudePids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty else { continue }

            // Skip subagent worktrees — they are child tasks, not independent sessions
            if cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
                continue
            }

            // Get process start time to filter stale transcript files
            let processStart = getProcessStartTime(pid)

            let projectDir = cwd.claudeProjectDirEncoded()
            let projectPath = "\(claudeProjects)/\(projectDir)"
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            // Find the most recently modified .jsonl that was written AFTER this process started
            var bestFile: String?
            var bestDate = Date.distantPast
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = "\(projectPath)/\(file)"
                if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified > bestDate {
                    // Skip files from old sessions: must be modified after process started
                    if let start = processStart, modified < start.addingTimeInterval(-10) {
                        continue
                    }
                    bestDate = modified
                    bestFile = file
                }
            }

            guard let file = bestFile else { continue }

            // Skip stale transcripts: only show sessions active within last 5 minutes.
            // When processStart is unknown (proc_pidinfo failed), use a tighter 30s window
            // to avoid resurrecting zombie sessions from stale transcript files.
            let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if bestDate.timeIntervalSinceNow < freshnessLimit { continue }

            let sessionId = String(file.dropLast(6))
            guard !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let fullPath = "\(projectPath)/\(file)"
            let (model, messages) = readRecentFromTranscript(path: fullPath)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: bestDate,
                recentMessages: messages,
                transcriptPath: fullPath
            ))
        }
        return results
    }

    private nonisolated static func allProcessIds() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    private nonisolated static func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard len > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    private nonisolated static func findPids(
        matchingPathSubstrings pathSubstrings: [String],
        argSubstrings: [String] = [],
        candidatePids: [pid_t]? = nil
    ) -> [pid_t] {
        let loweredPaths = pathSubstrings.map { $0.lowercased() }
        let loweredArgs = argSubstrings.map { $0.lowercased() }
        guard !loweredPaths.isEmpty || !loweredArgs.isEmpty else { return [] }

        var matched: [pid_t] = []
        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid)?.lowercased() else { continue }
            if loweredPaths.contains(where: { path.contains($0) }) {
                matched.append(pid)
                continue
            }
            guard !loweredArgs.isEmpty,
                  let args = getProcessArgs(pid)?.map({ $0.lowercased() }) else { continue }
            if args.contains(where: { arg in loweredArgs.contains(where: { arg.contains($0) }) }) {
                matched.append(pid)
            }
        }
        return matched
    }

    /// Get PIDs of running Claude Code processes
    /// Claude's binary is named by version (e.g. "2.1.91") under ~/.local/share/claude/versions/
    private nonisolated static func findClaudePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        let claudeVersionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/claude/versions").path

        var claudePids: [pid_t] = []

        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid) else { continue }
            // Match processes whose executable is under claude's versions directory
            if path.hasPrefix(claudeVersionsDir) {
                claudePids.append(pid)
            }
        }
        return claudePids
    }

    private nonisolated static func findGeminiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [],
            argSubstrings: [
                "/gemini-cli/bundle/gemini.js",
                "/opt/homebrew/bin/gemini",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findCursorPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/cursor.app/contents/macos/cursor",
                "/cursor.app/contents/frameworks/cursor helper",
                "/.local/share/cursor-agent/versions/",
            ],
            argSubstrings: ["/cursor-agent/index.js"],
            candidatePids: candidatePids
        )
    }

    /// Standalone Cursor CLI agent — must not match the desktop IDE/helper
    /// processes that `findCursorPids` also covers (#248).
    private nonisolated static func findCursorCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/share/cursor-agent/versions/",
            ],
            argSubstrings: ["/cursor-agent/index.js"],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findQoderPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/qoder.app/contents/macos/electron",
                "/qoder.app/contents/frameworks/qoder helper",
                "/.qoder/bin/qodercli/",
            ],
            candidatePids: candidatePids
        )
    }

    /// Standalone Qoder CLI — must not match the desktop IDE/helper (#248).
    /// Both Qoder CLI builds: the international `qodercli` under ~/.qoder and the
    /// China build `qoderclicn` under ~/.qoder-cn. Same hook contract, one source
    /// (#289) — the CN binary is a separate build, so its own paths are needed.
    private nonisolated static func findQoderCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.qoder/bin/qodercli/",
                "/@qoder-ai/qodercli",
                "/.qoder-cn/bin/qoderclicn/",
                "/@qoder-ai/qoderclicn",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/qodercli",
                "/usr/local/bin/qodercli",
                "/.local/bin/qodercli",
                "/opt/homebrew/bin/qoderclicn",
                "/usr/local/bin/qoderclicn",
                "/.local/bin/qoderclicn",
            ],
            candidatePids: candidatePids
        )
    }

    /// QoderWork desktop app (#249). Bundle layout is assumed from the standard
    /// /Applications/QoderWork.app install — no public bundle id / binary name
    /// docs, pending real-install verification. "/qoderwork.app/" never collides
    /// with the IDE's "/qoder.app/" substrings.
    private nonisolated static func findQoderWorkPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/qoderwork.app/contents/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findFactoryPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/factory.app/contents/macos/electron",
                "/factory.app/contents/frameworks/factory helper",
                "/.local/bin/droid",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findCodeBuddyPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/codebuddy.app/contents/macos/electron",
                "/codebuddy.app/contents/frameworks/codebuddy helper",
            ],
            argSubstrings: [
                "/@tencent-ai/codebuddy-code/bin/codebuddy",
                "/opt/homebrew/bin/codebuddy",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findCodyBuddyCNPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/codebuddycn.app/contents/macos/electron",
                "/codebuddycn.app/contents/frameworks/codebuddycn helper",
                "/.codybuddycn/",
                "/.codebuddycn/",
            ],
            argSubstrings: [
                "/.codybuddycn/",
                "/.codebuddycn/",
                "/opt/homebrew/bin/codybuddycn",
                "/opt/homebrew/bin/codebuddycn",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findStepFunPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/stepfun.app/contents/macos/stepfun",
                "/.stepfun/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/stepfun",
                "/.stepfun/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findTraePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/trae.app/contents/macos/trae",
                "/trae.app/contents/frameworks/trae helper",
                "/.trae/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/trae",
                "/.trae/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findTraeCNPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/traecn.app/contents/macos/trae",
                "/trae-cn.app/contents/macos/trae",
                "/.traecn/",
                "/.trae-cn/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/traecn",
                "/opt/homebrew/bin/trae-cn",
                "/.traecn/",
                "/.trae-cn/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findTraeCliPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opt/homebrew/bin/coco",
                "/opt/homebrew/bin/traecli",
                "/usr/local/bin/coco",
                "/usr/local/bin/traecli",
                "/.local/bin/coco",
                "/.local/bin/traecli",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/coco",
                "/opt/homebrew/bin/traecli",
                "/usr/local/bin/coco",
                "/usr/local/bin/traecli",
                "/.local/bin/coco",
                "/.local/bin/traecli",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findAntiGravityPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.antigravity/antigravity/bin/antigravity",
                "/antigravity.app/contents/macos/antigravity",
            ],
            argSubstrings: [
                "/.antigravity/antigravity/bin/antigravity",
            ],
            candidatePids: candidatePids
        )
    }

    /// Google Antigravity (Gemini-based IDE/CLI, #215). The actionable agent is the
    /// `agy` CLI (pypi google-antigravity) launched from the IDE's integrated
    /// terminal; the IDE itself is Antigravity.app (com.google.antigravity).
    /// We match the IDE app *only* via the Google-specific .app path component to
    /// avoid colliding with the existing "antigravity" Claude-fork CLI (which lives
    /// under ~/.antigravity, never in an .app named exactly "antigravity").
    private nonisolated static func findGoogleAntigravityPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/antigravity.app/contents/macos/",
                "/bin/agy",
            ],
            argSubstrings: [
                "/google-antigravity/",
                "/antigravity-cli/",
                "/bin/agy",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findWorkBuddyPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/workbuddy.app/contents/macos/workbuddy",
                "/.workbuddy/",
            ],
            argSubstrings: [
                "/opt/homebrew/bin/workbuddy",
                "/.workbuddy/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findHermesPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/hermes",
                "/hermes.app/contents/macos/hermes",
                "/.hermes/hermes-agent/",
            ],
            argSubstrings: [
                "/.local/bin/hermes",
                "/.hermes/",
            ],
            candidatePids: candidatePids
        )
    }

    // Electron app (.dmg distribution) — packaged executable path unverified
    // on a real machine; best-effort guess pending field report (#245).
    private nonisolated static func findZcodePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/zcode.app/contents/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findQwenPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.local/bin/qwen",
                "/.bun/bin/qwen",
            ],
            argSubstrings: [
                "/@qwen-code/qwen-code/",
                "/.qwen/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findKimiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/.kimi-code/bin/kimi",
                "/.local/bin/kimi",
                "/.local/share/uv/tools/kimi-cli/",
            ],
            argSubstrings: [
                "/kimi-cli/",
                "kimi_cli",
                "/.kimi-code/",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findGrokPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        (candidatePids ?? allProcessIds()).filter { pid in
            guard let path = executablePath(for: pid) else { return false }
            return CLIProcessResolver.sourceMatchesExecutablePath(path, source: "grok")
        }
    }

    private nonisolated static func findPiPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/pi-coding-agent/",
                "/.local/bin/pi",
                "/.local/bin/omp",
                "/bin/pi",
                "/bin/omp",
            ],
            argSubstrings: [
                "pi-coding-agent",
                "/.local/bin/omp",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func md5Hash(of string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func findActiveKimiSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let kimiPids = findKimiPids(candidatePids: candidatePids)
        guard !kimiPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        // Legacy kimi-cli hashes cwd under sessions/; kimi-code may only need
        // session_index.jsonl, so do not bail when these dirs are absent.
        let sessionsBases = ["\(home)/.kimi-code/sessions", "\(home)/.kimi/sessions"]
            .filter { fm.fileExists(atPath: $0) }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in kimiPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)

            // Prefer kimi-code session_index.jsonl (workDir → sessionDir mapping).
            if let indexed = discoverKimiCodeSessionFromIndex(
                home: home,
                cwd: cwd,
                pid: pid,
                processStart: processStart,
                fm: fm
            ), !seenSessionIds.contains(indexed.sessionId) {
                seenSessionIds.insert(indexed.sessionId)
                results.append(indexed)
                continue
            }

            // Legacy kimi-cli: ~/.kimi/sessions/<md5(cwd)>/<sessionId>/wire.jsonl
            let workdirHash = md5Hash(of: cwd)
            for sessionsBase in sessionsBases {
                let workdirPath = "\(sessionsBase)/\(workdirHash)"
                guard fm.fileExists(atPath: workdirPath),
                      let sessionDirs = try? fm.contentsOfDirectory(atPath: workdirPath) else { continue }

                var bestPath: String?
                var bestDate = Date.distantPast
                var bestSessionId: String?

                for sessionId in sessionDirs {
                    let wirePath = "\(workdirPath)/\(sessionId)/wire.jsonl"
                    guard fm.fileExists(atPath: wirePath),
                          let attrs = try? fm.attributesOfItem(atPath: wirePath),
                          let modified = attrs[.modificationDate] as? Date,
                          modified > bestDate else { continue }
                    if let start = processStart, modified < start.addingTimeInterval(-10) {
                        continue
                    }
                    bestPath = wirePath
                    bestDate = modified
                    bestSessionId = sessionId
                }

                guard let path = bestPath, let sessionId = bestSessionId else { continue }
                let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
                if bestDate.timeIntervalSinceNow < freshnessLimit { continue }

                let (_, messages) = readRecentFromKimiTranscript(path: path)
                guard !seenSessionIds.contains(sessionId) else { continue }
                seenSessionIds.insert(sessionId)

                results.append(DiscoveredSession(
                    sessionId: sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: nil,
                    pid: pid,
                    modifiedAt: bestDate,
                    recentMessages: messages,
                    source: "kimi"
                ))
                break
            }
        }

        return results
    }

    /// kimi-code tracks sessions in `~/.kimi-code/session_index.jsonl` with
    /// `{ sessionId, sessionDir, workDir }` — workdir folders are no longer md5(cwd).
    /// `home` is the user home directory (fixture-injectable for tests).
    private nonisolated static func discoverKimiCodeSessionFromIndex(
        home: String,
        cwd: String,
        pid: pid_t,
        processStart: Date?,
        fm: FileManager
    ) -> DiscoveredSession? {
        let indexPath = "\(home)/.kimi-code/session_index.jsonl"
        guard fm.fileExists(atPath: indexPath),
              let data = fm.contents(atPath: indexPath),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var best: (sessionId: String, sessionDir: String, modified: Date)?
        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let workDir = json["workDir"] as? String,
                  workDir == cwd,
                  let sessionId = json["sessionId"] as? String,
                  let sessionDir = json["sessionDir"] as? String
            else { continue }

            let statePath = "\(sessionDir)/state.json"
            let stampPath = fm.fileExists(atPath: statePath) ? statePath : sessionDir
            guard let attrs = try? fm.attributesOfItem(atPath: stampPath),
                  let modified = attrs[.modificationDate] as? Date else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            if best == nil || modified > best!.modified {
                best = (sessionId, sessionDir, modified)
            }
        }

        guard let match = best else { return nil }
        let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
        if match.modified.timeIntervalSinceNow < freshnessLimit { return nil }

        // kimi-code keeps the transcript under agents/main/wire.jsonl.
        let wirePath = "\(match.sessionDir)/agents/main/wire.jsonl"
        let messages: [ChatMessage]
        if fm.fileExists(atPath: wirePath) {
            messages = readRecentFromKimiTranscript(path: wirePath).1
        } else {
            messages = []
        }

        return DiscoveredSession(
            sessionId: match.sessionId,
            cwd: cwd,
            tty: nil,
            model: nil,
            pid: pid,
            modifiedAt: match.modified,
            recentMessages: messages,
            source: "kimi"
        )
    }

    /// Test seam for ``discoverKimiCodeSessionFromIndex`` without exposing
    /// private ``DiscoveredSession``.
    internal nonisolated static func discoverKimiCodeSessionFromIndexForTesting(
        home: String,
        cwd: String,
        pid: pid_t,
        processStart: Date?,
        fm: FileManager
    ) -> (sessionId: String, cwd: String, pid: pid_t?, source: String, messageTexts: [String])? {
        guard let match = discoverKimiCodeSessionFromIndex(
            home: home,
            cwd: cwd,
            pid: pid,
            processStart: processStart,
            fm: fm
        ) else { return nil }
        return (
            match.sessionId,
            match.cwd,
            match.pid,
            match.source,
            match.recentMessages.map(\.text)
        )
    }

    /// Parse recent chat turns from a Kimi wire.jsonl transcript.
    /// Supports legacy kimi-cli (`message.type = TurnBegin|ContentPart|TurnEnd`)
    /// and kimi-code (`turn.prompt` / `context.append_message` / `content.part`).
    internal nonisolated static func readRecentFromKimiTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 262_144)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var messages: [ChatMessage] = []
        var previousUserText: String?
        var previousAssistantText: String = ""
        /// True when the current open turn was started by `context.append_message`
        /// rather than `turn.prompt` — used so a later `turn.prompt` can replace
        /// the user text without flushing a duplicate line.
        var turnOpenedByAppend = false

        func flushTurn() {
            if let userText = previousUserText, !userText.isEmpty {
                messages.append(ChatMessage(isUser: true, text: userText))
                if !previousAssistantText.isEmpty {
                    messages.append(ChatMessage(isUser: false, text: previousAssistantText))
                }
            }
            previousUserText = nil
            previousAssistantText = ""
            turnOpenedByAppend = false
        }

        func textParts(from value: Any?) -> String {
            let parts: [[String: Any]]
            if let typed = value as? [[String: Any]] {
                parts = typed
            } else if let anyParts = value as? [Any] {
                parts = anyParts.compactMap { $0 as? [String: Any] }
            } else {
                return ""
            }
            return parts.compactMap { part -> String? in
                if let type = part["type"] as? String, type != "text" { return nil }
                return part["text"] as? String
            }.joined()
        }

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            // Legacy kimi-cli envelope: { "message": { "type": "TurnBegin"|... } }
            if let message = json["message"] as? [String: Any],
               let type = message["type"] as? String {
                switch type {
                case "TurnBegin":
                    flushTurn()
                    if let payload = message["payload"] as? [String: Any] {
                        previousUserText = textParts(from: payload["user_input"])
                    }
                case "ContentPart":
                    if let payload = message["payload"] as? [String: Any],
                       payload["type"] as? String == "text",
                       let textContent = payload["text"] as? String {
                        previousAssistantText += textContent
                    }
                case "TurnEnd":
                    flushTurn()
                default:
                    break
                }
                continue
            }

            // kimi-code wire protocol (v1.4+).
            // Observed order: turn.prompt opens a turn, then optional
            // context.append_message (same user text), then content.part replies.
            // Prefer turn.prompt when both exist. If append_message arrives first
            // (defensive), mark the turn so the later turn.prompt replaces the
            // user text instead of flushing a duplicate user line.
            switch json["type"] as? String {
            case "turn.prompt":
                let promptText = textParts(from: json["input"])
                if turnOpenedByAppend && previousAssistantText.isEmpty {
                    // Replace append-opened user text only when turn.prompt has
                    // content; an empty prompt must not wipe the append line.
                    if !promptText.isEmpty {
                        previousUserText = promptText
                    }
                } else {
                    flushTurn()
                    previousUserText = promptText
                }
                turnOpenedByAppend = false
            case "context.append_message":
                if let message = json["message"] as? [String: Any],
                   message["role"] as? String == "user" {
                    let userText = textParts(from: message["content"])
                    if !userText.isEmpty {
                        // Prefer turn.prompt when both exist for the same turn;
                        // only start a turn here if we don't already have one open.
                        if previousUserText == nil {
                            previousUserText = userText
                            turnOpenedByAppend = true
                        }
                    }
                }
            case "context.append_loop_event":
                if let event = json["event"] as? [String: Any],
                   event["type"] as? String == "content.part",
                   let part = event["part"] as? [String: Any],
                   part["type"] as? String == "text",
                   let textContent = part["text"] as? String {
                    previousAssistantText += textContent
                }
            default:
                break
            }
        }

        flushTurn()
        return (nil, Array(messages.suffix(3)))
    }

    /// Grok percent-encodes the full cwd into a single directory component,
    /// including `/` as `%2F` (for example `/Users/me` -> `%2FUsers%2Fme`).
    nonisolated static func grokEncodedCwd(_ cwd: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return cwd.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private struct GrokSessionCandidate {
        let sessionId: String
        let directory: String
        let model: String?
        let createdAt: Date?
        let activityAt: Date
    }

    /// Score a metadata session against a live Grok process. Grok's native
    /// hooks are authoritative once a turn starts; discovery is only a recovery
    /// path, so it must prefer missing a late `/new` over attaching a completed
    /// one-shot session to an unrelated long-lived process in the same cwd.
    nonisolated static func grokSessionProcessMatchScore(
        createdAt: Date?,
        activityAt: Date,
        processStart: Date?,
        now: Date = Date()
    ) -> TimeInterval? {
        guard let processStart else {
            let age = now.timeIntervalSince(activityAt)
            guard age >= -10, age <= 30 else { return nil }
            return 1_000 + max(age, 0)
        }

        guard activityAt >= processStart.addingTimeInterval(-10) else { return nil }

        if let createdAt {
            let creationDelta = createdAt.timeIntervalSince(processStart)
            if abs(creationDelta) <= 120 {
                return abs(creationDelta)
            }

            // A resumed session was created before this process. Accept it only
            // while its first recovered activity is still close to launch.
            if createdAt < processStart {
                let activityDelta = activityAt.timeIntervalSince(processStart)
                if activityDelta >= -10, activityDelta <= 120 {
                    return 300 + abs(activityDelta)
                }
            }
            return nil
        }

        let activityDelta = activityAt.timeIntervalSince(processStart)
        guard activityDelta >= -10, activityDelta <= 120 else { return nil }
        return 600 + abs(activityDelta)
    }

    /// Produce a one-to-one mapping for Grok processes that share a cwd. The
    /// newest viable session is assigned first and prefers its closest process
    /// start. An augmenting path may move an earlier assignment to its next-best
    /// process when that is required to keep another viable session visible.
    nonisolated static func matchGrokSessionsToProcesses(
        processes: [(pid: pid_t, startedAt: Date?)],
        sessions: [(id: String, createdAt: Date?, activityAt: Date)],
        now: Date = Date()
    ) -> [String: pid_t] {
        typealias Edge = (pid: pid_t, score: TimeInterval)
        let orderedSessions = sessions.sorted { lhs, rhs in
            if lhs.activityAt != rhs.activityAt {
                return lhs.activityAt > rhs.activityAt
            }
            return lhs.id < rhs.id
        }
        var edgesBySession: [String: [Edge]] = [:]

        for session in orderedSessions where edgesBySession[session.id] == nil {
            edgesBySession[session.id] = processes.compactMap { process in
                guard let score = grokSessionProcessMatchScore(
                    createdAt: session.createdAt,
                    activityAt: session.activityAt,
                    processStart: process.startedAt,
                    now: now
                ) else { return nil }
                return (process.pid, score)
            }.sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score < rhs.score
                }
                return lhs.pid < rhs.pid
            }
        }

        var sessionByPid: [pid_t: String] = [:]

        func assign(_ sessionId: String, visitedPids: inout Set<pid_t>) -> Bool {
            guard let edges = edgesBySession[sessionId] else { return false }

            // Preserve earlier (newer) choices when this session has an unused
            // viable PID of its own.
            if let freeEdge = edges.first(where: {
                !visitedPids.contains($0.pid) && sessionByPid[$0.pid] == nil
            }) {
                visitedPids.insert(freeEdge.pid)
                sessionByPid[freeEdge.pid] = sessionId
                return true
            }

            // Otherwise find an augmenting path: move the current owner to its
            // next-best PID, then claim the newly released one.
            for edge in edges where visitedPids.insert(edge.pid).inserted {
                guard let displacedSession = sessionByPid[edge.pid] else {
                    sessionByPid[edge.pid] = sessionId
                    return true
                }
                if assign(displacedSession, visitedPids: &visitedPids) {
                    sessionByPid[edge.pid] = sessionId
                    return true
                }
            }
            return false
        }

        var attemptedSessions: Set<String> = []
        for session in orderedSessions where attemptedSessions.insert(session.id).inserted {
            var visitedPids: Set<pid_t> = []
            _ = assign(session.id, visitedPids: &visitedPids)
        }

        return Dictionary(uniqueKeysWithValues: sessionByPid.map { ($0.value, $0.key) })
    }

    private nonisolated static func grokSessionCandidates(
        cwd: String,
        fm: FileManager = .default
    ) -> [GrokSessionCandidate] {
        guard let encodedCwd = grokEncodedCwd(cwd) else { return [] }
        let cwdDirectory = "\(ConfigInstaller.grokHome())/sessions/\(encodedCwd)"
        guard let sessionDirectories = try? fm.contentsOfDirectory(atPath: cwdDirectory) else { return [] }

        var candidates: [GrokSessionCandidate] = []
        for directoryName in sessionDirectories {
            let directory = "\(cwdDirectory)/\(directoryName)"
            let summaryPath = "\(directory)/summary.json"
            guard let data = fm.contents(atPath: summaryPath),
                  let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = summary["info"] as? [String: Any],
                  let summaryCwd = info["cwd"] as? String,
                  summaryCwd == cwd else { continue }

            let sessionId = (info["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? directoryName
            let createdAt = (summary["created_at"] as? String).flatMap(parseISO8601Timestamp)
            let timestamps = ["last_active_at", "updated_at", "created_at"]
                .compactMap { summary[$0] as? String }
                .compactMap(parseISO8601Timestamp)
            var activityAt = timestamps.max() ?? .distantPast

            // File mtimes catch a turn that has started writing events before
            // summary.json has been refreshed.
            for filename in ["summary.json", "events.jsonl", "updates.jsonl", "chat_history.jsonl"] {
                let path = "\(directory)/\(filename)"
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let modified = attrs[.modificationDate] as? Date,
                   modified > activityAt {
                    activityAt = modified
                }
            }

            candidates.append(GrokSessionCandidate(
                sessionId: sessionId,
                directory: directory,
                model: (summary["current_model_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: createdAt,
                activityAt: activityAt
            ))
        }
        return candidates
    }

    private nonisolated static func findRecentGrokSession(
        cwd: String,
        after processStart: Date?,
        fm: FileManager = .default
    ) -> GrokSessionCandidate? {
        grokSessionCandidates(cwd: cwd, fm: fm)
            .filter {
                grokSessionProcessMatchScore(
                    createdAt: $0.createdAt,
                    activityAt: $0.activityAt,
                    processStart: processStart
                ) != nil
            }
            .max { $0.activityAt < $1.activityAt }
    }

    private nonisolated static func findActiveGrokSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let grokPids = findGrokPids(candidatePids: candidatePids)
        guard !grokPids.isEmpty else { return [] }

        let fm = FileManager.default
        let liveProcesses = grokPids.compactMap { pid -> (pid: pid_t, cwd: String, startedAt: Date?)? in
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { return nil }
            return (pid, cwd, getProcessStartTime(pid))
        }
        let processGroups = Dictionary(grouping: liveProcesses) { $0.cwd }

        var results: [DiscoveredSession] = []
        for (cwd, processes) in processGroups {
            let candidates = grokSessionCandidates(cwd: cwd, fm: fm)
            let assignments = matchGrokSessionsToProcesses(
                processes: processes.map { ($0.pid, $0.startedAt) },
                sessions: candidates.map { ($0.sessionId, $0.createdAt, $0.activityAt) }
            )

            for candidate in candidates {
                guard let pid = assignments[candidate.sessionId] else { continue }
                let chatPath = "\(candidate.directory)/chat_history.jsonl"
                let hasChat = fm.fileExists(atPath: chatPath)
                let messages = hasChat ? readRecentFromTranscript(path: chatPath).1 : []
                results.append(DiscoveredSession(
                    sessionId: candidate.sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: candidate.model,
                    pid: pid,
                    modifiedAt: candidate.activityAt,
                    recentMessages: messages,
                    source: "grok",
                    transcriptPath: hasChat ? chatPath : nil
                ))
            }
        }
        return results
    }

    private nonisolated static func findCopilotPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [],
            argSubstrings: [
                "/@github/copilot/npm-loader.js",
                "/opt/homebrew/bin/copilot",
            ],
            candidatePids: candidatePids
        )
    }

    private nonisolated static func findClinePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        // Cline is a VSCode extension — it has no standalone CLI process.
        // Do NOT monitor VSCode main process as that causes crashes.
        // Session discovery still works via file-based scanning (taskHistory.json).
        return []
    }

    private nonisolated static func findOpenCodePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        findPids(
            matchingPathSubstrings: [
                "/opencode.app/contents/macos/opencode",
                "/opencode.app/contents/macos/opencode-cli",
                "/.opencode/bin/opencode",
            ],
            candidatePids: candidatePids
        )
    }

    /// Get the current working directory of a process using proc_pidinfo
    private nonisolated static func getCwd(for pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Get the start time of a process using proc_pidinfo
    private nonisolated static func getProcessStartTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    private nonisolated static func isSubagentWorktree(_ cwd: String) -> Bool {
        cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-")
    }

    private nonisolated static func findMostRecentJSONLFile(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    private nonisolated static func findFlatStoreSessions(
        pids: [pid_t],
        basePath: String,
        source: String,
        projectEncoder: (String) -> String,
        transcriptReader: (String) -> (String?, [ChatMessage])
    ) -> [DiscoveredSession] {
        guard !pids.isEmpty else { return [] }

        let fm = FileManager.default
        guard fm.fileExists(atPath: basePath) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in pids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            let projectPath = "\(basePath)/\(projectEncoder(cwd))"
            guard let best = findMostRecentJSONLFile(in: projectPath, after: processStart, fm: fm) else { continue }
            if best.modified.timeIntervalSinceNow < -300 { continue }

            let sessionId = ((best.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = transcriptReader(best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: source
            ))
        }

        return results
    }

    private nonisolated static func findActiveGeminiSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let geminiPids = findGeminiPids(candidatePids: candidatePids)
        guard !geminiPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let tmpBase = "\(home)/.gemini/tmp"
        guard fm.fileExists(atPath: tmpBase) else { return [] }

        let projects = readGeminiProjectsMap(path: "\(home)/.gemini/projects.json")
        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in geminiPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            guard let projectDir = findGeminiProjectDirectory(for: cwd, tmpBase: tmpBase, projects: projects, fm: fm) else {
                continue
            }

            let processStart = getProcessStartTime(pid)
            let chatsBase = "\(tmpBase)/\(projectDir)/chats"
            guard let best = findMostRecentGeminiSession(in: chatsBase, after: processStart, fm: fm) else { continue }
            let geminiFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if best.modified.timeIntervalSinceNow < geminiFreshnessLimit { continue }

            let (sessionId, model, messages) = readRecentFromGeminiTranscript(path: best.path)
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "gemini"
            ))
        }

        return results
    }

    private nonisolated static func readGeminiProjectsMap(path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return [:]
        }
        return projects
    }

    private nonisolated static func findGeminiProjectDirectory(
        for cwd: String,
        tmpBase: String,
        projects: [String: String],
        fm: FileManager
    ) -> String? {
        if let mapped = projects[cwd], fm.fileExists(atPath: "\(tmpBase)/\(mapped)") {
            return mapped
        }

        guard let dirs = try? fm.contentsOfDirectory(atPath: tmpBase) else { return nil }
        for dir in dirs {
            let projectRootPath = "\(tmpBase)/\(dir)/.project_root"
            guard let data = fm.contents(atPath: projectRootPath),
                  let root = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  root == cwd else { continue }
            return dir
        }
        return nil
    }

    private nonisolated static func findMostRecentGeminiSession(
        in directory: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate = Date.distantPast
        for file in files where file.hasPrefix("session-") && file.hasSuffix(".json") {
            let fullPath = "\(directory)/\(file)"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date,
                  modified > bestDate else { continue }
            if let start = processStart, modified < start.addingTimeInterval(-10) {
                continue
            }
            bestPath = fullPath
            bestDate = modified
        }

        guard let bestPath else { return nil }
        return (bestPath, bestDate)
    }

    private nonisolated static func readRecentFromGeminiTranscript(path: String) -> (String, String?, [ChatMessage]) {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (((path as NSString).lastPathComponent as NSString).deletingPathExtension, nil, [])
        }

        let sessionId = (json["sessionId"] as? String)
            ?? (((path as NSString).lastPathComponent as NSString).deletingPathExtension)
        let model = json["model"] as? String
        let messages = (json["messages"] as? [[String: Any]]) ?? []

        var combined: [(Int, ChatMessage)] = []
        for (index, message) in messages.enumerated() {
            let type = (message["type"] as? String)?.lowercased() ?? ""
            let text = extractTextContent(from: message["content"])
                ?? (message["content"] as? String)
            guard let text, !text.isEmpty else { continue }

            if type == "user" {
                combined.append((index, ChatMessage(isUser: true, text: text)))
            } else {
                combined.append((index, ChatMessage(isUser: false, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (sessionId, model, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func findActiveQoderSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: findQoderPids(candidatePids: candidatePids),
            basePath: "\(home)/.qoder/projects",
            source: "qoder",
            projectEncoder: { $0.claudeProjectDirEncoded() },
            transcriptReader: { readRecentFromTranscript(path: $0) }
        )
    }

    private nonisolated static func findActiveCodeBuddySessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: findCodeBuddyPids(candidatePids: candidatePids),
            basePath: "\(home)/.codebuddy/projects",
            source: "codebuddy",
            projectEncoder: { $0.appProjectDirEncoded() },
            transcriptReader: { readRecentFromCodeBuddyTranscript(path: $0) }
        )
    }

    private nonisolated static func findActiveFactorySessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return findFlatStoreSessions(
            pids: findFactoryPids(candidatePids: candidatePids),
            basePath: "\(home)/.factory/sessions",
            source: "droid",
            projectEncoder: { $0.claudeProjectDirEncoded() },
            transcriptReader: { readRecentFromFactoryTranscript(path: $0) }
        )
    }

    private nonisolated static func findActiveCursorSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let cursorPids = findCursorPids(candidatePids: candidatePids)
        guard !cursorPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let projectsBase = "\(home)/.cursor/projects"
        guard fm.fileExists(atPath: projectsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in cursorPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            let transcriptBase = "\(projectsBase)/\(cwd.appProjectDirEncoded())/agent-transcripts"
            guard let best = findMostRecentCursorTranscript(in: transcriptBase, after: processStart, fm: fm) else { continue }
            let cursorFreshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if best.modified.timeIntervalSinceNow < cursorFreshnessLimit { continue }

            let sessionId = ((best.path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromCursorTranscript(path: best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "cursor",
                transcriptPath: best.path
            ))
        }

        return results
    }

    private nonisolated static func findMostRecentCursorTranscript(
        in transcriptsBase: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let sessionDirs = try? fm.contentsOfDirectory(atPath: transcriptsBase) else { return nil }

        var best: (path: String, modified: Date)?
        for sessionDir in sessionDirs {
            let dirPath = "\(transcriptsBase)/\(sessionDir)"
            guard let candidate = findMostRecentJSONLFile(in: dirPath, after: processStart, fm: fm) else { continue }
            if best == nil || candidate.modified > best!.modified {
                best = candidate
            }
        }
        return best
    }

    private nonisolated static func findActiveCopilotSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let copilotPids = findCopilotPids(candidatePids: candidatePids)
        guard !copilotPids.isEmpty else { return [] }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let sessionsBase = "\(home)/.copilot/session-state"
        guard fm.fileExists(atPath: sessionsBase) else { return [] }

        var results: [DiscoveredSession] = []
        var seenSessionIds: Set<String> = []

        for pid in copilotPids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            guard let best = findRecentCopilotSession(base: sessionsBase, cwd: cwd, after: processStart, fm: fm) else {
                continue
            }
            if best.modified.timeIntervalSinceNow < -300 { continue }

            let sessionDir = (best.path as NSString).deletingLastPathComponent
            let sessionId = (sessionDir as NSString).lastPathComponent
            guard !sessionId.isEmpty, !seenSessionIds.contains(sessionId) else { continue }
            seenSessionIds.insert(sessionId)

            let (model, messages) = readRecentFromCopilotTranscript(path: best.path)
            results.append(DiscoveredSession(
                sessionId: sessionId,
                cwd: cwd,
                tty: nil,
                model: model,
                pid: pid,
                modifiedAt: best.modified,
                recentMessages: messages,
                source: "copilot"
            ))
        }

        return results
    }

    // MARK: - Cline (VSCode extension saoudrizwan.claude-dev)

    private nonisolated static func clineStorageRoot() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? ""
        return "\(appSupport)/Code/User/globalStorage/saoudrizwan.claude-dev"
    }

    private nonisolated static func findActiveClineSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let clineRoot = clineStorageRoot()
        let fm = FileManager.default
        let historyPath = "\(clineRoot)/state/taskHistory.json"
        guard fm.fileExists(atPath: historyPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: historyPath)),
              let history = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !history.isEmpty
        else { return [] }

        // Sort by ts descending, take the most recent task
        let sorted = history.sorted {
            ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0)
        }
        guard let latest = sorted.first,
              let taskId = latest["id"] as? String
        else { return [] }

        // Use the conversation file's mtime for freshness — more accurate than taskHistory ts.
        let conversationPath = "\(clineRoot)/tasks/\(taskId)/api_conversation_history.json"
        let fileDate: Date
        if let attrs = try? fm.attributesOfItem(atPath: conversationPath),
           let mtime = attrs[.modificationDate] as? Date {
            fileDate = mtime
        } else if let taskTs = latest["ts"] as? Double {
            fileDate = Date(timeIntervalSince1970: taskTs / 1000.0)
        } else {
            return []
        }

        // Cline has no process monitor — allow 10 min staleness
        let freshnessLimit: TimeInterval = -600
        guard fileDate.timeIntervalSinceNow > freshnessLimit else { return [] }

        let (model, messages) = readRecentFromClineHistory(
            path: conversationPath,
            modelFromHistory: latest["modelId"] as? String
        )

        let cwd = latest["cwdOnTaskInitialization"] as? String ?? ""
        // No PID for Cline — it's a VSCode extension, not a CLI process
        let pid: pid_t? = nil

        return [DiscoveredSession(
            sessionId: taskId,
            cwd: cwd,
            tty: nil,
            model: model,
            pid: pid,
            modifiedAt: fileDate,
            recentMessages: messages,
            source: "cline"
        )]
    }

    private nonisolated static func readRecentFromClineHistory(
        path: String,
        modelFromHistory: String?
    ) -> (String?, [ChatMessage]) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return (modelFromHistory, []) }

        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for entry in entries {
            guard let role = entry["role"] as? String,
                  let textContent = extractTextContent(from: entry["content"])
            else { continue }

            if role == "user" {
                userMessages.append((index, textContent))
            } else if role == "assistant" {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (modelFromHistory, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func findRecentCopilotSession(
        base: String,
        cwd: String,
        after processStart: Date?,
        fm: FileManager
    ) -> (path: String, modified: Date)? {
        guard let dirs = try? fm.contentsOfDirectory(atPath: base) else { return nil }

        let candidates = dirs.compactMap { dir -> (path: String, modified: Date)? in
            let fullPath = "\(base)/\(dir)/events.jsonl"
            guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                  let modified = attrs[.modificationDate] as? Date else { return nil }
            return (fullPath, modified)
        }.sorted { $0.modified > $1.modified }

        for candidate in candidates.prefix(50) {
            if let start = processStart, candidate.modified < start.addingTimeInterval(-10) {
                continue
            }
            if copilotSessionMatchesCwd(path: candidate.path, cwd: cwd) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func copilotSessionMatchesCwd(path: String, cwd: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 32768)
        guard let text = String(data: data, encoding: .utf8) else { return false }

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["data"] as? [String: Any] else { continue }

            if type == "session.start",
               let context = payload["context"] as? [String: Any],
               let sessionCwd = context["cwd"] as? String, sessionCwd == cwd {
                return true
            }

            if type == "hook.start",
               let input = payload["input"] as? [String: Any],
               let sessionCwd = input["cwd"] as? String, sessionCwd == cwd {
                return true
            }
        }
        return false
    }

    private nonisolated static func findActiveOpenCodeSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let openCodePids = findOpenCodePids(candidatePids: candidatePids)
        guard !openCodePids.isEmpty else { return [] }

        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return [] }

        return withSQLiteDatabase(at: dbPath) { db in
            var results: [DiscoveredSession] = []
            var seenSessionIds: Set<String> = []

            for pid in openCodePids {
                guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
                let processStart = getProcessStartTime(pid)
                guard let session = findRecentOpenCodeSession(in: db, cwd: cwd, after: processStart) else { continue }
                guard !seenSessionIds.contains(session.sessionId) else { continue }
                seenSessionIds.insert(session.sessionId)

                let (model, messages) = readRecentFromOpenCodeSession(db: db, sessionId: session.sessionId)
                results.append(DiscoveredSession(
                    sessionId: session.sessionId,
                    cwd: cwd,
                    tty: nil,
                    model: model,
                    pid: pid,
                    modifiedAt: session.modifiedAt,
                    recentMessages: messages,
                    source: "opencode"
                ))
            }

            return results
        } ?? []
    }

    private nonisolated static func withSQLiteDatabase<T>(
        at path: String,
        body: (OpaquePointer) -> T?
    ) -> T? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db else {
            if let db { sqlite3_close_v2(db) }
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        defer { sqlite3_close_v2(db) }
        return body(db)
    }

    private nonisolated static func prepareSQLiteStatement(db: OpaquePointer, sql: String) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private nonisolated static func sqliteTableColumns(
        db: OpaquePointer,
        tableName: String
    ) -> Set<String> {
        guard tableName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let statement = prepareSQLiteStatement(
                db: db,
                sql: "PRAGMA table_info(\(tableName));"
              ) else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqliteColumnString(statement, index: 1) {
                columns.insert(name)
            }
        }
        return columns
    }

    private nonisolated static func bindSQLiteText(_ text: String, to statement: OpaquePointer, index: Int32) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = text.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
    }

    private nonisolated static func sqliteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    private nonisolated static func findRecentOpenCodeSession(
        in db: OpaquePointer,
        cwd: String,
        after processStart: Date?
    ) -> (sessionId: String, modifiedAt: Date)? {
        let sql = """
            SELECT id, time_updated
            FROM session
            WHERE time_archived IS NULL
              AND (
                directory = ?
                OR EXISTS (
                    SELECT 1
                    FROM message m
                    WHERE m.session_id = session.id
                      AND json_extract(m.data, '$.path.cwd') = ?
                )
              )
            ORDER BY time_updated DESC
            LIMIT 20;
            """
        guard let statement = prepareSQLiteStatement(db: db, sql: sql) else { return nil }
        defer { sqlite3_finalize(statement) }

        bindSQLiteText(cwd, to: statement, index: 1)
        bindSQLiteText(cwd, to: statement, index: 2)

        let minUpdatedAtMs = processStart.map { Int64($0.timeIntervalSince1970 * 1000) - 10_000 }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionId = sqliteColumnString(statement, index: 0) else { continue }
            let updatedAtMs = sqlite3_column_int64(statement, 1)
            if let minUpdatedAtMs, updatedAtMs < minUpdatedAtMs { continue }
            let modifiedAt = Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000)
            return (sessionId, modifiedAt)
        }
        return nil
    }

    private nonisolated static func readRecentFromOpenCodeSession(
        db: OpaquePointer,
        sessionId: String
    ) -> (String?, [ChatMessage]) {
        var model: String?

        if let messageStatement = prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT data
                FROM message
                WHERE session_id = ?
                ORDER BY time_updated DESC
                LIMIT 12;
                """
        ) {
            defer { sqlite3_finalize(messageStatement) }
            bindSQLiteText(sessionId, to: messageStatement, index: 1)
            while sqlite3_step(messageStatement) == SQLITE_ROW {
                guard model == nil,
                      let data = sqliteColumnString(messageStatement, index: 0),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                model = json["modelID"] as? String
                if model == nil,
                   let modelInfo = json["model"] as? [String: Any] {
                    model = modelInfo["modelID"] as? String
                }
            }
        }

        var seenMessageIds: Set<String> = []
        var combined: [(Int64, ChatMessage)] = []
        if let partStatement = prepareSQLiteStatement(
            db: db,
            sql: """
                SELECT p.message_id, json_extract(m.data, '$.role'), p.time_created, p.data
                FROM part p
                JOIN message m ON m.id = p.message_id
                WHERE p.session_id = ?
                ORDER BY p.time_created DESC
                LIMIT 80;
                """
        ) {
            defer { sqlite3_finalize(partStatement) }
            bindSQLiteText(sessionId, to: partStatement, index: 1)
            while sqlite3_step(partStatement) == SQLITE_ROW {
                guard let messageId = sqliteColumnString(partStatement, index: 0),
                      !seenMessageIds.contains(messageId),
                      let role = sqliteColumnString(partStatement, index: 1),
                      let data = sqliteColumnString(partStatement, index: 3),
                      let jsonData = data.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      json["type"] as? String == "text",
                      let text = json["text"] as? String, !text.isEmpty else { continue }

                let isUser = role == "user"
                guard isUser || role == "assistant" else { continue }

                seenMessageIds.insert(messageId)
                combined.append((sqlite3_column_int64(partStatement, 2), ChatMessage(isUser: isUser, text: text)))
            }
        }

        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    // MARK: - Codex Session Discovery

    /// Find running Codex processes.
    /// Checks both executable path (Desktop app) and command-line args (npm/Homebrew: node script).
    nonisolated static func isCodexExecutablePath(_ path: String) -> Bool {
        let executableURL = URL(fileURLWithPath: path).standardizedFileURL
        let lowerPath = executableURL.path.lowercased()
        let resourceSuffix = "/contents/resources/codex"
        guard lowerPath.hasSuffix(resourceSuffix) else { return false }

        // Since Codex was folded into ChatGPT Desktop, the same com.openai.codex
        // bundle can now be installed as ChatGPT.app instead of Codex.app. Read
        // the bundle identifier first so future app renames continue to work.
        let appURL = executableURL
            .deletingLastPathComponent() // Resources
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // *.app
        if Bundle(url: appURL)?.bundleIdentifier == AppState.codexAppBundleId {
            return true
        }

        // Keep the legacy path check for synthetic/test bundles without an
        // Info.plist and for older installations whose bundle cannot be read.
        let appName = appURL.deletingPathExtension().lastPathComponent.lowercased()
        return appName == "codex" || appName == "chatgpt"
    }

    /// Codex Desktop's shared app-server is launched with `/` as its cwd. Its
    /// rollout metadata contains the project cwd, so desktop discovery must
    /// use that value instead of comparing every transcript to `/`.
    nonisolated static func codexDiscoveryUsesTranscriptCwd(processCwd: String?) -> Bool {
        guard let processCwd, !processCwd.isEmpty else { return true }
        return processCwd == "/"
    }

    /// Codex Desktop currently invokes some hooks without a payload, or with
    /// the shared app-server's root cwd. Those events contain no session data
    /// and would overwrite a session discovered from its rollout transcript.
    nonisolated static func isCodexPlaceholderHook(
        source: String?,
        cwd: String?,
        hasTranscriptPath: Bool
    ) -> Bool {
        guard source?.lowercased() == "codex", !hasTranscriptPath else { return false }
        return cwd == nil || cwd?.trimmingCharacters(in: .whitespacesAndNewlines) == "/"
    }

    /// Keep all three Codex Desktop discovery channels on one stable tracking
    /// key while leaving CLI sessions in the provider's raw namespace.
    nonisolated static func codexDiscoveryIdentity(
        rawSessionId: String,
        isDesktop: Bool
    ) -> CodexDiscoveryIdentity {
        if isDesktop {
            return CodexDiscoveryIdentity(
                sessionId: codexAppSessionPrefix + rawSessionId,
                providerSessionId: rawSessionId,
                termBundleId: codexAppBundleId
            )
        }
        return CodexDiscoveryIdentity(
            sessionId: rawSessionId,
            providerSessionId: nil,
            termBundleId: nil
        )
    }

    /// Upgrade pre-namespace persisted Desktop hook cards without touching raw
    /// Codex CLI ids. `termBundleId` is the reliable discriminator retained by
    /// #267-era snapshots.
    nonisolated static func canonicalRestoredCodexSessionId(
        sessionId: String,
        source: String,
        providerSessionId: String?,
        termBundleId: String?
    ) -> String {
        guard source == "codex", termBundleId == codexAppBundleId else {
            return sessionId
        }
        if sessionId.hasPrefix(codexAppSessionPrefix) {
            return sessionId
        }
        let rawId = providerSessionId?.isEmpty == false ? providerSessionId! : sessionId
        return codexAppSessionPrefix + rawId
    }

    /// Read only the rollout's first `session_meta` row to distinguish Desktop
    /// rollouts from CLI rollouts when both exist under `~/.codex/sessions`.
    /// Unknown future shapes remain eligible for the owning process as a
    /// best-effort fallback instead of being dropped.
    nonisolated static func codexTranscriptOrigin(path: String) -> CodexTranscriptOrigin {
        guard let firstLine = readFirstLine(path: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else {
            return .unknown
        }

        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let source = (payload["source"] as? String)?.lowercased() ?? ""
        if originator.contains("desktop") || source == "vscode" || source == "appserver" {
            return .desktop
        }
        if originator.contains("cli") || source == "cli" || source == "exec" {
            return .cli
        }
        return .unknown
    }

    private nonisolated static func findCodexPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        var codexPids: [pid_t] = []

        for pid in candidatePids ?? allProcessIds() {
            guard let path = executablePath(for: pid) else { continue }
            let pathLower = path.lowercased()

            // Match 1: Codex Desktop app (native binary). The executable may
            // live under Codex.app or ChatGPT.app depending on the release.
            if isCodexExecutablePath(path) {
                codexPids.append(pid)
                continue
            }

            // Match 2: npm/Homebrew install — node running @openai/codex script.
            // proc_pidpath returns the node binary, so check command-line args instead.
            if pathLower.hasSuffix("/node") {
                if let args = getProcessArgs(pid),
                   args.contains(where: { $0.contains("@openai/codex") || $0.contains("openai-codex") }) {
                    codexPids.append(pid)
                }
            }
        }
        return codexPids
    }

    /// Get command-line arguments for a process via sysctl KERN_PROCARGS2.
    private nonisolated static func getProcessArgs(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // First 4 bytes = argc (as int32)
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 256 else { return nil }

        // Skip past argc + executable path + padding nulls to reach argv
        var offset = MemoryLayout<Int32>.size
        // Skip executable path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip null padding
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Parse null-terminated argv strings
        var args: [String] = []
        var argStart = offset
        for _ in 0..<argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > argStart {
                args.append(String(bytes: buffer[argStart..<offset], encoding: .utf8) ?? "")
            }
            offset += 1
            argStart = offset
        }
        return args
    }

    /// Scan a rollout backwards in chunks until the latest lifecycle marker is
    /// found. This avoids both a full-file read and a fixed-tail limit while
    /// reusing `JSONLTailer`'s canonical Codex event interpretation.
    nonisolated static func latestCodexTurnStatus(
        path: String,
        chunkSize: UInt64 = 256 * 1024,
        maxBytesToScan: UInt64 = 64 * 1024 * 1024,
        maxLineBytes: Int = 4 * 1024 * 1024
    ) -> ConversationTurnStatus? {
        guard chunkSize > 0, maxBytesToScan > 0, maxLineBytes > 0 else { return nil }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let lowerBound = fileSize > maxBytesToScan ? fileSize - maxBytesToScan : 0
        var cursor = fileSize
        var leadingFragment = Data()
        var discardingOversizedLine = false

        while cursor > lowerBound {
            let readSize = min(cursor - lowerBound, chunkSize)
            cursor -= readSize
            handle.seek(toFileOffset: cursor)
            let chunk = handle.readData(ofLength: Int(readSize))
            var combined: Data
            if discardingOversizedLine {
                // We are walking backwards through one over-budget line. Drop
                // its bytes until the previous newline, then resume with older
                // complete lines instead of retaining/copying an unbounded blob.
                guard let newline = chunk.lastIndex(of: 0x0A) else { continue }
                combined = Data(chunk[...newline])
                discardingOversizedLine = false
            } else {
                combined = chunk
                combined.append(leadingFragment)
            }

            var lines: [Data] = []
            var lineStart = combined.startIndex
            for index in combined.indices where combined[index] == 0x0A {
                lines.append(Data(combined[lineStart..<index]))
                lineStart = combined.index(after: index)
            }
            lines.append(Data(combined[lineStart..<combined.endIndex]))
            if cursor > lowerBound, !lines.isEmpty {
                let fragment = lines.removeFirst()
                if fragment.count > maxLineBytes {
                    leadingFragment.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                } else {
                    leadingFragment = fragment
                }
            } else {
                leadingFragment.removeAll(keepingCapacity: true)
                // A capped scan begins in the middle of an unknown line. Never
                // parse that boundary fragment as if it were complete JSON.
                if lowerBound > 0, !lines.isEmpty {
                    lines.removeFirst()
                }
            }

            for line in lines.reversed()
            where !line.isEmpty && line.count <= maxLineBytes {
                if let status = codexTurnStatus(fromCompleteLine: line) {
                    return status
                }
            }
        }

        return nil
    }

    private nonisolated static func codexTurnStatus(fromCompleteLine line: Data) -> ConversationTurnStatus? {
        var newlineTerminated = line
        newlineTerminated.append(0x0A)
        return JSONLTailer.latestTurnStatus(in: newlineTerminated)
    }

    /// Load recently touched Codex Desktop threads from Codex's own state DB.
    /// Desktop app-server processes use `/` as CWD in current releases, making
    /// the process-to-project matcher insufficient on its own.
    nonisolated static func recentCodexDesktopThreadRecords(
        statePath overrideStatePath: String? = nil,
        now: Date = Date(),
        freshnessWindow: TimeInterval = 600,
        completionSettleWindow: TimeInterval = 30,
        fileManager: FileManager = .default
    ) -> [CodexDesktopThreadRecord] {
        let statePath = overrideStatePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path
        // `has_user_event` is not a reliable visibility bit for Desktop threads:
        // current ChatGPT/Codex builds may keep it at 0 while a user turn is
        // actively writing to the rollout. Pull a slightly wider DB candidate
        // window, then enforce the tighter freshness window from DB/file mtimes.
        let candidateWindow = max(freshnessWindow, 60 * 60)
        let cutoff = now.addingTimeInterval(-candidateWindow).timeIntervalSince1970

        return withSQLiteDatabase(at: statePath) { db in
            let columns = sqliteTableColumns(db: db, tableName: "threads")
            let requiredColumns: Set<String> = [
                "id", "rollout_path", "cwd", "archived", "source",
            ]
            guard requiredColumns.isSubset(of: columns) else { return [] }

            let updatedAtExpression: String
            if columns.contains("updated_at_ms"), columns.contains("updated_at") {
                updatedAtExpression = "COALESCE(NULLIF(updated_at_ms, 0) / 1000.0, updated_at)"
            } else if columns.contains("updated_at_ms") {
                updatedAtExpression = "updated_at_ms / 1000.0"
            } else if columns.contains("updated_at") {
                updatedAtExpression = "updated_at"
            } else {
                return []
            }
            let modelExpression = columns.contains("model") ? "model" : "NULL"
            let spawnColumns = sqliteTableColumns(db: db, tableName: "thread_spawn_edges")
            let hasSpawnStatus = Set(["child_thread_id", "status"]).isSubset(of: spawnColumns)
            let spawnJoin = hasSpawnStatus
                ? "LEFT JOIN thread_spawn_edges edge ON edge.child_thread_id = thread.id"
                : ""
            let spawnStatusExpression = hasSpawnStatus ? "edge.status" : "NULL"

            guard let statement = prepareSQLiteStatement(
                db: db,
                sql: """
                    SELECT thread.id, thread.rollout_path, thread.cwd,
                           \(updatedAtExpression), \(modelExpression),
                           \(spawnStatusExpression), thread.source
                    FROM threads AS thread
                    \(spawnJoin)
                    WHERE thread.archived = 0
                      AND \(updatedAtExpression) >= ?
                      AND (
                        thread.source = 'vscode'
                        OR thread.source = 'appServer'
                        OR thread.source LIKE '{"subagent"%'
                      )
                      ORDER BY \(updatedAtExpression) DESC
                      LIMIT 50;
                    """
            ) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff)

            var records: [CodexDesktopThreadRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let sessionId = sqliteColumnString(statement, index: 0),
                      let transcriptPath = sqliteColumnString(statement, index: 1),
                      let cwd = sqliteColumnString(statement, index: 2),
                      fileManager.fileExists(atPath: transcriptPath) else { continue }
                // JSON `source` rows can also belong to a concurrent Codex CLI
                // subagent. Never re-key an explicitly CLI-origin rollout into
                // the Desktop namespace merely because the Desktop host is open.
                let transcriptOrigin = codexTranscriptOrigin(path: transcriptPath)
                let databaseSource = sqliteColumnString(statement, index: 6) ?? ""
                if databaseSource.hasPrefix("{\"subagent") {
                    // JSON source alone does not identify the owning surface.
                    // Require positive Desktop provenance before namespacing it.
                    guard transcriptOrigin == .desktop else { continue }
                } else {
                    guard transcriptOrigin != .cli else { continue }
                }

                let dbUpdatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                let fileModifiedAt = (try? fileManager.attributesOfItem(atPath: transcriptPath))?[.modificationDate] as? Date
                let modifiedAt = max(dbUpdatedAt, fileModifiedAt ?? dbUpdatedAt)
                guard modifiedAt >= now.addingTimeInterval(-freshnessWindow) else { continue }

                let dbModel = sqliteColumnString(statement, index: 4)
                let (transcriptModel, messages) = readRecentFromCodexTranscript(path: transcriptPath)
                let turnStatus = latestCodexTurnStatus(path: transcriptPath)
                let isFresh = now.timeIntervalSince(modifiedAt) <= 300
                let isActive = isFresh && turnStatus == .processing
                if !isActive,
                   now.timeIntervalSince(modifiedAt) > completionSettleWindow {
                    continue
                }

                records.append(CodexDesktopThreadRecord(
                    sessionId: sessionId,
                    cwd: cwd,
                    model: dbModel ?? transcriptModel,
                    modifiedAt: modifiedAt,
                    recentMessages: messages,
                    transcriptPath: transcriptPath,
                    status: isActive ? .processing : .idle,
                    subagentMetadata: codexSubagentMetadata(inTranscriptPath: transcriptPath),
                    subagentStatus: sqliteColumnString(statement, index: 5)
                ))
            }
            return records
        } ?? []
    }

    /// Find active Codex sessions by matching running processes to session files
    private nonisolated static func findActiveCodexSessions(candidatePids: [pid_t]? = nil) -> [DiscoveredSession] {
        let codexPids = findCodexPids(candidatePids: candidatePids)
        guard !codexPids.isEmpty else { return [] }

        let processes = codexPids.map { pid in
            CodexProcessDiscoveryCandidate(
                pid: pid,
                cwd: getCwd(for: pid),
                startTime: getProcessStartTime(pid),
                isDesktop: executablePath(for: pid).map(isCodexExecutablePath) ?? false
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessionsBase = "\(home)/.codex/sessions"
        let statePath = "\(home)/.codex/state_5.sqlite"
        return discoverCodexSessions(
            processes: processes,
            sessionsBase: sessionsBase,
            statePath: statePath
        )
    }

    /// Filesystem/state-DB portion of Codex discovery, split from process
    /// inspection so root-CWD fallback and DB degradation can be tested without
    /// relying on live PIDs.
    nonisolated static func discoverCodexSessions(
        processes: [CodexProcessDiscoveryCandidate],
        sessionsBase: String,
        statePath: String,
        now: Date = Date(),
        fileManager fm: FileManager = .default
    ) -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        var seenDiscoveryIds: Set<String> = []
        var seenDesktopSessionIds: Set<String> = []
        var claimedUnknownSessionIds: Set<String> = []

        // Prefer the native host for unknown-origin root rollouts. Explicit CLI
        // and Desktop metadata is filtered below, so concurrent modes remain
        // distinct even when they share a project directory.
        let orderedProcesses = processes.sorted {
            $0.isDesktop && !$1.isDesktop
        }
        for process in orderedProcesses {
            let processCwd = process.cwd
            let useTranscriptCwd = codexDiscoveryUsesTranscriptCwd(processCwd: processCwd)
            if !useTranscriptCwd,
               let processCwd,
               isSubagentWorktree(processCwd) {
                continue
            }

            // Codex stores sessions in date-based dirs: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl.
            // A terminal process maps to one cwd; the shared Desktop app-server
            // may own several sessions, so inspect all fresh rollouts instead.
            let candidates = fm.fileExists(atPath: sessionsBase)
                ? findRecentCodexSessions(base: sessionsBase, after: process.startTime, fm: fm)
                : []
            let files: [String]
            if useTranscriptCwd {
                files = candidates.filter { file in
                    switch codexTranscriptOrigin(path: file) {
                    case .desktop: return process.isDesktop
                    case .cli: return !process.isDesktop
                    case .unknown: return true
                    }
                }
            } else if let processCwd {
                files = Array(candidates.filter { file in
                    guard codexSessionMatchesCwd(path: file, cwd: processCwd) else { return false }
                    switch codexTranscriptOrigin(path: file) {
                    case .desktop: return process.isDesktop
                    case .cli: return !process.isDesktop
                    case .unknown: return true
                    }
                }.prefix(1))
            } else {
                files = []
            }

            for file in files {
                let fileName = (file as NSString).lastPathComponent
                let rawSessionId = extractCodexSessionId(from: fileName)
                guard !rawSessionId.isEmpty else { continue }
                let identity = codexDiscoveryIdentity(
                    rawSessionId: rawSessionId,
                    isDesktop: process.isDesktop
                )
                guard !seenDiscoveryIds.contains(identity.sessionId) else { continue }
                let transcriptOrigin = codexTranscriptOrigin(path: file)
                if transcriptOrigin == .unknown,
                   claimedUnknownSessionIds.contains(rawSessionId) {
                    continue
                }

                let modifiedAt = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? now
                let codexFreshnessLimit: TimeInterval = process.startTime != nil ? -300 : -30
                if modifiedAt.timeIntervalSince(now) < codexFreshnessLimit { continue }

                let transcriptCwd = codexSessionCwd(path: file)
                let sessionCwd = useTranscriptCwd ? transcriptCwd : (transcriptCwd ?? processCwd)
                guard let sessionCwd, !sessionCwd.isEmpty, !isSubagentWorktree(sessionCwd) else { continue }

                let (model, messages) = readRecentFromCodexTranscript(path: file)
                let subagentMetadata = codexSubagentMetadata(inTranscriptPath: file)
                let turnStatus = latestCodexTurnStatus(path: file)

                results.append(DiscoveredSession(
                    sessionId: identity.sessionId,
                    cwd: sessionCwd,
                    tty: nil,
                    model: model,
                    pid: process.pid,
                    modifiedAt: modifiedAt,
                    recentMessages: messages,
                    source: "codex",
                    transcriptPath: file,
                    parentSessionId: subagentMetadata?.parentThreadId,
                    subagentStatus: nil,
                    agentType: subagentMetadata?.agentType,
                    agentNickname: subagentMetadata?.agentNickname,
                    status: turnStatus.map { $0 == .processing ? .processing : .idle },
                    termBundleId: identity.termBundleId,
                    providerSessionId: identity.providerSessionId
                ))
                // Only accepted candidates exclude a matching DB record. A stale
                // or malformed rollout must not hide a valid state-backed thread.
                seenDiscoveryIds.insert(identity.sessionId)
                if transcriptOrigin == .unknown {
                    claimedUnknownSessionIds.insert(rawSessionId)
                }
                if process.isDesktop {
                    seenDesktopSessionIds.insert(rawSessionId)
                }
            }
        }

        // Only actual active subagents need the optional spawn-edge status.
        // Resolve all of them through one read-only SQLite connection; terminal
        // transcript state already wins without consulting the database.
        let activeSubagentIds = Set(results.compactMap { result -> String? in
            guard result.parentSessionId != nil, result.status != .idle else { return nil }
            return result.providerSessionId ?? result.sessionId
        })
        if !activeSubagentIds.isEmpty {
            let spawnRecords = codexSpawnEdgeRecords(
                threadIds: activeSubagentIds,
                statePath: statePath
            )
            for index in results.indices {
                let providerSessionId = results[index].providerSessionId ?? results[index].sessionId
                results[index].subagentStatus = spawnRecords[providerSessionId]?.status
            }
        }

        // Native Codex Desktop / ChatGPT sessions cannot be mapped by process
        // CWD because its app-server runs from `/`. Hydrate recent threads from
        // state_5.sqlite and let transcript activity drive running/idle state.
        if processes.contains(where: { $0.isDesktop }) {
            results.append(contentsOf: findRecentCodexDesktopSessions(
                excluding: seenDesktopSessionIds,
                statePath: statePath,
                now: now,
                fileManager: fm
            ))
        }
        return results
    }

    private nonisolated static func findRecentCodexDesktopSessions(
        excluding excludedSessionIds: Set<String> = [],
        statePath: String? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> [DiscoveredSession] {
        let resolvedStatePath = statePath ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite").path

        return recentCodexDesktopThreadRecords(
            statePath: resolvedStatePath,
            now: now,
            fileManager: fileManager
        ).compactMap { record in
            guard !excludedSessionIds.contains(record.sessionId) else { return nil }
            let identity = codexDiscoveryIdentity(rawSessionId: record.sessionId, isDesktop: true)
            return DiscoveredSession(
                sessionId: identity.sessionId,
                cwd: record.cwd,
                tty: nil,
                model: record.model,
                pid: nil,
                modifiedAt: record.modifiedAt,
                recentMessages: record.recentMessages,
                source: "codex",
                transcriptPath: record.transcriptPath,
                parentSessionId: record.subagentMetadata?.parentThreadId,
                subagentStatus: record.subagentStatus,
                agentType: record.subagentMetadata?.agentType,
                agentNickname: record.subagentMetadata?.agentNickname,
                status: record.status,
                termBundleId: identity.termBundleId,
                providerSessionId: identity.providerSessionId
            )
        }
    }

    private nonisolated static func inspectCodexSubagentMetadata(
        inTranscriptPath path: String
    ) -> CodexTranscriptSubagentInspection {
        guard let firstLine = readFirstLine(path: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "session_meta",
              let payload = json["payload"] as? [String: Any] else {
            return .unavailable
        }

        guard let source = payload["source"] as? [String: Any],
              let subagent = source["subagent"] as? [String: Any],
              !subagent.isEmpty else {
            return .root
        }
        let parent = firstStringRecursively(in: subagent, key: "parent_thread_id")
        guard let parent, !parent.isEmpty else { return .unavailable }

        let agentType = firstStringRecursively(in: subagent, key: "agent_role")
            ?? subagent.keys.sorted().first
        let nickname = firstStringRecursively(in: subagent, key: "agent_nickname")
        return .subagent(CodexSubagentMetadata(
            parentThreadId: parent,
            agentType: agentType,
            agentNickname: nickname
        ))
    }

    nonisolated static func codexSubagentMetadata(inTranscriptPath path: String) -> CodexSubagentMetadata? {
        guard case .subagent(let metadata) = inspectCodexSubagentMetadata(
            inTranscriptPath: path
        ) else {
            return nil
        }
        return metadata
    }

    nonisolated static func codexSubagentMetadata(
        threadId: String,
        transcriptPath: String?,
        statePath overrideStatePath: String? = nil
    ) -> CodexSubagentMetadata? {
        if let transcriptPath {
            switch inspectCodexSubagentMetadata(inTranscriptPath: transcriptPath) {
            case .subagent(let metadata):
                return metadata
            case .root:
                return nil
            case .unavailable:
                break
            }
        }

        return codexSpawnEdgeRecords(
            threadIds: [threadId],
            statePath: overrideStatePath
        )[threadId]?.metadata
    }

    /// Resolve spawn relations/statuses in one read-only connection. Queries are
    /// chunked to keep SQLite variable counts bounded when restoring many cards.
    private nonisolated static func codexSpawnEdgeRecords(
        threadIds: Set<String>,
        statePath overrideStatePath: String? = nil
    ) -> [String: CodexSpawnEdgeRecord] {
        guard !threadIds.isEmpty else { return [:] }
        let statePath = overrideStatePath ?? {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return "\(home)/.codex/state_5.sqlite"
        }()
        return withSQLiteDatabase(at: statePath) { db in
            let edgeColumns = sqliteTableColumns(db: db, tableName: "thread_spawn_edges")
            guard Set(["parent_thread_id", "child_thread_id", "status"]).isSubset(of: edgeColumns) else {
                return [:]
            }
            let threadColumns = sqliteTableColumns(db: db, tableName: "threads")
            let canJoinThreads = threadColumns.contains("id")
            let roleExpression = canJoinThreads && threadColumns.contains("agent_role")
                ? "thread.agent_role" : "NULL"
            let nicknameExpression = canJoinThreads && threadColumns.contains("agent_nickname")
                ? "thread.agent_nickname" : "NULL"
            let sourceExpression = canJoinThreads && threadColumns.contains("source")
                ? "thread.source" : "NULL"
            let transcriptExpression = canJoinThreads && threadColumns.contains("rollout_path")
                ? "thread.rollout_path" : "NULL"
            let join = canJoinThreads
                ? "LEFT JOIN threads AS thread ON thread.id = edge.child_thread_id"
                : ""

            let orderedIds = threadIds.sorted()
            let chunkSize = 200
            var records: [String: CodexSpawnEdgeRecord] = [:]
            for start in stride(from: 0, to: orderedIds.count, by: chunkSize) {
                let end = min(start + chunkSize, orderedIds.count)
                let chunk = Array(orderedIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                    SELECT edge.child_thread_id, edge.parent_thread_id, edge.status,
                           \(roleExpression), \(nicknameExpression), \(sourceExpression),
                           \(transcriptExpression)
                    FROM thread_spawn_edges AS edge
                    \(join)
                    WHERE edge.child_thread_id IN (\(placeholders))
                    """
                guard let statement = prepareSQLiteStatement(db: db, sql: sql) else { continue }
                for (offset, threadId) in chunk.enumerated() {
                    bindSQLiteText(threadId, to: statement, index: Int32(offset + 1))
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    guard let child = nonEmptySQLiteColumnString(statement, index: 0),
                          let parent = nonEmptySQLiteColumnString(statement, index: 1) else {
                        continue
                    }
                    var agentType = nonEmptySQLiteColumnString(statement, index: 3)
                    var nickname = nonEmptySQLiteColumnString(statement, index: 4)
                    if let source = nonEmptySQLiteColumnString(statement, index: 5),
                       let data = source.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) {
                        agentType = agentType ?? firstStringRecursively(in: json, key: "agent_role")
                        nickname = nickname ?? firstStringRecursively(in: json, key: "agent_nickname")
                    }
                    records[child] = CodexSpawnEdgeRecord(
                        metadata: CodexSubagentMetadata(
                            parentThreadId: parent,
                            agentType: agentType,
                            agentNickname: nickname
                        ),
                        status: nonEmptySQLiteColumnString(statement, index: 2),
                        transcriptPath: nonEmptySQLiteColumnString(statement, index: 6)
                    )
                }
                sqlite3_finalize(statement)
            }
            return records
        } ?? [:]
    }

    private nonisolated static func readFirstLine(path: String, maxBytes: Int = 2_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var data = Data()
        while data.count < maxBytes {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data.append(chunk[..<newline])
                break
            }
            data.append(chunk)
        }
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func firstStringRecursively(in value: Any, key: String) -> String? {
        if let dict = value as? [String: Any] {
            if let string = dict[key] as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string
            }
            for child in dict.values {
                if let found = firstStringRecursively(in: child, key: key) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstStringRecursively(in: child, key: key) {
                    return found
                }
            }
        }
        return nil
    }

    private nonisolated static func nonEmptySQLiteColumnString(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let value = sqliteColumnString(statement, index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Find the most recent Codex session file matching a CWD
    /// Scans back up to 7 days to cover long-running sessions that span day boundaries
    private nonisolated static func findRecentCodexSession(base: String, cwd: String, after: Date?, fm: FileManager) -> String? {
        findRecentCodexSessions(base: base, after: after, fm: fm)
            .first(where: { codexSessionMatchesCwd(path: $0, cwd: cwd) })
    }

    private nonisolated static func findRecentCodexSessions(base: String, after: Date?, fm: FileManager) -> [String] {
        let cal = Calendar.current
        let now = Date()
        var dirs: [String] = []
        for daysBack in 0..<7 {
            guard let date = cal.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let y = String(format: "%04d", cal.component(.year, from: date))
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let dir = "\(base)/\(y)/\(m)/\(d)"
            if fm.fileExists(atPath: dir) {
                dirs.append(dir)
            }
        }
        guard !dirs.isEmpty else { return [] }
        return scanCodexDir(dirs: dirs, after: after, fm: fm)
    }

    private nonisolated static func scanCodexDir(dirs: [String], after: Date?, fm: FileManager) -> [String] {
        var results: [String] = []
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            // Sort descending to check newest first
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted(by: >)

            for file in jsonlFiles.prefix(20) {
                let fullPath = "\(dir)/\(file)"
                if let start = after,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < start.addingTimeInterval(-10) {
                    continue
                }
                results.append(fullPath)
            }
        }
        return results
    }

    /// Check if a Codex session file's CWD matches the target
    private nonisolated static func codexSessionMatchesCwd(path: String, cwd: String) -> Bool {
        codexSessionCwd(path: path) == cwd
    }

    nonisolated static func codexSessionCwd(path: String) -> String? {
        guard let firstLine = readFirstLine(path: path),
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else { return nil }
        return sessionCwd
    }

    /// Extract session ID from Codex filename: rollout-2026-04-04T20-54-48-{uuid}.jsonl
    private nonisolated static func extractCodexSessionId(from filename: String) -> String {
        // Format: rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl
        let name = filename.replacingOccurrences(of: ".jsonl", with: "")
        // The UUID is the last 36 chars (8-4-4-4-12)
        // Pattern: after the datetime portion, everything from the 4th dash group onwards is the UUID
        let parts = name.split(separator: "-")
        // rollout-YYYY-MM-DDThh-mm-ss-{8}-{4}-{4}-{4}-{12}
        // That's: [rollout, YYYY, MM, DDThh, mm, ss, uuid1, uuid2, uuid3, uuid4, uuid5]
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
    }

    private nonisolated static func extractTextContent(from rawContent: Any?) -> String? {
        if let text = rawContent as? String, !text.isEmpty {
            return text
        }
        if let items = rawContent as? [[String: Any]] {
            for item in items {
                if let text = item["text"] as? String, !text.isEmpty {
                    return text
                }
                if let output = item["output"] as? [String: Any],
                   let text = output["text"] as? String, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    nonisolated static func readRecentFromCursorTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let role = json["role"] as? String,
                  let message = json["message"] as? [String: Any],
                  let textContent = JSONLTailer.normalizedCursorChatText(from: message["content"])
                    ?? extractTextContent(from: message["content"])
            else { continue }

            if role == "user" {
                userMessages.append((index, textContent))
            } else if role == "assistant" {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (nil, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func readRecentFromCodeBuddyTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "message",
                  let role = json["role"] as? String,
                  let textContent = extractTextContent(from: json["content"])
            else { continue }

            if model == nil,
               let providerData = json["providerData"] as? [String: Any],
               let messageModel = providerData["model"] as? String, !messageModel.isEmpty {
                model = messageModel
            }

            if role == "user" {
                userMessages.append((index, textContent))
            } else if role == "assistant" {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func readRecentFromFactoryTranscript(path: String) -> (String?, [ChatMessage]) {
        let sidecarPath = path.replacingOccurrences(of: ".jsonl", with: ".settings.json")
        var model: String?
        if let data = FileManager.default.contents(atPath: sidecarPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let foundModel = json["model"] as? String, !foundModel.isEmpty {
            model = foundModel
        }
        let (_, messages) = readRecentFromTranscript(path: path)
        return (model, messages)
    }

    private nonisolated static func readRecentFromCopilotTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["data"] as? [String: Any]
            else { continue }

            if model == nil {
                if let currentModel = payload["currentModel"] as? String, !currentModel.isEmpty {
                    model = currentModel
                } else if let eventModel = payload["model"] as? String, !eventModel.isEmpty {
                    model = eventModel
                } else if let metrics = payload["modelMetrics"] as? [String: Any],
                          let metricModel = metrics.keys.sorted().last, !metricModel.isEmpty {
                    model = metricModel
                }
            }

            if type == "user.message",
               let textContent = payload["content"] as? String, !textContent.isEmpty {
                userMessages.append((index, textContent))
            } else if type == "assistant.message",
                      let textContent = payload["content"] as? String, !textContent.isEmpty {
                assistantMessages.append((index, textContent))
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        return (model, Array(combined.suffix(3).map { $0.1 }))
    }

    private nonisolated static func readTranscriptTail(path: String, maxBytes: UInt64 = 65536) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, maxBytes)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func parseISO8601Timestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    nonisolated static func codexLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        let terminalEventTypes: Set<String> = ["task_complete", "turn_aborted", "turn_failed"]
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String,
                  terminalEventTypes.contains(eventType),
                  let timestamp = json["timestamp"] as? String,
                  let date = parseISO8601Timestamp(timestamp) else { continue }

            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }

    nonisolated static func qoderLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = json["timestamp"] as? String,
                  let date = parseISO8601Timestamp(timestamp) else { continue }

            let type = json["type"] as? String ?? ""
            if type == "progress",
               let data = json["data"] as? [String: Any] {
                let hookEvent = (data["hookEvent"] as? String) ?? (data["hookName"] as? String) ?? ""
                if hookEvent == "Stop" || hookEvent == "SessionEnd" {
                    if latest == nil || date > latest! {
                        latest = date
                    }
                    continue
                }
            }

            if type == "assistant",
               let message = json["message"] as? [String: Any],
               (message["role"] as? String) == "assistant",
               extractTextContent(from: message["content"]) != nil {
                if latest == nil || date > latest! {
                    latest = date
                }
            }
        }

        return latest
    }

    nonisolated static func codeBuddyLatestTerminalTurnTimestamp(in transcriptTail: String) -> Date? {
        var latest: Date?

        for line in transcriptTail.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (json["type"] as? String) == "message",
                  (json["role"] as? String) == "assistant",
                  (json["status"] as? String) == "completed",
                  extractTextContent(from: json["content"]) != nil else { continue }

            let date: Date?
            if let rawTimestamp = json["timestamp"] as? NSNumber {
                date = Date(timeIntervalSince1970: rawTimestamp.doubleValue / 1000)
            } else if let rawTimestamp = json["timestamp"] as? Double {
                date = Date(timeIntervalSince1970: rawTimestamp / 1000)
            } else if let rawTimestamp = json["timestamp"] as? Int64 {
                date = Date(timeIntervalSince1970: TimeInterval(rawTimestamp) / 1000)
            } else {
                date = nil
            }

            guard let date else { continue }
            if latest == nil || date > latest! {
                latest = date
            }
        }

        return latest
    }

    /// Read model and recent messages from a Codex transcript file
    private nonisolated static func readRecentFromCodexTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let text = readTranscriptTail(path: path) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            // Extract model from session_meta
            if type == "session_meta", model == nil,
               let payload = json["payload"] as? [String: Any] {
                model = payload["model"] as? String
                    ?? payload["model_provider"] as? String
            }

            // Prefer event_msg (cleaner user/agent messages from Codex)
            if type == "event_msg",
               let payload = json["payload"] as? [String: Any],
               let msgType = payload["type"] as? String,
               let msg = payload["message"] as? String, !msg.isEmpty {
                if msgType == "user_message" {
                    userMessages.append((index, msg))
                } else if msgType == "agent_message" {
                    assistantMessages.append((index, msg))
                }
            }

            // Fallback: extract from response_item only if event_msg didn't provide the same content
            // (user messages come from event_msg which is cleaner — response_item user entries
            //  often contain injected system/tool context, not actual user input)
            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               let role = payload["role"] as? String {

                if let content = payload["content"] as? [[String: Any]] {
                    for item in content {
                        let itemType = item["type"] as? String ?? ""
                        if let t = item["text"] as? String, !t.isEmpty {
                            if role == "user" && itemType == "input_text" && userMessages.isEmpty {
                                // Only use response_item for user messages if no event_msg was found
                                userMessages.append((index, t))
                            } else if role == "assistant" && itemType == "output_text" && assistantMessages.last?.1 != t {
                                // Only add if not a duplicate of the last event_msg entry
                                assistantMessages.append((index, t))
                            }
                            break
                        }
                    }
                }
            }
            index += 1
        }

        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }

    /// Read model and last 3 user/assistant messages from a transcript file's tail
    nonisolated static func readRecentFromTranscript(path: String) -> (String?, [ChatMessage]) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, []) }
        defer { handle.closeFile() }

        // Read last 64KB
        let fileSize = handle.seekToEndOfFile()
        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return (nil, []) }

        var model: String?
        var userMessages: [(Int, String)] = []
        var assistantMessages: [(Int, String)] = []
        var index = 0

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = json["type"] as? String
            let message = (json["message"] as? [String: Any]) ?? json
            let role = (message["role"] as? String) ?? type

            guard let role else { continue }
            let normalizedRole = role.lowercased()

            if model == nil, let m = message["model"] as? String, !m.isEmpty {
                model = m
            }

            // Extract text content
            var textContent: String?
            if normalizedRole == "user" || normalizedRole == "user_input" {
                if let content = message["content"] as? String {
                    var text = content
                    if let startRange = text.range(of: "<USER_REQUEST>"),
                       let endRange = text.range(of: "</USER_REQUEST>", range: startRange.upperBound..<text.endIndex) {
                        text = String(text[startRange.upperBound..<endRange.lowerBound])
                    }
                    textContent = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    for item in contentArray {
                        if item["type"] as? String == "text",
                           let t = item["text"] as? String, !t.isEmpty {
                            textContent = t
                            break
                        }
                    }
                }
            } else if normalizedRole == "assistant" || normalizedRole == "planner_response" {
                if let content = message["content"] as? String {
                    textContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if let contentArray = message["content"] as? [[String: Any]] {
                    for item in contentArray {
                        if item["type"] as? String == "text",
                           let t = item["text"] as? String, !t.isEmpty {
                            textContent = t
                            break
                        }
                    }
                } else if let thinking = message["thinking"] as? String {
                    textContent = thinking.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if let text = textContent, !text.isEmpty {
                if normalizedRole == "user" || normalizedRole == "user_input" {
                    userMessages.append((index, text))
                } else if normalizedRole == "assistant" || normalizedRole == "planner_response" {
                    assistantMessages.append((index, text))
                }
            }
            index += 1
        }

        // Build recent messages: take last few user+assistant, sorted by order, keep 3
        var combined: [(Int, ChatMessage)] = []
        for (i, text) in userMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: true, text: text)))
        }
        for (i, text) in assistantMessages.suffix(3) {
            combined.append((i, ChatMessage(isUser: false, text: text)))
        }
        combined.sort { $0.0 < $1.0 }
        let recent = Array(combined.suffix(3).map { $0.1 })

        return (model, recent)
    }
}

/// Encode a path the same way Claude Code does for project directory names:
/// "/" → "-", non-ASCII → "-", spaces → "-"
extension String {
    func claudeProjectDirEncoded() -> String {
        var result = ""
        for c in self.unicodeScalars {
            if c == "/" || c == " " || c.value > 127 {
                result.append("-")
            } else {
                result.append(Character(c))
            }
        }
        return result
    }

    func appProjectDirEncoded() -> String {
        let encoded = claudeProjectDirEncoded()
        if encoded.hasPrefix("-") {
            return String(encoded.dropFirst())
        }
        return encoded
    }
}
