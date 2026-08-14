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
            headerWidth: 240,
            headerHeight: 38
        )

        XCTAssertTrue(hitbox.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY)))
        XCTAssertTrue(hitbox.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY - 20)))
    }

    func testRemainsRestrictedToCenteredNotchHeader() {
        let hitbox = NotchGestureHitbox(
            panelFrame: panelFrame,
            headerWidth: 240,
            headerHeight: 38
        )

        XCTAssertFalse(hitbox.contains(NSPoint(x: panelFrame.minX + 1, y: panelFrame.maxY - 20)))
        XCTAssertFalse(hitbox.contains(NSPoint(x: panelFrame.midX, y: panelFrame.maxY - 60)))
    }

    func testExpandedHeaderWidthExpandsGestureRegion() {
        let collapsed = NotchGestureHitbox(panelFrame: panelFrame, headerWidth: 240, headerHeight: 38)
        let expanded = NotchGestureHitbox(panelFrame: panelFrame, headerWidth: 520, headerHeight: 38)
        let point = NSPoint(x: panelFrame.midX + 220, y: panelFrame.maxY - 20)

        XCTAssertFalse(collapsed.contains(point))
        XCTAssertTrue(expanded.contains(point))
    }
}

@MainActor
final class NotchGestureMonitorTests: XCTestCase {
    func testObservedSwipeDownEmitsOpenBeforeGestureEnds() {
        let panelFrame = NSRect(x: 100, y: 300, width: 600, height: 500)
        let location = NSPoint(x: panelFrame.midX, y: panelFrame.maxY)
        let monitor = NotchGestureMonitor()
        monitor.isEnabled = true
        monitor.updateRegion(headerWidth: 240, headerHeight: 38)

        XCTAssertNil(monitor.consumeObservedSample(sample(y: 0, began: true), at: location, panelFrame: panelFrame))
        XCTAssertNil(monitor.consumeObservedSample(sample(y: -12), at: location, panelFrame: panelFrame))
        XCTAssertEqual(monitor.consumeObservedSample(sample(y: -13), at: location, panelFrame: panelFrame), .open)
        XCTAssertNil(monitor.consumeObservedSample(sample(ended: true), at: location, panelFrame: panelFrame))
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
