import AppKit

struct ScreenDetector {
    struct Candidate {
        let frame: CGRect
        let hasNotch: Bool
        let isMain: Bool
    }

    /// Simulated notch width for non-notch screens — scales with screen width.
    /// User scaling is applied in NotchPanelView.effectiveNotchW (reactive via @AppStorage).
    private static func fakeNotchWidth(for screen: NSScreen) -> CGFloat {
        let screenW = screen.frame.width
        return min(max(screenW * 0.14, 160), 240)
    }

    /// `activeWindowBounds` is in AppKit's global coordinates, as the
    /// candidates' frames are (`appKitRect(fromWindowBounds:primaryScreenMaxY:)`).
    static func autoPreferredIndex(candidates: [Candidate], activeWindowBounds: CGRect?) -> Int? {
        guard !candidates.isEmpty else { return nil }

        if let activeWindowBounds {
            let center = CGPoint(x: activeWindowBounds.midX, y: activeWindowBounds.midY)
            if let index = candidates.firstIndex(where: { $0.frame.contains(center) }) {
                return index
            }

            let bestOverlap = candidates.enumerated()
                .map { offset, candidate in
                    (offset, overlapArea(lhs: candidate.frame, rhs: activeWindowBounds))
                }
                .max { lhs, rhs in lhs.1 < rhs.1 }

            if let bestOverlap, bestOverlap.1 > 0 {
                return bestOverlap.0
            }
        }

        if let notchIndex = candidates.firstIndex(where: \.hasNotch) {
            return notchIndex
        }

        if let mainIndex = candidates.firstIndex(where: \.isMain) {
            return mainIndex
        }

        return candidates.indices.first
    }

    /// A window's CGWindowList bounds in AppKit's global coordinates.
    ///
    /// CGWindowList measures from the top-left of the primary screen with y
    /// growing down, `NSScreen.frame` from its bottom-left with y growing up.
    /// Compared as they were, a window on a display above or below the
    /// primary one — or beside it, below the primary's height — fell on no
    /// screen or on the wrong one, and Auto left the island on another
    /// display than the one being worked on (#384).
    static func appKitRect(fromWindowBounds bounds: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryScreenMaxY - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// Auto's pick for the front window as CGWindowList reports it. The
    /// candidates come in `NSScreen.screens` order: the primary screen, the
    /// one the window list is measured from, first.
    static func autoPreferredIndex(candidates: [Candidate], frontWindowListBounds: CGRect?) -> Int? {
        let primaryMaxY = candidates.first?.frame.maxY ?? 0
        return autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: frontWindowListBounds.map {
                appKitRect(fromWindowBounds: $0, primaryScreenMaxY: primaryMaxY)
            }
        )
    }

    /// Whether a window (AppKit coordinates) covers all of a screen: a
    /// fullscreen app on that display. Its size alone said so of a window as
    /// large as the screen on any display — fullscreen on a monitor of the
    /// same size or larger, or merely maximized on a larger one (#384). On a
    /// notched display fullscreen apps sit below the notch and never do.
    static func windowCoversScreen(_ window: CGRect, screenFrame: CGRect) -> Bool {
        // A point of slack for windows placed at fractional coordinates.
        window.insetBy(dx: -1, dy: -1).contains(screenFrame)
    }

    /// Whether one of these windows (CGWindowList bounds) is fullscreen on
    /// the screen with this frame.
    static func isFullscreen(
        onScreenFrame screenFrame: CGRect,
        windowListBounds: [CGRect],
        primaryScreenMaxY: CGFloat
    ) -> Bool {
        windowListBounds.contains {
            windowCoversScreen(appKitRect(fromWindowBounds: $0, primaryScreenMaxY: primaryScreenMaxY), screenFrame: screenFrame)
        }
    }

