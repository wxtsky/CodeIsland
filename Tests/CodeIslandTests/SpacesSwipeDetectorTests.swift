import XCTest
@testable import CodeIsland

final class SpacesSwipeFingerCountsTests: XCTestCase {
    func testFourFingerOnlyWhenThreeFingerDisabled() {
        XCTAssertEqual(
            SpacesSwipeFingerCounts.resolve(threeFinger: 0, fourFinger: 2),
            [4]
        )
    }

    func testThreeFingerOnlyWhenFourFingerDisabled() {
        XCTAssertEqual(
            SpacesSwipeFingerCounts.resolve(threeFinger: 2, fourFinger: 0),
            [3]
        )
    }

    func testBothWhenBothEnabled() {
        XCTAssertEqual(
            SpacesSwipeFingerCounts.resolve(threeFinger: 2, fourFinger: 2),
            [3, 4]
        )
    }

    /// The user turned the system gesture off entirely — there is no Spaces
    /// swipe to observe, so detection should stay silent rather than guess.
    func testEmptyWhenBothDisabled() {
        XCTAssertEqual(
            SpacesSwipeFingerCounts.resolve(threeFinger: 0, fourFinger: 0),
            []
        )
    }

    /// Preferences unreadable: accept either, since a spurious collapse costs
    /// far less than never collapsing at all.
    func testAcceptsBothWhenPreferencesAbsent() {
        XCTAssertEqual(
            SpacesSwipeFingerCounts.resolve(threeFinger: nil, fourFinger: nil),
            [3, 4]
        )
    }
}

final class SpacesSwipeDetectorTests: XCTestCase {
    private func fourFingers(at x: CGFloat) -> [CGFloat] {
        [x - 0.05, x, x + 0.05, x + 0.10]
    }

    func testFiresOnceThresholdCrossedToTheRight() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.30)))
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.35)))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.41)))
    }

    func testFiresOnThresholdCrossedToTheLeft() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.70)))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.59)))
    }

    /// One collapse per gesture — the panel must not be re-collapsed on every
    /// remaining frame of the same swipe.
    func testDoesNotFireTwiceWithinOneGesture() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        _ = detector.consume(touchingX: fourFingers(at: 0.30))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.45)))
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.60)))
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.75)))
    }

    func testSmallJitterNeverFires() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        _ = detector.consume(touchingX: fourFingers(at: 0.50))
        for x in stride(from: CGFloat(0.50), through: 0.58, by: 0.01) {
            XCTAssertFalse(detector.consume(touchingX: fourFingers(at: x)))
        }
    }

    func testWrongFingerCountIsIgnored() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        XCTAssertFalse(detector.consume(touchingX: [0.30, 0.35]))
        XCTAssertFalse(detector.consume(touchingX: [0.60, 0.65]))
    }

    /// Lifting fingers mid-swipe must rebaseline, so a later swipe starting
    /// from the new position isn't measured against the abandoned one.
    func testLiftingFingersResetsBaseline() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        _ = detector.consume(touchingX: fourFingers(at: 0.30))
        XCTAssertFalse(detector.consume(touchingX: []))
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.45)))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.56)))
    }

    func testDisabledFingerCountsNeverFire() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [])
        _ = detector.consume(touchingX: fourFingers(at: 0.20))
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.90)))
    }

    /// A gesture that ends and restarts should be able to fire again.
    func testFiresAgainOnASecondGesture() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        _ = detector.consume(touchingX: fourFingers(at: 0.30))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.45)))
        _ = detector.consume(touchingX: [])
        _ = detector.consume(touchingX: fourFingers(at: 0.30))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.45)))
    }

    /// Only fingers actually down should steer the average.
    func testHoveringContactsAreExcludedByCaller() {
        var detector = SpacesSwipeDetector(acceptedFingerCounts: [4])
        // Caller filters to touching contacts; a 5-element frame that filters
        // down to 4 is what the monitor hands over.
        XCTAssertFalse(detector.consume(touchingX: fourFingers(at: 0.30)))
        XCTAssertTrue(detector.consume(touchingX: fourFingers(at: 0.42)))
    }
}
