import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

// Shared by the opt-in offscreen harnesses (README screenshots, UI gallery):
// rasterising SwiftUI without launching the app, a defaults sandbox, and the
// stylised MacBook top edge the panel is shown against.

@MainActor
enum OffscreenRender {
    /// Renders `view` at `scale` into an 8-bit sRGB bitmap.
    ///
    /// `ImageRenderer.cgImage` picks its own pixel format and switches to
    /// 16-bit extended range (even HDR PQ) as soon as some content asks for
    /// it — the installed terminals' app icons do — and the down-conversion
    /// back to 8 bit is dithered, which put noise on every flat colour and
    /// tripled the file size. Drawing into our own context pins the format.
    ///
    /// ImageRenderer draws no AppKit-backed content (ScrollView, NSScrollView
    /// representables, Form, List); use `hosted` for those.
    static func rasterize<V: View>(_ view: V, scale: CGFloat = 2) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        var result: CGImage?
        renderer.render(rasterizationScale: scale) { size, draw in
            let w = Int((size.width * scale).rounded()), h = Int((size.height * scale).rounded())
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            draw(ctx)
            result = ctx.makeImage()
        }
        return result
    }

    /// Renders `view` the way the app hosts it: an `NSHostingView` filling a
    /// borderless window of `size` that is never ordered on screen. Needed
    /// for scroll views, forms and lists. Transparent where the view draws
    /// nothing; always `scale`× regardless of the screens attached.
    static func hosted<V: View>(
        _ view: V,
        size: CGSize,
        appearance: NSAppearance.Name? = nil,
        styleMask: NSWindow.StyleMask = [.borderless],
        scale: CGFloat = 2,
        passes: Int = 4,
        afterFirstLayout: (() -> Void)? = nil
    ) throws -> CGImage {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        if let appearance { window.appearance = NSAppearance(named: appearance) }
        window.contentView = host
        defer { window.contentView = nil }
        // Measured sizes (the completion reply, the quota chip) feed back
        // into the layout over a couple of update passes.
        for _ in 0..<passes {
            host.layoutSubtreeIfNeeded()
            // Lists and outline views fill their rows on display.
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        }
        // State a live view only shows after a change it observed (the
        // collapsed bar's lingering tool name) is set once it is on screen.
        if let afterFirstLayout {
            afterFirstLayout()
            for _ in 0..<passes {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.12))
            }
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        // Normalise to sRGB like `rasterize`, so both paths compose alike.
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        try drawGlassContent(of: host, into: ctx, scale: scale, dark: appearance == .darkAqua)
        return try XCTUnwrap(ctx.makeImage())
    }

    /// macOS 26 draws a NavigationSplitView sidebar inside an
    /// NSGlassEffectView, whose content `cacheDisplay` skips. Draw what the
    /// glass holds on a flat stand-in for the material.
    private static func drawGlassContent(of host: NSView, into ctx: CGContext, scale: CGFloat, dark: Bool) throws {
        func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
        func name(_ view: NSView) -> String { String(describing: type(of: view)) }
        // Host coordinates are flipped (origin top-left); the context's are not.
        func target(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: host)
            let y = host.isFlipped ? host.bounds.height - rect.maxY : rect.minY
            return CGRect(x: rect.minX * scale, y: y * scale, width: rect.width * scale, height: rect.height * scale)
        }
        func draw(_ view: NSView) throws {
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let rep = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            rep.size = size
            view.cacheDisplay(in: view.bounds, to: rep)
            if let image = rep.cgImage { ctx.draw(image, in: target(view)) }
        }
        for glass in descendants(host).filter({ name($0).contains("GlassEffectView") }) {
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: target(glass).insetBy(dx: 8 * scale, dy: 8 * scale),
                               cornerWidth: 14 * scale, cornerHeight: 14 * scale, transform: nil))
            ctx.setFillColor(dark ? CGColor(gray: 0.22, alpha: 1) : CGColor(gray: 0.98, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
            // Row by row: the list's own cacheDisplay comes back empty inside
            // the glass, its cells' does not.
            for row in descendants(glass) where name(row).contains("TableRowView") && !name(row).contains("Separator") {
                if (row as? NSTableRowView)?.isSelected == true {
                    ctx.saveGState()
                    ctx.addPath(CGPath(roundedRect: target(row).insetBy(dx: 10 * scale, dy: 1 * scale),
                                       cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil))
                    ctx.setFillColor(dark ? CGColor(gray: 1, alpha: 0.12) : CGColor(gray: 0, alpha: 0.08))
                    ctx.fillPath()
                    ctx.restoreGState()
                }
                for cell in descendants(row) where name(cell).hasPrefix("CellHostingView") || name(cell).hasPrefix("NSHostingView") {
                    try draw(cell)
                }
            }
        }
    }

    /// Index of the lowest pixel row holding anything visible.
    static func lastOpaqueRow(_ image: CGImage) -> Int? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.assumingMemoryBound(to: UInt8.self)
        // Bitmap memory starts at the image's top row.
        for y in stride(from: h - 1, through: 0, by: -1) {
            let row = px + y * w * 4
            for x in 0..<w where row[x * 4 + 3] > 4 { return y }
        }
        return nil
    }

    /// `image` cut just below its lowest visible row, rounded to whole points.
    static func trimmedToContent(_ image: CGImage, scale: CGFloat = 2) throws -> (image: CGImage, height: CGFloat) {
        let bottom = try XCTUnwrap(lastOpaqueRow(image), "rendered blank")
        let step = Int(scale)
        let rows = min(image.height, (bottom + step) / step * step)
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: rows)))
        return (cropped, CGFloat(rows) / scale)
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Defaults sandbox

