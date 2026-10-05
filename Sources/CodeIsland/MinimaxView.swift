import SwiftUI

/// MiniMax Code CLI (`mcode`) mark.
///
/// A bold geometric "M" drawn from straight segments. Kept static and
/// unmodified — session state is communicated by the surrounding CodeIsland
/// UI rather than by transforming the mark (same rule as GrokView).
struct MinimaxView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27

    var body: some View {
        MinimaxMark()
            .fill(Color.white)
            .frame(width: size * 0.72, height: size * 0.72)
            .frame(width: size, height: size)
            .accessibilityLabel("MiniMax Code CLI")
    }
}

/// Block-letter "M" on a 32×32 view box: two outer stems joined by a V that
/// dips toward the baseline, per the outline below (clockwise from top-left).
private struct MinimaxMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceWidth: CGFloat = 32
        let sourceHeight: CGFloat = 32
        let scale = min(rect.width / sourceWidth, rect.height / sourceHeight)
        let offsetX = rect.midX - sourceWidth * scale / 2
        let offsetY = rect.midY - sourceHeight * scale / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        var path = Path()
        path.move(to: point(0, 4))
        path.addLine(to: point(6.5, 4))
        path.addLine(to: point(16, 15))
        path.addLine(to: point(25.5, 4))
        path.addLine(to: point(32, 4))
        path.addLine(to: point(32, 28))
        path.addLine(to: point(25.5, 28))
        path.addLine(to: point(25.5, 13))
        path.addLine(to: point(19, 22))
        path.addLine(to: point(13, 22))
        path.addLine(to: point(6.5, 13))
        path.addLine(to: point(6.5, 28))
        path.addLine(to: point(0, 28))
        path.closeSubpath()
        return path
    }
}
