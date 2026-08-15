import XCTest
@testable import CodeIsland

final class NotchGestureInterpreterTests: XCTestCase {
    func testPhysicalDirectionsMapToNaturalNotchActions() {
        // NSEvent's normalized device delta is positive when the fingers move
        // left, so the shipped direction advances the filters to the right.
        XCTAssertEqual(action(x: 30), .navigateNext)
        XCTAssertEqual(action(x: -30), .navigatePrevious)
        XCTAssertEqual(action(y: -30), .open)
        XCTAssertEqual(action(y: 30), .close)
    }

    func testGestureRequiresThresholdAndDominantAxis() {
        XCTAssertNil(action(x: 8))
        XCTAssertNil(action(x: 30, y: 28))
    }

    func testGestureEmitsOnlyOnceUntilEnded() {
        var interpreter = NotchGestureInterpreter()

        XCTAssertEqual(interpreter.consume(sample(x: -30)), .navigateNext)
        XCTAssertNil(interpreter.consume(sample(x: -30)))
        XCTAssertNil(interpreter.consume(sample(ended: true)))
        XCTAssertEqual(interpreter.consume(sample(x: -30, began: true)), .navigateNext)
    }

    func testMomentumAndNonPreciseScrollAreIgnored() {
        var interpreter = NotchGestureInterpreter()

        XCTAssertNil(interpreter.consume(sample(y: -40, momentum: true)))
        XCTAssertNil(interpreter.consume(sample(y: -40, precise: false)))
    }

    func testDeviceDirectionMetadataNormalizesPhysicalMovement() {
        let natural = NotchScrollSample(
            scrollingDeltaX: 30,
            scrollingDeltaY: -20,
            directionInvertedFromDevice: true
        )
        let traditional = NotchScrollSample(
            scrollingDeltaX: 30,
            scrollingDeltaY: -20,
            directionInvertedFromDevice: false
        )

        XCTAssertEqual(natural.physicalDeltaX, -30)
        XCTAssertEqual(natural.physicalDeltaY, 20)
        XCTAssertEqual(traditional.physicalDeltaX, 30)
        XCTAssertEqual(traditional.physicalDeltaY, -20)
    }

    private func action(x: CGFloat = 0, y: CGFloat = 0) -> NotchGestureAction? {
        var interpreter = NotchGestureInterpreter()
        return interpreter.consume(sample(x: x, y: y))
    }

    private func sample(
        x: CGFloat = 0,
        y: CGFloat = 0,
        began: Bool = false,
        ended: Bool = false,
        momentum: Bool = false,
        precise: Bool = true
    ) -> NotchScrollSample {
        NotchScrollSample(
            physicalDeltaX: x,
            physicalDeltaY: y,
            began: began,
            ended: ended,
            momentum: momentum,
            precise: precise
        )
    }
}

final class NotchGestureHitboxTests: XCTestCase {
    private let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)

    func testIncludesExactScreenTopAndPhysicalNotchBand() {
        let hitbox = NotchGestureHitbox(
            panelFrame: panelFrame,
            regionWidth: 240,
            regionHeight: 38
        )

        XCTAssertTrue(hitbox.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY)))
        XCTAssertTrue(hitbox.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY - 20)))
    }

    func testRemainsRestrictedToCenteredNotchHeader() {
        let hitbox = NotchGestureHitbox(
            panelFrame: panelFrame,
            regionWidth: 240,
            regionHeight: 38
        )

        XCTAssertFalse(hitbox.contains(NSPoint(x: panelFrame.minX + 1, y: panelFrame.maxY - 20)))
        XCTAssertFalse(hitbox.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY - 60)))
    }

    func testExpandedVisiblePanelExpandsGestureRegionInBothAxes() {
        let collapsed = NotchGestureHitbox(panelFrame: panelFrame, regionWidth: 240, regionHeight: 38)
        let expanded = NotchGestureHitbox(panelFrame: panelFrame, regionWidth: 520, regionHeight: 220)
        let point = NSPoint(x: panelFrame.midX + 220, y: panelFrame.maxY - 160)

        XCTAssertFalse(collapsed.contains(point))
        XCTAssertTrue(expanded.contains(point))
        XCTAssertFalse(expanded.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY - 240)))
    }
}

final class NotchGestureRegionMetricsTests: XCTestCase {
    func testUsesRenderedWidthInsteadOfAnimatedTargetWidth() {
        let resolved = NotchGestureRegionMetrics.resolvedSize(
            renderedSize: CGSize(width: 360, height: 120),
            fallbackWidth: 580,
            headerHeight: 38,
            isExpanded: true
        )

        XCTAssertEqual(resolved, CGSize(width: 360, height: 120))
    }

    func testCollapsedRegionKeepsRenderedWidthButCapsHeightToHeader() {
        let resolved = NotchGestureRegionMetrics.resolvedSize(
            renderedSize: CGSize(width: 300, height: 160),
            fallbackWidth: 240,
            headerHeight: 38,
            isExpanded: false
        )

        XCTAssertEqual(resolved, CGSize(width: 300, height: 38))
    }
}

