import Foundation

/// Which finger counts macOS currently treats as a horizontal Spaces swipe.
///
/// The gesture is user-configurable (System Settings › Trackpad › More
/// Gestures › "Swipe between full-screen applications"), so hard-coding four
/// fingers would miss the swipe entirely for anyone who picked three — and
/// would fire on an unrelated three-finger page swipe for anyone who didn't.
enum SpacesSwipeFingerCounts {
    /// `2` means the gesture is enabled, `0` disabled. Two domains exist: the
    /// built-in trackpad and a paired Magic Trackpad.
    private static let enabledValue = 2
    private static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad",
    ]
    private static let threeFingerKey = "TrackpadThreeFingerHorizSwipeGesture"
    private static let fourFingerKey = "TrackpadFourFingerHorizSwipeGesture"

    /// Pure resolution so the preference decoding is testable without touching
    /// real user defaults. `nil` means "preference absent".
    static func resolve(threeFinger: Int?, fourFinger: Int?) -> Set<Int> {
        guard threeFinger != nil || fourFinger != nil else {
            // Nothing readable — accept either rather than silently doing
            // nothing, since a false collapse is far cheaper than a miss.
            return [3, 4]
        }
        var counts: Set<Int> = []
        if threeFinger == enabledValue { counts.insert(3) }
        if fourFinger == enabledValue { counts.insert(4) }
        return counts
    }

    /// Reads the live preference across both trackpad domains. A gesture
    /// enabled in either domain counts as enabled.
    static func current() -> Set<Int> {
        var three: Int?
        var four: Int?
        for domain in domains {
            guard let defaults = UserDefaults(suiteName: domain) else { continue }
            if let value = defaults.object(forKey: threeFingerKey) as? Int {
                three = max(three ?? 0, value)
            }
            if let value = defaults.object(forKey: fourFingerKey) as? Int {
                four = max(four ?? 0, value)
            }
        }
        return resolve(threeFinger: three, fourFinger: four)
    }
}

/// Turns a stream of raw trackpad contact frames into a single "the user has
/// committed to leaving this Space" signal.
///
/// This is the globally-observable counterpart to the responder-chain path in
/// `FourFingerSwipeObserving`: same threshold math, but fed by
/// `MultitouchDevice` so it works while another app is frontmost. It fires
/// once per gesture, as the swipe crosses the threshold — well before
/// `NSWorkspace.activeSpaceDidChangeNotification`, which only lands after
/// macOS has finished animating the Space change.
struct SpacesSwipeDetector {
    /// Finger counts that count as a Spaces swipe. Empty disables detection,
    /// which is correct when the user has turned the system gesture off.
    var acceptedFingerCounts: Set<Int>

    private var startX: CGFloat?
    private var triggered = false

    init(acceptedFingerCounts: Set<Int> = [3, 4]) {
        self.acceptedFingerCounts = acceptedFingerCounts
    }

    /// Feed one contact frame. Returns `true` exactly once per gesture, on the
    /// frame where horizontal displacement crosses the threshold.
    mutating func consume(touchingX: [CGFloat]) -> Bool {
        guard acceptedFingerCounts.contains(touchingX.count) else {
            // Finger count left the accepted set — either the gesture ended or
            // it was never a Spaces swipe. Either way, start over.
            reset()
            return false
        }

        let currentX = touchingX.reduce(CGFloat.zero, +) / CGFloat(touchingX.count)

        guard let startX else {
            self.startX = currentX
            return false
        }

        guard !triggered else { return false }
        guard FourFingerSwipeGesture.direction(startX: startX, currentX: currentX) != nil else {
            return false
        }

        triggered = true
        return true
    }

    mutating func reset() {
        startX = nil
        triggered = false
    }
}