/// Clears settings so every `@AppStorage` falls back to its shipped default,
/// and puts the previous values back afterwards.
struct DefaultsSandbox {
    private let keys: [String]
    private let saved: [String: Any]

    init(keys: [String]) {
        let defaults = UserDefaults.standard
        self.keys = keys
        var saved: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
        self.saved = saved
    }

    func restore() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Every key `SettingsKey` declares (read from Settings.swift, so new
    /// settings are covered without editing this list), the per-shortcut and
    /// per-CLI keys, and the config-dir preferences — everything a rendered
    /// view may read. Test runs from every checkout share one defaults domain
    /// (`com.apple.dt.xctest.tool`), so a key left out here can carry another
    /// run's value into a render.
    static var allSettingsKeys: [String] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeIsland/Settings.swift")
        var keys = panelKeys
        if let text = try? String(contentsOf: source, encoding: .utf8),
           let start = text.range(of: "enum SettingsKey {"),
           let end = text.range(of: "\n}", range: start.upperBound..<text.endIndex),
           let regex = try? NSRegularExpression(pattern: #"static let \w+ = "([^"]+)""#) {
            let body = String(text[start.upperBound..<end.lowerBound])
            for match in regex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let r = Range(match.range(at: 1), in: body) { keys.append(String(body[r])) }
            }
        }
        keys += ConfigInstaller.allCLIs.map { "cli_enabled_\($0.source)" }
        keys += ["cli_enabled_opencode", "cli_enabled_mimo", "cli_enabled_aiwork", "cli_enabled_aiwork-cli",
                 ClaudeConfigPaths.preferenceKey, ExtraConfigDirs.preferenceKey, SessionSnapshot.customCLIConfigsKey]
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    /// Every settings key the notch panel reads.
    static var panelKeys: [String] {
        [
            SettingsKey.appLanguage, SettingsKey.contentFontSize, SettingsKey.showAgentDetails,
            SettingsKey.smartSuppress, SettingsKey.hideWhenNoSession, SettingsKey.showToolStatus,
            SettingsKey.collapsedWidthScale, SettingsKey.hapticOnHover, SettingsKey.hapticIntensity,
            SettingsKey.sessionGroupingMode, SettingsKey.defaultSource, SettingsKey.soundEnabled,
            SettingsKey.quietHoursEnabled, SettingsKey.quietHoursStart, SettingsKey.quietHoursEnd,
            SettingsKey.autoCollapseAfterSessionJump, SettingsKey.maxVisibleSessions,
            SettingsKey.showUsageStats, SettingsKey.showClaudeQuota, SettingsKey.showGitBranch,
            SettingsKey.aiMessageLines, SettingsKey.mascotSpeed, SettingsKey.notchHeightMode,
            SettingsKey.customNotchHeight, SettingsKey.collapseOnMouseLeave, SettingsKey.maxToolHistory,
            SettingsKey.showSessionRecap, SettingsKey.showModelLabel, SettingsKey.showTaskProgress,
            SettingsKey.showProjectName, SettingsKey.autoExpandOnQuestion, SettingsKey.followUpReminderMinutes,
        ] + ShortcutAction.allCases.flatMap { action in
            [
                SettingsKey.shortcutEnabled(action.rawValue),
                SettingsKey.shortcutKeyCode(action.rawValue),
                SettingsKey.shortcutModifiers(action.rawValue),
            ]
        }
    }
}

