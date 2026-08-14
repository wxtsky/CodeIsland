import AppKit

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
