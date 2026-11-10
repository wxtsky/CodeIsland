import SwiftUI
import CodeIslandCore
import AppKit

// MARK: - Guaranteed 60fps Dancing Audio Spectrum (TimelineView)

struct CyberAudioSpectrumView: View {
    var barCount: Int = 4
    var isPlaying: Bool = true
    var barWidth: CGFloat = 2.6
    var segmentHeight: CGFloat = 1.8
    var segmentSpacing: CGFloat = 1.0

    private func segmentColor(level: Int, isActive: Bool) -> Color {
        guard isActive else {
            return Color(red: 0.12, green: 0.14, blue: 0.18)
        }
        switch level {
        case 0, 1:
            return Color(red: 0.0, green: 0.96, blue: 0.83) // Electric Cyan
        case 2:
            return Color(red: 0.96, green: 0.62, blue: 0.04) // Neon Amber
        default:
            return Color(red: 1.0, green: 0.16, blue: 0.53) // Peak Magenta
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    let normalized: Double = {
                        guard isPlaying else { return 0.2 }
                        let factor = Double(barIndex)
                        let b1 = sin(time * 8.0 + factor * 1.5) * 0.4
                        let b2 = cos(time * 13.0 + factor * 2.2) * 0.3
                        let b3 = sin(time * 4.5) * 0.15
                        return max(0.15, min(1.0, 0.45 + b1 + b2 + b3))
                    }()
                    let activeCount = isPlaying ? Int((normalized * 4.0).rounded()) : 1

                    VStack(spacing: segmentSpacing) {
                        ForEach((0..<4).reversed(), id: \.self) { step in
                            Rectangle()
                                .fill(segmentColor(level: step, isActive: step < activeCount))
                                .frame(width: barWidth, height: segmentHeight)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Retro Disco Equalizer Visualizer

struct CyberDiscoVisualizer: View {
    var isPlaying: Bool = true
    var barCount: Int = 6
    var maxHeight: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2.0) {
                ForEach(0..<barCount, id: \.self) { i in
                    let factor = Double(i) * 0.9
                    let wave = isPlaying
                        ? max(0.12, min(1.0, 0.5 + sin(time * 7.0 + factor) * 0.35 + cos(time * 12.0 + factor * 1.7) * 0.25))
                        : 0.15
                    let barH = max(3, maxHeight * CGFloat(wave))

                    VStack(spacing: 1.2) {
                        Rectangle()
                            .fill(Color(red: 1.0, green: 0.16, blue: 0.53))
                            .frame(width: 2.5, height: 1.5)
                            .opacity(isPlaying && wave > 0.6 ? 1 : 0.2)

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.0, green: 0.96, blue: 0.83),
                                        Color(red: 0.96, green: 0.62, blue: 0.04),
                                        Color(red: 1.0, green: 0.16, blue: 0.53)
                                    ],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: 2.5, height: barH)
                    }
                }
            }
            .frame(height: maxHeight + 4, alignment: .bottom)
        }
    }
}

// MARK: - Compact Wing Music View (Ultra-Compact for Small Notch)

struct CyberMusicWingView: View {
    @ObservedObject var nowPlaying: NowPlayingManager

    init(nowPlaying: NowPlayingManager) {
        self.nowPlaying = nowPlaying
    }

    var body: some View {
        HStack(spacing: 3) {
            // Mini Album Art
            if let art = nowPlaying.artworkImage {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(Color(white: 0.3), lineWidth: 0.5))
            } else {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color(red: 0.08, green: 0.09, blue: 0.12))
                    .frame(width: 13, height: 13)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 7))
                            .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83).opacity(0.8))
                    )
            }

            // Real-Time Dancing Equalizer
            CyberAudioSpectrumView(barCount: 4, isPlaying: nowPlaying.isPlaying, barWidth: 2.0, segmentHeight: 1.6, segmentSpacing: 0.8)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: 3.5)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.11))
                .overlay(RoundedRectangle(cornerRadius: 3.5).stroke(Color(red: 0.16, green: 0.19, blue: 0.25), lineWidth: 0.75))
        )
    }
}

// MARK: - Mini Peek Banner (Buka Tipis-Tipis saat Ganti Lagu)

