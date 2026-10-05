import SwiftUI

/// MiniMax mascot — a chunky pixel robot built around MiniMax's "M" mark:
/// the two stems of the M rise above the chassis as ears, and the mark
/// itself glows on the robot's dark face-screen. White body, warm accent,
/// antenna light — same pixel language as the Kiro/Pi robots.
struct MinimaxView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27

    private static let bodyC = Color(red: 0.96, green: 0.96, blue: 0.97)
    private static let bodyShade = Color(red: 0.72, green: 0.72, blue: 0.75)
    private static let screenC = Color(red: 0.10, green: 0.11, blue: 0.16)
    private static let accentC = Color(red: 1.0, green: 0.45, blue: 0.36)
    private static let dimC = Color(red: 0.42, green: 0.43, blue: 0.48)

    @State private var alive = false

    var body: some View {
        Group {
            switch status {
            case .idle:                 sleepScene
            case .processing, .running: workScene
            case .waitingApproval, .waitingQuestion: alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .accessibilityLabel("MiniMax Code CLI")
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat, y0: CGFloat
        init(_ sz: CGSize, svgW: CGFloat = 14, svgH: CGFloat = 14, svgY0: CGFloat = 0) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    /// The pixel "M" on the face-screen. `color` swaps for the alert flash,
    /// `hop` makes the mark bounce like it is typing.
    private func drawM(_ c: GraphicsContext, v: V, dy: CGFloat, color: Color, hop: CGFloat = 0) {
        let m = dy + hop
        c.fill(Path(v.r(4.2, 5.4, 1.2, 3.2, dy: m)), with: .color(color))
        c.fill(Path(v.r(8.6, 5.4, 1.2, 3.2, dy: m)), with: .color(color))
        // The V of the M: stepped diagonal from the stem tops to the center.
        c.fill(Path(v.r(5.4, 5.4, 1.0, 1.0, dy: m)), with: .color(color))
        c.fill(Path(v.r(7.6, 5.4, 1.0, 1.0, dy: m)), with: .color(color))
        c.fill(Path(v.r(6.0, 6.4, 1.0, 1.0, dy: m)), with: .color(color))
        c.fill(Path(v.r(7.0, 6.4, 1.0, 1.0, dy: m)), with: .color(color))
        c.fill(Path(v.r(6.5, 7.4, 1.0, 1.2, dy: m)), with: .color(color))
    }

    private func drawRobot(
        _ c: GraphicsContext, v: V, dy: CGFloat,
        mColor: Color, mOpacity: Double, hop: CGFloat = 0,
        tipOn: Bool
    ) {
        // Ground shadow
        c.fill(Path(v.r(4.2, 12.9, 5.6, 0.8)), with: .color(.black.opacity(0.25)))

        // Antenna: dim stem, tip lights up while working / flashes on alert.
        c.fill(Path(v.r(6.7, 1.6, 0.6, 1.6, dy: dy)), with: .color(Self.dimC))
        c.fill(
            Path(v.r(6.1, 0.4, 1.8, 1.2, dy: dy)),
            with: .color(tipOn ? Self.accentC : Self.dimC.opacity(0.5))
        )

        // The M's two stems rising above the chassis — the mark becomes ears.
        c.fill(Path(v.r(2, 1.4, 1.8, 2.6, dy: dy)), with: .color(Self.bodyC))
        c.fill(Path(v.r(10.2, 1.4, 1.8, 2.6, dy: dy)), with: .color(Self.bodyC))

        // Chassis + side shade for volume
        c.fill(Path(v.r(2, 3.4, 10, 7.4, dy: dy)), with: .color(Self.bodyC))
        c.fill(Path(v.r(10.6, 4.4, 1.4, 5.6, dy: dy)), with: .color(Self.bodyShade.opacity(0.6)))

        // Face-screen with the M mark
        c.fill(Path(v.r(3.4, 4.6, 7.2, 4.8, dy: dy)), with: .color(Self.screenC))
        drawM(c, v: v, dy: dy, color: mColor.opacity(mOpacity), hop: hop)

        // Feet
        c.fill(Path(v.r(3.6, 10.8, 1.9, 1.1, dy: dy)), with: .color(Self.bodyShade))
        c.fill(Path(v.r(8.5, 10.8, 1.9, 1.1, dy: dy)), with: .color(Self.bodyShade))
    }

    // ── SLEEP: slow breathing bob, screen dimmed, rare flicker, Z's ──
    private var sleepScene: some View {
        ZStack {
            MascotTimeline(interval: 0.12) { t in
                let bob = sin(t * 2 * .pi / 4.8) * 0.5 + sin(t * 2 * .pi / 7.3) * 0.25
                let flicker = MascotMotion.quirk(t, cycle: 9.0, duration: 0.8, seed: 0x6D12)
                return Canvas { c, sz in
                    let v = V(sz)
                    drawRobot(
                        c, v: v, dy: bob,
                        mColor: .white, mOpacity: 0.3 + flicker * 0.5,
                        tipOn: false
                    )
                }
            }
            MascotTimeline(interval: 0.12) { t in
                ForEach(0..<2, id: \.self) { i in
                    let ci = Double(i)
                    let cycle = 3.4 + ci * 0.5
                    let p = max(0, ((t - ci * 1.4).truncatingRemainder(dividingBy: cycle)) / cycle)
                    let fontSize: CGFloat = max(6, size * CGFloat(0.15 + p * 0.08))
                    let opacity: Double = p < 0.8 ? 0.55 - ci * 0.15 : (1 - p) * 3 * 0.55
                    Text("z")
                        .font(.system(size: fontSize, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(opacity))
                        .offset(x: size * CGFloat(0.16 + ci * 0.06), y: -size * CGFloat(0.12 + p * 0.3))
                }
            }
        }
    }

    // ── WORK: focused bob, the M types in little hops, antenna blinking ──
    private var workScene: some View {
        MascotTimeline(interval: 0.05) { t in
            let pause = MascotMotion.quirk(t, cycle: 10.5, duration: 1.1, seed: 0x6D13)
            let intensity = 1.0 - pause
            let bob = sin(t * 2 * .pi / 0.5) * 0.6 * intensity
                + sin(t * 2 * .pi / 3.1) * 0.25 * pause
            // The M taps out a rhythm — a small hop per beat, settling on pause.
            let beat = floor(t / 0.28)
            let hopPhase = (t / 0.28) - beat
            let hop = -sin(hopPhase * .pi) * 0.35 * intensity
            let blink = MascotMotion.blink(t, seed: 0x6D14)
            return Canvas { c, sz in
                let v = V(sz)
                drawRobot(
                    c, v: v, dy: bob,
                    mColor: Self.accentC,
                    mOpacity: 0.8 + blink * 0.2,
                    hop: hop,
                    tipOn: Int(t / 0.4) % 2 == 0
                )
            }
        }
    }

    // ── ALERT: startle rise, glow ring, the M flashes white↔accent ──
    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.accentC.opacity(alive ? 0.14 : 0))
                .frame(width: size * 0.8)
                .blur(radius: size * 0.05)

            MascotTimeline(interval: 0.05) { t in
                let cycle = t.truncatingRemainder(dividingBy: 3.4)
                let pct = CGFloat(cycle / 3.4)
                let rise: CGFloat
                if pct < 0.14 {
                    rise = -MascotMotion.easeOutBack(pct / 0.14) * 2.2
                } else if pct < 0.3 {
                    rise = -1.6 - sin((pct - 0.14) / 0.16 * .pi) * 0.5
                } else {
                    rise = -1.2
                }
                let flash = Int(t / 0.22) % 2 == 0
                return Canvas { c, sz in
                    let v = V(sz)
                    drawRobot(
                        c, v: v, dy: rise,
                        mColor: flash ? .white : Self.accentC,
                        mOpacity: 1,
                        tipOn: Int(t / 0.22) % 2 == 0
                    )
                }
            }
        }
    }
}
