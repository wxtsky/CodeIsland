import XCTest
@testable import CodeIsland

final class NotchGestureSettingsTests: XCTestCase {
    func testHoverSettingsShipWithIntendedDefaults() {
        // Hover-to-open is opt-in: brushing the notch on the way to the menu
        // bar shouldn't expand the island.
        XCTAssertFalse(SettingsDefaults.openOnHover)
        XCTAssertEqual(SettingsDefaults.hoverOpenDelay, 0.5, accuracy: 0.001)
        XCTAssertFalse(SettingsDefaults.invertHorizontalSwipeDirection)
        XCTAssertTrue(SettingsDefaults.showContrastEdge)
        XCTAssertEqual(SettingsKey.showContrastEdge, "showContrastEdge")
    }

    func testHoverDelayClampsValuesToSupportedRange() {
        XCTAssertEqual(HoverOpenDelay.clamped(-4), 0.1, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.clamped(0.7), 0.7, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.clamped(8), 1.5, accuracy: 0.001)
    }
}
