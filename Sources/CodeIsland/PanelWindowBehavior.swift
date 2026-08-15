import AppKit

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
