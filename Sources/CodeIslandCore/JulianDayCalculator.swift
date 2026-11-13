import Foundation

/// Pure mathematical Julian Day calculator based on Jean Meeus' "Astronomical Algorithms" (Chapter 7).
public enum JulianDayCalculator {

    /// Computes the Julian Day (JD) number for a given Gregorian calendar date at 12h UT.
    ///
    /// - Parameters:
    ///   - year: Gregorian calendar year (e.g. 2026).
    ///   - month: Gregorian month (1...12).
    ///   - day: Day of month, including fractional day (e.g. 15.0 or 15.5 for 12h UT).
    /// - Returns: Julian Day number as a Double.
    public static func julianDay(year: Int, month: Int, day: Double) -> Double {
        var y = year
        var m = month
        if m <= 2 {
            y -= 1
            m += 12
        }
        let a = floor(Double(y) / 100.0)
        let b = 2.0 - a + floor(a / 4.0)
        return floor(365.25 * Double(y + 4716)) + floor(30.6001 * Double(m + 1)) + day + b - 1524.5
    }
}
