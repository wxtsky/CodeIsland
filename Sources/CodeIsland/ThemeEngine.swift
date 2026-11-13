import SwiftUI

/// Unified Color Theme accessor for CodeIsland
public enum AppColorTheme {
    public static func accent(for colorKey: String, isModern: Bool = false) -> Color {
        let pc = MusicProgressColor(rawValue: colorKey) ?? .theme
        switch pc {
        case .theme:
            return isModern ? .white : Color(red: 0.12, green: 0.84, blue: 0.38)
        case .white: return .white
        case .cyan: return Color(red: 0.0, green: 0.96, blue: 0.83)
        case .pink: return Color(red: 1.0, green: 0.16, blue: 0.53)
        case .green: return Color(red: 0.12, green: 0.84, blue: 0.38)
        case .amber: return Color(red: 1.0, green: 0.72, blue: 0.20)
        }
    }
}