// MARK: - Stage (stylised MacBook top edge)

/// A display the panel is shown on.
struct StageScreen {
    let name: String
    let screenWidth: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let hasNotch: Bool

    /// 14" MacBook Pro at its default 1512×982pt resolution.
    static let macBook14 = StageScreen(name: "14in", screenWidth: 1512, notchWidth: 185, notchHeight: 32, hasNotch: true)
    /// 16" MacBook Pro at its default 1728×1117pt resolution (taller safe area).
    static let macBook16 = StageScreen(name: "16in", screenWidth: 1728, notchWidth: 185, notchHeight: 37, hasNotch: true)
    /// 1920pt external display: 25pt menu bar, simulated notch width
    /// (ScreenDetector.fakeNotchWidth: min(max(w × 0.14, 160), 240)).
    static let external = StageScreen(name: "external", screenWidth: 1920, notchWidth: 240, notchHeight: 25, hasNotch: false)

    /// PanelWindowController.panelSize: min(620, screenWidth - 40).
    var windowWidth: CGFloat { min(620, screenWidth - 40) }
}

enum StageWallpaper {
    case dark, light
}

enum StageGeometry {
    static let bezelHeight: CGFloat = 10
    static let cornerRadius: CGFloat = 20
}

struct StageLayout {
    let width: CGFloat
    let bottomMargin: CGFloat
    let menuItems: Bool
}

/// The panel image composited onto a stylised MacBook top edge.
struct Stage: View {
    let panel: CGImage
    let panelHeight: CGFloat
    let layout: StageLayout
    var screen: StageScreen = .macBook14
    var wallpaper: StageWallpaper = .dark
    /// Clock text for the menu bar ("Tue 9:41").
    var clock: String = "Tue 9:41"

