import SwiftUI

/// AiWorkBot — shared mascot for AiWork GUI and CLI (formerly DTCoder).
///
/// Built to the same spec as the other CodeIsland mascots (Clawd / CursorBot /
/// OpBot): a little creature whose "body" is the brand mark, with eyes, legs, a
/// ground shadow, and three animated scenes — sleep (breathing + floating z's),
/// work (typing at a keyboard, bouncing, blinking) and alert (startle jump +
/// `!` + pulsing glow). All motion is a pure function of the MascotTimeline
/// instant via MascotMotion, so frames re-render statelessly.
///
/// The mark itself is the official AiWork / AiWork icon: two interlocking rounded
/// panels — a lime→teal green panel (the face) nested with a cyan→blue panel
/// (lower-right), separated by a dark stepped seam.
struct AiWorkView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    @State private var alive = false
    @Environment(\.mascotAnimationsActive) private var animationsActive
    @Environment(\.mascotAnimationEpoch) private var animationEpoch

    // ── Official AiWork mark palette ──
    private static let greenLt = Color(red: 0.44, green: 0.85, blue: 0.30) // lime
    private static let greenDk = Color(red: 0.13, green: 0.66, blue: 0.40) // teal-green
    private static let cyanLt  = Color(red: 0.32, green: 0.82, blue: 0.99) // light cyan
    private static let cyanDk  = Color(red: 0.12, green: 0.52, blue: 0.97) // deep blue
    private static let seamC   = Color(red: 0.04, green: 0.05, blue: 0.08) // interlock gap
    private static let eyeC    = Color.white
    private static let alertC  = Color(red: 1.0, green: 0.42, blue: 0.12)  // warm attention
    private static let kbBase  = Color(red: 0.10, green: 0.12, blue: 0.16)
    private static let kbKey   = Color(red: 0.24, green: 0.28, blue: 0.34)
    private static let kbHi    = Color.white

    // ── Mark geometry (SVG-ish units shared across scenes) ──
    private static let panelW: CGFloat = 6.0
    private static let panelH: CGFloat = 6.0
    private static let corner: CGFloat = 1.45
    private static let greenX: CGFloat = 3.2
    private static let greenY: CGFloat = 5.0
    private static let cyanX:  CGFloat = 5.9   // green offset by +2.7 both axes
    private static let cyanY:  CGFloat = 7.7
    private static let centerX: CGFloat = 7.55 // union centre — squash pivot
    private static let centerY: CGFloat = 9.35
    // Eyes sit on the green panel's top band (clear of the interlock seam).
    private static let eyeLX: CGFloat = 4.35
    private static let eyeRX: CGFloat = 6.85
    private static let eyeW:  CGFloat = 1.2
    private static let eyeY:  CGFloat = 5.75
    private static let eyeH:  CGFloat = 1.15

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
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    // ── Coordinate helper: maps SVG units to view points ──
    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat
        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 14, svgY0: CGFloat = 3) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i-1].0) / (keyframes[i].0 - keyframes[i-1].0)
                return keyframes[i-1].1 + (keyframes[i].1 - keyframes[i-1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }

    private func rr(_ rect: CGRect, r: CGFloat) -> Path {
        Path(roundedRect: rect, cornerRadius: max(0, min(r, min(rect.width, rect.height) / 2)))
    }

    private func grad(_ rect: CGRect, _ a: Color, _ b: Color) -> GraphicsContext.Shading {
        .linearGradient(
            Gradient(colors: [a, b]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY),
            endPoint: CGPoint(x: rect.maxX, y: rect.maxY)
        )
    }

    // ── Draw the interlocking two-panel AiWork mark (the body/face) ──
    private func drawMark(_ c: GraphicsContext, v: V, dy: CGFloat,
                          sqx: CGFloat = 1, sqy: CGFloat = 1,
                          seam: CGFloat = 0.55,
                          eyeScale: CGFloat = 1.0,
                          eyeColor: Color = Self.eyeC,
                          caret: CGFloat = 0) {
        // Scope squash/stretch to the mark by drawing it into a transformed copy.
        var g = c
        if sqx != 1 || sqy != 1 {
            let px = v.ox + Self.centerX * v.s
            let py = v.oy + (Self.centerY - v.y0 + dy) * v.s
            g.translateBy(x: px, y: py)
            g.scaleBy(x: sqx, y: sqy)
            g.translateBy(x: -px, y: -py)
        }

        // Green panel (upper-left) — the face.
        let greenRect = v.r(Self.greenX, Self.greenY, Self.panelW, Self.panelH, dy: dy)
        g.fill(rr(greenRect, r: Self.corner * v.s), with: grad(greenRect, Self.greenLt, Self.greenDk))
        let gHi = v.r(Self.greenX + 0.85, Self.greenY + 0.5, Self.panelW - 1.7, 0.7, dy: dy)
        g.fill(rr(gHi, r: 0.35 * v.s), with: .color(.white.opacity(0.22)))

        // Dark interlock gap: carves green's lower-right and rings cyan's
        // upper-left, reproducing the icon's stepped seam without any clipping.
        let gapRect = v.r(Self.cyanX - seam, Self.cyanY - seam,
                          Self.panelW + 2 * seam, Self.panelH + 2 * seam, dy: dy)
        g.fill(rr(gapRect, r: (Self.corner + seam) * v.s), with: .color(Self.seamC))

        // Cyan panel (lower-right).
        let cyanRect = v.r(Self.cyanX, Self.cyanY, Self.panelW, Self.panelH, dy: dy)
        g.fill(rr(cyanRect, r: Self.corner * v.s), with: grad(cyanRect, Self.cyanLt, Self.cyanDk))
        let cHi = v.r(Self.cyanX + 0.85, Self.cyanY + 0.5, Self.panelW - 1.7, 0.6, dy: dy)
        g.fill(rr(cHi, r: 0.3 * v.s), with: .color(.white.opacity(0.16)))

        // Typing caret inside the cyan panel — a nod to the coding agent.
        if caret > 0.01 {
            let cr = v.r(Self.cyanX + Self.panelW * 0.5 - 0.28, Self.cyanY + 1.0, 0.55, 1.7, dy: dy)
            g.fill(rr(cr, r: 0.2 * v.s), with: .color(.white.opacity(0.85 * caret)))
        }

        // Eyes on the green face.
        let eh = Self.eyeH * eyeScale
        let ey = Self.eyeY + (Self.eyeH - eh) / 2
        g.fill(rr(v.r(Self.eyeLX, ey, Self.eyeW, max(0.28, eh), dy: dy), r: 0.55 * v.s),
               with: .color(eyeColor))
        g.fill(rr(v.r(Self.eyeRX, ey, Self.eyeW, max(0.28, eh), dy: dy), r: 0.55 * v.s),
               with: .color(eyeColor))
    }

    private func drawShadow(_ c: GraphicsContext, v: V, y: CGFloat,
                            width: CGFloat, opacity: Double) {
        c.fill(rr(v.r(Self.centerX - width / 2, y, width, 1.0), r: 0.5 * v.s),
               with: .color(.black.opacity(opacity)))
    }

    private func drawLegs(_ c: GraphicsContext, v: V, dy: CGFloat = 0) {
        let d = dy * 0.35
        // Left leg under the green column, right leg under the lower cyan panel —
        // the stepped stance echoes the interlocking mark.
        c.fill(rr(v.r(Self.greenX + 0.7, Self.greenY + Self.panelH - 0.2, 1.15, 1.7, dy: d), r: 0.4 * v.s),
               with: .color(Self.greenDk))
        c.fill(rr(v.r(Self.cyanX + Self.panelW - 1.85, Self.cyanY + Self.panelH - 0.2, 1.15, 1.7, dy: d), r: 0.4 * v.s),
               with: .color(Self.cyanDk))
    }

    // ━━━━━━ SLEEP ━━━━━━
    private var sleepScene: some View {
        ZStack {
            MascotTimeline(interval: 0.12) { t in
                sleepCanvas(t: t)
            }
            MascotTimeline(interval: 0.12) { t in
                floatingZs(t: t)
            }
        }
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.8 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                let baseOp = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOp : (1.0 - phase) * 3.5 * baseOp
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: size * CGFloat(0.15 + ci * 0.08),
                            y: -size * CGFloat(0.15 + phase * 0.38))
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Two incommensurate drift periods — the float never quite repeats, and
        // AiWorkBot's rhythm differs from its neighbours so rows don't sync (#15).
        let float = sin(t * 2 * .pi / 4.12) * 0.55 + sin(t * 2 * .pi / 6.53) * 0.28
        let breathe = MascotMotion.breathe(t, period: 4.6)

        return Canvas { c, sz in
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, y: 15.2, width: 7 + abs(float) * 0.3, opacity: 0.2 + Double(breathe) * 0.05)
            drawLegs(c, v: v, dy: float)
            drawMark(c, v: v, dy: float,
                     sqy: 1 - breathe * 0.03,
                     seam: 0.5,
                     eyeScale: 0.16,
                     eyeColor: Self.eyeC.opacity(0.5))
        }
    }

    // ━━━━━━ WORK ━━━━━━
    private var workScene: some View {
        MascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Work pause: every ~11s the bounce settles for a beat — reading output,
        // not hammering keys nonstop (#15).
        let workPause = MascotMotion.quirk(t, cycle: 10.7, duration: 1.2, seed: 0xD7C1)
        let bounce = sin(t * 2 * .pi / 0.4) * 0.9 * (1 - workPause)
            + sin(t * 2 * .pi / 2.8) * 0.28 * workPause
        let blink = max(0.12, MascotMotion.blink(t, seed: 0xD7C2))
        let seam = 0.48 + 0.12 * (0.5 + 0.5 * sin(t * 2 * .pi / 1.7))
        let caret = max(0.0, sin(t * 2 * .pi / 0.9))
        let land = max(0, bounce)
        let keyPhase = Int(t / 0.1) % 6

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            drawShadow(c, v: v, y: 16.0, width: 9 - abs(bounce) * 0.3,
                       opacity: max(0.1, 0.32 - Double(abs(bounce)) * 0.03))

            drawLegs(c, v: v, dy: bounce)

            // Keyboard
            c.fill(Path(v.r(0.5, 13, 14, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 1.0 + CGFloat(col) * 2.3
                    c.fill(Path(v.r(kx, ky, 1.7, 0.7)), with: .color(Self.kbKey))
                }
            }
            let fCol = keyPhase % 6
            let fRow = keyPhase / 3
            c.fill(Path(v.r(1.0 + CGFloat(fCol) * 2.3, 13.5 + CGFloat(fRow) * 1.2, 1.7, 0.7)),
                   with: .color(Self.kbHi.opacity(0.9)))

            drawMark(c, v: v, dy: bounce,
                     sqx: 1 + land * 0.02, sqy: 1 - land * 0.02,
                     seam: seam,
                     eyeScale: blink,
                     caret: caret)
        }
    }

    // ━━━━━━ ALERT ━━━━━━
    private var alertScene: some View {
        // Gate the pulsing glow on the animation state so the repeatForever
        // CAAnimation can't pin a core across display wake (#225).
        let glowActive = alive && animationsActive
        return ZStack {
            Circle()
                .fill(Self.alertC.opacity(glowActive ? 0.14 : 0))
                .frame(width: size * 0.82)
                .blur(radius: size * 0.05)
                .animation(
                    animationsActive
                        ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                        : .default,
                    value: glowActive
                )
                .id(animationEpoch)

            MascotTimeline(interval: 0.03) { t in
                alertCanvas(t: t)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -8), (0.20, -8), (0.25, 1.5),
            (0.275, -6), (0.30, -6), (0.35, 1.0),
            (0.375, -4), (0.40, -4), (0.45, 0.8),
            (0.475, -2), (0.50, -2), (0.55, 0.3),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        // Panels pop apart on the startle; eyes widen then flash warm.
        let seam = 0.55 + 0.5 * bangOp
        let sqx: CGFloat = jumpY > 0.5 ? 1 + jumpY * 0.03 : 1
        let sqy: CGFloat = jumpY > 0.5 ? 1 - jumpY * 0.025 : 1
        let eyeScale: CGFloat = (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0
        let eyeColor: Color = (pct > 0.03 && pct < 0.55 && sin(pct * 25) > 0) ? Self.alertC : Self.eyeC

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            drawShadow(c, v: v, y: 16.0, width: 9 * (1.0 - abs(min(0, jumpY)) * 0.04),
                       opacity: max(0.08, 0.4 - Double(abs(min(0, jumpY))) * 0.04))

            drawLegs(c, v: v, dy: jumpY)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawMark(c, v: v, dy: jumpY, sqx: sqx, sqy: sqy,
                     seam: seam, eyeScale: eyeScale, eyeColor: eyeColor)
            c.translateBy(x: -shakeX * v.s, y: 0)

            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 12.9
                let by: CGFloat = 3.2 + jumpY * 0.15
                c.fill(rr(v.r(bx, by, bw, 3.2 * bangScale, dy: 0), r: 0.4 * v.s),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(rr(v.r(bx, by + 3.7 * bangScale, bw, 1.3 * bangScale, dy: 0), r: 0.4 * v.s),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}
