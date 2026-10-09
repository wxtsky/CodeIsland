import AppKit
import Combine

/// Quit asks once. The first press arms the panel's power button (it turns
/// into a red "QUIT?" pill); only a second press within `window` quits. The
/// arm lapses by itself after `window`, and as soon as the pointer leaves the
/// button or the button goes away (the panel collapses) — so a stray click on
/// the island can never close the app, and a confirmation can't be left
/// primed for a later, unrelated click. Clicking anything else means leaving
/// the button first, which already disarms it.
///
/// Driven from the main actor (the view, the main-queue timeout); the
/// class itself isn't isolated so a view can create it as a default.
final class QuitConfirmation: ObservableObject {
    /// How long the armed pill waits for the confirming press.
    static let window: TimeInterval = 3

    /// Cancels a scheduled timeout.
    typealias Cancel = () -> Void
    /// Runs `fire` on the main actor after a delay; returns its cancel.
    typealias Scheduler = (_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Cancel

    @Published private(set) var isArmed = false

    private let quit: () -> Void
    private let now: () -> Date
    private let schedule: Scheduler
    private var armedAt: Date?
    private var cancelTimeout: Cancel?

    /// - Parameters:
    ///   - quit: what the confirming press does — terminates the app unless a
    ///     test swaps it out.
    ///   - now: the clock the confirm window is measured on.
    ///   - schedule: runs the timeout that reverts the pill.
    init(
        quit: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        now: @escaping () -> Date = Date.init,
        schedule: @escaping Scheduler = QuitConfirmation.mainQueueScheduler
    ) {
        self.quit = quit
        self.now = now
        self.schedule = schedule
    }

    /// A press on the button: arms it, or quits when it is already armed and
    /// the window is still open. A press after the window (the timeout hadn't
    /// run yet) arms afresh instead of quitting. Returns true when it quit.
    @MainActor @discardableResult
    func press() -> Bool {
        if isArmed, let armedAt, now().timeIntervalSince(armedAt) <= Self.window {
            disarm()
            quit()
            return true
        }
        arm()
        return false
    }

    /// The pointer left the button, or the button went away: revert to the
    /// plain power button without quitting.
    @MainActor
    func cancel() {
        disarm()
    }

    @MainActor
    private func arm() {
        cancelTimeout?()
        armedAt = now()
        isArmed = true
        cancelTimeout = schedule(Self.window) { [weak self] in self?.disarm() }
    }

    @MainActor
    private func disarm() {
        cancelTimeout?()
        cancelTimeout = nil
        armedAt = nil
        if isArmed { isArmed = false }
    }

    static func mainQueueScheduler(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> Cancel {
        let item = DispatchWorkItem { MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
