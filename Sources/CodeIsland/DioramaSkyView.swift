import SwiftUI

public struct DioramaSkyPalette {
    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
        var color: Color { Color(red: r, green: g, blue: b) }
    }

    private static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    private static let keys: [(h: Double, top: RGB, bottom: RGB)] = [
        (0.0,  RGB(r: 0.03, g: 0.04, b: 0.14), RGB(r: 0.08, g: 0.10, b: 0.25)),
        (5.0,  RGB(r: 0.16, g: 0.20, b: 0.42), RGB(r: 0.95, g: 0.55, b: 0.40)),
        (7.5,  RGB(r: 0.45, g: 0.72, b: 0.95), RGB(r: 0.98, g: 0.85, b: 0.62)),
        (12.0, RGB(r: 0.30, g: 0.62, b: 0.98), RGB(r: 0.62, g: 0.84, b: 1.00)),
        (16.0, RGB(r: 0.40, g: 0.55, b: 0.85), RGB(r: 1.00, g: 0.78, b: 0.45)),
        (18.3, RGB(r: 0.30, g: 0.22, b: 0.45), RGB(r: 1.00, g: 0.42, b: 0.22)),
        (19.6, RGB(r: 0.07, g: 0.08, b: 0.22), RGB(r: 0.28, g: 0.20, b: 0.38)),
        (24.0, RGB(r: 0.03, g: 0.04, b: 0.14), RGB(r: 0.08, g: 0.10, b: 0.25)),
    ]

    public static func colors(_ hour: Double) -> (Color, Color) {
        let h = hour.truncatingRemainder(dividingBy: 24)
        for i in 1..<keys.count where h <= keys[i].h {
            let a = keys[i - 1], b = keys[i]
            let t = (h - a.h) / (b.h - a.h)
            return (mix(a.top, b.top, t).color, mix(a.bottom, b.bottom, t).color)
        }
        return (keys[0].top.color, keys[0].bottom.color)
    }

    public static func nightFactor(_ hour: Double) -> Double {
        let h = hour.truncatingRemainder(dividingBy: 24)
        if h < 4.5 || h > 19.8 { return 1 }
        if h < 6.0 { return (6.0 - h) / 1.5 }
        if h > 18.3 { return (h - 18.3) / 1.5 }
        return 0
    }

    public static func windowsLit(_ hour: Double) -> Bool { hour >= 17.0 || hour < 5.6 }
}

/// 138pt living procedural diorama canvas with sky gradient, sun/moon arc, drifting clouds, stars, and skyline.
public struct DioramaSkyView: View {
    public let hour: Double
    public let hijriDay: Int
    public var pixel: Bool = false
    public var skyline: Bool = true
    public var skylineHeight: CGFloat = 0.12

    private static let stars: [(Double, Double)] = [
        (0.08, 0.15), (0.17, 0.40), (0.26, 0.12), (0.35, 0.30), (0.46, 0.10), (0.55, 0.38),
        (0.64, 0.18), (0.73, 0.08), (0.82, 0.34), (0.91, 0.16), (0.96, 0.42), (0.40, 0.22),
    ]
    private static let buildings: [Double] = [0.20, 0.30, 0.24, 0.38, 0.22, 0.32, 0.18, 0.28, 0.36, 0.21, 0.30, 0.16]

    public init(hour: Double, hijriDay: Int, pixel: Bool = false, skyline: Bool = true, skylineHeight: CGFloat = 0.12) {
        self.hour = hour
        self.hijriDay = hijriDay
        self.pixel = pixel
        self.skyline = skyline
        self.skylineHeight = skylineHeight
    }

    public var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = pixel ? 4 : 0
            func snap(_ v: CGFloat) -> CGFloat { cell > 0 ? (v / cell).rounded() * cell : v }