    /// Preferred screen: active work screen first, then built-in (notch), then main
    static var preferredScreen: NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return NSScreen.main ?? NSScreen()
        }

        let mainScreen = NSScreen.main
        let candidates = screens.map { screen in
            Candidate(
                frame: screen.frame,
                hasNotch: screenHasNotch(screen),
                isMain: mainScreen == screen
            )
        }

        if let index = autoPreferredIndex(
            candidates: candidates,
            frontWindowListBounds: frontmostApplicationWindowBounds()
        ), index < screens.count {
            return screens[index]
        }

        return mainScreen ?? screens.first ?? NSScreen()
    }

    static var hasNotch: Bool {
        screenHasNotch(preferredScreen)
    }

    /// Check if a specific screen has a notch
    static func screenHasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.auxiliaryTopLeftArea != nil || screen.auxiliaryTopRightArea != nil
        }
        return false
    }

    /// Height of the notch/menu bar area for a specific screen
    static func topBarHeight(for screen: NSScreen) -> CGFloat {
        let realNotchHeight: CGFloat
        if #available(macOS 12.0, *) {
            realNotchHeight = screen.safeAreaInsets.top
        } else {
            realNotchHeight = 0
        }

        // Menu bar height — only present on the screen that has it
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY

        func resolvedMenuBarHeight() -> CGFloat {
            // On the primary screen, this is ~25pt (non-notch) or ~37pt (notch)
            // On secondary screens without menu bar, this is 0
            if menuBarHeight > 5 { return menuBarHeight }
            if let main = NSScreen.main {
                let mainMenuBar = main.frame.maxY - main.visibleFrame.maxY
                if mainMenuBar > 5 { return mainMenuBar }
            }
            return 25
        }

        let modeRaw = UserDefaults.standard.string(forKey: SettingsKey.notchHeightMode) ?? SettingsDefaults.notchHeightMode
        let mode = NotchHeightMode(rawValue: modeRaw) ?? .matchNotch

        switch mode {
        case .matchNotch:
            if realNotchHeight > 0 { return realNotchHeight }
            return resolvedMenuBarHeight()
        case .matchMenuBar:
            return resolvedMenuBarHeight()
        case .custom:
            let custom = UserDefaults.standard.double(forKey: SettingsKey.customNotchHeight)
            let fallback = SettingsDefaults.customNotchHeight
            return CGFloat(max(15, min(custom > 0 ? custom : fallback, 60)))
        }
    }

    /// Height of the notch area — returns menu bar height on non-notch screens
    static var notchHeight: CGFloat {
        topBarHeight(for: preferredScreen)
    }

    /// Width of the notch — returns simulated width on non-notch screens
    static var notchWidth: CGFloat {
        notchWidth(for: preferredScreen)
    }

    /// Width of the notch for a specific screen
    static func notchWidth(for screen: NSScreen) -> CGFloat {
        if #available(macOS 12.0, *) {
            let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
            let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
            if leftWidth > 0 || rightWidth > 0 {
                return screen.frame.width - leftWidth - rightWidth
            }
        }
        return fakeNotchWidth(for: screen)
    }

    /// The display's own identity. It stays with the display across
    /// reconnects and rearrangements, unlike its place in `NSScreen.screens`.
    static func displayUUID(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func signature(for screen: NSScreen) -> String {
        let frame = screen.frame.integral
        return "\(Int(frame.origin.x)):\(Int(frame.origin.y)):\(Int(frame.width)):\(Int(frame.height))"
    }

    private static func overlapArea(lhs: CGRect, rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    /// The front window of the app in front, in CGWindowList coordinates.
    private static func frontmostApplicationWindowBounds() -> CGRect? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let preferredPID: pid_t? = frontApp.processIdentifier == ownPID ? nil : frontApp.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 0,
                  rect.height > 0 else { continue }
            guard pid != ownPID else { continue }
            if let preferredPID, pid != preferredPID { continue }
            return rect
        }

        guard preferredPID != nil else { return nil }

        for window in windowList {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid != ownPID,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 0,
                  rect.height > 0 else { continue }
            return rect
        }

        return nil
    }
}

/// Settings → General → Display: Auto, or the display the island is pinned to.
///
/// A pin names the display by its UUID ("display:<UUID>"). It used to name
/// an index into `NSScreen.screens` ("screen_<index>"), whose order follows
/// the primary display, so making another display the primary one or
/// reconnecting monitors silently moved the island to another display. A
/// legacy value still resolves as it did, and becomes the display's UUID
/// the first time it resolves.
enum DisplayChoice {
    static let auto = "auto"
    private static let pinPrefix = "display:"
    private static let legacyPrefix = "screen_"

    enum Resolution: Equatable {
        /// Auto, or a value this version doesn't know.
        case auto
        /// Pinned to the display at this index of `NSScreen.screens`.
        case pinned(index: Int)
        /// Pinned to a display that isn't connected. Auto's choice stands
        /// in, and the pin stays: the island goes back when it returns.
        case pinnedDisplayMissing
    }

    /// `displayUUIDs`: the connected displays' UUIDs in `NSScreen.screens`
    /// order, nil for a display without one.
    static func resolve(_ choice: String, displayUUIDs: [String?]) -> Resolution {
        if let uuid = pinnedUUID(choice) {
            guard let index = displayUUIDs.firstIndex(of: uuid) else { return .pinnedDisplayMissing }
            return .pinned(index: index)
        }
        if let index = legacyIndex(choice) {
            return index < displayUUIDs.count ? .pinned(index: index) : .pinnedDisplayMissing
        }
        return .auto
    }

    /// What to store in place of a legacy index pin that resolves now: the
    /// UUID pin of the display it names. Nil for anything else.
    static func migrated(_ choice: String, displayUUIDs: [String?]) -> String? {
        guard let index = legacyIndex(choice), index < displayUUIDs.count,
              let uuid = displayUUIDs[index] else { return nil }
        return pinPrefix + uuid
    }

    /// The picker tag of the connected display at `index`: its UUID pin, or
    /// its index for a display without a UUID.
    static func tag(forDisplayAt index: Int, displayUUIDs: [String?]) -> String {
        if let uuid = displayUUIDs[index] { return pinPrefix + uuid }
        return legacyPrefix + String(index)
    }

    /// The picker row a stored choice selects: a legacy pin selects its
    /// display's row, and a pin to a display that isn't connected selects
    /// a row of its own.
    static func pickerSelection(_ choice: String, displayUUIDs: [String?]) -> String {
        switch resolve(choice, displayUUIDs: displayUUIDs) {
        case .auto: return auto
        case .pinned(let index): return tag(forDisplayAt: index, displayUUIDs: displayUUIDs)
        case .pinnedDisplayMissing: return choice
        }
    }

    private static func pinnedUUID(_ choice: String) -> String? {
        guard choice.hasPrefix(pinPrefix) else { return nil }
        let uuid = String(choice.dropFirst(pinPrefix.count))
        return uuid.isEmpty ? nil : uuid
    }

    private static func legacyIndex(_ choice: String) -> Int? {
        guard choice.hasPrefix(legacyPrefix), let index = Int(choice.dropFirst(legacyPrefix.count)),
              index >= 0 else { return nil }
        return index
    }
}