struct CyberMusicMiniPeekBanner: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var onOpenFull: () -> Void

    var body: some View {
        Button(action: onOpenFull) {
            HStack(spacing: 8) {
                // Animated Cover Art
                if let art = nowPlaying.artworkImage {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(white: 0.3), lineWidth: 0.5))
                        .shadow(color: Color.black.opacity(0.5), radius: 3)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color(red: 0.0, green: 0.96, blue: 0.83))
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.12)))
                }

                // Track Title & Artist
                VStack(alignment: .leading, spacing: 1) {
                    Text(nowPlaying.title.isEmpty ? "No Track" : nowPlaying.title)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    Text(nowPlaying.artist.isEmpty ? "Now Playing" : nowPlaying.artist)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(Color(white: 0.65))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Dancing Spectrum
                CyberAudioSpectrumView(barCount: 4, isPlaying: nowPlaying.isPlaying, barWidth: 2.2, segmentHeight: 1.8, segmentSpacing: 1.0)

                // Close button
                Button(action: {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                        nowPlaying.showToast = false
                    }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(Color(white: 0.4))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(red: 0.05, green: 0.06, blue: 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(red: 0.16, green: 0.19, blue: 0.24), lineWidth: 1))
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 3)
        }
        .buttonStyle(.plain)
    }
}

extension FloatingLyricTextColor {
    var color: Color {
        switch self {
        case .white: return Color.white
        case .cyan: return Color(red: 0.0, green: 0.96, blue: 0.83)
        case .pink: return Color(red: 1.0, green: 0.16, blue: 0.53)
        case .green: return Color(red: 0.0, green: 0.90, blue: 0.46)
        case .amber: return Color(red: 1.0, green: 0.62, blue: 0.0)
        }
    }
}

// MARK: - Sub-Notch Floating Synced Lyric Bar (Mini Dynamic Island for Lyrics)

