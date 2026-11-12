import SwiftUI
import AppKit

struct NotchVolumeHUDView: View {
    @ObservedObject var volumeManager: SystemVolumeManager = .shared
    @AppStorage(SettingsKey.musicHUDProgressColor) private var musicHUDProgressColor = SettingsDefaults.musicHUDProgressColor

    private var activeProgressColor: Color {
        (MusicProgressColor(rawValue: musicHUDProgressColor) ?? .theme).color
    }

    private var activeProgressGradient: LinearGradient {
        (MusicProgressColor(rawValue: musicHUDProgressColor) ?? .theme).gradient
    }

    private var speakerIconName: String {
        if volumeManager.isMuted {
            return "speaker.slash.fill"
        } else if volumeManager.volume <= 0.001 {
            return "speaker.fill"
        } else if volumeManager.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volumeManager.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var speakerIconColor: Color {
        if volumeManager.isMuted {
            return Color(red: 1.0, green: 0.28, blue: 0.38)
        } else if volumeManager.volume <= 0.001 {
            return Color.white.opacity(0.5)
        } else {
            return activeProgressColor
        }
    }

    private var percentageText: String {
        if volumeManager.isMuted {
            return "MUTE"
        } else {
            return String(format: "%d%%", Int(round(volumeManager.volume * 100)))
        }
    }

    var body: some View {
        Button(action: { volumeManager.toggleMute() }) {
            HStack(spacing: 8) {
                // Dynamic speaker icon
                Image(systemName: speakerIconName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(speakerIconColor)
                    .frame(width: 14)

                // Theme-aligned volume progress bar
                GeometryReader { geo in
                    let totalWidth = geo.size.width
                    let fillWidth = volumeManager.isMuted ? 0 : totalWidth * CGFloat(volumeManager.volume)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.18))
                            .frame(height: 4)

                        Capsule()
                            .fill(activeProgressGradient)
                            .frame(width: max(0, min(totalWidth, fillWidth)), height: 4)
                    }
                }
                .frame(width: 95, height: 4)

                // Volume percentage readout
                Text(percentageText)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .frame(width: 32, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(white: 0.08).opacity(0.94))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 6, y: 3)
            )
        }
        .buttonStyle(.plain)
        .help("Click to toggle mute")
    }
}
