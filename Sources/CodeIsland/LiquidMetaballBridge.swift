import SwiftUI

/// PreferenceKey to measure the exact frames of the header navigation tab icons
struct TabIconFrameKey: PreferenceKey {
    static var defaultValue: [ExpandedContentTab: CGRect] = [:]
    static func reduce(value: inout [ExpandedContentTab: CGRect], nextValue: () -> [ExpandedContentTab: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Renders the Gravitational Liquid Metaball / Accretion Siphon bridge between two tabs
struct LiquidMetaballBridge: View {
    let originTab: ExpandedContentTab
    let targetTab: ExpandedContentTab
    let progress: CGFloat
    let tabFrames: [ExpandedContentTab: CGRect]
    let color: Color
    let isPixel: Bool

    var body: some View {
        if let f1 = tabFrames[originTab], let f2 = tabFrames[targetTab] {
            if isPixel {
                // Retro Cyber Chunky Pixel Liquid Bridge
                PixelLiquidBridgeView(
                    rect1: f1,
                    rect2: f2,
                    progress: progress,
                    color: color
                )
            } else {
                // Modern Smooth Gooey Bezier Metaball Bridge
                ModernGooeyBridgeView(
                    rect1: f1,
                    rect2: f2,
                    progress: progress,
                    color: color
                )
            }
        }
    }
}

// MARK: - Modern Smooth Gooey Bezier Bridge

private struct ModernGooeyBridgeView: View {
    let rect1: CGRect
    let rect2: CGRect
    let progress: CGFloat
    let color: Color

    var body: some View {
        let p = max(0, min(1, progress))
        let c1 = CGPoint(x: rect1.midX, y: rect1.midY)
        let c2 = CGPoint(x: rect2.midX, y: rect2.midY)
        let baseR: CGFloat = min(rect1.height, rect2.height) * 0.46

        // Origin and target radii morph dynamically with progress
        let r1 = max(1.5, baseR * pow(1.0 - p * 0.85, 0.5))
        let r2 = max(1.5, baseR * pow(max(0.01, p), 0.5))

        // Catenary neck properties
        let xNeck = c1.x + (c2.x - c1.x) * p
        let yNeck = (c1.y + c2.y) / 2
        let neckThickness = (p > 0.05 && p < 0.95)
            ? baseR * sin(.pi * p) * 0.45
            : 0

        ZStack {
            // Liquid fill with soft glow
            MetaballShape(
                c1: c1,
                r1: r1,
                c2: c2,
                r2: r2,
                xNeck: xNeck,
                yNeck: yNeck,
                neckThickness: neckThickness,
                isSnapped: p > 0.88
            )
            .fill(color == .white ? Color.white.opacity(0.20) : color.opacity(0.26))
            .shadow(color: color.opacity(0.35), radius: 3, x: 0, y: 0)

            // Dynamic cosmic accretion core highlight
            if neckThickness > 2 {
                Path { path in
                    path.move(to: CGPoint(x: c1.x + (c2.x - c1.x) * (p * 0.7), y: yNeck))
                    path.addLine(to: CGPoint(x: c1.x + (c2.x - c1.x) * (p * 1.1), y: yNeck))
                }
                .stroke(
                    LinearGradient(
                        colors: [color.opacity(0.1), color.opacity(0.7), color.opacity(0.2)],
                        startPoint: c1.x < c2.x ? .leading : .trailing,
                        endPoint: c1.x < c2.x ? .trailing : .leading
                    ),
                    style: StrokeStyle(lineWidth: max(1.0, neckThickness * 0.4), lineCap: .round)
                )
            }
        }
    }
}

// MARK: - Modern Metaball Path Shape

private struct MetaballShape: Shape {
    var c1: CGPoint
    var r1: CGFloat
    var c2: CGPoint
    var r2: CGFloat
    var xNeck: CGFloat
    var yNeck: CGFloat
    var neckThickness: CGFloat
    var isSnapped: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()

        if isSnapped || neckThickness <= 0.8 {
            // Disconnected: Target bulb absorbing mass
            path.addEllipse(in: CGRect(x: c2.x - r2, y: c2.y - r2, width: r2 * 2, height: r2 * 2))
            if r1 > 2 {
                path.addEllipse(in: CGRect(x: c1.x - r1, y: c1.y - r1, width: r1 * 2, height: r1 * 2))
            }
            return path
        }

        let isLeftToRight = c1.x <= c2.x
        let leftC = isLeftToRight ? c1 : c2
        let rightC = isLeftToRight ? c2 : c1
        let leftR = isLeftToRight ? r1 : r2
        let rightR = isLeftToRight ? r2 : r1

        // Top arc left
        path.move(to: CGPoint(x: leftC.x, y: leftC.y - leftR))
        // Top neck curve
        path.addQuadCurve(
            to: CGPoint(x: rightC.x, y: rightC.y - rightR),
            control: CGPoint(x: xNeck, y: yNeck - neckThickness)
        )
        // Right cap
        path.addArc(
            center: rightC,
            radius: rightR,
            startAngle: .degrees(-90),
            endAngle: .degrees(90),
            clockwise: false
        )
        // Bottom neck curve
        path.addQuadCurve(
            to: CGPoint(x: leftC.x, y: leftC.y + leftR),
            control: CGPoint(x: xNeck, y: yNeck + neckThickness)
        )
        // Left cap
        path.addArc(
            center: leftC,
            radius: leftR,
            startAngle: .degrees(90),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()

        return path
    }
}

// MARK: - Retro Pixel Chunky Liquid Bridge

private struct PixelLiquidBridgeView: View {
    let rect1: CGRect
    let rect2: CGRect
    let progress: CGFloat
    let color: Color

    var body: some View {
        let p = max(0, min(1, progress))
        let c1 = CGPoint(x: rect1.midX, y: rect1.midY)
        let c2 = CGPoint(x: rect2.midX, y: rect2.midY)
        let minX = min(c1.x, c2.x) - 10
        let maxX = max(c1.x, c2.x) + 10
        let totalW = max(10, maxX - minX)
        let totalH = max(rect1.height, rect2.height)

        Canvas { context, size in
            let pixelSize: CGFloat = 2.0
            let startX = c1.x
            let endX = c2.x
            let midY = (c1.y + c2.y) / 2
            let dist = endX - startX

            // Quantized stream of 2x2 blocks along catenary path
            let steps = Int(abs(dist) / pixelSize)
            guard steps > 0 else { return }

            for i in 0...steps {
                let stepFraction = CGFloat(i) / CGFloat(steps)
                let currentX = startX + dist * stepFraction
                let distToProgress = abs(stepFraction - p)

                // Dithered thickness: thickest near progress wave head
                let localSpread: CGFloat = max(0, 1.0 - distToProgress * 2.2)
                let thicknessBlocks = Int(ceil(localSpread * 3.5))

                for blockY in -thicknessBlocks...thicknessBlocks {
                    // Dithered pseudo-random dissolve for retro particle feel
                    let seed = Int((currentX * 13 + CGFloat(blockY) * 7).truncatingRemainder(dividingBy: 5))
                    if distToProgress > 0.35 && seed == 0 { continue }

                    let px = floor(currentX / pixelSize) * pixelSize
                    let py = floor((midY + CGFloat(blockY) * pixelSize) / pixelSize) * pixelSize

                    let blockRect = CGRect(x: px, y: py, width: pixelSize, height: pixelSize)
                    context.fill(Path(blockRect), with: .color(color.opacity(0.24)))
                }
            }

            // Head beacon cluster at current transfer front
            let headX = startX + dist * p
            let headRect = CGRect(
                x: floor(headX / pixelSize) * pixelSize - pixelSize,
                y: floor(midY / pixelSize) * pixelSize - pixelSize,
                width: pixelSize * 3,
                height: pixelSize * 3
            )
            context.fill(Path(headRect), with: .color(color.opacity(0.40)))
        }
        .frame(width: totalW, height: totalH)
    }
}