struct SubNotchFloatingLyricCapsuleView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var onOpenFull: () -> Void

    @AppStorage(SettingsKey.floatingLyricPreset) private var floatingLyricPreset = SettingsDefaults.floatingLyricPreset
    @AppStorage(SettingsKey.floatingLyricFontSize) private var floatingLyricFontSize = SettingsDefaults.floatingLyricFontSize
    @AppStorage(SettingsKey.floatingLyricFontDesign) private var floatingLyricFontDesign = SettingsDefaults.floatingLyricFontDesign
    @AppStorage(SettingsKey.floatingLyricTextColor) private var floatingLyricTextColor = SettingsDefaults.floatingLyricTextColor
    @State private var isHovered = false
    @State private var capsuleWidth: CGFloat = 180

    private var activePreset: FloatingLyricPreset {
        FloatingLyricPreset(rawValue: floatingLyricPreset) ?? .pureText
    }

    private var activeTextColor: Color {
        FloatingLyricTextColor(rawValue: floatingLyricTextColor)?.color ?? .white
    }

    private var activeFontDesign: Font.Design {
        switch FloatingLyricFontDesign(rawValue: floatingLyricFontDesign) ?? .rounded {
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .system: return .default
        }
    }

    private var activeNSFont: NSFont {
        let size = CGFloat(floatingLyricFontSize)
        switch FloatingLyricFontDesign(rawValue: floatingLyricFontDesign) ?? .rounded {
        case .rounded:
            if let desc = NSFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.withDesign(.rounded) {
                return NSFont(descriptor: desc, size: size) ?? NSFont.boldSystemFont(ofSize: size)
            }
            return NSFont.boldSystemFont(ofSize: size)
        case .monospaced:
            return NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
        case .system:
            return NSFont.boldSystemFont(ofSize: size)
        }
    }

    private var isRealLyric: Bool {
        !nowPlaying.currentLyricText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activeDisplayText: String {
        let lyric = nowPlaying.currentLyricText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !lyric.isEmpty {
            return lyric
        }
        if nowPlaying.lyricsLoading {
            return "♫ Loading lyrics..."
        }
        if nowPlaying.currentLyricIndex > 0 {
            return "♪ Instrumental Interlude ♪"
        }
        if !nowPlaying.title.isEmpty {
            let artist = nowPlaying.artist.isEmpty ? "" : " • \(nowPlaying.artist)"
            return "♪ Intro: \(nowPlaying.title)\(artist)"
        }
        return "♪ Music Playing..."
    }

    private var iconName: String {
        if isRealLyric {
            return "quote.bubble.fill"
        }
        if nowPlaying.lyricsLoading {
            return "arrow.triangle.2.circlepath"
        }
        return "music.note"
    }

    /// Computes pixel-perfect dynamic capsule width based on text length and active layout preset:
    /// Auto-expands smoothly with spring physics for long lyrics, contracts for short lines.
    private func calculateTargetWidth(for text: String, preset: FloatingLyricPreset) -> CGFloat {
        let font = activeNSFont
        let chromeWidth: CGFloat
        let minWidth: CGFloat

        switch preset {
        case .pureText:
            chromeWidth = 62
            minWidth = 110
        case .capsule:
            chromeWidth = 72
            minWidth = 130
        case .frostedGlass:
            chromeWidth = 68
            minWidth = 125
        case .neonHud:
            chromeWidth = 84
            minWidth = 140
        case .seamlessGlass:
            chromeWidth = 44
            minWidth = 200
        }

        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let target = ceil(textWidth + chromeWidth)
        return min(max(minWidth, target), 680)
    }

    @ViewBuilder
    private var presetContent: some View {
        switch activePreset {
        case .pureText:
            // Preset 1: Minimalist floating subtitle (No solid background)
            // Crisp pure-white text with layered drop shadow highlight & cyan neon accent
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovered ? Color(red: 1.0, green: 0.16, blue: 0.53) : Color(red: 0.0, green: 0.96, blue: 0.83))
                    .shadow(color: Color.black.opacity(0.85), radius: 2, x: 0, y: 1)
                    .shadow(color: Color(red: 0.0, green: 0.96, blue: 0.83).opacity(0.75), radius: 4, x: 0, y: 0)
                    .frame(width: 12)

                ZStack {
                    Text(activeDisplayText)
                        .font(.system(size: CGFloat(floatingLyricFontSize), weight: .bold, design: activeFontDesign))
                        .foregroundStyle(activeTextColor)
                        // Layered text highlight shadow for crystal-clear readability against any wallpaper
                        .shadow(color: Color.black.opacity(0.95), radius: 3, x: 0, y: 1.2)
                        .shadow(color: Color.black.opacity(0.80), radius: 6, x: 0, y: 2.5)
                        .shadow(color: activeTextColor.opacity(isHovered ? 0.70 : 0.30), radius: 4, x: 0, y: 0)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(activeDisplayText)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 4)),
                            removal: .opacity.combined(with: .offset(y: -4))
                        ))
                }
                .frame(maxWidth: .infinity)

                CyberAudioSpectrumView(
                    barCount: 3,
                    isPlaying: nowPlaying.isPlaying,
                    barWidth: 1.8,
                    segmentHeight: 1.4,
                    segmentSpacing: 0.6
                )
                .shadow(color: Color.black.opacity(0.8), radius: 2)
                .frame(width: 14)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

        case .capsule:
            // Preset 2: Original cyber capsule: solid black Dynamic Island pill with neon gradient border
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isHovered ? Color(red: 1.0, green: 0.16, blue: 0.53) : Color(red: 0.0, green: 0.96, blue: 0.83))
                    .frame(width: 12)

                ZStack {
                    Text(activeDisplayText)
                        .font(.system(size: CGFloat(floatingLyricFontSize), weight: .bold, design: activeFontDesign))
                        .foregroundStyle(isRealLyric ? activeTextColor : activeTextColor.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(activeDisplayText)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 5)),
                            removal: .opacity.combined(with: .offset(y: -5))
                        ))
                }
                .frame(maxWidth: .infinity)

                CyberAudioSpectrumView(
                    barCount: 3,
                    isPlaying: nowPlaying.isPlaying,
                    barWidth: 1.8,
                    segmentHeight: 1.4,
                    segmentSpacing: 0.6
                )
                .frame(width: 14)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 5)

        case .frostedGlass:
            // Preset 3: Apple-style translucent frosted blur pill with hairline border
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(isHovered ? Color.white : Color.white.opacity(0.8))
                    .frame(width: 12)

                ZStack {
                    Text(activeDisplayText)
                        .font(.system(size: CGFloat(floatingLyricFontSize), weight: .semibold, design: activeFontDesign))
                        .foregroundStyle(activeTextColor)
                        .shadow(color: Color.black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(activeDisplayText)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 4)),
                            removal: .opacity.combined(with: .offset(y: -4))
                        ))
                }
                .frame(maxWidth: .infinity)

                CyberAudioSpectrumView(
                    barCount: 3,
                    isPlaying: nowPlaying.isPlaying,
                    barWidth: 1.8,
                    segmentHeight: 1.4,
                    segmentSpacing: 0.6
                )
                .frame(width: 14)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

        case .neonHud:
            // Preset 4: Cyberpunk HUD with technical bracket telemetry styling
            HStack(spacing: 6) {
                Text("[")
                    .font(.system(size: CGFloat(floatingLyricFontSize), weight: .black, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83).opacity(0.9))

                Image(systemName: iconName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83))
                    .frame(width: 11)

                ZStack {
                    Text(activeDisplayText)
                        .font(.system(size: CGFloat(floatingLyricFontSize), weight: .bold, design: activeFontDesign))
                        .foregroundStyle(activeTextColor)
                        .shadow(color: activeTextColor.opacity(0.4), radius: 3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .id(activeDisplayText)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 4)),
                            removal: .opacity.combined(with: .offset(y: -4))
                        ))
                }
                .frame(maxWidth: .infinity)

                CyberAudioSpectrumView(
                    barCount: 3,
                    isPlaying: nowPlaying.isPlaying,
                    barWidth: 1.8,
                    segmentHeight: 1.4,
                    segmentSpacing: 0.6
                )
                .frame(width: 14)

                Text("]")
                    .font(.system(size: CGFloat(floatingLyricFontSize), weight: .black, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83).opacity(0.9))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)

        case .seamlessGlass:
            // Preset 5: Seamless Glass — borderless translucent frosted glass with pure text focus and iPad Spotify vertical roll-up
            HStack(spacing: 0) {
                ZStack {
                    Text(activeDisplayText)
                        .font(.system(size: CGFloat(floatingLyricFontSize), weight: .semibold, design: activeFontDesign))
                        .foregroundStyle(activeTextColor)
                        .shadow(color: Color.black.opacity(0.55), radius: 2.5, x: 0, y: 1)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.center)
                        .id("floating-seamless-\(nowPlaying.currentLyricIndex)")
                        .transition(.asymmetric(
                            insertion: .offset(y: 20).combined(with: .opacity),
                            removal: .offset(y: -20).combined(with: .opacity)
                        ))
                }
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4.5)
        }
    }

    @ViewBuilder
    private var presetBackground: some View {
        switch activePreset {
        case .pureText:
            // Feather-soft ambient blur shadow for 100% legibility without visible container box
            Capsule()
                .fill(Color.black.opacity(isHovered ? 0.28 : 0.08))
                .blur(radius: isHovered ? 8 : 4)
                .background(Capsule().fill(Color.clear))

        case .capsule:
            // Solid black pill with neon gradient border
            Capsule()
                .fill(Color.black.opacity(0.96))
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.0, green: 0.96, blue: 0.83).opacity(isHovered ? 0.95 : 0.50),
                                    Color(red: 1.0, green: 0.16, blue: 0.53).opacity(isHovered ? 0.90 : 0.35)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.0
                        )
                )
                .shadow(color: Color.black.opacity(0.92), radius: 8, x: 0, y: 4)
                .shadow(color: Color(red: 0.0, green: 0.96, blue: 0.83).opacity(isHovered ? 0.35 : 0.12), radius: 6, x: 0, y: 1)

        case .frostedGlass:
            // Apple-style translucent pill with hairline light border
            Capsule()
                .fill(Color.black.opacity(0.55))
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.38 : 0.22),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(0.65), radius: 6, x: 0, y: 3)

        case .neonHud:
            // Cyberpunk HUD dark slate with neon teal border & glow
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.04, green: 0.05, blue: 0.07).opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            Color(red: 0.0, green: 0.96, blue: 0.83).opacity(isHovered ? 0.85 : 0.45),
                            lineWidth: 0.75
                        )
                )
                .shadow(color: Color.black.opacity(0.9), radius: 6, x: 0, y: 3)
                .shadow(color: Color(red: 0.0, green: 0.96, blue: 0.83).opacity(isHovered ? 0.30 : 0.10), radius: 4, x: 0, y: 0)

        case .seamlessGlass:
            // Borderless translucent frosted blur pill (no stroke, pure subtle opacity)
            Capsule()
                .fill(Color.black.opacity(isHovered ? 0.45 : 0.32))
                .shadow(color: Color.black.opacity(0.40), radius: 6, x: 0, y: 2)
        }
    }

    var body: some View {
        Button(action: {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
            onOpenFull()
        }) {
            presetContent
                .frame(width: capsuleWidth, height: 26)
                .background(presetBackground)
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            capsuleWidth = calculateTargetWidth(for: activeDisplayText, preset: activePreset)
        }
        .onChange(of: activeDisplayText) { _, newText in
            let target = calculateTargetWidth(for: newText, preset: activePreset)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                capsuleWidth = target
            }
        }
        .onChange(of: floatingLyricPreset) { _, _ in
            let target = calculateTargetWidth(for: activeDisplayText, preset: activePreset)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                capsuleWidth = target
            }
        }
        .onChange(of: floatingLyricFontSize) { _, _ in
            let target = calculateTargetWidth(for: activeDisplayText, preset: activePreset)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                capsuleWidth = target
            }
        }
        .onChange(of: floatingLyricFontDesign) { _, _ in
            let target = calculateTargetWidth(for: activeDisplayText, preset: activePreset)
            withAnimation(.spring(response: 0.38, dampingFraction: 0.76)) {
                capsuleWidth = target
            }
        }
        .help("♫ Live Synced Lyrics [Style: \(activePreset.title)] (Click to open Music HUD)")
    }
}

