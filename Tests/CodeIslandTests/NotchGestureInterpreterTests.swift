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
