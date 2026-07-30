import Foundation

/// Maps Cursor Task/subagent hooks onto their parent chat card.
///
/// Child hooks use a different `session_id`, but `transcript_path` still points at
/// `…/agent-transcripts/<parentId>/…`. Without rewriting, each Task appears as a
/// duplicate Cursor card for the same IDE conversation.
public enum CursorSessionFolding {
    /// UUID segment under `agent-transcripts/`.
    private static let uuidDirPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    /// True when `path` is under Cursor's `agent-transcripts` tree
    /// (`~/.cursor/projects/…/agent-transcripts/…`).
    public static func isCursorAgentTranscriptPath(_ path: String?) -> Bool {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return false
        }
        guard path.contains("/agent-transcripts/") else { return false }
        return path.contains("/.cursor/") || path.contains("/cursor/projects/")
    }

    /// Parent conversation id from a Cursor `transcript_path`, when present.
    ///
    /// Recognized layouts:
    /// - `…/agent-transcripts/<parentId>/<parentId>.jsonl`
    /// - `…/agent-transcripts/<parentId>/subagents/<childId>.jsonl`
    public static func parentConversationId(fromTranscriptPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = (trimmed as NSString).pathComponents
        guard let transcriptsIdx = parts.lastIndex(of: "agent-transcripts"),
              transcriptsIdx + 1 < parts.count else {
            return nil
        }

        let parentCandidate = parts[transcriptsIdx + 1]
        guard parentCandidate.range(of: uuidDirPattern, options: .regularExpression) != nil else {
            return nil
        }
        return parentCandidate
    }

    /// Parent id when `childSessionId` is a Task of that conversation
    /// (`transcript_path` parent ≠ `childSessionId`).
    public static func foldTarget(childSessionId: String, transcriptPath: String?) -> String? {
        let child = childSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !child.isEmpty,
              let path = transcriptPath,
              let parentId = parentConversationId(fromTranscriptPath: path),
              parentId != child else {
            return nil
        }
        return parentId
    }
}

/// How to handle a Cursor Task/subagent hook under Agent Sub-Sessions.
public enum CursorSubsessionRouteDecision: Equatable {
    case leave
    case hide
    case merge(parentSessionId: String, childSessionId: String)
}

public enum CursorSubsessionRouter {
    /// `cursor` / `cursor-cli` after normalization.
    public static func isCursorFamilySource(_ source: String?) -> Bool {
        let normalized = SessionSnapshot.normalizedSupportedSource(source)
        return normalized == "cursor" || normalized == "cursor-cli"
    }

    /// Treat as Cursor Task routing even when `_source` is missing or still the
    /// default `"claude"` — Cursor Agent Tasks often fire Claude-format hooks
    /// without `--source`, which would otherwise leave a ghost Claude card.
    public static func shouldTreatAsCursorFamily(
        declaredSource: String?,
        transcriptPath: String?
    ) -> Bool {
        if isCursorFamilySource(declaredSource) { return true }
        guard CursorSessionFolding.isCursorAgentTranscriptPath(transcriptPath) else {
            return false
        }
        let normalized = SessionSnapshot.normalizedSupportedSource(declaredSource)
        return normalized == nil || normalized == "claude"
    }

    /// Positive process id from `_ppid` (Int / Int32 / NSNumber / decimal String).
    public static func positivePpid(from raw: [String: Any]) -> Int? {
        let parsed: Int?
        if let p = raw["_ppid"] as? Int {
            parsed = p
        } else if let p = raw["_ppid"] as? Int32 {
            parsed = Int(p)
        } else if let p = raw["_ppid"] as? NSNumber {
            parsed = p.intValue
        } else if let s = raw["_ppid"] as? String {
            parsed = Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            parsed = nil
        }
        guard let parsed, parsed > 0 else { return nil }
        return parsed
    }

    /// Apply Agent Sub-Sessions (`separate` / `merge` / `hide`) to Cursor hooks.
    /// Same three modes as Codex and plugin children.
    public static func decide(raw: [String: Any], mode: String) -> CursorSubsessionRouteDecision {
        let declared = (raw["_source"] as? String) ?? (raw["source"] as? String)
        let path = transcriptPath(from: raw)
        guard shouldTreatAsCursorFamily(declaredSource: declared, transcriptPath: path) else {
            return .leave
        }

        guard let childSessionId = sessionId(from: raw) else { return .leave }

        guard let parentId = CursorSessionFolding.foldTarget(
            childSessionId: childSessionId,
            transcriptPath: path
        ) else {
            return .leave
        }

        switch mode {
        case "hide":
            return .hide
        case "merge":
            return .merge(parentSessionId: parentId, childSessionId: childSessionId)
        default:
            // separate (or unknown): leave as its own session card
            return .leave
        }
    }

