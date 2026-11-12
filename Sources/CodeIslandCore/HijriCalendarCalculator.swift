import Foundation

/// Supported Islamic calendar calculation criteria.
public enum HijriCalendarSource: String, CaseIterable, Sendable, Codable {
    /// Kalender Hijriah Global Tunggal (Muhammadiyah / 2016 Istanbul Congress: 5° altitude / 8° elongation global).
    case khgt

    /// Takwim Standar Indonesia (Kemenag RI / Neo-MABIMS: 3° altitude / 6.4° elongation regional).
    case neoMABIMS

    public var displayName: String {
        switch self {
        case .khgt:
            return "KHGT (Global Tunggal)"
        case .neoMABIMS:
            return "Takwim Kemenag (Neo-MABIMS)"
        }
    }
}

/// A calendar date representation in the Islamic (Hijri) lunar calendar.
public struct HijriDate: Equatable, Sendable, Codable, Hashable {
    public let day: Int
    public let month: Int
    public let year: Int
    public let monthName: String

    public init(day: Int, month: Int, year: Int, monthName: String? = nil) {
        self.day = day
        self.month = month
        self.year = year
        self.monthName = monthName ?? Self.name(forMonth: month)
    }

    public var formattedString: String {
        "\(day) \(monthName) \(year)"
    }

    public static func name(forMonth month: Int) -> String {
        switch month {
        case 1: return "Muharram"
        case 2: return "Safar"
        case 3: return "Rabi' al-Awwal"
        case 4: return "Rabi' al-Thani"
        case 5: return "Jumada al-Ula"
        case 6: return "Jumada al-Akhirah"
        case 7: return "Rajab"
        case 8: return "Sha'ban"
        case 9: return "Ramadan"
        case 10: return "Shawwal"
        case 11: return "Dhu al-Qi'dah"
        case 12: return "Dhu al-Hijjah"
        default: return "Month \(month)"
        }
    }
}

/// Calculator for Islamic (Hijri) dates using verified 1447–1451 H tables and astronomical fallback.
public enum HijriCalendarCalculator {

    // MARK: - Public API

