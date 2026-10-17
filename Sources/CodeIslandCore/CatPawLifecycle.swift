import Foundation

/// Bounded, in-memory evidence only. Restarting the app must not reuse stale
/// requests to infer completion. Display groups are not a protocol parent tree.
struct CatPawLifecycle: Sendable {
    struct Request: Sendable {
        let id: String
        let turn: UUID
    }
    var turn = UUID()
    var startedAt = Date()
    var scope: String?
    var hasHost = false
    var requests: [Request] = []
    var pending: [String] = []
    var fallbackRequests: Set<String> = []
    var ended = false
    var endedAt: Date?
    var parentConfirmed = false
    var replyAt: Date?
    var workAt = Date()
    var completionInferred = false

    private static func scope(_ event: HookEvent) -> String {
        let raw = event.rawJSON
        // cwd belongs to an individual shell invocation; workspace_roots is
        // the stable conversation context, even when tools cd into subfolders.
        let roots = (raw["workspace_roots"] as? [String] ?? []).sorted()
        let workspace = roots.isEmpty ? (raw["cwd"] as? String ?? "") : roots.joined(separator: "\u{1}")
        return [raw["_source"] as? String ?? "", raw["_remote_host_id"] as? String ?? "", String((raw["_ppid"] as? NSNumber)?.intValue ?? 0),
                workspace, raw["catpaw_version"] as? String ?? ""]
            .joined(separator: "\u{0}")
    }

    static func observe(sessions: inout [String: SessionSnapshot], event: HookEvent, eventName: String) {
        guard let id = event.sessionId, var state = sessions[id]?.catpawLifecycle else { return }
        let scope = scope(event)
        if state.scope != scope { state = CatPawLifecycle() }
        state.scope = scope
        state.hasHost = ((event.rawJSON["_ppid"] as? NSNumber)?.intValue ?? 0) > 0
        if eventName == "UserPromptSubmit" {
            state.turn = UUID()
            state.startedAt = Date()
            state.ended = false
            state.endedAt = nil
            state.replyAt = nil
            state.workAt = Date()
            state.parentConfirmed = false
            state.completionInferred = false
            sessions[id]?.catpawParentSessionID = nil
            state.pending.removeAll()
            state.fallbackRequests.removeAll()
        }
        if eventName == "CatPawResponse" { state.replyAt = Date() }
        else {
            state.workAt = Date()
            // Work continuing after an unknown stop invalidates only the root
            // fallback. Keep the request pending for a late child identity.
            state.fallbackRequests.removeAll()
        }
        if let request = event.rawJSON["suggest_uuid"] as? String, !request.isEmpty,
           !state.requests.contains(where: { $0.id == request }) {
            state.requests.append(Request(id: request, turn: state.turn))
            if state.requests.count > 512 { state.requests.removeFirst() }
        }
        sessions[id]?.catpawLifecycle = state
    }

    static func receiveStop(sessions: inout [String: SessionSnapshot], event: HookEvent) -> [SideEffect] {
        guard event.rawJSON["status"] as? String == "completed",
              let id = event.sessionId, let state = sessions[id]?.catpawLifecycle,
              state.scope == scope(event),
              let request = event.rawJSON["suggest_uuid"] as? String, !request.isEmpty else { return [] }
        // Stop itself is NOT request ownership evidence: its identity can be root.
        if !state.pending.contains(request) {
            sessions[id]?.catpawLifecycle.pending.append(request)
            sessions[id]?.catpawLifecycle.fallbackRequests.insert(request)
            if (sessions[id]?.catpawLifecycle.pending.count ?? 0) > 128 {
                if let first = sessions[id]?.catpawLifecycle.pending.first {
                    sessions[id]?.catpawLifecycle.fallbackRequests.remove(first)
                }
                sessions[id]?.catpawLifecycle.pending.removeFirst()
            }
        }
        return resolve(sessions: &sessions)
    }