// Backward compatibility aliases
typealias SubNotchIntegratedLyricChinView = SubNotchFloatingLyricCapsuleView
typealias SubNotchLyricCapsuleView = SubNotchFloatingLyricCapsuleView

// MARK: - Full Solid Lyric Line View (Immediate 100% line display, no staggered word popup)

struct KaraokeLyricLineView: View {
    let text: String
    let isCurrent: Bool
    let currentFraction: Double // 0.0 ... 1.0 (kept for backwards signature compatibility)
    let primaryColor: Color
    var fontSize: CGFloat = 10.0

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: isCurrent ? .bold : .medium, design: .rounded))
            .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.40))
            .shadow(color: isCurrent ? primaryColor.opacity(0.65) : Color.clear, radius: isCurrent ? 3.5 : 0)
    }
}

// MARK: - Redesigned High-Taste Compact Music HUD View with Synced Lyrics

struct CyberMusicHUDView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var appState: AppState
    @AppStorage(SettingsKey.musicHUDTheme) private var musicHUDTheme = SettingsDefaults.musicHUDTheme

    init(nowPlaying: NowPlayingManager, appState: AppState) {
        self.nowPlaying = nowPlaying
        self.appState = appState
    }

    var body: some View {
        Group {
            if musicHUDTheme == MusicHUDTheme.retroCyber.rawValue {
                RetroCyberMusicHUDContentView(nowPlaying: nowPlaying, appState: appState)
            } else {
                ModernCleanMusicHUDContentView(nowPlaying: nowPlaying, appState: appState)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: musicHUDTheme)
    }
}

