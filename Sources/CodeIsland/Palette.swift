import SwiftUI

// MARK: - Theme

/// The island's colour theme (Settings → Appearance). A theme changes the
/// panel's tone only: status colours keep their meaning in every theme
/// (green = working, orange = needs you, grey = idle or done, red = error),
/// and each agent's mascot keeps its own art.
enum IslandTheme: String, CaseIterable, Identifiable {
    /// Today's island: black panel, white ink.
    case standard = "default"
    /// Near-black brown panel, cream ink, terracotta accent.
    case warm
    /// Greys, with orange as the one accent.
    case mono
    /// Pure black, stronger ink, saturated status colours.
    case highContrast

    var id: String { rawValue }

    /// Unknown or missing values read as the default.
    init(storedValue: String?) {
        self = storedValue.flatMap(IslandTheme.init(rawValue:)) ?? .standard
    }

    static var current: IslandTheme {
        IslandTheme(storedValue: UserDefaults.standard.string(forKey: SettingsKey.islandTheme))
    }

    var titleKey: String {
        switch self {
        case .standard: return "theme_default"
        case .warm: return "theme_warm"
        case .mono: return "theme_mono"
        case .highContrast: return "theme_high_contrast"
        }
    }

    var palette: Palette {
        switch self {
        case .standard: return .standard
        case .warm: return .warm
        case .mono: return .mono
        case .highContrast: return .highContrast
        }
    }
}

// MARK: - Palette

/// The panel's colour tokens. `standard` holds exactly the values the panel
/// drew before themes existed, so the default theme looks the same.
struct Palette {
    /// Panel and notch fill.
    let panel: Color
    /// Base foreground; secondary text and hairlines are this at an opacity.
    let ink: Color
    /// Multiplier on every `ink(_:)` opacity, capped at 1.
    let inkBoost: Double

    // Status — the hue only repeats what the status word says.
    /// Working / thinking: chips, rails, the selected mascot.
    let working: Color
    /// The brighter working green: live dots and tool glyphs.
    let workingBright: Color
    /// An approval or question waits on the user.
    let needsYou: Color
    /// Amber: a question's icon, a plan limit running low.
    let caution: Color
    let stopped: Color
    let error: Color
    /// Red glyphs: a rejected edit, a plan limit nearly spent.
    let alert: Color

    // Actions and accents
    /// The agent's own voice: reply dots, the live output prompt.
    let accent: Color
    let link: Color
    /// Allow buttons (white text on it ≥ 4.5:1).
    let allowFill: Color
    let allowFillHover: Color
    let deny: Color

    static var current: Palette { IslandTheme.current.palette }

    /// The theme's ink at `opacity`, lifted by its boost.
    static func ink(_ opacity: Double) -> Color {
        let palette = current
        return palette.ink.opacity(min(1, opacity * palette.inkBoost))
    }

    static let standard = Palette(
        panel: .black,
        ink: .white,
        inkBoost: 1,
        working: Color(red: 0.3, green: 0.85, blue: 0.4),
        workingBright: Color(red: 0.4, green: 1.0, blue: 0.5),
        needsYou: Color(red: 1.0, green: 0.6, blue: 0.2),
        caution: Color(red: 1.0, green: 0.7, blue: 0.28),
        stopped: Color(red: 1.0, green: 0.55, blue: 0.4),
        error: Color(red: 1.0, green: 0.38, blue: 0.42),
        alert: Color(red: 1.0, green: 0.4, blue: 0.4),
        accent: Color(red: 0.85, green: 0.47, blue: 0.34),
        link: Color(red: 0.45, green: 0.72, blue: 1.0),
        allowFill: Color(red: 0.16, green: 0.50, blue: 0.24),
        allowFillHover: Color(red: 0.17, green: 0.53, blue: 0.26),
        deny: Color(red: 0.92, green: 0.38, blue: 0.38)
    )

    static let warm = Palette(
        panel: Color(red: 0.094, green: 0.071, blue: 0.059),
        ink: Color(red: 1.0, green: 0.95, blue: 0.9),
        inkBoost: 1,
        working: Color(red: 0.56, green: 0.80, blue: 0.47),
        workingBright: Color(red: 0.66, green: 0.90, blue: 0.55),
        needsYou: Color(red: 0.96, green: 0.55, blue: 0.28),
        caution: Color(red: 0.98, green: 0.66, blue: 0.36),
        stopped: Color(red: 0.93, green: 0.58, blue: 0.45),
        error: Color(red: 0.95, green: 0.42, blue: 0.40),
        alert: Color(red: 0.95, green: 0.45, blue: 0.42),
        accent: Color(red: 0.85, green: 0.47, blue: 0.34),
        link: Color(red: 0.92, green: 0.62, blue: 0.48),
        allowFill: Color(red: 0.24, green: 0.42, blue: 0.20),
        allowFillHover: Color(red: 0.26, green: 0.45, blue: 0.22),
        deny: Color(red: 0.90, green: 0.43, blue: 0.38)
    )

    static let mono = Palette(
        panel: Color(white: 0.06),
        ink: Color(white: 0.96),
        inkBoost: 1,
        working: Color(red: 0.55, green: 0.78, blue: 0.60),
        workingBright: Color(red: 0.62, green: 0.88, blue: 0.66),
        needsYou: Color(red: 1.0, green: 0.62, blue: 0.22),
        caution: Color(red: 1.0, green: 0.70, blue: 0.32),
        stopped: Color(white: 0.7),
        error: Color(red: 0.92, green: 0.48, blue: 0.48),
        alert: Color(red: 0.92, green: 0.50, blue: 0.50),
        accent: Color(red: 1.0, green: 0.62, blue: 0.22),
        link: Color(red: 1.0, green: 0.62, blue: 0.22),
        allowFill: Color(white: 0.30),
        allowFillHover: Color(white: 0.34),
        deny: Color(white: 0.75)
    )

    static let highContrast = Palette(
        panel: .black,
        ink: .white,
        inkBoost: 1.5,
        working: Color(red: 0.2, green: 1.0, blue: 0.35),
        workingBright: Color(red: 0.3, green: 1.0, blue: 0.45),
        needsYou: Color(red: 1.0, green: 0.62, blue: 0.0),
        caution: Color(red: 1.0, green: 0.74, blue: 0.1),
        stopped: Color(red: 1.0, green: 0.5, blue: 0.3),
        error: Color(red: 1.0, green: 0.25, blue: 0.3),
        alert: Color(red: 1.0, green: 0.3, blue: 0.3),
        accent: Color(red: 1.0, green: 0.55, blue: 0.3),
        link: Color(red: 0.4, green: 0.78, blue: 1.0),
        allowFill: Color(red: 0.0, green: 0.45, blue: 0.15),
        allowFillHover: Color(red: 0.02, green: 0.5, blue: 0.17),
        deny: Color(red: 1.0, green: 0.3, blue: 0.3)
    )
}
