import XCTest
@testable import CodeIslandCore

final class PrayerTimeCalculatorTests: XCTestCase {

    // MARK: - Reference Cities & Coordinates

    private let bandaAceh = Coordinates(latitude: 5.5483, longitude: 95.3238)
    private let jakarta = Coordinates(latitude: -6.2088, longitude: 106.8456)
    private let surabaya = Coordinates(latitude: -7.2575, longitude: 112.7521)
    private let pontianak = Coordinates(latitude: 0.0000, longitude: 109.3333)
    private let makassar = Coordinates(latitude: -5.1477, longitude: 119.4327)
    private let jayapura = Coordinates(latitude: -2.5489, longitude: 140.7197)

    private let wib = TimeZone(secondsFromGMT: 7 * 3600)!
    private let wita = TimeZone(secondsFromGMT: 8 * 3600)!
    private let wit = TimeZone(secondsFromGMT: 9 * 3600)!

    // MARK: - Golden Reference Jakarta Baseline (2026-01-15)

    func testJakartaBaselineKemenagMatchesWithinOneMinute() {
        let day = YearMonthDay(year: 2026, month: 1, day: 15)
        let schedule = PrayerTimeCalculator.calculate(
            day: day,
            coordinates: jakarta,
            elevationMeters: 10,
            method: .kemenag,
            timeZone: wib
        )

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = wib

        func fmt(_ d: Date) -> String {
            let h = cal.component(.hour, from: d)
            let m = cal.component(.minute, from: d)
            return String(format: "%02d:%02d", h, m)
        }

        func assertDiffAtMostOneMinute(_ actualDate: Date, _ expectedStr: String, prayer: String) {
            let actualStr = fmt(actualDate)
            let expParts = expectedStr.split(separator: ":").compactMap { Int($0) }
            let expTotalMin = expParts[0] * 60 + expParts[1]

            let actH = cal.component(.hour, from: actualDate)
            let actM = cal.component(.minute, from: actualDate)
            let actTotalMin = actH * 60 + actM

            let diff = abs(actTotalMin - expTotalMin)
            XCTAssertLessThanOrEqual(
                diff, 1,
                "\(prayer) expected \(expectedStr) but got \(actualStr) (diff \(diff) min)"
            )
        }

        // Expected official Kemenag schedule for Jakarta on 2026-01-15
        assertDiffAtMostOneMinute(schedule.imsak, "04:17", prayer: "Imsak")
        assertDiffAtMostOneMinute(schedule.subuh, "04:27", prayer: "Subuh")
        assertDiffAtMostOneMinute(schedule.terbit, "05:45", prayer: "Terbit")
        assertDiffAtMostOneMinute(schedule.dzuhur, "05:45".isEmpty ? "12:05" : "12:05", prayer: "Dzuhur")
        assertDiffAtMostOneMinute(schedule.ashar, "15:30", prayer: "Ashar")
        assertDiffAtMostOneMinute(schedule.maghrib, "18:18", prayer: "Maghrib")
        assertDiffAtMostOneMinute(schedule.isya, "19:33", prayer: "Isya")
    }

    // MARK: - Seasonal Golden Fixtures Across 6 Cities

