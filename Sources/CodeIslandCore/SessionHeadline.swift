import Foundation

/// What a session card leads with.
///
/// By default a card leads with the project folder and appends the session
/// title (`#title`). With "Show project name" off — screen sharing, demos,
/// client work — no folder name may appear on the card, so the title moves
/// into the lead slot, and a session without a title falls back to the agent's
/// name rather than to the folder it was supposed to hide.
public struct SessionHeadline: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The project folder (clickable: reveals the folder in Finder).
        case project
        /// The session's own title (Claude custom/AI title, Codex thread name…).
        case sessionTitle
        /// No title yet — the agent's display name ("Claude", "Codex"…).
        case agent
    }

    public let text: String
    public let kind: Kind
    /// Session title rendered after the lead as `#title`; nil when the title
    /// already *is* the lead.
    public let trailingSessionLabel: String?

    public init(text: String, kind: Kind, trailingSessionLabel: String?) {
        self.text = text
        self.kind = kind
        self.trailingSessionLabel = trailingSessionLabel
    }

    /// Short context line for places outside the card (collapsed bar, question
    /// card header) that show the project folder today. Returns nil when there
    /// is nothing to show, so callers can drop the element entirely.
    public static func contextLabel(
        projectName: String?,
        sessionLabel: String?,
        showProjectName: Bool
    ) -> String? {
        showProjectName ? projectName : sessionLabel
    }

    public static func contextLabel(
        projectName: String?,
        session: SessionSnapshot?,
        showProjectName: Bool
    ) -> String? {
        if let session, session.isGeminiDesktopConversation {
            return session.sessionLabel ?? session.sourceLabel
        }
        return contextLabel(projectName: projectName, sessionLabel: session?.sessionLabel, showProjectName: showProjectName)
    }
}

extension SessionSnapshot {
    // Gemini Desktop conversations have a title but no project folder. Gemini CLI
    // still uses the user's project-name preference like the other CLI agents.
    fileprivate var isGeminiDesktopConversation: Bool {
        source == "gemini" && termBundleId == "com.google.GeminiMacOS"
    }

    public func headline(showProjectName: Bool) -> SessionHeadline {
        if showProjectName && !isGeminiDesktopConversation {
            return SessionHeadline(
                text: projectDisplayName,
                kind: .project,
                trailingSessionLabel: sessionLabel
            )
        }
        if let sessionLabel {
            return SessionHeadline(text: sessionLabel, kind: .sessionTitle, trailingSessionLabel: nil)
        }
        return SessionHeadline(text: sourceLabel, kind: .agent, trailingSessionLabel: nil)
    }
}
