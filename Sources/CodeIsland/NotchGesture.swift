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
    case hoverDisabled
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
        case (.prehover, .mouseExited), (.prehover, .hoverDisabled):
            return .collapsed
        case (.prehover, .expandDelayElapsed):
            return .expanded
        case (.expanded, .collapseDelayElapsed):
            return .collapsed
        default:
            return phase
        }
    }
}

enum NotchGestureAction: Equatable {
    case open
    case close
    case navigatePrevious
    case navigateNext
}

struct NotchScrollSample {
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
            action = accumulatedX < 0 ? .navigateNext : .navigatePrevious
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
        controlsVisible: Bool
    ) -> String? {
        guard controlsVisible,
              let currentIndex = filterModes.firstIndex(of: currentMode) else { return nil }

        let offset: Int
        switch action {
        case .navigatePrevious:
            offset = -1
        case .navigateNext:
            offset = 1
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

@MainActor
final class NotchGestureMonitor {
    var isEnabled = false {
        didSet {
            if !isEnabled {
                interpreter.reset()
            }
        }
    }

    private var monitor: Any?
    private var interpreter = NotchGestureInterpreter()

    func start(onAction: @escaping (NotchGestureAction) -> Void) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isEnabled else { return event }
            guard let action = self.interpreter.consume(NotchScrollSample(event: event)) else {
                return event
            }

            onAction(action)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        interpreter.reset()
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
