import AppKit

enum FourFingerSwipeDirection: Equatable {
    case left
    case right
}

/// Pure threshold math for a raw four-finger trackpad swipe, independent of the
/// NSTouch plumbing that drives it. Watching for the touches directly (rather
/// than reacting to NSWorkspace.activeSpaceDidChangeNotification after the
/// fact) lets the panel start collapsing as the gesture crosses the threshold,
/// not only once macOS has already finished switching Spaces.
enum FourFingerSwipeGesture {
    /// Fraction of the trackpad's normalized width (0...1) the four touches'
    /// average position must move before the swipe counts as deliberate.
    static let normalizedDisplacementThreshold: CGFloat = 0.10

    /// Tolerance for floating-point rounding at the threshold boundary — touch
    /// coordinates are sensor-derived doubles, so exact equality isn't meaningful.
    private static let epsilon: CGFloat = 0.0001

    static func direction(startX: CGFloat, currentX: CGFloat) -> FourFingerSwipeDirection? {
        let movement = currentX - startX
        if movement >= normalizedDisplacementThreshold - epsilon { return .right }
        if movement <= -normalizedDisplacementThreshold + epsilon { return .left }
        return nil
    }
}

/// Tracks raw NSTouch events on whichever view owns it to detect a four-finger
/// horizontal swipe independent of AppKit's own gesture recognizers or of
/// macOS actually completing a Space switch. Delivery is scoped to the key
/// window per AppKit's touch-event model — this fires reliably while the
/// panel itself is key (e.g. right after the user opened it), which is
/// exactly the case this exists for: collapsing an open panel when the user
/// swipes away from it.
protocol FourFingerSwipeObserving: NSView {
    var onFourFingerSwipeThresholdCrossed: (() -> Void)? { get set }
}

extension FourFingerSwipeObserving {
    func fourFingerSwipeTouchesBegan(_ event: NSEvent, state: inout FourFingerSwipeTrackingState) {
        let touches = event.touches(matching: .touching, in: self)
        guard touches.count == 4 else {
            state.reset()
            return
        }
        state.startX = Self.averageX(of: touches)
        state.triggered = false
    }

    func fourFingerSwipeTouchesMoved(_ event: NSEvent, state: inout FourFingerSwipeTrackingState) {
        guard !state.triggered, let startX = state.startX else { return }
        let touches = event.touches(matching: .touching, in: self)
        guard touches.count == 4 else { return }
        let currentX = Self.averageX(of: touches)
        guard FourFingerSwipeGesture.direction(startX: startX, currentX: currentX) != nil else { return }
        state.triggered = true
        onFourFingerSwipeThresholdCrossed?()
    }

    private static func averageX(of touches: Set<NSTouch>) -> CGFloat {
        touches.reduce(CGFloat.zero) { $0 + $1.normalizedPosition.x } / CGFloat(touches.count)
    }
}

struct FourFingerSwipeTrackingState {
    var startX: CGFloat?
    var triggered = false

    mutating func reset() {
        startX = nil
        triggered = false
    }
}
