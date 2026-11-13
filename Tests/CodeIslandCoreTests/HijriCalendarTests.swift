import XCTest
@testable import CodeIslandCore

final class HijriCalendarTests: XCTestCase {

    func testKHGTMonthTransitions1447() {
        // 1 Muharam 1447 H KHGT is 26 June 2025
        let h1 = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2025, month: 6, day: 26),
            source: .khgt
        )
        XCTAssertEqual(h1.day, 1)
        XCTAssertEqual(h1.month, 1)
        XCTAssertEqual(h1.year, 1447)
        XCTAssertEqual(h1.monthName, "Muharram")

        // 1 Ramadan 1447 H KHGT is 18 February 2026
        let hRamadan = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2026, month: 2, day: 18),
            source: .khgt
        )
        XCTAssertEqual(hRamadan.day, 1)
        XCTAssertEqual(hRamadan.month, 9)
        XCTAssertEqual(hRamadan.year, 1447)
        XCTAssertEqual(hRamadan.monthName, "Ramadan")

        // 1 Shawwal 1447 H KHGT is 20 March 2026
        let hSyawal = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2026, month: 3, day: 20),
            source: .khgt
        )
        XCTAssertEqual(hSyawal.day, 1)
        XCTAssertEqual(hSyawal.month, 10)
        XCTAssertEqual(hSyawal.year, 1447)
        XCTAssertEqual(hSyawal.monthName, "Shawwal")
    }

    func testNeoMABIMSMonthTransitions1447() {
        // 1 Muharam 1447 H Neo-MABIMS is 27 June 2025 (1 day after KHGT)
        let h1 = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2025, month: 6, day: 27),
            source: .neoMABIMS
        )
        XCTAssertEqual(h1.day, 1)
        XCTAssertEqual(h1.month, 1)
        XCTAssertEqual(h1.year, 1447)

        // 1 Ramadan 1447 H Neo-MABIMS is 19 February 2026
        let hRamadan = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2026, month: 2, day: 19),
            source: .neoMABIMS
        )
        XCTAssertEqual(hRamadan.day, 1)
        XCTAssertEqual(hRamadan.month, 9)
        XCTAssertEqual(hRamadan.year, 1447)

        // 1 Syawal 1447 H Neo-MABIMS is 21 March 2026
        let hSyawal = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2026, month: 3, day: 21),
            source: .neoMABIMS
        )
        XCTAssertEqual(hSyawal.day, 1)
        XCTAssertEqual(hSyawal.month, 10)
        XCTAssertEqual(hSyawal.year, 1447)
    }

    func test1448HTurnOfYear() {
        // 1 Muharam 1448 H is 16 June 2026 in both calendars
        let khgt1448 = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2026, month: 6, day: 16),
            source: .khgt
        )
        XCTAssertEqual(khgt1448.day, 1)
        XCTAssertEqual(khgt1448.month, 1)
        XCTAssertEqual(khgt1448.year, 1448)

        let mabims1448 = HijriCalendarCalculator.calculate(
            day: YearMonthDay(year: 2026, month: 6, day: 16),
            source: .neoMABIMS
        )
        XCTAssertEqual(mabims1448.day, 1)
        XCTAssertEqual(mabims1448.month, 1)
        XCTAssertEqual(mabims1448.year, 1448)
    }

    func testManualOffsetAdjustment() {
        let baseDay = YearMonthDay(year: 2026, month: 3, day: 20)

        let zeroOffset = HijriCalendarCalculator.calculate(day: baseDay, source: .khgt, manualOffsetDays: 0)
        XCTAssertEqual(zeroOffset.day, 1)

        let plusOne = HijriCalendarCalculator.calculate(day: baseDay, source: .khgt, manualOffsetDays: 1)
        XCTAssertEqual(plusOne.day, 2)

        let minusOne = HijriCalendarCalculator.calculate(day: baseDay, source: .khgt, manualOffsetDays: -1)
        XCTAssertEqual(minusOne.day, 30) // Previous month 30th
        XCTAssertEqual(minusOne.month, 9)
    }

    func testFormattedString() {
        let date = HijriDate(day: 21, month: 5, year: 1448)
        XCTAssertEqual(date.formattedString, "21 Jumada al-Ula 1448")
    }

    func testAlgorithmicFallbackBeyond1451() {
        // Date in 2035 (well beyond 1451 H)
        let futureDay = YearMonthDay(year: 2035, month: 1, day: 1)
        let futureHijri = HijriCalendarCalculator.calculate(day: futureDay, source: .khgt)

        XCTAssertGreaterThan(futureHijri.year, 1455)
        XCTAssertTrue((1...12).contains(futureHijri.month))
        XCTAssertTrue((1...30).contains(futureHijri.day))
    }
}
