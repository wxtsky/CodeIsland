import AppKit
import SwiftUI
import CodeIslandCore

// MARK: - Density

/// How much of each session the expanded list shows (Settings → Appearance).
enum SessionListDensity: String, CaseIterable {
    /// One card per session: status chip, prompt, reply, running tool.
    case comfortable
    /// One ~34pt row per session; only a session that needs you opens up to
    /// show its request and the inline actions.
    case compact

    /// Unknown or missing values read as the default.
    init(storedValue: String?) {
        self = storedValue.flatMap(SessionListDensity.init(rawValue:)) ?? .comfortable
    }

    var titleKey: String {
        switch self {
        case .comfortable: return "density_comfortable"
        case .compact: return "density_compact"
        }
    }
}

// MARK: - Status word

/// The status a session card spells out in its chip and colours its edge
/// rail with. The word carries the meaning; the hue only repeats it.
enum SessionCardStatus: Equatable, CaseIterable {
    /// An approval or a question is waiting on the user.
    case needsYou
    /// A tool is running.
    case working
    /// The model is thinking (no tool yet).
    case thinking
    /// Idle after a finished turn.
    case done
    /// Idle and nothing has happened yet.
    case idle
    /// The user interrupted the last turn.
    case stopped
    /// The last turn ended on an error (rate limit, overload, a failed stream).
    case error

    init(_ session: SessionSnapshot) {
        switch session.status {
        case .waitingApproval, .waitingQuestion:
            self = .needsYou
        case .running:
            self = .working
        case .processing:
            self = .thinking
        case .idle:
            if session.lastTurnFailed {
                self = .error
            } else if session.interrupted {
                self = .stopped
            } else if session.lastAssistantMessage != nil
                        || session.lastUserPrompt != nil
                        || !session.recentMessages.isEmpty {
                self = .done
            } else {
                self = .idle
            }
        }
    }

    var labelKey: String {
        switch self {
        case .needsYou: return "session_status_needs_you"
        case .working: return "session_status_working"
        case .thinking: return "session_status_thinking"
        case .done: return "session_status_done"
        case .idle: return "session_status_idle"
        case .stopped: return "session_status_stopped"
        case .error: return "session_status_error"
        }
    }

    var label: String { L10n.shared[labelKey] }

    /// Chip text and edge-rail colour. Every one reads at ≥ 4.5:1 on the
    /// card's near-black fill.
    var color: Color {
        switch self {
        case .needsYou: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .working, .thinking: return Color(red: 0.3, green: 0.85, blue: 0.4)
        case .done: return .white.opacity(0.62)
        case .idle: return .white.opacity(0.55)
        case .stopped: return Color(red: 1.0, green: 0.55, blue: 0.4)
        case .error: return Color(red: 1.0, green: 0.38, blue: 0.42)
        }
    }

    /// The rail is quieter than the chip for the resting states, so a list of
    /// finished sessions doesn't read as a column of alerts.
    var railColor: Color {
        switch self {
        case .done: return .white.opacity(0.28)
        case .idle: return .white.opacity(0.16)
        default: return color
        }
    }

    /// Sort tier: what needs you, then what is working, then the rest.
    var tier: Int {
        switch self {
        case .needsYou: return 0
        case .working, .thinking: return 1
        case .done, .idle, .stopped, .error: return 2
        }
    }
}

// MARK: - Ordering

/// The expanded list's order: sessions that need you first (in the order
/// their requests queued, so the one the buttons act on leads), then the
/// ones working (newest session first — a working session's activity changes
/// every few seconds, and sorting on it would shuffle the cards constantly),
/// then the rest by most recent activity.
enum SessionListOrdering {
    static func order(
        _ sessions: [String: SessionSnapshot],
        requestRank: [String: Int] = [:]
    ) -> [String] {
        let tiers = sessions.mapValues { SessionCardStatus($0).tier }
        return sessions.keys.sorted { a, b in
            guard let sa = sessions[a], let sb = sessions[b] else { return a < b }
            let ta = tiers[a] ?? 2, tb = tiers[b] ?? 2
            if ta != tb { return ta < tb }
            switch ta {
            case 0:
                let ra = requestRank[a] ?? Int.max, rb = requestRank[b] ?? Int.max
                if ra != rb { return ra < rb }
                if sa.lastActivity != sb.lastActivity { return sa.lastActivity > sb.lastActivity }
            case 1:
                if sa.startTime != sb.startTime { return sa.startTime > sb.startTime }
            default:
                if sa.lastActivity != sb.lastActivity { return sa.lastActivity > sb.lastActivity }
            }
            return a < b
        }
    }