    /// Rewrite the hook onto the parent session and attach `agent_id` = child.
    public static func applyMerge(
        to raw: inout [String: Any],
        parentSessionId: String,
        childSessionId: String
    ) {
        raw["session_id"] = parentSessionId
        raw["agent_id"] = nonEmptyString(raw["agent_id"]) ?? childSessionId
        if nonEmptyString(raw["agent_type"]) == nil {
            raw["agent_type"] = "cursor-subagent"
        }
        raw["_cursor_subagent"] = true
        // Misbranded Claude-default Task hooks must land as Cursor on the parent.
        if !isCursorFamilySource((raw["_source"] as? String) ?? (raw["source"] as? String)) {
            raw["_source"] = "cursor"
        }
    }

    /// Whether merge/hide may resolve a parent via `_ppid` after transcript fold
    /// returned `.leave`.
    ///
    /// True with Cursor family (including misbranded Claude-default + Cursor
    /// transcript path) + session id + positive `_ppid` and **no** parseable
    /// parent UUID in `transcript_path`.
    public static func shouldAttemptPpidParentFallback(raw: [String: Any]) -> Bool {
        let declared = (raw["_source"] as? String) ?? (raw["source"] as? String)
        let path = transcriptPath(from: raw)
        guard shouldTreatAsCursorFamily(declaredSource: declared, transcriptPath: path),
              sessionId(from: raw) != nil,
              positivePpid(from: raw) != nil else {
            return false
        }
        if let path,
           CursorSessionFolding.parentConversationId(fromTranscriptPath: path) != nil {
            return false
        }
        return true
    }

    /// Search order for same-IDE parent lookup: event source first, then sibling.
    public static func parentSourceSearchOrder(primarySource: String) -> [String] {
        let normalized = SessionSnapshot.normalizedSupportedSource(primarySource) ?? primarySource
        return normalized == "cursor-cli" ? ["cursor-cli", "cursor"] : ["cursor", "cursor-cli"]
    }

    /// True when this top-level card is a foldable Cursor Task (transcript parent ≠ id).
    public static func isLikelyCursorTaskCard(
        sessionId: String,
        providerSessionId: String?,
        transcriptPath: String?
    ) -> Bool {
        if CursorSessionFolding.foldTarget(
            childSessionId: sessionId,
            transcriptPath: transcriptPath
        ) != nil {
            return true
        }
        if let providerSessionId,
           providerSessionId != sessionId,
           CursorSessionFolding.foldTarget(
               childSessionId: providerSessionId,
               transcriptPath: transcriptPath
           ) != nil {
            return true
        }
        return false
    }

    /// True when the card looks like a main Cursor chat (owns its transcript dir,
    /// or already parents live/folded Tasks).
    public static func isLikelyCursorMainCard(
        sessionId: String,
        providerSessionId: String?,
        transcriptPath: String?,
        hasSubagents: Bool
    ) -> Bool {
        if hasSubagents { return true }
        let identities = [sessionId, providerSessionId].compactMap { id -> String? in
            guard let id else { return nil }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let path = transcriptPath,
              let parentId = CursorSessionFolding.parentConversationId(fromTranscriptPath: path)
        else {
            return false
        }
        return identities.contains(parentId)
    }

    /// Pick a unique `_ppid` parent among same-PID Cursor cards.
    ///
    /// - Excludes foldable Task cards (never parent onto an orphan Task).
    /// - Prefers main-looking cards (self transcript / already has subagents).
    /// - Allows a unique idle main when it shares the IDE pid (main often goes
    ///   idle while a Task is still running).
    /// - 2+ live non-Task chats → ambiguous (`nil`).
    public static func choosePpidFallbackParentId(
        candidates: [(sessionId: String, status: AgentStatus, startTime: Date, isMain: Bool, isTask: Bool)]
    ) -> String? {
        let eligible = candidates.filter { !$0.isTask }
        guard !eligible.isEmpty else { return nil }

        let mains = eligible.filter(\.isMain)
        let pool = mains.isEmpty ? eligible : mains
        if pool.count == 1 { return pool[0].sessionId }

        let active = pool.filter { $0.status != .idle }
        let idle = pool.filter { $0.status == .idle }

        // Two+ live chats on the same IDE process — do not guess.
        if active.count >= 2 { return nil }
        if active.count == 1 {
            // Idle leftovers + one live card: prefer unique main among idle+active,
            // else the older idle card when it predates the live orphan Task.
            if idle.isEmpty { return active[0].sessionId }
            if let mainIdle = idle.first(where: \.isMain), idle.filter(\.isMain).count == 1 {
                return mainIdle.sessionId
            }
            if let oldestIdle = idle.min(by: { $0.startTime < $1.startTime }),
               oldestIdle.startTime < active[0].startTime {
                return oldestIdle.sessionId
            }
            return active[0].sessionId
        }

        // All idle: unique oldest only when startTimes differ.
        let sorted = pool.sorted { $0.startTime < $1.startTime }
        guard sorted.count >= 2, sorted[0].startTime < sorted[1].startTime else {
            return nil
        }
        return sorted[0].sessionId
    }

    public static func sessionId(from raw: [String: Any]) -> String? {
        nonEmptyString(raw["session_id"]) ?? nonEmptyString(raw["sessionId"])
    }

    public static func transcriptPath(from raw: [String: Any]) -> String? {
        nonEmptyString(raw["transcript_path"]) ?? nonEmptyString(raw["transcriptPath"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
