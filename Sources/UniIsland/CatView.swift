import SwiftUI
import UniIslandCore

/// CatView — Extremely cute 8-bit pixel-art animated kitten mascot.
/// Features detailed orange tabby cat sprites for sleep (idle), play/work (active), and alert (waiting) states.
struct CatView: View {
    let status: AgentStatus
    var size: CGFloat = 27
    var isDraggingOver: Bool = false
    var isCoding: Bool = false
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // Tabby Kitten Palette
    private static let catOrange = Color(red: 0.95, green: 0.55, blue: 0.15) // Main Orange
    private static let catLight  = Color(red: 1.00, green: 0.78, blue: 0.45) // Cream Highlight
    private static let catDark   = Color(red: 0.78, green: 0.38, blue: 0.05) // Tabby Stripe / Shadow
    private static let earPink   = Color(red: 1.00, green: 0.70, blue: 0.70) // Pink Ear Inner / Nose
    private static let eyeC      = Color(red: 0.15, green: 0.10, blue: 0.05) // Dark Brown Eyes
    private static let toyC      = Color(red: 0.20, green: 0.75, blue: 1.00) // Blue yarn/toy ball

    var body: some View {
        ZStack {
            if isDraggingOver {
                dropsScene
            } else if isCoding {
                codingScene
            } else {
                switch status {
                case .idle:                 sleepScene
                case .processing, .running: workScene
                case .waitingApproval, .waitingQuestion: alertScene
                }
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
        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 16, svgY0: CGFloat = 2) {
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

    private func lerp(_ keyframes: [(NSDecimalNumber, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        let firstPct = CGFloat(first.0.doubleValue)
        if pct <= firstPct { return first.1 }
        for i in 1..<keyframes.count {
            let curPct = CGFloat(keyframes[i].0.doubleValue)
            if pct <= curPct {
                let prevPct = CGFloat(keyframes[i-1].0.doubleValue)
                let t = (pct - prevPct) / (curPct - prevPct)
                return keyframes[i-1].1 + (keyframes[i].1 - keyframes[i-1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
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
                let xOff = size * CGFloat(0.18 + ci * 0.08 + sin(phase * .pi * 2) * 0.03)
                let yOff = -size * CGFloat(0.12 + phase * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let breathe = max(0, sin(t * 2.0)) * 0.4 // dozing nod off
        
        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            let nodY = breathe
            
            // Shadow
            let shadowW: CGFloat = 10.0
            c.fill(Path(v.r(8 - shadowW / 2, 14.5, shadowW, 1)),
                   with: .color(.black.opacity(0.18)))
            
            // Sitting Cat Body
            let bodyW: CGFloat = 7.0
            let bodyH: CGFloat = 5.8
            let bodyX: CGFloat = 8.0 - bodyW / 2
            let bodyY: CGFloat = 14.5 - bodyH
            c.fill(Path(roundedRect: v.r(bodyX, bodyY, bodyW, bodyH), cornerRadius: 2.0 * v.s), with: .color(Self.catOrange))
            
            // Cream chest
            c.fill(Path(roundedRect: v.r(bodyX + 1.2, bodyY + 1.8, bodyW - 2.4, 3.5), cornerRadius: 1.0 * v.s), with: .color(Self.catLight))
            
            // Stripes on body sides
            c.fill(Path(v.r(bodyX, bodyY + 1.2, 0.8, 1.5)), with: .color(Self.catDark))
            c.fill(Path(v.r(bodyX + bodyW - 0.8, bodyY + 1.2, 0.8, 1.5)), with: .color(Self.catDark))
            
            // Resting paws
            c.fill(Path(ellipseIn: v.r(bodyX + 1.5, bodyY + 4.2, 1.2, 1.2)), with: .color(Self.catLight))
            c.fill(Path(ellipseIn: v.r(bodyX + bodyW - 2.7, bodyY + 4.2, 1.2, 1.2)), with: .color(Self.catLight))
            
            // Dozing Head (nods down slowly)
            let headW: CGFloat = 7.8
            let headH: CGFloat = 5.8
            let headX: CGFloat = 8.0 - headW / 2
            let headY: CGFloat = bodyY - headH + 1.5 + nodY
            c.fill(Path(roundedRect: v.r(headX, headY, headW, headH), cornerRadius: 2.4 * v.s), with: .color(Self.catOrange))
            
            // Cream muzzle/snout
            c.fill(Path(roundedRect: v.r(headX + 1.9, headY + 3.3, 4.0, 2.0), cornerRadius: 1.0 * v.s), with: .color(Self.catLight))
            
            // Ears
            let leftEar: [(CGFloat, CGFloat)] = [(headX + 0.5, headY + 1.5), (headX + 0.5, headY - 1.2), (headX + 3.0, headY + 0.8)]
            let rightEar: [(CGFloat, CGFloat)] = [(headX + 4.8, headY + 0.8), (headX + 7.3, headY - 1.2), (headX + 7.3, headY + 1.5)]
            c.fill(v.path(leftEar), with: .color(Self.catDark))
            c.fill(v.path(rightEar), with: .color(Self.catDark))
            
            // Inner Ears (Pink)
            c.fill(v.path([(headX + 0.8, headY + 1.0), (headX + 0.8, headY - 0.5), (headX + 2.5, headY + 0.8)]), with: .color(Self.earPink))
            c.fill(v.path([(headX + 5.3, headY + 0.8), (headX + 7.0, headY - 0.5), (headX + 7.0, headY + 1.0)]), with: .color(Self.earPink))
            
            // Whiskers (Left & Right)
            // Left whiskers
            var wl1 = Path()
            wl1.move(to: CGPoint(x: v.ox + (headX - 1.5) * v.s, y: v.oy + (headY + 3.6 - v.y0) * v.s))
            wl1.addLine(to: CGPoint(x: v.ox + (headX + 0.5) * v.s, y: v.oy + (headY + 3.6 - v.y0) * v.s))
            c.stroke(wl1, with: .color(Self.catDark), lineWidth: 0.8)

            var wl2 = Path()
            wl2.move(to: CGPoint(x: v.ox + (headX - 1.5) * v.s, y: v.oy + (headY + 4.3 - v.y0) * v.s))
            wl2.addLine(to: CGPoint(x: v.ox + (headX + 0.5) * v.s, y: v.oy + (headY + 4.0 - v.y0) * v.s))
            c.stroke(wl2, with: .color(Self.catDark), lineWidth: 0.8)

            // Right whiskers
            var wr1 = Path()
            wr1.move(to: CGPoint(x: v.ox + (headX + headW - 0.5) * v.s, y: v.oy + (headY + 3.6 - v.y0) * v.s))
            wr1.addLine(to: CGPoint(x: v.ox + (headX + headW + 1.5) * v.s, y: v.oy + (headY + 3.6 - v.y0) * v.s))
            c.stroke(wr1, with: .color(Self.catDark), lineWidth: 0.8)

            var wr2 = Path()
            wr2.move(to: CGPoint(x: v.ox + (headX + headW - 0.5) * v.s, y: v.oy + (headY + 4.0 - v.y0) * v.s))
            wr2.addLine(to: CGPoint(x: v.ox + (headX + headW + 1.5) * v.s, y: v.oy + (headY + 4.3 - v.y0) * v.s))
            c.stroke(wr2, with: .color(Self.catDark), lineWidth: 0.8)
            
            // Sleeping closed eyes
            c.fill(Path(v.r(headX + 1.5, headY + 2.5, 1.2, 0.6)), with: .color(Self.eyeC))
            c.fill(Path(v.r(headX + 5.1, headY + 2.5, 1.2, 0.6)), with: .color(Self.eyeC))
            
            // Pink nose
            c.fill(Path(v.r(headX + 3.5, headY + 3.2, 0.8, 0.6)), with: .color(Self.earPink))
            
            // Little w-shaped mouth
            c.stroke(v.path([(headX + 3.1, headY + 3.9), (headX + 3.5, headY + 4.2), (headX + 3.9, headY + 3.9), (headX + 4.3, headY + 4.2), (headX + 4.7, headY + 3.9)]), with: .color(Self.catDark), lineWidth: 0.8)
            
            // Curled tail wiggling slowly, with a cream-colored tip
            let tailWave = sin(t * 1.5) * 0.6
            let tailPoints: [(CGFloat, CGFloat)] = [
                (bodyX + bodyW - 1.0, bodyY + bodyH - 1.0),
                (bodyX + bodyW + 1.5, bodyY + bodyH - 2.0 + tailWave),
                (bodyX + bodyW + 1.0, bodyY + bodyH - 3.5 + tailWave),
                (bodyX + bodyW - 0.5, bodyY + bodyH - 3.0 + tailWave)
            ]
            c.fill(v.path(tailPoints), with: .color(Self.catOrange))
            c.fill(Path(ellipseIn: v.r(bodyX + bodyW + 0.6, bodyY + bodyH - 3.6 + tailWave, 1.2, 1.2)), with: .color(Self.catLight))
        }
    }

    // ━━━━━━ PLAY/WORK (Active State) ━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.04)) { ctx in
            workCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.45) * 0.8
        let tailWave = sin(t * 2 * .pi / 0.6) * 1.5
        let blinkCycle = t.truncatingRemainder(dividingBy: 4.5)
        let isBlinking = blinkCycle > 4.2 && blinkCycle < 4.4

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            let dy = bounce

            // Shadow
            let shadowW: CGFloat = 11 - abs(dy) * 0.2
            c.fill(Path(v.r(8 - shadowW / 2, 14.5, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.25 - abs(dy) * 0.03))))

            // Toy yarn ball (rolling/spinning at the bottom right)
            let toyRect = v.r(11.5, 11.5 + dy * 0.2, 3.5, 3.5)
            c.fill(Path(ellipseIn: toyRect), with: .color(Self.toyC))
            // Thread lines
            c.stroke(Path(v.r(11.5, 13.0 + dy * 0.2, 3.5, 0.5)), with: .color(.white.opacity(0.5)), lineWidth: 0.5)

            // Cat sitting/playing body
            let bodyRect = v.r(2.5, 8.5 + dy, 7.5, 6.0)
            c.fill(Path(roundedRect: bodyRect, cornerRadius: 2.0 * v.s), with: .color(Self.catOrange))

            // White chest
            c.fill(Path(roundedRect: v.r(4.0, 11.0 + dy, 4.5, 3.5), cornerRadius: 1.0 * v.s), with: .color(Self.catLight))

            // Stripes
            c.fill(Path(v.r(4.0, 9.0 + dy, 0.8, 2.0)), with: .color(Self.catDark))
            c.fill(Path(v.r(7.5, 9.0 + dy, 0.8, 2.0)), with: .color(Self.catDark))

            // Head (sitting high)
            let headX: CGFloat = 3.0
            let headY: CGFloat = 3.5 + dy
            let headRect = v.r(headX, headY, 6.5, 5.5)
            c.fill(Path(roundedRect: headRect, cornerRadius: 2.2 * v.s), with: .color(Self.catOrange))

            // Ears
            let leftEar: [(CGFloat, CGFloat)] = [(headX + 0.5, headY + 1.0), (headX + 0.5, headY - 1.2), (headX + 3.0, headY + 0.5)]
            let rightEar: [(CGFloat, CGFloat)] = [(headX + 3.5, headY + 0.5), (headX + 6.0, headY - 1.2), (headX + 6.0, headY + 1.0)]
            c.fill(v.path(leftEar), with: .color(Self.catDark))
            c.fill(v.path(rightEar), with: .color(Self.catDark))
            c.fill(v.path([(headX + 0.8, headY + 0.8), (headX + 0.8, headY - 0.5), (headX + 2.5, headY + 0.5)]), with: .color(Self.earPink))
            c.fill(v.path([(headX + 4.0, headY + 0.5), (headX + 5.7, headY - 0.5), (headX + 5.7, headY + 0.8)]), with: .color(Self.earPink))

            // Blinking eyes
            if isBlinking {
                c.fill(Path(v.r(headX + 1.3, headY + 2.7, 1.2, 0.3)), with: .color(Self.eyeC))
                c.fill(Path(v.r(headX + 4.0, headY + 2.7, 1.2, 0.3)), with: .color(Self.eyeC))
            } else {
                c.fill(Path(v.r(headX + 1.3, headY + 2.1, 1.2, 1.6)), with: .color(Self.eyeC))
                c.fill(Path(v.r(headX + 4.0, headY + 2.1, 1.2, 1.6)), with: .color(Self.eyeC))
                // Cute eye shine
                c.fill(Path(v.r(headX + 1.3, headY + 2.1, 0.6, 0.6)), with: .color(.white))
                c.fill(Path(v.r(headX + 4.0, headY + 2.1, 0.6, 0.6)), with: .color(.white))
            }

            // Nose
            c.fill(Path(v.r(headX + 3.0, headY + 3.2, 0.8, 0.6)), with: .color(Self.earPink))

            // Waving tail
            let tailPoints: [(CGFloat, CGFloat)] = [
                (2.5, 12.0 + dy),
                (1.0 + tailWave * 0.2, 10.0 + tailWave),
                (0.0 + tailWave * 0.3, 8.5 + tailWave * 1.2),
                (1.0 + tailWave * 0.2, 9.0 + tailWave)
            ]
            c.fill(v.path(tailPoints), with: .color(Self.catOrange))

            // Patting paw (reaches toward yarn ball)
            let pawReach = sin(t * 2 * .pi / 0.45) * 1.5
            let pawRect = v.r(8.5 + pawReach * 0.6, 11.5 + dy + abs(pawReach) * 0.3, 1.6, 1.6)
            c.fill(Path(ellipseIn: pawRect), with: .color(Self.catOrange))
        }
    }

    // ━━━━━━ ALERT (Notification State) ━━━━━━
    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.toyC.opacity(alive ? 0.12 : 0))
                .frame(width: size * 0.85)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)

            TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
                alertCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.2)
        let pct = cycle / 3.2

        let num0 = NSDecimalNumber(decimal: 0)
        let num03 = NSDecimalNumber(decimal: 0.03)
        let num10 = NSDecimalNumber(decimal: 0.10)
        let num15 = NSDecimalNumber(decimal: 0.15)
        let num175 = NSDecimalNumber(decimal: 0.175)
        let num20 = NSDecimalNumber(decimal: 0.20)
        let num25 = NSDecimalNumber(decimal: 0.25)
        let num275 = NSDecimalNumber(decimal: 0.275)
        let num30 = NSDecimalNumber(decimal: 0.30)
        let num35 = NSDecimalNumber(decimal: 0.35)
        let num375 = NSDecimalNumber(decimal: 0.375)
        let num40 = NSDecimalNumber(decimal: 0.40)
        let num45 = NSDecimalNumber(decimal: 0.45)
        let num475 = NSDecimalNumber(decimal: 0.475)
        let num50 = NSDecimalNumber(decimal: 0.50)
        let num55 = NSDecimalNumber(decimal: 0.55)
        let num62 = NSDecimalNumber(decimal: 0.62)
        let num1 = NSDecimalNumber(decimal: 1.0)

        let jumpY = lerp([
            (num0, 0), (num03, 0), (num10, -0.8), (num15, 1.2),
            (num175, -8.0), (num20, -8.0), (num25, 1.2),
            (num275, -6.0), (num30, -6.0), (num35, 0.8),
            (num375, -3.8), (num40, -3.8), (num45, 0.6),
            (num475, -2.0), (num50, -2.0), (num55, 0.2),
            (num62, 0), (num1, 0),
        ], at: pct)

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 90) * 0.6 : 0
        let scale: CGFloat = (pct > 0.03 && pct < 0.55) ? 1.0 + sin(pct * 25) * 0.15 : 1.0

        let bangOp = lerp([
            (num0, 0), (num03, 1), (num10, 1), (num55, 1), (num62, 0), (num1, 0),
        ], at: pct)
        let bangScale = lerp([
            (num0, 0.3), (num03, 1.3), (num10, 1.0), (num55, 1.0), (num62, 0.6), (num1, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)

            // Shadow
            let shadowW: CGFloat = 11 * (1.0 - abs(min(0, jumpY)) * 0.05)
            c.fill(Path(v.r(8 - shadowW / 2, 14.5, shadowW, 1)),
                   with: .color(.black.opacity(max(0.08, 0.30 - abs(min(0, jumpY)) * 0.04))))

            c.translateBy(x: shakeX * v.s, y: 0)

            // Startled cat body
            let bodyW = 8.5 * scale
            let bodyH = 5.5 * scale
            let bodyX = 8.0 - bodyW / 2
            let bodyY = 14.5 - bodyH + jumpY
            c.fill(Path(roundedRect: v.r(bodyX, bodyY, bodyW, bodyH), cornerRadius: 2.0 * v.s * scale), with: .color(Self.catOrange))

            // Stripes
            c.fill(Path(v.r(bodyX + 2, bodyY, 0.8, 2)), with: .color(Self.catDark))
            c.fill(Path(v.r(bodyX + 5, bodyY, 0.8, 2)), with: .color(Self.catDark))

            // Startled Head (jumping high)
            let headW = 7.0 * scale
            let headH = 6.0 * scale
            let headX = 8.0 - headW / 2
            let headY = bodyY - headH + 1.2
            c.fill(Path(roundedRect: v.r(headX, headY, headW, headH), cornerRadius: 2.2 * v.s * scale), with: .color(Self.catOrange))

            // Alert Ears standing straight up!
            let leftEar: [(CGFloat, CGFloat)] = [(headX + 0.5, headY + 1.5), (headX + 0.5, headY - 1.8), (headX + 3.2, headY + 0.8)]
            let rightEar: [(CGFloat, CGFloat)] = [(headX + 3.8, headY + 0.8), (headX + 6.5, headY - 1.8), (headX + 6.5, headY + 1.5)]
            c.fill(v.path(leftEar), with: .color(Self.catDark))
            c.fill(v.path(rightEar), with: .color(Self.catDark))
            c.fill(v.path([(headX + 0.8, headY + 1.0), (headX + 0.8, headY - 0.8), (headX + 2.8, headY + 0.8)]), with: .color(Self.earPink))
            c.fill(v.path([(headX + 4.2, headY + 0.8), (headX + 6.2, headY - 0.8), (headX + 6.2, headY + 1.0)]), with: .color(Self.earPink))

            // Wide open alert eyes!
            c.fill(Path(ellipseIn: v.r(headX + 1.2, headY + 2.0, 1.8, 1.8)), with: .color(Self.eyeC))
            c.fill(Path(ellipseIn: v.r(headX + 4.0, headY + 2.0, 1.8, 1.8)), with: .color(Self.eyeC))
            // Big white pupils
            c.fill(Path(ellipseIn: v.r(headX + 1.5, headY + 2.3, 0.8, 0.8)), with: .color(.white))
            c.fill(Path(ellipseIn: v.r(headX + 4.3, headY + 2.3, 0.8, 0.8)), with: .color(.white))

            // Nose
            c.fill(Path(v.r(headX + 3.1, headY + 3.5, 0.8, 0.6)), with: .color(Self.earPink))

            // Startled tail standing straight up!
            let tailPoints: [(CGFloat, CGFloat)] = [
                (bodyX + 1.0, bodyY + 2.0),
                (bodyX - 1.2, bodyY - 3.5),
                (bodyX - 0.2, bodyY - 4.5),
                (bodyX + 1.8, bodyY + 1.0)
            ]
            c.fill(v.path(tailPoints), with: .color(Self.catOrange))

            // Exclamation mark (!)
            if bangOp > 0.01 {
                let bw: CGFloat = 1.6 * bangScale
                let bx: CGFloat = 12.8
                let by: CGFloat = 2.5 + jumpY * 0.2
                c.fill(Path(v.r(bx, by, bw, 3.2 * bangScale)), with: .color(Self.toyC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 3.8 * bangScale, bw, 1.2 * bangScale)), with: .color(Self.toyC.opacity(bangOp)))
            }
        }
    }

