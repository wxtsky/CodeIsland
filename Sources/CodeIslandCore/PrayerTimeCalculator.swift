import Foundation

/// Pure, stateless astronomical calculator based on Jean Meeus' "Astronomical Algorithms".
public enum PrayerTimeCalculator {

    // MARK: - Public API

    /// Calculates daily prayer schedule for a specific day, coordinates, and calculation method.
    public static func calculate(
        day: YearMonthDay,
        coordinates: Coordinates,
        elevationMeters: Double = 0,
        method: PrayerCalculationMethod,
        timeZone: TimeZone
    ) -> DailyPrayerSchedule {
        let latRad = d2r(coordinates.latitude)
        let lonDeg = coordinates.longitude
        let tzHours = Double(timeZone.secondsFromGMT()) / 3600.0

        // 1. Julian Day at 12h UT
        let jd = JulianDayCalculator.julianDay(year: day.year, month: day.month, day: Double(day.day))
        let t = (jd - 2451545.0) / 36525.0

        // 2. Solar coordinates (Meeus Astronomical Algorithms)
        let l0 = normalizeDegrees(280.46646 + 36000.76983 * t + 0.0003032 * t * t)
        let m = normalizeDegrees(357.52911 + 35999.05029 * t - 0.0001537 * t * t)
        let mRad = d2r(m)

        let c = (1.914602 - 0.004817 * t - 0.000014 * t * t) * sin(mRad)
            + (0.019993 - 0.000101 * t) * sin(2 * mRad)
            + 0.000289 * sin(3 * mRad)

        let sunTrue = l0 + c
        let omega = 125.04 - 1934.136 * t
        let lambda = sunTrue - 0.00569 - 0.00478 * sin(d2r(omega))

        let eps0 = 23.439291 - 0.0130042 * t - 0.00000016 * t * t + 0.000000504 * t * t * t
        let eps = eps0 + 0.00256 * cos(d2r(omega))

        let epsRad = d2r(eps)
        let lambdaRad = d2r(lambda)

        let sinDelta = sin(epsRad) * sin(lambdaRad)
        let deltaRad = asin(sinDelta)
        let cosDelta = cos(deltaRad)
        var raDeg = r2d(atan2(cos(epsRad) * sin(lambdaRad), cos(lambdaRad)))
        raDeg = normalizeDegrees(raDeg)

        // Equation of Time in minutes
        var diff = l0 - raDeg
        while diff > 180.0 { diff -= 360.0 }
        while diff < -180.0 { diff += 360.0 }
        let eotMinutes = diff * 4.0

        // Solar transit (Noon / Istiwa) in local hours
        let transitHours = 12.0 + tzHours - (lonDeg / 15.0) - (eotMinutes / 60.0)

        // Helper to solve hour angle H in hours for a given solar altitude
        func hourAngle(altitudeDeg: Double) -> Double {
            let altRad = d2r(altitudeDeg)
            let cosH = (sin(altRad) - sin(latRad) * sinDelta) / (cos(latRad) * cosDelta)
            let clampedCosH = max(-1.0, min(1.0, cosH))
            return r2d(acos(clampedCosH)) / 15.0
        }

        // Subuh & Imsak
        let hSubuh = hourAngle(altitudeDeg: -method.fajrAngle)
        var subuhHours = transitHours - hSubuh
        if method == .kemenag {
            subuhHours += 2.0 / 60.0 // +2m ihtiyati
        }
        let imsakHours = subuhHours - (10.0 / 60.0) // 10m before Subuh

        // Sunrise (Terbit)
        let sunriseAlt: Double
        var sunriseAdjustMins: Double = 0
        switch method {
        case .kemenag:
            sunriseAlt = -1.0 // Standard Indonesian Falak baseline (-60' accounting for semidiameter, refraction, and nominal dip)
            sunriseAdjustMins = -2.0 - kemenagElevationMinutes(elevationMeters) // -2m ihtiyati & elevation
        case .nuLFPBNU:
            let dip = apparentDip(elevationMeters: elevationMeters)
            sunriseAlt = -0.8333 - dip
            sunriseAdjustMins = 0
        case .muhammadiyah:
            sunriseAlt = -0.8333
            sunriseAdjustMins = 0
        }
        let hRise = hourAngle(altitudeDeg: sunriseAlt)
        let terbitHours = transitHours - hRise + (sunriseAdjustMins / 60.0)

        // Dhuha (+4.5°)
        let hDhuha = hourAngle(altitudeDeg: method.dhuhaAngle)
        var dhuhaHours = transitHours - hDhuha
        if method == .kemenag {
            dhuhaHours += 2.0 / 60.0
        }

        // Dzuhur
        var dzuhurHours = transitHours + (method.dhuhrMinutesAfterTransit / 60.0)
        if method == .kemenag {
            dzuhurHours += 2.0 / 60.0 // +2m ihtiyati
        }

        // Ashar (Shafi'i shadow multiplier m = 1)
        let asrAltRad = atan(1.0 / (1.0 + tan(abs(latRad - deltaRad))))
        let asrAltDeg = r2d(asrAltRad)
        let hAshar = hourAngle(altitudeDeg: asrAltDeg)
        var asharHours = transitHours + hAshar
        if method == .kemenag {
            asharHours += 2.0 / 60.0
        }

        // Maghrib
        let sunsetAlt: Double
        var sunsetAdjustMins: Double = 0
        switch method {
        case .kemenag:
            sunsetAlt = -1.0
            sunsetAdjustMins = 2.0 + kemenagElevationMinutes(elevationMeters) // +2m ihtiyati & elevation
        case .nuLFPBNU:
            let dip = apparentDip(elevationMeters: elevationMeters)
            sunsetAlt = -0.8333 - dip
            sunsetAdjustMins = 0
        case .muhammadiyah:
            sunsetAlt = -0.8333
            sunsetAdjustMins = 0
        }
        let hMaghrib = hourAngle(altitudeDeg: sunsetAlt)
        let maghribHours = transitHours + hMaghrib + (sunsetAdjustMins / 60.0)

        // Isya
        let hIsya = hourAngle(altitudeDeg: -method.ishaAngle)
        var isyaHours = transitHours + hIsya
        if method == .kemenag {
            isyaHours += 2.0 / 60.0
        }

        // Build Dates
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone

        func toDate(_ hours: Double) -> Date {
            let totalMinutes: Int
            if method.usesCeilRounding {
                totalMinutes = Int(ceil(hours * 60.0))
            } else {
                totalMinutes = Int(round(hours * 60.0))
            }

            var comps = DateComponents()
            comps.year = day.year
            comps.month = day.month
            comps.day = day.day
            comps.hour = (totalMinutes / 60) % 24
            comps.minute = totalMinutes % 60
            comps.second = 0
            return cal.date(from: comps) ?? Date()
        }

        return DailyPrayerSchedule(
            day: day,
            method: method,
            imsak: toDate(imsakHours),
            subuh: toDate(subuhHours),
            terbit: toDate(terbitHours),
            dhuha: toDate(dhuhaHours),
            dzuhur: toDate(dzuhurHours),
            ashar: toDate(asharHours),
            maghrib: toDate(maghribHours),
            isya: toDate(isyaHours)
        )
    }

    // MARK: - Private Math Helpers

    private static func d2r(_ d: Double) -> Double { d * .pi / 180.0 }
    private static func r2d(_ r: Double) -> Double { r * 180.0 / .pi }

    private static func normalizeDegrees(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360.0)
        if d < 0 { d += 360.0 }
        return d
    }

    private static func apparentDip(elevationMeters: Double) -> Double {
        0.02933 * sqrt(max(0, elevationMeters))
    }

    private static func kemenagElevationMinutes(_ elevationMeters: Double) -> Double {
        switch elevationMeters {
        case ..<250:
            return 0
        case 250..<700:
            return 1
        case 700..<1000:
            return 2
        case 1000..<1500:
            return 3
        case 1500..<2000:
            return 4
        case 2000..<2500:
            return 5
        default:
            return 6
        }
    }
}