// MARK: - Modern Clean Dynamic Island Music HUD Theme

struct ModernCleanMusicHUDContentView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var appState: AppState

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatRemainingTime(position: Double, duration: Double) -> String {
        guard duration > 0 else { return "-0:00" }
        let remaining = max(0.0, duration - position)
        let total = Int(remaining)
        let m = total / 60
        let s = total % 60
        return String(format: "-%d:%02d", m, s)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // LEFT COLUMN: Album Art + Track Info + Modern Scrubber + Circular Play Controls (205pt fixed width)
            VStack(alignment: .leading, spacing: 6) {
                // Top: Artwork & Track Info
                HStack(spacing: 10) {
                    // Album Cover (50x50 squircle)
                    ZStack {
                        if let art = nowPlaying.artworkImage {
                            Image(nsImage: art)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                                )
                                .shadow(color: Color.black.opacity(0.35), radius: 5, x: 0, y: 2.5)
                        } else {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color(white: 0.16), Color(white: 0.08)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 50, height: 50)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 19))
                                        .foregroundColor(Color.white.opacity(0.6))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
                                )
                        }
                    }
                    .id(nowPlaying.title + nowPlaying.artist)

                    // Track Title, Artist, & Source
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying.title.isEmpty ? "No track" : nowPlaying.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(nowPlaying.title)

                        Text(nowPlaying.artist.isEmpty ? "Idle" : nowPlaying.artist)
                            .font(.system(size: 11, weight: .medium, design: .default))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 4) {
                            Circle()
                                .fill(nowPlaying.player.lowercased().contains("apple") ? Color(red: 0.98, green: 0.20, blue: 0.35) : Color(red: 0.12, green: 0.84, blue: 0.38))
                                .frame(width: 4.5, height: 4.5)

                            Text(nowPlaying.player.isEmpty ? "Spotify" : (nowPlaying.player.lowercased().contains("spotify") ? "Spotify" : "Apple Music"))
                                .font(.system(size: 9.5, weight: .medium, design: .default))
                                .foregroundStyle(Color.white.opacity(0.68))
                        }
                        .padding(.top, 1)
                    }
                }

                // Middle: Modern Interactive Scrubber
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        let totalWidth = geo.size.width
                        let progressFraction: CGFloat = nowPlaying.trackDuration > 0
                            ? min(1.0, max(0.0, CGFloat(nowPlaying.playerPosition / nowPlaying.trackDuration)))
                            : 0.0

                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.18))
                                .frame(height: 3.5)

                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.68, blue: 0.48), Color(red: 1.0, green: 0.58, blue: 0.42)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                                .frame(width: totalWidth * progressFraction, height: 3.5)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    guard nowPlaying.trackDuration > 0 else { return }
                                    let fraction = min(1.0, max(0.0, value.location.x / totalWidth))
                                    let targetTime = Double(fraction) * nowPlaying.trackDuration
                                    nowPlaying.seek(to: targetTime)
                                }
                        )
                    }
                    .frame(height: 3.5)

                    HStack {
                        Text(formatTime(nowPlaying.playerPosition))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.48))
                        Spacer()
                        Text(formatRemainingTime(position: nowPlaying.playerPosition, duration: nowPlaying.trackDuration))
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.48))
                    }
                }

                // Bottom: Clean Circular Playback Controls
                HStack(spacing: 18) {
                    Spacer()

                    Button(action: { nowPlaying.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: { nowPlaying.togglePlayPause() }) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Color.black)
                                    .offset(x: nowPlaying.isPlaying ? 0 : 0.8)
                            )
                            .shadow(color: Color.white.opacity(0.18), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)

                    Button(action: { nowPlaying.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }
            }
            .frame(width: 205, alignment: .leading)

            // Subtle vertical hairline separator with gradient fade
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.0), Color.white.opacity(0.12), Color.white.opacity(0.0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: 1, height: 84)

            // RIGHT COLUMN: Modern Streaming Lyrics (Pure Apple Music / Spotify iPad Fluid Typography)
            VStack(alignment: .leading, spacing: 0) {
                if nowPlaying.lyrics.isEmpty {
                    VStack(spacing: 5) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.white.opacity(0.35))
                        Text(nowPlaying.lyricsLoading ? "Fetching lyrics..." : "No lyrics available")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.40))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(nowPlaying.lyrics) { line in
                                    let isCurrent = (line.id == nowPlaying.currentLyricIndex)

                                    Text(line.text)
                                        .font(.system(
                                            size: isCurrent ? 13 : 10.5,
                                            weight: isCurrent ? .bold : .medium,
                                            design: .rounded
                                        ))
                                        .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.32))
                                        .shadow(color: isCurrent ? Color.white.opacity(0.35) : Color.clear, radius: isCurrent ? 6 : 0)
                                        .scaleEffect(isCurrent ? 1.0 : 0.98, anchor: .leading)
                                        .animation(.easeInOut(duration: 0.25), value: isCurrent)
                                        .lineLimit(2)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            nowPlaying.seek(to: line.timestamp)
                                        }
                                        .id(line.id)
                                }
                            }
                            .padding(.vertical, 8)
                            .padding(.trailing, 6)
                        }
                        .mask(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: 0.16),
                                    .init(color: .black, location: 0.84),
                                    .init(color: .clear, location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onAppear {
                            proxy.scrollTo(nowPlaying.currentLyricIndex, anchor: .center)
                        }
                        .onChange(of: nowPlaying.currentLyricIndex) { _, newIndex in
                            withAnimation(.easeInOut(duration: 0.35)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 98)
        .padding(.horizontal, 10)
    }
}

