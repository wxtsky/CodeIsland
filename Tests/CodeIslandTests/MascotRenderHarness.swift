import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import CodeIsland

/// Offscreen render harness for mascot animation review (#15).
///
/// Not a pass/fail test of pixels — it renders each mascot's scenes at a
/// series of timeline instants into contact-sheet PNGs so animation changes
/// can be reviewed without launching the app. Sheets land in
/// `$MASCOT_SHEET_DIR` (skipped entirely when the variable is unset, so CI
/// never pays for it).
@MainActor
final class MascotRenderHarness: XCTestCase {

    /// One-frame icon export for cli-icons assets: renders each source's
    /// mascot at a fixed instant on a transparent background. Opt-in like the
    /// contact sheets (`MASCOT_ICON_DIR` + `MASCOT_ICON_SOURCES=kiro,openclaw`).
    func testRenderCliIcons() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_ICON_DIR"] else {
            throw XCTSkip("MASCOT_ICON_DIR not set — harness is opt-in")
        }
        let sources = (ProcessInfo.processInfo.environment["MASCOT_ICON_SOURCES"] ?? "kiro,openclaw")
            .split(separator: ",").map(String.init)
        let status: MascotAgentStatus = switch ProcessInfo.processInfo.environment["MASCOT_ICON_STATUS"] {
        case "idle": .idle
        case "waitingApproval": .waitingApproval
        case "waitingQuestion": .waitingQuestion
        default: .processing
        }
        let time = Double(ProcessInfo.processInfo.environment["MASCOT_ICON_TIME"] ?? "") ?? 0.0

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for source in sources {
            let icon = MascotIconFrame(source: source, status: status, time: time)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 2  // 64pt frame → 128px asset
            guard let cgImage = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            else {
                XCTFail("icon render failed for \(source)"); continue
            }
            try png.write(to: URL(fileURLWithPath: "\(outDir)/\(source).png"))
        }
    }

    func testRenderContactSheets() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_SHEET_DIR"] else {
            throw XCTSkip("MASCOT_SHEET_DIR not set — harness is opt-in")
        }
        let sources = (ProcessInfo.processInfo.environment["MASCOT_SHEET_SOURCES"] ?? "claude,codex")
            .split(separator: ",").map(String.init)
        let statuses: [(String, MascotAgentStatus)] = [
            ("idle", .idle),
            ("processing", .processing),
            ("waitingApproval", .waitingApproval),
            ("waitingQuestion", .waitingQuestion),
        ]
        // Sample instants chosen to catch blink/quirk windows, not just phase 0.
        let times: [Double] = [0.0, 0.6, 1.3, 2.1, 2.9, 3.6, 4.4, 5.2, 6.1, 7.0, 7.8, 8.5]

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for source in sources {
            for (label, status) in statuses {
                let sheet = MascotContactSheet(source: source, status: status, times: times)
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 4  // 4x for crisp pixel inspection
                guard let cgImage = renderer.cgImage else {
                    XCTFail("render failed for \(source)/\(label)"); continue
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("png encode failed for \(source)/\(label)"); continue
                }
                let path = "\(outDir)/\(source)-\(label).png"
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Animated mascot GIFs for the README "Supported Tools" table: one
    /// seamless working-state loop per distinct mascot, on a transparent
    /// background, all on the same square canvas. Opt-in like the sheets:
    /// `MASCOT_GIF_DIR=docs/images/mascots` (+ optional
    /// `MASCOT_GIF_SOURCES=claude,kiro` to limit to some file names).
    func testRenderReadmeGifs() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_GIF_DIR"] else {
            throw XCTSkip("MASCOT_GIF_DIR not set — harness is opt-in")
        }
        let only = ProcessInfo.processInfo.environment["MASCOT_GIF_SOURCES"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for spec in ReadmeGifSpec.all where only?.contains(spec.name) ?? true {
            let t0 = try XCTUnwrap(spec.loopStart(), "no calm \(spec.period)s window for \(spec.name)")
            var frames: [[UInt8]] = []
            for k in 0..<spec.frames {
                let t = t0 + spec.period * Double(k) / Double(spec.frames)
                let frame = MascotGifFrame(spec: spec, time: t)
                guard var pixels = ReadmeGif.rasterize(frame, size: Int(spec.viewSize)) else {
                    XCTFail("render failed for \(spec.name) @ \(t)"); break
                }
                if spec.contour { ReadmeGif.addContour(&pixels, size: Int(spec.viewSize)) }
                frames.append(pixels)
            }
            guard frames.count == spec.frames else { continue }
            let images = try ReadmeGif.centerOnCanvas(frames, size: Int(spec.viewSize), name: spec.name)
            let url = URL(fileURLWithPath: "\(outDir)/\(spec.name).gif")
            try ReadmeGif.writeGif(images, delays: spec.delays, to: url)
        }
    }
}

