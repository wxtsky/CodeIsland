import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

final class QuotaChipLayoutTests: XCTestCase {
    // 14" MacBook Pro-ish: 27pt mascot → 41pt wings, ~185pt notch.
    private let mascot: CGFloat = 27
    private var wing: CGFloat { mascot + 14 }
    private let notch: CGFloat = 185

    /// Lays the collapsed bar out the way the view does — centred on the notch,
    /// then offset by `shift` — and returns where things land (0 = notch centre).
    private func geometry(chip: CGFloat, statusExtra: CGFloat)
        -> (chipTail: CGFloat, notchLeft: CGFloat, rightEdge: CGFloat, baseRightEdge: CGFloat) {
        let r = QuotaChipLayout.reserve(chipWidth: chip, mascotSize: mascot, wing: wing,
                                        statusExtra: statusExtra, hasNotch: true)
        let base = notch + wing * 2 + statusExtra
        let width = base + r.extraWidth
        let leftEdge = -width / 2 + r.shift
        let chipTail = leftEdge + QuotaChipLayout.wingLeading + mascot + QuotaChipLayout.wingSpacing + chip
        return (chipTail, -notch / 2, width / 2 + r.shift, base / 2)
    }

    func testChipNeverReachesTheNotchAndTheRightWingStaysPut() {
        // Idle / working, tool status off / on (≈3% of a 1512pt screen), chip
        // from a short "5h 3%" to a long model-scoped label.
        for statusExtra: CGFloat in [0, 20, 45, 65] {
            for chip: CGFloat in [40, 60, 90, 130] {
                let g = geometry(chip: chip, statusExtra: statusExtra)
                XCTAssertLessThanOrEqual(g.chipTail + QuotaChipLayout.notchGap, g.notchLeft + 0.001,
                                         "chip \(chip) with status extra \(statusExtra) slides under the notch")
                XCTAssertEqual(g.rightEdge, g.baseRightEdge, accuracy: 0.001,
                               "the right wing must not move — nothing is spent on symmetry")
            }
        }
    }

    func testReserveIsOnlyTheMissingWidth() {
        // Needed: 6 + 27 + 6 + 90 + 4 = 133; room: 41 + 45/2 = 63.5 → 69.5 short.
        let r = QuotaChipLayout.reserve(chipWidth: 90, mascotSize: mascot, wing: wing, statusExtra: 45, hasNotch: true)
        XCTAssertEqual(r.extraWidth, 69.5, accuracy: 0.001)
        XCTAssertEqual(r.shift, -34.75, accuracy: 0.001)
    }

    func testChipThatFitsChangesNothing() {
        // Needed: 6 + 27 + 6 + 10 + 4 = 53; room: 41 + 40/2 = 61.
        XCTAssertEqual(
            QuotaChipLayout.reserve(chipWidth: 10, mascotSize: mascot, wing: wing, statusExtra: 40, hasNotch: true),
            .none
        )
    }

    func testLeftEdgeDoesNotMoveWithStatusReserveOnceTheChipDominates() {
        // Idle → working adds 20pt of status reserve. With the chip already the
        // widest thing on the left, only the right half grows (as on main); the
        // left edge, and the chip with it, must not jump.
        func leftEdge(_ statusExtra: CGFloat) -> CGFloat {
            let r = QuotaChipLayout.reserve(chipWidth: 90, mascotSize: mascot, wing: wing, statusExtra: statusExtra, hasNotch: true)
            return -(notch + wing * 2 + statusExtra + r.extraWidth) / 2 + r.shift
        }
        XCTAssertEqual(leftEdge(45), leftEdge(65), accuracy: 0.001)
    }

    func testNonNotchScreensOnlyAddTheChipWidthAndNeverShift() {
        let r = QuotaChipLayout.reserve(chipWidth: 60, mascotSize: mascot, wing: wing, statusExtra: 65, hasNotch: false)
        XCTAssertEqual(r, QuotaChipLayout.Reserve(extraWidth: 60 + QuotaChipLayout.wingSpacing, shift: 0))
    }

    func testNonNotchReserveStopsAtThePanelWindow() {
        // A 2560pt external display at 150%, working, tool status on: the bar
        // is already ~548pt of the 620pt window, so a 90pt chip only gets the
        // rest — the centre tool status gives up the difference.
        let r = QuotaChipLayout.reserve(chipWidth: 90, mascotSize: 19, wing: 33, statusExtra: 122, hasNotch: false, spareWidth: 72)
        XCTAssertEqual(r, QuotaChipLayout.Reserve(extraWidth: 72, shift: 0))
        let full = QuotaChipLayout.reserve(chipWidth: 90, mascotSize: 19, wing: 33, statusExtra: 122, hasNotch: false, spareWidth: -3)
        XCTAssertEqual(full, .none)
    }

    // MARK: - Chip content

    func testLongModelNameIsCutShortOnTheChip() {
        let l10n = L10n.shared
        let long = ClaudeQuotaLimit(kind: .weeklyScoped, percent: 48, scopeLabel: "Claude Fable 5 Extended")
        let label = QuotaChip.label(for: long, l10n: l10n)
        XCTAssertEqual(label, "Claude…")
        XCTAssertLessThanOrEqual(label.count, QuotaChip.maxLabelLength)
        // Short labels are untouched.
        XCTAssertEqual(QuotaChip.label(for: ClaudeQuotaLimit(kind: .weeklyScoped, percent: 1, scopeLabel: "Fable"), l10n: l10n), "Fable")
        XCTAssertEqual(QuotaChip.label(for: ClaudeQuotaLimit(kind: .session, percent: 1), l10n: l10n), "5h")
    }

