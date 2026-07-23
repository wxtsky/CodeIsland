import SwiftUI

/// Grok's February 2025 black-and-white geometric mark.
///
/// The two paths below preserve the published SVG geometry exactly. Keep the
/// mark static and unmodified; session state is communicated by the surrounding
/// CodeIsland UI rather than by transforming the trademark.
/// Source: https://upload.wikimedia.org/wikipedia/commons/f/f7/Grok-feb-2025-logo.svg
struct GrokView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27

    var body: some View {
        GrokMark()
            .fill(Color.white)
            .frame(width: size * 0.68, height: size * 0.68)
        .frame(width: size, height: size)
        .accessibilityLabel("Grok")
    }
}

/// Exact geometry from the two `#mark` paths in Grok's February 2025 SVG.
/// Source view-box bounds for the mark are x: 0...33.6964, y: 0.5...32.5.
private struct GrokMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceWidth: CGFloat = 33.6964
        let sourceHeight: CGFloat = 32.0
        let sourceMinY: CGFloat = 0.5
        let scale = min(rect.width / sourceWidth, rect.height / sourceHeight)
        let offsetX = rect.midX - sourceWidth * scale / 2
        let offsetY = rect.midY - sourceHeight * scale / 2

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: offsetX + x * scale,
                y: offsetY + (y - sourceMinY) * scale
            )
        }

        var path = Path()

        path.move(to: point(13.2371, 21.0407))
        path.addLine(to: point(24.3186, 12.8506))
        path.addCurve(
            to: point(25.8973, 13.2294),
            control1: point(24.8619, 12.4491),
            control2: point(25.6384, 12.6057)
        )
        path.addCurve(
            to: point(23.9403, 23.1851),
            control1: point(27.2597, 16.5185),
            control2: point(26.651, 20.4712)
        )
        path.addCurve(
            to: point(14.0108, 25.1386),
            control1: point(21.2297, 25.8989),
            control2: point(17.4581, 26.4941)
        )
        path.addLine(to: point(10.2449, 26.8843))
        path.addCurve(
            to: point(26.304, 25.5601),
            control1: point(15.6463, 30.5806),
            control2: point(22.2053, 29.6665)
        )
        path.addCurve(
            to: point(29.6205, 13.8673),
            control1: point(29.5551, 22.3051),
            control2: point(30.562, 17.8683)
        )
        path.addLine(to: point(29.629, 13.8758))
        path.addCurve(
            to: point(33.449, 0.844576),
            control1: point(28.2637, 7.99809),
            control2: point(29.9647, 5.64871)
        )
        path.addCurve(
            to: point(33.6964, 0.5),
            control1: point(33.5314, 0.730667),
            control2: point(33.6139, 0.616757)
        )
        path.addLine(to: point(29.1113, 5.09055))
        path.addLine(to: point(29.1113, 5.07631))
        path.addLine(to: point(13.2343, 21.0436))
        path.closeSubpath()

        path.move(to: point(10.9503, 23.0313))
        path.addCurve(
            to: point(11.0498, 10.2763),
            control1: point(7.07343, 19.3235),
            control2: point(7.74185, 13.5853)
        )
        path.addCurve(
            to: point(21.0021, 8.2971),
            control1: point(13.4959, 7.82722),
            control2: point(17.5036, 6.82767)
        )
        path.addLine(to: point(24.7595, 6.55998))
        path.addCurve(
            to: point(22.2195, 5.17313),
            control1: point(24.0826, 6.07017),
            control2: point(23.215, 5.54334)
        )
        path.addCurve(
            to: point(8.67479, 7.90126),
            control1: point(17.7198, 3.31926),
            control2: point(12.3326, 4.24192)
        )
        path.addCurve(
            to: point(5.94992, 21.4622),
            control1: point(5.15635, 11.4239),
            control2: point(4.0499, 16.8403)
        )
        path.addCurve(
            to: point(2.69884, 29.826),
            control1: point(7.36924, 24.9165),
            control2: point(5.04257, 27.3598)
        )
        path.addCurve(
            to: point(0.36364, 32.5),
            control1: point(1.86829, 30.7002),
            control2: point(1.0349, 31.5745)
        )
        path.addLine(to: point(10.9474, 23.0341))
        path.closeSubpath()

        return path
    }
}
