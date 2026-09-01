import XCTest
@testable import CodeIsland

final class MascotPaletteTests: XCTestCase {
    func testUnknownSourceFallsBackToClawd() {
        XCTAssertEqual(MascotPalette.signature(for: "not-a-real-cli"), MascotPalette.fallback)
        XCTAssertEqual(MascotPalette.signature(for: ""), MascotPalette.fallback)
    }

    /// "claude" has no explicit entry — it is the default branch in MascotView,
    /// so it must resolve through the same fallback rather than by accident.
    func testClaudeResolvesToFallback() {
        XCTAssertEqual(MascotPalette.signature(for: "claude"), MascotPalette.fallback)
    }

    func testAliasesShareTheirMascotColor() {
        XCTAssertEqual(
            MascotPalette.signature(for: "gemini"),
            MascotPalette.signature(for: "google-antigravity")
        )
        XCTAssertEqual(
            MascotPalette.signature(for: "pi"),
            MascotPalette.signature(for: "omp")
        )
        XCTAssertEqual(
            MascotPalette.signature(for: "qoder"),
            MascotPalette.signature(for: "qoderwork")
        )
        XCTAssertEqual(
            MascotPalette.signature(for: "cursor"),
            MascotPalette.signature(for: "cursor-cli")
        )
    }

    func testBlendingTowardWhiteRaisesEveryChannel() {
        let cline = MascotPalette.signature(for: "cline")
        let blended = cline.blendedWithWhite(0.62)
        XCTAssertGreaterThan(blended.red, cline.red)
        XCTAssertGreaterThan(blended.green, cline.green)
        XCTAssertGreaterThan(blended.blue, cline.blue)
    }

    func testBlendBoundsAreIdentityAndWhite() {
        let color = MascotPalette.signature(for: "kimi")
        XCTAssertEqual(color.blendedWithWhite(0), color)

        let white = color.blendedWithWhite(1)
        XCTAssertEqual(white.red, 1.0, accuracy: 0.0001)
        XCTAssertEqual(white.green, 1.0, accuracy: 0.0001)
        XCTAssertEqual(white.blue, 1.0, accuracy: 0.0001)
    }

    func testBlendClampsOutOfRangeFractions() {
        let color = MascotPalette.signature(for: "qwen")
        XCTAssertEqual(color.blendedWithWhite(-1), color)

        let clampedHigh = color.blendedWithWhite(5)
        XCTAssertEqual(clampedHigh.red, 1.0, accuracy: 0.0001)
    }

    /// The point of the blend: even the most saturated mascot must land pale
    /// enough to read as tinted light instead of a colored outline.
    func testEverySignatureStaysPaleAfterBlending() {
        let mix = NotchVisualStyle.contrastEdgeTintWhiteMix
        for (source, signature) in MascotPalette.signatureColors {
            let blended = signature.blendedWithWhite(mix)
            let luminance = 0.2126 * blended.red + 0.7152 * blended.green + 0.0722 * blended.blue
            XCTAssertGreaterThan(
                luminance, 0.6,
                "\(source) is too dark after blending to read as a highlight"
            )
        }
    }

    /// Channel spread is what carries the hue — the blend must not flatten
    /// every mascot into the same near-white.
    func testSaturatedMascotsKeepDistinguishableHue() {
        let mix = NotchVisualStyle.contrastEdgeTintWhiteMix
        for source in ["cline", "kimi", "cursor", "qwen"] {
            let blended = MascotPalette.signature(for: source).blendedWithWhite(mix)
            let spread = max(blended.red, blended.green, blended.blue)
                - min(blended.red, blended.green, blended.blue)
            XCTAssertGreaterThan(spread, 0.05, "\(source) lost its hue in the blend")
        }
    }
}