    static func resolve(sessions: inout [String: SessionSnapshot]) -> [SideEffect] {
        var effects: [SideEffect] = []
        for rootID in sessions.keys.sorted() {
            guard let root = sessions[rootID], CatPawHookPayload.isSource(root.source),
                  root.catpawLifecycle.scope != nil else { continue }
            for request in root.catpawLifecycle.pending {
                // Include historical turns when checking uniqueness, then reject
                // stale ownership below. Conflicts cannot use the root fallback.
                let owners = sessions.filter { id, candidate in
                    candidate.source == root.source &&
                    candidate.catpawLifecycle.scope == root.catpawLifecycle.scope &&
                    candidate.catpawLifecycle.requests.contains { $0.id == request }
                }
                var targetID: String
                var target: SessionSnapshot
                var inferred = false
                if owners.count == 1, let owner = owners.first,
                   let evidence = owner.value.catpawLifecycle.requests.first(where: { $0.id == request }),
                   evidence.turn == owner.value.catpawLifecycle.turn,
                   owner.key == rootID || (root.catpawLifecycle.hasHost && !root.catpawIsSubagent && owner.value.catpawIsSubagent &&
                       owner.value.catpawLifecycle.startedAt >= root.catpawLifecycle.startedAt) {
                    targetID = owner.key
                    target = owner.value
                } else if owners.isEmpty, root.catpawLifecycle.fallbackRequests.contains(request), canInferRootCompletion(rootID: rootID, root: root, sessions: sessions) {
                    targetID = rootID
                    target = root
                    inferred = true
                } else { continue }
                if targetID != rootID {
                    sessions[targetID]?.catpawParentSessionID = rootID
                    sessions[targetID]?.catpawLifecycle.parentConfirmed = true
                }
                sessions[rootID]?.catpawLifecycle.pending.removeAll { $0 == request }
                sessions[rootID]?.catpawLifecycle.fallbackRequests.remove(request)
                guard sessions[targetID]?.catpawLifecycle.ended != true else { continue }
                sessions[targetID]?.catpawLifecycle.ended = true
                sessions[targetID]?.catpawLifecycle.endedAt = Date()
                sessions[targetID]?.catpawLifecycle.completionInferred = inferred
                sessions[targetID]?.status = .idle
                sessions[targetID]?.currentTool = nil
                sessions[targetID]?.toolDescription = nil
                sessions[targetID]?.lastActivity = Date()
                if !target.catpawIsSubagent {
                    effects.append(.enqueueCompletion(sessionId: targetID))
                    effects.append(.playSound("Stop"))
                }
            }
        }
        updateGrouping(sessions: &sessions)
        return effects
    }

    /// The protocol says stop ends a conversation, not a particular response.
    /// Some versions provide a fresh request UUID. Use the root identity only
    /// after a reply with no subsequent work, and after every observed child
    /// has a confirmed completion under this root. Never use reply text meaning.
    private static func canInferRootCompletion(rootID: String, root: SessionSnapshot,
                                               sessions: [String: SessionSnapshot]) -> Bool {
        guard !root.catpawIsSubagent, !root.catpawLifecycle.ended,
              let replyAt = root.catpawLifecycle.replyAt,
              replyAt >= root.catpawLifecycle.workAt else { return false }
        let roots = sessions.filter {
            !$0.value.catpawIsSubagent && $0.value.catpawLifecycle.scope == root.catpawLifecycle.scope &&
            !$0.value.catpawLifecycle.ended
        }
        guard roots.count == 1, roots[rootID] != nil else { return false }
        let children = sessions.values.filter {
            $0.catpawIsSubagent && $0.catpawLifecycle.scope == root.catpawLifecycle.scope &&
            $0.catpawLifecycle.startedAt >= root.catpawLifecycle.startedAt
        }
        return children.allSatisfy {
            $0.catpawLifecycle.ended && $0.catpawLifecycle.parentConfirmed &&
            $0.catpawParentSessionID == rootID &&
            ($0.catpawLifecycle.endedAt.map { replyAt >= $0 } ?? false)
        }
    }

    /// Unique active-root grouping is presentation only; it is never evidence
    /// for stop routing. Concurrent roots leave unconfirmed children separate.
    private static func updateGrouping(sessions: inout [String: SessionSnapshot]) {
        for id in sessions.keys.sorted() {
            guard let child = sessions[id], child.catpawIsSubagent,
                  child.catpawLifecycle.scope != nil else { continue }
            if !child.catpawLifecycle.parentConfirmed {
                let roots = sessions.filter {
                    !$0.value.catpawIsSubagent && $0.value.source == child.source &&
                    $0.value.catpawLifecycle.scope == child.catpawLifecycle.scope &&
                    !$0.value.catpawLifecycle.ended && child.catpawLifecycle.hasHost &&
                    $0.value.catpawLifecycle.startedAt <= child.catpawLifecycle.startedAt
                }
                sessions[id]?.catpawParentSessionID = roots.count == 1 ? roots.first?.key : nil
            }
        }
        for id in sessions.keys.sorted() {
            guard let root = sessions[id], !root.catpawIsSubagent,
                  CatPawHookPayload.isSource(root.source) else { continue }
            let children = sessions.values.filter {
                $0.catpawParentSessionID == id && $0.catpawLifecycle.startedAt >= root.catpawLifecycle.startedAt
            }
            sessions[id]?.catpawChildrenRunning = children.filter { !$0.catpawLifecycle.ended }.count
            sessions[id]?.catpawChildrenCompleted = children.filter { $0.catpawLifecycle.ended }.count
        }
    }
}
