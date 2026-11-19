import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Opt in on a Mac with CODEISLAND_PROFILE_EXPANSION=1. Exercises the real
/// panel with eleven cards, without agent discovery, hooks, or user defaults.
/// This measures main-thread stalls, not the display's presented frame rate.
@MainActor
final class NotchExpansionPerformanceTests: XCTestCase {
    func testColdAndRepeatedExpansionStalls() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CODEISLAND_PROFILE_EXPANSION"] == "1")
        _ = NSApplication.shared
        let wasVisible = MascotAnimationGate.shared.isPanelVisible
        if ProcessInfo.processInfo.environment["CODEISLAND_PROFILE_PAUSE_MASCOTS"] == "1" {
            MascotAnimationGate.shared.setPanelVisible(false)
        }
        defer { MascotAnimationGate.shared.setPanelVisible(wasVisible) }
        let state = AppState()
        let sessionCount = Int(ProcessInfo.processInfo.environment["CODEISLAND_PROFILE_SESSIONS"] ?? "11") ?? 11
        for index in 0..<max(1, sessionCount) {
            var session = SessionSnapshot()
            session.source = index.isMultiple(of: 2) ? "codex" : "claude"
            session.cwd = "/Users/dev/project-\(index)"
            session.status = index < 6 ? .running : .idle
            session.currentTool = index < 6 ? "Read" : nil
            session.toolDescription = "Sources/Feature/Implementation.swift"
            session.lastUserPrompt = "Inspect the implementation and improve the animation."
            session.addRecentMessage(ChatMessage(isUser: true, text: session.lastUserPrompt!))
            session.addRecentMessage(ChatMessage(isUser: false, text: "The panel shows all active sessions, their current tools, and the latest replies."))
            state.sessions["fixture-\(index)"] = session
        }
        state.activeSessionId = "fixture-0"
        state.refreshDerivedState()
        state.surface = .collapsed

        let view = NotchPanelView(appState: state, hasNotch: true, notchHeight: 32, notchW: 185, screenWidth: 1512)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 510)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let onscreen = ProcessInfo.processInfo.environment["CODEISLAND_PROFILE_ONSCREEN"] == "1"
        if onscreen {
            if let screen = NSScreen.main {
                window.setFrameOrigin(NSPoint(x: screen.frame.midX - 310, y: screen.frame.maxY - 510))
            }
            window.orderFrontRegardless()
        }
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        var phaseMaxima: [String: Double] = [:]
        func pump(for duration: TimeInterval) -> [Double] {
            var stalls: [Double] = []
            let deadline = CACurrentMediaTime() + duration
            while CACurrentMediaTime() < deadline {
                let start = CACurrentMediaTime()
                if !onscreen { host.layoutSubtreeIfNeeded() }
                let layoutEnd = CACurrentMediaTime()
                if !onscreen { window.displayIfNeeded() }
                let displayEnd = CACurrentMediaTime()
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                let runLoopEnd = CACurrentMediaTime()
                phaseMaxima["layout"] = max(phaseMaxima["layout"] ?? 0, (layoutEnd - start) * 1_000)
                phaseMaxima["display"] = max(phaseMaxima["display"] ?? 0, (displayEnd - layoutEnd) * 1_000)
                phaseMaxima["runloop"] = max(phaseMaxima["runloop"] ?? 0, (runLoopEnd - displayEnd) * 1_000)
                stalls.append((CACurrentMediaTime() - start) * 1_000)
            }
            return stalls
        }
        _ = pump(for: 0.3)
        var coldMaximum: Double = 0
        var maxima: [Double] = []
        for cycle in 0..<5 {
            let start = CACurrentMediaTime()
            withAnimation(NotchAnimation.open) { state.surface = .sessionList }
            let synchronous = (CACurrentMediaTime() - start) * 1_000
            let samples = pump(for: 0.6)
            let maximum = max(synchronous, samples.max() ?? 0)
            // Keep the first graph/font setup visible in the report. Repeated
            // hover is a separate budget: the original rebuilt every time.
            if cycle == 0 { coldMaximum = maximum } else { maxima.append(maximum) }
            print(String(format: "[expansion-perf] cycle=%d maximum_main_thread_stall_ms=%.2f", cycle, maximum))
            withAnimation(NotchAnimation.close) { state.surface = .collapsed }
            _ = pump(for: 0.5)
        }
        print("[expansion-perf] sessions=\(sessionCount) phase_maxima_ms=\(phaseMaxima)")
        XCTAssertLessThan(coldMaximum, 100, "Cold expansion blocks input for over 100 ms")
        XCTAssertLessThan(maxima.max() ?? .infinity, 33.34, "Repeated expansion blocks the main thread for more than two 60 Hz frames")
    }
}
