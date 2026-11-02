import SwiftUI
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "AppState")

/// AppState's answers to the Agent Sub-Sessions resolvers, taken on the main
/// actor for one hook (``AppState/subsessionContext``).
struct AppSubsessionContext: SubsessionContext {
    let cards: [String: SessionSnapshot]
    let codexRollouts: CodexRolloutCache

    func codexRolloutInspection(transcriptPath: String) -> CodexTranscriptSubagentInspection {
        codexRollouts.inspection(transcriptPath: transcriptPath)
    }
}

/// The session store the island's views observe, and the coordinator around
/// it, on the main actor: hook events, approvals and questions, completions
/// and attention land here. The slow work it coordinates runs elsewhere —
/// session discovery in `SessionDiscoveryCoordinator` and the `Discovery/`
/// namespaces, a known card's store reads through `SessionStoreReaders`,
/// both off the main actor; exit watches in `SessionProcessMonitor`; the
/// compact bar's rotation in `CompactBarRotation` — and AppState integrates
/// what they find.
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
    var permissionQueue: [PermissionRequest] = [] {
        didSet {
            followUps.waitingChanged()
            PushNotifier.shared.requestsChanged()
        }
    }
    var questionQueue: [QuestionRequest] = [] {
        didSet {
            // A close lasts as long as its request: once answered, skipped or
            // drained, its id is forgotten.
            if !dismissedQuestionIds.isEmpty {
                let queued = Set(questionQueue.map(\.id))
                if !dismissedQuestionIds.isSubset(of: queued) {
                    dismissedQuestionIds.formIntersection(queued)
                }
            }
            // So does what the user had typed into its card.
            if !questionDrafts.isEmpty {
                let queued = Set(questionQueue.map(\.id))
                questionDrafts = questionDrafts.filter { queued.contains($0.key) }
            }
            followUps.waitingChanged()
            PushNotifier.shared.requestsChanged()
        }
    }
    /// What the user has typed and picked on a question card, by request. The
    /// card's view is rebuilt whenever the island moves to another display or
    /// the displays change, and its own state went with it: half an answer
    /// typed, a multi-question wizard's earlier answers. Kept while the
    /// request is queued, closed cards included.
    @ObservationIgnored
    private var questionDrafts: [UUID: QuestionWizardState] = [:]

    func questionDraft(for requestId: UUID) -> QuestionWizardState? {
        questionDrafts[requestId]
    }

    func saveQuestionDraft(_ draft: QuestionWizardState) {
        guard let id = draft.requestId, questionQueue.contains(where: { $0.id == id }) else { return }
        questionDrafts[id] = draft
    }

    /// Follow-up reminders for waiting approvals / questions and unseen
    /// completions. Holds no entries and arms no timer while the setting is off.
    @ObservationIgnored
    private(set) lazy var followUps = FollowUpReminderController(appState: self)
    /// What each display-only wait asks, recorded by the source that opened
    /// it, for its pushes. See AppState+DisplayOnlyWaits.
    @ObservationIgnored
    var displayOnlyWaitAsks: [String: PushContent] = [:]

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
    /// Cache of in-flight PreToolUse records keyed by card and tool_use_id. Used to correlate
    /// permission requests back to their originating tool call. See AppState+ToolUseCache.
    @ObservationIgnored
    var pendingToolUses: [ToolUseKey: PreToolUseRecord] = [:]
    /// Records the transcript path currently watched for each session so we only
    /// reattach when the path actually changes. See AppState+TranscriptTailer.
    @ObservationIgnored
    var attachedTranscriptPaths: [String: String] = [:]
    /// Token for the exact JSONLTailer attachment currently owned by a session.
    /// A queued delta from an older attachment must not mutate a same-id session
    /// that was closed and subsequently re-created.
    @ObservationIgnored
    var attachedTranscriptTokens: [String: UUID] = [:]
    /// Attach-time checklist scans still running off the main actor, keyed by
    /// session. See AppState+AgentTasks.
    @ObservationIgnored
    var pendingAgentTaskBackfills: [String: PendingAgentTaskBackfill] = [:]
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
    /// Grok sessions retired because their pager process started another
    /// session (#318), mapped to that process. While it lives, discovery and
    /// trailing passive hooks must not resurrect the card; a new prompt or
    /// SessionStart for the session means the user switched back to it.
    @ObservationIgnored
    var supersededGrokSessions: [String: ProcessIdentity] = [:]
    /// Cursor gives its own hooks and the Claude Code hooks it imports one
    /// payload per step, and CodeIsland is wired into both, so a `stop` or a
    /// `beforeSubmitPrompt` arrives twice (#377). See ``CursorHookPayload``.
    @ObservationIgnored
    var cursorHookDeliveries = CursorHookDeliveryFilter()
    /// Claude Code compacting finished sessions in the background: the
    /// compaction's own hooks leave the card as it was. See
    /// ``BackgroundCompactionFilter``.
    @ObservationIgnored
    var backgroundCompactions = BackgroundCompactionFilter()

    /// Per-agent AiWork/Agentix daemon watch clients (`sessions.watch`).
    /// Keyed by agent id (e.g. `"coder"`). See AppState+AiWorkWatch.
    @ObservationIgnored
    var aiworkWatchClients: [String: AiWorkWatchClient] = [:]
    /// Periodic reconnect / rediscovery timer for Agentix daemons.
    @ObservationIgnored
    var aiworkWatchReconnectTimer: Timer?
    /// Daemon session ids that already received a `sessions.get` title/cwd hydrate.
    @ObservationIgnored
    var aiworkHydratedSessionIds: Set<String> = []
    /// When a `sessions.get` hydrate last failed, per daemon session id. The id
    /// stays in `aiworkHydratedSessionIds` until the cooldown elapses, so a
    /// failing daemon is not re-dialled on every streamed token.
    @ObservationIgnored
    var aiworkHydrateFailedAt: [String: Date] = [:]
    /// Agentix state dir to discover daemons under; nil = `$AGENTIX_STATE_DIR`
    /// or `~/.agentix`. Tests point this at a temp dir so they never reach a
    /// real daemon on the developer's machine.
    @ObservationIgnored
    var aiworkStateDirOverride: String?
    /// Guards overlapping `agent.stats` reconciles from the 3s rediscovery timer.
    @ObservationIgnored
    var aiworkReconcileInFlight = false

    /// Claude Desktop Cowork/Chat session-store watcher; nil while the setting
    /// is off. See AppState+CoworkWatch.
    @ObservationIgnored
    var coworkWatcher: CoworkSessionWatcher?
    /// The Claude Desktop process each in-flight Cowork turn runs in, and
    /// how to find the running one (a seam for tests).
    @ObservationIgnored
    var coworkTurnHosts: [String: ProcessIdentity] = [:]
    @ObservationIgnored
    var claudeDesktopProcessProvider: () -> ProcessIdentity? = { AppState.runningClaudeDesktopProcess() }
    @ObservationIgnored
    var claudeDesktopTerminationObserver: NSObjectProtocol?

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
                claudeQuota.noteExpanded()
            } else {
                claudeQuota.noteCollapsed()
            }
            if surface != oldValue {
                followUps.surfaceChanged(surface)
            }
            if surface != .sessionList, idleSessionRemovalRequest != nil {
                idleSessionRemovalRequest = nil
            }
            switch surface {
            case .approvalCard(let sid): cardRequestId = pendingPermission(forSession: sid)?.id
            case .questionCard(let sid): cardRequestId = pendingQuestion(forSession: sid)?.id
            case .collapsed, .sessionList, .completionCard: cardRequestId = nil
            }
        }
    }

    /// The request the approval / question card on screen was opened for.
    /// While that very request still waits, re-evaluating the queue leaves
    /// the card alone — it may be one the user picked that is not the head.
    /// Once it is answered, the session's next request filling the same card
    /// is weighed like any other.
    @ObservationIgnored
    private var cardRequestId: UUID?

    /// Index of the approval the card on screen still shows, when it is
    /// still waiting and visible.
    private var shownApprovalIndex: Int? {
        guard let cardRequestId, case .approvalCard(let sid) = surface,
              !dismissedPermissionSessionIds.contains(sid),
              pendingPermission(forSession: sid)?.id == cardRequestId else { return nil }
        return permissionQueue.firstIndex { $0.id == cardRequestId }
    }

    /// The session of the question card on screen, when the question it was
    /// opened for still waits.
    private var shownQuestionSessionId: String? {
        guard let cardRequestId, case .questionCard(let sid) = surface,
              pendingQuestion(forSession: sid)?.id == cardRequestId else { return nil }
        return sid
    }

    /// Local-transcript token usage shown in the session-list footer.
    /// Refreshed lazily on panel expansion (no resident timer, no API calls).
    var claudeUsage: ClaudeUsageScanner.Snapshot?
    /// Subscription rate limits (5h / weekly) from Anthropic — opt-in, network.
    let claudeQuota = ClaudeQuotaMonitor()
    /// Process-wide, not per-instance: the scan reads one shared history
    /// (`~/.claude`), so two concurrent runs are always duplicate work. Production
    /// has a single AppState and never noticed, but anything constructing several —
    /// the test bundle does — otherwise starts N cold scans at once on the shared
    /// `.utility` cooperative pool and starves every other detached probe on it
    /// (git-branch resolution among them).
    private static var usageScanInFlight = false
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
    /// How long a completion card stays up on its own. Tests shorten it.
    @ObservationIgnored
    var completionAutoCollapseDelay: TimeInterval = 5
    private var completionQueue: [String] = []
    /// The queued completion whose card waits on Smart Suppress's look at
    /// its session's tab (off the main thread). It is the next card on its
    /// way: nothing else leaves the queue meanwhile.
    @ObservationIgnored
    private var queuedCompletionLookingAtTab: String?
    /// Mouse must enter the panel before auto-collapse is allowed (prevents instant dismiss)
    var completionHasBeenEntered = false {
        // The pointer on the completion card is the one proof the turn was seen.
        didSet {
            if completionHasBeenEntered, let sid = justCompletedSessionId {
                followUps.completionSeen(sessionId: sid)
            }
        }
    }
    /// Auto-collapse timer fired but mouse is inside panel — defer collapse until mouse leaves
    var deferCollapseOnMouseLeave = false
    /// Exit watches on the sessions' local CLI processes.
    private let processMonitor = SessionProcessMonitor()
    /// Sessions in the grace period after their process exited, with that process.
    private var exitingSessions: [String: ProcessIdentity] = [:]
    /// Run-local tombstones keep passive discovery from immediately restoring cards the user removed.
    @ObservationIgnored var manuallyRemovedSessions: [String: Date] = [:]
    /// The connected group recorded at removal time; real activity revives all of its members together.
    @ObservationIgnored private var manuallyRemovedSessionPeers: [String: Set<String>] = [:]
    /// The idle cards the session list's banner asks the user to confirm
    /// removing, as they were when the header button was clicked. nil: no
    /// banner. Leaving the list, or nothing in it staying removable, drops it.
    var idleSessionRemovalRequest: IdleSessionRemovalSelection?
    @ObservationIgnored
    nonisolated(unsafe) private var saveTimer: Timer?
    /// Session discovery: the session-store watcher and the scans it runs off
    /// the main actor, whose sessions land in `integrateDiscovered`.
    @ObservationIgnored
    private(set) lazy var discovery: SessionDiscoveryCoordinator = {
        let discovery = SessionDiscoveryCoordinator()
        discovery.onDiscovered = { [weak self] in self?.integrateDiscovered($0) }
        return discovery
    }()
    /// Cursor Agent Task transcripts on disk, for rebranding default-Claude
    /// Task cards and folding Cursor-labelled ones. Built off the main actor;
    /// see `rebrandMisattributedCursorTaskCards`.
    @ObservationIgnored
    private var cursorSubagentIndex: CursorSubagentTranscriptIndex?
    @ObservationIgnored
    nonisolated(unsafe) private var cursorSubagentIndexTask: Task<Void, Never>?
    @ObservationIgnored
    nonisolated(unsafe) private var cursorSubagentIndexRecheck: Task<Void, Never>?
    /// When `cursorSubagentIndexRecheck` fires.
    @ObservationIgnored
    private var cursorSubagentIndexRecheckAt: Date?
    /// The lookup schedule of each card the index does not resolve.
    @ObservationIgnored
    private var cursorSubagentLookups: [String: CursorSubagentLookupSchedule] = [:]
    /// When such a card is looked up after it first goes unresolved. Tests shorten it.
    @ObservationIgnored
    var cursorSubagentLookupDelays = CursorSubagentLookupSchedule.defaultDelays
    /// What each Codex thread's rollout says about its parent: Agent
    /// Sub-Sessions asks on every Codex hook, and reads a rollout once.
    @ObservationIgnored
    let codexRollouts = CodexRolloutCache(read: { CodexDiscovery.inspectCodexSubagentMetadata(inTranscriptPath: $0) })
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
    /// Cards whose model (`maybeBackfillModel`), YOLO setting or native-app
    /// turn end is being read off the main actor.
    @ObservationIgnored
    private(set) var modelReadsInFlight: Set<String> = []
    @ObservationIgnored
    private(set) var cursorYoloReadsInFlight: Set<String> = []
    @ObservationIgnored
    private(set) var nativeAppTurnReadsInFlight: Set<String> = []
    /// The reads of the agents' own stores made for a known card, run off
    /// the main actor (see `SessionStoreReaders`). Inert in a test process;
    /// tests install their own.
    @ObservationIgnored
    var storeReaders = SessionStoreReaders.current
    /// Per parent session → subagent id: the subagent's own model/effort once
    /// read from its transcript, and the reads still trying to find it.
    @ObservationIgnored
    var subagentModelObservations: [String: [String: ModelObservation]] = [:]
    @ObservationIgnored
    var subagentModelReads: [String: [String: SubagentModelRead]] = [:]
    /// Per local Hermes session: the read of Hermes's own store in progress.
    @ObservationIgnored
    var hermesStoreReads: [String: HermesStoreRead] = [:]

    private var dismissedPermissionSessionIds: Set<String> = [] {
        didSet { followUps.waitingChanged() }
    }
    private func nextVisiblePermissionIndex() -> Int? {
        permissionQueue.firstIndex { request in
            let sid = request.event.sessionId ?? "default"
            return !dismissedPermissionSessionIds.contains(sid)
        }
    }

    /// Sessions whose approval is still waiting on the user: queued and not
    /// dismissed. Dismissing hides a request without dequeuing it (#309), so
    /// the queue alone would keep reminding about a prompt the user hid.
    var visiblePermissionSessionIds: Set<String> {
        Set(permissionQueue.map { $0.event.sessionId ?? "default" })
            .subtracting(dismissedPermissionSessionIds)
    }

    /// The request each of those sessions' approval card shows — its first
    /// queued one — by session. Follow-up reminders belong to that request.
    var visiblePermissionRequestIds: [String: String] {
        var ids: [String: String] = [:]
        for request in permissionQueue {
            let sid = request.event.sessionId ?? "default"
            guard ids[sid] == nil, !dismissedPermissionSessionIds.contains(sid) else { continue }
            ids[sid] = request.id.uuidString
        }
        return ids
    }

    /// Question requests the user closed without answering. Unlike approvals
    /// these are keyed by request, not session: a new question from the same
    /// session is a new thing to see. Hidden, never resolved — the agent keeps
    /// waiting, and the collapsed bar's question badge reopens the card.
    private(set) var dismissedQuestionIds: Set<UUID> = [] {
        didSet { followUps.waitingChanged() }
    }

    /// The question each session's card shows — its first queued one — in
    /// queue order, for the sessions whose card the user has not closed. That
    /// first question decides: a later one from the same session (a
    /// subagent's) waits behind a closed card instead of reopening it on the
    /// question the user just put away.
    private var visibleQuestionCards: [QuestionRequest] {
        var seen = Set<String>()
        return questionQueue.filter { request in
            seen.insert(request.event.sessionId ?? "default").inserted
                && !dismissedQuestionIds.contains(request.id)
        }
    }

    /// The first question whose card the user has not closed — what may open
    /// by itself, and what a question shortcut acts on.
    var nextVisibleQuestion: QuestionRequest? {
        visibleQuestionCards.first
    }

    /// Question counterpart of `visiblePermissionRequestIds`: closed cards are
    /// left out, so follow-up reminders stop for a card the user put away.
    var pendingQuestionRequestIds: [String: String] {
        var ids: [String: String] = [:]
        for request in visibleQuestionCards {
            ids[request.event.sessionId ?? "default"] = request.id.uuidString
        }
        return ids
    }

    /// The compact bar's mascot rotation through the active sessions.
    private let rotation = CompactBarRotation()
    var rotatingSessionId: String? { rotation.rotatingSessionId }
    var rotatingSession: SessionSnapshot? {
        guard let rid = rotatingSessionId else { return nil }
        return sessions[rid]
    }

    private func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.cleanupIdleSessions()
            }
        }
    }

    /// Agents whose tracked process is a long-lived daemon rather than a
    /// per-turn CLI. Process exit never marks the end of a reply, so when the
    /// turn-end hook is missing (not approved on the agent's side, or the turn
    /// died before it fired) a card that has gone quiet with no tool in flight
    /// is the only evidence the turn is over. (#303)
    nonisolated static let daemonBackedSources: Set<String> = ["hermes"]

    /// How long a daemon-backed session may sit on bare "thinking" with no tool
    /// and no new events before it settles. Only a safety net: Hermes's
    /// on_session_end ends every turn, interrupted ones included (#364). The
    /// card is on "thinking" from the prompt on (pre_llm_call), and a
    /// reasoning model easily thinks for longer than 20 s before its first or
    /// next tool call — the card must not read idle while it does.
    nonisolated static let daemonTurnSettleTimeout: TimeInterval = 120

    /// Minutes an idle card with no process to outlive waits before it goes.
    nonisolated static let defaultStaleIdleMinutes = 10

    /// Whether the idle sweep removes an idle card. The user's timeout applies
    /// to every card. Otherwise a card whose process is monitored lives as
    /// long as that process; one without (hook-only) goes after
    /// `defaultStaleIdleMinutes`. So does a Hermes gateway chat's card: its
    /// monitored process is the gateway daemon, which never exits (#364).
    nonisolated static func isStaleIdleSession(
        idleMinutes: Int,
        userTimeoutMinutes: Int,
        hasMonitor: Bool,
        hermesChatElsewhere: Bool
    ) -> Bool {
        if userTimeoutMinutes > 0 && idleMinutes >= userTimeoutMinutes { return true }
        let livesWithItsProcess = hasMonitor && !hermesChatElsewhere
        return !livesWithItsProcess && idleMinutes >= defaultStaleIdleMinutes
    }

    nonisolated static func isDaemonBackedSource(_ source: String?) -> Bool {
        guard let normalized = SessionSnapshot.normalizedSupportedSource(source) else { return false }
        return daemonBackedSources.contains(normalized)
    }

    private func cleanupIdleSessions() {
        // 1. Verify monitored PIDs are still alive (DispatchSource can silently miss exits)
        //    Also kill orphaned processes (ppid <= 1, terminal closed but process survived).
        let sweep = processMonitor.sweep()
        let orphaned = sweep.reparented.filter {
            shouldTerminateOrphanedProcess(sessionId: $0.sessionId, pid: $0.pid)
        }
        for (sessionId, process) in sweep.exited {
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
        //    Claude Desktop Cowork cards are skipped too and settled on their own
        //    clock right after: their session store stays silent through a long
        //    tool run and for as long as a permission card is left open.
        for (key, session) in sessions
            where !processMonitor.isWatching(key)
            && session.status != .idle
            && !session.isRemote
            && !key.hasPrefix(Self.coworkSessionPrefix) {
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
        settleCoworkCards()

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
            // Daemon-backed agents settle on their own timeout whether or not we
            // hold a process monitor: their backend never exits, so a live PID
            // says nothing about whether the turn is over (#303).
            if Self.isDaemonBackedSource(session.source) {
                if elapsed > Self.daemonTurnSettleTimeout {
                    sessions[key]?.status = .idle
                }
                continue
            }
            guard processMonitor.isWatching(key) else { continue }
            // Native apps write transcripts synchronously — if the transcript check below
            // didn't find a stop marker after 30s, the session is almost certainly idle.
            if session.isNativeAppMode, elapsed > nativeAppThinkingTimeout {
                sessions[key]?.status = .idle
                continue
            }
            // Before that, the turn's end in its transcript settles it: read
            // off the main actor, applied when the read lands.
            if session.isNativeAppMode, elapsed >= codexTerminalTurnSettleTime {
                checkNativeAppTurnEnded(sessionId: key, session: session, settleTime: codexTerminalTurnSettleTime)
                continue
            }
            if elapsed > monitoredThinkingTimeout {
                sessions[key]?.status = .idle
            }
        }

        // 3. Verify PID liveness for sessions without monitors but with a known PID.
        //    If the process died: idle sessions are removed directly (no grace needed),
        //    non-idle sessions go through handleProcessExit for the 5s grace period.
        for (key, session) in sessions where !processMonitor.isWatching(key) {
            guard let process = resolvedSessionProcessIdentity(for: key) else { continue }
            if !ProcessTable.isLiveProcess(process) {
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
        discovery.pollCodexDesktopIfDue(now: Date(), runningBundleIdentifiers: runningBundleIds)

        // 4. Remove idle sessions past timeout (user setting, or 10 min default for no-monitor sessions)
        let userTimeout = SettingsManager.shared.sessionTimeout
        for (key, session) in sessions where session.status == .idle {
            let idleMinutes = Int(-session.lastActivity.timeIntervalSinceNow / 60)
            if Self.isStaleIdleSession(
                idleMinutes: idleMinutes,
                userTimeoutMinutes: userTimeout,
                hasMonitor: processMonitor.isWatching(key),
                hermesChatElsewhere: session.hermesChatElsewhere
            ) {
                removeSession(key)
            }
        }

        // 4b. AiWork sessions come from the Agentix daemon's persistent session
        //     store, which keeps every conversation as status:"active" forever and
        //     never emits a close/delete event. A finished turn or an exited TUI/GUI
        //     conversation just goes idle, so without this it would sit here for the
        //     full 10-min no-monitor timeout (Section 4) — completed eval bursts pile
        //     up in the notch. Backfill already treats idle AiWork entries as
        //     historical and skips them, so mirror that: drop an idle AiWork session
        //     shortly after its last activity. Live turns bump lastActivity on every
        //     stream event, so an in-use conversation is never swept mid-thought and
        //     re-appears the moment the next turn starts.
        let aiworkIdleGrace: TimeInterval = 60
        for (key, session) in sessions
            where key.hasPrefix(AppState.aiworkSessionPrefix)
            && session.status == .idle {
            guard -session.lastActivity.timeIntervalSinceNow > aiworkIdleGrace else { continue }
            if let daemonId = session.providerSessionId {
                forgetAiWorkHydrateState(daemonId)
            }
            removeSession(key)
        }

        // 5. Reclaim memory for abandoned tool_use_id cache entries.
        prunePendingToolUses()

        refreshDerivedState()
    }

    /// Settle a native app's thinking card idle once its transcript shows
    /// the turn ended after the card's last activity. The cleanup tick asks
    /// every 3 s while the card thinks, and the read opens the state database
    /// and reads the transcript's tail, so it runs off the main actor; the
    /// card is settled when it lands if it is still the same quiet,
    /// monitored, thinking card.
    func checkNativeAppTurnEnded(sessionId: String, session: SessionSnapshot, settleTime: TimeInterval) {
        guard nativeAppTurnReadsInFlight.insert(sessionId).inserted else { return }
        let read = storeReaders.nativeAppFinishedTurn
        Task.detached(priority: .utility) { [weak self] in
            let finishedAt = read(sessionId, session)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.nativeAppTurnReadsInFlight.remove(sessionId)
                guard let finishedAt,
                      let current = self.sessions[sessionId],
                      current.status == .processing,
                      current.currentTool == nil,
                      current.toolDescription == nil,
                      current.isNativeAppMode,
                      !Self.isDaemonBackedSource(current.source),
                      self.processMonitor.isWatching(sessionId),
                      -current.lastActivity.timeIntervalSinceNow >= settleTime,
                      finishedAt >= current.lastActivity.addingTimeInterval(-1) else { return }
                self.sessions[sessionId]?.status = .idle
                self.refreshDerivedState()
            }
        }
    }

    /// Agent Sub-Sessions as set now; an unknown setting reads as Show
    /// separately, the default (HookServer routes hooks by the same reading).
    nonisolated static func currentPluginSessionMode() -> SubsessionMode {
        SubsessionMode(
            setting: UserDefaults.standard.string(forKey: SettingsKey.pluginSessionMode)
                ?? SettingsDefaults.pluginSessionMode
        )
    }

    // MARK: - Process Monitoring (DispatchSource)

    private func currentSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let pid = sessions[sessionId]?.cliPid, pid > 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: sessions[sessionId]?.cliStartTime)
    }

    private func resolvedSessionProcessIdentity(for sessionId: String) -> ProcessIdentity? {
        guard let process = currentSessionProcessIdentity(for: sessionId) else { return nil }
        if let resolved = ProcessTable.trackedProcessIdentity(for: process.pid, source: sessions[sessionId]?.source) {
            if resolved != process {
                setSessionProcessIdentity(resolved, for: sessionId)
            }
            return resolved
        }
        if process.startTime != nil { return process }
        guard let refreshed = ProcessTable.liveProcessIdentity(for: process.pid) else { return process }
        setSessionProcessIdentity(refreshed, for: sessionId)
        return refreshed
    }

    /// A remote session's agent runs on its own host: no process here is
    /// ever its own, to watch or to signal.
    private func setSessionProcessIdentity(_ process: ProcessIdentity, for sessionId: String) {
        guard sessions[sessionId]?.isRemote != true else { return }
        sessions[sessionId]?.cliPid = process.pid
        sessions[sessionId]?.cliStartTime = process.startTime
    }

    private func shouldTerminateOrphanedProcess(sessionId: String, pid: pid_t) -> Bool {
        Self.shouldTerminateOrphanedProcess(session: sessions[sessionId], pid: pid)
    }

    /// cleanupIdleSessions' orphan filter: whether a watched process its
    /// parent left (`SessionProcessMonitor.isReparentedOrphan`) is SIGTERMed.
    /// Never one running Claude Code's binary as anything but its CLI — a
    /// grep its shell ran, its terminal host or a spare worker its own
    /// supervisor reaps — however the process came to be watched.
    nonisolated static func shouldTerminateOrphanedProcess(
        session: SessionSnapshot?,
        pid: pid_t,
        executablePath: (pid_t) -> String? = { ProcessTable.executablePath(for: $0) },
        arguments: (pid_t) -> [String]? = { ProcessTable.getProcessArgs($0) }
    ) -> Bool {
        if AgentProcessFinder.isClaudeCodeNonCLIProcess(pid, executablePath: executablePath, arguments: arguments) {
            return false
        }
        guard let session else { return true }
        if session.isNativeAppMode || session.isRemote { return false }
        guard let source = SessionSnapshot.normalizedSupportedSource(session.source) else { return true }
        return !AgentProcessFinder.isNativeAppProcess(pid, source: source, executablePath: executablePath)
    }

    /// Watch a Claude process for exit — waits a grace period before removing, in case the
    /// process restarts (e.g. auto-update) or a new hook event re-activates the session.
    private func monitorProcess(sessionId: String, pid: pid_t) {
        guard let process = ProcessTable.liveProcessIdentity(for: pid) else {
            handleProcessExit(sessionId: sessionId, exitedProcess: ProcessIdentity(pid: pid, startTime: nil))
            return
        }
        monitorProcess(sessionId: sessionId, process: process)
    }

    private func monitorProcess(sessionId: String, process: ProcessIdentity) {
        guard sessions[sessionId]?.isRemote != true else { return }
        let attached = processMonitor.watch(sessionId: sessionId, process: process) { [weak self] in
            guard let self = self, self.sessions[sessionId] != nil else { return }
            self.handleProcessExit(sessionId: sessionId, exitedProcess: process)
        }
        guard attached else { return }
        exitingSessions.removeValue(forKey: sessionId)

        // Keep cliPid aligned with the monitored process unless we already have a different
        // live PID from a stronger source (hooks beat heuristic discovery).
        if let currentProcess = resolvedSessionProcessIdentity(for: sessionId) {
            if !ProcessTable.isLiveProcess(currentProcess) || currentProcess.pid == process.pid {
                setSessionProcessIdentity(process, for: sessionId)
            }
        } else {
            setSessionProcessIdentity(process, for: sessionId)
        }

        // Safety: if process already exited before monitor started
        if !ProcessTable.isLiveProcess(process) {
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
           currentProcess != exitedProcess, ProcessTable.isLiveProcess(currentProcess) {
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
            if self.processMonitor.isWatching(sessionId) { return }

            // Session was taken over by a different process (e.g. auto-update/restart):
            // cliPid changed to a new PID that's still alive → attach monitor, don't remove.
            if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
               currentProcess != exitedProcess, ProcessTable.isLiveProcess(currentProcess) {
                self.monitorProcess(sessionId: sessionId, process: currentProcess)
                return
            }

            // Original process confirmed dead — remove regardless of lastActivity.
            // This prevents a race where an in-flight hook event (e.g. "Stop") updates
            // lastActivity after exitTime, causing the session to linger for 10+ minutes.
            if !ProcessTable.isLiveProcess(exitedProcess) {
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
        processMonitor.stop(sessionId)
    }

    /// Remove a session, clean up its monitor, and resume any pending continuations.
    /// Every removal path (cleanup timer, process exit, reducer effect) goes through here
    /// so leaked continuations / connections are impossible. Atomic batch removals defer
    /// derived-state work with `refresh: false`, then refresh once after the whole group is gone.
    func removeSession(_ sessionId: String, refresh: Bool = true) {
        let displayOnlyWaitBefore = displayOnlyWaitKind(forSession: sessionId)
        // Resume ALL pending continuations for this session
        drainPermissions(forSession: sessionId, reason: "removeSession")
        drainQuestions(forSession: sessionId, reason: "removeSession")

        completionQueue.removeAll { $0 == sessionId }
        if surface.sessionId == sessionId {
            autoCollapseTask?.cancel()
            if case .completionCard = surface {
                // The turn on this card belongs to a session that is going
                // away: nothing is left on it to read, pointer on it or not.
                completionHasBeenEntered = false
                deferCollapseOnMouseLeave = false
                showNextCompletionOrCollapse()
            } else {
                _ = showNextPending()
            }
        }
        // An AiWork card that comes back is hydrated (title, folder, client)
        // again, whichever way it went — not only through the AiWork sweeps.
        if sessionId.hasPrefix(Self.aiworkSessionPrefix) {
            forgetAiWorkHydrateState(
                sessions[sessionId]?.providerSessionId ?? String(sessionId.dropFirst(Self.aiworkSessionPrefix.count))
            )
        }
        sessions.removeValue(forKey: sessionId)
        noteDisplayOnlyWait(sessionId: sessionId, was: displayOnlyWaitBefore)
        stopMonitor(sessionId)
        detachTranscriptTailer(sessionId: sessionId)
        exitingSessions.removeValue(forKey: sessionId)
        modelReadRetryAt.removeValue(forKey: sessionId)
        subagentModelObservations.removeValue(forKey: sessionId)
        subagentModelReads.removeValue(forKey: sessionId)
        hermesStoreReads.removeValue(forKey: sessionId)
        hostHarnessProbes.removeValue(forKey: sessionId)
        hostHarnessProbeRetryAt.removeValue(forKey: sessionId)
        claudeTerminalProbes.removeValue(forKey: sessionId)
        if activeSessionId == sessionId {
            activeSessionId = mostActiveSessionId()
        }
        if refresh {
            startRotationIfNeeded()
            refreshDerivedState()
            scheduleSave()
        }
    }

    /// Parent/child cards form one removal unit. Any live work or pending
    /// interaction retains the whole connected group.
    var idleSessionRemovalSelection: IdleSessionRemovalSelection {
        let blocked = Set(permissionQueue.map { $0.event.sessionId ?? "default" }
            + questionQueue.map { $0.event.sessionId ?? "default" })
        return IdleSessionRemovalPolicy.selection(sessions: sessions, blockedSessionIDs: blocked)
    }

    func validatedIdleSessionRemovalSelection(
        _ requested: IdleSessionRemovalSelection
    ) -> IdleSessionRemovalSelection {
        // Preserve only exact groups captured when confirmation opened. A new child or a status
        // change retains the original group, while unrelated sessions that later become idle stay put.
        let current = idleSessionRemovalSelection
        let requestedGroups = Set(requested.groups)
        return IdleSessionRemovalSelection(groups: current.groups.filter(requestedGroups.contains))
    }

    /// The header button: ask to confirm removing the idle cards it would
    /// remove now — or, with the banner up, put the banner away. A request
    /// with nothing left to show (its cards came back) counts as no banner.
    func toggleIdleSessionRemovalRequest() {
        if pendingIdleSessionRemoval != nil {
            idleSessionRemovalRequest = nil
            return
        }
        let selection = surface == .sessionList ? idleSessionRemovalSelection : .empty
        idleSessionRemovalRequest = selection.isEmpty ? nil : selection
    }

    /// What the banner offers to remove right now: the request's groups that
    /// are still removable exactly as they were. nil: no banner.
    var pendingIdleSessionRemoval: IdleSessionRemovalSelection? {
        guard let request = idleSessionRemovalRequest else { return nil }
        let current = validatedIdleSessionRemovalSelection(request)
        return current.isEmpty ? nil : current
    }

    func confirmIdleSessionRemoval() {
        guard let request = idleSessionRemovalRequest else { return }
        idleSessionRemovalRequest = nil
        removeIdleSessions(selection: request)
    }

    func cancelIdleSessionRemoval() {
        idleSessionRemovalRequest = nil
    }

    func removeIdleSessions(selection requested: IdleSessionRemovalSelection? = nil) {
        let selection = requested.map(validatedIdleSessionRemovalSelection) ?? idleSessionRemovalSelection
        guard !selection.isEmpty else { return }
        let now = Date()
        for group in selection.groups {
            for id in group {
                manuallyRemovedSessions[id] = now
                manuallyRemovedSessionPeers[id] = group
            }
            for id in group.sorted() {
                followUps.completionSeen(sessionId: id)
                removeSession(id, refresh: false)
            }
        }
        // Tombstones need only cover recent passive callbacks and must not grow for the app's lifetime.
        if manuallyRemovedSessions.count > 1024 {
            let oldest = manuallyRemovedSessions.sorted { $0.value < $1.value }
                .prefix(manuallyRemovedSessions.count - 1024)
            for entry in oldest {
                manuallyRemovedSessions.removeValue(forKey: entry.key)
                manuallyRemovedSessionPeers.removeValue(forKey: entry.key)
            }
        }
        startRotationIfNeeded()
        refreshDerivedState()
        scheduleSave()
    }

    /// Whether an input may bring back a card the user removed. Any input may
    /// for a card that was not removed. A removed card comes back — its whole
    /// group with it — for work; passive input (a store snapshot, a hook
    /// trailing the finished turn, a delayed read) leaves it away, and so does
    /// work observed (`observedAt`) no later than the removal: a scan that
    /// started before the click.
    ///
    /// A card back on the island by any other way (a fold creating its parent,
    /// a request) makes the tombstone moot: its later hooks must reach it.
    @discardableResult
    func shouldAdmitRemovedSession(
        _ sessionId: String,
        evidence: RemovedSessionRevivalEvidence,
        observedAt: Date? = nil
    ) -> Bool {
        guard let removedAt = manuallyRemovedSessions[sessionId] else { return true }
        if sessions[sessionId] == nil {
            switch evidence {
            case .passive:
                return false
            case .activeWork:
                if let observedAt, observedAt <= removedAt { return false }
            case .blockingRequest:
                break
            }
        }
        let group = manuallyRemovedSessionPeers[sessionId] ?? [sessionId]
        for member in group {
            manuallyRemovedSessions.removeValue(forKey: member)
            manuallyRemovedSessionPeers.removeValue(forKey: member)
        }
        return true
    }

    /// A request an agent blocks on — a permission, a question — always
    /// surfaces, on a removed card too: it brings the card's group back.
    func reviveRemovedSession(_ sessionId: String) {
        shouldAdmitRemovedSession(sessionId, evidence: .blockingRequest)
    }

    // MARK: - Compact bar mascot rotation

    private func startRotationIfNeeded() {
        // When rotation stops, ensure activeSessionId points to the remaining
        // active session (if any) so the collapsed bar doesn't stick on an idle one.
        if let active = rotation.update(sessions: sessions),
           activeSessionId != active {
            activeSessionId = active
        }
    }

    /// Start monitoring the CLI process for a session.
    /// Prefers the PID captured by the bridge (_ppid), falls back to source-aware process scans by CWD.
    private func tryMonitorSession(_ sessionId: String) {
        guard sessions[sessionId]?.isRemote != true else { return }
        // An isolated run watches no process: the pids its hooks name are this
        // Mac's real agents, which an orphan sweep could otherwise signal.
        guard !RuntimeEnvironment.isIsolated else { return }
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
        let currentMonitor = processMonitor.watchedProcess(for: sessionId)

        // Primary: use PID from bridge (works for any CLI)
        if let sessionProcess = resolvedSessionProcessIdentity(for: sessionId),
           ProcessTable.isLiveProcess(sessionProcess) {
            if backfillClaudeTerminalMetadata(sessionId: sessionId, process: sessionProcess) {
                scheduleSave()
            }
            if currentMonitor == sessionProcess { return }
            if currentMonitor != nil {
                stopMonitor(sessionId)
            }
            monitorProcess(sessionId: sessionId, process: sessionProcess)
            return
        }

        if let currentMonitor, ProcessTable.isLiveProcess(currentMonitor) {
            setSessionProcessIdentity(currentMonitor, for: sessionId)
            if backfillClaudeTerminalMetadata(sessionId: sessionId, process: currentMonitor) {
                scheduleSave()
            }
            return
        }

        // Fallback: scan for matching processes by CWD (source-aware)
        guard let cwd = sessions[sessionId]?.cwd else { return }
        let source = sessions[sessionId]?.source
        Task.detached {
            let pid = AgentProcessFinder.findPidForCwd(cwd, source: source)
            await MainActor.run { [weak self] in
                guard let self = self, let pid = pid,
                      self.sessions[sessionId] != nil else { return }
                guard let discoveredProcess = ProcessTable.liveProcessIdentity(for: pid) else { return }

                let preferredProcess: ProcessIdentity
                if let currentProcess = self.resolvedSessionProcessIdentity(for: sessionId),
                   ProcessTable.isLiveProcess(currentProcess) {
                    preferredProcess = currentProcess
                } else {
                    preferredProcess = discoveredProcess
                    self.setSessionProcessIdentity(discoveredProcess, for: sessionId)
                }

                if self.backfillClaudeTerminalMetadata(sessionId: sessionId, process: preferredProcess) {
                    self.scheduleSave()
                }
                if let monitorProcess = self.processMonitor.watchedProcess(for: sessionId),
                   monitorProcess == preferredProcess, ProcessTable.isLiveProcess(monitorProcess) {
                    return
                }

                if self.processMonitor.isWatching(sessionId) {
                    self.stopMonitor(sessionId)
                }
                self.monitorProcess(sessionId: sessionId, process: preferredProcess)
            }
        }
    }

    typealias CompletionStyle = CodeIslandCore.CompletionStyle

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

    /// Announce a finished turn the way `AttentionPolicy` decided: the card's
    /// ERROR mark (`turnFailed`: a StopFailure, a failed AiWork stream or
    /// Cowork turn), the follow-up, then the completion card or the glance dot.
    func announceCompletion(_ decision: AttentionDecision, sessionId: String) {
        guard let completion = decision.completion else { return }
        // The session card reads ERROR until the next prompt.
        sessions[sessionId]?.lastTurnFailed = completion.turnFailed
        if case .trackCompletion(let turnFailed)? = decision.followUp {
            followUps.trackCompletion(sessionId: sessionId, turnFailed: turnFailed)
        }
        switch completion.presentation {
        case .statusOnly:
            // Panel stays compact — status indicators still update, but no
            // completion card pops down (#146).
            return
        case .glance:
            flashGlanceCompletionIndicator()
            return
        case .card:
            // Don't queue duplicates
            if completionQueue.contains(sessionId) || justCompletedSessionId == sessionId { return }

            // Already showing one, or one is on its way out of the queue —
            // queue this for later
            if isShowingCompletion || isShowingInteractive || queuedCompletionLookingAtTab != nil {
                completionQueue.append(sessionId)
            } else {
                // Show immediately
                showCompletion(sessionId)
            }
        }
    }

    /// Prewarm at launch so the footer doesn't pop in (and shift panel height)
    /// on the first expansion.
    func refreshClaudeUsageIfStale() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.showUsageStats) else { return }
        guard !Self.usageScanInFlight else { return }
        if let scannedAt = claudeUsage?.scannedAt, Date().timeIntervalSince(scannedAt) < 120 { return }
        Self.usageScanInFlight = true
        let cacheCopy = usageFileCache
        Task.detached(priority: .utility) {
            var cache = cacheCopy
            let snapshot = ClaudeUsageScanner.scan(claudeHomes: ClaudeConfigPaths.allConfigDirs(), cache: &cache)
            // Bound to a `let` before the hop: capturing the `var` in the
            // concurrently-executing closure is an error under Swift 6.
            let scannedCache = cache
            await MainActor.run { [weak self] in
                self?.claudeUsage = snapshot
                self?.usageFileCache = scannedCache
                AppState.usageScanInFlight = false
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

    /// Last conclusive host-harness probe per session, keyed to the CLI pid it
    /// walked. A SessionStart rebuilds the snapshot; the cache lets the result
    /// be re-applied without walking the ancestry again. (#321)
    private var hostHarnessProbes: [String: (pid: pid_t, harness: HostHarness?)] = [:]
    private var hostHarnessProbesInFlight: Set<String> = []
    /// Throttle for probes that could not read the process (it had already
    /// exited, or the pid is a short-lived hook shell) — retried, not cached.
    private var hostHarnessProbeRetryAt: [String: Date] = [:]
    /// The Claude process whose environment `backfillClaudeTerminalMetadata`
    /// already read, per session. tryMonitorSession runs on every hook event
    /// and discovery scan, and an environment is fixed at exec, so one read
    /// per process is all there is to learn.
    @ObservationIgnored
    var claudeTerminalProbes: [String: ProcessIdentity] = [:]

    /// Detect a UI harness (T3 Code) in the CLI's ancestry, off the main actor.
    /// Runs once per CLI pid; remote sessions never probe the local process table.
    private func maybeResolveHostHarness(for sessionId: String) {
        guard let session = sessions[sessionId],
              !session.isRemote,
              let pid = session.cliPid, pid > 1 else { return }
        if let cached = hostHarnessProbes[sessionId], cached.pid == pid {
            if session.hostHarness != cached.harness {
                sessions[sessionId]?.hostHarness = cached.harness
            }
            return
        }
        guard !hostHarnessProbesInFlight.contains(sessionId),
              Date() >= hostHarnessProbeRetryAt[sessionId] ?? .distantPast else { return }
        hostHarnessProbesInFlight.insert(sessionId)
        Task.detached(priority: .utility) {
            let result = HostHarnessSupport.probe(cliPid: pid)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.hostHarnessProbesInFlight.remove(sessionId)
                guard self.sessions[sessionId]?.cliPid == pid else { return }
                if result.conclusive {
                    self.hostHarnessProbes[sessionId] = (pid, result.harness)
                    self.hostHarnessProbeRetryAt.removeValue(forKey: sessionId)
                } else {
                    self.hostHarnessProbeRetryAt[sessionId] = Date().addingTimeInterval(10)
                }
                if self.sessions[sessionId]?.hostHarness != result.harness {
                    self.sessions[sessionId]?.hostHarness = result.harness
                }
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

    /// The question counterpart of `autoExpandOnPermission`. Questions never
    /// honoured that switch — an AskUserQuestion card opened even when the
    /// user had asked the island not to steal focus. With this off the sound
    /// still plays, the collapsed bar shows a question badge, and one click
    /// (on the bar, or "Answer" in the session list) opens the card.
    static func autoExpandOnQuestion(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.autoExpandOnQuestion) != nil else {
            return SettingsDefaults.autoExpandOnQuestion
        }
        return defaults.bool(forKey: SettingsKey.autoExpandOnQuestion)
    }

    /// Session of a queued question the island is not showing — what the
    /// collapsed bar's question badge advertises and a click opens.
    var hiddenPendingQuestionSessionId: String? {
        // A question still waiting to be seen comes before one the user closed.
        guard let head = nextVisibleQuestion ?? questionQueue.first else { return nil }
        if case .questionCard = surface { return nil }
        return head.event.sessionId ?? "default"
    }

    /// Open the card for a pending question on an explicit user action (a click
    /// on the collapsed bar, "Answer" in the session list). Never gated by
    /// auto-expand or Smart Suppress: those only decide what opens *by itself*.
    func openPendingQuestionCard(sessionId: String? = nil) {
        guard let sid = sessionId ?? hiddenPendingQuestionSessionId,
              let request = pendingQuestion(forSession: sid) else { return }
        // Opening it again takes back a close: it is on screen, so it may
        // stay up and remind like any other waiting question.
        dismissedQuestionIds.remove(request.id)
        activeSessionId = sid
        withAnimation(NotchAnimation.open) {
            surface = .questionCard(sessionId: sid)
        }
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

    /// Smart Suppress for a question: may its card open by itself, as far as
    /// "is the user already looking at the agent" goes? The "auto-expand on
    /// question" switch is a separate, UI-only choice checked where the card
    /// opens; folded in here, it read as "the user is looking" to anything
    /// else that asked (the AskUserQuestion push once did).
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

    /// Fast app-level suppress check (main-thread safe, no blocking): Smart
    /// Suppress is on and the session's own terminal is in front.
    private func shouldSuppressAppLevel(for sessionId: String) -> Bool {
        !shouldAutoOpenPendingSurface(for: sessionId)
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
        let delay = completionAutoCollapseDelay
        autoCollapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            showNextCompletionOrCollapse()
        }
    }

    func cancelCompletionQueue() {
        autoCollapseTask?.cancel()
        completionQueue.removeAll()
        queuedCompletionLookingAtTab = nil
        deferCollapseOnMouseLeave = false
    }

    private func showNextCompletionOrCollapse() {
        // Once the mouse has entered the completion card, defer collapse until it leaves
        if completionHasBeenEntered {
            deferCollapseOnMouseLeave = true
            return
        }
        // Interactive items first, then the next finished turn, then collapse.
        if showNextPending() || showNextQueuedCompletion() { return }
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
        // A banner whose cards all came back to life asks nothing any more:
        // it must not reappear if they go idle again later.
        if idleSessionRemovalRequest != nil, pendingIdleSessionRemoval == nil {
            idleSessionRemovalRequest = nil
        }
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

        readProviderTitle(
            ProviderTitleLookup(sessionId: lookupSessionId, provider: session.source, cwd: session.cwd),
            for: trackedSessionId
        )
    }

    /// A card's title read in flight, and the newest lookup asked for while
    /// it ran.
    private struct ProviderTitleRead {
        var next: ProviderTitleLookup?
    }

    @ObservationIgnored
    private var providerTitleReads: [String: ProviderTitleRead] = [:]
    /// Per card, bumped when a title arrives from elsewhere (Codex's
    /// `thread/started`): a store read started before then is stale.
    @ObservationIgnored
    private var providerTitleGenerations: [String: Int] = [:]

    /// Look a card's title up in its provider's store, off the main actor:
    /// every Claude and Codex hook asks, and the lookup reads a file (Codex's
    /// whole thread index, the head and tail of a Claude transcript). One read
    /// per card at a time. What a read finds is applied when it lands (unless
    /// a newer title came from elsewhere meanwhile), then the newest lookup
    /// asked for during it runs.
    private func readProviderTitle(_ lookup: ProviderTitleLookup, for cardId: String) {
        if providerTitleReads[cardId] != nil {
            providerTitleReads[cardId]?.next = lookup
            return
        }
        providerTitleReads[cardId] = ProviderTitleRead()
        let generation = providerTitleGenerations[cardId, default: 0]
        let read = storeReaders.title
        Task.detached(priority: .userInitiated) { [weak self] in
            let resolved = read(lookup)
            await MainActor.run { [weak self] in
                guard let self else { return }
                let next = self.providerTitleReads.removeValue(forKey: cardId)?.next
                if self.providerTitleGenerations[cardId, default: 0] == generation {
                    self.applyProviderTitle(resolved, to: cardId)
                }
                if let next {
                    self.readProviderTitle(next, for: cardId)
                }
            }
        }
    }

    /// A title the store has replaces the card's. A store with none says
    /// nothing: the card keeps a title a hook (`session_title`), Codex
    /// (`thread/started`) or Agent Sub-Sessions (a child's nickname) gave it.
    private func applyProviderTitle(_ resolved: ResolvedSessionTitle?, to cardId: String) {
        guard let resolved, let session = sessions[cardId],
              session.sessionTitle != resolved.title
                || session.sessionTitleSource != resolved.source else { return }
        sessions[cardId]?.sessionTitle = resolved.title
        sessions[cardId]?.sessionTitleSource = resolved.source
        scheduleSave()
        refreshDerivedState()
    }

    /// The card just got a title from Codex itself, newer than anything a
    /// store read in flight for it can find: those reads are dropped.
    func invalidateProviderTitleReads(for cardId: String) {
        providerTitleGenerations[cardId, default: 0] += 1
    }

    func handleEvent(_ event: HookEvent) {
        // Cursor ran both of CodeIsland's hooks for this step: the second copy
        // is the same prompt or finished turn, not another one to chime for.
        if let digest = event.rawJSON[CursorHookPayload.digestKey] as? String,
           cursorHookDeliveries.isRepeat(digest: digest, now: Date()) {
            return
        }

        // Skip events from subagent worktrees — tracked via parent's SubagentStart/Stop
        if let cwd = event.rawJSON["cwd"] as? String,
           cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-") {
            return
        }

        let source = event.rawJSON["_source"] as? String
        let hasTranscriptPath = (event.rawJSON["transcript_path"] as? String)
            .map { !$0.isEmpty } ?? false
        if CodexDiscovery.isCodexPlaceholderHook(
            source: source,
            cwd: event.rawJSON["cwd"] as? String,
            hasTranscriptPath: hasTranscriptPath
        ) {
            return
        }

        let sessionId = event.sessionId ?? "default"
        let normalizedEventName = EventNormalizer.normalize(event.eventName)
        // Claude Code compacting a finished session in the background: no
        // card to open again, none to wake — not by its PreCompact, nor by
        // the stop of the agent writing the summary or the restart from it.
        // Before the removed-card check: none of it is the user's session
        // waking, so a card the user removed stays removed (#385).
        if backgroundCompactions.absorbs(event, session: sessions[sessionId], now: Date()) {
            return
        }

        guard shouldAdmitRemovedSession(
            sessionId,
            evidence: .forHookEvent(event, normalizedEventName: normalizedEventName)
        ) else { return }

        // Account chatter, not session activity. CodeBuddy fires
        // Notification(auth_success) as the CLI boots — before SessionStart and
        // under a different session id — which minted a second card that then
        // never updated (#288).
        if normalizedEventName == "Notification",
           Self.isAccountNotification(event) {
            return
        }

        if shouldDropEventForSupersededGrokSession(
            sessionId: sessionId,
            normalizedEventName: normalizedEventName
        ) {
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
        let displayOnlyWaitBefore = displayOnlyWaitKind(forSession: sessionId)
        let cwdBeforeReduce = sessions[sessionId]?.cwd

        // Cache PreToolUse payloads so downstream events sharing tool_use_id can be
        // correlated, and drain queue entries whose agent already moved on.
        cachePreToolUseIfApplicable(event)
        // #216: permission requests with no correlatable tool_use_id can't be drained by
        // resolveToolUseIfCompleted. A later step of the agent that asked means it was
        // answered in the terminal: its card goes, answered with no decision — never allow.
        // Runs first: the step's call is known by its PreToolUse, which
        // resolveToolUseIfCompleted forgets once that call is done.
        resolveOrphanPermissionsOnActivity(event)
        resolveToolUseIfCompleted(event)

        let reduction = reduceHookEvent(sessions: &sessions, event: event, maxHistory: maxHistory,
                                        replyCompletePlaceholder: L10n.shared["reply_complete_placeholder"])
        // Whose turn this was is read off the session as the event left it,
        // before the Cursor fold below can rebrand, fold or drop the card.
        let attentionSubject = AttentionSubject(sessions[sessionId])

        // Cursor Agent Tasks often fire Claude-format hooks without `--source`,
        // leaving ghost Claude cards. Rebrand + fold before the rest of the
        // pipeline treats them as standalone Claude sessions. A Task card the
        // bridge already labelled Cursor still needs its transcript found.
        if sessions.values.contains(where: Self.needsCursorTaskTranscriptLookup) {
            _ = applyCursorSubsessionModeToKnownSessions()
        }

        // After reduce: remoteHostId is authoritative (extractMetadata just ran),
        // so a remote session can never probe the local filesystem here.
        maybeRefreshGitBranch(for: sessionId, cwdBefore: cwdBeforeReduce, normalizedEventName: normalizedEventName)
        maybeResolveHostHarness(for: sessionId)

        // A finished local Claude turn is booked against the plan limits now —
        // the quota monitor coalesces these into at most one fetch a minute.
        if normalizedEventName == "Stop",
           let s = sessions[sessionId], s.isClaude, s.isRemote != true {
            claudeQuota.noteStop()
        }

        // Backfill model after metadata extraction. Hooks are inconsistent across providers,
        // so retry with a cooldown instead of giving up permanently on the first miss.
        if sessions[sessionId]?.isRemote != true {
            maybeBackfillModel(for: sessionId)
            if let agentId = event.agentId {
                maybeBackfillSubagentModel(sessionId: sessionId, agentId: agentId, event: event)
            }
            requestHermesStoreRead(for: sessionId, event: event)
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
        //
        // The sweep only covers questions asked by the same agent as the event.
        // Background subagents share the parent's session_id, so their tool
        // calls and SubagentStop kept arriving while the main thread's question
        // was on screen and denied it ("Permission denied by hook").
        if wasWaiting {
            let keepWaiting: Set<String> = ["Notification", "SessionStart", "SessionEnd", "PreCompact"]
            if !keepWaiting.contains(normalizedEventName) {
                drainQuestions(
                    forSession: sessionId,
                    reason: "wasWaiting-blanket-drain-event=\(normalizedEventName)",
                    where: { $0.agentId == event.agentId }
                )
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
            readCursorYoloMode(for: sessionId)
        }

        // Now that the event has settled: does the user hear about it, and
        // how. One decision, carried out in the order the outlets always ran
        // in — the push, the completion, then the sound.
        //
        // A card the Cursor fold above just moved into its parent's (or
        // dropped) was a Task's: its turn is its parent's business, like a
        // child's — no chime, no completion card for a card that is gone, no
        // push as the user's own turn, nothing to follow up.
        var subject = attentionSubject
        if sessions[sessionId] == nil {
            subject.isChild = true
        }
        let attention = decideAttention(.hookEvent(reduction.facts), sessionId: sessionId, subject: subject)
        if let push = attention.push {
            pushTurnEnded(
                push,
                sessionId: sessionId,
                errorType: reduction.facts.turnError?.type,
                errorDetail: reduction.facts.turnError?.detail
            )
        }
        announceCompletion(attention, sessionId: sessionId)
        for effect in reduction.effects {
            executeEffect(effect, sessionId: sessionId)
        }
        playAttentionSound(attention, sessionId: sessionId)

        if normalizedEventName == "SessionStart" {
            retireGrokSessionsSuperseded(bySessionStartOf: sessionId)
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
            // A Stop keeps its session up for the completion card it pops. A
            // turn end that pops none — a child's (#378), a gateway chat's
            // (#364), one the completion style keeps to the glance dot or to
            // nothing — hands the spot on like any event; so does a child's
            // Stop that ended no turn.
            let poppedCard: Bool
            if case .card? = attention.completion?.presentation { poppedCard = true } else { poppedCard = false }
            let keepsSpot = normalizedEventName == "Stop"
                && (reduction.facts.endedTurn ? poppedCard : !subject.isChild)
            if !keepsSpot {
                activeSessionId = mostActiveSessionId()
            }
        }

        // A terminal permission prompt announced by a Notification waits
        // display-only until the next activity event clears it.
        noteDisplayOnlyWait(
            sessionId: sessionId,
            was: displayOnlyWaitBefore,
            asking: Self.displayOnlyWaitAsk(forHookEvent: event, normalizedEventName: normalizedEventName)
        )

        scheduleSave()
        startRotationIfNeeded()
        refreshDerivedState()
    }

    /// Grok's TUI switches the session it hosts in place (`/resume`, `/new`, a
    /// welcome-screen pick) without any hook for the session it leaves, so
    /// that card stayed alive for as long as the process did (#318). One pager
    /// process can also run several top-level sessions at once (Agent
    /// Dashboard dispatch, `/fork`), so only an idle card — no turn, no
    /// working subagent — counts as superseded. Every other provider keeps its
    /// many-sessions-per-PID model (Codex app-server, IDEs, opencode server).
    nonisolated static func isGrokSessionSupersededBySessionStart(
        candidate: SessionSnapshot,
        candidateId: String,
        started: SessionSnapshot,
        startedId: String
    ) -> Bool {
        guard candidateId != startedId,
              started.source == "grok",
              candidate.source == "grok",
              !started.isRemote,
              !candidate.isRemote,
              let pid = started.cliPid,
              pid > 0,
              candidate.cliPid == pid,
              candidate.status == .idle else {
            return false
        }
        return !candidate.subagents.values.contains { $0.status != .idle }
    }

    private func retireGrokSessionsSuperseded(bySessionStartOf sessionId: String) {
        guard let started = sessions[sessionId],
              started.source == "grok",
              let pid = started.cliPid else { return }
        supersededGrokSessions = supersededGrokSessions.filter { ProcessTable.isLiveProcess($0.value) }

        let superseded = sessions.compactMap { key, candidate -> String? in
            guard Self.isGrokSessionSupersededBySessionStart(
                candidate: candidate,
                candidateId: key,
                started: started,
                startedId: sessionId
            ),
            !permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == key }),
            !questionQueue.contains(where: { ($0.event.sessionId ?? "default") == key }) else {
                return nil
            }
            return key
        }
        guard !superseded.isEmpty else { return }

        let process = ProcessTable.liveProcessIdentity(for: pid) ?? ProcessIdentity(pid: pid, startTime: nil)
        for key in superseded {
            log.info("retiring superseded grok session=\(key, privacy: .public) pid=\(pid, privacy: .public) new=\(sessionId, privacy: .public)")
            supersededGrokSessions[key] = process
            removeSession(key)
        }
    }

    /// A retired Grok session can still emit passive hooks (the `idle_prompt`
    /// Notification about a minute after it settles, the session-end Stop and
    /// SessionEnd when Grok quits). Only generation-start activity revives it.
    private func shouldDropEventForSupersededGrokSession(
        sessionId: String,
        normalizedEventName: String
    ) -> Bool {
        guard let process = supersededGrokSessions[sessionId] else { return false }
        if normalizedEventName == "SessionStart"
            || normalizedEventName == "UserPromptSubmit"
            || !ProcessTable.isLiveProcess(process) {
            supersededGrokSessions.removeValue(forKey: sessionId)
            return false
        }
        return true
    }

    private func isSupersededGrokDiscovery(_ info: DiscoveredSession) -> Bool {
        guard let process = supersededGrokSessions[info.sessionId] else { return false }
        if ProcessTable.isLiveProcess(process) { return true }
        supersededGrokSessions.removeValue(forKey: info.sessionId)
        return false
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
        case .tryMonitorSession(let sid):
            tryMonitorSession(sid)
        case .stopMonitor(let sid):
            stopMonitor(sid)
        case .removeSession(let sid):
            removeSession(sid)
        case .setActiveSession(let sid):
            activeSessionId = sid
        case .playSound, .enqueueCompletion:
            // Attention is AttentionPolicy's to decide; `reduceHookEvent`
            // never emits these (only the `reduceEvent` composition does).
            assertionFailure("\(effect) reached executeEffect: attention goes through AttentionPolicy")
        }
    }

    /// The read walks the card's transcript or session store (a Codex
    /// rollout search, OpenCode's database), so it runs off the main actor,
    /// one at a time per card. A model a hook supplies meanwhile wins.
    private func maybeBackfillModel(for sessionId: String) {
        // A remote session's store and transcript are on its own host.
        guard let session = sessions[sessionId], !session.isRemote, session.model == nil else { return }
        let now = Date()
        if let retryAt = modelReadRetryAt[sessionId], retryAt > now {
            return
        }
        guard modelReadsInFlight.insert(sessionId).inserted else { return }

        let read = storeReaders.model
        Task.detached(priority: .utility) { [weak self] in
            let model = read(sessionId, session)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.modelReadsInFlight.remove(sessionId)
                guard self.sessions[sessionId] != nil else { return }
                if let model {
                    if self.sessions[sessionId]?.model == nil {
                        self.sessions[sessionId]?.model = model
                        self.scheduleSave()
                        self.refreshDerivedState()
                    }
                    self.modelReadRetryAt.removeValue(forKey: sessionId)
                } else {
                    self.modelReadRetryAt[sessionId] = now.addingTimeInterval(5)
                }
            }
        }
    }

    /// Read Cursor's settings for the card's YOLO badge, off the main actor;
    /// once per card (nil = unchecked).
    private func readCursorYoloMode(for sessionId: String) {
        guard let session = sessions[sessionId], session.isYoloMode == nil,
              cursorYoloReadsInFlight.insert(sessionId).inserted else { return }
        let read = storeReaders.cursorYoloMode
        Task.detached(priority: .utility) { [weak self] in
            let yolo = read()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cursorYoloReadsInFlight.remove(sessionId)
                guard self.sessions[sessionId] != nil, self.sessions[sessionId]?.isYoloMode == nil else { return }
                self.sessions[sessionId]?.isYoloMode = yolo
                self.scheduleSave()
                self.refreshDerivedState()
            }
        }
    }

    func handlePermissionRequest(
        _ event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        hookConnectionId: UUID? = nil
    ) {
        let sessionId = event.sessionId ?? "default"
        reviveRemovedSession(sessionId)
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
        // ensureSubagent refusing late tool hooks after Stop). Nor is the request
        // decided: the SubagentStop that closed the id says nothing of what the
        // user would choose — it may have overtaken a request still waiting, and
        // whoever can send a hook can send it — so the agent asks in its own prompt.
        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            continuation.resume(returning: Self.noDecisionAnswer)
            return
        }

        // "Always allow" on an earlier card of this session, for an agent
        // that keeps nothing which stops it asking again (approvePermission):
        // the island answers the request, as that card said it would.
        if sessionAlwaysAllows(event, sessionId: sessionId) {
            continuation.resume(returning: Self.plainAllowAnswer)
            return
        }

        // Clear any pending questions from THIS agent (mutually exclusive within an agent;
        // a background subagent's request must not deny the main thread's question)
        drainQuestions(forSession: sessionId, reason: "newPermissionRequest", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingApproval
        sessions[sessionId]?.currentTool = event.activityLabel
        sessions[sessionId]?.toolDescription = event.toolDescription
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, event: event, status: .waitingApproval)
        // Backfill tool name/description from cached PreToolUse when the payload is thin.
        enrichPermissionRequestFromCache(sessionId: sessionId, event: event)
        // The tool now up is this request's: its own PostToolUse takes it down.
        sessions[sessionId]?.currentToolUseId = event.toolUseId

        let request = PermissionRequest(event: event, continuation: continuation, hookConnectionId: hookConnectionId)

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
        let attention = decideAttention(.approvalQueued(firstOfBurst: !burstAlreadyInProgress), sessionId: sessionId)
        pushPermissionQueued(event, sessionId: sessionId, push: attention.push)

        // Show UI only when no approval card is already up to be stolen from.
        // showNextPending picks the first *visible* request, promotes it to the
        // head and applies the session-list / Smart Suppress rules — pointing
        // the card at this session by hand would show the dismissed request's
        // content whenever a dismissed entry still leads the queue.
        if !approvalCardOnScreen {
            showNextPending()
        }
        playAttentionSound(attention, sessionId: sessionId)
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
    /// ever mirror the head (the hardware Buddy, a companion command that names
    /// no session). (#308)
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
        let responseData = always
            ? alwaysAllowAnswer(for: pending, sessionId: sessionId)
            : Self.plainAllowAnswer
        pending.continuation.resume(returning: responseData)
        resolveMergedSubagentAfterUI(
            sessionId: sessionId,
            agentId: pending.event.agentId,
            subagentStatus: .running,
            keepSubagentTool: pending.event.toolName,
            idleParentWhenNoAgent: false
        )
        if always {
            answerQueuedRequestsCoveredByAlways(sessionId: sessionId)
        }

        showNextPending()
        refreshDerivedState()
    }

    /// The session's requests that were already waiting when the user chose
    /// "Always" on one of them — a parallel call's, a subagent's — and that
    /// the island now holds that "Always" for (sessionAlwaysAllows): answered
    /// as the session's later ones will be, rather than each asking again.
    private func answerQueuedRequestsCoveredByAlways(sessionId: String) {
        let covered = permissionQueue.filter {
            ($0.event.sessionId ?? "default") == sessionId && sessionAlwaysAllows($0.event, sessionId: sessionId)
        }
        guard !covered.isEmpty else { return }
        let ids = Set(covered.map(\.id))
        permissionQueue.removeAll { ids.contains($0.id) }
        for request in covered {
            request.continuation.resume(returning: Self.plainAllowAnswer)
            resolveMergedSubagentAfterUI(
                sessionId: sessionId,
                agentId: request.event.agentId,
                subagentStatus: .running,
                keepSubagentTool: request.event.toolName,
                idleParentWhenNoAgent: false
            )
        }
    }

    /// Allows `pending`, and makes its "Always" hold for what its card said:
    /// in the rule the agent keeps, or — where the agent keeps none that
    /// stops its next request asking — in the session, which the island
    /// answers (sessionAlwaysAllows).
    private func alwaysAllowAnswer(for pending: PermissionRequest, sessionId: String) -> Data {
        let event = pending.event
        if CodexPermissionRules.isCodexEvent(event) {
            // A running Codex never takes in what "Always" saves: it reads
            // ~/.codex/rules and config.toml when a session starts
            // (codex-rs/core/src/session/mod.rs, `ExecPolicyManager::load`;
            // only its own approvals reach the session's policy), and its
            // PermissionRequest output holds nothing beyond this call. The
            // rule stops the sessions Codex starts from now on; this one's
            // next requests come here, and the island answers them as the
            // card said. A remote Codex reads its rules on its own host and
            // none may be written to this Mac's, and a request no rule can
            // describe has none to save: "Always" holds for the session.
            rememberCodexAlways(pending, sessionId: sessionId)
            return Self.plainAllowAnswer
        }
        if Self.agentKeepsAlwaysRule(for: event) {
            return Self.claudeAlwaysAllowResponse(
                toolName: event.toolName ?? "",
                bareToolName: SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) == "minimax"
            )
        }
        if let toolName = event.toolName, !toolName.isEmpty {
            sessions[sessionId]?.alwaysAllowedTools.insert(toolName)
        }
        // This call only. What these agents would make of a rule is not what
        // the card said: nothing at all; only the patterns OpenCode picked,
        // shared by every session in the folder (1.x) or saved to the project
        // for good (2.x); a rule ZCode saves to the project for good. A
        // Codex-family agent (Trae CLI Next) refuses an answer carrying one.
        return Self.plainAllowAnswer
    }

    /// Codex's "Always", as its card's link put it (``PermissionRequest/alwaysScope``):
    /// the rule saved for the sessions Codex starts from now on, and held by
    /// the island for this one.
    private func rememberCodexAlways(_ pending: PermissionRequest, sessionId: String) {
        let event = pending.event
        let toolName = event.toolName ?? ""
        switch pending.alwaysScope {
        case .codexRules(let patterns):
            _ = CodexPermissionRules().persistPrefixRules(patterns, for: event)
            sessions[sessionId]?.alwaysAllowedCommandPrefixes.formUnion(patterns)
        case .codexMCPConfig:
            _ = CodexPermissionRules().persistAlwaysAllowRule(for: event)
            if !toolName.isEmpty { sessions[sessionId]?.alwaysAllowedTools.insert(toolName) }
        case .session:
            if !toolName.isEmpty { sessions[sessionId]?.alwaysAllowedTools.insert(toolName) }
        }
    }

    /// Whether an "Always" the user chose on an earlier card of this session
    /// answers `event` (approvePermission): the tool it named, or — for Codex
    /// — a command each of whose commands starts with words a rule it saved
    /// names. Only the session's own: a subagent filed under it is in it, and
    /// a remote host's sessions are filed under ids of their own.
    private func sessionAlwaysAllows(_ event: HookEvent, sessionId: String) -> Bool {
        guard let session = sessions[sessionId],
              let toolName = event.toolName, !toolName.isEmpty else { return false }
        if session.alwaysAllowedTools.contains(toolName) { return true }
        return CodexPermissionRules.isCodexEvent(event)
            && CodexPermissionRules.commandsStart(event, withAnyOf: session.alwaysAllowedCommandPrefixes)
    }

    /// Whether the agent keeps the rule "Always allow" sends with its answer
    /// for the rest of the session — the tool, every call of it — so that
    /// its later requests for the tool never come here. What it asks after
    /// that is its own call (a protected path, a safety check), for the user
    /// to answer.
    /// - Claude Code adds `updatedPermissions` to the session's rules, where
    ///   `Bash(*)` reads as the bare tool, and a subagent's go into the same
    ///   rules (2.1.312: a subagent's context is handed the session's
    ///   `setSessionToolPermissionContext`).
    /// - Qoder CLI and Qoder CN (`qoder-cli`, 1.1.80) apply them the same
    ///   way, kept in memory for the session.
    /// - MiniMax Code (0.7.1, CodeIsland's pack is a Claude-format plugin)
    ///   keeps a `session` rule in its plugin permission store; its file
    ///   tools match a `ruleContent` as a path, so it gets the bare tool name.
    ///
    /// The rest read one decision from the answer and ask again for the next
    /// call: Gemini CLI (an allow cannot even skip its own confirmation),
    /// Qwen Code (its PermissionRequest result has no field for the rules),
    /// the Qoder IDE and app, Trae CLI, pi, Oh My Pi, OpenClaw, DeepSeek
    /// Harness's plugin, ZCode (which saves the rule to the project, for
    /// good) and OpenCode (which keeps patterns of its own choosing, for
    /// every session in the folder or the project). The island keeps
    /// "Always" for those (sessionAlwaysAllows). Codex is handled on its own
    /// (rememberCodexAlways).
    nonisolated static func agentKeepsAlwaysRule(for event: HookEvent) -> Bool {
        // A hook that names no source is Claude Code's.
        guard let raw = event.rawJSON["_source"] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        switch SessionSnapshot.normalizedSupportedSource(raw) {
        case "claude", "qoder-cli", "minimax": return true
        default: return false
        }
    }

    /// "Always allow" as Claude Code reads it: a session rule for the tool.
    nonisolated static func claudeAlwaysAllowResponse(toolName: String, bareToolName: Bool = false) -> Data {
        // MCP tools (`mcp__server__tool`) don't accept a rule specifier — the
        // rule must be the bare tool name. Sending `ruleContent: "*"` makes
        // Claude Code assemble `mcp__server__tool(*)`, which never matches an
        // actual MCP call, so the "always allow" rule silently fails to
        // persist and the same approval keeps re-prompting. Non-MCP tools
        // (Bash/Read/Edit/…) keep the `*` specifier. (#224)
        var rule: [String: Any] = ["toolName": toolName]
        if !bareToolName, !toolName.hasPrefix("mcp__") {
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
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    nonisolated static func isQoderEvent(_ event: HookEvent) -> Bool {
        guard let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String) else { return false }
        return source == "qoder" || source == "qoder-cli"
    }

    /// `expectedSessionId` is the session the remote surface was showing when
    /// the button was pressed. The hardware Buddy has no session identity to
    /// send and passes nil, keeping its head-of-queue behaviour; the iPhone
    /// does send one, so a tap resolves against the card the user actually saw
    /// — the #308 failure mode, which the panel fixed in #310 but this path
    /// never did. A round trip over Bluetooth makes the race wider here than
    /// it ever was on the panel.
    func handleBuddyControlCommand(_ command: BuddyControlCommand, expectedSessionId: String? = nil) {
        switch command {
        case .approveCurrentPermission:
            if !permissionQueue.isEmpty {
                approvePermission(expectedSessionId: expectedSessionId)
            } else {
                log.info("Ignored Buddy approve command because permission queue is empty")
            }
        case .denyCurrentPermission:
            if !permissionQueue.isEmpty {
                denyPermission(expectedSessionId: expectedSessionId)
            } else {
                log.info("Ignored Buddy deny command because permission queue is empty")
            }
        case .skipCurrentQuestion:
            if !questionQueue.isEmpty {
                skipQuestion(expectedSessionId: expectedSessionId)
            } else {
                log.info("Ignored Buddy skip command because question queue is empty")
            }
        }
    }

    /// See `handleBuddyControlCommand` for why `expectedSessionId` matters.
    func answerCompanionQuestion(_ answer: String, expectedSessionId: String? = nil) {
        guard !questionQueue.isEmpty else {
            log.info("Ignored companion question answer because question queue is empty")
            return
        }
        // Route by the card the phone was showing, which need not be the head:
        // never answer a question the user never read. Gone entirely (answered
        // in the terminal) → answerQuestion discards it and resyncs.
        guard let index = questionIndex(expecting: expectedSessionId) else {
            answerQuestion(answer, expectedSessionId: expectedSessionId)
            return
        }

        // AskUserQuestion is answered one question at a time from the phone.
        // This must run at the addressed index too: answerQuestion() ignores
        // wizard requests, so handing a non-head one to it dropped the answer.
        if questionQueue[index].isFromPermission,
           var askState = questionQueue[index].askUserQuestionState {
            guard let itemIndex = askState.items.firstIndex(where: { askState.answers[$0.answerKey] == nil }) else {
                answerQuestionMulti(askState.items.map {
                    (question: $0.payload.question, answer: askState.answers[$0.answerKey] ?? "")
                }, expectedSessionId: expectedSessionId)
                return
            }

            let item = askState.items[itemIndex]
            askState.answers[item.answerKey] = answer
            questionQueue[index].askUserQuestionState = askState

            if askState.canConfirm {
                answerQuestionMulti(askState.items.map {
                    (question: $0.payload.question, answer: askState.answers[$0.answerKey] ?? "")
                }, expectedSessionId: expectedSessionId)
            } else {
                refreshDerivedState()
            }
            return
        }

        answerQuestion(answer, expectedSessionId: expectedSessionId)
    }

    func findSessionId(providerSessionId: String) -> String? {
        SubsessionCards.cardId(forProviderSessionId: providerSessionId, in: sessions)
    }

    /// Resolve a Codex parent in the same Desktop/CLI namespace as its child.
    /// Raw and `codexapp:` cards may legitimately share a provider thread id
    /// when a user resumes the same thread in both surfaces.
    func findCodexParentSessionId(
        providerSessionId: String,
        childTermBundleId: String?
    ) -> String? {
        SubsessionCards.codexParentCard(
            threadId: providerSessionId,
            childTermBundleId: childTermBundleId,
            in: sessions
        )
    }

    /// What Agent Sub-Sessions needs from the island to route one hook.
    var subsessionContext: AppSubsessionContext {
        AppSubsessionContext(cards: sessions, codexRollouts: codexRollouts)
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

    func handleQuestion(
        _ event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        hookConnectionId: UUID? = nil
    ) {
        let sessionId = event.sessionId ?? "default"
        reviveRemovedSession(sessionId)
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
        drainPermissions(forSession: sessionId, reason: "handleQuestion(Notification)", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, event: event, status: .waitingQuestion)

        let request = QuestionRequest(
            event: event,
            question: question,
            continuation: continuation,
            hookConnectionId: hookConnectionId
        )
        questionQueue.append(request)
        // First of a burst: nothing else visibly waiting. Not `count == 1` —
        // a closed question stays queued, and must not swallow every later
        // question's card and sound (the trap #309 fixed for approvals).
        let firstOfBurst = nextVisibleQuestion?.id == request.id
        let attention = decideAttention(.questionQueued(firstOfBurst: firstOfBurst), sessionId: sessionId)
        pushQuestionQueued(request, sessionId: sessionId, push: attention.push)

        if firstOfBurst {
            activeSessionId = sessionId
            if Self.autoExpandOnQuestion(), shouldAutoOpenPendingSurface(for: sessionId) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
        }
        playAttentionSound(attention, sessionId: sessionId)
        refreshDerivedState()
    }

    func handleAskUserQuestion(
        _ event: HookEvent,
        continuation: CheckedContinuation<Data, Never>,
        hookConnectionId: UUID? = nil
    ) {
        let sessionId = event.sessionId ?? "default"
        reviveRemovedSession(sessionId)
        if sessions[sessionId] == nil {
            sessions[sessionId] = SessionSnapshot()
        }
        if event.agentId == nil {
            extractMetadata(into: &sessions, sessionId: sessionId, event: event)
        } else {
            fillMissingParentMetadataFromSubagentEvent(into: &sessions, sessionId: sessionId, event: event)
        }
        tryMonitorSession(sessionId)

        // As for a closed subagent's permission request: no card, no decision.
        if shouldSuppressClosedSubagentUI(sessionId: sessionId, agentId: event.agentId) {
            continuation.resume(returning: Self.noDecisionAnswer)
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

        drainPermissions(forSession: sessionId, reason: "handleAskUserQuestion", where: { $0.agentId == event.agentId })
        drainQuestions(forSession: sessionId, reason: "handleAskUserQuestion", where: { $0.agentId == event.agentId })

        sessions[sessionId]?.status = .waitingQuestion
        sessions[sessionId]?.lastActivity = Date()
        markMergedSubagentWaiting(sessionId: sessionId, event: event, status: .waitingQuestion)

        let askState = AskUserQuestionState(items: askItems, answers: [:])
        let request = QuestionRequest(
            event: event,
            question: askItems[0].payload,
            continuation: continuation,
            isFromPermission: true,
            askUserQuestionState: askState,
            hookConnectionId: hookConnectionId
        )
        questionQueue.append(request)
        // First of a burst, as in `handleQuestion`.
        let firstOfBurst = nextVisibleQuestion?.id == request.id
        // Smart Suppress alone: whether the island opens the card by itself
        // (the "auto-expand on question" switch) says nothing about whether
        // the person is looking at the question in their terminal.
        let attention = decideAttention(
            .questionQueued(firstOfBurst: firstOfBurst),
            sessionId: sessionId,
            terminalFrontmost: questionTerminalFrontmostDetector
        )
        pushQuestionQueued(request, sessionId: sessionId, push: attention.push)

        if firstOfBurst {
            activeSessionId = sessionId
            if Self.autoExpandOnQuestion(), shouldAutoOpenQuestionSurface(for: event) {
                withAnimation(NotchAnimation.open) {
                    surface = .questionCard(sessionId: sessionId)
                }
            }
        }
        playAttentionSound(attention, sessionId: sessionId)
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
        // Wizard answers are mapped onto items by position below. A set that
        // is not exactly one answer per this request's questions was collected
        // for some other request — delivering it would answer this CLI's
        // question with another session's answer — so it is refused and the
        // request stays waiting. (#333)
        if let askState = questionQueue[index].askUserQuestionState,
           !askState.accepts(answers) {
            let sessionId = questionQueue[index].event.sessionId ?? "default"
            log.notice("⚠️ refused answers for session=\(sessionId, privacy: .public) — \(answers.count, privacy: .public) answer(s) do not match its \(askState.items.count, privacy: .public) question(s)")
            refreshDerivedState()
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
        // Structured picks for plugins that answer with label arrays: OMP/Pi,
        // and OpenCode, whose multi-select answers are `string[]` (v1) or a
        // multiselect form field (v2) — a ", "-joined display string can't be
        // split back when a label itself contains ", " (#332). MiMo Code runs
        // the same plugin against OpenCode 1.x's question API.
        let detailsSource = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
        if !answerDetails.isEmpty,
           (detailsSource == "pi" && event.toolUseId != nil)
            || detailsSource == "opencode" || detailsSource == "mimo" {
            updatedInput["_codeislandAnswerDetails"] = answerDetails
        }
        return updatedInput
    }

    /// Close a question card without answering it. The request stays queued
    /// and the agent keeps waiting: answer it in the terminal, or reopen the
    /// card from the collapsed bar's question badge. Skip, by contrast,
    /// answers — for AskUserQuestion it denies the tool call.
    func dismissQuestion(expectedSessionId: String? = nil) {
        guard let index = questionIndex(expecting: expectedSessionId) else {
            if let expectedSessionId {
                discardStalePanelAction(expected: expectedSessionId, kind: "dismiss")
            }
            return
        }
        dismissedQuestionIds.insert(questionQueue[index].id)

        if case .questionCard = surface {
            withAnimation(NotchAnimation.close) {
                surface = .collapsed
            }
        }
        // Hand the panel to whatever is still visibly waiting, if it may open.
        showNextPending()
        refreshDerivedState()
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

    /// Drain queued permissions for a specific session, answering each with no
    /// decision (``noDecisionAnswer``). The session ending, or its agent asking
    /// something else, says nothing of what the user would choose — and on a
    /// host whose agents run as other users, any of them can send the
    /// SessionEnd: a drain must not decide someone else's request, deny
    /// included. `matches` narrows the drain by the request's event —
    /// background subagents share the parent's session_id, so callers reacting
    /// to one agent pass an agent_id filter.
    private func drainPermissions(
        forSession sessionId: String,
        reason: String = "unknown",
        where matches: (HookEvent) -> Bool = { _ in true }
    ) {
        dismissedPermissionSessionIds.remove(sessionId)
        permissionQueue.removeAll { item in
            guard item.event.sessionId == sessionId, matches(item.event) else { return false }
            log.notice("⚠️ permission dropped, no decision reason=drainPermissions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) toolUseId=\(item.toolUseId ?? "nil", privacy: .public) tool=\(item.event.toolName ?? "nil", privacy: .public)")
            item.continuation.resume(returning: Self.noDecisionAnswer)
            return true
        }
    }

    /// Drains every pending request of one agent in a session, as if all its
    /// hooks had gone at once; another agent's request in the same session
    /// stays. A single hook that goes takes only its own request
    /// (``handleHookGone(connectionId:)``).
    func handlePeerDisconnect(sessionId: String, agentId: String? = nil) {
        let sameAgent: (HookEvent) -> Bool = { $0.sessionId == sessionId && $0.agentId == agentId }
        let hadPending = questionQueue.contains(where: { sameAgent($0.event) })
            || permissionQueue.contains(where: { sameAgent($0.event) })
        guard hadPending else { return }

        drainQuestions(forSession: sessionId, reason: "peer-disconnect", where: sameAgent)
        drainPermissions(forSession: sessionId, reason: "peer-disconnect", where: sameAgent)
        settleAfterWaitEnded(sessionId: sessionId)
    }

    /// A held request's hook is gone — killed, or its agent answered in the
    /// terminal (``HookServer``). The request that hook waited on goes, and
    /// only that one: its session's other requests — a parallel tool call's,
    /// a subagent's — each have a hook of their own still waiting on the
    /// user, and stay answerable.
    func handleHookGone(connectionId: UUID) {
        let sessionId: String
        if let index = permissionQueue.firstIndex(where: { $0.hookConnectionId == connectionId }) {
            let pending = permissionQueue.remove(at: index)
            sessionId = pending.event.sessionId ?? "default"
            log.notice("⚠️ permission deny reason=hookGone session=\(sessionId, privacy: .public) toolUseId=\(pending.toolUseId ?? "nil", privacy: .public) tool=\(pending.event.toolName ?? "nil", privacy: .public)")
            // Nobody reads it, but the continuation must not leak.
            pending.continuation.resume(returning: Data(
                #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
            ))
            // A dismissal goes with the last of the session's requests; the
            // rest stay as the user left them.
            if !permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == sessionId }) {
                dismissedPermissionSessionIds.remove(sessionId)
            }
        } else if let index = questionQueue.firstIndex(where: { $0.hookConnectionId == connectionId }) {
            let pending = questionQueue.remove(at: index)
            sessionId = pending.event.sessionId ?? "default"
            if pending.isFromPermission {
                log.notice("⚠️ permission deny reason=hookGone session=\(sessionId, privacy: .public) tool=AskUserQuestion")
                pending.resolution.resumeHook(returning: Data(
                    #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8
                ))
            } else {
                pending.resolution.resumeHook(returning: Data("{}".utf8))
            }
        } else {
            return  // answered already, or never queued
        }
        settleAfterWaitEnded(sessionId: sessionId)
    }

    /// After a disconnect took requests of `sessionId`: a session that was
    /// waiting waits on what is still queued for it, else goes back to work.
    private func settleAfterWaitEnded(sessionId: String) {
        let currentStatus = sessions[sessionId]?.status
        let wasWaiting = currentStatus == .waitingApproval || currentStatus == .waitingQuestion
        if wasWaiting, permissionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingApproval
        } else if wasWaiting, questionQueue.contains(where: { $0.event.sessionId == sessionId }) {
            sessions[sessionId]?.status = .waitingQuestion
        } else if wasWaiting {
            sessions[sessionId]?.status = .processing
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.toolDescription = nil
        }
        showNextPending()
        refreshDerivedState()
    }

    /// Drain all queued questions for a specific session, deciding none: an
    /// AskUserQuestion-derived request gets no decision (its agent asks in its
    /// own prompt, as ``drainPermissions`` leaves a permission), a
    /// notification question returns empty, and a Codex app-server request is
    /// abandoned.
    private func drainQuestions(
        forSession sessionId: String,
        reason: String = "unknown",
        where matches: (HookEvent) -> Bool = { _ in true }
    ) {
        questionQueue.removeAll { item in
            guard item.event.sessionId == sessionId, matches(item.event) else { return false }
            if item.isCodexAppServer {
                // Abandon the Codex app-server request so the server stops waiting.
                item.resolveCodexAppServer(nil)
            } else if item.isFromPermission {
                log.notice("⚠️ permission dropped, no decision reason=drainQuestions(\(reason, privacy: .public)) session=\(sessionId, privacy: .public) tool=AskUserQuestion")
                item.resolution.resumeHook(returning: Self.noDecisionAnswer)
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

    /// After dequeuing, show the next pending item, else the next finished
    /// turn, else collapse.
    ///
    /// Returns whether something the user can act on is on screen afterwards:
    /// an approval / question card, or the session list (which answers them
    /// inline), or the next completion card. A request that stays hidden —
    /// its auto-expand switch is off, Smart Suppress holds it back — is not
    /// on screen: a completion card whose time is up then moves on to the
    /// next finished turn or folds, instead of staying up for nobody.
    @discardableResult
    func showNextPending() -> Bool {
        collapseStaleCardSurface()
        let hasPending: Bool
        if let idx = nextVisiblePermissionIndex() {
            hasPending = true
            // An approval card still showing the request it was opened for
            // stays — the user may have picked it (session list, reminder)
            // over the head. It becomes the head, so whatever mirrors the
            // head (Buddy) agrees with the screen.
            let shownIdx = shownApprovalIndex
            // One assignment: removing and re-inserting in place would show
            // the queue's observers (follow-up reminders) a moment where this
            // request is gone, and its reminder would start over.
            var queue = permissionQueue
            let next = queue.remove(at: shownIdx ?? idx)
            queue.insert(next, at: 0)
            permissionQueue = queue
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if shownIdx != nil { return true }
            // When the session list is open, keep it open; approvals can be handled inline.
            if surface == .sessionList { return true }
            if Self.autoExpandOnPermission(), shouldAutoOpenPendingSurface(for: sid) {
                surface = .approvalCard(sessionId: sid)
                return true
            }
            // The approval stays hidden; a card already up stays with it.
            if surface.approvalSessionId != nil || surface.questionSessionId != nil { return true }
        } else if let next = nextVisibleQuestion {
            hasPending = true
            // A question card still showing the question it was opened for
            // stays, even when it is not the head (the user clicked "Answer"
            // on it, a reminder reopened it).
            if let shown = shownQuestionSessionId {
                activeSessionId = shown
                return true
            }
            let sid = next.event.sessionId ?? "default"
            activeSessionId = sid
            if !Self.autoExpandOnQuestion() {
                // Nothing opens by itself — and a card the user opened with a
                // click stays put. Stale cards were already folded above.
                if surface.questionSessionId != nil || surface == .sessionList { return true }
            } else if shouldAutoOpenQuestionSurface(for: next.event) {
                surface = .questionCard(sessionId: sid)
                return true
            } else if case .questionCard = surface {
                // Smart Suppress wants this card collapsed (e.g. an OMP ask
                // whose terminal dialog is racing). Fold an inherited
                // question-card surface so the promoted card does not render
                // expanded on top of the previous question's surface.
                surface = .collapsed
            } else if surface == .sessionList {
                return true
            }
        } else {
            hasPending = false
        }
        // Nothing interactive on screen. A completion card that is up keeps
        // its own time (`showNextCompletionOrCollapse` moves on when it is
        // over); a request arriving hidden must not cut it short.
        if !hasPending || !isShowingCompletion, showNextQueuedCompletion() {
            return true
        }
        if surface.approvalSessionId != nil || surface.questionSessionId != nil {
            surface = .collapsed
        }
        return false
    }

    /// Show the oldest queued completion whose session still exists, held to
    /// Smart Suppress as a card shown at once is: with its terminal in front,
    /// its tab is looked at off the main thread first, and a card whose own
    /// tab is showing stays down while the queue moves on.
    ///
    /// Returns whether a card is on screen or on its way there, so callers
    /// neither fold the island nor take another card out of the queue.
    private func showNextQueuedCompletion() -> Bool {
        if queuedCompletionLookingAtTab != nil { return true }
        while let next = completionQueue.first {
            completionQueue.removeFirst()
            guard let session = sessions[next] else { continue }
            guard shouldSuppressAppLevel(for: next) else {
                withAnimation(NotchAnimation.pop) { doShowCompletion(next) }
                return true
            }
            queuedCompletionLookingAtTab = next
            let sessionCopy = session
            Task.detached {
                let tabVisible = TerminalVisibilityDetector.isSessionTabVisible(sessionCopy)
                await MainActor.run { [weak self] in
                    self?.finishLookingAtQueuedCompletionTab(next, tabVisible: tabVisible)
                }
            }
            return true
        }
        return false
    }

    /// The tab of the queued completion on its way came back: pop its card,
    /// or move on with the queue.
    private func finishLookingAtQueuedCompletionTab(_ sessionId: String, tabVisible: Bool) {
        // The queue was cancelled meanwhile.
        guard queuedCompletionLookingAtTab == sessionId else { return }
        queuedCompletionLookingAtTab = nil
        switch surface {
        case .approvalCard, .questionCard:
            // An approval or question took the island meanwhile: the card
            // waits behind it again, first in line.
            if sessions[sessionId] != nil { completionQueue.insert(sessionId, at: 0) }
        case .sessionList:
            // The user opened the session list, which shows this finished
            // turn as well: no card over it.
            break
        case .collapsed, .completionCard:
            if sessions[sessionId] != nil, !tabVisible {
                withAnimation(NotchAnimation.pop) { doShowCompletion(sessionId) }
            } else if case .completionCard = surface {
                // Its own tab is in front (or it is gone): the card whose time
                // ran out moves on to the next one, or folds.
                showNextCompletionOrCollapse()
            } else {
                _ = showNextQueuedCompletion()
            }
        }
    }

    /// Find the most recently active non-idle session
    private func mostActiveSessionId() -> String? {
        // Pick the most urgent session: highest status priority, then most recent activity
        sessions.max { a, b in
            let pa = CompactBarRotation.statusPriority(a.value.status)
            let pb = CompactBarRotation.statusPriority(b.value.status)
            if pa != pb { return pa < pb }
            return a.value.lastActivity < b.value.lastActivity
        }?.key
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

    func restoreSessions() {
        let persisted = SessionPersistence.load()
        let cutoff = Date().addingTimeInterval(-30 * 60) // 30 minutes
        for p in persisted where p.lastActivity > cutoff {
            guard let source = SessionSnapshot.normalizedSupportedSource(p.source) else { continue }
            let restoredSessionId = CodexDiscovery.canonicalRestoredCodexSessionId(
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
            snapshot.herdrPaneId = p.herdrPaneId
            snapshot.herdrSocketPath = p.herdrSocketPath
            snapshot.herdrBinaryPath = p.herdrBinaryPath
            snapshot.claudeDesktopSessionId = p.claudeDesktopSessionId
            snapshot.hermesChatElsewhere = p.hermesChatElsewhere ?? false
            snapshot.parentSessionId = p.parentSessionId
            snapshot.lastActivity = p.lastActivity
            snapshot.transcriptPath = p.transcriptPath
            snapshot.recap = p.recap
            snapshot.reasoningEffort = p.reasoningEffort
            // A prompt typed while CodeIsland wasn't running supersedes the
            // saved recap; the transcript tail is the judge. Restored cards
            // don't always get a tailer, so check now rather than on attach.
            if snapshot.recap != nil, let path = snapshot.transcriptPath,
               let scan = JSONLTailer.scanFileTail(path: path) {
                _ = snapshot.applyTranscriptBackfill(scan)
            }
            if let closed = p.closedSubagentIds, !closed.isEmpty {
                snapshot.restoreClosedSubagentIds(closed)
            }
            if let agentTasks = p.agentTasks {
                snapshot.agentTasks = agentTasks
            }
            // Restore persisted cliPid only if the process is still alive — avoids
            // stale sessions reappearing briefly after the app or IDE restarts (#46).
            if let pid = p.cliPid, pid > 0 {
                let identity = ProcessIdentity(pid: pid, startTime: p.cliStartTime)
                if ProcessTable.isLiveProcess(identity) {
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
            // Harness is re-probed, not persisted — it may have restarted between runs.
            maybeResolveHostHarness(for: restoredSessionId)
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

    func startSessionDiscovery() {
        startCleanupTimer()
        // Restore persisted sessions before process scan (deduped by scan)
        restoreSessions()

        // Initial scan for already-running sessions, respecting per-source toggles,
        // then watch all known session-store roots so discovery keeps working when
        // hooks are missed.
        discovery.start()
    }

    /// Re-arm discovery after the watched roots changed — an extra config dir
    /// was added, removed or paused in Settings → Hooks — and rescan at once so
    /// sessions already running under a newly added root show up.
    func restartProjectsWatcher() {
        discovery.restartProjectsWatcher()
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
            guard shouldAdmitRemovedSession(
                info.sessionId,
                evidence: info.status.map { $0 == .idle ? .passive : .activeWork } ?? .passive,
                observedAt: info.modifiedAt
            ) else { continue }
            if shouldSuppressClosedCodexDesktopDiscovery(info) {
                continue
            }
            if isSupersededGrokDiscovery(info) {
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
            ), !hasWaitingRequest(onCard: info.sessionId) {
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
                    let existingAlive = existingProcess.map(ProcessTable.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                        // Existing PID is alive and different — discovery PID is unreliable.
                    } else {
                        // No existing PID, or it's dead, or it matches — safe to use discovery PID.
                        if !existingAlive, let process = ProcessTable.liveProcessIdentity(for: pid) {
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
                if linkDiscoveredChild(info) {
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
                // A process found on this Mac is never a remote session, however
                // its cwd reads: merged in, its pid and transcript would be this
                // Mac's on the remote card.
                guard !existing.isRemote,
                      existing.source == info.source,
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
                   ProcessTable.isLiveProcess(ProcessIdentity(pid: existingPid, startTime: existing.cliStartTime)) { return false }
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
                    let existingAlive = existingProcess.map(ProcessTable.isLiveProcess) ?? false
                    if existingAlive && existingPid != pid {
                    } else {
                        if !existingAlive, let process = ProcessTable.liveProcessIdentity(for: pid) {
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
            if let pid = info.pid, let process = ProcessTable.liveProcessIdentity(for: pid) {
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
            session.parentSessionId = discoveredParentCardId(info)
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

    /// Link the discovered thread's own card to its parent (see
    /// ``discoveredParentCardId(_:)``). Never a card the discovery was merged
    /// into as a duplicate: a Codex CLI discovery names no provider thread, so
    /// that can be another thread's card — a root, which a link would silence.
    @discardableResult
    private func linkDiscoveredChild(_ info: DiscoveredSession) -> Bool {
        guard sessions[info.sessionId]?.parentSessionId == nil,
              let parent = discoveredParentCardId(info) else {
            return false
        }
        sessions[info.sessionId]?.parentSessionId = parent
        return true
    }

    /// The card a discovered Codex subagent thread works for: its parent
    /// thread's card, or the card that thread's hooks would build. Agent
    /// Sub-Sessions shows it on a card of its own only in Show separately (or
    /// while Merge has no parent card to fold it into), where it stays quiet.
    private func discoveredParentCardId(_ info: DiscoveredSession) -> String? {
        guard info.source == "codex",
              let parentThreadId = info.parentSessionId,
              !parentThreadId.isEmpty else {
            return nil
        }
        let parent = findCodexParentSessionId(
            providerSessionId: parentThreadId,
            childTermBundleId: info.termBundleId
        ) ?? CodexDiscovery.codexDiscoveryIdentity(
            rawSessionId: parentThreadId,
            isDesktop: info.termBundleId == Self.codexAppBundleId
        ).sessionId
        return parent == info.sessionId ? nil : parent
    }

    @discardableResult
    func applyCodexSubsessionModeToKnownSessions(statePath: String? = nil) -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == .hide || mode == .merge else {
            return false
        }

        // This Mac's rollouts and state DB know nothing of a remote thread, and
        // its transcript path names a file on its own host; its hooks place it
        // (CodexThreadSubsession).
        let candidates = sessions
            .filter { !$0.value.isRemote }
            .map { (sessionId: $0.key, session: $0.value) }
        var transcriptMetadata: [String: CodexSubagentMetadata] = [:]
        var databaseLookupIds: Set<String> = []

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            if let transcriptPath = candidate.session.transcriptPath {
                switch codexRollouts.inspection(transcriptPath: transcriptPath) {
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
        let databaseRecords = CodexDiscovery.codexSpawnEdgeRecords(
            threadIds: databaseLookupIds,
            statePath: statePath
        )
        var didMutate = false

        for candidate in candidates where candidate.session.source == "codex" {
            let providerSessionId = candidate.session.providerSessionId ?? candidate.sessionId
            guard let metadata = transcriptMetadata[candidate.sessionId]
                    ?? databaseRecords[providerSessionId]?.metadata,
                  metadata.parentThreadId != providerSessionId,
                  !hasWaitingRequest(onCard: candidate.sessionId) else {
                continue
            }

            if mode == .hide {
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
            // The thread's later hooks follow its row here.
            subagent.subsessionKind = .codexThread
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

    /// Whether an approval or question on this card still waits for the user.
    /// The passes over known cards leave such a card alone: removing or
    /// folding it would deny the request unseen. The next pass after it is
    /// answered moves the card as usual.
    private func hasWaitingRequest(onCard sessionId: String) -> Bool {
        permissionQueue.contains(where: { ($0.event.sessionId ?? "default") == sessionId })
            || questionQueue.contains(where: { ($0.event.sessionId ?? "default") == sessionId })
    }

    /// Apply Agent Sub-Sessions to known Cursor Task/subagent cards
    /// (`transcriptPath` is the parent chat; `session_id` is the child).
    /// `merge` / `hide` only; `separate` is handled by `separateMergedCursorSubagents()`.
    @discardableResult
    func applyCursorSubsessionModeToKnownSessions() -> Bool {
        let mode = Self.currentPluginSessionMode()
        guard mode == .hide || mode == .merge else {
            return false
        }

        // Cursor Agent Tasks that fired Claude-format hooks keep default
        // source=claude and never enter the fold loop — rebrand first.
        var didMutate = rebrandMisattributedCursorTaskCards()

        // Refresh after rebrand so newly tagged cursor cards are included.
        let candidates = sessions.map { (sessionId: $0.key, session: $0.value) }

        if mode == .hide {
            for candidate in candidates {
                let source = candidate.session.source
                guard source == "cursor" || source == "cursor-cli" else { continue }
                guard cursorFoldIdentity(for: candidate) != nil,
                      !hasWaitingRequest(onCard: candidate.sessionId) else { continue }
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
            guard let fold = cursorFoldIdentity(for: candidate),
                  !hasWaitingRequest(onCard: candidate.sessionId) else { continue }
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
                    parent.remoteHostId = candidate.session.remoteHostId
                    parent.remoteHostName = candidate.session.remoteHostName
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
                // A remote Task's chat runs on the same host. Unmarked, the
                // card would have that host's transcript path read here.
                parent.remoteHostId = candidate.session.remoteHostId
                parent.remoteHostName = candidate.session.remoteHostName
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
            // The Task's later hooks follow its row here.
            subagent.subsessionKind = .cursorTask
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
        event: HookEvent,
        status: AgentStatus
    ) {
        guard let agentId = event.agentId else { return }
        guard var session = sessions[sessionId] else { return }
        // A row the request creates goes by the hook's own `agent_type` (a
        // Codex thread's role, a pi child's agent). A child session Agent
        // Sub-Sessions folded here is marked as one, so its later hooks
        // follow this row.
        let foldedKind = SubsessionRouter.foldedKind(of: event)
        let agentType = (event.rawJSON["agent_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var subagent = session.subagents[agentId]
            ?? SubagentState(
                agentId: agentId,
                agentType: agentType.flatMap { $0.isEmpty ? nil : $0 }
                    ?? foldedKind?.defaultAgentType
                    ?? "cursor-subagent"
            )
        subagent.status = status
        subagent.lastActivity = Date()
        if let foldedKind {
            subagent.subsessionKind = foldedKind
        }
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
    /// (`~/.cursor/.../agent-transcripts/.../subagents/<id>.jsonl`), and give
    /// Cursor-labelled Task cards that transcript, which folds them.
    ///
    /// Runs on every hook event and discovery scan, so it never touches the
    /// disk: cards without a Cursor transcript path are looked up in
    /// `cursorSubagentIndex`, and a card the index does not resolve is looked
    /// up again by fresh walks off the main actor, on a bounded schedule
    /// (`scheduleCursorSubagentLookups`). When a walk finds it, the card is
    /// rebranded then (`installCursorSubagentIndex`).
    @discardableResult
    func rebrandMisattributedCursorTaskCards() -> Bool {
        var didMutate = false
        for (sessionId, snap) in sessions {
            guard Self.needsCursorTaskTranscriptLookup(snap) else { continue }

            if let path = snap.transcriptPath,
               CursorSessionFolding.isCursorAgentTranscriptPath(path) {
                sessions[sessionId]?.source = "cursor"
                didMutate = true
                continue
            }
            // A remote card's transcripts live on its own host, never in the local index.
            guard !snap.isRemote else { continue }

            guard let found = cursorSubagentIndex?.transcriptPath(
                sessionId: sessionId,
                preferredBase: Self.cursorProjectTranscriptBase(cwd: snap.cwd)
            ) else {
                continue
            }
            if !CursorSubsessionRouter.isCursorFamilySource(snap.source) {
                sessions[sessionId]?.source = "cursor"
            }
            if sessions[sessionId]?.transcriptPath == nil {
                sessions[sessionId]?.transcriptPath = found
            }
            didMutate = true
        }
        scheduleCursorSubagentLookups()
        return didMutate
    }

    /// Cards the Task transcript index is consulted for: default-Claude cards,
    /// and local Cursor cards with no transcript at all. A Task's own hooks
    /// never carry one (Cursor resolves `transcript_path` only for a top-level
    /// conversation), and since the bridge reads Cursor's payload (#377) the
    /// Task hooks Cursor runs from Claude Code's config arrive labelled Cursor
    /// rather than as the default Claude.
    nonisolated static func needsCursorTaskTranscriptLookup(_ snap: SessionSnapshot) -> Bool {
        switch SessionSnapshot.normalizedSupportedSource(snap.source) {
        case nil, "claude":
            return true
        case "cursor", "cursor-cli":
            return snap.transcriptPath == nil && !snap.isRemote
        default:
            return false
        }
    }

    /// Give each card the index does not resolve a lookup schedule (kept
    /// across calls, dropped once the card is gone or rebranded), then start
    /// the walk its earliest due lookup needs, or arm the re-check timer for
    /// it. At most one walk and one timer are ever pending.
    private func scheduleCursorSubagentLookups(now: Date = Date()) {
        // `separate` folds nothing, so nothing is looked up; leaving it starts
        // every card's schedule afresh (`applyCurrentPluginSessionMode`).
        let mode = Self.currentPluginSessionMode()
        guard mode == .merge || mode == .hide else {
            resetCursorSubagentLookups()
            return
        }
        var lookups: [String: CursorSubagentLookupSchedule] = [:]
        for sessionId in cursorRebrandCandidateIds()
        where cursorSubagentIndex?.contains(sessionId: sessionId) != true {
            lookups[sessionId] = cursorSubagentLookups[sessionId]
                ?? CursorSubagentLookupSchedule(since: now, delays: cursorSubagentLookupDelays)
        }
        cursorSubagentLookups = lookups
        guard cursorSubagentIndexTask == nil else { return }  // its completion reschedules
        guard let due = lookups.values.compactMap(\.nextLookup).min() else {
            cancelCursorSubagentIndexRecheck()
            return
        }
        if due <= now {
            startCursorSubagentIndexRebuild()
        } else {
            armCursorSubagentIndexRecheck(at: due)
        }
    }

    /// The timer, not hook traffic, drives a card's later lookups.
    private func armCursorSubagentIndexRecheck(at due: Date) {
        if cursorSubagentIndexRecheck != nil, let armed = cursorSubagentIndexRecheckAt, armed <= due { return }
        cursorSubagentIndexRecheck?.cancel()
        cursorSubagentIndexRecheckAt = due
        let delay = max(0, due.timeIntervalSinceNow)
        cursorSubagentIndexRecheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded(.up)))
            guard let self, !Task.isCancelled else { return }
            self.cursorSubagentIndexRecheck = nil
            self.cursorSubagentIndexRecheckAt = nil
            self.scheduleCursorSubagentLookups()
        }
    }

    private func cancelCursorSubagentIndexRecheck() {
        cursorSubagentIndexRecheck?.cancel()
        cursorSubagentIndexRecheck = nil
        cursorSubagentIndexRecheckAt = nil
    }

    /// Drop every card's lookup schedule and the timer driving them.
    private func resetCursorSubagentLookups() {
        cursorSubagentLookups = [:]
        cancelCursorSubagentIndexRecheck()
    }

    private func startCursorSubagentIndexRebuild() {
        guard cursorSubagentIndexTask == nil else { return }
        cancelCursorSubagentIndexRecheck()
        let scan = discovery.scanners.cursorSubagentIndex
        cursorSubagentIndexTask = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            let index = scan()
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                // Cancelled by teardown, which already dropped the handle.
                guard let self, !Task.isCancelled else { return }
                self.cursorSubagentIndexTask = nil
                self.installCursorSubagentIndex(index)
            }
        }
    }

    /// Adopt a freshly walked index: count it against the schedule of every
    /// card it does not resolve, and rebrand (and fold) the cards it does.
    private func installCursorSubagentIndex(_ index: CursorSubagentTranscriptIndex) {
        cursorSubagentIndex = index
        for sessionId in Array(cursorSubagentLookups.keys) where !index.contains(sessionId: sessionId) {
            cursorSubagentLookups[sessionId]?.recordMiss(walkStartedAt: index.builtAt)
        }

        let resolvedAny = cursorRebrandCandidateIds().contains { index.contains(sessionId: $0) }
        if resolvedAny, applyCursorSubsessionModeToKnownSessions() {
            scheduleSave()
            startRotationIfNeeded()
            refreshDerivedState()
        } else {
            scheduleCursorSubagentLookups()
        }
    }

    /// Local cards the index may resolve (``needsCursorTaskTranscriptLookup``)
    /// whose transcript path does not already say Cursor.
    private func cursorRebrandCandidateIds() -> [String] {
        sessions.compactMap { sessionId, snap in
            guard Self.needsCursorTaskTranscriptLookup(snap), !snap.isRemote,
                  !CursorSessionFolding.isCursorAgentTranscriptPath(snap.transcriptPath) else { return nil }
            return sessionId
        }
    }

    /// `~/.cursor/projects/<cwd-encoded>/agent-transcripts` — where a Task run
    /// from `cwd` keeps its transcripts.
    nonisolated static func cursorProjectTranscriptBase(
        cwd: String?,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return "\(home)/.cursor/projects/\(cwd.appProjectDirEncoded())/agent-transcripts"
    }

    func applyCurrentPluginSessionMode(persist: Bool = true) {
        let mode = Self.currentPluginSessionMode()
        var didMutate = false

        switch mode {
        case .separate:
            // Back in merge or hide, every candidate card is looked up afresh.
            resetCursorSubagentLookups()
            didMutate = separateMergedCodexSubagents()
            didMutate = separateMergedCursorSubagents() || didMutate
        case .merge:
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = applyCursorSubsessionModeToKnownSessions() || didMutate
        case .hide:
            didMutate = applyCodexSubsessionModeToKnownSessions()
            didMutate = hideMergedCodexSubagents() || didMutate
            didMutate = applyCursorSubsessionModeToKnownSessions() || didMutate
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
        let childIds = Set(parentCandidates.filter { !$0.session.isRemote }.flatMap { $0.session.subagents.keys })
        // One DB connection for the whole mode transition; never open SQLite
        // once per child (each open carries a busy timeout).
        let databaseRecords = CodexDiscovery.codexSpawnEdgeRecords(threadIds: childIds)
        var didMutate = false

        for parent in parentCandidates where parent.session.source == "codex" && !parent.session.subagents.isEmpty {
            for (agentId, subagent) in parent.session.subagents {
                let childIsDesktop = parent.session.termBundleId == Self.codexAppBundleId
                let childKey = findCodexParentSessionId(
                    providerSessionId: agentId,
                    childTermBundleId: parent.session.termBundleId
                ) ?? CodexDiscovery.codexDiscoveryIdentity(
                    rawSessionId: agentId,
                    isDesktop: childIsDesktop
                ).sessionId
                guard childKey != parent.sessionId else { continue }

                var child = sessions[childKey] ?? SessionSnapshot(startTime: subagent.startTime)
                child.source = "codex"
                child.providerSessionId = agentId
                child.cwd = child.cwd ?? parent.session.cwd
                // The child's own model (its hooks, then its rollout below) —
                // never the parent's: children routinely run on another model.
                child.model = child.model ?? subagent.model
                child.reasoningEffort = child.reasoningEffort ?? subagent.reasoningEffort
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
                child.remotePid = child.remotePid ?? parent.session.remotePid
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity
                // Still the parent's child, on a card of its own: quiet.
                child.parentSessionId = child.parentSessionId ?? parent.sessionId

                // A remote child's rollout is on its own host: none of this
                // Mac's rollouts, state DB or sessions folder is read for it.
                let readsLocalStore = !parent.session.isRemote
                let transcriptMetadata = readsLocalStore
                    ? child.transcriptPath.flatMap { CodexDiscovery.codexSubagentMetadata(inTranscriptPath: $0) }
                    : nil
                let metadata = transcriptMetadata ?? (readsLocalStore ? databaseRecords[agentId]?.metadata : nil)
                if child.sessionTitle == nil {
                    child.sessionTitle = metadata?.agentNickname ?? subagent.toolDescription ?? subagent.agentType
                }
                if readsLocalStore, child.transcriptPath == nil {
                    if let statePath = databaseRecords[agentId]?.transcriptPath,
                       FileManager.default.fileExists(atPath: statePath) {
                        child.transcriptPath = statePath
                    } else if let cwd = parent.session.cwd {
                        let base = FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".codex/sessions").path
                        child.transcriptPath = CodexDiscovery.findRecentCodexSession(
                            base: base,
                            cwd: cwd,
                            after: parent.session.cliStartTime,
                            fm: .default
                        )
                    }
                }
                if readsLocalStore, let transcriptPath = child.transcriptPath {
                    let (model, messages) = CodexDiscovery.readRecentFromCodexTranscript(path: transcriptPath)
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
                // Own model only, never the parent chat's (see the Codex split).
                child.model = child.model ?? subagent.model
                child.reasoningEffort = child.reasoningEffort ?? subagent.reasoningEffort
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
                child.herdrPaneId = child.herdrPaneId ?? parent.session.herdrPaneId
                child.herdrSocketPath = child.herdrSocketPath ?? parent.session.herdrSocketPath
                child.herdrBinaryPath = child.herdrBinaryPath ?? parent.session.herdrBinaryPath
                child.claudeDesktopSessionId = child.claudeDesktopSessionId ?? parent.session.claudeDesktopSessionId
                child.remoteHostId = child.remoteHostId ?? parent.session.remoteHostId
                child.remoteHostName = child.remoteHostName ?? parent.session.remoteHostName
                // Keep the child's own process identity only — the parent Cursor chat
                // often shares the IDE process, which must not be attributed to Tasks.
                child.status = subagent.status
                child.currentTool = subagent.currentTool
                child.toolDescription = subagent.toolDescription ?? subagent.agentType
                child.lastActivity = subagent.lastActivity
                // Still the chat's Task, on a card of its own: quiet.
                child.parentSessionId = child.parentSessionId ?? parent.sessionId
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
              !parentSessionId.isEmpty,
              // A thread whose request waits on its own card stays there
              // until it is answered; discovery just keeps the card current.
              !hasWaitingRequest(onCard: info.sessionId) else {
            return false
        }

        let mode = Self.currentPluginSessionMode()
        guard mode == .hide || mode == .merge else {
            return false
        }

        if mode == .hide {
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
        // The thread's hooks follow its row here.
        subagent.subsessionKind = .codexThread
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
        discovery.stop()
        rotation.stopTimer()
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        cursorSubagentIndexTask?.cancel()
        cursorSubagentIndexTask = nil
        cancelCursorSubagentIndexRecheck()
        processMonitor.stopAll()
    }

    deinit {
        // Must not use MainActor.assumeIsolated: async callers (notably XCTest)
        // can release AppState off the main actor via ARC. Main-synced Timer
        // teardown keeps it crash-free. The discovery coordinator (FSEvents,
        // scans) and the process monitor (exit sources) tear down their own
        // when they are released.
        tearDownMainThreadResources()
        cursorSubagentIndexTask?.cancel()
        cursorSubagentIndexRecheck?.cancel()
        codexAppServerReconnectTask?.cancel()
    }

    /// Invalidates main-run-loop Timers in one main-queue hop. Safe from any
    /// thread so `deinit` stays uniformly main-safe.
    nonisolated private func tearDownMainThreadResources() {
        let teardown = { [self] in
            rotation.tearDownAssumingMain()
            cleanupTimer?.invalidate()
            cleanupTimer = nil
            saveTimer?.invalidate()
            saveTimer = nil
        }
        if Thread.isMainThread {
            teardown()
        } else {
            DispatchQueue.main.sync(execute: teardown)
        }
    }
}
