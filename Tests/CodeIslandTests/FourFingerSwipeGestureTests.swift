import XCTest
@testable import CodeIsland

final class FourFingerSwipeGestureTests: XCTestCase {
    func testNoDirectionBelowThreshold() {
        XCTAssertNil(FourFingerSwipeGesture.direction(startX: 0.5, currentX: 0.55))
        XCTAssertNil(FourFingerSwipeGesture.direction(startX: 0.5, currentX: 0.45))
    }

    func testRightDirectionAtOrAboveThreshold() {
        XCTAssertEqual(FourFingerSwipeGesture.direction(startX: 0.5, currentX: 0.60), .right)
        XCTAssertEqual(FourFingerSwipeGesture.direction(startX: 0.5, currentX: 0.70), .right)
    }

    func testLeftDirectionAtOrBeyondThreshold() {
        XCTAssertEqual(FourFingerSwipeGesture.direction(startX: 0.5, currentX: 0.40), .left)
        XCTAssertEqual(FourFingerSwipeGesture.direction(startX: 0.5, currentX: 0.30), .left)
    }

    func testThresholdIsTenPercent() {
        XCTAssertEqual(FourFingerSwipeGesture.normalizedDisplacementThreshold, 0.10, accuracy: 0.0001)
    }
}
