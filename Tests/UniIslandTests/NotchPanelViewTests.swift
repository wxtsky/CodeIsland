import XCTest
@testable import UniIsland

final class NotchPanelViewTests: XCTestCase {
    func testCollapsedWidthScaleUsesSinglePercentIncrements() {
        XCTAssertEqual(NotchWidthScale.step, 1)
    }

    func testEffectiveNotchWidthAppliesCollapsedWidthScale() {
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 50),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 150),
            300,
            accuracy: 0.001
        )
    }

    func testEffectiveNotchWidthClampsOutOfRangeScale() {
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 10),
            100,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NotchWidthMetrics.effectiveNotchWidth(notchW: 200, collapsedWidthScale: 250),
            300,
            accuracy: 0.001
        )
    }

    func testIdleExpandedWidthFollowsCollapsedWidthScaleButStaysPartial() {
        let normal = NotchWidthMetrics.idlePanelWidth(
            notchW: 200,
            compactWingWidth: 30,
            collapsedWidthScale: 100,
            phase: .expanded
        )
        let wider = NotchWidthMetrics.idlePanelWidth(
            notchW: 200,
            compactWingWidth: 30,
            collapsedWidthScale: 150,
            phase: .expanded
        )
        let fullExpanded = NotchWidthMetrics.expandedPanelWidth(
            notchW: 200,
            collapsedWidthScale: 150,
            screenWidth: 800
        )

        XCTAssertGreaterThan(wider, normal)
        XCTAssertLessThan(wider, fullExpanded)
    }

    func testCollapsedRightWingReservesRoomForAlertCount() {
        let normal = NotchWidthMetrics.collapsedRightWingReservedWidth(
            showToolStatus: false,
            isAlerting: false
        )
        let alerting = NotchWidthMetrics.collapsedRightWingReservedWidth(
            showToolStatus: false,
            isAlerting: true
        )

        XCTAssertGreaterThanOrEqual(normal, 30)
        XCTAssertGreaterThan(alerting, normal)
    }

    func testActiveCollapsedPanelWidthAddsRequestedBreathingRoom() {
        let width = NotchWidthMetrics.activeCollapsedPanelWidth(
            scaledCenterGap: 198,
            compactWingWidth: 35,
            rightWingWidth: 32,
            prehoverExtra: 0,
            minimumVisibleWidth: 198
        )

        XCTAssertEqual(width, 198 + 35 + 32 + 60, accuracy: 0.001)
    }

    func testActiveCollapsedPanelWidthUsesScaledWidthWhenStillCoveringNotch() {
        let width = NotchWidthMetrics.activeCollapsedPanelWidth(
            scaledCenterGap: 126,
            compactWingWidth: 35,
            rightWingWidth: 32,
            prehoverExtra: 0,
            minimumVisibleWidth: 198
        )

        XCTAssertEqual(width, 126 + 35 + 32 + 60, accuracy: 0.001)
    }

    func testActiveCollapsedPanelWidthNeverShrinksBelowNotchCoverage() {
        let width = NotchWidthMetrics.activeCollapsedPanelWidth(
            scaledCenterGap: 80,
            compactWingWidth: 20,
            rightWingWidth: 20,
            prehoverExtra: 0,
            minimumVisibleWidth: 198
        )

        XCTAssertEqual(width, 198, accuracy: 0.001)
    }

    func testCollapsedCenterGapUsesPhysicalNotchWhenScaledSmaller() {
        XCTAssertEqual(
            NotchWidthMetrics.collapsedCenterGap(
                effectiveNotchWidth: 100,
                physicalNotchWidth: 200,
                hasNotch: true
            ),
            198,
            accuracy: 0.001
        )
    }

    func testCollapsedCenterGapUsesEffectiveWidthWithoutNotch() {
        XCTAssertEqual(
            NotchWidthMetrics.collapsedCenterGap(
                effectiveNotchWidth: 100,
                physicalNotchWidth: 200,
                hasNotch: false
            ),
            100,
            accuracy: 0.001
        )
    }

    func testHoverInteractionCancelsExpansionWhenMouseLeavesPrehover() {
        var phase = NotchHoverInteraction.nextPhase(from: .collapsed, event: .mouseEntered)
        XCTAssertEqual(phase, .prehover)

        phase = NotchHoverInteraction.nextPhase(from: phase, event: .mouseExited)
        XCTAssertEqual(phase, .collapsed)

        phase = NotchHoverInteraction.nextPhase(from: phase, event: .expandDelayElapsed)
        XCTAssertEqual(phase, .collapsed)
    }

    func testHoverInteractionKeepsExpandedUntilCollapseDelayElapsed() {
        var phase = NotchHoverInteraction.nextPhase(from: .collapsed, event: .mouseEntered)
        phase = NotchHoverInteraction.nextPhase(from: phase, event: .expandDelayElapsed)
        XCTAssertEqual(phase, .expanded)

        phase = NotchHoverInteraction.nextPhase(from: phase, event: .mouseExited)
        XCTAssertEqual(phase, .expanded)

        phase = NotchHoverInteraction.nextPhase(from: phase, event: .collapseDelayElapsed)
        XCTAssertEqual(phase, .collapsed)
    }

    func testShouldTriggerJumpFailureFeedbackWhenAllAttemptsFail() {
        XCTAssertTrue(shouldTriggerJumpFailureFeedback([false, false, false]))
    }

    func testShouldNotTriggerJumpFailureFeedbackWhenAnyAttemptSucceeds() {
        XCTAssertFalse(shouldTriggerJumpFailureFeedback([false, true, false]))
    }

    func testJumpFailureShakeSequenceUsesFastAlternatingOffsets() {
        XCTAssertEqual(JumpAnimationHelper.shakeSequence, [8, -8, 6, -6, 3, -3, 0])
    }

    func testWeChatNativeActivationSkipsWorkspaceTitleMatching() {
        XCTAssertTrue(
            TerminalActivator.shouldUseDirectNativeAppActivation(
                source: "wechat",
                bundleId: "com.tencent.xinWeChat",
                cwd: "/Applications/WeChat.app"
            )
        )
    }

    func testProjectNativeActivationKeepsWorkspaceTitleMatching() {
        XCTAssertFalse(
            TerminalActivator.shouldUseDirectNativeAppActivation(
                source: "cursor",
                bundleId: "com.todesktop.230313mzl4w4u92",
                cwd: "/Users/example/project"
            )
        )
    }

    func testEvaluateJumpValidationReturnsSuccessWhenCheckSucceeds() async {
        var callCount = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: {
                callCount += 1
                return callCount == 2
            }
        )

        XCTAssertEqual(outcome, .success)
    }

    func testEvaluateJumpValidationReturnsFailedWhenAllChecksFail() async {
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { false },
            sleep: { _ in },
            checkSucceeded: { false }
        )

        XCTAssertEqual(outcome, .failed)
    }

    func testEvaluateJumpValidationReturnsCancelledBeforeCheckRuns() async {
        var checksRan = 0
        let outcome = await evaluateJumpValidation(
            delays: [1, 1, 1],
            isCancelled: { true },
            sleep: { _ in },
            checkSucceeded: {
                checksRan += 1
                return false
            }
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(checksRan, 0)
    }

    func testClickJumpCollapseTimelineShowsClickRingWhenCursorReachesClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)

        XCTAssertGreaterThan(timeline.expand, 0.95)
        XCTAssertTrue(timeline.showClickRing)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorToClickPointFaster() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.08)

        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineMovesCursorFullyOffscreenBeforeExpandStarts() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.80)

        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
    }

    func testClickJumpCollapseTimelineStartsExpandAfterCursorIsAlreadyOffscreen() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.85)

        XCTAssertGreaterThan(timeline.expand, 0.3)
        XCTAssertEqual(timeline.cursorX, 34, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 28, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeCollapseSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.38)

        XCTAssertGreaterThan(timeline.expand, 0.5)
        XCTAssertLessThan(timeline.expand, 0.7)
    }

    func testClickJumpCollapseTimelineUsesMouseLeaveLikeExpandSpeed() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.93)

        XCTAssertGreaterThanOrEqual(timeline.expand, 0.999)
    }

    func testClickJumpCollapseTimelineHoldsCollapsedStateForMiddleWindow() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.60)

        XCTAssertLessThanOrEqual(timeline.expand, 0.001)
        XCTAssertEqual(timeline.cursorX, 0, accuracy: 0.001)
        XCTAssertEqual(timeline.cursorY, 0, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLoopSeamIsSmooth() {
        let start = clickJumpCollapsePreviewTimeline(progress: 0)
        let end = clickJumpCollapsePreviewTimeline(progress: 1)

        XCTAssertEqual(start.expand, end.expand, accuracy: 0.001)
        XCTAssertEqual(start.cursorX, end.cursorX, accuracy: 0.001)
        XCTAssertEqual(start.cursorY, end.cursorY, accuracy: 0.001)
    }

    func testClickJumpCollapseTimelineLowersClickPoint() {
        let timeline = clickJumpCollapsePreviewTimeline(progress: 0.26)
        XCTAssertEqual(timeline.clickPointY, 16.0, accuracy: 0.1)
    }

    func testWeChatSummaryShowsTwoSendersVertically() {
        let summary = AppState.summarizeWeChatNotifications([
            AppState.WeChatNotif(sender: "张三", body: "在吗"),
            AppState.WeChatNotif(sender: "李四", body: "收到"),
        ], badge: "2")

        XCTAssertEqual(summary, "张三: 在吗\n李四: 收到")
    }

    func testWeChatSummaryDropsBodiesWhenManySendersArrive() {
        let summary = AppState.summarizeWeChatNotifications([
            AppState.WeChatNotif(sender: "张三", body: "1"),
            AppState.WeChatNotif(sender: "李四", body: "2"),
            AppState.WeChatNotif(sender: "王五", body: "3"),
            AppState.WeChatNotif(sender: "赵六", body: "4"),
            AppState.WeChatNotif(sender: "钱七", body: "5"),
        ], badge: "5")

        XCTAssertEqual(summary, "张三 发来消息\n李四 发来消息\n王五 发来消息\n赵六 发来消息\n等 5 人发来消息")
    }

    func testWeChatSummaryOnlyUsesUnreadBadgeCount() {
        let summary = AppState.summarizeWeChatNotifications([
            AppState.WeChatNotif(sender: "新联系人", body: "刚发的"),
            AppState.WeChatNotif(sender: "旧联系人", body: "已读旧消息"),
        ], badge: "1")

        XCTAssertEqual(summary, "新联系人: 刚发的")
    }

    func testWeChatPollIntervalBurstsAfterChange() {
        XCTAssertEqual(
            AppState.weChatPollInterval(isBursting: true, burstUntil: Date(timeIntervalSinceReferenceDate: 10), now: Date(timeIntervalSinceReferenceDate: 5)),
            0.03,
            accuracy: 0.001
        )
    }

    func testWeChatPollIntervalReturnsToIdleAfterBurst() {
        XCTAssertEqual(
            AppState.weChatPollInterval(isBursting: true, burstUntil: Date(timeIntervalSinceReferenceDate: 5), now: Date(timeIntervalSinceReferenceDate: 10)),
            0.2,
            accuracy: 0.001
        )
    }

}