    func testPaceMarkOnlyWhereTheBarIsTallEnough() {
        // Notched MacBooks: 32–38pt bars → 26–27pt mascot; the mark fits.
        XCTAssertTrue(QuotaChip.paceFits(mascotSize: 26))
        XCTAssertTrue(QuotaChip.paceFits(mascotSize: 27))
        // A menu-bar-height bar (external display, ≈25pt) → 19pt mascot: the
        // mark would hang past the wing and be cut in half.
        XCTAssertFalse(QuotaChip.paceFits(mascotSize: 19))
    }

    // MARK: - Rendered

    /// The real collapsed bar, rendered offscreen on a red backdrop: whatever
    /// the chip shows, nothing drawn in the left wing reaches the notch, and
    /// the bar stays inside the panel window.
    @MainActor
    func testRenderedChipClearsTheNotchAndStaysInsideTheWindow() throws {
        let cases: [(mode: ClaudeQuotaChipMode, label: String?, working: Bool, toolStatus: Bool)] = [
            (.auto, "Fable", false, false),
            (.auto, "Fable", true, true),
            (.weeklyScoped, "Fable", false, true),
            // A long server-provided model name used to push the bar's left
            // end past the window, mascot and all.
            (.weeklyScoped, "Claude Fable 5 Extended Thinking", false, false),
            (.weeklyScoped, "Claude Fable 5 Extended Thinking", true, true),
        ]
        for c in cases {
            let g = try renderedGeometry(mode: c.mode, scopeLabel: c.label, working: c.working, toolStatus: c.toolStatus)
            let name = "\(c.mode) \(c.label ?? "-") working=\(c.working) toolStatus=\(c.toolStatus)"
            XCTAssertGreaterThan(g.barLeft, 0, "\(name): the bar runs past the panel window")
            XCTAssertLessThanOrEqual(g.contentRight, g.notchLeft - 2, "\(name): the chip reaches under the notch")
        }
    }

    /// Points from the window's left edge: the bar's left end, the right end
    /// of what the left wing draws, and the physical notch's left edge.
    @MainActor
    private func renderedGeometry(
        mode: ClaudeQuotaChipMode, scopeLabel: String?, working: Bool, toolStatus: Bool
    ) throws -> (barLeft: CGFloat, contentRight: CGFloat, notchLeft: CGFloat) {
        _ = NSApplication.shared
        // The panel's @AppStorage reads this suite; the AppState's monitor
        // keeps reading the (disabled) standard defaults, so nothing fetches.
        let suiteName = "QuotaChipLayoutTests"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: SettingsKey.showClaudeQuota)
        suite.set(mode.rawValue, forKey: SettingsKey.claudeQuotaChip)
        suite.set(toolStatus, forKey: SettingsKey.showToolStatus)
        MascotAnimationGate.shared.setPanelVisible(false)
        defer { MascotAnimationGate.shared.setPanelVisible(true) }

        let state = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/web-app"
        session.status = working ? .running : .idle
        state.sessions = ["s1": session]
        state.activeSessionId = "s1"
        state.refreshDerivedState()
        let now = Date()
        state.claudeQuota.applyPreview(ClaudeQuotaSnapshot(limits: [
            ClaudeQuotaLimit(kind: .session, percent: 8, resetsAt: now.addingTimeInterval(4 * 3600)),
            ClaudeQuotaLimit(kind: .weeklyAll, percent: 20, resetsAt: now.addingTimeInterval(86_400)),
            ClaudeQuotaLimit(kind: .weeklyScoped, percent: 100, severity: "critical",
                             resetsAt: now.addingTimeInterval(86_400), scopeLabel: scopeLabel),
        ], fetchedAt: now))

        let windowWidth: CGFloat = 620, height: CGFloat = 64
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: 32, notchW: notch, screenWidth: 1512)
            .environment(\.mascotStaticTime, 5.2)
            .defaultAppStorage(suite)
            .background(Color(red: 1, green: 0, blue: 0))
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: windowWidth, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        // The chip's measured width feeds back into the bar on the next pass.
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let w = image.width, h = image.height
        let scale = CGFloat(w) / windowWidth
        let context = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let p = px + (y * w + x) * 4
            return (Int(p[0]), Int(p[1]), Int(p[2]))
        }
        func isBackdrop(_ c: (Int, Int, Int)) -> Bool { c.0 > 200 && c.1 < 60 && c.2 < 60 }
        func isBlack(_ c: (Int, Int, Int)) -> Bool { c.0 < 12 && c.1 < 12 && c.2 < 12 }
        let barRows = 0..<Int(32 * scale)
        let mid = Int(16 * scale)
        let left = try XCTUnwrap((0..<w).first { !isBackdrop(rgb($0, mid)) }, "no bar rendered")
        // Rightmost drawn pixel of the left wing (mascot, label, ring, percent,
        // pace mark), scanning in from the window's centre.
        var contentRight = left
        for x in stride(from: w / 2, to: left, by: -1)
        where barRows.contains(where: { y in let c = rgb(x, y); return !isBlack(c) && !isBackdrop(c) }) {
            contentRight = x
            break
        }
        return (CGFloat(left) / scale, CGFloat(contentRight + 1) / scale, (windowWidth - notch) / 2)
    }
}
