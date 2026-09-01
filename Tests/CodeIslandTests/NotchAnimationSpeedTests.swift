import XCTest
@testable import CodeIsland

final class NotchAnimationSpeedTests: XCTestCase {
    /// `UserDefaults.double` yields 0 for an absent key. That must read as
    /// normal speed — dividing by it would produce an infinite response.
    func testUnsetValueReadsAsNormalSpeed() {
        XCTAssertEqual(NotchAnimationSpeed.clamped(0), NotchAnimationSpeed.normal)
        XCTAssertEqual(NotchAnimationSpeed.clamped(-3), NotchAnimationSpeed.normal)
    }

    func testClampsToRange() {
        XCTAssertEqual(NotchAnimationSpeed.clamped(0.1), NotchAnimationSpeed.minimum)
        XCTAssertEqual(NotchAnimationSpeed.clamped(99), NotchAnimationSpeed.maximum)
        XCTAssertEqual(NotchAnimationSpeed.clamped(1.3), 1.3, accuracy: 0.0001)
    }

    func testNormalSpeedLeavesBaseResponseUnchanged() {
        XCTAssertEqual(
            NotchAnimationSpeed.response(base: 0.42, speed: 1.0),
            0.42,
            accuracy: 0.0001
        )
    }

    func testHigherSpeedShortensResponse() {
        let fast = NotchAnimationSpeed.response(base: 0.42, speed: 2.0)
        let normal = NotchAnimationSpeed.response(base: 0.42, speed: 1.0)
        XCTAssertLessThan(fast, normal)
        XCTAssertEqual(fast, 0.21, accuracy: 0.0001)
    }

    func testLowerSpeedLengthensResponse() {
        let slow = NotchAnimationSpeed.response(base: 0.42, speed: 0.5)
        XCTAssertEqual(slow, 0.84, accuracy: 0.0001)
    }

    /// Every reachable slider position must stay a usable spring response —
    /// no zero, no runaway.
    func testEverySliderPositionProducesSaneResponse() {
        var speed = NotchAnimationSpeed.minimum
        while speed <= NotchAnimationSpeed.maximum + 0.0001 {
            let response = NotchAnimationSpeed.response(
                base: NotchAnimationMetrics.baseOpenResponse,
                speed: speed
            )
            XCTAssertGreaterThan(response, 0.1)
            XCTAssertLessThan(response, 1.0)
            speed += NotchAnimationSpeed.step
        }
    }

    func testOpenAndCloseShareTheSameBase() {
        XCTAssertEqual(
            NotchAnimationMetrics.baseOpenResponse,
            NotchAnimationMetrics.baseCloseResponse,
            accuracy: 0.0001
        )
    }
}

/// Shipped defaults for the settings added here. The contrast-edge and
/// hover-open defaults are asserted in `NotchGestureSettingsTests`, which owns
/// that pair.
final class NotchDefaultsTests: XCTestCase {
    func testMascotTintShipsOff() {
        XCTAssertFalse(SettingsDefaults.tintContrastEdgeWithMascot)
    }

    func testAnimationSpeedShipsAtNormal() {
        XCTAssertEqual(SettingsDefaults.notchAnimationSpeed, NotchAnimationSpeed.normal)
    }
}