// MARK: - README GIF export

/// One README GIF: which mascot, which scene, and how to loop it.
private struct ReadmeGifSpec {
    /// Output file name (`<name>.gif`) — the key the README links.
    let name: String
    /// Routing key for `routedMascot` (e.g. Factory's mascot is `droid`).
    let source: String
    var status: MascotAgentStatus = .processing
    /// Loop length in seconds: a common multiple of the scene's periodic
    /// motions (bounce, key sweep…) so the last frame flows into the first.
    let period: Double
    let frames: Int
    /// Mascot frame side in points (rendered 1pt = 1px). Chosen as the scene
    /// viewport's unit count × a whole number so the art sits on an integer
    /// pixel grid: 16-unit viewports × 7 → 112; Kiro's 14-unit one × 8 → 112
    /// (the keyboard-less ghost would look undersized at 7).
    var viewSize: CGFloat = 112
    /// White / near-white silhouettes (Codex's cloud, Kiro's ghost, Grok's
    /// mark) would vanish on a light page: give their light edges a dark
    /// contour, which disappears again on a dark page.
    var contour = false
    /// False at instants holding a one-off beat (blink, thinking pause,
    /// signal flash) that would stutter if replayed every loop.
    var isCalm: (Double) -> Bool = { _ in true }
    /// Extra constraint on the loop's start instant, for secondary motions
    /// whose period doesn't divide `period` (keeps their seam jump invisible).
    var startOK: (Double) -> Bool = { _ in true }

    /// Per-frame GIF delays (seconds, centisecond-quantised with error
    /// carried forward so the loop keeps its exact length).
    var delays: [Double] {
        (0..<frames).map { k in
            let a = (period * Double(k) / Double(frames) * 100).rounded()
            let b = (period * Double(k + 1) / Double(frames) * 100).rounded()
            return (b - a) / 100
        }
    }

    /// First start instant (on a 50 ms grid) whose sampled frames are all calm.
    func loopStart() -> Double? {
        for step in 0..<4000 {
            let t0 = Double(step) * 0.05
            guard startOK(t0) else { continue }
            let calm = (0..<frames).allSatisfy { k in
                isCalm(t0 + period * Double(k) / Double(frames))
            }
            if calm { return t0 }
        }
        return nil
    }

    /// Calm = eyes fully open and outside the mascot's work-pause quirk.
    /// Seeds/cycles mirror the mascot's `workCanvas`.
    static func calm(blinkSeed: UInt64?, pause: (cycle: Double, duration: Double, seed: UInt64)?)
        -> (Double) -> Bool {
        { t in
            if let blinkSeed, MascotMotion.blink(t, seed: blinkSeed) < 0.999 { return false }
            if let pause, MascotMotion.quirk(t, cycle: pause.cycle, duration: pause.duration, seed: pause.seed) > 0 {
                return false
            }
            return true
        }
    }

    /// True when `t`'s phase within `cycle` falls inside `window` (fractions).
    static func phase(_ t: Double, cycle: Double, in window: ClosedRange<Double>) -> Bool {
        window.contains(t.truncatingRemainder(dividingBy: cycle) / cycle)
    }

