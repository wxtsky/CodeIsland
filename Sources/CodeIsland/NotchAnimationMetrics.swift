import Foundation

enum NotchAnimationMetrics {
    enum SurfaceTransition: Equatable {
        case open
        case close
    }

    /// Unscaled spring responses — the motion at 1.0× speed.
    static let baseOpenResponse: TimeInterval = 0.42
    static let baseCloseResponse: TimeInterval = baseOpenResponse

    /// Read live rather than captured at load, so moving the speed slider
    /// takes effect on the next open or close without relaunching.
    static var openResponse: TimeInterval {
        NotchAnimationSpeed.response(base: baseOpenResponse, speed: storedSpeed)
    }

    static var closeResponse: TimeInterval {
        NotchAnimationSpeed.response(base: baseCloseResponse, speed: storedSpeed)
    }

    private static var storedSpeed: Double {
        UserDefaults.standard.double(forKey: SettingsKey.notchAnimationSpeed)
    }

    static func surfaceTransition(for surface: IslandSurface) -> SurfaceTransition {
        surface == .collapsed ? .close : .open
    }
}
