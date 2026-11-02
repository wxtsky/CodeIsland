import Foundation

/// Lets a compaction Claude Code runs on a finished session in the
/// background (``isIdleBackgroundCompaction(_:session:)``) pass without a
/// trace on the card.
///
/// Its PreCompact is not the only hook it fires. The agent that writes the
/// summary is one the card never saw start, and it stops when it is done
/// (SubagentStop). Where Claude Code applies the summary at once instead of
/// keeping it for the user's return, the conversation then starts over from
/// it (SessionStart, source "compact"). On a card the idle sweep had
/// removed, either one brought the card back; on a finished card the stop
/// kept it from being swept, and the restart wiped its last reply and rang
/// the session-start sound where that is on. Once a background compaction
/// has begun on a card, these hooks of its own change nothing either, as
/// long as the card is still finished or gone.
///
/// The compaction ends with its SessionStart, with anything else from the
/// session's main thread — the user's next prompt, above all — or after
/// ``window``.
public struct BackgroundCompactionFilter: Sendable {
    /// The summary is one model request. A hook this long after the
    /// compaction began is not part of it.
    public let window: TimeInterval
    private var began: [String: Date] = [:]

    public init(window: TimeInterval = 10 * 60) {
        self.window = window
    }

    /// True when `event` belongs to a background compaction of the card it
    /// names — `session`, nil when the card is gone — and so must change
    /// nothing: open no card, wake none, ring nothing.
    public mutating func absorbs(_ event: HookEvent, session: SessionSnapshot?, now: Date) -> Bool {
        let cardId = event.sessionId ?? "default"
        let eventName = EventNormalizer.normalize(event.eventName)
        began = began.filter { now.timeIntervalSince($0.value) < window }

        if isIdleBackgroundCompaction(event, session: session) {
            if eventName == "PreCompact" {
                began[cardId] = now
            }
            return true
        }
        guard began[cardId] != nil else { return false }
        // The card has work again (a turn, a request): what comes now is
        // the session's own.
        guard session == nil || session?.status == .idle else {
            began[cardId] = nil
            return false
        }
        if let agentId = event.agentId {
            // The agent writing the summary. One the card knows is the
            // session's, finishing work of its own.
            return session?.subagents[agentId] == nil
        }
        began[cardId] = nil
        return eventName == "SessionStart"
            && (event.rawJSON["source"] as? String)?.lowercased() == "compact"
    }
}
