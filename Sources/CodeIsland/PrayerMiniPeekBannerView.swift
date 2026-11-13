import SwiftUI
import CodeIslandCore

/// Mini Peek Toast Banner that gently rolls down from under the notch for ~6 seconds
/// upon approaching prayer time or when prayer time arrives.
public struct PrayerMiniPeekBannerView: View {
    @ObservedObject var manager: PrayerTimeManager
    var onOpenFull: () -> Void

    public init(manager: PrayerTimeManager, onOpenFull: @escaping () -> Void) {
        self.manager = manager
        self.onOpenFull = onOpenFull
    }

    public var body: some View {
        Button(action: onOpenFull) {
            HStack(spacing: 8) {
                // Phase / Prayer Icon Capsule
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(manager.currentPhase.accentColor.opacity(0.18))
                        .frame(width: 28, height: 28)
                    Image(systemName: manager.currentPhase.systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(manager.currentPhase.accentColor)
                }

                // Announcement text
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.miniPeekBannerTitle)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(manager.miniPeekBannerSubtitle)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Countdown badge
                if manager.upcomingPrayer != nil {
                    let diffMins = manager.minutesUntilNextPrayer
                    Text(diffMins <= 0 ? "Now" : "-\(diffMins)m")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(manager.currentPhase.accentColor.opacity(0.25))
                        )
                        .foregroundStyle(manager.currentPhase.accentColor)
                }

                // Dismiss button
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        manager.dismissMiniPeekBanner()
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.45))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 5)
        }
        .buttonStyle(.plain)
    }
}
