import Foundation
import AppKit
import CodeIslandCore

extension AppState {
    /// Session ID prefix applied to AiWork/Agentix sessions surfaced via
    /// `sessions.watch`. Keeps the namespace disjoint from hook-driven sources.
    static let aiworkSessionPrefix = "aiwork:"

    // MARK: - Public lifecycle

    /// Start discovering Agentix daemons and maintaining `sessions.watch`
    /// subscriptions. Idempotent. No-ops when both AiWork GUI and CLI monitoring
    /// are disabled in Hooks settings.
    func startAiWorkWatcher() {
        guard ConfigInstaller.isAnyAiWorkMonitoringEnabled() else {
            stopAiWorkWatcher()
            return
        }
        if aiworkWatchReconnectTimer != nil { return }

        // Periodic rediscovery covers daemon restarts and late launches
        // (AiWork GUI / `aiwork tui` bring the coder daemon up on demand).
        let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileAiWorkWatchClients()
            }
        }
        // Tolerate a bit of AppKit run-loop jitter so a busy main thread
        // doesn't stall rediscovery for many seconds.
        timer.tolerance = 1.0
        aiworkWatchReconnectTimer = timer

        reconcileAiWorkWatchClients()
    }

    func stopAiWorkWatcher() {
        aiworkWatchReconnectTimer?.invalidate()
        aiworkWatchReconnectTimer = nil

        let agents = Array(aiworkWatchClients.keys)
        for agentId in agents {
            stopAiWorkWatchClient(agentId: agentId)
        }
        aiworkHydratedSessionIds.removeAll()
    }

    // MARK: - Client lifecycle

    func reconcileAiWorkWatchClients() {
        guard ConfigInstaller.isAnyAiWorkMonitoringEnabled() else {
            let agents = Array(aiworkWatchClients.keys)
            for agentId in agents {
                stopAiWorkWatchClient(agentId: agentId)
            }
            return
        }
        let ready = AiWorkWatchClient.discoverReadyDaemons()
        let readyIds = Set(ready.map(\.agentId))

        // Drop clients whose daemon disappeared.
        for agentId in aiworkWatchClients.keys where !readyIds.contains(agentId) {
            stopAiWorkWatchClient(agentId: agentId)
        }

        // Start clients for newly ready daemons.
        for daemon in ready where aiworkWatchClients[daemon.agentId] == nil {
            startAiWorkWatchClient(agentId: daemon.agentId, socketPath: daemon.socketPath)
        }

        // Drop sessions whose surface was toggled off in Hooks settings.
        pruneDisabledAiWorkSessions()

        // Stream events can miss stream.completed / tool_result (watch gap,
        // client exit mid-tool). Daemon agent.stats is source of truth for
        // "is a turn actually running" — correct stuck .running/.processing.
        reconcileAiWorkLiveStatuses()
    }

    /// Remove local AiWork sessions whose Hooks toggle is off.
    func pruneDisabledAiWorkSessions() {
        let stale = sessions.compactMap { key, snapshot -> String? in
            guard key.hasPrefix(AppState.aiworkSessionPrefix) else { return nil }
            let source = snapshot.source
            if source == "aiwork" || source == "aiwork-cli" {
                return ConfigInstaller.isEnabled(source: source) ? nil : key
            }
            // Legacy / unknown: resolve from client_type.
            let resolved = AiWorkStatusMapper.codeIslandSource(
                clientType: snapshot.aiworkClientType,
                daemonSessionId: snapshot.providerSessionId
            )
            return ConfigInstaller.isEnabled(source: resolved) ? nil : key
        }
        guard !stale.isEmpty else { return }
        for id in stale {
            if let daemonId = sessions[id]?.providerSessionId
                ?? id.dropPrefix(AppState.aiworkSessionPrefix) {
                aiworkHydratedSessionIds.remove(daemonId)
            }
            sessions.removeValue(forKey: id)
        }
        refreshDerivedState()
    }

    /// Drop every local session for one Hooks surface (`aiwork` or `aiwork-cli`).
    func removeAiWorkSessions(source: String) {
        let stale = sessions.compactMap { key, snapshot -> String? in
            guard key.hasPrefix(AppState.aiworkSessionPrefix) else { return nil }
            if snapshot.source == source { return key }
            let resolved = AiWorkStatusMapper.codeIslandSource(
                clientType: snapshot.aiworkClientType,
                daemonSessionId: snapshot.providerSessionId
            )
            return resolved == source ? key : nil
        }
        for id in stale {
            if let daemonId = sessions[id]?.providerSessionId
                ?? id.dropPrefix(AppState.aiworkSessionPrefix) {
                aiworkHydratedSessionIds.remove(daemonId)
            }
            sessions.removeValue(forKey: id)
        }
        if !stale.isEmpty {
            refreshDerivedState()
        }
    }

    /// Force-idle local AiWork sessions that the daemon no longer lists as busy.
    ///
    /// `sessions.watch` is lossy across reconnects and mid-tool client exits: a
    /// `stream.tool_call` can leave CodeIsland at `.running` forever while the
    /// daemon has already returned to `phase=idle` / `active_requests=0`.
    func reconcileAiWorkLiveStatuses() {
        let stuck = sessions.compactMap {
            key, snapshot -> (key: String, daemonId: String, lastActivity: Date)? in
            guard key.hasPrefix(AppState.aiworkSessionPrefix), snapshot.status != .idle else {
                return nil
            }
            let daemonId = snapshot.providerSessionId
                ?? String(key.dropFirst(AppState.aiworkSessionPrefix.count))
            return (key, daemonId, snapshot.lastActivity)
        }
        guard !stuck.isEmpty else { return }
        guard !aiworkReconcileInFlight else { return }

        // The busy set has to come from the daemon that actually owns the session.
        // Querying one arbitrary socket (dictionary order over aiworkWatchClients)
        // meant a turn genuinely running on daemon B was absent from daemon A's
        // stats and got force-idled after the grace window — so group the stuck
        // sessions per agent and ask each daemon about its own.
        var sockets: [String: String] = [:]
        for (agentId, client) in aiworkWatchClients {
            sockets[agentId] = client.socketPath
        }
        for daemon in AiWorkWatchClient.discoverReadyDaemons()
        where sockets[daemon.agentId] == nil {
            sockets[daemon.agentId] = daemon.socketPath
        }
        // An id with no agent segment can only be attributed when there is exactly
        // one daemon to attribute it to.
        let soleAgent = sockets.count == 1 ? sockets.keys.first : nil
        var groups: [String: [(key: String, daemonId: String, lastActivity: Date)]] = [:]
        for entry in stuck {
            let owner = AiWorkWatchClient.agentId(fromDaemonSessionId: entry.daemonId) ?? soleAgent
            guard let owner, sockets[owner] != nil else { continue }
            groups[owner, default: []].append(entry)
        }
        guard !groups.isEmpty else { return }

        aiworkReconcileInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            var results: [AiWorkBusyReconcileResult] = []
            for (agentId, entries) in groups {
                guard let socketPath = sockets[agentId] else { continue }
                // nil = stats unreachable for this daemon — leave its sessions alone.
                guard let busy = AiWorkStatusMapper.fetchBusyDaemonSessionIds(
                    socketPath: socketPath
                ) else { continue }
                results.append(AiWorkBusyReconcileResult(sessions: entries, busyDaemonIds: busy))
            }
            guard let self else { return }
            await self.finishAiWorkBusyReconcile(results: results)
        }
    }

    /// One daemon's answer: the sessions it owns, and the ids it reports as busy.
    struct AiWorkBusyReconcileResult: Sendable {
        let sessions: [(key: String, daemonId: String, lastActivity: Date)]
        let busyDaemonIds: Set<String>
    }

    /// MainActor tail of `reconcileAiWorkLiveStatuses`: releases the in-flight
    /// guard and applies each daemon's own busy set to its own sessions.
    func finishAiWorkBusyReconcile(results: [AiWorkBusyReconcileResult]) {
        aiworkReconcileInFlight = false
        let now = Date()
        for result in results {
            applyAiWorkBusyReconcile(
                localSessions: result.sessions,
                busyDaemonIds: result.busyDaemonIds,
                now: now
            )
        }
    }

    /// Pure decision + apply seam for tests.
    func applyAiWorkBusyReconcile(
        localSessions: [(key: String, daemonId: String, lastActivity: Date)],
        busyDaemonIds: Set<String>,
        now: Date,
        grace: TimeInterval = 8
    ) {
        var changed = false
        for (key, daemonId, lastActivity) in localSessions {
            guard AiWorkStatusMapper.shouldForceIdleSession(
                daemonSessionId: daemonId,
                lastActivity: lastActivity,
                busyDaemonIds: busyDaemonIds,
                now: now,
                grace: grace
            ) else { continue }
            guard var snapshot = sessions[key], snapshot.status != .idle else { continue }
            // Re-check against the CURRENT activity stamp: `lastActivity` in
            // localSessions was snapshotted before the agent.stats round trip, so a
            // turn that started inside that window would otherwise be judged on
            // pre-turn activity and flashed back to idle.
            if -snapshot.lastActivity.timeIntervalSinceNow <= grace { continue }
            snapshot.status = .idle
            snapshot.currentTool = nil
            snapshot.toolDescription = nil
            sessions[key] = snapshot
            changed = true
        }
        if changed {
            refreshDerivedState()
        }
    }

    private func startAiWorkWatchClient(agentId: String, socketPath: String) {
        guard aiworkWatchClients[agentId] == nil else { return }

        let client = AiWorkWatchClient(socketPath: socketPath)
        client.onFrame = { [weak self] frame in
            Task { @MainActor in
                self?.handleAiWorkFrame(frame, agentId: agentId)
            }
        }
        client.onExit = { [weak self] in
            Task { @MainActor in
                self?.aiworkWatchClients.removeValue(forKey: agentId)
                self?.removeAiWorkSessions(agentId: agentId)
            }
        }

        do {
            try client.start()
            try client.watchSessions(watchAckId: "codeisland-\(agentId)")
        } catch {
            client.stop()
            return
        }

        aiworkWatchClients[agentId] = client
        backfillAiWorkActiveSessions(agentId: agentId, socketPath: socketPath)
    }

    private func stopAiWorkWatchClient(agentId: String) {
        if let client = aiworkWatchClients.removeValue(forKey: agentId) {
            client.stop()
        }
        removeAiWorkSessions(agentId: agentId)
    }

    func removeAiWorkSessions(agentId: String? = nil) {
        let stale: [String]
        if let agentId {
            // Daemon session ids look like `acp:coder:…` / `cli:coder:…`.
            // Match either the agent segment or any session we tagged with this
            // agent via providerSessionId when the prefix is ambiguous.
            stale = sessions.compactMap { key, snapshot in
                guard key.hasPrefix(AppState.aiworkSessionPrefix) else { return nil }
                let daemonId = snapshot.providerSessionId ?? String(key.dropFirst(AppState.aiworkSessionPrefix.count))
                let parts = daemonId.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                // channel:agent:uuid  → parts[1] == agent
                if parts.count >= 2, parts[1] == agentId { return key }
                // Fallback: agent id embedded anywhere in the daemon session id.
                if daemonId.contains(":\(agentId):") { return key }
                return nil
            }
        } else {
            stale = sessions.keys.filter { $0.hasPrefix(AppState.aiworkSessionPrefix) }
        }
        for id in stale {
            sessions.removeValue(forKey: id)
            if let daemonId = id.dropPrefix(AppState.aiworkSessionPrefix) {
                aiworkHydratedSessionIds.remove(daemonId)
            }
        }
        if !stale.isEmpty {
            refreshDerivedState()
        }
    }

    // MARK: - Frame handling

    func handleAiWorkFrame(_ frame: AiWorkFrame, agentId: String) {
        switch frame.kind {
        case .event(let name, _):
            handleAiWorkStreamEvent(name: name, frame: frame, agentId: agentId)
        case .response, .unknown:
            // Watch stream is event-driven; unary responses arrive on a
            // separate short-lived connection used for backfill / hydrate.
            break
        }
    }

    func handleAiWorkStreamEvent(name: String, frame: AiWorkFrame, agentId: String) {
        guard let daemonSessionId = frame.sessionId, !daemonSessionId.isEmpty else { return }

        let mappedStatus = AiWorkStatusMapper.status(forEventName: name)
        // Metadata-only events (e.g. session_info_changed) still update title/cwd.
        let isMetadataEvent = name == "stream.session_info_changed"
            || name == "stream.session_mode_changed"
            || name == "stream.session_config_changed"
        guard mappedStatus != nil || isMetadataEvent || frame.dataObject?["session"] != nil else {
            return
        }

        let sessionId = AppState.aiworkSessionPrefix + daemonSessionId
        let isNew = sessions[sessionId] == nil
        // A status-less event for a conversation we are not already tracking is
        // history, not activity. Creating a card from one would surface long-
        // finished conversations (backfill deliberately skips idle entries for the
        // same reason), so only an event that maps to a status may open a card.
        if mappedStatus == nil, isNew { return }
        var snapshot = sessions[sessionId] ?? SessionSnapshot(startTime: Date())
        snapshot.providerSessionId = daemonSessionId
        AppState.applyAiWorkAppIdentity(&snapshot)

        AppState.applyAiWorkSessionMetadata(&snapshot, data: frame.dataObject)

        let source = AiWorkStatusMapper.codeIslandSource(
            clientType: snapshot.aiworkClientType,
            daemonSessionId: daemonSessionId
        )
        guard ConfigInstaller.isEnabled(source: source) else {
            // `source` is only a guess until sessions.get returns client_type: a
            // modern `aiwork tui` session also carries the `acp:` prefix, so it
            // reads as GUI here. Dropping it now would mean hydrate never runs, the
            // real client_type is never learned, and a "CLI on / GUI off" setup
            // would silently lose every TUI session forever. Hydrate first and let
            // the post-hydrate guard — which sees the real client_type — decide.
            if snapshot.aiworkClientType == nil,
               ConfigInstaller.isAnyAiWorkMonitoringEnabled() {
                hydrateAiWorkSessionIfNeeded(daemonSessionId: daemonSessionId, agentId: agentId)
                return
            }
            // Surface toggled off — drop any leftover card for this session.
            if sessions[sessionId] != nil {
                sessions.removeValue(forKey: sessionId)
                aiworkHydratedSessionIds.remove(daemonSessionId)
                refreshDerivedState()
            }
            return
        }
        snapshot.source = source

        if let newStatus = mappedStatus {
            AppState.applyAiWorkStreamEvent(
                &snapshot,
                eventName: name,
                data: frame.dataObject,
                status: newStatus
            )
        }

        // Only a status-bearing event counts as activity: refreshing this on every
        // metadata event would keep resetting the idle sweep's grace window, so a
        // finished conversation's card would never be collected.
        if mappedStatus != nil {
            snapshot.lastActivity = Date()
        }
        sessions[sessionId] = snapshot

        if AiWorkStatusMapper.isTerminalEvent(name) {
            enqueueCompletion(sessionId)
        }

        // Sound: reuse the event names the hook-driven sources emit so the existing
        // per-event toggles in Sound settings apply unchanged. Deliberately narrow —
        // one sound per turn boundary, never per streaming delta.
        switch name {
        case "stream.started":
            SoundManager.shared.handleEvent(isNew ? "SessionStart" : "UserPromptSubmit")
        case "stream.approval_required", "stream.plan_confirmation_required":
            SoundManager.shared.handleEvent("PermissionRequest")
        case "stream.question_required":
            SoundManager.shared.handleEvent("PermissionRequest")
        case "stream.completed":
            SoundManager.shared.handleEvent("Stop")
        case "stream.failed":
            SoundManager.shared.handleEvent("PostToolUseFailure")
        default:
            break
        }

        refreshDerivedState()

        // Title/cwd/client_type often arrive only via sessions.get —
        // hydrate when we first see the session or when those fields are missing.
        if isNew
            || snapshot.sessionTitle == nil
            || snapshot.cwd == nil
            || snapshot.aiworkClientType == nil {
            hydrateAiWorkSessionIfNeeded(
                daemonSessionId: daemonSessionId,
                agentId: agentId
            )
        }
    }

    /// Pure reducer used by live events and unit tests.
    static func applyAiWorkStreamEvent(
        _ snapshot: inout SessionSnapshot,
        eventName: String,
        data: [String: AnyCodableLike]?,
        status: AgentStatus
    ) {
        snapshot.status = status
        switch eventName {
        case "stream.started":
            // Mirror Claude UserPromptSubmit: keep the user turn in recentMessages
            // so idle cards still show `>` / `$` chat lines after completion.
            if let prompt = aiworkUserPrompt(from: data), !prompt.isEmpty {
                snapshot.lastUserPrompt = prompt
                let last = snapshot.recentMessages.last
                if last?.isUser != true || last?.text != prompt {
                    snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
                }
            }
            snapshot.lastAssistantMessage = nil
            snapshot.currentTool = nil
            snapshot.toolDescription = nil

        case "stream.tool_call":
            snapshot.currentTool = AiWorkStatusMapper.toolName(from: data)
            snapshot.toolDescription = AiWorkStatusMapper.toolDescription(from: data)
            if let tool = snapshot.currentTool {
                snapshot.recordTool(
                    tool,
                    description: snapshot.toolDescription,
                    success: true,
                    agentType: nil,
                    maxHistory: 20
                )
            }

        case "stream.progress",
             "stream.thinking_delta",
             "stream.text_delta",
             "stream.ack",
             "stream.fallback_started":
            snapshot.currentTool = AiWorkStatusMapper.progressLabel(from: data, eventName: eventName)
            if let text = AiWorkStatusMapper.progressText(from: data) {
                if eventName == "stream.text_delta" || eventName == "stream.thinking_delta" {
                    // Deltas are tiny fragments. Putting each one into toolDescription
                    // (a) looks like noise and (b) re-triggers MorphText's blur on every
                    // token so the `$` row stays permanently blurred while streaming.
                    // Accumulate into lastAssistantMessage and show a trailing preview.
                    let existing = snapshot.lastAssistantMessage ?? ""
                    let merged = existing.isEmpty ? text : (existing + text)
                    snapshot.lastAssistantMessage = String(merged.suffix(800))
                    let preview = String(merged.suffix(200))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    snapshot.toolDescription = preview.isEmpty
                        ? snapshot.currentTool
                        : AiWorkStatusMapper.truncate(preview, max: 160)
                } else {
                    snapshot.toolDescription = text
                }
            } else if snapshot.toolDescription == nil {
                snapshot.toolDescription = snapshot.currentTool
            }

        case "stream.tool_result":
            // Brief linger: keep the tool name but mark completion via description
            // until the next progress/thinking event arrives.
            if snapshot.currentTool == nil {
                snapshot.currentTool = AiWorkStatusMapper.toolName(from: data)
            }
            snapshot.toolDescription = AiWorkStatusMapper.toolDescription(from: data)
                ?? snapshot.currentTool
            snapshot.status = .processing

        case "stream.approval_required",
             "stream.plan_confirmation_required":
            snapshot.currentTool = AiWorkStatusMapper.toolName(from: data)
                ?? data?["command"]?.asString
                ?? "approval"
            snapshot.toolDescription = data?["command"]?.asString
                ?? data?["reason"]?.asString
                ?? snapshot.toolDescription

        case "stream.question_required":
            snapshot.currentTool = "question"
            snapshot.toolDescription = data?["message"]?.asString
                ?? AiWorkStatusMapper.progressText(from: data)
                ?? "waiting for answer"

        case "stream.approval_resolved",
             "stream.plan_confirmation_resolved",
             "stream.question_resolved":
            snapshot.currentTool = "working"
            snapshot.toolDescription = nil

        case "stream.completed",
             "stream.failed",
             "stream.aborted":
            finalizeAiWorkTurnMessages(&snapshot, data: data, eventName: eventName)
            snapshot.currentTool = nil
            snapshot.toolDescription = nil

        default:
            break
        }
    }

    /// Pull the observer-facing user prompt from `stream.started` (daemon
    /// `display_text`) or common prompt aliases.
    static func aiworkUserPrompt(from data: [String: AnyCodableLike]?) -> String? {
        guard let data else { return nil }
        let candidates = [
            data["display_text"]?.asString,
            data["prompt"]?.asString,
            data["text"]?.asString,
            data["message"]?.asString,
            data["user_message"]?.asString,
            data["session"]?.asObject?["title"]?.asString
        ]
        for raw in candidates {
            guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                continue
            }
            return AiWorkStatusMapper.truncate(text, max: 200)
        }
        return nil
    }

    /// Mirror Claude `Stop`: keep chat preview after the turn goes idle.
    /// Localized stand-in when a turn ends with no assistant text of its own.
    /// Routed through L10n so this cannot regress to hardcoded Chinese literals —
    /// v1.0.33 (#322) shipped exactly that fix for `reply_complete_placeholder`,
    /// and L10nTests asserts these values are never bracketed.
    static func aiworkTerminalPlaceholder(eventName: String) -> String {
        switch eventName {
        case "stream.failed": return L10n.shared["reply_failed_placeholder"]
        case "stream.aborted": return L10n.shared["reply_aborted_placeholder"]
        default: return L10n.shared["reply_complete_placeholder"]
        }
    }

    static func finalizeAiWorkTurnMessages(
        _ snapshot: inout SessionSnapshot,
        data: [String: AnyCodableLike]?,
        eventName: String
    ) {
        let noticeSummary = data?["terminal_notice"]?.asObject?["summary"]?.asString
        let finalText = data?["final_text"]?.asString
            ?? data?["text"]?.asString
            ?? noticeSummary
            ?? snapshot.lastAssistantMessage

        if let msg = finalText?.trimmingCharacters(in: .whitespacesAndNewlines), !msg.isEmpty {
            let clipped = AiWorkStatusMapper.truncate(msg, max: 200)
            snapshot.lastAssistantMessage = String(msg.suffix(800))
            let last = snapshot.recentMessages.last
            if last?.isUser == true || last?.text != clipped {
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: clipped))
            }
        } else if snapshot.recentMessages.last?.isUser == true {
            let placeholder = AppState.aiworkTerminalPlaceholder(eventName: eventName)
            snapshot.addRecentMessage(ChatMessage(isUser: false, text: placeholder))
        }

        // Late attach / missed stream.started: still leave a visible idle preview.
        if snapshot.recentMessages.isEmpty {
            if let prompt = snapshot.lastUserPrompt
                ?? snapshot.sessionTitle
                ?? aiworkUserPrompt(from: data) {
                snapshot.lastUserPrompt = snapshot.lastUserPrompt ?? prompt
                snapshot.addRecentMessage(ChatMessage(isUser: true, text: prompt))
                let placeholder = AppState.aiworkTerminalPlaceholder(eventName: eventName)
                snapshot.addRecentMessage(ChatMessage(isUser: false, text: placeholder))
            }
        }
    }

    static func applyAiWorkSessionMetadata(
        _ snapshot: inout SessionSnapshot,
        data: [String: AnyCodableLike]?
    ) {
        guard let data else { return }
        let sessionObj = data["session"]?.asObject

        if let cwd = sessionObj?["cwd"]?.asString ?? data["cwd"]?.asString, !cwd.isEmpty {
            snapshot.cwd = cwd
        }
        if let title = sessionObj?["title"]?.asString ?? data["title"]?.asString, !title.isEmpty {
            snapshot.sessionTitle = title
        }
        if let model = sessionObj?["model"]?.asString ?? data["model"]?.asString, !model.isEmpty {
            snapshot.model = model
        }
        if let clientType = sessionObj?["client_type"]?.asString
            ?? data["client_type"]?.asString,
           !clientType.isEmpty {
            snapshot.aiworkClientType = clientType
        }
        if let prompt = data["prompt"]?.asString
            ?? data["user_prompt"]?.asString
            ?? sessionObj?["last_user_prompt"]?.asString,
           !prompt.isEmpty {
            snapshot.lastUserPrompt = String(prompt.prefix(240))
        }
        if let signal = sessionObj?["readable_summary"]?.asObject?["signal"]?.asString,
           !signal.isEmpty,
           snapshot.toolDescription == nil,
           snapshot.status != .idle {
            snapshot.toolDescription = AiWorkStatusMapper.truncate(signal, max: 160)
        }
    }

    // MARK: - Hydrate / backfill

    /// Fetch `sessions.get` so the notch can show the real conversation title
    /// and the correct GUI/TUI client label (`client_type` is get-only).
    func hydrateAiWorkSessionIfNeeded(daemonSessionId: String, agentId: String) {
        let key = AppState.aiworkSessionPrefix + daemonSessionId
        let snap = sessions[key]
        if snap?.sessionTitle != nil, snap?.aiworkClientType != nil {
            return
        }
        // In-flight / already attempted — avoid spamming sessions.get on every event.
        if aiworkHydratedSessionIds.contains(daemonSessionId) { return }
        aiworkHydratedSessionIds.insert(daemonSessionId)

        let socketPath = aiworkWatchClients[agentId]?.socketPath
            ?? AiWorkWatchClient.discoverReadyDaemons()
                .first(where: { $0.agentId == agentId })?
                .socketPath
        guard let socketPath else {
            aiworkHydratedSessionIds.remove(daemonSessionId)
            return
        }

        // `self` is bound once up front rather than reached through `self?.` inside
        // nested MainActor.run closures — that pattern is a captured-var-in-
        // concurrent-code warning today and an error under the Swift 6 language mode.
        Task.detached(priority: .utility) { [weak self] in
            let frame = AiWorkWatchClient.unaryCall(
                socketPath: socketPath,
                method: "sessions.get",
                params: ["sessionId": daemonSessionId],
                timeoutSeconds: 5
            )
            guard let self else { return }
            guard let frame, case .response(_, true) = frame.kind else {
                await self.releaseAiWorkHydrateMarker(daemonSessionId)
                return
            }
            guard let entry = frame.dataObject?["session"]?.asObject ?? frame.dataObject else {
                await self.releaseAiWorkHydrateMarker(daemonSessionId)
                return
            }
            await self.applyAiWorkHydrate(key: key, daemonSessionId: daemonSessionId, entry: entry)
        }
    }

    /// Let a later event retry `sessions.get` after a failed hydrate.
    func releaseAiWorkHydrateMarker(_ daemonSessionId: String) {
        aiworkHydratedSessionIds.remove(daemonSessionId)
    }

    /// MainActor tail of `hydrateAiWorkSessionIfNeeded`.
    func applyAiWorkHydrate(
        key: String,
        daemonSessionId: String,
        entry: [String: AnyCodableLike]
    ) {
        var snapshot = sessions[key] ?? SessionSnapshot(startTime: Date())
        snapshot.providerSessionId = daemonSessionId
        AppState.applyAiWorkAppIdentity(&snapshot)
        AppState.applyAiWorkListEntry(
            &snapshot,
            daemonSessionId: daemonSessionId,
            entry: entry,
            preserveLiveStatus: true
        )
        guard ConfigInstaller.isEnabled(source: snapshot.source) else {
            sessions.removeValue(forKey: key)
            aiworkHydratedSessionIds.remove(daemonSessionId)
            refreshDerivedState()
            return
        }
        sessions[key] = snapshot
        refreshDerivedState()
    }

    /// On connect, pull currently-busy sessions so the notch isn't empty until
    /// the next live event. Idle historical sessions are intentionally skipped.
    ///
    /// Both RPCs below block their calling thread (`unaryCall` waits on a
    /// DispatchGroup), so they must never run on this MainActor-isolated type: a
    /// daemon that accepts the connection but never answers would otherwise freeze
    /// the UI for the full timeout. Same off-main shape as
    /// `hydrateAiWorkSessionIfNeeded` — only the apply steps hop back to main.
    func backfillAiWorkActiveSessions(agentId: String, socketPath: String) {
        Task.detached(priority: .utility) { [weak self] in
            // Prefer agent.stats active_request_details when present; fall back to
            // sessions.list filtered by AiWorkStatusMapper.isActiveListEntry.
            let stats = AiWorkWatchClient.unaryCall(
                socketPath: socketPath,
                method: "agent.stats",
                params: [String: Any]()
            )
            var statsRows: [AnyCodableLike] = []
            if let stats, case .response(_, true) = stats.kind,
               case .array(let rows) = stats.dataObject?["active_request_details"] {
                statsRows = rows
            }
            guard let self else { return }
            if await self.applyAiWorkStatsBackfill(agentId: agentId, rows: statsRows) {
                return
            }

            let list = AiWorkWatchClient.unaryCall(
                socketPath: socketPath,
                method: "sessions.list",
                params: ["limit": 50]
            )
            guard let list, case .response(_, true) = list.kind,
                  case .array(let listRows) = list.dataObject?["sessions"] else {
                return
            }
            await self.applyAiWorkListBackfill(agentId: agentId, rows: listRows)
        }
    }

    /// Apply `agent.stats` rows. Returns true when at least one card was written,
    /// in which case `sessions.list` is not consulted.
    @discardableResult
    func applyAiWorkStatsBackfill(agentId: String, rows: [AnyCodableLike]) -> Bool {
        guard !rows.isEmpty else { return false }
        var applied = false
        for row in rows {
            guard let obj = row.asObject else { continue }
            let sid = obj["session_id"]?.asString
                ?? obj["sessionId"]?.asString
            guard let sid, !sid.isEmpty else { continue }
            let sessionId = AppState.aiworkSessionPrefix + sid
            var snapshot = sessions[sessionId] ?? SessionSnapshot(startTime: Date())
            snapshot.providerSessionId = sid
            AppState.applyAiWorkAppIdentity(&snapshot)
            // Prefer client_type from the stats row when present; otherwise
            // keep existing / fall back via session id until hydrate.
            if let clientType = obj["client_type"]?.asString, !clientType.isEmpty {
                snapshot.aiworkClientType = clientType
            }
            let source = AiWorkStatusMapper.codeIslandSource(
                clientType: snapshot.aiworkClientType,
                daemonSessionId: sid
            )
            guard ConfigInstaller.isEnabled(source: source) else { continue }
            snapshot.source = source
            if let cwd = obj["cwd"]?.asString, !cwd.isEmpty {
                snapshot.cwd = cwd
            }
            let phase = obj["phase"]?.asString
            switch phase {
            case "tool_execution":
                snapshot.status = .running
                snapshot.currentTool = "tool"
            default:
                snapshot.status = .processing
                snapshot.currentTool = AiWorkStatusMapper.compactPhaseLabel(phase ?? "llm_streaming")
            }
            if let label = obj["phase_label"]?.asString, !label.isEmpty {
                snapshot.toolDescription = label
            } else if let phase {
                snapshot.toolDescription = AiWorkStatusMapper.compactPhaseLabel(phase)
            }
            snapshot.lastActivity = Date()
            sessions[sessionId] = snapshot
            applied = true
            hydrateAiWorkSessionIfNeeded(daemonSessionId: sid, agentId: agentId)
        }
        if applied {
            refreshDerivedState()
        }
        return applied
    }

    /// Apply `sessions.list` rows, filtered to active entries owned by `agentId`.
    func applyAiWorkListBackfill(agentId: String, rows: [AnyCodableLike]) {
        var applied = false
        for row in rows {
            guard let entry = row.asObject else { continue }
            guard AiWorkStatusMapper.isActiveListEntry(entry) else { continue }
            guard let sid = entry["session_id"]?.asString, !sid.isEmpty else { continue }
            // Keep backfill scoped to this agent when the id is embedded.
            if !sid.contains(":\(agentId):"), !sid.hasSuffix(":\(agentId)"), sid != agentId {
                // Still accept ids like `acp:coder:uuid`.
                let parts = sid.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                if parts.count >= 2, parts[1] != agentId { continue }
            }

            let sessionId = AppState.aiworkSessionPrefix + sid
            var snapshot = sessions[sessionId] ?? SessionSnapshot(startTime: Date())
            AppState.applyAiWorkListEntry(
                &snapshot,
                daemonSessionId: sid,
                entry: entry,
                preserveLiveStatus: false
            )
            guard ConfigInstaller.isEnabled(source: snapshot.source) else { continue }
            sessions[sessionId] = snapshot
            applied = true
            aiworkHydratedSessionIds.insert(sid)
        }
        if applied {
            refreshDerivedState()
        }
    }

    /// Tag AiWork sessions with the IDE bundle so TerminalBadge can show the
    /// app icon + "AiWork" / "AiWork CLI" label (same pattern as Cursor).
    /// Bundle id did not change with the AiWork → AiWork rename.
    static let aiworkAppBundleId = "com.alipay.dtcoder.ide"

    static func applyAiWorkAppIdentity(_ snapshot: inout SessionSnapshot) {
        snapshot.termBundleId = aiworkAppBundleId
        snapshot.termApp = "AiWork"
    }

    /// Test seam / shared apply for list/get projections.
    static func applyAiWorkListEntry(
        _ snapshot: inout SessionSnapshot,
        daemonSessionId: String,
        entry: [String: AnyCodableLike],
        preserveLiveStatus: Bool = false
    ) {
        snapshot.providerSessionId = daemonSessionId
        applyAiWorkAppIdentity(&snapshot)
        if let cwd = entry["cwd"]?.asString, !cwd.isEmpty {
            snapshot.cwd = cwd
        }
        if let title = entry["title"]?.asString, !title.isEmpty {
            snapshot.sessionTitle = title
        }
        if let model = entry["model"]?.asString, !model.isEmpty {
            snapshot.model = model
        }
        if let clientType = entry["client_type"]?.asString, !clientType.isEmpty {
            snapshot.aiworkClientType = clientType
        }
        snapshot.source = AiWorkStatusMapper.codeIslandSource(
            clientType: snapshot.aiworkClientType,
            daemonSessionId: daemonSessionId
        )
        if !preserveLiveStatus || snapshot.status == .idle {
            snapshot.status = AiWorkStatusMapper.agentStatus(fromListEntry: entry)
        }
        if snapshot.toolDescription == nil,
           let signal = entry["readable_summary"]?.asObject?["signal"]?.asString,
           !signal.isEmpty,
           snapshot.status != .idle {
            snapshot.toolDescription = AiWorkStatusMapper.truncate(signal, max: 160)
            if snapshot.currentTool == nil {
                let phase = entry["readable_summary"]?.asObject?["phase"]?.asString
                snapshot.currentTool = AiWorkStatusMapper.compactPhaseLabel(phase ?? "working")
            }
        }
        snapshot.lastActivity = Date()
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
