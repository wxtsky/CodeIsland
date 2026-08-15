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
    /// Join every Space while participating in the system's desktop transition,
    /// so the island travels with the screen instead of dropping out mid-swipe.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .canJoinAllApplications,
        .managed,
        .fullScreenAuxiliary,
        .ignoresCycle,
    ]
}
