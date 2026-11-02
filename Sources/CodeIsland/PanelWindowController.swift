import AppKit
import SwiftUI
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "Panel")

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// The island deliberately overlaps the menu-bar / notch area. AppKit's
    /// default constrain clamps borderless windows below the menu bar whenever
    /// the system re-places windows (display reconfigure, wake from sleep),
    /// which detaches the panel from the notch (#263).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Ensures first click on a nonactivatingPanel fires SwiftUI actions
/// instead of being consumed for key-window activation.
/// Also guards against NSHostingView constraint-update re-entrancy crash:
/// during updateConstraints(), SwiftUI may invalidate the view graph and
/// call setNeedsUpdateConstraints again, which AppKit forbids.
private class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// When true, the deferred handler is setting super — don't re-defer.
    private var applyingDeferred = false

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Latest requested value awaiting its deferred apply, or nil when nothing
    /// is queued. Coalescing matters: SwiftUI sets these several times per
    /// animation frame, and the mascot drives frames continuously, so one
    /// `DispatchQueue.main.async` per *set* was a permanent stream of closure
    /// allocations and main-queue wakeups on an otherwise idle Mac (#299).
    private var pendingConstraintsValue: Bool?
    private var pendingLayoutValue: Bool?

    /// Always defer `needsUpdateConstraints = true` to the next run-loop turn.
    /// During AppKit's display-cycle (constraint-update or layout phases),
    /// calling setNeedsUpdateConstraints synchronously re-enters
    /// `_postWindowNeedsUpdateConstraints` and throws.  Deferring avoids
    /// that entirely; the one-tick delay is imperceptible.
    override var needsUpdateConstraints: Bool {
        get { super.needsUpdateConstraints }
        set {
            if applyingDeferred {
                super.needsUpdateConstraints = newValue
                return
            }
            // Nothing queued and already in the requested state — no-op.
            if pendingConstraintsValue == nil, super.needsUpdateConstraints == newValue { return }
            let alreadyScheduled = pendingConstraintsValue != nil
            pendingConstraintsValue = newValue
            guard !alreadyScheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let value = self.pendingConstraintsValue else { return }
                self.pendingConstraintsValue = nil
                self.applySuperNeedsUpdateConstraints(value)
            }
        }
    }

    private func applySuperNeedsUpdateConstraints(_ value: Bool) {
        applyingDeferred = true
        super.needsUpdateConstraints = value
        applyingDeferred = false
    }

    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if applyingDeferred {
                super.needsLayout = newValue
                return
            }
            if pendingLayoutValue == nil, super.needsLayout == newValue { return }
            let alreadyScheduled = pendingLayoutValue != nil
            pendingLayoutValue = newValue
            guard !alreadyScheduled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let value = self.pendingLayoutValue else { return }
                self.pendingLayoutValue = nil
                self.applySuperNeedsLayout(value)
            }
        }
    }

    private func applySuperNeedsLayout(_ value: Bool) {
        applyingDeferred = true
        super.needsLayout = value
        applyingDeferred = false
    }
}

struct PanelScreenHopFrames {
    let outgoing: NSRect
    let incoming: NSRect
}

struct PanelScreenHopMotion {
    let outgoingOffset: CGFloat
    let incomingOffset: CGFloat
    let fadeOutDuration: TimeInterval
    let incomingPauseDuration: TimeInterval
    let fadeInDuration: TimeInterval
}

enum PanelHeightMetrics {
    /// Window height the panel asks for before clamping to the screen: room
    /// for `maxVisibleSessions` cards plus the notch bar. Shared with the
    /// completion card, whose reply area has to fit inside the same window.
    static func desiredHeight(maxVisibleSessions: Int) -> CGFloat {
        let sessions = CGFloat(max(2, maxVisibleSessions))
        return max(300, sessions * 90 + 60)
    }
}

