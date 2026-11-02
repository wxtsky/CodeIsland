import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "PermissionDeny")

/// Cached metadata for an in-flight tool call (``ToolUseKey``), written on PreToolUse and
/// consumed by downstream PermissionRequest / PostToolUse events of the same card.
///
/// This lets us (1) correlate PermissionRequest payloads back to the originating tool
/// invocation even when some providers strip fields on re-emit, (2) drain stale queue
/// entries when the agent moved on (PostToolUse arrives while a PermissionRequest for
/// the same call is still queued), (3) dedupe duplicate PermissionRequest replays, and
/// (4) know a finishing call by the input it was asked with, for a request that carries
/// no tool_use_id (``AppState/resolveOrphanPermissionsOnActivity(_:)``).
struct PreToolUseRecord {
    let sessionId: String
    let toolName: String?
    let toolDescription: String?
    let toolInput: [String: Any]?
    let receivedAt: Date
}

/// A tool call, named by the card it is filed under and the id its agent gave it.
///
/// Agents mint their own tool_use_ids, and another host's agent — or a process
/// there passing itself off as one — can put any id it likes in a hook. An id
/// alone must never reach another card's request: to drop it, to take its card
/// over with a replay, or to catch the user's answer to it. The card session id
/// carries the host (`remote:<host>:…`), so two hosts never share a key.
struct ToolUseKey: Hashable {
    let sessionId: String
    let toolUseId: String

    init(sessionId: String, toolUseId: String) {
        self.sessionId = sessionId
        self.toolUseId = toolUseId
    }

    /// The event's tool call; nil when it carries no tool_use_id.
    init?(_ event: HookEvent) {
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return nil }
        self.init(sessionId: event.sessionId ?? "default", toolUseId: toolUseId)
    }
}

extension PermissionRequest {
    /// The tool call this request is for; nil when its agent sent no tool_use_id.
    var toolUseKey: ToolUseKey? { ToolUseKey(event) }
}

extension AppState {
    /// TTL for cached PreToolUse records. Generous — tool calls may block on user input
    /// or long-running subprocesses; pruning reclaims memory for aborted/abandoned ids.
    static let pendingToolUseTTL: TimeInterval = 900  // 15 minutes

    /// The answer to a held request that decides nothing.
    ///
    /// The island answers for the user only when the user answers. A request
    /// it takes off the queue for any other reason — its agent got past it,
    /// its session ended — gets this, and the agent goes on as it would
    /// without the island:
    /// - Claude Code, Codex and the Claude-format hooks (Qoder, CodeBuddy,
    ///   Trae, custom CLIs) find no `hookSpecificOutput.decision` and keep to
    ///   their own approval prompt; ZCode, whose schema is strict, falls back
    ///   to its own dialog.
    /// - Gemini CLI gets `{}` through the bridge's decision translation: no
    ///   `decision`, so its own policy and confirmation decide.
    /// - pi's, OMP's and OpenClaw's plugins find no `behavior` and fall
    ///   through to the agent's own gate, as when the island is not running;
    ///   OpenCode's plugin sends OpenCode no reply, which keeps its own prompt.
    /// - Nothing of Cursor's, Copilot's or Antigravity's is ever held: the
    ///   bridge prints nothing to a Cursor hook, Copilot sends no permission
    ///   request, and Antigravity's `PreToolUse` is answered `ask` at the edge.
    nonisolated static let noDecisionAnswer = Data("{}".utf8)

    /// "Allow" this one call, and nothing more. Codex's PermissionRequest
    /// output fails closed on anything else (codex-rs/hooks/schema/generated/
    /// permission-request.command.output.schema.json: `updatedPermissions`
    /// is reserved), and the bridge reduces it to Gemini's `{"decision":"allow"}`.
    nonisolated static let plainAllowAnswer = Data(
        #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8
    )

    /// Cache a PreToolUse so later PermissionRequest / PostToolUse events of the
    /// same card carrying the same tool_use_id can be correlated back to the
    /// originating invocation.
    func cachePreToolUseIfApplicable(_ event: HookEvent) {
        guard EventNormalizer.normalize(event.eventName) == "PreToolUse" else { return }
        guard let key = ToolUseKey(event) else { return }

        pendingToolUses[key] = PreToolUseRecord(
            sessionId: key.sessionId,
            toolName: event.activityLabel,
            toolDescription: event.toolDescription,
            toolInput: event.toolInput,
            receivedAt: Date()
        )
    }

