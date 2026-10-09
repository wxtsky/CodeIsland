import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// The completion card has to fit the panel window: whatever sits around the
/// reply (task progress, the "N sessions" link, a recap, older replies, a
/// taller notch, a larger font) comes out of the reply's scroll area, never
/// off the bottom of the window.
///
/// Renders the real panel in an offscreen window and reads the pixels: the
/// panel is black on a red backdrop, so a card cut by the window leaves no
/// red under it.
@MainActor
final class CompletionCardLayoutTests: XCTestCase {
    private let keys = [
        SettingsKey.contentFontSize, SettingsKey.aiMessageLines, SettingsKey.maxVisibleSessions,
        SettingsKey.maxPanelHeight, SettingsKey.showTaskProgress, SettingsKey.showSessionRecap,
        SettingsKey.showUsageStats, SettingsKey.showClaudeQuota, SettingsKey.showProjectName,
        SettingsKey.hideWhenNoSession,
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
            defaults.removeObject(forKey: key)
        }
        defaults.set(false, forKey: SettingsKey.showUsageStats)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = saved[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        MascotAnimationGate.shared.setPanelVisible(true)
        super.tearDown()
    }

    func testCrowdedCardFitsTheWindowAtALargeFontUnderATallNotch() throws {
        // Measured before the fix: 184–216pt of chrome against a fixed
        // 180pt estimate, so the bottom of the card was cut.
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let gap = try gapUnderPanel(state(tasks: true, recap: true, secondSession: true), notchHeight: 38)
        assertCardFillsTheWindow(gap)
    }

    func testLongOlderReplyUnderUnlimitedLinesLeavesRoomForTheNewOne() throws {
        // "AI reply lines: unlimited" used to render the previous reply in
        // full above the new one and push the card ~450pt past the window.
        UserDefaults.standard.set(0, forKey: SettingsKey.aiMessageLines)
        let gap = try gapUnderPanel(state(tasks: true, recap: true, secondSession: true, longOlderReply: true), notchHeight: 32)
        assertCardFillsTheWindow(gap)
    }

    func testSmallWindowStillHoldsTheWholeCard() throws {
        UserDefaults.standard.set(2, forKey: SettingsKey.maxVisibleSessions)
        UserDefaults.standard.set(14, forKey: SettingsKey.contentFontSize)
        let gap = try gapUnderPanel(state(tasks: true, recap: true, secondSession: true), notchHeight: 32)
        assertCardFillsTheWindow(gap)
    }

    func testCardOfAMissingSessionShowsNoSessions() throws {
        // The AiWork watchers drop sessions without moving the surface off
        // their card. Such a card used to fall back to every session as a
        // completion card, and two completion replies size against each
        // other without settling (#357).
        let state = state(tasks: false, recap: false, secondSession: true)
        state.surface = .completionCard(sessionId: "gone")
        let noSessions = AppState()
        noSessions.surface = .completionCard(sessionId: "gone")

        // With no sessions the panel shows only the idle bar. The card may
        // add its header and the "N sessions" link (38.5pt measured); any
        // session card is taller than the 50pt allowed.
        let gap = try gapUnderPanel(state, notchHeight: 32)
        XCTAssertGreaterThan(gap, try gapUnderPanel(noSessions, notchHeight: 32) - 50,
                             "a card whose session is gone still renders other sessions")
    }

