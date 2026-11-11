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

        VStack(spacing: 12) {
            // 1. Living Diorama Canvas Sky Card (~142pt)
            ZStack(alignment: .topLeading) {
                DioramaSkyView(
                    hour: manager.currentFractionalHour,
                    hijriDay: manager.hijriDay,
                    sunriseHour: manager.sunriseHour,
                    sunsetHour: manager.sunsetHour,
                    skyline: true,
                    skylineHeight: 0.14
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 0) {
                    // Top Row: Phase Badge (Left) & Upcoming Prayer Countdown (Right)
                    HStack(alignment: .center) {
                        HStack(spacing: 6) {
                            Image(systemName: phase.systemImage)
                                .font(.system(size: 11, weight: .bold))
                            Text(phase.displayName)
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.42))
                                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                        )

                        Spacer()

                        if let next = upcoming {
                            HStack(alignment: .center, spacing: 8) {
                                Text("\(next.prayer.displayName) \(manager.formattedPrayerTime(next.date))")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)

                                Text("-\(manager.formattedCountdown)")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(Color(red: 0.30, green: 0.36, blue: 0.56))
                                    )
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    // Big Digital Clock (Left-aligned)
                    Text(manager.currentSecondsString)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Spacer(minLength: 6)

                    // Subtitle: City · Day Date · Hijri Date (Left-aligned)
                    let subtitle = "\(manager.cityName) · \(manager.gregorianDateString) · \(manager.hijriDateString)"
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.95))
                        .lineLimit(1)
                }
                .shadow(color: Color.black.opacity(0.6), radius: 2)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
            .frame(height: 142)

            // 2. Five Prayer Capsules (Subuh, Dzuhur, Ashar, Maghrib, Isya)
            if let sched = schedule {
                HStack(spacing: 8) {
                    ForEach(sched.fivePrayers, id: \.prayer.rawValue) { item in
                        let isNext = (item.prayer == upcoming?.prayer)
                        VStack(spacing: 4) {
                            Text(item.prayer.displayName)
                                .font(.system(size: 11, weight: isNext ? .semibold : .medium, design: .rounded))
                                .foregroundStyle(isNext ? Color(red: 0.08, green: 0.09, blue: 0.16) : Color.white.opacity(0.70))

                            Text(manager.formattedPrayerTime(item.date))
                                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                                .foregroundStyle(isNext ? Color(red: 0.08, green: 0.09, blue: 0.16) : Color.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(isNext ? Color(red: 0.60, green: 0.67, blue: 0.98) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .stroke(isNext ? Color.clear : Color.white.opacity(0.04), lineWidth: 0.8)
                        )
                        .shadow(color: isNext ? Color(red: 0.60, green: 0.67, blue: 0.98).opacity(0.35) : Color.clear, radius: 6, y: 2)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity)
    }
}
