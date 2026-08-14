import SwiftUI

/// The visible software perimeter of the island. This path deliberately stays
/// open across the screen edge so it never draws a seam behind the real notch.
struct NotchVisibleOutlineShape: Shape {
    var topExtension: CGFloat
    var bottomRadius: CGFloat
    var minHeight: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topExtension, bottomRadius) }
        set {
            topExtension = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ext = topExtension
        let maxY = max(rect.maxY, rect.minY + minHeight)
        let br = min(bottomRadius, rect.width / 4, (maxY - rect.minY) / 2)
        let k: CGFloat = 0.62

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + ext),
            control1: CGPoint(x: rect.minX - ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.minX, y: rect.minY + ext * 0.35)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: maxY - br))
        path.addCurve(
            to: CGPoint(x: rect.minX + br, y: maxY),
            control1: CGPoint(x: rect.minX, y: maxY - br * (1 - k)),
            control2: CGPoint(x: rect.minX + br * (1 - k), y: maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - br, y: maxY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: maxY - br),
            control1: CGPoint(x: rect.maxX - br * (1 - k), y: maxY),
            control2: CGPoint(x: rect.maxX, y: maxY - br * (1 - k))
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + ext))
        path.addCurve(
            to: CGPoint(x: rect.maxX + ext, y: rect.minY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35),
            control2: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY)
        )
        return path
    }
}
