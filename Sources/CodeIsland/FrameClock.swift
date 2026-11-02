import Observation
import SwiftUI

/// Redraws `content` once every `interval` seconds, and only then: the clock
/// behind the island's continuous motion (the mascots, the shimmer on a running
/// tool's name).
///
/// TimelineView and repeating animations can't be asked for that. A
/// `repeatForever` animation updates on every display frame, and so does a
/// TimelineView whose entries are less than about a quarter second apart,
/// whatever its schedule says. Inside the panel each of those updates laid the
/// whole island out again — the session cards, the header, the footer — 120
/// times a second on a ProMotion screen (#381).
///
/// Every clock runs off one timer (FrameTicker), so a tick is one wakeup and
/// one update of the island for everything due at it, however many mascots
/// and labels are moving. `interval` is rounded to a whole number of 20 fps
/// steps for that. `content` gets the time as seconds since the reference date.
struct FrameClock<Content: View>: View {
    let interval: TimeInterval
    let content: (TimeInterval) -> Content

    init(interval: TimeInterval, @ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.interval = FrameTicker.steps(for: interval) * FrameTicker.step
        self.content = content
    }

    var body: some View {
        FrameClockFace(beat: FrameTicker.shared.beat(every: interval), content: content)
    }
}

private struct FrameClockFace<Content: View>: View {
    let beat: FrameBeat
    let content: (TimeInterval) -> Content

    var body: some View {
        content(beat.now)
            // The ticker runs while some clock is on screen, and stops with the
            // last one: a still island schedules nothing.
            .task {
                beat.attach()
                defer { beat.detach() }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
            }
    }
}

/// The time of the latest tick, for the clocks of one interval.
@MainActor
@Observable
final class FrameBeat {
    let steps: Int
    fileprivate(set) var now = Date.timeIntervalSinceReferenceDate
    @ObservationIgnored fileprivate var clocks = 0

    fileprivate init(steps: Int) {
        self.steps = steps
    }

    fileprivate func attach() {
        clocks += 1
        FrameTicker.shared.start()
    }

    fileprivate func detach() {
        clocks -= 1
    }
}

/// The single timer behind every FrameClock: 20 ticks a second, on a grid of
/// the reference date, while any clock is on screen.
@MainActor
final class FrameTicker {
    static let shared = FrameTicker()
    /// The grid every interval is rounded to: 20 fps.
    nonisolated static let step: TimeInterval = 0.05

    private var beats: [Int: FrameBeat] = [:]
    private var task: Task<Void, Never>?

    nonisolated static func steps(for interval: TimeInterval) -> Double {
        max(1, (interval / step).rounded())
    }

    /// Whether the ticker is running; it stops once no clock is attached.
    var isRunning: Bool { task != nil }

    func beat(every interval: TimeInterval) -> FrameBeat {
        let steps = Int(Self.steps(for: interval))
        if let beat = beats[steps] { return beat }
        let beat = FrameBeat(steps: steps)
        beats[steps] = beat
        return beat
    }

    fileprivate func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while let self, self.beats.values.contains(where: { $0.clocks > 0 }), !Task.isCancelled {
                let wait = Self.step - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.step)
                try? await Task.sleep(for: .seconds(wait))
                self.tick()
            }
            self?.task = nil
        }
    }

    private func tick() {
        let now = Date.timeIntervalSinceReferenceDate
        let tick = Int((now / Self.step).rounded())
        for beat in beats.values where beat.clocks > 0 && tick % beat.steps == 0 {
            beat.now = now
        }
    }
}
