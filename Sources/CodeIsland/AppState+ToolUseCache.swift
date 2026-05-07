import Foundation
import os.log
import CodeIslandCore

private let log = Logger(subsystem: "com.codeisland", category: "PermissionDeny")

/// Cached metadata for an in-flight tool_use_id, written on PreToolUse and consumed by
/// downstream PermissionRequest / PostToolUse events.
///
/// This lets us (1) correlate PermissionRequest payloads back to the originating tool
/// invocation even when some providers strip fields on re-emit, (2) drain stale queue
/// entries when the agent moved on (PostToolUse arrives while a PermissionRequest for
/// the same id is still queued), and (3) dedupe duplicate PermissionRequest replays.
struct PreToolUseRecord {
    let sessionId: String
    let toolName: String?
    let toolDescription: String?
    let toolInput: [String: Any]?
    let receivedAt: Date
}

extension AppState {
    /// TTL for cached PreToolUse records. Generous — tool calls may block on user input
    /// or long-running subprocesses; pruning reclaims memory for aborted/abandoned ids.
    static let pendingToolUseTTL: TimeInterval = 900  // 15 minutes

    /// Cache a PreToolUse so later PermissionRequest / PostToolUse events carrying the
    /// same tool_use_id can be correlated back to the originating invocation.
    func cachePreToolUseIfApplicable(_ event: HookEvent) {
        guard EventNormalizer.normalize(event.eventName) == "PreToolUse" else { return }
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }

        pendingToolUses[toolUseId] = PreToolUseRecord(
            sessionId: event.sessionId ?? "default",
            toolName: event.toolName,
            toolDescription: event.toolDescription,
            toolInput: event.toolInput,
            receivedAt: Date()
        )
    }

    /// Drop cache entries for a completed tool invocation. If a PermissionRequest for the
    /// same id is still sitting in the queue (e.g. agent moved on after a local timeout),
    /// drain it with a deny so we don't hold the UI hostage to a dead waiter.
    func resolveToolUseIfCompleted(_ event: HookEvent) {
        let normalized = EventNormalizer.normalize(event.eventName)
        guard normalized == "PostToolUse"
                || normalized == "PostToolUseFailure"
                || normalized == "PermissionDenied"
        else { return }
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }

        pendingToolUses.removeValue(forKey: toolUseId)

        guard let staleIndex = permissionQueue.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return }

        if shouldKeepQueuedPermissionForCompletedEvent(event, normalizedEventName: normalized) {
            return
        }

        let stale = permissionQueue.remove(at: staleIndex)
        log.notice("⚠️ permission deny reason=resolveToolUseIfCompleted session=\(stale.event.sessionId ?? "nil", privacy: .public) toolUseId=\(toolUseId, privacy: .public) tool=\(stale.event.toolName ?? "nil", privacy: .public) triggerEvent=\(normalized, privacy: .public)")
        let denyBody = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        stale.continuation.resume(returning: Data(denyBody.utf8))

        // If the card we were showing was the drained one, advance to the next pending
        // request (or collapse if nothing is left).
        let wasHead = staleIndex == 0
        if wasHead {
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
    func prunePendingToolUses(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-AppState.pendingToolUseTTL)
        pendingToolUses = pendingToolUses.filter { $0.value.receivedAt >= cutoff }
    }

    /// Try to merge this permission request into an existing queue entry for the same
    /// tool_use_id. Returns true when the new arrival was treated as a replay and its
    /// continuation has already been resolved (caller must not enqueue).
    ///
    /// Behavior: the newer continuation replaces the queued one in-place. The older
    /// continuation is denied so Claude's prior waiter doesn't hang; the queue slot and
    /// its position remain the same so the visible card doesn't reshuffle under the user.
    func mergeDuplicatePermissionRequest(_ request: PermissionRequest) -> Bool {
        guard let toolUseId = request.toolUseId, !toolUseId.isEmpty else { return false }
        guard let existingIndex = permissionQueue.firstIndex(where: { $0.toolUseId == toolUseId })
        else { return false }

        let existing = permissionQueue[existingIndex]
        log.notice("⚠️ permission deny reason=mergeDuplicatePermissionRequest session=\(existing.event.sessionId ?? "nil", privacy: .public) toolUseId=\(toolUseId, privacy: .public) tool=\(existing.event.toolName ?? "nil", privacy: .public)")
        let denyBody = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        existing.continuation.resume(returning: Data(denyBody.utf8))
        permissionQueue[existingIndex] = request
        return true
    }

    func shouldKeepQueuedPermissionForCompletedEvent(_ event: HookEvent, normalizedEventName: String) -> Bool {
        guard normalizedEventName != "PermissionDenied" else { return false }

        let source = SessionSnapshot.normalizedSupportedSource(event.rawJSON["_source"] as? String)
            ?? permissionQueue.first(where: { $0.toolUseId == event.toolUseId })
                .flatMap { SessionSnapshot.normalizedSupportedSource($0.event.rawJSON["_source"] as? String) }

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
        guard let toolUseId = event.toolUseId, !toolUseId.isEmpty else { return }
        guard let record = pendingToolUses[toolUseId] else { return }

        if sessions[sessionId]?.currentTool == nil, let name = record.toolName {
            sessions[sessionId]?.currentTool = name
        }
        if sessions[sessionId]?.toolDescription == nil, let desc = record.toolDescription {
            sessions[sessionId]?.toolDescription = desc
        }
    }
}