/// Hide in Fullscreen's hold on the island: the latch a fullscreen app on
/// the island's display sets, and the reveal a shortcut makes over it.
struct PanelFullscreenHide {
    /// The island's display shows a fullscreen app.
    private(set) var isLatched = false
    /// A shortcut asked for the island while the latch hid it. Hide in
    /// Fullscreen keeps the island out of the way by itself; a key press
    /// that asks for it gets it, until it collapses again (#384).
    private(set) var isRevealed = false

    mutating func latch() { isLatched = true }

    mutating func unlatch() {
        isLatched = false
        isRevealed = false
    }

    mutating func reveal() {
        if isLatched { isRevealed = true }
    }

    mutating func islandCollapsed() { isRevealed = false }

    func hidesIsland(hideInFullscreen: Bool) -> Bool {
        hideInFullscreen && isLatched && !isRevealed
    }
}

/// Where the island is for a shortcut the user just pressed.
enum PanelSight {
    /// Whether the press should bring the island to the user rather than
    /// take it as seen. It should when the island is hidden over a
    /// fullscreen app, or up on another display than the one being worked
    /// on — or on its way between two — with the user not on it (typing
    /// into its card, pointing at it). Hidden for another reason — no
    /// session running — there is nothing to bring.
    static func isAway(
        hiddenInFullscreen: Bool,
        isShown: Bool,
        userIsOnIsland: Bool,
        isOnWorkingDisplay: @autoclosure () -> Bool
    ) -> Bool {
        if hiddenInFullscreen { return true }
        guard isShown, !userIsOnIsland else { return false }
        return !isOnWorkingDisplay()
    }
}

@MainActor
class PanelWindowController: NSObject, NSWindowDelegate {
    private enum ScreenHopMetrics {
        static let outgoingOffset: CGFloat = 18
        static let incomingOffset: CGFloat = 30
        static let fadeOutDuration: TimeInterval = 0.14
        static let incomingPauseDuration: TimeInterval = 0.06
        static let fadeInDuration: TimeInterval = 0.34
    }

    nonisolated static func screenHopMotion() -> PanelScreenHopMotion {
        PanelScreenHopMotion(
            outgoingOffset: ScreenHopMetrics.outgoingOffset,
            incomingOffset: ScreenHopMetrics.incomingOffset,
            fadeOutDuration: ScreenHopMetrics.fadeOutDuration,
            incomingPauseDuration: ScreenHopMetrics.incomingPauseDuration,
            fadeInDuration: ScreenHopMetrics.fadeInDuration
        )
    }

    private var panel: NSPanel?
    private var hostingView: NotchHostingView<NotchPanelView>?
    private let appState: AppState

    nonisolated static func screenHopFrames(
        oldFrame: NSRect,
        newFrame: NSRect
    ) -> PanelScreenHopFrames {
        let motion = screenHopMotion()
        return PanelScreenHopFrames(
            outgoing: oldFrame.offsetBy(dx: 0, dy: motion.outgoingOffset),
            incoming: newFrame.offsetBy(dx: 0, dy: motion.incomingOffset)
        )
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        let desiredH = PanelHeightMetrics.desiredHeight(
            maxVisibleSessions: UserDefaults.standard.integer(forKey: SettingsKey.maxVisibleSessions)
        )
        // Clamp to the screen's usable height. A borderless, non-opaque panel with a
        // very tall backing store (e.g. maxVisibleSessions=99 → 8970pt, ~18k px tall on
        // a Retina display) has its compositing dropped by the macOS 26 WindowServer
        // once the surface goes idle — the card renders blank until a mouse event forces
        // a redraw, which looked like "invisible after ~2s, reappears on hover" (#304).
        // The content is top-anchored and the session list scrolls internally, so the
        // window never needs to be taller than the visible screen.
        let maxH = min(desiredH, screen.visibleFrame.height)
        let screenW = screen.frame.width
        let width = min(620, screenW - 40)
        return NSSize(width: width, height: maxH)
    }

    private var panelSize: NSSize {
        panelSize(for: chosenScreen())
    }