    private var height: CGFloat {
        StageGeometry.bezelHeight + panelHeight + layout.bottomMargin
    }

    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper(size: CGSize(width: layout.width, height: height), style: wallpaper)
            VStack(spacing: 0) {
                Bezel()
                    .frame(height: StageGeometry.bezelHeight)
                ZStack(alignment: .top) {
                    MenuBarStrip(clock: clock, showItems: layout.menuItems, height: screen.notchHeight, light: wallpaper == .light)
                    if screen.hasNotch {
                        PhysicalNotch()
                            .fill(Color.black)
                            .frame(width: screen.notchWidth, height: screen.notchHeight)
                    }
                    Image(decorative: panel, scale: 2)
                        .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 14)
                        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: layout.width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: StageGeometry.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

private func rgb(_ hex: UInt32) -> Color {
    Color(
        red: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255
    )
}

/// Dark indigo → purple → teal (or a pale daylight variant) with a few soft
/// glows, rasterised by hand.
///
/// SwiftUI/CoreGraphics gradients are dithered, and that per-pixel noise
/// alone tripled the PNG size. Computing the gradient directly keeps it
/// smooth, so the image stays truecolour yet compresses well.
struct Wallpaper: View {
    let size: CGSize
    var style: StageWallpaper = .dark

    var body: some View {
        if let image = Self.raster(size: size, scale: 2, style: style) {
            Image(decorative: image, scale: 2)
        }
    }

    private struct RGB {
        var r: Float, g: Float, b: Float
        init(_ hex: UInt32) {
            r = Float((hex >> 16) & 0xFF) / 255
            g = Float((hex >> 8) & 0xFF) / 255
            b = Float(hex & 0xFF) / 255
        }
        func mixed(with o: RGB, _ t: Float) -> RGB {
            var c = self
            c.r += (o.r - r) * t; c.g += (o.g - g) * t; c.b += (o.b - b) * t
            return c
        }
    }

    private struct Glow {
        let x: Float, y: Float, radius: Float, color: RGB, alpha: Float
    }

    static func raster(size: CGSize, scale: CGFloat, style: StageWallpaper = .dark) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let fw = Float(w), fh = Float(h), longest = max(fw, fh)
        let stops: [RGB]
        let glows: [Glow]
        switch style {
        case .dark:
            stops = [RGB(0x1B1845), RGB(0x34205F), RGB(0x15405A)]
            glows = [
                Glow(x: 0.03, y: 1.00, radius: 0.62, color: RGB(0x2FB5A6), alpha: 0.55),
                Glow(x: 0.97, y: 0.06, radius: 0.58, color: RGB(0xA35BE8), alpha: 0.46),
                Glow(x: 0.52, y: 0.95, radius: 0.46, color: RGB(0x5B7CFA), alpha: 0.26),
            ]
        case .light:
            stops = [RGB(0xEEF1F8), RGB(0xF7ECE2), RGB(0xE1F1F0)]
            glows = [
                Glow(x: 0.03, y: 1.00, radius: 0.62, color: RGB(0xB9E6DF), alpha: 0.55),
                Glow(x: 0.97, y: 0.06, radius: 0.58, color: RGB(0xF1D3E8), alpha: 0.50),
                Glow(x: 0.52, y: 0.95, radius: 0.46, color: RGB(0xCAD6FB), alpha: 0.30),
            ]
        }
        let diag = fw * fw + fh * fh
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let py = Float(y) + 0.5
            for x in 0..<w {
                let px = Float(x) + 0.5
                // topLeading → bottomTrailing, like LinearGradient on the rect
                let t = min(max((px * fw + py * fh) / diag, 0), 1)
                var c = t < 0.5 ? stops[0].mixed(with: stops[1], t * 2) : stops[1].mixed(with: stops[2], t * 2 - 1)
                for g in glows {
                    let dx = px - g.x * fw, dy = py - g.y * fh
                    let s = min((dx * dx + dy * dy).squareRoot() / (g.radius * longest), 1)
                    let falloff = 1 - s * s * (3 - 2 * s)  // smoothstep
                    c = c.mixed(with: g.color, g.alpha * falloff)
                }
                let i = (y * w + x) * 4
                pixels[i] = UInt8(min(max(c.r * 255, 0), 255).rounded())
                pixels[i + 1] = UInt8(min(max(c.g * 255, 0), 255).rounded())
                pixels[i + 2] = UInt8(min(max(c.b * 255, 0), 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// The display's top bezel: near-black with a faint lid-edge highlight.
struct Bezel: View {
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(rgb(0x060607))
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
        }
    }
}

/// Translucent menu bar with a few stand-in items at the crop edges.
struct MenuBarStrip: View {
    let clock: String
    let showItems: Bool
    var height: CGFloat = 32
    var light = false

    var body: some View {
        ZStack {
            Rectangle().fill(light ? Color.white.opacity(0.45) : Color.black.opacity(0.30))
            if showItems {
                HStack(spacing: 0) {
                    HStack(spacing: 18) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Ghostty")
                            .font(.system(size: 13, weight: .bold))
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 15) {
                        Image(systemName: "wifi")
                            .font(.system(size: 13, weight: .semibold))
                        Text(clock)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .padding(.horizontal, 20)
                .foregroundStyle(light ? Color.black.opacity(0.85) : Color.white.opacity(0.92))
            }
        }
        .frame(height: height)
    }
}

/// Notch cut-out: rounded bottom corners plus the small concave flares where
/// it meets the bezel. Sits under the panel, which grows out of it.
struct PhysicalNotch: Shape {
    func path(in rect: CGRect) -> Path {
        let flare: CGFloat = 4
        let radius: CGFloat = 10
        var p = Path()
        p.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + flare), control: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + flare))
        p.addQuadCurve(to: CGPoint(x: rect.minX - flare, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Demo requests

/// Pending hook requests for demo states: the continuations are resumed on
/// `release` so no task is left hanging.
@MainActor
enum DemoRequests {
    static func hookEvent(_ payload: [String: Any]) throws -> HookEvent {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(HookEvent(from: data), "HookEvent parse failed")
    }

    /// Queues a permission request on `state` and returns its release.
    static func enqueuePermission(_ state: AppState, event: HookEvent) async -> () -> Void {
        let before = state.permissionQueue.count
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                state.permissionQueue.append(PermissionRequest(event: event, continuation: continuation))
            }
        }
        await waitUntil { state.permissionQueue.count > before }
        return {
            for request in state.permissionQueue { request.continuation.resume(returning: Data()) }
            state.permissionQueue.removeAll()
            _ = task
        }
    }

    /// Queues an AskUserQuestion request (as AppState.handleAskUserQuestion
    /// builds it) and returns its release.
    static func enqueueQuestion(
        _ state: AppState,
        sessionId: String,
        cwd: String,
        items: [(question: String, header: String?, options: [(String, String?)], multiSelect: Bool)]
    ) async throws -> () -> Void {
        let event = try hookEvent([
            "hook_event_name": "PermissionRequest",
            "session_id": sessionId,
            "cwd": cwd,
            "tool_name": "AskUserQuestion",
            "tool_input": [
                "questions": items.map { item -> [String: Any] in
                    var q: [String: Any] = [
                        "question": item.question,
                        "multiSelect": item.multiSelect,
                        "options": item.options.map { ["label": $0.0, "description": $0.1 ?? ""] },
                    ]
                    if let header = item.header { q["header"] = header }
                    return q
                },
            ],
        ])
        let built = items.map { item -> AskUserQuestionItem in
            let payload = QuestionPayload(
                question: item.question,
                options: item.options.isEmpty ? nil : item.options.map(\.0),
                descriptions: item.options.isEmpty ? nil : item.options.map { $0.1 ?? "" },
                header: item.header
            )
            return AskUserQuestionItem(payload: payload, answerKey: item.question, multiSelect: item.multiSelect)
        }
        let first = try XCTUnwrap(built.first).payload
        return await enqueueQuestion(state, event: event, payload: first,
                                     askState: AskUserQuestionState(items: built, answers: [:]))
    }

    /// Queues a question request with an explicit payload (nil `askState`
    /// for the legacy Notification-style question) and returns its release.
    static func enqueueQuestion(
        _ state: AppState,
        event: HookEvent,
        payload: QuestionPayload,
        askState: AskUserQuestionState?
    ) async -> () -> Void {
        let before = state.questionQueue.count
        let task = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                state.questionQueue.append(QuestionRequest(
                    event: event,
                    question: payload,
                    continuation: continuation,
                    isFromPermission: askState != nil,
                    askUserQuestionState: askState
                ))
            }
        }
        await waitUntil { state.questionQueue.count > before }
        return {
            for request in state.questionQueue { request.resolution.resumeHook(returning: Data()) }
            state.questionQueue.removeAll()
            _ = task
        }
    }
}
