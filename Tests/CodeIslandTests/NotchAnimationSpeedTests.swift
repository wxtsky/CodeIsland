import XCTest
@testable import CodeIsland

final class NotchAnimationSpeedTests: XCTestCase {
    private var previousStoredSpeed: Any?

    override func setUp() {
        previousStoredSpeed = UserDefaults.standard.object(forKey: SettingsKey.notchAnimationSpeed)
    }

    override func tearDown() {
        if let previousStoredSpeed {
            UserDefaults.standard.set(previousStoredSpeed, forKey: SettingsKey.notchAnimationSpeed)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKey.notchAnimationSpeed)
        }
    }

    func testExplicitNonPositiveSpeedClampsToMinimum() {
        XCTAssertEqual(NotchAnimationSpeed.clamped(0), 0.5)
        XCTAssertEqual(NotchAnimationSpeed.clamped(-1), 0.5)
    }

    func testSpeedIsClampedToTheSliderRange() {
        XCTAssertEqual(NotchAnimationSpeed.clamped(0.1), 0.5)
        XCTAssertEqual(NotchAnimationSpeed.clamped(99), 2.0)
        XCTAssertEqual(NotchAnimationSpeed.clamped(1.3), 1.3, accuracy: 0.0001)
    }

    func testHigherSpeedShortensTheSpringResponse() {
        XCTAssertEqual(
            NotchAnimationSpeed.response(base: 0.42, speed: 2.0),
            0.21,
            accuracy: 0.0001
        )
    }

    func testLowerSpeedLengthensTheSpringResponse() {
        XCTAssertEqual(
            NotchAnimationSpeed.response(base: 0.42, speed: 0.5),
            0.84,
            accuracy: 0.0001
        )
    }

    func testShippedOpenAndCloseResponsesRemainDistinct() {
        XCTAssertEqual(NotchAnimationMetrics.baseOpenResponse, 0.42, accuracy: 0.0001)
        XCTAssertEqual(NotchAnimationMetrics.baseCloseResponse, 0.38, accuracy: 0.0001)
    }

    func testStoredSpeedScalesBothAnimationResponses() {
        UserDefaults.standard.set(2.0, forKey: SettingsKey.notchAnimationSpeed)

        XCTAssertEqual(NotchAnimationMetrics.openResponse, 0.21, accuracy: 0.0001)
        XCTAssertEqual(NotchAnimationMetrics.closeResponse, 0.19, accuracy: 0.0001)
    }

    func testMissingStoredSpeedUsesNormalResponses() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.notchAnimationSpeed)

        XCTAssertEqual(NotchAnimationMetrics.openResponse, 0.42, accuracy: 0.0001)
        XCTAssertEqual(NotchAnimationMetrics.closeResponse, 0.38, accuracy: 0.0001)
    }
}
