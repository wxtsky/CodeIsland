import AppKit
import SwiftUI

/// Central gate that decides whether the pixel mascots should keep driving
/// their per-frame `TimelineView` redraws.
///
/// Two things pin a CPU core when this is left unchecked (issue #225):
///  1. The notch panel is hidden / occluded but the mascot Canvas keeps
///     redrawing at ~20fps forever (worst with zero sessions, where the idle
///     mascot animates indefinitely).
///  2. After display sleep/wake the `TimelineView(.periodic(from: .now, by:))`
///     schedules are still anchored to their original reference date, so
///     SwiftUI tries to "catch up" every missed tick in a burst.
///
/// The gate solves both: `animationsActive` is false while the panel is hidden
/// or the machine is asleep (views render a static frame instead of looping),
/// and `epoch` is bumped on wake so the periodic schedules — keyed on the epoch
/// via `.id()` — get torn down and re-anchored to the *new* current time rather
/// than replaying the gap.
@MainActor
final class MascotAnimationGate: ObservableObject {
    static let shared = MascotAnimationGate()

    /// Bumped whenever the system wakes so periodic schedules re-anchor to "now".
    @Published private(set) var epoch: Int = 0

    /// True while the panel window is on-screen / not occluded.
    @Published private(set) var isPanelVisible: Bool = true

    /// True while the display/system is awake.
    @Published private(set) var isAwake: Bool = true

    /// True when the island is collapsed and every session is idle — i.e. the
    /// mascot is asleep in a ~20pt strip and nothing is happening.
    @Published private(set) var isIdleSettled: Bool = false

    /// System Settings › Accessibility › Display › Reduce motion. Read in
    /// `start()`, so a test process (which never starts the gate) keeps
    /// animating whatever the machine running it is set to.
    @Published private(set) var reduceMotion: Bool = false

    /// Whether mascot per-frame animations should run right now.
    var animationsActive: Bool {
        Self.shouldAnimate(isVisible: isPanelVisible, isAwake: isAwake, isIdleSettled: isIdleSettled,
                           reduceMotion: reduceMotion)
    }

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Pure decision used by `animationsActive` and unit tests. Animations only
    /// run while the panel is visible *and* the machine is awake — there is no
    /// point burning frames behind a hidden panel or during sleep.
    ///
    /// The third condition is the expensive one. A live `TimelineView` does not
    /// merely run its own schedule: it keeps SwiftUI's update machinery on a
    /// display link, and every cycle re-runs the whole panel's layout pass. That
    /// measured at ~7.6% CPU forever on an idle Mac, against ~2% with no live
    /// timeline — and *slowing* the schedule barely helped (4 fps still cost
    /// ~6.2%), because the cost is per display cycle, not per mascot frame.
    /// So when the island is collapsed and nothing is running, the mascot holds
    /// a static sleeping frame instead. Any state change — a session waking, the
    /// panel expanding on hover — re-enables it immediately. (#299)
    ///
    /// With Reduce Motion on, the mascots hold their status pose instead of
    /// looping forever next to whatever the user is reading.
    static func shouldAnimate(isVisible: Bool, isAwake: Bool, isIdleSettled: Bool = false,
                              reduceMotion: Bool = false) -> Bool {
        isVisible && isAwake && !isIdleSettled && !reduceMotion
    }

    /// Begin observing system sleep/wake and the Reduce Motion setting. Idempotent.
    func start() {
        guard observers.isEmpty else { return }
        let wsCenter = NSWorkspace.shared.notificationCenter

        let sleepNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
        ]
        let wakeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]

        for name in sleepNames {
            observers.append(wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setAwake(false) }
            })
        }
        for name in wakeNames {
            observers.append(wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setAwake(true) }
            })
        }

        setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        observers.append(wsCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) }
        })
    }

    /// Follow the Reduce Motion setting. Turning it off re-anchors the
    /// schedules like any other resume.
    func setReduceMotion(_ reduce: Bool) {
        guard reduceMotion != reduce else { return }
        reduceMotion = reduce
        if !reduce { epoch &+= 1 }
    }

    /// Report the panel's current on-screen visibility (called from the
    /// window controller whenever it orders the panel in or out).
    func setPanelVisible(_ visible: Bool) {
        guard isPanelVisible != visible else { return }
        isPanelVisible = visible
        // Coming back on-screen behaves like a wake for the render layer:
        // re-anchor so we don't replay frames accumulated while hidden.
        if visible { epoch &+= 1 }
    }

    /// Report whether the island is collapsed with nothing running. Coming back
    /// out of that state re-anchors the schedules, exactly like a wake.
    func setIdleSettled(_ settled: Bool) {
        guard isIdleSettled != settled else { return }
        isIdleSettled = settled
        if !settled { epoch &+= 1 }
    }

    private func setAwake(_ awake: Bool) {
        guard isAwake != awake else { return }
        isAwake = awake
        // On wake, bump the epoch so schedules anchored to the old reference
        // date are discarded instead of catching up every missed periodic tick.
        if awake { epoch &+= 1 }
    }

    deinit {
        let wsCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            wsCenter.removeObserver(observer)
        }
    }
}

// MARK: - Environment plumbing

private struct MascotAnimationsActiveKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

private struct MascotAnimationEpochKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    /// Whether the mascot's per-frame redraw loops should run.
    var mascotAnimationsActive: Bool {
        get { self[MascotAnimationsActiveKey.self] }
        set { self[MascotAnimationsActiveKey.self] = newValue }
    }

    /// Identity bumped on wake / re-show so periodic schedules re-anchor.
    var mascotAnimationEpoch: Int {
        get { self[MascotAnimationEpochKey.self] }
        set { self[MascotAnimationEpochKey.self] = newValue }
    }
}
