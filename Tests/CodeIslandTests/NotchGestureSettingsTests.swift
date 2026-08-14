import XCTest
@testable import CodeIsland

final class NotchGestureSettingsTests: XCTestCase {
    func testHoverSettingsPreserveExistingDefaults() {
        XCTAssertTrue(SettingsDefaults.openOnHover)
        XCTAssertEqual(SettingsDefaults.hoverOpenDelay, 0.5, accuracy: 0.001)
    }

    func testHoverDelayClampsValuesToSupportedRange() {
        XCTAssertEqual(HoverOpenDelay.clamped(-4), 0.1, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.clamped(0.7), 0.7, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.clamped(8), 1.5, accuracy: 0.001)
    }
}
