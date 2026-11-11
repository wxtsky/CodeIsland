import SwiftUI
import CodeIslandCore

/// The expanded living diorama clock and interactive prayer schedule card.
public struct PrayerExpandedCardView: View {
    @ObservedObject public var manager: PrayerTimeManager

    public init(manager: PrayerTimeManager) {
        self.manager = manager
    }

    public var body: some View {
        let upcoming = manager.upcomingPrayer
        let schedule = manager.todaySchedule
        let phase = manager.currentPhase

        VStack(spacing: 14) {
            // 1. Living Diorama Canvas Sky Card (138pt)
            ZStack(alignment: .topLeading) {
                DioramaSkyView(
                    hour: manager.currentFractionalHour,
                    hijriDay: manager.hijriDay,
                    sunriseHour: manager.sunriseHour,
                    sunsetHour: manager.sunsetHour,
                    skyline: true,
                    skylineHeight: 0.12
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    // Top Row: Phase Badge (Left) & Upcoming Prayer Countdown (Right)
                    HStack(alignment: .center) {
                        HStack(spacing: 6) {
                            Image(systemName: phase.systemImage)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                            Text(phase.displayName)
                                .font(.system(size: 9, weight: .heavy, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Color.black.opacity(0.35)))
                                .foregroundStyle(.white)
                        }

                        Spacer()

                        if let next = upcoming {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("\(next.prayer.displayName) \(manager.formattedPrayerTime(next.date))")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)

                                Text("-\(manager.formattedCountdown)")
                                    .font(.system(size: 18, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(phase.accentColor.opacity(0.45)))
                            }
                        }
                    }

                    Spacer(minLength: 6)

                    // Big Digital Clock
                    Text(manager.currentSecondsString)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer(minLength: 8)

                    // Centered Subtitle: City · Day Date · Hijri Date
                    let subtitle = "\(manager.cityName) · \(manager.gregorianDateString) · \(manager.hijriDateString)"
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                }
                .shadow(color: Color.black.opacity(0.7), radius: 2.5)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)
            }
            .frame(height: 138)

            // 2. Five Prayer Capsules (Subuh, Dzuhur, Ashar, Maghrib, Isya)
            if let sched = schedule {
                HStack(spacing: 6) {
                    ForEach(sched.fivePrayers, id: \.prayer.rawValue) { item in
                        let isNext = (item.prayer == upcoming?.prayer)
                        VStack(spacing: 2) {
                            Text(item.prayer.displayName)
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            Text(manager.formattedPrayerTime(item.date))
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(isNext ? Color.black : Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(isNext ? phase.accentColor : Color.white.opacity(0.08)))
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 24)
        .frame(maxWidth: 520)
    }
}
