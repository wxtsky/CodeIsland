import Foundation

/// Calculated prayer milestones for a single calendar day.
public struct DailyPrayerSchedule: Equatable, Sendable {
    public let day: YearMonthDay
    public let method: PrayerCalculationMethod
    public let imsak: Date
    public let subuh: Date
    public let terbit: Date
    public let dhuha: Date
    public let dzuhur: Date
    public let ashar: Date
    public let maghrib: Date
    public let isya: Date

    public init(
        day: YearMonthDay,
        method: PrayerCalculationMethod,
        imsak: Date,
        subuh: Date,
        terbit: Date,
        dhuha: Date,
        dzuhur: Date,
        ashar: Date,
        maghrib: Date,
        isya: Date
    ) {
        self.day = day
        self.method = method
        self.imsak = imsak
        self.subuh = subuh
        self.terbit = terbit
        self.dhuha = dhuha
        self.dzuhur = dzuhur
        self.ashar = ashar
        self.maghrib = maghrib
        self.isya = isya
    }

    /// Access date for any prayer type.
    public func time(for type: PrayerType) -> Date {
        switch type {
        case .imsak: return imsak
        case .subuh: return subuh
        case .terbit: return terbit
        case .dhuha: return dhuha
        case .dzuhur: return dzuhur
        case .ashar: return ashar
        case .maghrib: return maghrib
        case .isya: return isya
        }
    }

    /// The 5 fardh prayers in chronological order.
    public var fivePrayers: [(prayer: PrayerType, date: Date)] {
        [
            (.subuh, subuh),
            (.dzuhur, dzuhur),
            (.ashar, ashar),
            (.maghrib, maghrib),
            (.isya, isya)
        ]
    }

    /// All 8 daily prayer milestones in chronological order.
    public var allMilestones: [(prayer: PrayerType, date: Date)] {
        [
            (.imsak, imsak),
            (.subuh, subuh),
            (.terbit, terbit),
            (.dhuha, dhuha),
            (.dzuhur, dzuhur),
            (.ashar, ashar),
            (.maghrib, maghrib),
            (.isya, isya)
        ]
    }

    private func nextMilestone(
        in items: [(prayer: PrayerType, date: Date)],
        after date: Date,
        tomorrowSubuh: Date?
    ) -> (prayer: PrayerType, date: Date)? {
        items.first(where: { $0.date > date }) ?? tomorrowSubuh.map { (.subuh, $0) }
    }

    /// Finds the upcoming prayer milestone relative to the reference date.
    /// If all today's prayers have passed and tomorrowSubuh is provided, returns tomorrow's Subuh.
    public func nextPrayer(at date: Date, tomorrowSubuh: Date? = nil) -> (prayer: PrayerType, date: Date)? {
        nextMilestone(in: allMilestones, after: date, tomorrowSubuh: tomorrowSubuh)
    }

    /// Finds the upcoming obligatory (fardh) prayer.
    public func nextFardhPrayer(at date: Date, tomorrowSubuh: Date? = nil) -> (prayer: PrayerType, date: Date)? {
        nextMilestone(in: fivePrayers, after: date, tomorrowSubuh: tomorrowSubuh)
    }

    /// Identifies the active prayer period based on the last arrived fardh prayer.
    public func currentFardhPrayer(at date: Date) -> PrayerType {
        if date < subuh {
            return .isya // Still night from previous day
        } else if date < dzuhur {
            return .subuh
        } else if date < ashar {
            return .dzuhur
        } else if date < maghrib {
            return .ashar
        } else if date < isya {
            return .maghrib
        } else {
            return .isya
        }
    }
}
