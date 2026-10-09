import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The collapsed bar's right wing — quiet-hours moon, completion dot, question
/// badge, session count — must stay clear of the notch. Its room was sized for
/// the count and one badge; with tool status in simple mode nothing else pads
/// it, so a waiting question's badge slid under the notch, and the completion
/// dot beside it disappeared behind the notch altogether. A question the user
/// dismissed (#352) keeps that badge up until it is answered in the terminal.
@MainActor
final class CollapsedRightWingLayoutTests: XCTestCase {
    private let suiteName = "CollapsedRightWingLayoutTests"
    private var suite: UserDefaults!
    private var responses: [Task<Data, Never>] = []
    private var saved: [String: Any?] = [:]
    private let standardKeys = [
        SettingsKey.autoExpandOnQuestion, SettingsKey.smartSuppress, SettingsKey.followUpReminderMinutes,
    ]
    private let notch: CGFloat = 185

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        suite.removePersistentDomain(forName: suiteName)
        // AppState reads these from the standard defaults: the question stays
        // behind the collapsed bar's badge instead of opening its card.
        for key in standardKeys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(false, forKey: SettingsKey.autoExpandOnQuestion)
        UserDefaults.standard.set(false, forKey: SettingsKey.smartSuppress)
        UserDefaults.standard.set(0, forKey: SettingsKey.followUpReminderMinutes)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        for key in standardKeys {
            if let value = saved[key] ?? nil { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        MascotAnimationGate.shared.setPanelVisible(true)
        try await super.tearDown()
    }

    func testRightWingMissingWidthIsOnlyWhatItLacks() {
        // Room: 41 + 20/2 = 51. A count and one badge fit with notch clearance.
        XCTAssertEqual(CompactRightWingLayout.missing(contentWidth: 46, wing: 41, statusExtra: 20, hasNotch: true), 0)
        // Badge + dot + count: 66 + 4 clearance − 51 = 19 short.
        XCTAssertEqual(CompactRightWingLayout.missing(contentWidth: 66, wing: 41, statusExtra: 20, hasNotch: true), 19, accuracy: 0.001)
        // No notch to clear: the right wing sits past a flexible centre.
        XCTAssertEqual(CompactRightWingLayout.missing(contentWidth: 66, wing: 41, statusExtra: 20, hasNotch: false), 0)
        // Not measured yet.
        XCTAssertEqual(CompactRightWingLayout.missing(contentWidth: 0, wing: 41, statusExtra: 20, hasNotch: true), 0)
    }

    func testQuestionBadgeAndCompletionDotStayClearOfTheNotch() async throws {
        for (glance, chip) in [(false, false), (true, false), (true, true)] {
            let state = try await collapsedState(glance: glance, chip: chip)
            let g = try renderedGeometry(state)
            let name = "glance=\(glance) chip=\(chip)"
            XCTAssertNil(g.intrusion, "\(name): the right wing draws under the notch at \(g.intrusion ?? 0)pt")
            XCTAssertLessThanOrEqual(g.barRight, 620, "\(name): the bar runs past the panel window")
            XCTAssertGreaterThanOrEqual(g.barLeft, 0, "\(name): the bar runs past the panel window")
            await drain(state)
        }
    }

    func testRightWingThatFitsLeavesTheBarAlone() async throws {
        // Tool status in detailed mode pads both wings: the badge and dot fit,
        // and the bar must stay exactly where it was.
        suite.set(true, forKey: SettingsKey.showToolStatus)
        let state = try await collapsedState(glance: true, chip: false)
        let g = try renderedGeometry(state)
        XCTAssertNil(g.intrusion)
        // Centred on the notch: base bar = notch + 2 × 41 + 20 + 3% of 1512.
        // The panel shape is drawn about a point inside its frame.
        let base = notch + 82 + 20 + 1512 * 0.03
        XCTAssertEqual(g.barRight, (620 + base) / 2 - 1, accuracy: 1)
        XCTAssertEqual(g.barLeft, (620 - base) / 2 + 1, accuracy: 1)
        await drain(state)
    }

    // MARK: - Fixture

    private func collapsedState(glance: Bool, chip: Bool) async throws -> AppState {
        suite.set(chip, forKey: SettingsKey.showClaudeQuota)
        if suite.object(forKey: SettingsKey.showToolStatus) == nil {
            suite.set(false, forKey: SettingsKey.showToolStatus)
        }
        let state = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/web-app"
        var other = SessionSnapshot()
        other.source = "codex"
        other.cwd = "/Users/dev/code/api"
        state.sessions = ["s1": session, "s2": other]
        state.activeSessionId = "s1"
        state.refreshDerivedState()
        if chip {
            let now = Date()
            state.claudeQuota.applyPreview(ClaudeQuotaSnapshot(limits: [
                ClaudeQuotaLimit(kind: .weeklyAll, percent: 20, resetsAt: now.addingTimeInterval(86_400)),
            ], fetchedAt: now))
        }
        let payload: [String: Any] = [
            "hook_event_name": "PermissionRequest", "session_id": "s1", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [[
                "question": "Deploy?", "header": "Pick",
                "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]],
            ]]],
        ]
        let event = try XCTUnwrap(HookEvent(from: try JSONSerialization.data(withJSONObject: payload)))
        responses.append(await startHookRequest { state.handleAskUserQuestion(event, continuation: $0) })
        XCTAssertEqual(state.hiddenPendingQuestionSessionId, "s1", "the question should wait behind the badge")
        state.glanceCompletionActive = glance
        return state
    }

    private func drain(_ state: AppState) async {
        for event in state.questionQueue.map(\.event) {
            state.handlePeerDisconnect(sessionId: event.sessionId ?? "default", agentId: event.agentId)
        }
        for task in responses { _ = try? await awaitValue(of: task) }
        responses = []
    }

    // MARK: - Rendering

    /// The real panel on a red backdrop: the bar's ends, and the first column
    /// under the physical notch where anything but the bar's black is drawn.
    private func renderedGeometry(_ state: AppState) throws -> (barLeft: CGFloat, barRight: CGFloat, intrusion: CGFloat?) {
        let windowWidth: CGFloat = 620, height: CGFloat = 64, notchHeight: CGFloat = 32
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: notchHeight, notchW: notch, screenWidth: 1512)
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
        // Measured widths feed back into the bar on the next pass.
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
        let barRows = 0..<Int(notchHeight * scale)
        let mid = Int(notchHeight / 2 * scale)
        let left = try XCTUnwrap((0..<w).first { !isBackdrop(rgb($0, mid)) }, "no bar rendered")
        let right = try XCTUnwrap((0..<w).reversed().first { !isBackdrop(rgb($0, mid)) })
        let notchLeft = Int((windowWidth - notch) / 2 * scale), notchRight = Int((windowWidth + notch) / 2 * scale)
        let intrusion = (notchLeft..<notchRight).first { x in
            barRows.contains { y in let c = rgb(x, y); return !isBlack(c) && !isBackdrop(c) }
        }
        return (CGFloat(left) / scale, CGFloat(right + 1) / scale, intrusion.map { CGFloat($0) / scale })
    }
}
