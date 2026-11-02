import XCTest
@testable import CodeIsland

/// Settings → General → Display pins a display by its UUID: the place of a
/// display in `NSScreen.screens` follows the primary display, so an index
/// pinned another display once that changed.
final class DisplayChoiceTests: XCTestCase {
    private let builtIn = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    private let monitor = "9A4B2C61-7E35-4F0A-8D2B-1C6E5F3A7B90"

    func testAutoAndUnknownValuesFollowAuto() {
        for choice in ["auto", "", "builtin", "main", "screen_", "screen_x", "screen_-1", "display:"] {
            XCTAssertEqual(DisplayChoice.resolve(choice, displayUUIDs: [builtIn, monitor]), .auto, choice)
            XCTAssertNil(DisplayChoice.migrated(choice, displayUUIDs: [builtIn, monitor]), choice)
        }
    }

    /// The monitor made the primary display moves to the front of the list;
    /// the pin stays on it.
    func testAPinFollowsItsDisplayWhenTheOrderChanges() {
        let choice = "display:\(monitor)"
        XCTAssertEqual(DisplayChoice.resolve(choice, displayUUIDs: [builtIn, monitor]), .pinned(index: 1))
        XCTAssertEqual(DisplayChoice.resolve(choice, displayUUIDs: [monitor, builtIn]), .pinned(index: 0))
    }

    /// Unplugged, the monitor's pin waits: Auto stands in, nothing is
    /// rewritten, and plugged back in the island returns to it.
    func testAPinToADisplayThatIsNotConnectedWaitsForIt() {
        let choice = "display:\(monitor)"
        XCTAssertEqual(DisplayChoice.resolve(choice, displayUUIDs: [builtIn]), .pinnedDisplayMissing)
        XCTAssertNil(DisplayChoice.migrated(choice, displayUUIDs: [builtIn]))
        XCTAssertEqual(DisplayChoice.resolve(choice, displayUUIDs: [monitor, builtIn]), .pinned(index: 0))
    }

    // MARK: - Legacy index pins

    func testALegacyIndexResolvesAsBeforeAndTakesItsDisplaysUUID() {
        XCTAssertEqual(DisplayChoice.resolve("screen_1", displayUUIDs: [builtIn, monitor]), .pinned(index: 1))
        XCTAssertEqual(DisplayChoice.migrated("screen_1", displayUUIDs: [builtIn, monitor]), "display:\(monitor)")
        XCTAssertEqual(
            DisplayChoice.resolve("display:\(monitor)", displayUUIDs: [builtIn, monitor]), .pinned(index: 1),
            "the rewritten value names the same display"
        )
    }

    /// Out of range it falls back to Auto, as it did, and is only rewritten
    /// once it resolves.
    func testALegacyIndexOutOfRangeFallsBackToAutoAndIsKept() {
        XCTAssertEqual(DisplayChoice.resolve("screen_1", displayUUIDs: [builtIn]), .pinnedDisplayMissing)
        XCTAssertNil(DisplayChoice.migrated("screen_1", displayUUIDs: [builtIn]))
    }

    /// A display without a UUID can only be named by its index.
    func testADisplayWithoutAUUIDKeepsItsIndex() {
        XCTAssertEqual(DisplayChoice.resolve("screen_1", displayUUIDs: [builtIn, nil]), .pinned(index: 1))
        XCTAssertNil(DisplayChoice.migrated("screen_1", displayUUIDs: [builtIn, nil]))
        XCTAssertEqual(DisplayChoice.tag(forDisplayAt: 1, displayUUIDs: [builtIn, nil]), "screen_1")
    }

    // MARK: - Picker

    func testPickerRowsAreTaggedByUUID() {
        XCTAssertEqual(DisplayChoice.tag(forDisplayAt: 0, displayUUIDs: [builtIn, monitor]), "display:\(builtIn)")
        XCTAssertEqual(DisplayChoice.tag(forDisplayAt: 1, displayUUIDs: [builtIn, monitor]), "display:\(monitor)")
    }

    func testThePickerSelectsTheStoredChoicesRow() {
        let uuids = [builtIn, monitor]
        XCTAssertEqual(DisplayChoice.pickerSelection("auto", displayUUIDs: uuids), "auto")
        XCTAssertEqual(DisplayChoice.pickerSelection("builtin", displayUUIDs: uuids), "auto")
        XCTAssertEqual(DisplayChoice.pickerSelection("display:\(monitor)", displayUUIDs: uuids), "display:\(monitor)")
        // Not yet rewritten, a legacy pin still selects its display's row.
        XCTAssertEqual(DisplayChoice.pickerSelection("screen_1", displayUUIDs: uuids), "display:\(monitor)")
        // A pin to a display that isn't connected selects its own row.
        XCTAssertEqual(DisplayChoice.pickerSelection("display:\(monitor)", displayUUIDs: [builtIn]), "display:\(monitor)")
    }
}
