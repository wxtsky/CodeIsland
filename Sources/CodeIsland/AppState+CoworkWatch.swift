import Foundation
import AppKit
import CodeIslandCore

/// Claude Desktop Cowork tasks and local Chat sessions on the island.
///
/// Cowork runs Claude Code inside a sandbox VM, so it fires no hooks
/// (anthropics/claude-code#40495). `CoworkSessionWatcher` reads Claude
/// Desktop's own session store instead; this file maps its updates onto
/// ordinary `claude` session cards hosted by Claude Desktop. Approvals cannot
/// be answered from here — a waiting card only says so, and a click opens the
/// conversation in Claude Desktop.
extension AppState {
    /// Keeps store ids (`local_<uuid>`) disjoint from hook session ids.
    nonisolated static let coworkSessionPrefix = "cowork:"
    nonisolated static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"

    nonisolated static func coworkSessionKey(_ storeSessionId: String) -> String {
        coworkSessionPrefix + storeSessionId
    }

    nonisolated static func coworkStoreSessionId(fromKey key: String) -> String? {
        guard key.hasPrefix(coworkSessionPrefix) else { return nil }
        return String(key.dropFirst(coworkSessionPrefix.count))
    }

    /// A turn with no audit or transcript line for this long is settled idle.
    /// Nothing is written while a tool runs, so the generic 3-minute "a tool
    /// that quiet must have been missed" rule would flip a long build.
    nonisolated static let coworkTurnSilenceTimeout: TimeInterval = 30 * 60
    /// A permission card or question left open this long is settled idle.
    /// The store is silent for exactly as long as the card is up, so this is
    /// only the backstop for a wait nothing will ever close: the VM died, the
    /// CLI was killed, or Claude Desktop dropped the request without logging
    /// a response or a result. (Archiving, deleting or quitting Claude Desktop
    /// clear the card through their own paths.)
    nonisolated static let coworkWaitSilenceTimeout: TimeInterval = 4 * 60 * 60

    /// How long a Cowork card in `status` may stay silent before the sweep
    /// settles it; nil when there is nothing to settle.
    nonisolated static func coworkSilenceTimeout(status: AgentStatus) -> TimeInterval? {
        switch status {
        case .idle: return nil
        case .processing, .running: return coworkTurnSilenceTimeout
        case .waitingApproval, .waitingQuestion: return coworkWaitSilenceTimeout
        }
    }

