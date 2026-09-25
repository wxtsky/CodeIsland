import SwiftUI
import CodeIslandCore

/// Global shortcuts for the approval and question cards.
///
/// A shortcut acts only on the card the user can see: approve, always allow
/// and deny on an approval card on screen, skip on a question card on
/// screen. When no such card is up but a request of that kind waits out of
/// sight — auto-expand is off, Smart Suppress held it back, a completion
/// card or the session list is showing — the press only opens its card; the
/// next press acts on it. With nothing of that kind waiting it does nothing.
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
    func performCardShortcut(_ action: ShortcutAction) -> CardShortcutOutcome {
        switch action {
        case .approve, .approveAlways, .deny:
            let visible = visiblePermissionSessionIds
            if let sid = surface.approvalSessionId, visible.contains(sid) {
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
