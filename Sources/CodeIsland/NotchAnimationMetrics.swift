import Foundation

enum NotchAnimationMetrics {
    enum SurfaceTransition: Equatable {
        case open
        case close
    }

    static let openResponse: TimeInterval = 0.42
    static let closeResponse: TimeInterval = openResponse

    static func surfaceTransition(for surface: IslandSurface) -> SurfaceTransition {
        surface == .collapsed ? .close : .open
    }
}
