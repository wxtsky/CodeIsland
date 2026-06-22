import SwiftUI
import UIKit

// MARK: - 外观偏好（跟随系统 / 浅色 / 深色）

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// 传给 `.preferredColorScheme`；nil 表示跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// AppStorage 键，App 与各视图共用。
let appAppearanceStorageKey = "appAppearance"

// MARK: - 自适应主题色
//
// 用 dynamic UIColor 按 light/dark 自动解析，视图侧无需注入环境，
// 颜色随 `.preferredColorScheme` 决定的有效外观自动切换。
// 深色保持原有「灵动岛」纯黑观感；浅色为暖白护眼米色。

extension Color {
    /// 应用背景：深色近黑 / 浅色暖米白。
    static let ciBackground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.015, green: 0.016, blue: 0.018, alpha: 1)
            : UIColor(red: 0.945, green: 0.925, blue: 0.880, alpha: 1)
    })

    /// 卡片 / 胶囊表面：深色纯黑 / 浅色暖白（略亮于背景，使卡片浮起）。
    static let ciSurface = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0, green: 0, blue: 0, alpha: 1)
            : UIColor(red: 0.995, green: 0.985, blue: 0.960, alpha: 1)
    })

    /// 主前景（文字 / 图标 / 描边与浅填充的基色）：深色白 / 浅色暖深棕。
    /// 替换原先的 `.white` 与 `.white.opacity(x)`，透明度沿用不变。
    static let ciForeground = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 1)
            : UIColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
    })
}