    func testSeasonalCalculationsAcrossSixCitiesProduceValidChronologicalOrder() {
        let cities: [(name: String, coord: Coordinates, tz: TimeZone, elev: Double)] = [
            ("Banda Aceh", bandaAceh, wib, 10),
            ("Jakarta", jakarta, wib, 10),
            ("Surabaya", surabaya, wib, 5),
            ("Pontianak", pontianak, wib, 3),
            ("Makassar", makassar, wita, 15),
            ("Jayapura", jayapura, wit, 25)
        ]

        let seasons = [
            YearMonthDay(year: 2026, month: 3, day: 20),  // Vernal Equinox
            YearMonthDay(year: 2026, month: 6, day: 21),  // Summer Solstice
            YearMonthDay(year: 2026, month: 9, day: 22),  // Autumnal Equinox
            YearMonthDay(year: 2026, month: 12, day: 21)  // Winter Solstice
        ]

        for city in cities {
            for season in seasons {
                for method in PrayerCalculationMethod.allCases {
                    let schedule = PrayerTimeCalculator.calculate(
                        day: season,
                        coordinates: city.coord,
                        elevationMeters: city.elev,
                        method: method,
                        timeZone: city.tz
                    )

                    // Verify strict chronological sequence: Imsak < Subuh < Terbit < Dhuha < Dzuhur < Ashar < Maghrib < Isya
                    XCTAssertLessThan(schedule.imsak, schedule.subuh, "\(city.name) \(season.month)/\(season.day) \(method)")
                    XCTAssertLessThan(schedule.subuh, schedule.terbit, "\(city.name) \(season.month)/\(season.day) \(method)")
                    XCTAssertLessThan(schedule.terbit, schedule.dhuha, "\(city.name) \(season.month)/\(season.day) \(method)")
                    XCTAssertLessThan(schedule.dhuha, schedule.dzuhur, "\(city.name) \(season.month)/\(season.day) \(method)")
                    XCTAssertLessThan(schedule.dzuhur, schedule.ashar, "\(city.name) \(season.month)/\(season.day) \(method)")
                    XCTAssertLessThan(schedule.ashar, schedule.maghrib, "\(city.name) \(season.month)/\(season.day) \(method)")
                    XCTAssertLessThan(schedule.maghrib, schedule.isya, "\(city.name) \(season.month)/\(season.day) \(method)")
                }
            }
        }
    }

    // MARK: - Method Comparison (Muhammadiyah vs Kemenag Subuh Difference)

    func testMuhammadiyahFajrIsLaterThanKemenagDueToAngleDifference() {
        let day = YearMonthDay(year: 2026, month: 1, day: 15)
        let kemenag = PrayerTimeCalculator.calculate(
            day: day, coordinates: jakarta, elevationMeters: 10, method: .kemenag, timeZone: wib)
        let muhammadiyah = PrayerTimeCalculator.calculate(
            day: day, coordinates: jakarta, elevationMeters: 10, method: .muhammadiyah, timeZone: wib)

        // Muhammadiyah (-18°) Subuh is approximately 6-9 minutes later than Kemenag (-20° + 2m ihtiyati)
        let diffMinutes = muhammadiyah.subuh.timeIntervalSince(kemenag.subuh) / 60.0
        XCTAssertGreaterThanOrEqual(diffMinutes, 5.0, "Muhammadiyah Subuh should be later than Kemenag")
        XCTAssertLessThanOrEqual(diffMinutes, 11.0, "Subuh difference between -18° and -20° in tropics is ~8m")
    }

    // MARK: - Next Prayer & Sequence Helpers

    func testNextPrayerDetection() {
        let day = YearMonthDay(year: 2026, month: 1, day: 15)
        let schedule = PrayerTimeCalculator.calculate(
            day: day, coordinates: jakarta, elevationMeters: 10, method: .kemenag, timeZone: wib)

        // 1. Time just before Dzuhur -> next fardh is Dzuhur
        let beforeDzuhur = schedule.dzuhur.addingTimeInterval(-600) // 10 mins before
        let nextFardh = schedule.nextFardhPrayer(at: beforeDzuhur)
        XCTAssertEqual(nextFardh?.prayer, .dzuhur)
        XCTAssertEqual(nextFardh?.date, schedule.dzuhur)

        // 2. Active prayer period
        XCTAssertEqual(schedule.currentFardhPrayer(at: beforeDzuhur), .subuh)
        XCTAssertEqual(schedule.currentFardhPrayer(at: schedule.dzuhur.addingTimeInterval(300)), .dzuhur)

        // 3. After Isya -> next with tomorrowSubuh
        let afterIsya = schedule.isya.addingTimeInterval(600)
        let tomorrowSubuh = schedule.subuh.addingTimeInterval(86400)
        let nextTomorrow = schedule.nextFardhPrayer(at: afterIsya, tomorrowSubuh: tomorrowSubuh)
        XCTAssertEqual(nextTomorrow?.prayer, .subuh)
        XCTAssertEqual(nextTomorrow?.date, tomorrowSubuh)
    }
}