    /// Request queue position per session: approvals (they hold a tool call)
    /// before questions, each in arrival order.
    static func requestRank(permissionSessionIds: [String], questionSessionIds: [String]) -> [String: Int] {
        var rank: [String: Int] = [:]
        for (index, id) in (permissionSessionIds + questionSessionIds).enumerated() where rank[id] == nil {
            rank[id] = index
        }
        return rank
    }
}

/// "Group by status" sections.
enum SessionListGrouping {
    /// Section order: what waits on you, then what is running. A session that
    /// changes status moves to its new section even while the order is held —
    /// the header above a card has to stay true.
    static let statusSections: [(statuses: Set<AgentStatus>, labelKey: String)] = [
        ([.waitingApproval, .waitingQuestion], "status_waiting"),
        ([.running], "status_running"),
        ([.processing], "status_processing"),
        ([.idle], "status_idle"),
    ]

    /// Non-empty sections, each keeping `orderedIds`' order.
    static func byStatus(
        _ orderedIds: [String],
        sessions: [String: SessionSnapshot]
    ) -> [(labelKey: String, ids: [String])] {
        statusSections.compactMap { section in
            let ids = orderedIds.filter { id in
                sessions[id].map { section.statuses.contains($0.status) } ?? false
            }
            return ids.isEmpty ? nil : (section.labelKey, ids)
        }
    }
}

/// Holds the list's order while the pointer is over it, so a card never
/// moves out from under the cursor when a session changes status; the list
/// re-sorts when the pointer leaves.
struct SessionOrderFreeze: Equatable {
    private(set) var frozen: [String]?

    var isFrozen: Bool { frozen != nil }

    /// Pointer entered: keep what is on screen now. A second call while
    /// already frozen keeps the first order.
    mutating func freeze(_ current: [String]) {
        if frozen == nil { frozen = current }
    }

    /// Pointer left: back to the live order.
    mutating func thaw() {
        frozen = nil
    }

    /// The order to show. While frozen, sessions keep their places; a session
    /// that ended drops out and one that started joins at the end, so nothing
    /// already on screen moves.
    func apply(_ live: [String]) -> [String] {
        guard let frozen else { return live }
        let liveSet = Set(live)
        let kept = frozen.filter { liveSet.contains($0) }
        let keptSet = Set(kept)
        return kept + live.filter { !keptSet.contains($0) }
    }
}

extension AppState {
    /// Session ids in the expanded list's live (unfrozen) order.
    func sessionListOrder() -> [String] {
        let rank = SessionListOrdering.requestRank(
            permissionSessionIds: permissionQueue.map { $0.event.sessionId ?? "default" },
            questionSessionIds: questionQueue.map { $0.event.sessionId ?? "default" }
        )
        return SessionListOrdering.order(sessions, requestRank: rank)
    }
}

// MARK: - Compact metrics

enum CompactSessionRowMetrics {
    /// Height of one collapsed row.
    static let rowHeight: CGFloat = 34
    /// Gap between rows.
    static let spacing: CGFloat = 3

    /// The status word, a little smaller than the row's text.
    static func statusFontSize(_ contentFontSize: CGFloat) -> CGFloat {
        max(8.5, contentFontSize - 2)
    }

    /// Width of the status-word column: the widest word in the current
    /// language, so the words line up in a column whatever the language.
    static func statusColumnWidth(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let widest = SessionCardStatus.allCases
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return (widest + 2).rounded(.up)
    }

    /// Most the project column takes: ~16 characters at the default size,
    /// growing a little with the text so large sizes still leave the
    /// activity most of the row.
    static func projectColumnCap(fontSize: CGFloat) -> CGFloat {
        min(160 * fontSize / 11, 180)
    }

    /// Width of the project column: the widest name on screen, capped so the
    /// activity keeps most of the row.
    static func projectColumnWidth(names: [String], fontSize: CGFloat, cap: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let widest = names
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(max(48, (widest + 2).rounded(.up)), cap)
    }
}
