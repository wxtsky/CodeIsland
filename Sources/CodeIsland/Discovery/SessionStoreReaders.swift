import Foundation
import CodeIslandCore

/// One `SessionTitleStore` lookup: the provider's own session id, and the cwd
/// a Claude transcript sits under (or the transcript path its hooks sent).
struct ProviderTitleLookup: Sendable {
    let sessionId: String
    let provider: String
    let cwd: String?
    var transcriptPath: String? = nil
}

/// The reads AppState makes of an agent's own store for a card it already
/// shows: its provider title, its model, whether a native app finished its
/// turn, Cursor's YOLO setting. Each reads a file or a database, and hooks
/// and the cleanup tick ask for them, so AppState runs them off the main
/// actor. `live` reads the machine; a test process reads nothing (`inert`)
/// unless a test installs readers (`AppState.storeReaders`).
struct SessionStoreReaders: Sendable {
    /// The card's title in its provider's store (Codex's thread index, the
    /// Claude app's Code tab title, a Claude transcript's custom / AI title).
    var title: @Sendable (_ lookup: ProviderTitleLookup) -> ResolvedSessionTitle?
    /// The model the card's transcript or session store records.
    var model: @Sendable (_ sessionId: String, _ session: SessionSnapshot) -> String?
    /// When a native app's card last finished a turn, by its transcript.
    var nativeAppFinishedTurn: @Sendable (_ sessionId: String, _ session: SessionSnapshot) -> Date?
    /// Whether Cursor's settings turn YOLO mode on.
    var cursorYoloMode: @Sendable () -> Bool

    static let live = SessionStoreReaders(
        title: {
            SessionTitleStore.title(
                for: $0.sessionId, provider: $0.provider, cwd: $0.cwd, transcriptPath: $0.transcriptPath)
        },
        model: { SessionDiscovery.readModelForSession(sessionId: $0, session: $1) },
        nativeAppFinishedTurn: { SessionDiscovery.nativeAppFinishedTurnTimestamp(sessionId: $0, session: $1) },
        cursorYoloMode: { CursorDiscovery.detectCursorYoloMode() }
    )

    /// Finds nothing: no title, no model, no turn end, YOLO off.
    static let inert = SessionStoreReaders(
        title: { _ in nil },
        model: { _, _ in nil },
        nativeAppFinishedTurn: { _, _ in nil },
        cursorYoloMode: { false }
    )

    /// `inert` in a test process, `live` otherwise.
    static var current: SessionStoreReaders { RuntimeEnvironment.isRunningTests ? .inert : .live }
}
