import SwiftUI
import UniIslandCore

/// WeChatView — Premium 8-bit pixel-art WeChat double-bubble mascot.
/// Renders two cute overlapping speech bubbles (one WeChat Green, one Light-Gray)
/// with animated blinking eyes, breathing idle states, typing dots, and startled jumps.
struct WeChatView: View {
    let status: AgentStatus
    var size: CGFloat = 27
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // Brand Colors
    private static let greenLt  = Color(red: 0.20, green: 0.82, blue: 0.20) // #33D133
    private static let greenC   = Color(red: 0.10, green: 0.68, blue: 0.10) // #1AAD1A (WeChat Green)
    private static let greenDk  = Color(red: 0.05, green: 0.50, blue: 0.05) // #0D800D
    private static let whiteLt  = Color(red: 0.98, green: 0.98, blue: 0.98) // #FAFAFA
    private static let whiteC   = Color(red: 0.92, green: 0.92, blue: 0.92) // #ECECEC (WeChat Light Gray)
    private static let whiteDk  = Color(red: 0.78, green: 0.78, blue: 0.78) // #C7C7C7
    private static let eyeC     = Color.black
    private static let alertC   = Color(red: 1.0, green: 0.24, blue: 0.0)

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
        let ox: CGFloat, oy: CGFloat, s: CGFloat, y0: CGFloat
        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 14, svgY0: CGFloat = 4) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
        func path(_ points: [(CGFloat, CGFloat)], dy: CGFloat = 0) -> Path {
            var p = Path()
            guard let first = points.first else { return p }
            p.move(to: CGPoint(x: ox + first.0 * s, y: oy + (first.1 - y0 + dy) * s))
            for i in 1..<points.count {
                p.addLine(to: CGPoint(x: ox + points[i].0 * s, y: oy + (points[i].1 - y0 + dy) * s))
            }
            p.closeSubpath()
            return p
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

    // ── Draw WeChat Speach Bubbles ──
    private func drawBubbles(_ c: GraphicsContext, v: V, dy: CGFloat, scale: CGFloat = 1.0, typingPhase: Int = 0) {
        // --- 1. Draw Large Green Bubble (Left-Center) ---
        let bgW: CGFloat = 9.0 * scale
        let bgH: CGFloat = 7.0 * scale
        let bgX: CGFloat = 1.5
        let bgY: CGFloat = 6.0
        
        let bgRect = v.r(bgX, bgY, bgW, bgH, dy: dy)
        let bgPath = Path(roundedRect: bgRect, cornerRadius: 2.0 * v.s * scale)
        c.fill(bgPath, with: .linearGradient(
            Gradient(colors: [Self.greenLt, Self.greenC, Self.greenDk]),
            startPoint: CGPoint(x: bgRect.midX, y: bgRect.minY),
            endPoint: CGPoint(x: bgRect.midX, y: bgRect.maxY)))
            
        // Green tail (points down-left)
        let tailGPoints: [(CGFloat, CGFloat)] = [
            (bgX + 1.5, bgY + bgH - 0.5),
            (bgX + 0.5, bgY + bgH + 1.5),
            (bgX + 3.0, bgY + bgH - 0.5)
        ]
        c.fill(v.path(tailGPoints, dy: dy), with: .color(Self.greenDk))

        // --- 2. Draw Small White/Gray Bubble (Right-Bottom, overlapping) ---
        let bwW: CGFloat = 7.0 * scale
        let bwH: CGFloat = 5.5 * scale
        let bwX: CGFloat = 7.5
        let bwY: CGFloat = 8.5
        
        let bwRect = v.r(bwX, bwY, bwW, bwH, dy: dy)
        let bwPath = Path(roundedRect: bwRect, cornerRadius: 1.8 * v.s * scale)
        c.fill(bwPath, with: .linearGradient(
            Gradient(colors: [Self.whiteLt, Self.whiteC, Self.whiteDk]),
            startPoint: CGPoint(x: bwRect.midX, y: bwRect.minY),
            endPoint: CGPoint(x: bwRect.midX, y: bwRect.maxY)))
            
        // White/Gray tail (points down-right)
        let tailWPoints: [(CGFloat, CGFloat)] = [
            (bwX + bwW - 3.0, bwY + bwH - 0.5),
            (bwX + bwW - 0.5, bwY + bwH + 1.0),
            (bwX + bwW - 1.5, bwY + bwH - 0.5)
        ]
        c.fill(v.path(tailWPoints, dy: dy), with: .color(Self.whiteDk))
    }

    // ── Draw Dot Eyes inside the bubbles ──
    private func drawFace(_ c: GraphicsContext, v: V, dy: CGFloat, blinkPhase: CGFloat = 1.0, typingPhase: Int = 0) {
        // Eyes in Green Bubble
        let eyeH1: CGFloat = 1.2 * blinkPhase
        let eyeY1: CGFloat = 8.0 + (1.2 - eyeH1) / 2
        c.fill(Path(v.r(3.8, eyeY1, 1.0, max(0.2, eyeH1), dy: dy)), with: .color(Self.eyeC))
        c.fill(Path(v.r(7.2, eyeY1, 1.0, max(0.2, eyeH1), dy: dy)), with: .color(Self.eyeC))

        // Eyes in White/Gray Bubble
        let eyeH2: CGFloat = 0.9 * blinkPhase
        let eyeY2: CGFloat = 10.2 + (0.9 - eyeH2) / 2
        c.fill(Path(v.r(9.2, eyeY2, 0.8, max(0.2, eyeH2), dy: dy)), with: .color(Self.eyeC))
        c.fill(Path(v.r(12.0, eyeY2, 0.8, max(0.2, eyeH2), dy: dy)), with: .color(Self.eyeC))

        // --- Premium: Flash typing dots inside bubbles during processing/work scene ---
        if typingPhase > 0 {
            let dotSize: CGFloat = 0.5
            let dotY: CGFloat = 7.0
            
            // Draw 3 typing dots inside the green bubble (flash them in sequence)
            for i in 0..<3 {
                let dotX = 4.3 + CGFloat(i) * 1.5
                let opacity = (typingPhase == i + 1) ? 1.0 : 0.3
                c.fill(Path(v.r(dotX, dotY, dotSize, dotSize, dy: dy)), with: .color(Self.eyeC.opacity(opacity)))
            }
        }
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 11, opacity: Double = 0.25) {
        c.fill(Path(v.r(8.0 - width / 2, 15.5, width, 1.0)),
               with: .color(.black.opacity(opacity)))
    }

    // ━━━━━━ SLEEP (Idle State) ━━━━━━
    private var sleepScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                sleepCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                floatingZs(t: ctx.date.timeIntervalSinceReferenceDate * speed)
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
                let baseOp = 0.65 - ci * 0.1
                let opacity = phase < 0.8 ? baseOp : (1.0 - phase) * 3.5 * baseOp
                let xOff = size * CGFloat(0.16 + ci * 0.08 + sin(phase * .pi * 2) * 0.03)
                let yOff = -size * CGFloat(0.12 + phase * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.0) / 4.0
        let float = sin(phase * .pi * 2) * 0.6
        let blinkCycle = t.truncatingRemainder(dividingBy: 5.0)
        let blink: CGFloat = (blinkCycle > 4.6 && blinkCycle < 4.8) ? 0.1 : 1.0

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            drawShadow(c, v: v, width: 10 + float * 0.3, opacity: 0.18)
            drawBubbles(c, v: v, dy: float, scale: 0.95)
            drawFace(c, v: v, dy: float, blinkPhase: blink)
        }
    }

    // ━━━━━━ WORK (Processing / Active State) ━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
            workCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.4) * 0.8
        let blinkCycle = t.truncatingRemainder(dividingBy: 3.0)
        let blink: CGFloat = (blinkCycle > 2.7 && blinkCycle < 2.85) ? 0.15 : 1.0
        
        // Staggered typing dots sequence (1 -> 2 -> 3 -> idle -> 1)
        let typingPhase = Int(t / 0.22) % 4

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            let dy = bounce

            let shadowW: CGFloat = 11 - abs(dy) * 0.3
            c.fill(Path(v.r(8.0 - shadowW / 2, 15.5, shadowW, 1.0)),
                   with: .color(.black.opacity(max(0.1, 0.30 - abs(dy) * 0.03))))

            drawBubbles(c, v: v, dy: dy, scale: 1.0)
            drawFace(c, v: v, dy: dy, blinkPhase: blink, typingPhase: typingPhase + 1)
        }
    }

    // ━━━━━━ ALERT (Notification / Action Required State) ━━━━━━
    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.alertC.opacity(alive ? 0.12 : 0))
                .frame(width: size * 0.82)
                .blur(radius: size * 0.04)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)

            TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
                alertCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -0.8), (0.15, 1.2),
            (0.175, -7.5), (0.20, -7.5), (0.25, 1.2),
            (0.275, -5.5), (0.30, -5.5), (0.35, 0.8),
            (0.375, -3.5), (0.40, -3.5), (0.45, 0.6),
            (0.475, -1.8), (0.50, -1.8), (0.55, 0.2),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 90) * 0.5 : 0
        let pulseScale: CGFloat = (pct > 0.03 && pct < 0.55)
            ? 1.0 + sin(pct * 25) * 0.12 : 1.0

        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)

            let shadowW: CGFloat = 10 * (1.0 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(8.0 - shadowW / 2, 15.5, shadowW, 1.0)),
                   with: .color(.black.opacity(max(0.08, 0.35 - abs(min(0, jumpY)) * 0.04))))

            c.translateBy(x: shakeX * v.s, y: 0)
            drawBubbles(c, v: v, dy: jumpY, scale: pulseScale)
            drawFace(c, v: v, dy: jumpY, blinkPhase: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
            c.translateBy(x: -shakeX * v.s, y: 0)

            // ! mark
            if bangOp > 0.01 {
                let bw: CGFloat = 1.6 * bangScale
                let bx: CGFloat = 13.5
                let by: CGFloat = 3.5 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.2 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 3.8 * bangScale, bw, 1.2 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}
