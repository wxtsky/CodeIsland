import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Every expanded surface has to fit the panel window: what doesn't is cut
/// off by the window's bottom edge, out of reach. Rendered offscreen on a red
/// backdrop (PanelHost) so the panel's bottom edge can be read from pixels.
@MainActor
final class PanelFitLayoutTests: XCTestCase {
    private var sandbox: DefaultsSandbox?

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        MascotAnimationGate.shared.setPanelVisible(true)
        sandbox?.restore()
        super.tearDown()
    }

    // MARK: - Session list

    func testListScrollsByHeightNotOnlyBySessionCount() {
        let budget = SessionListMetrics.scrollHeight(maxVisibleSessions: 5)
        XCTAssertEqual(budget, 450)
        XCTAssertFalse(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 4, contentHeight: 300, maxVisibleSessions: 5))
        XCTAssertTrue(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 4, contentHeight: 620, maxVisibleSessions: 5))
        XCTAssertTrue(SessionListMetrics.needsScroll(isCompletionCard: false, sessionCount: 6, contentHeight: 0, maxVisibleSessions: 5))
        // The completion card sizes its own reply instead.
        XCTAssertFalse(SessionListMetrics.needsScroll(isCompletionCard: true, sessionCount: 6, contentHeight: 900, maxVisibleSessions: 5))
    }

    func testFewTallSessionsStayInsideTheWindow() throws {
        // Four sessions — under the five the window is sized for — but with
        // a task list, an approval row and a recap they ran ~150pt past the
        // 510pt window, footer and all.
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    func testTallSessionsAtALargeFontStayInsideTheWindow() throws {
        UserDefaults.standard.set(16, forKey: SettingsKey.contentFontSize)
        let state = try tallSessions(count: 4)
        defer { state.release() }
        let panel = try PanelHost(state.state, notchHeight: 37)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the session list runs off the bottom of the window")
    }

    // MARK: - Question card

    func testQuestionWithManyOptionsKeepsItsButtonsInsideTheWindow() async throws {
        // Ten options with descriptions used to push option 10, "Other" and
        // the Dismiss / Skip row past the bottom of the 510pt window.
        let state = AppState()
        var s = SessionSnapshot()
        s.source = "claude"
        s.cwd = "/Users/dev/code/web-app"
        s.status = .waitingQuestion
        state.sessions = ["q": s]
        state.activeSessionId = "q"
        let regions = (1...10).map { ("region-\($0)", Optional("Latency to the team: medium")) }
        let release = try await DemoRequests.enqueueQuestion(state, sessionId: "q", cwd: "/Users/dev/code/web-app", items: [
            ("Which region should the staging stack deploy to?", "Region", regions, false),
        ])
        defer { release() }
        state.refreshDerivedState()
        state.surface = .questionCard(sessionId: "q")
        let panel = try PanelHost(state, notchHeight: 32)
        defer { panel.close() }
        panel.settle()
        XCTAssertGreaterThan(try panel.gapUnderPanel(), 0, "the question card runs off the bottom of the window")
    }

    // MARK: - Fixtures

    private struct Demo {
        let state: AppState
        let release: () -> Void
    }

    private func tallSessions(count: Int) throws -> Demo {
        let state = AppState()
        var usage = ClaudeUsageTotals()
        usage.outputTokens = 96_000
        state.claudeUsage = ClaudeUsageScanner.Snapshot(last5h: usage, today: usage, hourlyOutputTokens: [1, 2, 3], scannedAt: Date())
        for index in 0..<count {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-600))
            s.source = "claude"
            s.cwd = "/Users/dev/code/project-\(index)"
            s.gitBranch = "feat/branch-\(index)"
            s.status = .running
            s.currentTool = "Edit"
            s.toolDescription = "src/components/Dashboard.tsx"
            s.lastUserPrompt = "Add filters to the dashboard page"
            s.addRecentMessage(ChatMessage(isUser: true, text: "Add filters to the dashboard page"))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Adding a date-range and status filter bar above the orders table."))
            s.agentTasks = AgentTaskList(items: (1...5).map {
                AgentTaskItem(id: "t\($0)", title: "Task \($0)", status: $0 < 3 ? .completed : ($0 == 3 ? .inProgress : .pending))
            })
            state.sessions["s\(index)"] = s
        }
        state.activeSessionId = "s0"
        state.refreshDerivedState()
        state.surface = .sessionList
        return Demo(state: state, release: {})
    }
}