    /// Every distinct mascot, named by its README key. Aliases that share a
    /// mascot (cursor-cli, qoder-cli/qoderwork, traecn/traecli, codybuddycn,
    /// google-antigravity → Gemini, omp → Pi, aiwork-cli, dsh/zcode → Clawd)
    /// get no GIF of their own.
    static let all: [ReadmeGifSpec] = [
        // Clawd: 0.35s bounce ×3; typing arms are stroke-randomised anyway.
        ReadmeGifSpec(name: "claude", source: "claude", period: 1.05, frames: 15,
                      isCalm: { t in
                          let scan = t.truncatingRemainder(dividingBy: 10.0)
                          return !(scan > 5.6 && scan < 7.0)
                              && calm(blinkSeed: 0xB1, pause: (11.0, 1.4, 0x7A9))(t)
                      }),
        // Shared keyboard template: 0.4s bounce × 0.6s key sweep → 1.2s.
        ReadmeGifSpec(name: "codex", source: "codex", period: 1.2, frames: 15, contour: true,
                      isCalm: calm(blinkSeed: nil, pause: (12.0, 1.2, 0xDE2))),
        ReadmeGifSpec(name: "gemini", source: "gemini", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x40E, pause: (12.9, 1.2, 0x40D))),
        // Shimmer (1.5s) doesn't divide 1.2s: start where it reads the same
        // at both ends of the loop (phase .35 / .85).
        ReadmeGifSpec(name: "cursor", source: "cursor", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xE2F, pause: (11.0, 1.2, 0xE2E)),
                      startOK: { phase($0, cycle: 1.5, in: 0.33...0.37) || phase($0, cycle: 1.5, in: 0.83...0.87) }),
        ReadmeGifSpec(name: "trae", source: "trae", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x9C8, pause: (12.9, 1.2, 0x9C7))),
        // Copilot's blink (3.2s) and ear signal (2.5s) are fixed windows.
        ReadmeGifSpec(name: "copilot", source: "copilot", period: 1.2, frames: 15,
                      isCalm: { t in
                          !phase(t, cycle: 3.2, in: (1.45 / 3.2)...(1.65 / 3.2))
                              && !phase(t, cycle: 2.5, in: (1.95 / 2.5)...(2.35 / 2.5))
                              && calm(blinkSeed: nil, pause: (11.6, 1.2, 0x8F8))(t)
                      }),
        ReadmeGifSpec(name: "qoder", source: "qoder", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x1BD, pause: (11.4, 1.2, 0x1BC))),
        // Droid: 0.5s bounce ×2 (its 0.12s key sweep just restarts a row).
        ReadmeGifSpec(name: "factory", source: "droid", period: 1.0, frames: 12,
                      isCalm: calm(blinkSeed: 0x297, pause: (10.6, 1.2, 0x296))),
        ReadmeGifSpec(name: "codebuddy", source: "codebuddy", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x132, pause: (10.2, 1.2, 0x131))),
        ReadmeGifSpec(name: "stepfun", source: "stepfun", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x100E, pause: (12.6, 1.2, 0x100D))),
        ReadmeGifSpec(name: "opencode", source: "opencode", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xC89, pause: (11.1, 1.2, 0xC88))),
        ReadmeGifSpec(name: "qwen", source: "qwen", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x7F6, pause: (9.6, 1.2, 0x7F5))),
        ReadmeGifSpec(name: "antigravity", source: "antigravity", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xAEF, pause: (11.6, 1.2, 0xAEE))),
        ReadmeGifSpec(name: "workbuddy", source: "workbuddy", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x89F, pause: (12.3, 1.2, 0x89E))),
        ReadmeGifSpec(name: "hermes", source: "hermes", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xCDD, pause: (11.3, 1.2, 0xCDC))),
        ReadmeGifSpec(name: "kimi", source: "kimi", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x35F, pause: (10.8, 1.2, 0x35E))),
        // AiWork's caret pulses every 0.9s: start in its dark half so the
        // loop seam lands while it's off at both ends.
        ReadmeGifSpec(name: "aiwork", source: "aiwork", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xD7C2, pause: (10.7, 1.2, 0xD7C1)),
                      startOK: { phase($0, cycle: 0.9, in: 0.5...0.66) }),
        // Cline: 0.5s bounce ×2.
        ReadmeGifSpec(name: "cline", source: "cline", period: 1.0, frames: 12,
                      isCalm: calm(blinkSeed: 0xFE3, pause: (11.1, 1.2, 0xFE2))),
        // 0.42s bounce ×3.
        ReadmeGifSpec(name: "openclaw", source: "openclaw", period: 1.26, frames: 15,
                      isCalm: calm(blinkSeed: 0xC1A7, pause: (10.5, 1.2, 0xC1A4))),
        ReadmeGifSpec(name: "pi", source: "pi", period: 1.26, frames: 15,
                      isCalm: calm(blinkSeed: 0x9BB, pause: nil)),
        // Kiro: 0.45s hover-bob ×4 on a 14-unit viewport.
        ReadmeGifSpec(name: "kiro", source: "kiro", period: 1.8, frames: 20, viewSize: 112, contour: true,
                      isCalm: calm(blinkSeed: 0x419C, pause: (11.5, 1.2, 0x419B))),
        // Grok's mark is deliberately static — a single frame. Vector art, so
        // no unit grid: sized to match the others' visual weight.
        ReadmeGifSpec(name: "grok", source: "grok", period: 1.0, frames: 1, viewSize: 132, contour: true),
    ]
}