@MainActor
final class NotchGestureMonitorTests: XCTestCase {
    func testPanelContextReadsTheControllersLiveFrame() {
        var frame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let context = NotchPanelInteractionContext(
            panelFrame: { frame },
            isActiveTerminalForeground: { false }
        )

        XCTAssertEqual(context.panelFrame(), frame)
        frame.origin.x = 220
        XCTAssertEqual(context.panelFrame(), frame)
    }

    func testObservedActionDeliveryDefersUIHandlerUntilScheduledWorkRuns() {
        var scheduledWork: (() -> Void)?
        var receivedActions: [NotchGestureAction] = []
        let delivery = NotchGestureActionDelivery { work in
            scheduledWork = work
        }

        delivery.deliver(.open) { action in
            receivedActions.append(action)
        }

        XCTAssertTrue(receivedActions.isEmpty)
        scheduledWork?()
        XCTAssertEqual(receivedActions, [.open])
    }

    func testObservedSwipeDownEmitsOpenBeforeGestureEnds() {
        let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let location = NSPoint(x: panelFrame.midX, y: panelFrame.maxY)
        let monitor = NotchGestureMonitor()
        monitor.isEnabled = true
        monitor.updateRegion(width: 240, height: 38)

        XCTAssertNil(monitor.consumeObservedSample(sample(y: 0, began: true), at: location, panelFrame: panelFrame))
        XCTAssertNil(monitor.consumeObservedSample(sample(y: -12), at: location, panelFrame: panelFrame))
        XCTAssertEqual(monitor.consumeObservedSample(sample(y: -13), at: location, panelFrame: panelFrame), .open)
        XCTAssertNil(monitor.consumeObservedSample(sample(ended: true), at: location, panelFrame: panelFrame))
    }

    func testObservedSwipeWorksBelowHeaderWhenExpandedRegionIncludesIt() {
        let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let location = NSPoint(x: panelFrame.midX + 180, y: panelFrame.maxY - 160)
        let monitor = NotchGestureMonitor()
        monitor.isEnabled = true
        monitor.updateRegion(width: 520, height: 220)

        XCTAssertNil(monitor.consumeObservedSample(sample(y: 0, began: true), at: location, panelFrame: panelFrame))
        XCTAssertEqual(monitor.consumeObservedSample(sample(y: 25), at: location, panelFrame: panelFrame), .close)
    }

    func testLiveVisibleContentFrameOverridesStaleMeasuredRegion() {
        let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let visibleContentFrame = NSRect(x: 140, y: 580, width: 520, height: 220)
        let location = NSPoint(x: panelFrame.midX + 220, y: panelFrame.maxY - 180)
        let monitor = NotchGestureMonitor()
        monitor.isEnabled = true
        monitor.updateRegion(width: 240, height: 38)
        monitor.updateVisibleContentFrame(visibleContentFrame, relativeTo: panelFrame)

        XCTAssertNil(monitor.consumeObservedSample(sample(y: 0, began: true), at: location, panelFrame: panelFrame))
        XCTAssertEqual(monitor.consumeObservedSample(sample(y: 25), at: location, panelFrame: panelFrame), .close)
    }

    func testPanelEventInTransparentRemainderIsRejected() {
        let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let visibleContentFrame = NSRect(x: 140, y: 580, width: 520, height: 220)
        let location = NSPoint(x: panelFrame.midX, y: visibleContentFrame.minY - 40)
        let monitor = NotchGestureMonitor()
        monitor.isEnabled = true
        monitor.updateRegion(width: 240, height: 38)
        monitor.updateVisibleContentFrame(visibleContentFrame, relativeTo: panelFrame)

        XCTAssertNil(monitor.consumeObservedSample(sample(y: 25, began: true), at: location, panelFrame: panelFrame))
    }

    func testLiveVisibleContentFrameTracksPanelMovement() {
        let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let visibleContentFrame = NSRect(x: 140, y: 580, width: 520, height: 220)
        let movedPanelFrame = panelFrame.offsetBy(dx: 700, dy: -120)
        let originalLocation = NSPoint(x: visibleContentFrame.midX, y: visibleContentFrame.midY)
        let movedLocation = NSPoint(x: originalLocation.x + 700, y: originalLocation.y - 120)
        let monitor = NotchGestureMonitor()
        monitor.isEnabled = true
        monitor.updateVisibleContentFrame(visibleContentFrame, relativeTo: panelFrame)

        XCTAssertNil(monitor.consumeObservedSample(
            sample(y: 25, began: true),
            at: originalLocation,
            panelFrame: movedPanelFrame
        ))
        XCTAssertNil(monitor.consumeObservedSample(
            sample(y: 0, began: true),
            at: movedLocation,
            panelFrame: movedPanelFrame
        ))
        XCTAssertEqual(monitor.consumeObservedSample(
            sample(y: 25),
            at: movedLocation,
            panelFrame: movedPanelFrame
        ), .close)
    }

    private func sample(
        y: CGFloat = 0,
        began: Bool = false,
        ended: Bool = false
    ) -> NotchScrollSample {
        NotchScrollSample(
            physicalDeltaX: 0,
            physicalDeltaY: y,
            began: began,
            ended: ended
        )
    }
}
