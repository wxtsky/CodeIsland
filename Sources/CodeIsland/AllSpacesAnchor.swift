import AppKit

/// Anchors a window into a dedicated private CoreGraphics "space" that sits far
/// above the ordinary per-desktop Space stack, instead of relying solely on
/// `NSWindow.collectionBehavior`'s `.canJoinAllSpaces`. Public collectionBehavior
/// tells WindowServer the window is a *member* of every Space, but the window is
/// still part of the normal per-Space window pool and can still be nudged during
/// a Space-swipe gesture. Anchoring it into a separate, always-shown space above
/// everything else keeps it outside that pool entirely — the same mechanism
/// several other menu-bar/notch overlay tools rely on for this exact guarantee.
///
/// This uses undocumented CoreGraphics ("CGS") symbols. They've been stable for
/// years across many shipping tools that use this pattern, but Apple could
/// change or remove them in a future release.
final class AllSpacesAnchor {
    static let shared = AllSpacesAnchor()

    /// Absolute level for the anchor space. Deliberately the maximum 32-bit
    /// value CGS's level field accepts — the private API's underlying type
    /// is narrower than Swift's `Int`, so this uses the exact tested constant
    /// rather than `Int.max`.
    private static let maxSpaceLevel = 2_147_483_647

    private let spaceID: CGSSpaceID
    private var anchoredWindows: Set<NSWindow> = []

    private init() {
        // The creation option MUST be 1 — with 0, Finder treats the new space
        // as a real desktop and starts drawing desktop icons into it.
        let desktopIconSuppressionFlag = 1
        spaceID = CGSSpaceCreate(CGSMainConnection(), desktopIconSuppressionFlag, nil)
        CGSSpaceSetAbsoluteLevel(CGSMainConnection(), spaceID, Self.maxSpaceLevel)
        CGSShowSpaces(CGSMainConnection(), [spaceID])
    }

    /// Moves `window` into the anchor space. Idempotent.
    func anchor(_ window: NSWindow) {
        guard !anchoredWindows.contains(window) else { return }
        anchoredWindows.insert(window)
        CGSAddWindowsToSpaces(CGSMainConnection(), [window.windowNumber] as NSArray, [spaceID])
    }

    /// Removes `window` from the anchor space. Idempotent.
    func release(_ window: NSWindow) {
        guard anchoredWindows.remove(window) != nil else { return }
        CGSRemoveWindowsFromSpaces(CGSMainConnection(), [window.windowNumber] as NSArray, [spaceID])
    }

    deinit {
        CGSHideSpaces(CGSMainConnection(), [spaceID])
        CGSSpaceDestroy(CGSMainConnection(), spaceID)
    }
}

// MARK: - Private CoreGraphics Spaces bindings

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func CGSMainConnection() -> CGSConnectionID

@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ options: Int, _ properties: NSDictionary?) -> CGSSpaceID

@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)

@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)

@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)

@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)

@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