    public static func calculate(
        date: Date,
        source: HijriCalendarSource,
        manualOffsetDays: Int = 0,
        timeZone: TimeZone
    ) -> HijriDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let ymd = YearMonthDay(year: comps.year ?? 2026, month: comps.month ?? 1, day: comps.day ?? 1)
        return calculate(day: ymd, source: source, manualOffsetDays: manualOffsetDays)
    }

    public static func calculate(
        day: YearMonthDay,
        source: HijriCalendarSource,
        manualOffsetDays: Int = 0
    ) -> HijriDate {
        let targetJD = JulianDayCalculator.julianDay(year: day.year, month: day.month, day: Double(day.day)) + Double(manualOffsetDays)

        // 1. Check tabular table (1447 H - 1451 H)
        let table = (source == .khgt) ? khgtBoundaries : neoMABIMSBoundaries
        if let firstEntry = table.first, let lastEntry = table.last {
            let firstJD = firstEntry.jd
            // Estimate end of 1451 H Zulhijah (~30 days after last month start)
            let endTableJD = lastEntry.jd + 30.0

            if targetJD >= firstJD && targetJD < endTableJD {
                // Find month boundary where targetJD >= month.jd
                var matchedIndex = 0
                for (i, entry) in table.enumerated() {
                    if targetJD >= entry.jd {
                        matchedIndex = i
                    } else {
                        break
                    }
                }
                let entry = table[matchedIndex]
                let dayOfHijriMonth = Int(targetJD - entry.jd) + 1
                return HijriDate(day: dayOfHijriMonth, month: entry.month, year: entry.year)
            }
        }

        // 2. Astronomical algorithmic fallback for dates outside 1447-1451 H
        return calculateAlgorithmic(targetJD: targetJD, source: source)
    }

    // MARK: - Private Tables & Algorithmic Calculation

    private struct MonthBoundary {
        let year: Int
        let month: Int
        let jd: Double
    }

    private static func makeBoundary(hYear: Int, hMonth: Int, gYear: Int, gMonth: Int, gDay: Int) -> MonthBoundary {
        let jd = JulianDayCalculator.julianDay(year: gYear, month: gMonth, day: Double(gDay))
        return MonthBoundary(year: hYear, month: hMonth, jd: jd)
    }

    // Official KHGT verified tabular boundaries (1447 H - 1451 H) from khgt.muhammadiyah.or.id
    private static let khgtBoundaries: [MonthBoundary] = [
        // 1447 H
        makeBoundary(hYear: 1447, hMonth: 1, gYear: 2025, gMonth: 6, gDay: 26),
        makeBoundary(hYear: 1447, hMonth: 2, gYear: 2025, gMonth: 7, gDay: 26),
        makeBoundary(hYear: 1447, hMonth: 3, gYear: 2025, gMonth: 8, gDay: 24),
        makeBoundary(hYear: 1447, hMonth: 4, gYear: 2025, gMonth: 9, gDay: 23),
        makeBoundary(hYear: 1447, hMonth: 5, gYear: 2025, gMonth: 10, gDay: 23),
        makeBoundary(hYear: 1447, hMonth: 6, gYear: 2025, gMonth: 11, gDay: 21),
        makeBoundary(hYear: 1447, hMonth: 7, gYear: 2025, gMonth: 12, gDay: 21),
        makeBoundary(hYear: 1447, hMonth: 8, gYear: 2026, gMonth: 1, gDay: 20),
        makeBoundary(hYear: 1447, hMonth: 9, gYear: 2026, gMonth: 2, gDay: 18),
        makeBoundary(hYear: 1447, hMonth: 10, gYear: 2026, gMonth: 3, gDay: 20),
        makeBoundary(hYear: 1447, hMonth: 11, gYear: 2026, gMonth: 4, gDay: 18),
        makeBoundary(hYear: 1447, hMonth: 12, gYear: 2026, gMonth: 5, gDay: 18),

        // 1448 H
        makeBoundary(hYear: 1448, hMonth: 1, gYear: 2026, gMonth: 6, gDay: 16),
        makeBoundary(hYear: 1448, hMonth: 2, gYear: 2026, gMonth: 7, gDay: 15),
        makeBoundary(hYear: 1448, hMonth: 3, gYear: 2026, gMonth: 8, gDay: 14),
        makeBoundary(hYear: 1448, hMonth: 4, gYear: 2026, gMonth: 9, gDay: 12),
        makeBoundary(hYear: 1448, hMonth: 5, gYear: 2026, gMonth: 10, gDay: 12),
        makeBoundary(hYear: 1448, hMonth: 6, gYear: 2026, gMonth: 11, gDay: 10),
        makeBoundary(hYear: 1448, hMonth: 7, gYear: 2026, gMonth: 12, gDay: 10),
        makeBoundary(hYear: 1448, hMonth: 8, gYear: 2027, gMonth: 1, gDay: 9),
        makeBoundary(hYear: 1448, hMonth: 9, gYear: 2027, gMonth: 2, gDay: 8),
        makeBoundary(hYear: 1448, hMonth: 10, gYear: 2027, gMonth: 3, gDay: 9),
        makeBoundary(hYear: 1448, hMonth: 11, gYear: 2027, gMonth: 4, gDay: 8),
        makeBoundary(hYear: 1448, hMonth: 12, gYear: 2027, gMonth: 5, gDay: 7),

        // 1449 H
        makeBoundary(hYear: 1449, hMonth: 1, gYear: 2027, gMonth: 6, gDay: 6),
        makeBoundary(hYear: 1449, hMonth: 2, gYear: 2027, gMonth: 7, gDay: 5),
        makeBoundary(hYear: 1449, hMonth: 3, gYear: 2027, gMonth: 8, gDay: 3),
        makeBoundary(hYear: 1449, hMonth: 4, gYear: 2027, gMonth: 9, gDay: 2),
        makeBoundary(hYear: 1449, hMonth: 5, gYear: 2027, gMonth: 10, gDay: 1),
        makeBoundary(hYear: 1449, hMonth: 6, gYear: 2027, gMonth: 10, gDay: 31),
        makeBoundary(hYear: 1449, hMonth: 7, gYear: 2027, gMonth: 11, gDay: 29),
        makeBoundary(hYear: 1449, hMonth: 8, gYear: 2027, gMonth: 12, gDay: 29),
        makeBoundary(hYear: 1449, hMonth: 9, gYear: 2028, gMonth: 1, gDay: 28),
        makeBoundary(hYear: 1449, hMonth: 10, gYear: 2028, gMonth: 2, gDay: 26),
        makeBoundary(hYear: 1449, hMonth: 11, gYear: 2028, gMonth: 3, gDay: 27),
        makeBoundary(hYear: 1449, hMonth: 12, gYear: 2028, gMonth: 4, gDay: 26),

        // 1450 H
        makeBoundary(hYear: 1450, hMonth: 1, gYear: 2028, gMonth: 5, gDay: 25),
        makeBoundary(hYear: 1450, hMonth: 2, gYear: 2028, gMonth: 6, gDay: 24),
        makeBoundary(hYear: 1450, hMonth: 3, gYear: 2028, gMonth: 7, gDay: 23),
        makeBoundary(hYear: 1450, hMonth: 4, gYear: 2028, gMonth: 8, gDay: 21),
        makeBoundary(hYear: 1450, hMonth: 5, gYear: 2028, gMonth: 9, gDay: 20),
        makeBoundary(hYear: 1450, hMonth: 6, gYear: 2028, gMonth: 10, gDay: 19),
        makeBoundary(hYear: 1450, hMonth: 7, gYear: 2028, gMonth: 11, gDay: 17),
        makeBoundary(hYear: 1450, hMonth: 8, gYear: 2028, gMonth: 12, gDay: 17),
        makeBoundary(hYear: 1450, hMonth: 9, gYear: 2029, gMonth: 1, gDay: 16),
        makeBoundary(hYear: 1450, hMonth: 10, gYear: 2029, gMonth: 2, gDay: 14),
        makeBoundary(hYear: 1450, hMonth: 11, gYear: 2029, gMonth: 3, gDay: 16),
        makeBoundary(hYear: 1450, hMonth: 12, gYear: 2029, gMonth: 4, gDay: 15),

        // 1451 H
        makeBoundary(hYear: 1451, hMonth: 1, gYear: 2029, gMonth: 5, gDay: 15),
        makeBoundary(hYear: 1451, hMonth: 2, gYear: 2029, gMonth: 6, gDay: 13),
        makeBoundary(hYear: 1451, hMonth: 3, gYear: 2029, gMonth: 7, gDay: 13),
        makeBoundary(hYear: 1451, hMonth: 4, gYear: 2029, gMonth: 8, gDay: 11),
        makeBoundary(hYear: 1451, hMonth: 5, gYear: 2029, gMonth: 9, gDay: 9),
        makeBoundary(hYear: 1451, hMonth: 6, gYear: 2029, gMonth: 10, gDay: 9),
        makeBoundary(hYear: 1451, hMonth: 7, gYear: 2029, gMonth: 11, gDay: 7),
        makeBoundary(hYear: 1451, hMonth: 8, gYear: 2029, gMonth: 12, gDay: 6),
        makeBoundary(hYear: 1451, hMonth: 9, gYear: 2030, gMonth: 1, gDay: 5),
        makeBoundary(hYear: 1451, hMonth: 10, gYear: 2030, gMonth: 2, gDay: 4),
        makeBoundary(hYear: 1451, hMonth: 11, gYear: 2030, gMonth: 3, gDay: 5),
        makeBoundary(hYear: 1451, hMonth: 12, gYear: 2030, gMonth: 4, gDay: 4)
    ]

    // Official Takwim Standar Indonesia (Neo-MABIMS 3° / 6.4°) verified tabular boundaries (1447 H - 1451 H)
    private static let neoMABIMSBoundaries: [MonthBoundary] = [
        // 1447 H (Note +1 day shift on 1 Muharam, 1 Rabiul Awal, 1 Ramadan, 1 Syawal as confirmed officially)
        makeBoundary(hYear: 1447, hMonth: 1, gYear: 2025, gMonth: 6, gDay: 27),
        makeBoundary(hYear: 1447, hMonth: 2, gYear: 2025, gMonth: 7, gDay: 26),
        makeBoundary(hYear: 1447, hMonth: 3, gYear: 2025, gMonth: 8, gDay: 25),
        makeBoundary(hYear: 1447, hMonth: 4, gYear: 2025, gMonth: 9, gDay: 23),
        makeBoundary(hYear: 1447, hMonth: 5, gYear: 2025, gMonth: 10, gDay: 23),
        makeBoundary(hYear: 1447, hMonth: 6, gYear: 2025, gMonth: 11, gDay: 21),
        makeBoundary(hYear: 1447, hMonth: 7, gYear: 2025, gMonth: 12, gDay: 21),
        makeBoundary(hYear: 1447, hMonth: 8, gYear: 2026, gMonth: 1, gDay: 20),
        makeBoundary(hYear: 1447, hMonth: 9, gYear: 2026, gMonth: 2, gDay: 19),
        makeBoundary(hYear: 1447, hMonth: 10, gYear: 2026, gMonth: 3, gDay: 21),
        makeBoundary(hYear: 1447, hMonth: 11, gYear: 2026, gMonth: 4, gDay: 19),
        makeBoundary(hYear: 1447, hMonth: 12, gYear: 2026, gMonth: 5, gDay: 18),

        // 1448 H
        makeBoundary(hYear: 1448, hMonth: 1, gYear: 2026, gMonth: 6, gDay: 16),
        makeBoundary(hYear: 1448, hMonth: 2, gYear: 2026, gMonth: 7, gDay: 16),
        makeBoundary(hYear: 1448, hMonth: 3, gYear: 2026, gMonth: 8, gDay: 15),
        makeBoundary(hYear: 1448, hMonth: 4, gYear: 2026, gMonth: 9, gDay: 13),
        makeBoundary(hYear: 1448, hMonth: 5, gYear: 2026, gMonth: 10, gDay: 13),
        makeBoundary(hYear: 1448, hMonth: 6, gYear: 2026, gMonth: 11, gDay: 11),
        makeBoundary(hYear: 1448, hMonth: 7, gYear: 2026, gMonth: 12, gDay: 11),
        makeBoundary(hYear: 1448, hMonth: 8, gYear: 2027, gMonth: 1, gDay: 10),
        makeBoundary(hYear: 1448, hMonth: 9, gYear: 2027, gMonth: 2, gDay: 8),
        makeBoundary(hYear: 1448, hMonth: 10, gYear: 2027, gMonth: 3, gDay: 10),
        makeBoundary(hYear: 1448, hMonth: 11, gYear: 2027, gMonth: 4, gDay: 8),
        makeBoundary(hYear: 1448, hMonth: 12, gYear: 2027, gMonth: 5, gDay: 8),

        // 1449 H
        makeBoundary(hYear: 1449, hMonth: 1, gYear: 2027, gMonth: 6, gDay: 6),
        makeBoundary(hYear: 1449, hMonth: 2, gYear: 2027, gMonth: 7, gDay: 6),
        makeBoundary(hYear: 1449, hMonth: 3, gYear: 2027, gMonth: 8, gDay: 4),
        makeBoundary(hYear: 1449, hMonth: 4, gYear: 2027, gMonth: 9, gDay: 3),
        makeBoundary(hYear: 1449, hMonth: 5, gYear: 2027, gMonth: 10, gDay: 2),
        makeBoundary(hYear: 1449, hMonth: 6, gYear: 2027, gMonth: 11, gDay: 1),
        makeBoundary(hYear: 1449, hMonth: 7, gYear: 2027, gMonth: 11, gDay: 30),
        makeBoundary(hYear: 1449, hMonth: 8, gYear: 2027, gMonth: 12, gDay: 30),
        makeBoundary(hYear: 1449, hMonth: 9, gYear: 2028, gMonth: 1, gDay: 29),
        makeBoundary(hYear: 1449, hMonth: 10, gYear: 2028, gMonth: 2, gDay: 27),
        makeBoundary(hYear: 1449, hMonth: 11, gYear: 2028, gMonth: 3, gDay: 28),
        makeBoundary(hYear: 1449, hMonth: 12, gYear: 2028, gMonth: 4, gDay: 27),

        // 1450 H
        makeBoundary(hYear: 1450, hMonth: 1, gYear: 2028, gMonth: 5, gDay: 26),
        makeBoundary(hYear: 1450, hMonth: 2, gYear: 2028, gMonth: 6, gDay: 25),
        makeBoundary(hYear: 1450, hMonth: 3, gYear: 2028, gMonth: 7, gDay: 24),
        makeBoundary(hYear: 1450, hMonth: 4, gYear: 2028, gMonth: 8, gDay: 22),
        makeBoundary(hYear: 1450, hMonth: 5, gYear: 2028, gMonth: 9, gDay: 21),
        makeBoundary(hYear: 1450, hMonth: 6, gYear: 2028, gMonth: 10, gDay: 20),
        makeBoundary(hYear: 1450, hMonth: 7, gYear: 2028, gMonth: 11, gDay: 18),
        makeBoundary(hYear: 1450, hMonth: 8, gYear: 2028, gMonth: 12, gDay: 18),
        makeBoundary(hYear: 1450, hMonth: 9, gYear: 2029, gMonth: 1, gDay: 17),
        makeBoundary(hYear: 1450, hMonth: 10, gYear: 2029, gMonth: 2, gDay: 15),
        makeBoundary(hYear: 1450, hMonth: 11, gYear: 2029, gMonth: 3, gDay: 17),
        makeBoundary(hYear: 1450, hMonth: 12, gYear: 2029, gMonth: 4, gDay: 16),

        // 1451 H
        makeBoundary(hYear: 1451, hMonth: 1, gYear: 2029, gMonth: 5, gDay: 16),
        makeBoundary(hYear: 1451, hMonth: 2, gYear: 2029, gMonth: 6, gDay: 14),
        makeBoundary(hYear: 1451, hMonth: 3, gYear: 2029, gMonth: 7, gDay: 14),
        makeBoundary(hYear: 1451, hMonth: 4, gYear: 2029, gMonth: 8, gDay: 12),
        makeBoundary(hYear: 1451, hMonth: 5, gYear: 2029, gMonth: 9, gDay: 10),
        makeBoundary(hYear: 1451, hMonth: 6, gYear: 2029, gMonth: 10, gDay: 10),
        makeBoundary(hYear: 1451, hMonth: 7, gYear: 2029, gMonth: 11, gDay: 8),
        makeBoundary(hYear: 1451, hMonth: 8, gYear: 2029, gMonth: 12, gDay: 7),
        makeBoundary(hYear: 1451, hMonth: 9, gYear: 2030, gMonth: 1, gDay: 6),
        makeBoundary(hYear: 1451, hMonth: 10, gYear: 2030, gMonth: 2, gDay: 5),
        makeBoundary(hYear: 1451, hMonth: 11, gYear: 2030, gMonth: 3, gDay: 6),
        makeBoundary(hYear: 1451, hMonth: 12, gYear: 2030, gMonth: 4, gDay: 5)
    ]

    private static func calculateAlgorithmic(targetJD: Double, source: HijriCalendarSource) -> HijriDate {
        // Reference epoch: 1 Muharam 1447 H (KHGT: JD 2460852.5 = 2025-06-26)
        let epochJD = 2460852.5
        let synodicMonth = 29.530588853
        let elapsedDays = targetJD - epochJD
        let elapsedMonths = floor(elapsedDays / synodicMonth)
        let totalMonths = 1447 * 12 + Int(elapsedMonths)

        let hYear = totalMonths / 12
        let hMonth = (totalMonths % 12) + 1

        let approxMonthStartJD = epochJD + (elapsedMonths * synodicMonth)
        var dayOfHijriMonth = Int(targetJD - approxMonthStartJD) + 1
        if dayOfHijriMonth < 1 { dayOfHijriMonth = 1 }
        if dayOfHijriMonth > 30 { dayOfHijriMonth = 30 }

        return HijriDate(day: dayOfHijriMonth, month: hMonth, year: hYear)
    }
}
