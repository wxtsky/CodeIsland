import XCTest
@testable import CodeIsland

final class FloatingLyricPresetTests: XCTestCase {

    func testAllFloatingLyricPresetsDefined() {
        let expectedCases: [FloatingLyricPreset] = [
            .pureText,
            .capsule,
            .frostedGlass,
            .neonHud,
            .seamlessGlass
        ]

        XCTAssertEqual(FloatingLyricPreset.allCases.count, 5)
        for preset in expectedCases {
            XCTAssertTrue(FloatingLyricPreset.allCases.contains(preset))
            XCTAssertFalse(preset.title.isEmpty)
            XCTAssertFalse(preset.shortLabel.isEmpty)
            XCTAssertFalse(preset.description.isEmpty)
        }
    }

    func testSeamlessGlassPresetProperties() {
        let preset = FloatingLyricPreset.seamlessGlass
        XCTAssertEqual(preset.rawValue, "seamlessGlass")
        XCTAssertEqual(preset.shortLabel, "SEAMLESS")
        XCTAssertTrue(preset.title.contains("Seamless Glass"))
    }

    func testPresetRawValuesRoundTrip() {
        for preset in FloatingLyricPreset.allCases {
            let roundTrip = FloatingLyricPreset(rawValue: preset.rawValue)
            XCTAssertEqual(roundTrip, preset)
        }
    }
}
