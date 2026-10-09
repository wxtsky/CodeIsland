import SwiftUI

/// MiMoBot — MiMo Code / Xiaomi MiMo mascot: a little charcoal tile whose face
/// is the 2×2 "M I M O" glyph grid of the MiMo app icon (notched block, square,
/// notched block, circle). Drawn in-house from that motif rather than copying
/// the icon; Xiaomi orange marks activity and alerts.
struct MiMoView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    @State private var alive = false

    private static let bodyC   = Color(red: 0.13, green: 0.13, blue: 0.145)  // #212125 tile
    private static let rimC    = Color(red: 0.36, green: 0.36, blue: 0.39)   // #5C5C63 — keeps the tile visible on the black notch
    private static let glyphC  = Color(red: 0.96, green: 0.96, blue: 0.97)
    private static let accentC = Color(red: 1.0, green: 0.41, blue: 0.0)     // #FF6900 Xiaomi orange
    private static let legC    = Color(red: 0.30, green: 0.30, blue: 0.33)
    private static let kbBase  = Color(red: 0.10, green: 0.10, blue: 0.115)
    private static let kbKey   = Color(red: 0.23, green: 0.23, blue: 0.25)

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

    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat
        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 12, svgY0: CGFloat = 4) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
        func p(_ x: CGFloat, _ y: CGFloat, dy: CGFloat = 0) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + (y - y0 + dy) * s)
        }
    }

    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i - 1].0) / (keyframes[i].0 - keyframes[i - 1].0)
                return keyframes[i - 1].1 + (keyframes[i].1 - keyframes[i - 1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }

    // ── Tile body ──
    private func drawTile(_ c: GraphicsContext, v: V, dy: CGFloat,
                          squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let w: CGFloat = 9 * squashX
        let h: CGFloat = 8.6 * squashY
        let x: CGFloat = 8 - w / 2
        let y: CGFloat = 13.1 - h   // feet stay planted while squashing
        let tile = Path(roundedRect: v.r(x, y, w, h, dy: dy), cornerRadius: 1.8 * v.s)
        c.fill(tile, with: .color(Self.bodyC))
        c.stroke(tile, with: .color(Self.rimC), lineWidth: max(0.5, 0.45 * v.s))
        // Soft top sheen, like the icon's glassy edge.
        c.fill(Path(roundedRect: v.r(x + 1.2, y + 0.5, w - 2.4, 0.5, dy: dy), cornerRadius: 0.25 * v.s),
               with: .color(.white.opacity(0.10)))
    }

    /// Cell `index` of the 2×2 grid, clockwise from top-left (M, I, O, M).
    /// `topScale` squashes the top row (the "eyes") for blinks and sleep.
    private func drawGlyphs(_ c: GraphicsContext, v: V, dy: CGFloat,
                            topScale: CGFloat = 1, opacity: Double = 1,
                            highlight: Int? = nil, tint: Color? = nil, circleScale: CGFloat = 1,
                            squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let cell: CGFloat = 2.6
        let gap: CGFloat = 1.0
        let gridW = (cell * 2 + gap) * squashX
        let left = 8 - gridW / 2
        let tileTop = 13.1 - 8.6 * squashY
        let top = tileTop + 1.2 * squashY
        let cw = cell * squashX
        let ch = cell * squashY

        func color(_ index: Int) -> Color {
            if let tint { return tint.opacity(opacity) }
            if index == highlight { return Self.accentC }
            return Self.glyphC.opacity(opacity)
        }

        // Top row: eyes. Squash around each cell's vertical centre.
        let eyeH = max(0.3, ch * topScale)
        let eyeY = top + (ch - eyeH) / 2
        // 0 — notched "M"
        notchedBlock(c, v: v, x: left, y: eyeY, w: cw, h: eyeH, dy: dy, color: color(0))
        // 1 — square "I"
        c.fill(Path(roundedRect: v.r(left + cw + gap * squashX, eyeY, cw, eyeH, dy: dy),
                    cornerRadius: 0.35 * v.s), with: .color(color(1)))

        // Bottom row
        let rowY = top + ch + gap * squashY
        // 2 — circle "O" (bottom-right)
        let d = cell * circleScale
        let cx = left + cw + gap * squashX + cw / 2
        let cy = rowY + ch / 2
        c.fill(Path(ellipseIn: v.r(cx - d * squashX / 2, cy - d * squashY / 2, d * squashX, d * squashY, dy: dy)),
               with: .color(color(2)))
        // 3 — notched "M" (bottom-left)
        notchedBlock(c, v: v, x: left, y: rowY, w: cw, h: ch, dy: dy, color: color(3))
    }

    /// A block with a V cut from the top edge down to its middle — the "M".
    private func notchedBlock(_ c: GraphicsContext, v: V, x: CGFloat, y: CGFloat,
                              w: CGFloat, h: CGFloat, dy: CGFloat, color: Color) {
        var path = Path()
        path.move(to: v.p(x, y, dy: dy))
        path.addLine(to: v.p(x + w / 2, y + h * 0.5, dy: dy))
        path.addLine(to: v.p(x + w, y, dy: dy))
        path.addLine(to: v.p(x + w, y + h, dy: dy))
        path.addLine(to: v.p(x, y + h, dy: dy))
        path.closeSubpath()
        c.fill(path, with: .color(color))
    }

    private func drawLegs(_ c: GraphicsContext, v: V, dy: CGFloat = 0) {
        let legDy = dy * 0.25
        c.fill(Path(v.r(5.2, 13.3, 1.1, 1.6, dy: legDy)), with: .color(Self.legC))
        c.fill(Path(v.r(9.7, 13.3, 1.1, 1.6, dy: legDy)), with: .color(Self.legC))
    }

    private func drawShadow(_ c: GraphicsContext, v: V, y: CGFloat, width: CGFloat, opacity: Double) {
        c.fill(Path(v.r(8 - width / 2, y, width, 1)), with: .color(.black.opacity(opacity)))
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

    private func sleepCanvas(t: Double) -> some View {
        // Own drift rhythm so a row of sleeping mascots never bobs in sync (#15).
        let float = sin(t * 2 * .pi / 4.21) * 0.62 + sin(t * 2 * .pi / 6.53) * 0.34
        // The "O" breathes while the eyes stay shut.
        let breath = MascotMotion.breathe(t, period: 4.8)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, y: 15, width: 7 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v, dy: float)
            drawTile(c, v: v, dy: float, squashX: 0.97, squashY: 0.97)
            drawGlyphs(c, v: v, dy: float, topScale: 0.18, opacity: 0.45,
                       circleScale: 0.82 + breath * 0.14, squashX: 0.97, squashY: 0.97)
        }
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.7 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                let baseOp = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOp : (1.0 - phase) * 3.5 * baseOp
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: size * CGFloat(0.16 + ci * 0.08),
                            y: -size * CGFloat(0.16 + phase * 0.38))
            }
        }
    }

    // ━━━━━━ WORK ━━━━━━
    private var workScene: some View {
        MascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Every ~12s the bounce settles for a beat — reading, not typing (#15).
        let workPause = MascotMotion.quirk(t, cycle: 11.7, duration: 1.2, seed: 0x31F0)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * (1 - workPause)
            + sin(t * 2 * .pi / 2.9) * 0.3 * workPause
        let blink = max(0.1, MascotMotion.blink(t, seed: 0x31F1))
        let keyPhase = Int(t / 0.1) % 6
        // The orange runs round the grid, M → I → O → M, once per 1.2s.
        let lit = Int(t / 0.3) % 4

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
            drawShadow(c, v: v, y: 16, width: 8 - abs(bounce) * 0.3,
                       opacity: max(0.1, 0.35 - abs(bounce) * 0.03))

            // Keyboard
            c.fill(Path(v.r(0.5, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    c.fill(Path(v.r(1 + CGFloat(col) * 2.4, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            c.fill(Path(v.r(1 + CGFloat(keyPhase % 6) * 2.4, 13.5 + CGFloat(keyPhase / 3) * 1.2, 1.8, 0.7)),
                   with: .color(Self.accentC.opacity(0.9)))

            drawTile(c, v: v, dy: bounce)
            drawGlyphs(c, v: v, dy: bounce, topScale: blink, highlight: lit)
        }
    }

    // ━━━━━━ ALERT ━━━━━━
    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.accentC.opacity(alive ? 0.14 : 0))
                .frame(width: size * 0.8)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)

            MascotTimeline(interval: 0.03) { t in
                alertCanvas(t: t)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let pct = CGFloat(t.truncatingRemainder(dividingBy: 3.5) / 3.5)

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -6.5), (0.20, -6.5), (0.25, 1.4),
            (0.275, -5), (0.30, -5), (0.35, 1.0),
            (0.375, -3.2), (0.40, -3.2), (0.45, 0.7),
            (0.475, -1.6), (0.50, -1.6), (0.55, 0.3),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        let bangOp = lerp([(0, 0), (0.03, 1), (0.55, 1), (0.62, 0), (1, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1, 0.6)], at: pct)
        // Wide-eyed on the first hop, glyphs flash orange while the "!" shows.
        let wide = pct > 0.03 && pct < 0.15
        let tint: Color? = bangOp > 0.4 ? Self.accentC : nil

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
            drawShadow(c, v: v, y: 16, width: 8 * (1.0 - abs(min(0, jumpY)) * 0.04),
                       opacity: max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))
            drawLegs(c, v: v, dy: jumpY)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawTile(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawGlyphs(c, v: v, dy: jumpY, topScale: wide ? 1.15 : 1.0, tint: tint,
                       squashX: squashX, squashY: squashY)
            c.translateBy(x: -shakeX * v.s, y: 0)

            if bangOp > 0.01 {
                let bw: CGFloat = 1.8 * bangScale
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(13.4, by, bw, 3.4 * bangScale)), with: .color(Self.accentC.opacity(bangOp)))
                c.fill(Path(v.r(13.4, by + 3.9 * bangScale, bw, 1.4 * bangScale)),
                       with: .color(Self.accentC.opacity(bangOp)))
            }
        }
    }
}
