import SwiftUI

// Glyph identifier for pixel-art icons
public enum PixelIconGlyph: String, CaseIterable, Sendable {
    case agents
    case workspace
    case music
    case prayer
    case calendar
    case email
}

// Crisp Canvas-based vector pixel icon renderer
public struct PixelIcon: View {
    let glyph: PixelIconGlyph
    let color: Color
    var pixelSize: CGFloat = 1.6

    // Dimensions and binary bitmap matrices
    private var spec: (w: Int, h: Int, data: [UInt8]) {
        switch glyph {
        case .agents:
            return (9, 9, [
                0,0,0,0,1,0,0,0,0,
                0,0,0,0,1,0,0,0,0,
                0,1,1,1,1,1,1,1,0,
                1,1,0,1,1,1,0,1,1,
                1,1,1,1,1,1,1,1,1,
                1,1,0,0,0,0,0,1,1,
                0,1,1,1,1,1,1,1,0,
                0,0,1,0,0,0,1,0,0,
                0,0,1,1,1,1,1,0,0
            ])
        case .workspace:
            return (10, 9, [
                1,1,1,1,0,0,0,0,0,0,
                1,1,1,1,1,1,1,1,1,1,
                1,0,0,0,0,0,0,0,0,1,
                1,0,1,0,0,0,0,1,0,1,
                1,0,0,1,0,0,1,0,0,1,
                1,0,1,0,0,0,0,1,0,1,
                1,0,0,0,0,0,0,0,0,1,
                1,1,1,1,1,1,1,1,1,1,
                0,0,0,0,0,0,0,0,0,0
            ])
        case .music:
            return (9, 9, [
                0,0,0,0,1,1,1,1,1,
                0,0,0,0,1,0,0,0,1,
                0,0,0,0,1,0,0,0,1,
                0,0,0,0,1,0,0,0,1,
                0,0,1,1,1,0,0,0,1,
                0,1,1,1,1,0,1,1,1,
                1,1,1,1,1,1,1,1,1,
                0,1,1,1,0,0,1,1,0,
                0,0,1,0,0,0,0,0,0
            ])
        case .prayer:
            return (9, 9, [
                0,0,1,1,1,0,0,0,1,
                0,1,1,0,0,1,0,1,1,
                1,1,0,0,0,0,0,0,1,
                1,1,0,0,0,0,0,0,0,
                1,1,0,0,0,0,0,0,0,
                1,1,0,0,0,0,0,0,0,
                0,1,1,0,0,1,0,0,0,
                0,0,1,1,1,0,0,0,0,
                0,0,0,0,0,0,0,0,0
            ])
        case .calendar:
            return (9, 9, [
                0,1,0,0,1,0,0,1,0,
                1,1,1,1,1,1,1,1,1,
                1,1,1,1,1,1,1,1,1,
                1,0,0,0,0,0,0,0,1,
                1,0,1,0,1,0,1,0,1,
                1,0,0,0,0,0,0,0,1,
                1,0,1,0,1,0,1,0,1,
                1,0,0,0,0,0,0,0,1,
                1,1,1,1,1,1,1,1,1
            ])
        case .email:
            return (9, 9, [
                1,1,1,1,1,1,1,1,1,
                1,1,0,0,0,0,0,1,1,
                1,0,1,0,0,0,1,0,1,
                1,0,0,1,0,1,0,0,1,
                1,0,0,0,1,0,0,0,1,
                1,0,0,1,0,1,0,0,1,
                1,0,1,0,0,0,1,0,1,
                1,1,0,0,0,0,0,1,1,
                1,1,1,1,1,1,1,1,1
            ])
        }
    }

    public var body: some View {
        let (w, h, data) = spec
        let px = pixelSize
        let totalW = CGFloat(w) * px
        let totalH = CGFloat(h) * px

        Canvas { ctx, _ in
            for row in 0..<h {
                for col in 0..<w {
                    if data[row * w + col] == 1 {
                        let rect = CGRect(
                            x: CGFloat(col) * px,
                            y: CGFloat(row) * px,
                            width: px,
                            height: px
                        )
                        ctx.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: totalW, height: totalH)
    }
}
