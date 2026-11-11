import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class PrayerTimeManagerTests: XCTestCase {

    func testDayPhaseProperties() {
        XCTAssertEqual(DayPhase.pagi.displayName, "PAGI")
        XCTAssertEqual(DayPhase.siang.displayName, "SIANG")
        XCTAssertEqual(DayPhase.sore.displayName, "SORE")
        XCTAssertEqual(DayPhase.malam.displayName, "MALAM")

        XCTAssertFalse(DayPhase.pagi.systemImage.isEmpty)
        XCTAssertEqual(DayPhase.pagi.skyGradientColors.count, 2)
        XCTAssertEqual(DayPhase.sore.skyGradientColors.count, 3)
    }

    func testPriorityShiftNearPrayerTime() {
        let manager = PrayerTimeManager.shared

        // When prayer is disabled, never prioritize
        UserDefaults.standard.set(false, forKey: SettingsKey.prayerEnabled)
        XCTAssertFalse(manager.isPrayerPrioritized)
    }

    func testManagerRecalculatesAccuratelyWhenEnabled() {
        UserDefaults.standard.set(true, forKey: SettingsKey.prayerEnabled)
        UserDefaults.standard.set("kemenag", forKey: SettingsKey.prayerCalculationMethod)

        let manager = PrayerTimeManager.shared
        manager.forceRecalculate()

        XCTAssertNotNil(manager.todaySchedule)
        XCTAssertFalse(manager.currentTimeString.isEmpty)
        XCTAssertTrue((0.0...1.0).contains(manager.solarProgress))
        XCTAssertGreaterThan(manager.sunsetHour, manager.sunriseHour)
        XCTAssertTrue((4.0...7.0).contains(manager.sunriseHour))
        XCTAssertTrue((17.0...19.5).contains(manager.sunsetHour))

        // When disabled, timer and active schedule are cleanly torn down
        UserDefaults.standard.set(false, forKey: SettingsKey.prayerEnabled)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        XCTAssertFalse(manager.isEnabled)
    }
}
