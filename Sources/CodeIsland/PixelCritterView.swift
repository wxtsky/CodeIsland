import SwiftUI

/// How Claude's and Codex's mascots are drawn. Classic keeps Clawd and Dex as
/// they have always been; Pixel critter swaps both for `PixelCritterView`.
/// Every other mascot looks the same in either style.
enum MascotStyle: String, CaseIterable {
    case classic
    case critter

    /// Unknown or missing values read as Classic.
    init(setting: String) {
        self = MascotStyle(rawValue: setting) ?? .classic
    }

    /// The critter that stands in for Clawd (or Dex, when `codex`), or nil
    /// when the classic mascot is drawn.
    func critter(codex: Bool) -> CritterStyle? {
        switch self {
        case .classic: return nil
        case .critter: return codex ? .dex : .clawd
        }
    }
}

/// How a turn ended, for the critter's done / error poses. Only the critter
/// reads it; classic and other mascots ignore it.
enum MascotOutcome: Equatable {
    case done, error
}

/// What tells the critters apart: body colour, the keyboard's lit-key colour
/// (it has to stand out against the body) and Codex's antenna.
struct CritterStyle: Equatable {
    let body: Color
    let keyLit: Color
    let antenna: Bool

    /// Claude: terracotta (#D97757).
    static let clawd = CritterStyle(body: Color(red: 0.851, green: 0.467, blue: 0.341),
                                    keyLit: .white, antenna: false)
    /// Codex: OpenAI's off-white, grey lit keys, a blue-tipped antenna.
    static let dex = CritterStyle(body: Color(red: 0.92, green: 0.92, blue: 0.93),
                                  keyLit: Color(red: 0.55, green: 0.55, blue: 0.58), antenna: true)
}

/// The "Pixel critter" mascot style: one boxy critter on a 16×16 grid, shared
/// by Claude and Codex, with seven poses.
///
/// Grid (y down): symbols live in rows 0–4, the body in rows 5–12 (x 2–13),
/// side nubs at rows 9–10, four stub legs in rows 13–14.
struct PixelCritterView: View {
    let status: MascotAgentStatus
    var outcome: MascotOutcome? = nil
    var size: CGFloat = 27
    var style: CritterStyle = .clawd

    enum Pose: Equatable, CaseIterable {
        case idle, thinking, running, approval, question, done, error
    }

    /// An outcome wins over the status; otherwise the status picks the pose.
    static func pose(status: MascotAgentStatus, outcome: MascotOutcome?) -> Pose {
        switch outcome {
        case .done?: return .done
        case .error?: return .error
        case nil: break
        }
        switch status {
        case .idle: return .idle
        case .processing: return .thinking
        case .running: return .running
        case .waitingApproval: return .approval
        case .waitingQuestion: return .question
        }
    }

    var pose: Pose { Self.pose(status: status, outcome: outcome) }