            let (top, bottom) = DioramaSkyPalette.colors(hour)
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [top, bottom]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))

            let night = DioramaSkyPalette.nightFactor(hour)
            if night > 0.05 {
                for (sx, sy) in Self.stars {
                    let r: CGFloat = pixel ? 2 : 1.1
                    let rect = CGRect(x: snap(sx * size.width), y: snap(sy * size.height * 0.8), width: r, height: r)
                    ctx.fill(Path(rect), with: .color(.white.opacity(0.85 * night)))
                }
            }

            // Sun: 5.75 → 18.3. Moon: 18.3 → 29.75 (5.75 next day).
            let horizonY = size.height * (skyline ? 0.82 : 1.0)
            let archH = horizonY * 0.78
            func arcPoint(_ p: Double) -> CGPoint {
                CGPoint(x: size.width * (0.10 + 0.80 * p), y: horizonY - archH * sin(.pi * p))
            }
            let h = hour
            if h >= 5.75 && h <= 18.3 {
                let p = (h - 5.75) / (18.3 - 5.75)
                let c = arcPoint(p)
                let r = min(size.width, size.height) * 0.07
                let col = (h >= 15.5 && h < 18.3) ? Color(red: 1.0, green: 0.62, blue: 0.25) : Color(red: 1.0, green: 0.93, blue: 0.6)
                if pixel {
                    ctx.fill(Path(CGRect(x: snap(c.x - r), y: snap(c.y - r), width: snap(r * 2), height: snap(r * 2))), with: .color(col))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.9, y: c.y - r * 1.9, width: r * 3.8, height: r * 3.8)), with: .color(col.opacity(0.22)))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(col))
                }
            } else {
                let hh = h < 5.75 ? h + 24 : h
                let p = max(0, min(1, (hh - 18.3) / (29.75 - 18.3)))
                let c = arcPoint(p)
                let r = min(size.width, size.height) * 0.06
                let f = Double(hijriDay) / 29.5
                let dx = (f < 0.5 ? -1.0 : 1.0) * 2.0 * Double(r) * sin(f * .pi)
                if pixel {
                    ctx.fill(Path(CGRect(x: snap(c.x - r), y: snap(c.y - r), width: snap(r * 2), height: snap(r * 2))), with: .color(Color(red: 0.95, green: 0.95, blue: 0.85)))
                    ctx.fill(Path(CGRect(x: snap(c.x - r + CGFloat(dx)), y: snap(c.y - r), width: snap(r * 2), height: snap(r * 2))), with: .color(top))
                } else {
                    let moon = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    ctx.fill(moon, with: .color(Color(red: 0.95, green: 0.95, blue: 0.85)))
                    ctx.drawLayer { layer in
                        layer.clip(to: moon)
                        layer.fill(Path(ellipseIn: CGRect(x: c.x - r + CGFloat(dx), y: c.y - r, width: r * 2, height: r * 2)), with: .color(top))
                    }
                }
            }

            // Clouds (drift with the hour = cheap parallax), fade at night.
            let cloudA = 1.0 - night * 0.85
            for (i, base) in [0.2, 0.62].enumerated() {
                let x = (base * size.width + CGFloat(hour) * (i == 0 ? 6 : 3)).truncatingRemainder(dividingBy: size.width + 60) - 30
                let y = size.height * (i == 0 ? 0.22 : 0.38)
                if pixel {
                    ctx.fill(Path(CGRect(x: snap(x), y: snap(y), width: 28, height: 4)), with: .color(.white.opacity(0.5 * cloudA)))
                    ctx.fill(Path(CGRect(x: snap(x + 4), y: snap(y - 4), width: 16, height: 4)), with: .color(.white.opacity(0.5 * cloudA)))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 34, height: 9)), with: .color(.white.opacity(0.45 * cloudA)))
                }
            }

            // Skyline + windows
            if skyline {
                let n = Self.buildings.count
                let w = size.width / CGFloat(n)
                let lit = DioramaSkyPalette.windowsLit(hour)
                let baseSkylineY = size.height * 0.92
                for (i, bh) in Self.buildings.enumerated() {
                    let bHeight = snap(size.height * skylineHeight * CGFloat(bh) / 0.38)
                    let rect = CGRect(x: snap(CGFloat(i) * w), y: baseSkylineY - bHeight, width: snap(w) + 0.5, height: bHeight + size.height * 0.15)
                    ctx.fill(Path(rect), with: .color(Color(red: 0.05, green: 0.06, blue: 0.10)))
                    if lit {
                        var wy = rect.minY + 4
                        while wy < baseSkylineY - 2 {
                            let wx = rect.minX + w * 0.28
                            ctx.fill(Path(CGRect(x: snap(wx), y: snap(wy), width: pixel ? 4 : 2.2, height: pixel ? 4 : 2.2)),
                                     with: .color(Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.9)))
                            wy += pixel ? 8 : 6.5
                        }
                    }
                }
            }
        }
    }
}
