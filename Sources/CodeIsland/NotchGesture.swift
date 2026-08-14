import AppKit

// MARK: - Hover interaction state machine

/// Where the island is in its hover interaction. `prehover` is the immediate
/// lightweight acknowledgement shown while the configurable open delay runs.
enum NotchHoverPhase {
    case collapsed
    case prehover
    case expanded
}

enum NotchHoverEvent {
    case mouseEntered
    case mouseExited
    case expandDelayElapsed
    case collapseDelayElapsed
}

enum NotchHoverInteraction {
    static let prehoverAnimationDuration: TimeInterval = 0.21
    static let collapseDelay: TimeInterval = 0.5
    static let prehoverWidthDelta: CGFloat = 7
    static let prehoverScale: CGFloat = 1.004

    static func nextPhase(from phase: NotchHoverPhase, event: NotchHoverEvent) -> NotchHoverPhase {
        switch (phase, event) {
        case (.collapsed, .mouseEntered):
            return .prehover
        case (.prehover, .mouseExited):
            return .collapsed
        case (.prehover, .expandDelayElapsed):
            return .expanded
        case (.expanded, .collapseDelayElapsed):
            return .collapsed
        default:
            return phase
        }
    }

    static func shouldScheduleOpen(openOnHover: Bool) -> Bool {
        openOnHover
    }
}

enum NotchVisualStyle {
    static let contrastEdgeWidth: CGFloat = 0.9
    static let contrastEdgeTopOpacity = 0.005
    static let contrastEdgeSideOpacity = 0.07
    static let contrastEdgeBottomOpacity = 0.20
    static let contrastEdgeUpperHoldLocation = 0.18
    static let contrastEdgeSideLocation = 0.72
    static let contrastEdgeBlurRadius: CGFloat = 0

    static func showsContrastEdge(hasNotch _: Bool, phase _: NotchHoverPhase) -> Bool {
        true
    }
}

/// Live controller-owned dependencies needed by the panel's input behavior.
/// Passing these directly avoids relying on SwiftUI's forwarding app delegate,
/// which is not guaranteed to be the concrete `AppDelegate` instance.
@MainActor
struct NotchPanelInteractionContext {
    let panelFrame: () -> NSRect?
    let isActiveTerminalForeground: () -> Bool
}

enum NotchGestureAction: Equatable, Sendable {
    case open
    case close
    case navigatePrevious
    case navigateNext
}

struct NotchScrollSample: Sendable {
    let physicalDeltaX: CGFloat
    let physicalDeltaY: CGFloat
    let began: Bool
    let ended: Bool
    let momentum: Bool
    let precise: Bool

    init(
        physicalDeltaX: CGFloat,
        physicalDeltaY: CGFloat,
        began: Bool = false,
        ended: Bool = false,
        momentum: Bool = false,
        precise: Bool = true
    ) {
        self.physicalDeltaX = physicalDeltaX
        self.physicalDeltaY = physicalDeltaY
        self.began = began
        self.ended = ended
        self.momentum = momentum
        self.precise = precise
    }

    init(
        scrollingDeltaX: CGFloat,
        scrollingDeltaY: CGFloat,
        directionInvertedFromDevice: Bool,
        began: Bool = false,
        ended: Bool = false,
        momentum: Bool = false,
        precise: Bool = true
    ) {
        let direction: CGFloat = directionInvertedFromDevice ? -1 : 1
        self.init(
            physicalDeltaX: scrollingDeltaX * direction,
            physicalDeltaY: scrollingDeltaY * direction,
            began: began,
            ended: ended,
            momentum: momentum,
            precise: precise
        )
    }

    init(event: NSEvent) {
        self.init(
            scrollingDeltaX: event.scrollingDeltaX,
            scrollingDeltaY: event.scrollingDeltaY,
            directionInvertedFromDevice: event.isDirectionInvertedFromDevice,
            began: event.phase.contains(.began),
            ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
            momentum: !event.momentumPhase.isEmpty,
            precise: event.hasPreciseScrollingDeltas
        )
    }
}

struct NotchGestureHitbox {
    /// Include the exact screen edge and tolerate sub-pixel coordinate rounding
    /// when macOS reports a pointer hidden behind the physical camera notch.
    static let topEdgeExtension: CGFloat = 2

    private let minX: CGFloat
    private let maxX: CGFloat
    private let minY: CGFloat
    private let maxY: CGFloat

    init(panelFrame: NSRect, regionWidth: CGFloat, regionHeight: CGFloat) {
        let width = Swift.min(Swift.max(regionWidth, 0), panelFrame.width)
        minX = panelFrame.midX - width / 2
        maxX = panelFrame.midX + width / 2
        minY = panelFrame.maxY - Swift.min(Swift.max(regionHeight, 0), panelFrame.height)
        maxY = panelFrame.maxY + Self.topEdgeExtension
    }

