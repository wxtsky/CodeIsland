import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class PrayerBannerSuppressionTests: XCTestCase {

    private func makeAppState(status: AgentStatus = .idle, surface: IslandSurface = .sessionList) -> AppState {
        let appState = AppState()
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = status
        appState.sessions["test"] = session
        appState.activeSessionId = "test"
        appState.refreshDerivedState()
        appState.surface = surface
        return appState
    }

    func testBannerSuppressedWhenAgentWaitingApproval() {
        let manager = PrayerTimeManager.shared
        manager.dismissMiniPeekBanner()

        let appState = makeAppState(status: .waitingApproval)

        // Queue a test banner
        manager.queueBannerForTesting(title: "10 Menit Menuju Ashar", subtitle: "15:20", appState: appState)

        // Banner should NOT be presented while waiting approval
        XCTAssertFalse(manager.showMiniPeekBanner, "Banner must be suppressed during agent approval")

        // Once agent finishes approval flow:
        var session = SessionSnapshot()
        session.source = "claude"
        session.status = .idle
        appState.sessions["test"] = session
        appState.refreshDerivedState()
        appState.surface = .sessionList
        manager.checkAndFlushPendingBanner(appState: appState)

        // Now banner should be presented
        XCTAssertTrue(manager.showMiniPeekBanner, "Banner should flush and show after approval completes")
    }

    func testBannerPresentsImmediatelyWhenAgentIdle() {
        let manager = PrayerTimeManager.shared
        manager.dismissMiniPeekBanner()

        let appState = makeAppState(status: .idle, surface: .sessionList)

        manager.queueBannerForTesting(title: "Waktu Dzuhur Telah Masuk", subtitle: "12:05", appState: appState)

        XCTAssertTrue(manager.showMiniPeekBanner, "Banner should show immediately when agent is idle")
    }
}