    /// The running Claude Desktop, as a process identity that a restart
    /// (same bundle, new process) no longer matches.
    nonisolated static func runningClaudeDesktopProcess() -> ProcessIdentity? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: claudeDesktopBundleId)
            .first(where: { !$0.isTerminated }) else { return nil }
        return liveProcessIdentity(for: app.processIdentifier)
    }

    static func isCoworkTrackingEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: SettingsKey.trackClaudeDesktopCowork) != nil else {
            return SettingsDefaults.trackClaudeDesktopCowork
        }
        return defaults.bool(forKey: SettingsKey.trackClaudeDesktopCowork)
    }

    // MARK: - Lifecycle

    /// Idempotent. With the setting off this also clears any Cowork card left
    /// over from the previous run.
    func startCoworkWatcher(rootPath: String = CoworkPaths.defaultRoot()) {
        guard Self.isCoworkTrackingEnabled() else {
            stopCoworkWatcher()
            return
        }
        guard coworkWatcher == nil else { return }
        let watcher = CoworkSessionWatcher(rootPath: rootPath) { [weak self] output in
            Task { @MainActor in self?.handleCoworkOutput(output) }
        }
        coworkWatcher = watcher
        // The cleanup sweep also notices a quit Claude Desktop, but only every
        // few seconds — and not at all when it relaunches in between (an
        // auto-update). The notification catches both.
        claudeDesktopTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == AppState.claudeDesktopBundleId else { return }
            Task { @MainActor in self?.claudeDesktopTerminated() }
        }
        watcher.start()
    }

    func stopCoworkWatcher() {
        coworkWatcher?.stop()
        coworkWatcher = nil
        if let observer = claudeDesktopTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            claudeDesktopTerminationObserver = nil
        }
        removeCoworkSessions()
        coworkTurnHosts.removeAll()
    }

    func removeCoworkSessions() {
        for key in sessions.keys where key.hasPrefix(Self.coworkSessionPrefix) {
            removeSession(key)
        }
    }

    func handleCoworkOutput(_ output: CoworkSessionWatcher.Output) {
        // A delivery queued before the watcher was stopped must not bring
        // cards back.
        guard coworkWatcher != nil else { return }
        switch output {
        case .launchSnapshot(let updates):
            let claudeDesktop = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.claudeDesktopBundleId)
                .first
            applyCoworkLaunchSnapshot(
                updates,
                claudeDesktopRunning: claudeDesktop != nil,
                claudeDesktopLaunchedAt: claudeDesktop?.launchDate
            )
        case .updates(let updates):
            for update in updates {
                applyCoworkUpdate(update)
            }
            refreshDerivedState()
        case .removed(let storeIds):
            for storeId in storeIds where sessions[Self.coworkSessionKey(storeId)] != nil {
                removeSession(Self.coworkSessionKey(storeId))
            }
        }
    }

    // MARK: - Applying updates

    /// Reconcile with the store right after launch. Cards restored from the
    /// previous run's `sessions.json` are only a snapshot of what was on screen
    /// then; the store decides now. Anything it does not vouch for — archived,
    /// deleted, gone quiet, or Claude Desktop not even running — goes, so a
    /// restart never resurrects a finished Cowork task as a ghost card.
    ///
    /// A turn (or permission card) the log leaves open but that was last
    /// written before the running Claude Desktop started died with the previous
    /// instance — Claude Desktop logs nothing when it restarts over one — so it
    /// is rebuilt idle rather than as a card that "thinks" forever.
    func applyCoworkLaunchSnapshot(
        _ updates: [CoworkSessionWatcher.SessionUpdate],
        claudeDesktopRunning: Bool,
        claudeDesktopLaunchedAt: Date? = nil
    ) {
        let vouched = claudeDesktopRunning
            ? Set(updates.map { Self.coworkSessionKey($0.sessionId) })
            : []
        for key in sessions.keys where key.hasPrefix(Self.coworkSessionPrefix) && !vouched.contains(key) {
            removeSession(key)
        }
        guard claudeDesktopRunning else { return }
        for update in updates {
            applyCoworkUpdate(update, isLaunch: true)
            if let launchedAt = claudeDesktopLaunchedAt,
               let lastActivity = update.lastActivity,
               lastActivity < launchedAt {
                settleCoworkCard(Self.coworkSessionKey(update.sessionId))
            }
        }
        refreshDerivedState()
    }

    // MARK: - Turns Claude Desktop will never finish

    /// Settle a Cowork card's turn or wait idle: Claude Desktop will never
    /// log its end. Keeps the card's age, so the idle sweep collects it on the
    /// usual clock.
    func settleCoworkCard(_ key: String) {
        coworkTurnHosts.removeValue(forKey: key)
        guard var snapshot = sessions[key], snapshot.status != .idle else { return }
        let waitBefore = displayOnlyWaitKind(forSession: key)
        snapshot.status = .idle
        snapshot.currentTool = nil
        snapshot.toolDescription = nil
        sessions[key] = snapshot
        noteDisplayOnlyWait(sessionId: key, was: waitBefore)
    }

    /// Cleanup-sweep pass for Cowork cards, which the generic silence rule
    /// skips. A turn or wait is settled once the Claude Desktop process it ran
    /// in is gone — quit, crashed or restarted, none of which Claude Desktop
    /// logs — or once it has been silent past `coworkSilenceTimeout`.
    func settleCoworkCards(now: Date = Date()) {
        for (key, session) in sessions
            where key.hasPrefix(Self.coworkSessionPrefix) && session.status != .idle {
            let hostGone = coworkTurnHosts[key].map { !Self.isLiveProcess($0) } ?? false
            let timedOut = Self.coworkSilenceTimeout(status: session.status)
                .map { now.timeIntervalSince(session.lastActivity) > $0 } ?? false
            if hostGone || timedOut {
                settleCoworkCard(key)
            }
        }
        if !coworkTurnHosts.isEmpty {
            coworkTurnHosts = coworkTurnHosts.filter { key, _ in
                sessions[key].map { $0.status != .idle } ?? false
            }
        }
    }

    /// Claude Desktop quit (or is restarting): every turn and permission card
    /// it had open went with it.
    func claudeDesktopTerminated() {
        for (key, session) in sessions
            where key.hasPrefix(Self.coworkSessionPrefix) && session.status != .idle {
            settleCoworkCard(key)
        }
        refreshDerivedState()
    }

    /// Remember which Claude Desktop process a turn runs in, from the moment
    /// it leaves idle until it is idle again.
    private func noteCoworkTurnHost(_ key: String) {
        guard let status = sessions[key]?.status, status != .idle else {
            coworkTurnHosts.removeValue(forKey: key)
            return
        }
        if coworkTurnHosts[key] == nil, let host = claudeDesktopProcessProvider() {
            coworkTurnHosts[key] = host
        }
    }

    /// Apply one watcher update. Only a launch rebuild or live audit activity
    /// may open a card: a metadata-only change (a generated title, a re-save)
    /// for a session the idle sweep already collected is history, not activity.
    ///
    /// The same two are the only ones that move the turn state. A metadata-only
    /// update still carries the watcher's folded audit, which may hold a turn
    /// or permission card the island has since settled — one that died with a
    /// restarted Claude Desktop — and must not bring it back.
    func applyCoworkUpdate(_ update: CoworkSessionWatcher.SessionUpdate, isLaunch: Bool = false) {
        let key = Self.coworkSessionKey(update.sessionId)
        let metadata = update.metadata
        guard CoworkSessionPolicy.isTrackable(metadata),
              !CoworkSessionPolicy.isShadowedByHookSession(
                cliSessionId: metadata.cliSessionId,
                existingSessionKeys: Set(sessions.keys)
              ) else {
            if sessions[key] != nil { removeSession(key) }
            return
        }
        let isNew = sessions[key] == nil
        let movesTurnState = isLaunch || update.isLive
        guard !isNew || movesTurnState else { return }
        let waitBefore = displayOnlyWaitKind(forSession: key)

        var snapshot = sessions[key] ?? SessionSnapshot(startTime: metadata.createdAt ?? Date())
        Self.applyCoworkMetadata(&snapshot, metadata: metadata, transcriptPath: update.transcriptPath)
        if movesTurnState {
            Self.applyCoworkAuditState(&snapshot, state: update.audit)
        }
        if update.isLive {
            snapshot.lastActivity = Date()
        } else if isNew, let lastActivity = update.lastActivity {
            // Rebuilt from history: keep the real age so the idle sweep
            // retires it on the same clock as every other card.
            snapshot.lastActivity = lastActivity
        }
        sessions[key] = snapshot
        if movesTurnState {
            noteCoworkTurnHost(key)
        }
        attachTranscriptTailerIfNeeded(sessionId: key)
        // Claude Desktop's configured model only seeds the label, after the
        // transcript backfill had its say: the transcript names the model that
        // actually answered, in its own spelling, and overwriting it on every
        // metadata save flipped the label between the two.
        if sessions[key]?.model == nil, let model = metadata.model {
            sessions[key]?.model = model
        }
        // A permission card or question in Claude Desktop: reminders, and a
        // push when a live one first appears.
        noteDisplayOnlyWait(
            sessionId: key,
            was: waitBefore,
            asking: movesTurnState ? DisplayOnlyWait.content(forCowork: update.audit) : nil,
            announce: update.isLive && !isLaunch
        )

        guard update.isLive else { return }
        if snapshot.status != .idle,
           activeSessionId == nil || sessions[activeSessionId ?? ""]?.status == .idle {
            activeSessionId = key
        }
        // One cue per turn boundary, reusing the hook event names so the
        // existing per-event sound toggles apply unchanged.
        if update.turnsCompleted > 0, snapshot.status == .idle {
            // Stopped with Claude Desktop's Stop button: the user is right
            // there and knows. Like an AiWork abort — no jingle, no completion
            // card (so no follow-up), no push; the card just reads interrupted.
            guard !update.audit.lastTurnInterrupted else { return }
            SoundManager.shared.handleEvent(
                update.audit.lastTurnFailed ? EventSoundRouting.turnFailed : "Stop",
                sessionId: key
            )
            enqueueCompletion(key, turnFailed: update.audit.lastTurnFailed)
            // A failed turn's `result` record carries the error text.
            pushTurnEnded(
                sessionId: key,
                failed: update.audit.lastTurnFailed,
                errorDetail: update.audit.lastTurnFailed ? update.audit.lastResultText : nil
            )
        } else if update.permissionsRequested > 0,
                  snapshot.status == .waitingApproval || snapshot.status == .waitingQuestion {
            // Display-only wait, like Cursor's in-IDE question (#265): the sound
            // and the waiting status say Cowork is blocked; nothing is queued,
            // since the answer can only be given in Claude Desktop.
            SoundManager.shared.handleEvent("PermissionRequest")
        } else if update.promptsStarted > 0 {
            let isFreshSession = isNew && metadata.createdAt.map { Date().timeIntervalSince($0) < 120 } == true
            SoundManager.shared.handleEvent(isFreshSession ? "SessionStart" : "UserPromptSubmit")
        }
    }

    /// Identity and context from `local_<id>.json`. Pure — shared by live
    /// updates, the launch rebuild and tests.
    nonisolated static func applyCoworkMetadata(
        _ snapshot: inout SessionSnapshot,
        metadata: CoworkSessionMetadata,
        transcriptPath: String?
    ) {
        // The engine is Claude Code: keep the claude mascot and every
        // transcript-driven feature. The host bundle marks it as a Claude
        // Desktop session (badge, native-app handling, click-to-jump).
        snapshot.source = "claude"
        snapshot.termBundleId = claudeDesktopBundleId
        snapshot.termApp = "Claude"
        if let cliSessionId = metadata.cliSessionId {
            snapshot.providerSessionId = cliSessionId
        }
        if let title = metadata.displayTitle {
            snapshot.sessionTitle = title
        }
        if let cwd = metadata.hostCwd {
            snapshot.cwd = cwd
        }
        if let transcriptPath {
            snapshot.transcriptPath = transcriptPath
        }
    }

    /// Status from the audit-log reducer. Pure.
    nonisolated static func applyCoworkAuditState(_ snapshot: inout SessionSnapshot, state: CoworkAuditState) {
        switch state.phase {
        case .idle:
            snapshot.status = .idle
            snapshot.interrupted = state.lastTurnInterrupted
            // Cowork has no prompt hook to clear it, and a stopped turn skips
            // enqueueCompletion: the log's own verdict on the last turn rules.
            snapshot.lastTurnFailed = state.lastTurnFailed
            snapshot.currentTool = nil
            snapshot.toolDescription = nil
        case .processing:
            // `.running` is what hook sources report while a tool executes; the
            // bare "thinking" indicator stays for model output.
            snapshot.status = state.currentTool == nil ? .processing : .running
            snapshot.interrupted = false
            snapshot.currentTool = state.currentTool?.name
            snapshot.toolDescription = state.currentTool?.detail
        case .waitingApproval:
            let tool = state.activePermission?.toolName ?? "tool"
            let ask = String(format: L10n.shared["cowork_waiting_approval"], tool)
            snapshot.status = .waitingApproval
            snapshot.interrupted = false
            snapshot.currentTool = tool
            snapshot.toolDescription = state.activePermission?.detail.map { "\(ask) · \($0)" } ?? ask
        case .waitingQuestion:
            snapshot.status = .waitingQuestion
            snapshot.interrupted = false
            snapshot.currentTool = "AskUserQuestion"
            if let question = state.activePermission?.detail {
                snapshot.toolDescription = String(format: L10n.shared["cowork_waiting_question"], question)
            } else {
                snapshot.toolDescription = L10n.shared["cowork_waiting_question_generic"]
            }
        }

        // Without a transcript yet (the CLI writes it a beat after the audit
        // log) fall back to what the audit carries; once the tailer is attached
        // it owns the chat lines, so both sources never double-post.
        guard snapshot.transcriptPath == nil else { return }
        if let prompt = state.lastPrompt, snapshot.lastUserPrompt != prompt {
            snapshot.lastUserPrompt = prompt
            snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
        }
        if state.phase == .idle, state.completedTurnCount > 0 {
            let placeholder = state.lastTurnInterrupted ? "reply_aborted_placeholder"
                : state.lastTurnFailed ? "reply_failed_placeholder"
                : "reply_complete_placeholder"
            let reply = state.lastResultText ?? L10n.shared[placeholder]
            if snapshot.lastAssistantMessage != reply {
                snapshot.lastAssistantMessage = reply
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: reply))
            }
        }
    }

    // MARK: - Click-to-jump

    /// Open a Cowork card's conversation in Claude Desktop. Returns false when
    /// `sessionKey` is not a Cowork card, so the caller falls back to its
    /// generic activation.
    ///
    /// The deep link is not a guess: Claude Desktop's URL handler routes
    /// `claude://claude.ai/cowork/<id>` to its in-app `/cowork/<id>` screen,
    /// the same route its own "needs input" and "task finished" notifications
    /// navigate to (verified in the shipped app bundle, v2.2553).
    @discardableResult
    nonisolated static func openCoworkSession(sessionKey: String) -> Bool {
        guard let storeId = coworkStoreSessionId(fromKey: sessionKey) else { return false }
        openInClaudeDesktop(CoworkSessionPolicy.deepLinkURL(sessionId: storeId))
        return true
    }

    /// Bring Claude Desktop forward and, given a deep link, navigate it there.
    /// Shared by Cowork cards and Code-tab sessions.
    nonisolated static func openInClaudeDesktop(_ deepLink: URL?) {
        let workspace = NSWorkspace.shared
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: claudeDesktopBundleId).first,
           app.isHidden {
            app.unhide()
        }
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: claudeDesktopBundleId) else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Reopen first, like a Dock click: it brings back a closed or hidden
        // main window (and switches Space). The link event queues behind it and
        // then navigates that window to the conversation.
        workspace.openApplication(at: appURL, configuration: configuration)
        if let deepLink {
            workspace.open([deepLink], withApplicationAt: appURL, configuration: configuration)
        }
    }
}