    var body: some View {
        let pose = self.pose
        let style = self.style
        // Sleep ticks every 0.25 s like the other sleep scenes; the rest need
        // 0.1 s to show their quarter-second hops and key flashes.
        MascotTimeline(interval: pose == .idle ? 0.25 : 0.1) { t in
            Canvas { ctx, sz in
                Self.draw(pose, t: t, in: ctx, size: sz, style: style)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    // MARK: Drawing

    private static let eyeC = Color.black
    private static let alertC = Color(red: 1.0, green: 0.62, blue: 0.2)   // "!" (needs you)
    private static let errorC = Color(red: 1.0, green: 0.24, blue: 0.0)   // #FF3D00
    private static let inkC = Color.white
    private static let antennaTipC = Color(red: 0.45, green: 0.55, blue: 1.0)

    /// Grid → view points; `dx`/`dy` move the whole figure in grid units.
    private struct G {
        let s: CGFloat, ox: CGFloat, oy: CGFloat
        var dx: CGFloat = 0, dy: CGFloat = 0
        init(_ sz: CGSize) {
            s = min(sz.width, sz.height) / 16
            ox = (sz.width - 16 * s) / 2
            oy = (sz.height - 16 * s) / 2
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 1, _ h: CGFloat = 1) -> CGRect {
            CGRect(x: ox + (x + dx) * s, y: oy + (y + dy) * s, width: w * s, height: h * s)
        }
    }

    private static func px(_ ctx: GraphicsContext, _ g: G, _ c: Color,
                           _ rects: [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
        for (x, y, w, h) in rects { ctx.fill(Path(g.r(x, y, w, h)), with: .color(c)) }
    }

    /// Square wave: true for the first half of each `period`.
    private static func on(_ t: Double, _ period: Double, phase: Double = 0) -> Bool {
        (t + phase).truncatingRemainder(dividingBy: period) < period / 2
    }

    private enum Arms { case side, up, down, wave }

    private static func figure(_ ctx: GraphicsContext, _ g: G, _ style: CritterStyle, arms: Arms,
                               legsSquash: Bool = false, bodyTop: CGFloat = 5) {
        let bodyC = style.body
        px(ctx, g, bodyC, [(2, bodyTop, 12, 13 - bodyTop)])
        if style.antenna {
            // Codex's antenna: a stalk and a tip, off-centre left.
            px(ctx, g, bodyC, [(5, bodyTop - 2, 1, 2)])
            px(ctx, g, antennaTipC, [(4, bodyTop - 3, 3, 1), (5, bodyTop - 4, 1, 1)])
        }
        let legH: CGFloat = legsSquash ? 1 : 2
        px(ctx, g, bodyC, [(3, 13, 1, legH), (6, 13, 1, legH), (9, 13, 1, legH), (12, 13, 1, legH)])
        switch arms {
        case .side:
            px(ctx, g, bodyC, [(0, 9, 2, 2), (14, 9, 2, 2)])
        case .down:
            px(ctx, g, bodyC, [(1, 10, 1, 3), (14, 10, 1, 3)])
        case .up:
            px(ctx, g, bodyC, [(1, 6, 1, 2), (0, 4, 1, 2), (14, 6, 1, 2), (15, 4, 1, 2)])
        case .wave:
            px(ctx, g, bodyC, [(0, 9, 2, 2), (14, 6, 1, 2), (15, 4, 1, 2)])
        }
    }

    private static func openEyes(_ ctx: GraphicsContext, _ g: G, lookUp: Bool = false, blink: Bool = false) {
        let y: CGFloat = lookUp ? 6 : 7
        if blink {
            px(ctx, g, eyeC, [(5, y + 1, 1, 1), (10, y + 1, 1, 1)])
        } else {
            px(ctx, g, eyeC, [(5, y, 1, 2), (10, y, 1, 2)])
        }
    }

    static func draw(_ pose: Pose, t: Double, in ctx: GraphicsContext, size: CGSize, style: CritterStyle) {
        var g = G(size)
        switch pose {
        case .idle:
            // Closed eyes, slow breath, a "z" drifting up.
            g.dy = on(t, 2.4) ? 0 : 0.5
            figure(ctx, g, style, arms: .side)
            px(ctx, g, eyeC, [(4, 8, 2, 1), (10, 8, 2, 1)])
            let rise = CGFloat(t.truncatingRemainder(dividingBy: 2.4) / 2.4) * 2
            var z = G(size); z.dy = -rise
            px(ctx, z, inkC.opacity(Double(1 - rise / 2.4)), [(12, 2, 3, 1), (13, 3, 1, 1), (12, 4, 3, 1)])
        case .thinking:
            // Eyes up, two dots rising in turn.
            figure(ctx, g, style, arms: .side)
            openEyes(ctx, g, lookUp: true, blink: t.truncatingRemainder(dividingBy: 3.0) < 0.15)
            if on(t, 1.0) { px(ctx, g, inkC, [(11, 3, 1, 1)]) }
            if on(t, 1.0, phase: 0.5) { px(ctx, g, inkC, [(13, 0, 2, 2)]) }
        case .running:
            // Typing: a hop, the keyboard mouth flashing, speed lines.
            g.dy = on(t, 0.25) ? 0 : -0.5
            figure(ctx, g, style, arms: .side)
            openEyes(ctx, g)
            let phase = Int(t * 8) % 2
            for k in 0..<6 {
                let lit = (k + phase) % 2 == 0
                px(ctx, g, lit ? style.keyLit : eyeC, [(CGFloat(5 + k), 10, 1, 1)])
            }
            var lines = G(size); lines.dx = on(t, 0.25) ? 0 : 0.5
            px(ctx, lines, inkC.opacity(0.85), [(14, 2, 2, 1), (14, 4, 2, 1)])
        case .approval:
            // Arms up waving, a blinking orange "!".
            figure(ctx, g, style, arms: on(t, 0.5) ? .up : .wave)
            openEyes(ctx, g)
            if on(t, 0.8) { px(ctx, g, alertC, [(12, 0, 1, 2), (12, 3, 1, 1)]) }
        case .question:
            // Head cocked (eyes offset), a bobbing "?".
            g.dx = on(t, 1.6) ? 0 : 0.5
            figure(ctx, g, style, arms: .side)
            px(ctx, g, eyeC, [(5, 8, 1, 2), (10, 7, 1, 2)])
            var q = G(size); q.dy = on(t, 0.8) ? 0 : -0.5
            px(ctx, q, inkC, [(12, 0, 2, 1), (14, 1, 1, 1), (13, 2, 1, 1), (13, 4, 1, 1)])
        case .done:
            // A happy hop, ^^ eyes, arms up, a twinkle.
            g.dy = on(t, 0.5) ? -1 : 0
            figure(ctx, g, style, arms: .up)
            px(ctx, g, eyeC, [(4, 8, 1, 1), (5, 7, 1, 1), (6, 8, 1, 1), (9, 8, 1, 1), (10, 7, 1, 1), (11, 8, 1, 1)])
            if on(t, 0.5, phase: 0.25) {
                px(ctx, G(size), inkC, [(13, 0, 1, 1), (12, 1, 1, 1), (14, 1, 1, 1), (13, 2, 1, 1)])
            }
        case .error:
            // Slumped body, X eyes, a red "x" above.
            figure(ctx, g, style, arms: .down, legsSquash: true, bodyTop: 6)
            px(ctx, g, eyeC, [(4, 7, 1, 1), (6, 7, 1, 1), (5, 8, 1, 1), (4, 9, 1, 1), (6, 9, 1, 1),
                              (9, 7, 1, 1), (11, 7, 1, 1), (10, 8, 1, 1), (9, 9, 1, 1), (11, 9, 1, 1)])
            if on(t, 1.0) {
                px(ctx, g, errorC, [(12, 0, 1, 1), (14, 0, 1, 1), (13, 1, 1, 1), (12, 2, 1, 1), (14, 2, 1, 1)])
            }
        }
    }
}