    func testReplyMakesRoomWhenTheCardGrowsWhileOpen() throws {
        // The reply only re-fits when the rest of the card changes, so a task
        // list arriving on an open card has to reach it.
        let state = state(tasks: false, recap: false, secondSession: true)
        let panel = try PanelHost(state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        assertCardFillsTheWindow(try panel.gapUnderPanel())

        state.sessions["a-card"]?.agentTasks = AgentTaskList(items: (1...6).map {
            AgentTaskItem(id: "t\($0)", title: "Task \($0)", activeForm: "Working on task \($0)", status: .pending)
        })
        panel.settle()
        assertCardFillsTheWindow(try panel.gapUnderPanel())
    }

    func testRepliesSharingThePanelSettleAtOnce() throws {
        // Two replies in one panel used to count each other as chrome and
        // flip between 228 and 764pt for good: a layout loop like the one
        // that hung the main thread in #357. The real panel shows one at a
        // time now, so this stacks them in a panel measured the same way.
        for count in 1...3 {
            let heights = panelHeights(replies: count, window: 500)
            XCTAssertLessThanOrEqual(heights.count, 3, "\(count) replies kept re-fitting: \(heights)")
            XCTAssertEqual(try XCTUnwrap(heights.last), 500 - CompletionReplyMetrics.bottomMargin, accuracy: CGFloat(count),
                           "\(count) replies should share the whole window")
        }
    }

    private func assertCardFillsTheWindow(_ gap: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(gap, 0, "the card's bottom edge is cut by the window", file: file, line: line)
        XCTAssertLessThanOrEqual(gap, CompletionReplyMetrics.bottomMargin + 1,
                                 "the reply leaves part of the window unused", file: file, line: line)
    }

    // MARK: - Fixture

    private func state(tasks: Bool, recap: Bool, secondSession: Bool, longOlderReply: Bool = false) -> AppState {
        func session(_ project: String) -> SessionSnapshot {
            var session = SessionSnapshot(startTime: Date().addingTimeInterval(-900))
            session.source = "claude"
            session.cwd = "/Users/dev/code/\(project)"
            session.status = .idle
            session.lastActivity = Date()
            return session
        }
        var card = session("web-app")
        let reply = (1...40)
            .map { "Line \($0): the dashboard filter now keeps its **state** across reloads and `tabs`." }
            .joined(separator: "\n\n")
        let older = longOlderReply
            ? (1...30).map { "Older paragraph \($0) explaining an earlier change in enough detail to wrap." }.joined(separator: "\n\n")
            : "Earlier: I looked at the existing filter components."
        card.lastUserPrompt = "add a filter bar to the dashboard"
        card.lastAssistantMessage = reply
        card.addRecentMessage(ChatMessage(isUser: false, text: older))
        card.addRecentMessage(ChatMessage(isUser: true, text: "add a filter bar to the dashboard"))
        card.addRecentMessage(ChatMessage(isUser: false, text: reply))
        if tasks {
            card.agentTasks = AgentTaskList(items: (1...10).map { index in
                AgentTaskItem(
                    id: "t\(index)",
                    title: "Task \(index)",
                    activeForm: "Working on task \(index)",
                    status: index < 4 ? .completed : (index == 4 ? .inProgress : .pending)
                )
            })
        }
        if recap {
            card.recap = SessionRecap(
                text: "Added a cost-based query planner to /search; p95 went from 820ms to 140ms and every test passes. Next: your call on shipping it.",
                createdAt: Date()
            )
        }
        let state = AppState()
        state.sessions = ["a-card": card]
        if secondSession {
            state.sessions["b-other"] = session("api-server")
        }
        state.activeSessionId = "a-card"
        state.surface = .completionCard(sessionId: "a-card")
        return state
    }

    // MARK: - Rendering

    /// Points of backdrop left under the panel's bottom edge, 0 when the
    /// panel runs into the window's last row.
    private func gapUnderPanel(_ state: AppState, notchHeight: CGFloat) throws -> CGFloat {
        let panel = try PanelHost(state, notchHeight: notchHeight)
        defer { panel.close() }
        panel.settle()
        return try panel.gapUnderPanel()
    }

    /// Every height a panel of long completion replies takes, measured as
    /// NotchPanelView measures its own, until it is left alone.
    private func panelHeights(replies count: Int, window height: CGFloat) -> [CGFloat] {
        final class Heights { var all: [CGFloat] = [] }
        let heights = Heights()
        let space = CompletionCardSpace()
        let reply = (1...40).map { "Line \($0): the dashboard filter now keeps its state across reloads." }
            .joined(separator: "\n\n")
        let view = VStack(spacing: 0) {
            VStack(spacing: 6) {
                Color.black.frame(height: 100)
                ForEach(0..<count, id: \.self) { _ in
                    AssistantReplyText(text: reply, fontSize: 13, lineLimit: nil, isCompletionReply: true)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights.all.append($0) }
            .recordsCompletionCardChrome(in: space)
            Spacer(minLength: 0)
        }
        .frame(width: 600)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { space.recordWindowHeight($0) }
        .environment(space)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        return heights.all
    }
}

/// The real panel hosted as PanelWindowController hosts it, on a red
/// backdrop so the panel's black bottom edge can be read from the pixels.
@MainActor
struct PanelHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    let height: CGFloat

    init(_ state: AppState, notchHeight: CGFloat) throws {
        let maxVisible = UserDefaults.standard.object(forKey: SettingsKey.maxVisibleSessions) as? Int
            ?? SettingsDefaults.maxVisibleSessions
        height = PanelHeightMetrics.desiredHeight(maxVisibleSessions: maxVisible)
        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: notchHeight, notchW: 185, screenWidth: 1512)
            .environment(\.mascotStaticTime, 5.2)
            .background(Color(red: 1, green: 0, blue: 0))
        host = NSHostingView(rootView: AnyView(view))
        // As PanelWindowController hosts it: the window's size, not the content's.
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// The reply's area is sized from measurements of the laid-out panel,
    /// which take a couple of update passes to settle.
    func settle() {
        for _ in 0..<4 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Points of backdrop left under the panel's bottom edge, 0 when the
    /// panel runs into the window's last row.
    func gapUnderPanel() throws -> CGFloat {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)

        let pixelsWide = image.width, pixelsHigh = image.height
        let scale = CGFloat(pixelsHigh) / height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: pixelsWide * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // The panel is centred; its bottom edge is flat across the middle.
        let x = pixelsWide / 2
        func isBackdrop(row: Int) -> Bool {
            let pixel = pixels + (row * pixelsWide + x) * 4
            return pixel[0] > 200 && pixel[1] < 60 && pixel[2] < 60
        }
        XCTAssertFalse(isBackdrop(row: 2), "the notch bar should sit at the top of the window")
        var row = pixelsHigh - 1
        while row > 0, isBackdrop(row: row) { row -= 1 }
        return CGFloat(pixelsHigh - 1 - row) / scale
    }
}
