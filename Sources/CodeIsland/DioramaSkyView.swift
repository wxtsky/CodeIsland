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
        (0.0,  RGB(r: 0.07, g: 0.07, b: 0.18), RGB(r: 0.16, g: 0.13, b: 0.28)),
        (4.5,  RGB(r: 0.08, g: 0.08, b: 0.22), RGB(r: 0.22, g: 0.16, b: 0.34)),
        (5.5,  RGB(r: 0.16, g: 0.20, b: 0.42), RGB(r: 0.95, g: 0.55, b: 0.40)),
        (7.5,  RGB(r: 0.45, g: 0.72, b: 0.95), RGB(r: 0.98, g: 0.85, b: 0.62)),
        (12.0, RGB(r: 0.30, g: 0.62, b: 0.98), RGB(r: 0.62, g: 0.84, b: 1.00)),
        (16.0, RGB(r: 0.40, g: 0.55, b: 0.85), RGB(r: 1.00, g: 0.78, b: 0.45)),
        (18.3, RGB(r: 0.30, g: 0.22, b: 0.45), RGB(r: 1.00, g: 0.42, b: 0.22)),
        (19.6, RGB(r: 0.11, g: 0.10, b: 0.26), RGB(r: 0.26, g: 0.18, b: 0.38)),
        (21.5, RGB(r: 0.09, g: 0.09, b: 0.22), RGB(r: 0.20, g: 0.16, b: 0.32)),
        (24.0, RGB(r: 0.07, g: 0.07, b: 0.18), RGB(r: 0.16, g: 0.13, b: 0.28)),
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
    public var sunriseHour: Double = 5.75
    public var sunsetHour: Double = 18.3
    public var pixel: Bool = false
    public var skyline: Bool = true
    public var skylineHeight: CGFloat = 0.12

    private struct Star {
        let x: Double
        let y: Double
        let isCross: Bool
        let brightness: Double
    }

    private static let stars: [Star] = [
        Star(x: 0.08, y: 0.16, isCross: false, brightness: 0.8),
        Star(x: 0.16, y: 0.38, isCross: false, brightness: 0.75),
        Star(x: 0.23, y: 0.12, isCross: true,  brightness: 0.95),
        Star(x: 0.32, y: 0.26, isCross: false, brightness: 0.7),
        Star(x: 0.43, y: 0.10, isCross: false, brightness: 0.85),
        Star(x: 0.48, y: 0.34, isCross: true,  brightness: 0.90),
        Star(x: 0.58, y: 0.16, isCross: false, brightness: 0.75),
        Star(x: 0.67, y: 0.30, isCross: false, brightness: 0.8),
        Star(x: 0.74, y: 0.08, isCross: true,  brightness: 0.95),
        Star(x: 0.82, y: 0.24, isCross: false, brightness: 0.8),
        Star(x: 0.90, y: 0.14, isCross: false, brightness: 0.7),
        Star(x: 0.95, y: 0.32, isCross: false, brightness: 0.85),
    ]
    private static let buildings: [Double] = [0.20, 0.30, 0.24, 0.38, 0.22, 0.32, 0.18, 0.28, 0.36, 0.21, 0.30, 0.16]

    public init(
        hour: Double,
        hijriDay: Int,
        sunriseHour: Double = 5.75,
        sunsetHour: Double = 18.3,
        pixel: Bool = false,
        skyline: Bool = true,
        skylineHeight: CGFloat = 0.12
    ) {
        self.hour = hour
        self.hijriDay = hijriDay
        self.sunriseHour = sunriseHour
        self.sunsetHour = sunsetHour
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
                for star in Self.stars {
                    let cx = snap(star.x * size.width)
                    let cy = snap(star.y * size.height * 0.75)
                    let a = night * star.brightness
                    if star.isCross {
                        ctx.fill(Path(CGRect(x: cx - 1, y: cy - 1, width: 2, height: 2)), with: .color(.white.opacity(a)))
                        ctx.fill(Path(CGRect(x: cx - 2, y: cy, width: 5, height: 1)), with: .color(.white.opacity(a * 0.75)))
                        ctx.fill(Path(CGRect(x: cx, y: cy - 2, width: 1, height: 5)), with: .color(.white.opacity(a * 0.75)))
                    } else {
                        let r: CGFloat = pixel ? 2 : 1.3
                        ctx.fill(Path(CGRect(x: cx, y: cy, width: r, height: r)), with: .color(.white.opacity(a)))
                    }
                }
            }

            // Dynamic celestial arc: Sunrise -> Sunset (Sun), Sunset -> Next Sunrise (Moon)
            let sunrise = sunriseHour
            let sunset = sunsetHour
            let nextSunrise = sunrise + 24.0
            let horizonY = size.height * (skyline ? 0.80 : 1.0)
            let archH = horizonY * 0.75
            func arcPoint(_ p: Double) -> CGPoint {
                CGPoint(x: size.width * (0.08 + 0.84 * p), y: horizonY - archH * sin(.pi * p))
            }
            let h = hour
            if h >= sunrise && h <= sunset {
                let p = (h - sunrise) / max(0.1, sunset - sunrise)
                let c = arcPoint(p)
                let r = min(size.width, size.height) * 0.07
                let col = (h >= (sunset - 2.8) && h < sunset) ? Color(red: 1.0, green: 0.62, blue: 0.25) : Color(red: 1.0, green: 0.93, blue: 0.6)
                if pixel {
                    ctx.fill(Path(CGRect(x: snap(c.x - r), y: snap(c.y - r), width: snap(r * 2), height: snap(r * 2))), with: .color(col))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 1.8, y: c.y - r * 1.8, width: r * 3.6, height: r * 3.6)), with: .color(col.opacity(0.20)))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(col))
                }
            } else {
                let hh = h < sunrise ? h + 24.0 : h
                let p = max(0, min(1, (hh - sunset) / max(0.1, nextSunrise - sunset)))
                let c = arcPoint(p)
                let r = min(size.width, size.height) * 0.08
                let phaseRatio = Double(max(1, min(30, hijriDay))) / 29.5
                let illuminated = 0.5 * (1.0 - cos(2.0 * .pi * phaseRatio))

                let moonRect = CGRect(x: snap(c.x - r), y: snap(c.y - r), width: snap(r * 2), height: snap(r * 2))
                let moonPath = Path(ellipseIn: moonRect)
                ctx.fill(moonPath, with: .color(Color(red: 0.96, green: 0.96, blue: 0.92)))

                if illuminated < 0.92 {
                    ctx.drawLayer { layer in
                        layer.clip(to: moonPath)
                        let cutoutR = r * 1.02
                        let shift = (phaseRatio < 0.5 ? 1.0 : -1.0) * Double(r) * (0.28 + illuminated * 1.9)
                        let cutoutRect = CGRect(x: c.x - cutoutR + CGFloat(shift), y: c.y - cutoutR, width: cutoutR * 2, height: cutoutR * 2)
                        layer.fill(Path(ellipseIn: cutoutRect), with: .color(top))
                    }
                }
            }

            // Clouds (drift with the hour = cheap parallax), fade at night.
            let cloudColor = night > 0.3
                ? Color(red: 0.08, green: 0.07, blue: 0.16).opacity(0.40)
                : Color.white.opacity(0.35 * (1.0 - night))

            for (baseX, baseY, cw, ch) in [(0.44, 0.22, 48.0, 10.0), (0.68, 0.30, 56.0, 11.0)] {
                let cx = (baseX * size.width + CGFloat(hour) * 3).truncatingRemainder(dividingBy: size.width + 80) - 40
                let cy = baseY * size.height
                let rect = CGRect(x: snap(cx), y: snap(cy), width: snap(cw), height: snap(ch))
                ctx.fill(Path(roundedRect: rect, cornerRadius: ch / 2), with: .color(cloudColor))
            }

            // Skyline + windows
            if skyline {
                let n = Self.buildings.count
                let w = size.width / CGFloat(n)
                let lit = DioramaSkyPalette.windowsLit(hour)
                let baseSkylineY = size.height * 0.96
                for (i, bh) in Self.buildings.enumerated() {
                    let bHeight = snap(size.height * skylineHeight * CGFloat(bh) / 0.38)
                    let rect = CGRect(x: snap(CGFloat(i) * w), y: baseSkylineY - bHeight, width: snap(w) + 0.5, height: bHeight + size.height * 0.15)
                    ctx.fill(Path(rect), with: .color(Color(red: 0.07, green: 0.06, blue: 0.13)))
                    if lit {
                        var wy = rect.minY + 4
                        while wy < baseSkylineY - 4 {
                            let wx = rect.minX + w * 0.32
                            ctx.fill(Path(CGRect(x: snap(wx), y: snap(wy), width: pixel ? 3 : 2.2, height: pixel ? 3 : 2.2)),
                                     with: .color(Color(red: 1.0, green: 0.85, blue: 0.45).opacity(0.85)))
                            wy += pixel ? 7 : 6.5
                        }
                    }
                }
            }
        }
    }
}
