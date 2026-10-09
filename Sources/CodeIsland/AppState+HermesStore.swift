import Foundation
import CodeIslandCore

/// One local Hermes session's read of Hermes's own store.
struct HermesStoreRead {
    var databasePath: String
    /// Hermes's id for the session (`sessions.id`): the hook's `session_id`.
    var storeSessionId: String
    var inFlight = false
    /// Another event came in during the read; read once more when it ends.
    var rerun = false
}

/// Hermes hooks never carry the session title, and carry the prompt and reply
/// only when the user approved those hooks on the Hermes side. Hermes's store
/// (`$HERMES_HOME/state.db`) has all three, so every hook from a local Hermes
/// session schedules a read of it — off the main actor, at most one at a time
/// per session, a burst of hooks folded into one read. Remote sessions never
/// get here: their hook reads the store on the remote host.
extension AppState {
    /// How long a read waits before it starts, so a tool's pre/post pair or a
    /// turn's post_llm_call + on_session_end costs one read rather than two.
    nonisolated static let hermesStoreReadDelay: Duration = .milliseconds(250)

    /// Where Hermes keeps its data when the hook didn't say (an older bridge,
    /// no HERMES_HOME in the hook's environment). Off under tests: they name a
    /// temporary home through `_hermes_home`, never the user's.
    nonisolated static var defaultHermesHome: String? {
        RuntimeEnvironment.isRunningTests ? nil : NSHomeDirectory() + "/.hermes"
    }

    func requestHermesStoreRead(for sessionId: String, event: HookEvent) {
        guard let session = sessions[sessionId], !session.isRemote,
              SessionSnapshot.normalizedSupportedSource(session.source) == "hermes" else { return }
        let hookHome = (event.rawJSON["_hermes_home"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil }
        guard let home = hookHome ?? Self.defaultHermesHome else { return }
        let storeSessionId = (event.rawJSON["session_id"] as? String) ?? sessionId

        var read = hermesStoreReads[sessionId]
            ?? HermesStoreRead(databasePath: "", storeSessionId: storeSessionId)
        read.databasePath = HermesSessionStore.databasePath(hermesHome: home)
        read.storeSessionId = storeSessionId
        if read.inFlight {
            read.rerun = true
            hermesStoreReads[sessionId] = read
            return
        }
        hermesStoreReads[sessionId] = read
        startHermesStoreRead(for: sessionId)
    }

    private func startHermesStoreRead(for sessionId: String) {
        guard var read = hermesStoreReads[sessionId] else { return }
        read.inFlight = true
        read.rerun = false
        hermesStoreReads[sessionId] = read
        let databasePath = read.databasePath
        let storeSessionId = read.storeSessionId
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.hermesStoreReadDelay)
            let snapshot = HermesSessionStore.read(databasePath: databasePath, sessionId: storeSessionId)
            await self?.finishHermesStoreRead(for: sessionId, snapshot: snapshot)
        }
    }

    func finishHermesStoreRead(for sessionId: String, snapshot: HermesSessionStore.Snapshot?) {
        // Gone with its session (removeSession drops the read).
        guard var read = hermesStoreReads[sessionId] else { return }
        read.inFlight = false
        hermesStoreReads[sessionId] = read
        // Write back only a change: every write to `sessions` redraws the panel.
        if let snapshot, var session = sessions[sessionId], session.applyHermesStore(snapshot) {
            sessions[sessionId] = session
            scheduleSave()
            refreshDerivedState()  // companions show the title and preview too
        }
        if read.rerun {
            startHermesStoreRead(for: sessionId)
        }
    }
}