    private var visibilityTimer: Timer?
    private var autoScreenPoller: Timer?
    private var fullscreenPoller: Timer?
    private var isSessionObservationArmed = false
    private var fullscreenHide = PanelFullscreenHide()
    private var settingsObservers: [NSObjectProtocol] = []
    private var globalClickMonitor: Any?
    private var lastChosenScreenSignature = ""
    private var isAnimatingScreenHop = false
    private var dragStartMouseX: CGFloat?
    private var dragStartPanelX: CGFloat?
    private var isDraggingPanel = false
    private var localDragMonitor: Any?
    private var lastDisplayChoice = ""
    private var lastNotchHeightMode = SettingsDefaults.notchHeightMode
    private var lastCustomNotchHeight = SettingsDefaults.customNotchHeight

    init(appState: AppState) {
        self.appState = appState
        super.init()
    }

    /// Watch `sessions` / `surface` for changes that affect panel visibility.
    ///
    /// `withObservationTracking` is one-shot, so it has to be re-armed. Doing
    /// that from a 500 ms polling loop meant a permanent timer wakeup on a Mac
    /// where nothing was happening (#299) — and it bought nothing, because the
    /// loop never *detected* anything: `onChange` already fires the instant a
    /// tracked property is written. Re-arm from `onChange` instead, so an idle
    /// app schedules no work at all.
    ///
    /// Re-arming happens in the same main-actor turn as `updateVisibility()`,
    /// with no await between them, so no mutation can slip through the window
    /// where tracking is momentarily disarmed.
    private func armSessionObservation() {
        guard !isSessionObservationArmed else { return }
        isSessionObservationArmed = true
        withObservationTracking {
            _ = appState.sessions
            _ = appState.surface
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isSessionObservationArmed = false
                self.updateVisibility()
                self.armSessionObservation()
            }
        }
    }

    func showPanel() {
        let screen = chosenScreen()
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView

        let size = panelSize
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .readOnly
        panel.contentView = contentView
        panel.delegate = self

        self.panel = panel
        self.lastChosenScreenSignature = ScreenDetector.signature(for: screen)
        // A follow-up for the card under the pointer would remind someone who
        // is already reading it. The island's own hover says whether the
        // pointer is on the card (`pointerOverIsland`); the window frame —
        // mostly transparent, and as large as the card ever gets — only
        // backs that up against a hover flag a rebuilt view left behind.
        appState.followUps.isPointerOverPanel = { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return false }
            return panel.frame.contains(NSEvent.mouseLocation)
        }

        setupHorizontalDragMonitor()
        updatePosition()
        panel.orderFrontRegardless()
        MascotAnimationGate.shared.setPanelVisible(true)

        // Screen change observer
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen(forceRebuild: true)
                // macOS may not have finished updating NSScreen.screens when the notification fires.
                // Rebuild again after a short delay to pick up the final screen configuration.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.refreshCurrentScreen(forceRebuild: true)
                // A pinned display that went away leaves the island to Auto
                // until it is back.
                self?.configureAutoScreenPolling()
            }
        }

        // Active space change — check fullscreen
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if self.isActiveSpaceFullscreen() {
                    self.fullscreenHide.latch()
                    self.updateVisibility()
                    self.startFullscreenExitPoller()
                } else {
                    // Non-fullscreen space: clear any stale latch immediately so the panel
                    // doesn't stay hidden for up to 1.5s while the exit poller catches up (#104).
                    if self.fullscreenHide.isLatched {
                        self.fullscreenHide.unlatch()
                        self.fullscreenPoller?.invalidate()
                        self.fullscreenPoller = nil
                    }
                    self.updateVisibility()
                }
            }
        }

        // Frontmost app change
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.refreshCurrentScreen()
                if !self.fullscreenHide.isLatched { self.updateVisibility() }
            }
        }

        // Observe session changes via @Observable tracking
        armSessionObservation()

        // Observe settings changes (display choice, panel height)
        observeSettingsChanges()
        configureAutoScreenPolling()

        // Global click monitor: close panel + repost click when clicking outside
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
                guard let self = self, self.appState.surface.isExpanded else { return }
                // Don't close during approval/question
                switch self.appState.surface {
                case .approvalCard, .questionCard: return
                default: break
                }
                // Don't collapse if click is within the panel frame (event leaked on external display)
                if let panelFrame = self.panel?.frame {
                    let clickLocation = NSEvent.mouseLocation
                    if panelFrame.contains(clickLocation) { return }
                }
                withAnimation(NotchAnimation.close) {
                    self.appState.surface = .collapsed
                    self.appState.cancelCompletionQueue()
                }
            }
        }
    }

    private func makeHostingView(for screen: NSScreen) -> NotchHostingView<NotchPanelView> {
        let hasNotch = ScreenDetector.screenHasNotch(screen)
        let notchHeight = ScreenDetector.topBarHeight(for: screen)
        let notchW = ScreenDetector.notchWidth(for: screen)

        let rootView = NotchPanelView(
            appState: appState,
            hasNotch: hasNotch,
            notchHeight: notchHeight,
            notchW: notchW,
            screenWidth: screen.frame.width
        )
        let contentView = NotchHostingView(rootView: rootView)
        contentView.sizingOptions = []
        contentView.translatesAutoresizingMaskIntoConstraints = true
        return contentView
    }

    /// Rebuild the SwiftUI view when the target screen changes
    /// (notchHeight, notchWidth, hasNotch may be different)
    private func rebuildForCurrentScreen(_ screen: NSScreen) {
        guard let panel = panel else { return }
        let contentView = makeHostingView(for: screen)
        self.hostingView = contentView
        panel.contentView = contentView
        lastChosenScreenSignature = ScreenDetector.signature(for: screen)
        panel.setFrame(panelFrame(for: screen), display: true)
    }

    private func refreshCurrentScreen(forceRebuild: Bool = false) {
        if isAnimatingScreenHop { return }

        let screen = chosenScreen()
        let signature = ScreenDetector.signature(for: screen)

        if forceRebuild {
            rebuildForCurrentScreen(screen)
            return
        }

        // Not out from under the user: a move rebuilds the island, and one
        // while they point at it or type into it took their half-typed answer
        // and their place with it. It follows at the next check once they've
        // left it (the poll, the next app switch or Space change).
        if signature != lastChosenScreenSignature, !isUserOnIsland {
            animateScreenHop(to: screen, signature: signature)
        }
    }

    private func animateScreenHop(to screen: NSScreen, signature: String) {
        guard let panel = panel else {
            rebuildForCurrentScreen(screen)
            return
        }

        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            rebuildForCurrentScreen(screen)
            panel.alphaValue = 1
            return
        }

        isAnimatingScreenHop = true
        let oldFrame = panel.frame
        let newFrame = panelFrame(for: screen)
        let motion = Self.screenHopMotion()
        let frames = Self.screenHopFrames(oldFrame: oldFrame, newFrame: newFrame)
        let targetSignature = signature

        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frames.outgoing, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard let panel = self.panel else {
                    self.isAnimatingScreenHop = false
                    return
                }

                let targetScreen = NSScreen.screens.first {
                    ScreenDetector.signature(for: $0) == targetSignature
                } ?? self.chosenScreen()

                self.rebuildForCurrentScreen(targetScreen)
                panel.alphaValue = 0
                panel.setFrame(frames.incoming, display: true)

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(motion.incomingPauseDuration * 1_000_000_000))
                    guard let self = self else { return }
                    guard let panel = self.panel else {
                        self.isAnimatingScreenHop = false
                        return
                    }

                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = motion.fadeInDuration
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
                        panel.animator().alphaValue = 1
                        panel.animator().setFrame(newFrame, display: true)
                    } completionHandler: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.lastChosenScreenSignature = targetSignature
                            self?.isAnimatingScreenHop = false
                        }
                    }
                }
            }
        }
    }

    private func observeSettingsChanges() {
        lastDisplayChoice = SettingsManager.shared.displayChoice
        lastNotchHeightMode = SettingsManager.shared.notchHeightMode.rawValue
        lastCustomNotchHeight = SettingsManager.shared.customNotchHeight
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                let newChoice = SettingsManager.shared.displayChoice
                let newHeightMode = SettingsManager.shared.notchHeightMode.rawValue
                let newCustomHeight = SettingsManager.shared.customNotchHeight
                if newChoice != self.lastDisplayChoice {
                    self.lastDisplayChoice = newChoice
                    self.refreshCurrentScreen(forceRebuild: true)
                    self.configureAutoScreenPolling()
                } else if newHeightMode != self.lastNotchHeightMode
                    || abs(newCustomHeight - self.lastCustomNotchHeight) > 0.001 {
                    self.lastNotchHeightMode = newHeightMode
                    self.lastCustomNotchHeight = newCustomHeight
                    self.refreshCurrentScreen(forceRebuild: true)
                } else {
                    self.updateVisibility()
                    self.updatePosition()
                }
            }
        }
        settingsObservers.append(observer)
    }

    private func configureAutoScreenPolling() {
        autoScreenPoller?.invalidate()
        autoScreenPoller = nil

        guard !isPinnedToConnectedDisplay else { return }

        // Screen-parameter / Space-change / frontmost-app notifications already cover the
        // common cases. This poller is a fallback for the rare path where a window is
        // dragged to another display without switching focus — a low cadence is enough
        // and every tick runs a full CGWindowListCopyWindowInfo, which was measurably
        // contributing to Energy Impact (#92).
        autoScreenPoller = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshCurrentScreen()
            }
        }
    }

    private func updatePosition() {
        guard let panel = panel else { return }
        let screen = chosenScreen()
        // Another display than the one the view was built for is a display
        // change, which rebuilds the view for that display's notch.
        guard ScreenDetector.signature(for: screen) == lastChosenScreenSignature else {
            refreshCurrentScreen()
            return
        }
        panel.setFrame(panelFrame(for: screen), display: true)
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let size = panelSize(for: screen)
        let screenFrame = screen.frame
        let centeredX = centeredX(for: size, screen: screen)
        let dragOffset = SettingsManager.shared.allowHorizontalDrag
            ? CGFloat(SettingsManager.shared.panelHorizontalOffset)
            : 0
        var desiredX = centeredX + dragOffset

        // #219: on external screens the simulated notch can land on third-party
        // status items (Bartender & co.) — slide it into the nearest clear gap.
        // A user-dragged offset is an explicit choice and always wins.
        if SettingsManager.shared.avoidMenuBarIcons,
           dragOffset == 0,
           !ScreenDetector.screenHasNotch(screen) {
            let occupied = MenuBarIconAvoidance.occupiedMenuBarRanges(on: screen)
            desiredX = MenuBarIconAvoidance.resolvedX(
                preferredX: desiredX,
                panelWidth: size.width,
                occupied: occupied,
                screenMinX: screenFrame.minX,
                screenMaxX: screenFrame.maxX,
                maxShift: screenFrame.width * MenuBarIconAvoidance.maxShiftFraction
            )
        }

        let x = clampedX(desiredX, panelWidth: size.width, on: screen)
        let y = screenFrame.maxY - size.height
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func centeredX(for size: NSSize, screen: NSScreen) -> CGFloat {
        screen.frame.midX - size.width / 2
    }

    private func clampedX(_ desiredX: CGFloat, panelWidth: CGFloat, on screen: NSScreen) -> CGFloat {
        min(max(desiredX, screen.frame.minX), screen.frame.maxX - panelWidth)
    }

    private func setupHorizontalDragMonitor() {
        let dragThreshold: CGFloat = 5

        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let panel = self.panel,
                  SettingsManager.shared.allowHorizontalDrag else { return event }

            switch event.type {
            case .leftMouseDown:
                if event.window === panel {
                    self.dragStartMouseX = NSEvent.mouseLocation.x
                    self.dragStartPanelX = panel.frame.origin.x
                    self.isDraggingPanel = false
                }
            case .leftMouseDragged:
                if let startMouseX = self.dragStartMouseX,
                   let startPanelX = self.dragStartPanelX {
                    let deltaX = NSEvent.mouseLocation.x - startMouseX
                    // Only start moving after exceeding threshold
                    if !self.isDraggingPanel {
                        guard abs(deltaX) > dragThreshold else { return event }
                        self.isDraggingPanel = true
                    }
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let newX = self.clampedX(startPanelX + deltaX, panelWidth: size.width, on: screen)
                    let fixedY = screen.frame.maxY - size.height
                    panel.setFrameOrigin(NSPoint(x: newX, y: fixedY))
                }
            case .leftMouseUp:
                if self.isDraggingPanel, let panel = self.panel {
                    let screen = self.chosenScreen()
                    let size = panel.frame.size
                    let offset = panel.frame.origin.x - self.centeredX(for: size, screen: screen)
                    SettingsManager.shared.panelHorizontalOffset = Double(offset)
                }
                self.dragStartMouseX = nil
                self.dragStartPanelX = nil
                self.isDraggingPanel = false
            default:
                break
            }
            return event
        }
    }

    /// Choose which screen to display on based on displayChoice setting
    private func chosenScreen() -> NSScreen {
        let screens = NSScreen.screens
        let uuids = screens.map(ScreenDetector.displayUUID(for:))
        let choice = SettingsManager.shared.displayChoice

        // A pin saved as a screen index takes its display's UUID the first
        // time it resolves; the display it names doesn't change.
        if let migrated = DisplayChoice.migrated(choice, displayUUIDs: uuids) {
            lastDisplayChoice = migrated
            SettingsManager.shared.displayChoice = migrated
        }
        if case .pinned(let index) = DisplayChoice.resolve(choice, displayUUIDs: uuids) {
            return screens[index]
        }

        // Auto — prefer the active work screen, then notch, then main. A
        // pinned display that isn't connected gets the same, and its pin
        // stays for when it comes back.
        return ScreenDetector.preferredScreen
    }

    /// Whether the island stays on a pinned display, connected now; Auto
    /// (and a missing pin) follows the window in front.
    private var isPinnedToConnectedDisplay: Bool {
        let uuids = NSScreen.screens.map(ScreenDetector.displayUUID(for:))
        if case .pinned = DisplayChoice.resolve(SettingsManager.shared.displayChoice, displayUUIDs: uuids) {
            return true
        }
        return false
    }

    /// Poll every 1.5s while in fullscreen; stop when fullscreen ends
    private func startFullscreenExitPoller() {
        fullscreenPoller?.invalidate()
        fullscreenPoller = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }
                if !self.isActiveSpaceFullscreen() {
                    self.fullscreenHide.unlatch()
                    self.updateVisibility()
                    timer.invalidate()
                    self.fullscreenPoller = nil
                }
            }
        }
    }

    /// Update panel visibility based on settings
    private func updateVisibility() {
        guard let panel = panel else { return }
        let settings = SettingsManager.shared
        // A shortcut's reveal lasts while the island stays open.
        if !appState.surface.isExpanded { fullscreenHide.islandCollapsed() }
        if fullscreenHide.hidesIsland(hideInFullscreen: settings.hideInFullscreen) {
            panel.orderOut(nil)
            MascotAnimationGate.shared.setPanelVisible(false)
            return
        }

        if settings.hideWhenNoSession && appState.activeSessionCount == 0 {
            panel.orderOut(nil)
            MascotAnimationGate.shared.setPanelVisible(false)
            return
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        MascotAnimationGate.shared.setPanelVisible(true)
        MascotAnimationGate.shared.setIdleSettled(isIslandSettled())
    }

    /// Collapsed island with nothing running — the state a Mac spends most of
    /// its day in, and the one where a live mascot timeline costs real CPU for
    /// motion nobody is looking at (#299). Any expanded surface, or any session
    /// that is not idle, keeps the mascot animating.
    private func isIslandSettled() -> Bool {
        guard !appState.surface.isExpanded else { return false }
        return appState.sessions.values.allSatisfy { $0.status == .idle }
    }

    /// Whether the frontmost app is fullscreen on the island's display. One
    /// fullscreen on another display — with "Displays have separate Spaces"
    /// each display shows a Space of its own — leaves the island alone.
    private func isActiveSpaceFullscreen() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return false }

        // Primary: check if frontmost app has a window covering the entire screen
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
        let appWindows = windowList.compactMap { window -> CGRect? in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  pid == frontApp.processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        return ScreenDetector.isFullscreen(
            onScreenFrame: chosenScreen().frame,
            windowListBounds: appWindows,
            primaryScreenMaxY: primaryMaxY
        )
    }

    // MARK: - Shortcuts

    /// Whether the island is up on a screen, whichever display it is on: a
    /// card on it can be seen. Hidden over a fullscreen app, it can't.
    var isIslandOnScreen: Bool {
        panel?.isVisible == true
    }

    /// Whether a shortcut should bring the island to the user rather than
    /// take it as seen (`PanelSight.isAway`). With Auto, the working display
    /// is the one of the window in front, which the island otherwise follows
    /// only on an app switch, a Space change or a 5 s poll — not when the
    /// user moves between two windows of one app on different displays.
    var isIslandAwayFromUser: Bool {
        guard let panel else { return false }
        return PanelSight.isAway(
            hiddenInFullscreen: fullscreenHide.hidesIsland(hideInFullscreen: SettingsManager.shared.hideInFullscreen),
            isShown: panel.isVisible,
            userIsOnIsland: isUserOnIsland,
            isOnWorkingDisplay: !isAnimatingScreenHop
                && ScreenDetector.signature(for: chosenScreen()) == lastChosenScreenSignature
        )
    }

    /// Bring the island to the user for a shortcut they pressed: onto the
    /// display they are working on, and up even where Hide in Fullscreen
    /// hides it, until it collapses again. Call it once the surface the
    /// press opened is set. (#384)
    func bringIslandIntoSight() {
        fullscreenHide.reveal()
        // Typing into its card or pointing at it, the user already has it.
        if !isUserOnIsland { refreshCurrentScreen() }
        updateVisibility()
    }

    /// The user is on the island itself: it holds keyboard focus (they
    /// clicked into it), or the pointer is on it. A view rebuilt mid-hover
    /// can leave `pointerOverIsland` behind, so the window frame backs it up.
    private var isUserOnIsland: Bool {
        guard let panel, panel.isVisible else { return false }
        if panel.isKeyWindow { return true }
        return appState.followUps.pointerOverIsland && panel.frame.contains(NSEvent.mouseLocation)
    }

    /// Whether the island currently holds keyboard focus. It only becomes key
    /// when the user clicks into it (NotchHostingView.mouseDown).
    var isPanelKeyWindow: Bool {
        panel?.isKeyWindow == true
    }

    /// Fast check: is the terminal running the active session the foreground app?
    /// Main-thread safe — no AppleScript or subprocess calls.
    func isActiveTerminalForeground() -> Bool {
        guard let sessionId = appState.activeSessionId,
              let session = appState.sessions[sessionId],
              session.termApp != nil else { return false }
        return TerminalVisibilityDetector.isTerminalFrontmostForSession(session)
    }

    func windowDidMove(_ notification: Notification) {
        // Horizontal drag (setupHorizontalDragMonitor) only ever changes x, and the
        // screen-hop animation runs under isAnimatingScreenHop. A y drifted off the
        // top edge therefore means the system re-placed the panel — e.g. a display
        // reconfigure clamping it below the menu bar (#263) — so snap it back.
        guard !isDraggingPanel, !isAnimatingScreenHop, let panel = panel else { return }
        let expectedY = chosenScreen().frame.maxY - panel.frame.height
        guard abs(panel.frame.origin.y - expectedY) > 0.5 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isDraggingPanel, !self.isAnimatingScreenHop else { return }
            self.updatePosition()
        }
    }

    deinit {
        autoScreenPoller?.invalidate()
        fullscreenPoller?.invalidate()
        for observer in settingsObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localDragMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
