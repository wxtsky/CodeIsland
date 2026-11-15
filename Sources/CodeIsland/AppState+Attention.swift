import Foundation
import CodeIslandCore

/// What the island does about a moment — a sound, the completion card, a
/// push, a follow-up reminder — is `AttentionPolicy`'s decision. AppState
/// gathers what the policy reads (the user's settings, the room, the
/// session) and carries out what it decides; the rules themselves live in
/// the policy and nowhere else.
extension AppState {
    /// The user's settings and the room, as the policy reads them for a
    /// moment in `sessionId`. Smart Suppress's answer is asked only if a
    /// card or a push depends on it.
    ///
    /// - `terminalFrontmost`: the app-level probe behind Smart Suppress (the
    ///   AskUserQuestion path passes its own test seam).
    func attentionContext(
        for sessionId: String,
        terminalFrontmost: @escaping (SessionSnapshot) -> Bool = TerminalVisibilityDetector.isTerminalFrontmostForSession
    ) -> AttentionContext {
        let sounds = SoundManager.shared
        return AttentionContext(
            sounds: sounds.preferences,
            soundHold: sounds.hold,
            // Permission-only mode pops nothing for a finished turn: no card,
            // no glance dot, and no follow-up that would open the island later.
            completionStyle: Self.permissionOnlyMode() ? .off : Self.completionStyle(),
            pushEnabled: PushNotifier.shared.isEnabled,
            sessionInFront: { [weak self] in
                guard let self else { return false }
                return self.isSmartSuppressed(sessionId: sessionId, isTerminalFrontmost: terminalFrontmost)
            }
        )
    }

    /// The policy's decision about `moment` in `sessionId`, reading the
    /// session as it stands unless the caller saw it at a better moment.
    func decideAttention(
        _ moment: AttentionMoment,
        sessionId: String,
        subject: AttentionSubject? = nil,
        terminalFrontmost: @escaping (SessionSnapshot) -> Bool = TerminalVisibilityDetector.isTerminalFrontmostForSession
    ) -> AttentionDecision {
        AttentionPolicy.decide(
            moment,
            subject: subject ?? AttentionSubject(sessions[sessionId]),
            context: attentionContext(for: sessionId, terminalFrontmost: terminalFrontmost)
        )
    }

    /// Decide `moment` and carry the decision out at once — for turns and
    /// requests from sources the hook reducer never sees (Claude Desktop,
    /// AiWork, Cursor's in-IDE question), which have nothing to interleave
    /// with it.
    ///
    /// - `errorDetail`: what the source itself said went wrong, for the push
    ///   of a failed turn.
    @discardableResult
    func attend(_ moment: AttentionMoment, sessionId: String, errorDetail: String? = nil) -> AttentionDecision {
        let decision = decideAttention(moment, sessionId: sessionId)
        if let push = decision.push {
            pushTurnEnded(push, sessionId: sessionId, errorDetail: errorDetail)
        }
        announceCompletion(decision, sessionId: sessionId)
        playAttentionSound(decision, sessionId: sessionId)
        return decision
    }

    /// Plays the decided sound. `sessionId` scopes the turn-failure jingle's
    /// debounce.
    func playAttentionSound(_ decision: AttentionDecision, sessionId: String) {
        guard let cue = decision.sound else { return }
        SoundManager.shared.play(cue: cue, sessionId: sessionId)
    }
}
