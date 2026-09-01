import AppKit
import os.log

private let log = Logger(subsystem: "com.codeisland", category: "SpacesSwipe")

/// Watches for the user starting a Spaces swipe and reports the moment the
/// gesture becomes deliberate, so an expanded island can shrink while the
/// desktop is still moving rather than snapping shut once it has arrived.
///
/// Detection only runs while armed — that is, while there is something
/// expanded worth collapsing — so an idle island does no per-frame work.
@MainActor
final class SpacesSwipeMonitor {
    private let stateLock = NSLock()
    nonisolated(unsafe) private var detector = SpacesSwipeDetector()
    nonisolated(unsafe) private var armed = false

    private var onThresholdCrossed: (() -> Void)?
    private var started = false

    /// False when MultitouchSupport could not be resolved, which is the signal
    /// for callers to lean on their coarser Space-change fallback instead.
    var isAvailable: Bool { MultitouchDevice.shared.isAvailable }

    func start(onThresholdCrossed: @escaping () -> Void) {
        guard !started else { return }
        started = true
        self.onThresholdCrossed = onThresholdCrossed
        refreshFingerCounts()
        MultitouchDevice.shared.start { [weak self] contacts in
            self?.handleFrame(contacts)
        }
        log.notice(
            "Spaces swipe detection started — multitouch available: \(self.isAvailable, privacy: .public), finger counts: \(SpacesSwipeFingerCounts.current().sorted().description, privacy: .public)"
        )
    }

    func stop() {
        guard started else { return }
        started = false
        onThresholdCrossed = nil
        setArmed(false)
        MultitouchDevice.shared.stop()
    }

    /// Arm only while an expanded surface is on screen. Disarming also clears
    /// any partial gesture so the next swipe starts from a clean baseline.
    func setArmed(_ isArmed: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard armed != isArmed else { return }
        armed = isArmed
        detector.reset()
    }

    /// Re-reads the system trackpad gesture preference. Cheap enough to call
    /// whenever settings change; the user can flip this in System Settings
    /// while the app is running.
    func refreshFingerCounts() {
        let counts = SpacesSwipeFingerCounts.current()
        stateLock.lock()
        detector.acceptedFingerCounts = counts
        detector.reset()
        stateLock.unlock()
    }

    /// Runs on MultitouchSupport's thread at trackpad frame rate. Everything
    /// here is bounded arithmetic under a lock; the only main-actor hop is the
    /// single threshold crossing, at most once per gesture.
    private nonisolated func handleFrame(_ contacts: [MultitouchDevice.Contact]) {
        stateLock.lock()
        guard armed else {
            stateLock.unlock()
            return
        }
        let touchingX = contacts.filter(\.isTouching).map(\.normalizedX)
        let crossed = detector.consume(touchingX: touchingX)
        stateLock.unlock()

        guard crossed else { return }
        Task { @MainActor [weak self] in
            self?.onThresholdCrossed?()
        }
    }
}
