import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

/// The island's continuous motion runs on FrameClock: at most 20 updates a
/// second, one for everything moving, instead of one per display frame (#381).
///
/// An offscreen window has no display to pace it, so anything that asks for an
/// update on every frame (a TimelineView with entries under a quarter second
/// apart, a `repeatForever` animation) lays its host out thousands of times a
/// second here, against the clock's 20. The rates asserted below sit far from
/// both.
@MainActor
final class FrameClockTests: XCTestCase {
    final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() {
            super.layout()
            layouts += 1
        }
    }

    /// The clock's 20 passes a second, with room for ticks that straddle two of
    /// `settle`'s 10 ms turns.
    private static let clockRateCeiling = 45

    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        MascotAnimationGate.shared.setPanelVisible(true)
        MascotAnimationGate.shared.setIdleSettled(false)
        MascotAnimationGate.shared.setReduceMotion(false)
    }

    override func tearDown() {
        for window in windows {
            window.contentView = nil
        }
        windows = []
        super.tearDown()
    }

    func testEveryMascotMovesOnTheIslandClockNotTheDisplaysFrames() {
        // Every mascot in every state, animating, in one host.
        let sources = SessionSnapshot.supportedSources.sorted()
        let statuses: [AgentStatus] = [.idle, .running, .waitingApproval]
        let grid = VStack(spacing: 0) {
            ForEach(sources, id: \.self) { source in
                HStack(spacing: 0) {
                    ForEach(statuses, id: \.self) { status in
                        MascotView(source: source, status: status, size: 20)
                    }
                }
            }
        }
        let host = install(grid, size: CGSize(width: 60, height: CGFloat(sources.count) * 20))

        let rate = layoutRate(of: host)
        XCTAssertLessThanOrEqual(rate, Self.clockRateCeiling, "a mascot updates on every display frame")
        XCTAssertGreaterThanOrEqual(rate, 5, "the mascots stopped moving")
    }

    func testAnimationSpeedOffHoldsTheMascotsStill() {
        // "Off" froze the picture but kept redrawing it on every frame.
        let mascots = HStack {
            ClawdView(status: .running, size: 20)
            DexView(status: .waitingApproval, size: 20)
            GeminiView(status: .idle, size: 20)
        }
        .environment(\.mascotAnimationsActive, true)
        .environment(\.mascotSpeed, 0)
        let host = install(mascots, size: CGSize(width: 80, height: 20))
        XCTAssertEqual(layoutRate(of: host), 0)
    }

    func testAnAnimatingIslandLaysOutAtTheClockRate() {
        // Working, idle and waiting mascots, a "Thinking…" shimmer and the
        // usage footer, open; collapsed with a tool running, whose name gets
        // the shimmer in the bar of a screen without a notch.
        for hasNotch in [true, false] {
            for open in [true, false] {
                let name = "\(open ? "open" : "collapsed"), notch: \(hasNotch)"
                let state = AppState()
                if open {
                    DebugHarness.apply(.multi, to: state)
                    state.sessions["thinking"] = Self.thinkingSession()
                    state.surface = .sessionList
                } else {
                    DebugHarness.apply(.working, to: state)
                    state.surface = .collapsed
                }
                let host = install(panel(state, hasNotch: hasNotch), size: CGSize(width: 620, height: 510))
                if !open {
                    // The bar shows the tool's name once it starts.
                    settle(host, seconds: 0.3)
                    state.sessions["preview-working"]?.currentTool = "Bash"
                }
                let rate = layoutRate(of: host)
                XCTAssertLessThanOrEqual(rate, Self.clockRateCeiling, "\(name): the island lays out on every display frame")
                XCTAssertGreaterThanOrEqual(rate, 5, "\(name): nothing on the island moves")
                uninstall(host)
            }
        }
    }

    func testAWaitingBadgeOnTheCollapsedBarMovesOnTheClock() {
        // An approval waiting behind the collapsed bar: its badge pulses with
        // the mascots, and holds still with them.
        for animating in [true, false] {
            MascotAnimationGate.shared.setPanelVisible(animating)
            let state = AppState()
            DebugHarness.apply(.approval, to: state)
            state.surface = .collapsed
            state.refreshDerivedState()
            XCTAssertEqual(state.status, .waitingApproval, "the bar shows no waiting badge")
            let host = install(panel(state, hasNotch: true), size: CGSize(width: 620, height: 510))
            let rate = layoutRate(of: host)
            if animating {
                XCTAssertLessThanOrEqual(rate, Self.clockRateCeiling, "the badge pulses on every display frame")
                XCTAssertGreaterThanOrEqual(rate, 5, "nothing on the bar moves")
            } else {
                XCTAssertEqual(rate, 0, "the badge keeps pulsing while the island holds still")
            }
            uninstall(host)
        }
        MascotAnimationGate.shared.setPanelVisible(true)
    }

    func testEveryClockDueAtATickSeesTheSameTick() {
        // One wakeup and one update per tick, not one per clock: each clock
        // updating on its own woke the island up several times a frame.
        final class Seen { var times: [Int: Set<TimeInterval>] = [:] }
        let seen = Seen()
        let clocks = HStack {
            ForEach(0..<4, id: \.self) { index in
                FrameClock(interval: 0.05) { now in
                    let _ = seen.times[index, default: []].insert(now)
                    Text("\(index)")
                }
            }
        }
        let host = install(clocks, size: CGSize(width: 100, height: 20))
        settle(host, seconds: 0.6)

        XCTAssertEqual(seen.times.count, 4)
        let ticks = seen.times[0] ?? []
        XCTAssertGreaterThan(ticks.count, 3, "the clocks didn't tick")
        for index in 1..<4 {
            XCTAssertEqual(seen.times[index], ticks, "clock \(index) ticked on its own")
        }
    }

    func testTheTickerStopsWithTheLastClock() {
        let host = install(FrameClock(interval: 0.05) { now in Text("\(now)") }, size: CGSize(width: 200, height: 20))
        settle(host, seconds: 0.2)
        XCTAssertTrue(FrameTicker.shared.isRunning)

        // A still island schedules nothing.
        uninstall(host)
        let deadline = Date().addingTimeInterval(1)
        while FrameTicker.shared.isRunning, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertFalse(FrameTicker.shared.isRunning)
    }

    func testIntervalsLandOnTheTwentyFpsGrid() {
        XCTAssertEqual(FrameClock(interval: 0.03) { _ in EmptyView() }.interval, 0.05, accuracy: 1e-9)
        XCTAssertEqual(FrameClock(interval: 0.05) { _ in EmptyView() }.interval, 0.05, accuracy: 1e-9)
        // The sleep scenes ask for 0.12 s: they tick on every other frame of
        // the rest instead of in updates of their own.
        XCTAssertEqual(FrameClock(interval: 0.12) { _ in EmptyView() }.interval, 0.10, accuracy: 1e-9)
    }

    func testASleepZTakesTheSameRoomAtEverySize() {
        // A z that grew in layout moved the island's layout with it, every
        // frame of every sleeping mascot; only its drawing may change.
        func fitting(_ fontSize: CGFloat) -> CGSize {
            NSHostingView(rootView: MascotSleepZ(fontSize: fontSize, fullSize: 9, color: .white, opacity: 0.5)).fittingSize
        }
        XCTAssertEqual(fitting(6), fitting(9))
        XCTAssertEqual(fitting(7.5), fitting(9))
    }

    func testTheAlertGlowPulsesOnceASecondFromFullStrength() {
        XCTAssertEqual(MascotMotion.glowPulse(0), 1, accuracy: 1e-9)
        XCTAssertEqual(MascotMotion.glowPulse(0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(MascotMotion.glowPulse(0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(MascotMotion.glowPulse(1), 1, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private static func thinkingSession() -> SessionSnapshot {
        var session = SessionSnapshot()
        session.status = .processing
        session.cwd = "/Users/dev/notes"
        session.source = "claude"
        session.lastActivity = Date()
        return session
    }

    private func panel(_ state: AppState, hasNotch: Bool) -> NotchPanelView {
        NotchPanelView(appState: state, hasNotch: hasNotch, notchHeight: hasNotch ? 32 : 24,
                       notchW: hasNotch ? 185 : 202, screenWidth: hasNotch ? 1512 : 1440)
    }

    /// Hosts `view` as PanelWindowController does: an NSHostingView that takes
    /// the window's size, in a borderless window never ordered on screen.
    private func install<V: View>(_ view: V, size: CGSize) -> CountingHost<V> {
        let host = CountingHost(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        return host
    }

    private func uninstall(_ host: NSView) {
        guard let window = host.window else { return }
        window.contentView = nil
        windows.removeAll { $0 === window }
    }

    private func settle(_ host: NSView, seconds: TimeInterval = 0.3) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Layout passes per second once the view has settled.
    private func layoutRate<V: View>(of host: CountingHost<V>) -> Int {
        settle(host, seconds: 0.5)
        host.layouts = 0
        settle(host, seconds: 1)
        return host.layouts
    }
}