    func contains(_ point: NSPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

enum NotchGestureRegionMetrics {
    static func resolvedSize(
        renderedSize: CGSize,
        fallbackWidth: CGFloat,
        headerHeight: CGFloat,
        isExpanded: Bool
    ) -> CGSize {
        let width = renderedSize.width > 0 ? renderedSize.width : fallbackWidth
        let height = isExpanded ? max(renderedSize.height, headerHeight) : headerHeight
        return CGSize(width: width, height: height)
    }
}

struct NotchGestureInterpreter {
    static let activationThreshold: CGFloat = 24
    static let axisDominance: CGFloat = 1.2

    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var emitted = false

    mutating func consume(_ sample: NotchScrollSample) -> NotchGestureAction? {
        if sample.began {
            reset()
        }

        if sample.ended {
            reset()
            return nil
        }

        guard sample.precise, !sample.momentum else { return nil }

        accumulatedX += sample.physicalDeltaX
        accumulatedY += sample.physicalDeltaY

        guard !emitted else { return nil }

        let horizontal = abs(accumulatedX)
        let vertical = abs(accumulatedY)
        let action: NotchGestureAction?

        if horizontal >= Self.activationThreshold,
           horizontal >= vertical * Self.axisDominance {
            action = accumulatedX > 0 ? .navigateNext : .navigatePrevious
        } else if vertical >= Self.activationThreshold,
                  vertical >= horizontal * Self.axisDominance {
            action = accumulatedY < 0 ? .open : .close
        } else {
            action = nil
        }

        if action != nil {
            emitted = true
        }
        return action
    }

    mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        emitted = false
    }
}

enum NotchGesturePolicy {
    private static let filterModes = ["all", "status", "cli"]

    static func canOpen(surface: IslandSurface, hasSessions: Bool) -> Bool {
        surface == .collapsed && hasSessions
    }

    static func canClose(surface: IslandSurface) -> Bool {
        switch surface {
        case .sessionList, .completionCard:
            return true
        case .collapsed, .approvalCard, .questionCard:
            return false
        }
    }

    static func filterMode(
        from currentMode: String,
        action: NotchGestureAction,
        controlsVisible: Bool,
        inverted: Bool
    ) -> String? {
        guard controlsVisible,
              let currentIndex = filterModes.firstIndex(of: currentMode) else { return nil }

        let offset: Int
        switch action {
        case .navigatePrevious:
            offset = inverted ? 1 : -1
        case .navigateNext:
            offset = inverted ? -1 : 1
        case .open, .close:
            return nil
        }

        let nextIndex = Swift.min(
            Swift.max(currentIndex + offset, filterModes.startIndex),
            filterModes.index(before: filterModes.endIndex)
        )
        return filterModes[nextIndex]
    }
}

/// Keeps AppKit's ordered gesture interpretation separate from SwiftUI state
/// mutation. Global event-monitor callbacks can arrive while AppKit is already
/// dispatching input, so their resulting UI action runs on the next main-loop
/// turn instead of re-entering panel layout from inside the callback.
@MainActor
struct NotchGestureActionDelivery {
    typealias Work = @MainActor @Sendable () -> Void

    private let schedule: (@escaping Work) -> Void

    init(schedule: @escaping (@escaping Work) -> Void = { work in
        DispatchQueue.main.async(execute: work)
    }) {
        self.schedule = schedule
    }

    func deliver(
        _ action: NotchGestureAction,
        to handler: @escaping @MainActor @Sendable (NotchGestureAction) -> Void
    ) {
        schedule {
            handler(action)
        }
    }
}

@MainActor
final class NotchGestureMonitor {
    var isEnabled = false {
        didSet {
            if !isEnabled {
                interpreter.reset()
            }
        }
    }

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var interpreter = NotchGestureInterpreter()
    private let actionDelivery = NotchGestureActionDelivery()
    private var panelFrameProvider: (() -> NSRect?)?
    private var onAction: ((NotchGestureAction) -> Void)?
    private var regionWidth: CGFloat = 0
    private var regionHeight: CGFloat = 0

    func updateRegion(width: CGFloat, height: CGFloat) {
        regionWidth = width
        regionHeight = height
    }

    func start(
        panelFrameProvider: @escaping () -> NSRect?,
        onAction: @escaping (NotchGestureAction) -> Void
    ) {
        guard localMonitor == nil, globalMonitor == nil else { return }
        self.panelFrameProvider = panelFrameProvider
        self.onAction = onAction

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isEnabled else { return event }
            guard let action = self.consumeObservedSample(
                NotchScrollSample(event: event),
                at: NSEvent.mouseLocation,
                panelFrame: self.panelFrameProvider?()
            ) else { return event }

            self.actionDelivery.deliver(action) { [weak self] action in
                self?.onAction?(action)
            }
            return nil
        }

        // A nonactivating panel does not receive scroll events when macOS routes
        // them to the app underneath the physical notch. Global observation fills
        // that gap; local events remain consumable and are not duplicated here.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return }
            guard
                  let action = self.consumeObservedSample(
                    NotchScrollSample(event: event),
                    at: NSEvent.mouseLocation,
                    panelFrame: self.panelFrameProvider?()
                  ) else { return }
            self.actionDelivery.deliver(action) { [weak self] action in
                self?.onAction?(action)
            }
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        panelFrameProvider = nil
        onAction = nil
        interpreter.reset()
    }

    /// Process samples immediately on AppKit's ordered event-monitor callback.
    /// Deferring each sample into a separate task can reorder began/delta/ended.
    func consumeObservedSample(
        _ sample: NotchScrollSample,
        at location: NSPoint,
        panelFrame: NSRect?
    ) -> NotchGestureAction? {
        guard isEnabled, let panelFrame else {
            interpreter.reset()
            return nil
        }
        guard NotchGestureHitbox(
            panelFrame: panelFrame,
            regionWidth: regionWidth,
            regionHeight: regionHeight
        ).contains(location) else {
            interpreter.reset()
            return nil
        }
        return interpreter.consume(sample)
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
    }
}
