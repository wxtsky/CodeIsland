import SwiftUI
import CodeIslandCore

/// Global shortcuts for the approval and question cards, and Toggle Panel.
///
/// A card shortcut acts only on the card the user can see: approve, always
/// allow and deny on an approval card on screen, skip on a question card on
/// screen. When no such card is up but a request of that kind waits out of
/// sight — auto-expand is off, Smart Suppress held it back, a completion
/// card or the session list is showing — the press only opens its card; the
/// next press acts on it. With nothing of that kind waiting it does nothing.
/// Nor can the user see a card on an island that is off screen — hidden
/// over a fullscreen app by Hide in Fullscreen: the press only brings it up
/// (#384).
/// (The hardware Buddy, which has no screen of its own for the card, keeps
/// acting on the head of the queue through `handleBuddyControlCommand`.)
extension AppState {
    enum CardShortcutOutcome: Equatable {
        /// Resolved the request on the card for this session.
        case acted(sessionId: String)
        /// Nothing resolved; this card was brought up for the next press.
        case opened(IslandSurface)
        case ignored
    }

    @discardableResult
    func performCardShortcut(_ action: ShortcutAction, islandOnScreen: Bool = true) -> CardShortcutOutcome {
        switch action {
        case .approve, .approveAlways, .deny:
            let visible = visiblePermissionSessionIds
            if let sid = surface.approvalSessionId, visible.contains(sid) {
                guard islandOnScreen else { return .opened(.approvalCard(sessionId: sid)) }
                switch action {
                case .approve: approvePermission(expectedSessionId: sid)
                case .approveAlways: approvePermission(always: true, expectedSessionId: sid)
                default: denyPermission(expectedSessionId: sid)
                }
                return .acted(sessionId: sid)
            }
            // A dismissed request stays hidden: the user put it away.
            guard let sid = permissionQueue.lazy
                .map({ $0.event.sessionId ?? "default" })
                .first(where: { visible.contains($0) })
            else {
                foldDeadCard()
                return .ignored
            }
            openPendingApprovalCard(sessionId: sid)
            return .opened(.approvalCard(sessionId: sid))

        case .skipQuestion:
            if let sid = surface.questionSessionId, pendingQuestion(forSession: sid) != nil {
                guard islandOnScreen else { return .opened(.questionCard(sessionId: sid)) }
                skipQuestion(expectedSessionId: sid)
                return .acted(sessionId: sid)
            }
            // A closed question stays hidden, as a dismissed approval does.
            guard let head = nextVisibleQuestion else {
                foldDeadCard()
                return .ignored
            }
            let sid = head.event.sessionId ?? "default"
            openPendingQuestionCard(sessionId: sid)
            return .opened(.questionCard(sessionId: sid))

        case .togglePanel, .jumpToTerminal:
            return .ignored
        }
    }

    enum PanelToggleOutcome: Equatable {
        case opened
        case collapsed
        /// The island was open where the user couldn't see it; it stays
        /// open, to be brought to them.
        case keptOpen
    }

    /// The Toggle Panel shortcut. An island open out of the user's sight —
    /// hidden over a fullscreen app, or up on another display than the one
    /// they work on (`PanelSight.isAway`) — is not closed unseen: it stays
    /// open, and the caller brings it to them (#384).
    @discardableResult
    func togglePanelFromShortcut(islandAway: Bool) -> PanelToggleOutcome {
        if surface.isExpanded {
            if islandAway { return .keptOpen }
            withAnimation(NotchAnimation.close) { surface = .collapsed }
            return .collapsed
        }
        withAnimation(NotchAnimation.open) {
            surface = .sessionList
            cancelCompletionQueue()
            if activeSessionId == nil {
                activeSessionId = sessions.keys.sorted().first
            }
        }
        return .opened
    }

    /// Open a waiting approval's card on an explicit user action. Like
    /// `openPendingQuestionCard`, never gated by auto-expand or Smart
    /// Suppress: those only decide what opens by itself.
    func openPendingApprovalCard(sessionId: String) {
        guard visiblePermissionSessionIds.contains(sessionId) else { return }
        activeSessionId = sessionId
        withAnimation(NotchAnimation.open) {
            surface = .approvalCard(sessionId: sessionId)
        }
    }

    /// A card whose request is gone can only swallow the press; let the
    /// usual re-evaluation fold it.
    private func foldDeadCard() {
        switch surface {
        case .approvalCard(let sid) where !visiblePermissionSessionIds.contains(sid):
            showNextPending()
        case .questionCard(let sid) where pendingQuestion(forSession: sid) == nil:
            showNextPending()
        default:
            break
        }
    }
}