    // ━━━━━━ DROPS (Dragging Over State) ━━━━━━
    private var dropsScene: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
            dropsCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func dropsCanvas(t: Double) -> some View {
        let bounce = sin(t * 6.0) * 0.4
        let tailWave = sin(t * 8.0) * 1.8
        
        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            let dy = bounce
            
            // Shadow
            let shadowW: CGFloat = 10.5 - abs(dy) * 0.2
            c.fill(Path(v.r(8 - shadowW / 2, 14.5, shadowW, 1)),
                   with: .color(.black.opacity(0.20 - abs(dy) * 0.02)))
            
            // Leaned back sitting body
            let bodyW: CGFloat = 8.0
            let bodyH: CGFloat = 5.5
            let bodyX: CGFloat = 8 - bodyW / 2
            let bodyY: CGFloat = 14.5 - bodyH + dy
            c.fill(Path(roundedRect: v.r(bodyX, bodyY, bodyW, bodyH), cornerRadius: 2.0 * v.s), with: .color(Self.catOrange))
            
            // Cream chest
            c.fill(Path(roundedRect: v.r(bodyX + 1.5, bodyY + 2.5, bodyW - 3.0, 3.0), cornerRadius: 1.0 * v.s), with: .color(Self.catLight))
            
            // Stripes on body
            c.fill(Path(v.r(bodyX + 1.0, bodyY + 1.0, 0.8, 1.8)), with: .color(Self.catDark))
            c.fill(Path(v.r(bodyX + 6.2, bodyY + 1.0, 0.8, 1.8)), with: .color(Self.catDark))
            
            // Head looking up
            let headW: CGFloat = 7.0
            let headH: CGFloat = 5.8
            let headX: CGFloat = 8 - headW / 2
            let headY: CGFloat = bodyY - headH + 1.5
            c.fill(Path(roundedRect: v.r(headX, headY, headW, headH), cornerRadius: 2.2 * v.s), with: .color(Self.catOrange))
            
            // Pointy ears looking alert
            let leftEar: [(CGFloat, CGFloat)] = [(headX + 0.5, headY + 1.5), (headX + 0.2, headY - 1.5), (headX + 3.0, headY + 0.8)]
            let rightEar: [(CGFloat, CGFloat)] = [(headX + 4.0, headY + 0.8), (headX + 6.8, headY - 1.5), (headX + 6.5, headY + 1.5)]
            c.fill(v.path(leftEar), with: .color(Self.catDark))
            c.fill(v.path(rightEar), with: .color(Self.catDark))
            
            // Pink inside ears
            c.fill(v.path([(headX + 0.8, headY + 1.1), (headX + 0.5, headY - 0.7), (headX + 2.6, headY + 0.8)]), with: .color(Self.earPink))
            c.fill(v.path([(headX + 4.4, headY + 0.8), (headX + 6.5, headY - 0.7), (headX + 6.2, headY + 1.1)]), with: .color(Self.earPink))
            
            // Wide open sparkly eyes looking up!
            let eyeY = headY + 1.5
            c.fill(Path(ellipseIn: v.r(headX + 1.2, eyeY, 1.8, 1.8)), with: .color(Self.eyeC))
            c.fill(Path(ellipseIn: v.r(headX + 4.0, eyeY, 1.8, 1.8)), with: .color(Self.eyeC))
            
            // Big white sparkles near the top-center of the eyes
            c.fill(Path(ellipseIn: v.r(headX + 1.5, eyeY + 0.2, 0.8, 0.8)), with: .color(.white))
            c.fill(Path(ellipseIn: v.r(headX + 4.3, eyeY + 0.2, 0.8, 0.8)), with: .color(.white))
            // Extra tiny sparkle
            c.fill(Path(ellipseIn: v.r(headX + 2.2, eyeY + 1.0, 0.4, 0.4)), with: .color(.white))
            c.fill(Path(ellipseIn: v.r(headX + 5.0, eyeY + 1.0, 0.4, 0.4)), with: .color(.white))
            
            // Pink nose
            c.fill(Path(v.r(headX + 3.1, headY + 3.2, 0.8, 0.6)), with: .color(Self.earPink))
            
            // Startled/happy open mouth
            c.fill(Path(ellipseIn: v.r(headX + 3.0, headY + 4.0, 1.0, 1.1)), with: .color(Self.earPink))
            
            // Waving excited tail
            let tailPoints: [(CGFloat, CGFloat)] = [
                (bodyX + 1.5, bodyY + 3.5),
                (bodyX - 1.5 + tailWave * 0.2, bodyY + 1.5 + tailWave),
                (bodyX - 2.5 + tailWave * 0.3, bodyY - 0.5 + tailWave * 1.2),
                (bodyX - 1.5 + tailWave * 0.2, bodyY + 0.2 + tailWave)
            ]
            c.fill(v.path(tailPoints), with: .color(Self.catOrange))
            
            // Open paws reaching UPwards to catch the file!
            let pawL_Y = headY + 3.0 + sin(t * 8.0) * 0.6
            let pawR_Y = headY + 3.0 + sin(t * 8.0 + .pi) * 0.6
            c.fill(Path(roundedRect: v.r(headX - 1.2, pawL_Y, 1.6, 2.2), cornerRadius: 0.8 * v.s), with: .color(Self.catOrange))
            c.fill(Path(roundedRect: v.r(headX + headW - 0.4, pawR_Y, 1.6, 2.2), cornerRadius: 0.8 * v.s), with: .color(Self.catOrange))
            
            // Cream paw pads on the raised paws
            c.fill(Path(ellipseIn: v.r(headX - 1.0, pawL_Y + 0.3, 1.2, 1.2)), with: .color(Self.catLight))
            c.fill(Path(ellipseIn: v.r(headX + headW - 0.2, pawR_Y + 0.3, 1.2, 1.2)), with: .color(Self.catLight))
        }
    }

    // ━━━━━━ CODING (Pomodoro Active State) ━━━━━━
    private var codingScene: some View {
        TimelineView(.periodic(from: .now, by: 0.04)) { ctx in
            codingCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func codingCanvas(t: Double) -> some View {
        let bounce = sin(t * 8.0) * 0.4
        let tailWave = sin(t * 4.0) * 1.0
        let dy = bounce
        
        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            
            // Shadow under cat and laptop
            let shadowW: CGFloat = 11.0
            c.fill(Path(v.r(8 - shadowW / 2, 14.5, shadowW, 1)),
                   with: .color(.black.opacity(0.18)))
            
            // Draw a cute glowing laptop on the left
            let screenGlow = Color(red: 0.20, green: 0.85, blue: 1.00)
            // Laptop screen (tilted / open)
            c.stroke(v.path([(2.0, 13.0 + dy), (1.5, 9.0 + dy)]), with: .color(Self.catDark), lineWidth: 1.5)
            // Glowing screen panel
            c.fill(v.path([(2.2, 12.8 + dy), (1.8, 9.2 + dy), (3.0, 9.5 + dy), (3.0, 12.8 + dy)]), with: .color(screenGlow.opacity(0.85)))
            
            // Laptop keyboard base
            c.fill(Path(v.r(2.0, 13.0 + dy, 4.0, 1.0)), with: .color(Self.catDark))
            // Key highlights
            c.fill(Path(v.r(2.5, 13.2 + dy, 2.5, 0.5)), with: .color(.white.opacity(0.4)))

            // Floating code particles (0 and 1 dots) rising from screen
            for i in 0..<3 {
                let pCycle = 3.0
                let pDelay = Double(i) * 1.0
                let pPhase = max(0, ((t + pDelay).truncatingRemainder(dividingBy: pCycle)) / pCycle)
                let px = 2.5 + CGFloat(sin(t * 2.0 + Double(i))) * 0.8
                let py = 8.5 - CGFloat(pPhase * 6.0) + dy
                let popacity = 1.0 - pPhase
                if popacity > 0.05 {
                    c.fill(Path(v.r(px, py, 0.8, 0.8)), with: .color(screenGlow.opacity(popacity)))
                }
            }

            // Cat sitting body (facing left towards laptop)
            let bodyX: CGFloat = 6.0
            let bodyY: CGFloat = 14.5 - 6.0 + dy
            let bodyW: CGFloat = 7.0
            let bodyH: CGFloat = 6.0
            c.fill(Path(roundedRect: v.r(bodyX, bodyY, bodyW, bodyH), cornerRadius: 2.0 * v.s), with: .color(Self.catOrange))
            
            // Cream chest
            c.fill(Path(roundedRect: v.r(bodyX, bodyY + 2.5, 2.5, 3.5), cornerRadius: 1.0 * v.s), with: .color(Self.catLight))
            
            // Stripes on back
            c.fill(Path(v.r(bodyX + 5.0, bodyY + 1.0, 0.8, 1.8)), with: .color(Self.catDark))
            c.fill(Path(v.r(bodyX + 6.0, bodyY + 2.0, 0.8, 1.8)), with: .color(Self.catDark))

            // Head (facing left)
            let headX: CGFloat = 5.0
            let headY: CGFloat = bodyY - 5.0 + 1.2
            c.fill(Path(roundedRect: v.r(headX, headY, 6.5, 5.0), cornerRadius: 2.2 * v.s), with: .color(Self.catOrange))

            // Pointy pink ears
            c.fill(v.path([(headX + 1.5, headY + 0.8), (headX + 2.5, headY - 1.2), (headX + 3.5, headY + 0.5)]), with: .color(Self.catDark))
            c.fill(v.path([(headX + 4.5, headY + 0.5), (headX + 5.5, headY - 1.2), (headX + 6.0, headY + 0.8)]), with: .color(Self.catDark))
            c.fill(v.path([(headX + 1.8, headY + 0.6), (headX + 2.5, headY - 0.6), (headX + 3.2, headY + 0.5)]), with: .color(Self.earPink))
            c.fill(v.path([(headX + 4.8, headY + 0.5), (headX + 5.5, headY - 0.6), (headX + 5.8, headY + 0.6)]), with: .color(Self.earPink))

            // Focused eye looking left
            c.fill(Path(v.r(headX + 1.0, headY + 2.0, 1.5, 1.5)), with: .color(Self.eyeC))
            c.fill(Path(v.r(headX + 1.0, headY + 2.0, 0.6, 0.6)), with: .color(.white)) // eye shine

            // Whiskers (left side, tiny thin lines)
            c.stroke(v.path([(headX + 0.5, headY + 3.2), (headX - 0.5, headY + 3.0)]), with: .color(Self.catDark), lineWidth: 0.5)
            c.stroke(v.path([(headX + 0.5, headY + 3.7), (headX - 0.5, headY + 3.9)]), with: .color(Self.catDark), lineWidth: 0.5)

            // Nose
            c.fill(Path(v.r(headX + 0.6, headY + 3.1, 0.5, 0.5)), with: .color(Self.earPink))

            // Typing Paws (moving rapidly left and right onto the keyboard!)
            let paw1X = 4.0 + CGFloat(sin(t * 15.0)) * 0.6
            let paw1Y = 12.2 + CGFloat(cos(t * 15.0)) * 0.4 + dy
            c.fill(Path(ellipseIn: v.r(paw1X, paw1Y, 1.2, 1.2)), with: .color(Self.catOrange))
            
            let paw2X = 4.3 - CGFloat(sin(t * 15.0)) * 0.6
            let paw2Y = 12.6 - CGFloat(cos(t * 15.0)) * 0.4 + dy
            c.fill(Path(ellipseIn: v.r(paw2X, paw2Y, 1.2, 1.2)), with: .color(Self.catOrange))

            // Wiggling Tail Curled Behind
            let tailPoints: [(CGFloat, CGFloat)] = [
                (bodyX + bodyW - 1.0, bodyY + bodyH - 1.0),
                (bodyX + bodyW + 1.5, bodyY + bodyH - 2.0 + tailWave),
                (bodyX + bodyW + 1.0, bodyY + bodyH - 3.5 + tailWave),
                (bodyX + bodyW - 0.5, bodyY + bodyH - 3.0 + tailWave)
            ]
            c.fill(v.path(tailPoints), with: .color(Self.catOrange))
            c.fill(Path(ellipseIn: v.r(bodyX + bodyW + 0.6, bodyY + bodyH - 3.6 + tailWave, 1.2, 1.2)), with: .color(Self.catLight))
        }
    }
}
