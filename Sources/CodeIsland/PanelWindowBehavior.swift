import AppKit

enum PanelSpaceTransitionPolicy {
    /// Never hide synchronously from the Space-change callback. The window list
    /// and frontmost app can describe the outgoing desktop during the animation.
    static let immediateFullscreenLatch = false
    static let fullscreenEvaluationDelay: TimeInterval = 0.35

    static func settledFullscreenLatch(isFullscreen: Bool) -> Bool {
        isFullscreen
    }
}

enum PanelWindowBehavior {
    /// `.canJoinAllSpaces` and `.managed` are contradictory membership models —
    /// `.managed` tells Spaces the window belongs to one Space at a time and should
    /// be reassigned as the user switches, which is what caused the island to drop
    /// out and reappear mid-swipe. `.stationary` is the correct pairing: the window
    /// stays pinned in place, like the menu bar, and never participates in the
    /// transition animation at all.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .fullScreenAuxiliary,
        .ignoresCycle,
    ]
}