/// A mascot pinned to one timeline instant, sized for GIF export.
private struct MascotGifFrame: View {
    let spec: ReadmeGifSpec
    let time: Double

    var body: some View {
        MascotContactSheet.routedMascot(source: spec.source, status: spec.status, size: spec.viewSize)
            .environment(\.mascotAnimationsActive, false)
            .environment(\.mascotStaticTime, time)
            .frame(width: spec.viewSize, height: spec.viewSize)
    }
}

private enum ReadmeGif {
    /// Uniform output canvas (px) for every README GIF.
    static let canvas = 128
    /// Supersampling factor; each output pixel takes the sample nearest its
    /// centre, i.e. aliased point sampling — hard edges, no AA fringe.
    static let supersample = 4

    /// Renders `view` (a `size`×`size` pt frame) and returns straight-alpha
    /// RGBA8 at `size`×`size` px with alpha forced to 0 or 255 — GIF
    /// transparency is 1-bit, and point sampling + un-premultiplying keeps
    /// edge pixels from turning into a dark halo. Soft drop shadows (< 50%
    /// alpha) fall away, which is what we want on arbitrary page colours.
    @MainActor
    static func rasterize<V: View>(_ view: V, size: Int) -> [UInt8]? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(supersample)
        guard let cg = renderer.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = ctx.data else { return nil }
        let hi = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = ctx.bytesPerRow

        var out = [UInt8](repeating: 0, count: size * size * 4)
        let maxX = cg.width - 1, maxY = cg.height - 1
        for y in 0..<size {
            for x in 0..<size {
                let sx = min(maxX, x * supersample + supersample / 2)
                let sy = min(maxY, y * supersample + supersample / 2)
                let i = sy * rowBytes + sx * 4
                let a = Int(hi[i + 3])
                guard a >= 128 else { continue }
                let o = (y * size + x) * 4
                for c in 0..<3 {
                    out[o + c] = UInt8(min(255, (Int(hi[i + c]) * 255 + a / 2) / a))
                }
                out[o + 3] = 255
            }
        }
        return out
    }

    /// Paints transparent pixels within `radius` px of a light opaque pixel
    /// (luma ≥ 0.5) in near-black. Keyed on light pixels only, so dark parts
    /// such as the keyboard keep their exact size.
    static func addContour(_ f: inout [UInt8], size: Int, radius: Int = 3) {
        var light = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) where f[i * 4 + 3] != 0 {
            let luma = 0.2126 * Double(f[i * 4]) + 0.7152 * Double(f[i * 4 + 1]) + 0.0722 * Double(f[i * 4 + 2])
            light[i] = luma >= 128
        }
        let src = f
        for y in 0..<size {
            for x in 0..<size where src[(y * size + x) * 4 + 3] == 0 {
                var near = false
                search: for oy in -radius...radius {
                    for ox in -radius...radius where ox * ox + oy * oy <= radius * radius {
                        let nx = x + ox, ny = y + oy
                        if nx >= 0, nx < size, ny >= 0, ny < size, light[ny * size + nx] {
                            near = true; break search
                        }
                    }
                }
                if near {
                    let o = (y * size + x) * 4
                    f[o] = 0x14; f[o + 1] = 0x16; f[o + 2] = 0x1A; f[o + 3] = 255
                }
            }
        }
    }

    /// Centres the union of all frames' opaque pixels on the shared canvas
    /// (whole-pixel shift, so nothing resamples) and returns CGImages.
    static func centerOnCanvas(_ frames: [[UInt8]], size: Int, name: String) throws -> [CGImage] {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for f in frames {
            for y in 0..<size {
                for x in 0..<size where f[(y * size + x) * 4 + 3] != 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX else { throw GifError.blank(name) }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        guard bw <= canvas, bh <= canvas else { throw GifError.tooBig(name, bw, bh) }
        let dx = (canvas - bw) / 2 - minX, dy = (canvas - bh) / 2 - minY

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw GifError.encode(name) }
        return try frames.map { f in
            var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
            for y in minY...maxY {
                for x in minX...maxX {
                    let s = (y * size + x) * 4, d = ((y + dy) * canvas + (x + dx)) * 4
                    px[d..<(d + 4)] = f[s..<(s + 4)]
                }
            }
            // Alpha is 0/255 with RGB zeroed under 0, so straight == premultiplied.
            guard let provider = CGDataProvider(data: Data(px) as CFData),
                  let image = CGImage(width: canvas, height: canvas, bitsPerComponent: 8,
                                      bitsPerPixel: 32, bytesPerRow: canvas * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent)
            else { throw GifError.encode(name) }
            return image
        }
    }

    /// Infinite-loop GIF via ImageIO.
    static func writeGif(_ images: [CGImage], delays: [Double], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, images.count, nil)
        else { throw GifError.encode(url.lastPathComponent) }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (image, delay) in zip(images, delays) {
            CGImageDestinationAddImage(dest, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw GifError.encode(url.lastPathComponent) }
    }

    enum GifError: Error {
        case blank(String)
        case tooBig(String, Int, Int)
        case encode(String)
    }
}

