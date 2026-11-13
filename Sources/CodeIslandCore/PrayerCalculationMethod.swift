import Foundation

/// Geographic coordinates on Earth in decimal degrees.
public struct Coordinates: Equatable, Sendable, Codable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Calendar day representation decoupled from TimeZone.
public struct YearMonthDay: Equatable, Sendable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init(date: Date, timeZone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        self.year = comps.year ?? 2026
        self.month = comps.month ?? 1
        self.day = comps.day ?? 1
    }

    public static func < (lhs: YearMonthDay, rhs: YearMonthDay) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

/// The specific Islamic prayer time calculation methodology.
public enum PrayerCalculationMethod: String, CaseIterable, Sendable, Codable {
    /// Indonesian Ministry of Religious Affairs (Kemenag RI):
    /// Subuh -20°, Isya -18°, Dzuhur istiwa + 2m, Ihtiyati +2m (and -2m for Terbit),
    /// elevation lookup table for Terbit and Maghrib. Nearest minute rounding.
    case kemenag

    /// Nahdlatul Ulama (Lembaga Falakiyah PBNU):
    /// Subuh -20°, Isya -18°, Dzuhur istiwa + 1m, true spherical dip elevation correction,
    /// 0 ihtiyati, ceiling minute rounding.
    case nuLFPBNU

    /// Muhammadiyah (Majelis Tarjih dan Tajdid):
    /// Subuh -18°, Isya -18°, Dzuhur istiwa + 0m, 0 ihtiyati, ceiling minute rounding.
    case muhammadiyah

    public var displayName: String {
        switch self {
        case .kemenag:
            return "Kemenag RI"
        case .nuLFPBNU:
            return "Nahdlatul Ulama (LF PBNU)"
        case .muhammadiyah:
            return "Muhammadiyah (MTT)"
        }
    }

    public var fajrAngle: Double {
        switch self {
        case .kemenag, .nuLFPBNU:
            return 20.0
        case .muhammadiyah:
            return 18.0
        }
    }

    public var ishaAngle: Double {
        return 18.0
    }

    public var dhuhaAngle: Double {
        return 4.5
    }

    public var dhuhrMinutesAfterTransit: Double {
        switch self {
        case .kemenag:
            return 2.0
        case .nuLFPBNU:
            return 1.0
        case .muhammadiyah:
            return 0.0
        }
    }

    public var usesCeilRounding: Bool {
        switch self {
        case .kemenag:
            return false
        case .nuLFPBNU, .muhammadiyah:
            return true
        }
    }
}

/// Distinct daily prayer and astronomical milestones.
public enum PrayerType: String, CaseIterable, Sendable, Codable {
    case imsak
    case subuh
    case terbit
    case dhuha
    case dzuhur
    case ashar
    case maghrib
    case isya

    public var displayName: String {
        switch self {
        case .imsak: return "Imsak"
        case .subuh: return "Fajr"
        case .terbit: return "Sunrise"
        case .dhuha: return "Duha"
        case .dzuhur: return "Dhuhr"
        case .ashar: return "Asr"
        case .maghrib: return "Maghrib"
        case .isya: return "Isha"
        }
    }

    /// The 5 fardh (obligatory) prayers.
    public var isFardh: Bool {
        switch self {
        case .subuh, .dzuhur, .ashar, .maghrib, .isya:
            return true
        case .imsak, .terbit, .dhuha:
            return false
        }
    }
}