    /// Drop cache entries for a completed tool invocation. If a PermissionRequest for the
    /// same call is still sitting in the queue (e.g. agent moved on after a local timeout),
    /// drop it, with no decision, so we don't hold the UI hostage to a dead waiter.
    /// Only the request's own card names that call (``ToolUseKey``).
    func resolveToolUseIfCompleted(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard normalized == "PostToolUse"
                || normalized == "PostToolUseFailure"
                || normalized == "PermissionDenied"
        else { return }
        guard let key = ToolUseKey(event) else { return }

        pendingToolUses.removeValue(forKey: key)

        guard let staleIndex = permissionQueue.firstIndex(where: { $0.toolUseKey == key })
        else { return }

        if shouldKeepQueuedPermissionForCompletedEvent(
            event, queued: permissionQueue[staleIndex], normalizedEventName: normalized
        ) {
            return
        }

        dropPermissionsTheirAgentGotPast(at: [staleIndex], reason: "resolveToolUseIfCompleted", triggerEvent: normalized)
    }

    /// What shows an agent got past a request it asked: a tool step of its
    /// own, its turn ending, its user typing again. A new request or question
    /// has enqueue paths of its own.
    private static let movedOnEvents: Set<String> = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "UserPromptSubmit"
    ]

    /// Drops the requests with no tool_use_id that `event` shows their agent
    /// already got past (#216).
    ///
    /// Claude Code's and Codex's PermissionRequest carry no tool_use_id, so
    /// nothing correlates one with what follows it: answered in the terminal,
    /// its card stayed up. A later step of the agent that asked is the sign it
    /// moved on — but only of that agent. Subagents share their parent's
    /// session_id and go on working while it waits on the user (a background
    /// one, or several Task agents at once), and a sibling's Read says nothing
    /// about a pending `rm -rf`. Where the step names a tool call, it must be
    /// the request's: another call of the same agent is not this one (#147).
    /// The call is known by the input it was asked with, which its PreToolUse
    /// recorded: the host that ran it may have changed the input it finished
    /// with (the Claude app's `propose_branch` does, answered in the app).
    ///
    /// Nor is the step ever taken for the user's answer. What the user chose
    /// in the terminal is not known here — a denied call is followed by a
    /// prompt just as an approved one is by its PostToolUse — and whoever can
    /// send a hook to the socket can send this step. The request is answered
    /// with no decision (``noDecisionAnswer``), which leaves it to the agent's
    /// own prompt: where it was answered, if its hook is still waiting at all.
    func resolveOrphanPermissionsOnActivity(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard Self.movedOnEvents.contains(normalized) else { return }

        let sessionId = event.sessionId ?? "default"
        let calledWith = ToolUseKey(event).flatMap { pendingToolUses[$0] }?.toolInput
        let stale = permissionQueue.indices.filter { index in
            let request = permissionQueue[index]
            return (request.event.sessionId ?? "default") == sessionId
                && (request.toolUseId?.isEmpty ?? true)
                && Self.step(event, calledWith: calledWith, isPastRequest: request.event)
        }
        dropPermissionsTheirAgentGotPast(at: stale, reason: "resolveOrphanPermissionsOnActivity", triggerEvent: normalized)
    }

    /// Whether `step` comes from the agent that asked `request` — the same
    /// subagent, or the main thread for the main thread's — and, where both
    /// name a tool call, is that call. `calledWith` is the input the step's
    /// call had at its PreToolUse, where that was seen; it or the step's own
    /// input must be the request's.
    nonisolated static func step(
        _ step: HookEvent, calledWith: [String: Any]?, isPastRequest request: HookEvent
    ) -> Bool {
        guard step.agentId == request.agentId else { return false }
        if let tool = step.toolName, let asked = request.toolName, tool != asked {
            return false
        }
        let inputs = [step.toolInput, calledWith].compactMap { $0 }
        if let asked = request.toolInput, !inputs.isEmpty,
           !inputs.contains(where: { NSDictionary(dictionary: $0).isEqual(to: asked) }) {
            return false
        }
        return true
    }

    /// Takes requests off the queue that their agent already got past, each
    /// answered with no decision. A card showing one moves on to the next
    /// request, or folds.
    private func dropPermissionsTheirAgentGotPast(at indices: [Int], reason: String, triggerEvent: String) {
        guard !indices.isEmpty else { return }
        let dropped = indices.map { permissionQueue[$0] }
        let droppedIds = Set(dropped.map(\.id))
        let headWasDropped = indices.contains(0)
        permissionQueue.removeAll { droppedIds.contains($0.id) }
        for stale in dropped {
            log.notice("⚠️ permission dropped, no decision reason=\(reason, privacy: .public) session=\(stale.event.sessionId ?? "nil", privacy: .public) toolUseId=\(stale.toolUseId ?? "nil", privacy: .public) tool=\(stale.event.toolName ?? "nil", privacy: .public) triggerEvent=\(triggerEvent, privacy: .public)")
            stale.continuation.resume(returning: Self.noDecisionAnswer)
        }

        // If the card we were showing was a dropped one, advance to the next
        // pending request (or collapse if nothing is left). A card the user
        // opened on a request further down the queue counts too.
        let cardLostItsRequest = surface.approvalSessionId.map { pendingPermission(forSession: $0) == nil } ?? false
        if headWasDropped || cardLostItsRequest {
            if permissionQueue.isEmpty {
                if case .approvalCard = surface {
                    surface = .collapsed
                }
            } else {
                showNextPending()
            }
        }
    }

    /// Remove stale cache entries. Called from the cleanup timer tick.
    ///
    /// A card's records stay while a request with no tool_use_id waits in it:
    /// the call it asks about is known by its PreToolUse until that call
    /// finishes (``resolveOrphanPermissionsOnActivity(_:)``), however long the
    /// user takes to answer where it was asked.
    func prunePendingToolUses(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-AppState.pendingToolUseTTL)
        let cardsWaiting = Set(permissionQueue
            .filter { $0.toolUseId?.isEmpty ?? true }
            .map { $0.event.sessionId ?? "default" })
        pendingToolUses = pendingToolUses.filter { key, record in
            record.receivedAt >= cutoff || cardsWaiting.contains(key.sessionId)
        }
    }

    /// Try to merge this permission request into an existing queue entry for the same
    /// tool call — same card, same tool_use_id (``ToolUseKey``). Returns true when the
    /// new arrival was treated as a replay and its continuation has already been
    /// resolved (caller must not enqueue).
    ///
    /// Behavior: the newer continuation replaces the queued one in-place. The older
    /// continuation is answered with no decision so the prior waiter doesn't hang —
    /// a replay is no answer to the request it repeats, and where an agent folds
    /// several hooks' answers (Codex: any deny wins) a deny here would outvote the
    /// user's answer to the new waiter. The queue slot and its position remain the
    /// same so the visible card doesn't reshuffle under the user.
    func mergeDuplicatePermissionRequest(_ request: PermissionRequest) -> Bool {
        guard let key = request.toolUseKey else { return false }
        guard let existingIndex = permissionQueue.firstIndex(where: { $0.toolUseKey == key })
        else { return false }

        let existing = permissionQueue[existingIndex]
        // #169: a shared tool_use_id alone is not enough to call this a replay.
        // Claude Code can emit several *parallel* tool calls (e.g. reading 4
        // files at once); if they carry the same id but different inputs they are
        // distinct requests and each needs its own decision. Treat it as a replay
        // — answer the old waiter, keep the new one in place — only when the tool
        // inputs match. Otherwise let the new request enqueue on its own.
        let existingInput = existing.event.toolInput ?? [:]
        let newInput = request.event.toolInput ?? [:]
        guard NSDictionary(dictionary: existingInput).isEqual(to: NSDictionary(dictionary: newInput)) else {
            return false
        }
        log.notice("⚠️ permission replayed, old waiter gets no decision reason=mergeDuplicatePermissionRequest session=\(key.sessionId, privacy: .public) toolUseId=\(key.toolUseId, privacy: .public) tool=\(existing.event.toolName ?? "nil", privacy: .public)")
        existing.continuation.resume(returning: Self.noDecisionAnswer)
        // Same request, new waiter: it keeps its identity, so its reminders
        // and the card showing it carry on rather than starting over. It now
        // goes with the new waiter's hook; the old one has its answer.
        permissionQueue[existingIndex] = PermissionRequest(
            id: existing.id,
            event: request.event,
            continuation: request.continuation,
            hookConnectionId: request.hookConnectionId,
            alwaysScope: existing.alwaysScope
        )
        return true
    }

    func shouldKeepQueuedPermissionForCompletedEvent(
        _ event: HookEvent,
        queued: PermissionRequest,
        normalizedEventName: String
    ) -> Bool {
        guard normalizedEventName != "PermissionDenied" else { return false }

        let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
            ?? SessionSnapshot.normalizedSupportedSource(queued.event.rawJSON["_source"] as? String)

        switch source {
        case "trae", "traecn", "traecli":
            return true
        default:
            return false
        }
    }

    /// Backfill tool metadata from the cached PreToolUse when the PermissionRequest
    /// payload is missing fields (observed with some third-party CLIs that re-emit
    /// permission events without replaying the tool input).
    func enrichPermissionRequestFromCache(sessionId: String, event: HookEvent) {
        guard let key = ToolUseKey(event), let record = pendingToolUses[key] else { return }

        if sessions[sessionId]?.currentTool == nil, let name = record.toolName {
            sessions[sessionId]?.currentTool = name
        }
        if sessions[sessionId]?.toolDescription == nil, let desc = record.toolDescription {
            sessions[sessionId]?.toolDescription = desc
        }
    }
}