// MARK: - Retro Cyber Pixel Music HUD Theme (Preserved Classic)

struct RetroCyberMusicHUDContentView: View {
    @ObservedObject var nowPlaying: NowPlayingManager
    var appState: AppState

    init(nowPlaying: NowPlayingManager, appState: AppState) {
        self.nowPlaying = nowPlaying
        self.appState = appState
    }

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // LEFT COLUMN: Album Art, Track info, Scrubber & Controls (175pt fixed width)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    // Album Cover (48x48)
                    ZStack {
                        if let art = nowPlaying.artworkImage {
                            Image(nsImage: art)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.25), lineWidth: 0.8))
                                .shadow(color: Color.black.opacity(0.5), radius: 3, y: 2)
                        } else {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(red: 0.08, green: 0.09, blue: 0.12))
                                .frame(width: 48, height: 48)
                                .overlay(Image(systemName: "music.note").font(.system(size: 18)).foregroundColor(Color(red: 0.0, green: 0.96, blue: 0.83)))
                        }
                    }
                    .id(nowPlaying.title + nowPlaying.artist)

                    // Track Title & Artist
                    VStack(alignment: .leading, spacing: 2) {
                        Text(nowPlaying.player.isEmpty ? "SPOTIFY" : nowPlaying.player.uppercased())
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 1.0, green: 0.16, blue: 0.53))

                        Text(nowPlaying.title.isEmpty ? "No track" : nowPlaying.title)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .id(nowPlaying.title)

                        Text(nowPlaying.artist.isEmpty ? "Idle" : nowPlaying.artist)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color(white: 0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                // Interactive Scrubber
                VStack(spacing: 2) {
                    GeometryReader { geo in
                        let totalWidth = geo.size.width
                        let progressFraction: CGFloat = nowPlaying.trackDuration > 0
                            ? min(1.0, max(0.0, CGFloat(nowPlaying.playerPosition / nowPlaying.trackDuration)))
                            : 0.0

                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: 0.14, green: 0.16, blue: 0.22))
                                .frame(height: 3)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(red: 0.0, green: 0.96, blue: 0.83))
                                .frame(width: totalWidth * progressFraction, height: 3)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onEnded { value in
                                    guard nowPlaying.trackDuration > 0 else { return }
                                    let fraction = min(1.0, max(0.0, value.location.x / totalWidth))
                                    let targetTime = Double(fraction) * nowPlaying.trackDuration
                                    nowPlaying.seek(to: targetTime)
                                }
                        )
                    }
                    .frame(height: 4)

                    HStack {
                        Text(formatTime(nowPlaying.playerPosition))
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                        Spacer()
                        Text(formatTime(nowPlaying.trackDuration))
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }

                // Playback Controls + Mini Disco
                HStack(spacing: 8) {
                    Button(action: { nowPlaying.previousTrack() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(white: 0.85))
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.11)))
                    }
                    .buttonStyle(.plain)

                    Button(action: { nowPlaying.togglePlayPause() }) {
                        Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83))
                            .frame(width: 22, height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.05, green: 0.14, blue: 0.14)))
                    }
                    .buttonStyle(.plain)

                    Button(action: { nowPlaying.nextTrack() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(white: 0.85))
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.11)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // Retro Disco Visualizer (compact 6 bars)
                    CyberDiscoVisualizer(isPlaying: nowPlaying.isPlaying, barCount: 6, maxHeight: 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Divider Rule (fixed height, never expands!)
            Rectangle()
                .fill(Color(red: 0.16, green: 0.19, blue: 0.24))
                .frame(width: 1, height: 92)

            // RIGHT COLUMN: Synced Real-Time Lyrics View (clean, full-height lyrics only)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("LYRICS")
                        .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.0, green: 0.96, blue: 0.83))

                    Spacer()

                    if nowPlaying.lyricsLoading {
                        Text("LOADING...")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                    }
                }

                if nowPlaying.lyrics.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 16))
                            .foregroundColor(Color(red: 0.0, green: 0.96, blue: 0.83).opacity(0.6))
                        Text(nowPlaying.lyricsLoading ? "Fetching lyrics..." : "No lyrics found")
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(Color(white: 0.45))
                    }
                    .frame(maxWidth: .infinity, minHeight: 82, maxHeight: 82, alignment: .center)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 3.5) {
                                ForEach(nowPlaying.lyrics) { line in
                                    let isCurrent = (line.id == nowPlaying.currentLyricIndex)
                                    let currentLine = nowPlaying.lyrics.first(where: { $0.id == nowPlaying.currentLyricIndex })
                                    let nextLine = nowPlaying.lyrics.first(where: { $0.id == (nowPlaying.currentLyricIndex + 1) })
                                    let duration = max(1.0, (nextLine?.timestamp ?? ((currentLine?.timestamp ?? 0) + 3.8)) - (currentLine?.timestamp ?? 0))
                                    let elapsed = max(0.0, nowPlaying.playerPosition - (currentLine?.timestamp ?? 0))
                                    let fraction = min(1.0, elapsed / duration)

                                    HStack(spacing: 4) {
                                        if isCurrent {
                                            Circle()
                                                .fill(Color(red: 0.0, green: 0.96, blue: 0.83))
                                                .frame(width: 3, height: 3)
                                        }
                                        KaraokeLyricLineView(
                                            text: line.text,
                                            isCurrent: isCurrent,
                                            currentFraction: fraction,
                                            primaryColor: Color(red: 0.0, green: 0.96, blue: 0.83),
                                            fontSize: isCurrent ? 9.5 : 8.0
                                        )
                                        .lineLimit(2)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        nowPlaying.seek(to: line.timestamp)
                                    }
                                    .id(line.id)
                                }
                            }
                            .padding(.trailing, 4)
                        }
                        .frame(height: 82)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { _ in
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                }
                        )
                        .onAppear {
                            proxy.scrollTo(nowPlaying.currentLyricIndex, anchor: .center)
                        }
                        .onChange(of: nowPlaying.currentLyricIndex) { _, newIndex in
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(newIndex, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 98)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(red: 0.05, green: 0.06, blue: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(red: 0.16, green: 0.19, blue: 0.24), lineWidth: 1)
                )
        )
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }
}

