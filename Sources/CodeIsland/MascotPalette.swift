import SwiftUI

/// One mascot's signature color, kept as components so it can be blended on
/// macOS 14 — `Color.mix(with:by:)` needs macOS 15.
struct MascotSignatureColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    /// Pull the color toward white by `fraction` (0 = untouched, 1 = white).
    ///
    /// Tinting the contrast edge with a raw brand color turns a hairline
    /// highlight into a colored stripe. Lifting it toward white keeps the edge
    /// reading as light that happens to carry a hue.
    func blendedWithWhite(_ fraction: Double) -> MascotSignatureColor {
        let amount = min(max(fraction, 0), 1)
        return MascotSignatureColor(
            red: red + (1 - red) * amount,
            green: green + (1 - green) * amount,
            blue: blue + (1 - blue) * amount
        )
    }
}

/// Signature colors per CLI source, mirroring the routing in `MascotView` so
/// every source that resolves to a mascot also resolves to a color — aliases
/// included.
enum MascotPalette {
    /// Clawd, the default mascot for unrecognized sources.
    static let fallback = MascotSignatureColor(red: 0.871, green: 0.533, blue: 0.427)

    private static let dex = MascotSignatureColor(red: 0.92, green: 0.92, blue: 0.93)
    private static let grok = MascotSignatureColor(red: 1.0, green: 1.0, blue: 1.0)
    private static let gemini = MascotSignatureColor(red: 0.278, green: 0.588, blue: 0.894)
    private static let cursor = MascotSignatureColor(red: 0.96, green: 0.31, blue: 0.0)
    private static let copilot = MascotSignatureColor(red: 0.35, green: 0.75, blue: 0.95)
    private static let qoder = MascotSignatureColor(red: 0.165, green: 0.859, blue: 0.361)
    private static let droid = MascotSignatureColor(red: 0.835, green: 0.416, blue: 0.149)
    private static let buddyViolet = MascotSignatureColor(red: 0.424, green: 0.302, blue: 1.0)
    private static let workBuddy = MascotSignatureColor(red: 0.475, green: 0.380, blue: 0.870)
    private static let openClaw = MascotSignatureColor(red: 0.93, green: 0.36, blue: 0.24)
    private static let qwen = MascotSignatureColor(red: 0.486, green: 0.228, blue: 0.929)
    private static let kimi = MascotSignatureColor(red: 0.29, green: 0.56, blue: 1.0)
    private static let kiro = MascotSignatureColor(red: 0.62, green: 0.45, blue: 1.0)
    private static let pi = MascotSignatureColor(red: 0.55, green: 0.43, blue: 0.95)
    private static let openCode = MascotSignatureColor(red: 0.55, green: 0.55, blue: 0.57)
    private static let cline = MascotSignatureColor(red: 0.00, green: 0.70, blue: 0.49)

    static let signatureColors: [String: MascotSignatureColor] = [
        "codex": dex,
        "grok": grok,
        "gemini": gemini,
        "google-antigravity": gemini,
        "cursor": cursor,
        "cursor-cli": cursor,
        "trae": cursor,
        "traecn": cursor,
        "traecli": cursor,
        "copilot": copilot,
        "qoder": qoder,
        "qoder-cli": qoder,
        "qoderwork": qoder,
        "droid": droid,
        "codebuddy": buddyViolet,
        "codybuddycn": buddyViolet,
        "stepfun": buddyViolet,
        "antigravity": buddyViolet,
        "hermes": buddyViolet,
        "workbuddy": workBuddy,
        "openclaw": openClaw,
        "qwen": qwen,
        "kimi": kimi,
        "kiro": kiro,
        "pi": pi,
        "omp": pi,
        "opencode": openCode,
        "cline": cline,
    ]

    static func signature(for source: String) -> MascotSignatureColor {
        signatureColors[source] ?? fallback
    }

    static func color(for source: String) -> Color {
        signature(for: source).color
    }

    /// The mascot's color as the contrast edge should wear it: lifted toward
    /// white so it stays a highlight rather than becoming a colored line.
    static func contrastEdgeTint(for source: String) -> Color {
        signature(for: source)
            .blendedWithWhite(NotchVisualStyle.contrastEdgeTintWhiteMix)
            .color
    }
}