/// Single transparent-background frame sized for a cli-icons asset.
private struct MascotIconFrame: View {
    let source: String
    let status: MascotAgentStatus
    let time: Double

    var body: some View {
        MascotContactSheet.routedMascot(source: source, status: status, size: 58)
            .environment(\.mascotAnimationsActive, false)
            .environment(\.mascotStaticTime, time)
            .frame(width: 64, height: 64)
    }
}

/// One row of frames for a (source, status) pair, each frame rendered at a
/// fixed timeline instant via the static-frame path of MascotTimeline
/// (mascotAnimationsActive=false renders content(mascotStaticTime) once).
private struct MascotContactSheet: View {
    let source: String
    let status: MascotAgentStatus
    let times: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(times, id: \.self) { t in
                VStack(spacing: 2) {
                    mascot
                        .environment(\.mascotAnimationsActive, false)
                        .environment(\.mascotStaticTime, t)
                        .frame(width: 64, height: 64)
                        .background(Color.black)
                    Text(String(format: "%.1f", t))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(6)
        .background(Color.black)
    }

    /// Direct routing (bypasses MascotView, which re-injects the live gate).
    private var mascot: some View {
        Self.routedMascot(source: source, status: status, size: 54)
    }

    @ViewBuilder
    static func routedMascot(source: String, status: MascotAgentStatus, size: CGFloat) -> some View {
        switch source {
        case "codex": DexView(status: status, size: size)
        case "grok": GrokView(status: status, size: size)
        case "gemini": GeminiView(status: status, size: size)
        case "cursor": CursorView(status: status, size: size)
        case "trae": TraeView(status: status, size: size)
        case "copilot": CopilotView(status: status, size: size)
        case "qoder": QoderView(status: status, size: size)
        case "droid": DroidView(status: status, size: size)
        case "codebuddy": BuddyView(status: status, size: size)
        case "stepfun": StepFunView(status: status, size: size)
        case "opencode": OpenCodeView(status: status, size: size)
        case "qwen": QwenView(status: status, size: size)
        case "antigravity": AntiGravityView(status: status, size: size)
        case "workbuddy": WorkBuddyView(status: status, size: size)
        case "hermes": HermesView(status: status, size: size)
        case "openclaw": OpenClawView(status: status, size: size)
        case "kiro": KiroView(status: status, size: size)
        case "kimi": KimiView(status: status, size: size)
        case "pi": PiView(status: status, size: size)
        case "cline": ClineView(status: status, size: size)
        case "aiwork", "aiwork-cli": AiWorkView(status: status, size: size)
        case "minimax": MinimaxView(status: status, size: size)
        default: ClawdView(status: status, size: size)
        }
    }
}