// MARK: - Machined Token Usage Badge (Kept for Agent View)

struct MachinedTokenBadge: View {
    var appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    private var tokenSnapshot: ClaudeUsageTotals? {
        appState.claudeUsage?.today
    }

    private var totalTokens: Int {
        guard let s = tokenSnapshot else { return 0 }
        return s.inputTokens + s.outputTokens + s.cacheCreationTokens + s.cacheReadTokens
    }

    private var tokenLabel: String {
        if totalTokens > 0 {
            return ClaudeUsageScanner.formatTokens(totalTokens)
        }
        let totalToolCalls = appState.sessions.values.reduce(0) { $0 + $1.totalToolCallCount }
        if totalToolCalls > 0 {
            return "\(totalToolCalls) ops"
        }
        return "0k"
    }

    var body: some View {
        HStack(spacing: 3) {
            Text("⚡")
                .font(.system(size: 8))
                .foregroundColor(Color(red: 0.0, green: 0.96, blue: 0.83))
            Text(tokenLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(Color(red: 0.92, green: 0.94, blue: 0.98))
            Text("TOK")
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.07, green: 0.08, blue: 0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(red: 0.16, green: 0.19, blue: 0.25), lineWidth: 0.75)
                )
        )
    }
}

// MARK: - Compatibility Aliases
typealias CyberMusicNotificationBanner = CyberMusicMiniPeekBanner
