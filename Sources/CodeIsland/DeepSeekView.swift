import SwiftUI

/// DeepSeek — DeepSeek Harness mascot: the DeepSeek brand whale (#4D6BFE),
/// pixel-drawn in-house on the same unit grid as the other mascots (no external
/// asset, so the app bundle stays self-contained). The whale bobs gently while
/// idle, spouts water while a turn runs, and raises an alert dot when DSH waits
/// for an approval or a question.
struct DeepSeekView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27

    private static let bodyC  = Color(red: 0.302, green: 0.420, blue: 0.996) // #4D6BFE DeepSeek blue
    private static let darkC  = Color(red: 0.145, green: 0.235, blue: 0.780) // fin / tail shade
    private static let bellyC = Color(red: 0.898, green: 0.933, blue: 1.000) // pale belly
    private static let eyeC   = Color(red: 0.043, green: 0.067, blue: 0.141)
    private static let sprayC = Color(red: 0.604, green: 0.831, blue: 1.000)
    private static let alertC = Color(red: 1.000, green: 0.420, blue: 0.260)

    var body: some View {
        ZStack {
            switch status {
            case .idle:                 sleepScene
            case .processing, .running: workScene
            case .waitingApproval, .waitingQuestion: alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    // ── Coordinate helper: unit grid (16 × 12) → view points ──
    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat

        init(_ sz: CGSize, svgW: CGFloat = 15, svgH: CGFloat = 9, svgY0: CGFloat = 3.0) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    private func block(_ c: GraphicsContext, _ v: V,
                       _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                       _ color: Color, dy: CGFloat = 0) {
        c.fill(Path(v.r(x, y, w, h, dy: dy)), with: .color(color))
    }

    /// The whale itself. `dy` bobs the whole animal; `eyeH` squashes the eye for
    /// blinks; `finDy` flaps the pectoral fin.
    private func drawWhale(_ c: GraphicsContext, _ v: V, dy: CGFloat,
                           eyeH: CGFloat = 1, finDy: CGFloat = 0,
                           eyeColor: Color = Self.eyeC) {
        // Tail (left): stem + two horizontal flukes, the classic whale silhouette.
        block(c, v, 2.2, 6.4, 2.4, 2.0, Self.bodyC, dy: dy)
        block(c, v, 0.6, 4.6, 2.0, 1.2, Self.darkC, dy: dy)
        block(c, v, 1.4, 5.6, 1.3, 1.0, Self.darkC, dy: dy)
        block(c, v, 0.6, 8.6, 2.0, 1.2, Self.darkC, dy: dy)
        block(c, v, 1.4, 7.6, 1.3, 1.0, Self.darkC, dy: dy)

        // Main body: back hump, barrel, chin, all in DeepSeek blue.
        block(c, v, 4.4, 4.2, 8.4, 1.1, Self.bodyC, dy: dy)
        block(c, v, 3.6, 5.2, 10.2, 4.2, Self.bodyC, dy: dy)
        block(c, v, 4.2, 9.2, 8.2, 0.9, Self.bodyC, dy: dy)

        // Belly, pectoral fin, dorsal ridge.
        block(c, v, 4.8, 8.7, 7.6, 0.9, Self.bellyC, dy: dy)
        block(c, v, 6.2, 7.4, 2.6, 2.0, Self.darkC, dy: dy + finDy)
        block(c, v, 8.4, 3.6, 2.6, 0.7, Self.darkC, dy: dy)

        // Eye (with a glint), mouth, and a soft highlight on the head.
        block(c, v, 12.1, 6.2, 1.15, max(0.22, eyeH), eyeColor, dy: dy)
        block(c, v, 12.4, 6.45, 0.4, 0.4, Color.white.opacity(0.85), dy: dy)
        block(c, v, 12.6, 8.1, 1.7, 0.4, Self.eyeC, dy: dy)
        block(c, v, 10.2, 5.5, 2.4, 0.35, Color.white.opacity(0.15), dy: dy)
    }

    /// Rising water spout above the blowhole. Pure function of `t`.
    private func drawSpout(_ c: GraphicsContext, _ v: V, t: Double, intensity: Double, dy: CGFloat) {
        guard intensity > 0 else { return }
        block(c, v, 9.0, 3.2, 1.2, 0.5, Self.sprayC.opacity(0.85 * intensity), dy: dy)
        for i in 0..<4 {
            var phase = (t * (1.0 / 1.2) - Double(i) * 0.22).truncatingRemainder(dividingBy: 1.0)
            if phase < 0 { phase += 1 }
            let x = 9.0 + CGFloat(sin(phase * .pi * 2 + Double(i))) * 0.55
            let y = 2.9 - CGFloat(phase) * 2.6
            let sz: CGFloat = i == 0 ? 0.9 : 0.7
            c.fill(Path(v.r(x, y, sz, sz, dy: dy)),
                   with: .color(Self.sprayC.opacity((1 - phase) * 0.9 * intensity)))
        }
    }

    // ── SLEEP / idle: slow bob, half-closed eyes, occasional sleepy bubble ──
    private var sleepScene: some View {
        MascotTimeline(interval: 0.12) { t in
            Canvas { c, sz in
                let v = V(sz)
                let bob = CGFloat(sin(t * 2 * .pi / 3.2)) * 0.28
                drawWhale(c, v, dy: bob, eyeH: 0.30, finDy: 0.15)

                let bubble = MascotMotion.quirk(t, cycle: 6.5, duration: 1.4, seed: 0xD5EE)
                if bubble > 0 {
                    let p = CGFloat(bubble)
                    c.fill(Path(ellipseIn: v.r(12.5, 3.8 - p * 2.4, 0.55 + p * 0.55, 0.55 + p * 0.55)),
                           with: .color(Self.sprayC.opacity(0.75 * (1 - Double(p)))))
                }
            }
        }
    }

    // ── WORK: faster bob, flapping fin, continuous spout, natural blinks ──
    private var workScene: some View {
        MascotTimeline(interval: 0.08) { t in
            Canvas { c, sz in
                let v = V(sz)
                let bob = CGFloat(sin(t * 2 * .pi / 1.2)) * 0.45
                let fin = CGFloat(sin(t * 2 * .pi / 0.6)) * 0.5
                let open = MascotMotion.blink(t, seed: 0xD5E2)
                drawWhale(c, v, dy: bob, eyeH: 0.25 + open * 0.85, finDy: fin)
                drawSpout(c, v, t: t, intensity: 1.0, dy: bob)
            }
        }
    }

    // ── ALERT: whale holds still, wide eye, blinking amber dot ──
    private var alertScene: some View {
        MascotTimeline(interval: 0.12) { t in
            Canvas { c, sz in
                let v = V(sz)
                let wiggle = CGFloat(sin(t * 2 * .pi / 0.6)) * 0.16
                drawWhale(c, v, dy: wiggle, eyeH: 1.15, finDy: 0.4)

                let on = t.truncatingRemainder(dividingBy: 1.1) < 0.7
                if on {
                    c.fill(Path(ellipseIn: v.r(12.0, 2.2, 2.0, 2.0)),
                           with: .color(Self.alertC))
                    block(c, v, 12.75, 2.55, 0.5, 0.85, .white)
                    block(c, v, 12.75, 3.65, 0.5, 0.35, .white)
                }
            }
        }
    }
}
