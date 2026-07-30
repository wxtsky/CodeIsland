import Foundation

/// Maps Cursor Task/subagent hooks onto their parent chat card.
///
/// Child hooks use a different `session_id`, but `transcript_path` still points at
/// `…/agent-transcripts/<parentId>/…`. Without rewriting, each Task appears as a
/// duplicate Cursor card for the same IDE conversation.
public enum CursorSessionFolding {
    /// UUID segment under `agent-transcripts/`.
    private static let uuidDirPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

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
        guard isCursorFamilySource(
            (raw["_source"] as? String) ?? (raw["source"] as? String)
        ) else {
            return .leave
        }

        guard let childSessionId = sessionId(from: raw) else { return .leave }

        guard let parentId = CursorSessionFolding.foldTarget(
            childSessionId: childSessionId,
            transcriptPath: transcriptPath(from: raw)
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
    }

    /// Whether merge/hide may resolve a parent via `_ppid` after transcript fold
    /// returned `.leave`.
    ///
    /// True only with Cursor source + session id + positive `_ppid` and **no**
    /// parseable parent UUID in `transcript_path`. A parseable parent means either
    /// the main chat or a foldable Task (`decide` already handles the latter).
    public static func shouldAttemptPpidParentFallback(raw: [String: Any]) -> Bool {
        guard isCursorFamilySource((raw["_source"] as? String) ?? (raw["source"] as? String)),
              sessionId(from: raw) != nil,
              positivePpid(from: raw) != nil else {
            return false
        }
        if let path = transcriptPath(from: raw),
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
