import SwiftUI

/// Shared frame driver for every pixel mascot (#225 → all mascots).
///
/// Ticks with the MascotAnimationGate plumbing that PixelCharacterView
/// pioneered, so ALL mascots — not just Clawd — stop their per-frame Canvas
/// redraws when the panel is hidden/occluded or the machine is asleep, and
/// re-anchor their schedules on wake instead of replaying every missed tick in
/// a catch-up burst. On the Mac the ticks come from FrameClock, the island's
/// one 20 fps clock: a TimelineView this fast updates on every display frame,
/// and laid the whole panel out each time (#381). The iOS companion keeps
/// `TimelineView(.periodic)`.
///
/// `content` receives the mascot-local time `t` (already scaled by the user's
/// animation-speed setting), exactly like the raw pattern it replaces:
///
///     MascotTimeline(interval: 0.05) { t in workCanvas(t: t) }
///
/// The effective interval is clamped to `minInterval` (20 fps): a menu-bar-
/// sized pixel sprite gains nothing perceivable above that, and the wasted
/// wakeups were a real contributor to "CodeIsland makes my Mac warm" (#14).
struct MascotTimeline<Content: View>: View {
    /// Floor for all mascot frame intervals — 20 fps.
    static var minInterval: TimeInterval { 0.05 }

    let interval: TimeInterval
    /// Time handed to `content` for the single static frame rendered while
    /// animations are gated off.
    var staticTime: Double = 0
    @ViewBuilder let content: (Double) -> Content

    @Environment(\.mascotSpeed) private var speed
    @Environment(\.mascotAnimationsActive) private var animationsActive
    @Environment(\.mascotAnimationEpoch) private var animationEpoch
    @Environment(\.mascotStaticTime) private var staticTimeOverride

    var body: some View {
        // Animation speed "Off" holds the mascot still: a clock would only
        // redraw the same frame.
        if animationsActive && speed > 0 {
            #if os(macOS)
            // Not TimelineView: see FrameClock.
            FrameClock(interval: max(interval, Self.minInterval)) { now in
                content(now * speed)
            }
            .id(animationEpoch)
            #else
            TimelineView(.periodic(from: .now, by: max(interval, Self.minInterval))) { ctx in
                content(ctx.date.timeIntervalSinceReferenceDate * speed)
            }
            .id(animationEpoch)
            #endif
        } else {
            content(staticTimeOverride ?? staticTime)
        }
    }
}

// MARK: - Sleep z

/// One of the z's floating up from a sleeping mascot, `fontSize` points tall.
/// It is laid out at `fullSize`, the largest it gets, and scaled down to
/// `fontSize` when drawn, so a frame only changes how it is drawn: a font size
/// or text colour changing every frame made SwiftUI resolve the text again and
/// lay the island out around it on every frame (#381).
struct MascotSleepZ: View {
    let fontSize: CGFloat
    let fullSize: CGFloat
    let color: Color
    let opacity: Double

    var body: some View {
        Text("z")
            .font(.system(size: fullSize, weight: .black, design: .monospaced))
            .foregroundStyle(color)
            .opacity(opacity)
            .scaleEffect(fontSize / fullSize)
    }
}

// MARK: - Alert glow

/// The soft glow behind a mascot that is waiting on you, pulsing once a
/// second. It runs on the mascot's clock like the rest of the mascot: as a
/// `repeatForever` animation it redrew on every display frame, and went on
/// pulsing with Reduce Motion on. The pulse is the circle's opacity, which a
/// frame can change without blurring the circle again — the blur was most of
/// a waiting mascot's cost. While animations are off it holds at full strength.
struct MascotAlertGlow: View {
    let color: Color
    /// Opacity at the top of the pulse.
    let peak: Double
    let size: CGFloat
    /// Diameter, as a fraction of the mascot's size.
    var scale: CGFloat = 0.8

    var body: some View {
        MascotTimeline(interval: 0.05) { t in
            Circle()
                .fill(color)
                .frame(width: size * scale)
                .blur(radius: size * 0.05)
                .opacity(peak * MascotMotion.glowPulse(t))
        }
    }
}

// MARK: - Static-frame override (render harness)

private struct MascotStaticTimeKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

extension EnvironmentValues {
    /// When set (and animations are gated off), MascotTimeline renders its
    /// single static frame at this timeline instant instead of `staticTime`.
    /// Used by the offscreen contact-sheet harness to inspect specific frames.
    var mascotStaticTime: Double? {
        get { self[MascotStaticTimeKey.self] }
        set { self[MascotStaticTimeKey.self] = newValue }
    }
}
