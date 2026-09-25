import XCTest
@testable import CodeIsland

final class QuotaChipLayoutTests: XCTestCase {
    // 14" MacBook Pro-ish: 27pt mascot → 41pt wings, ~185pt notch.
    private let mascot: CGFloat = 27
    private var wing: CGFloat { mascot + 14 }
    private let notch: CGFloat = 185

    /// Lays the collapsed bar out the way the view does — centred on the notch,
    /// then offset by `shift` — and returns where things land (0 = notch centre).
    private func geometry(chip: CGFloat, statusExtra: CGFloat)
        -> (chipTail: CGFloat, notchLeft: CGFloat, rightEdge: CGFloat, baseRightEdge: CGFloat) {
        let r = QuotaChipLayout.reserve(chipWidth: chip, mascotSize: mascot, wing: wing,
                                        statusExtra: statusExtra, hasNotch: true)
        let base = notch + wing * 2 + statusExtra
        let width = base + r.extraWidth
        let leftEdge = -width / 2 + r.shift
        let chipTail = leftEdge + QuotaChipLayout.wingLeading + mascot + QuotaChipLayout.wingSpacing + chip
        return (chipTail, -notch / 2, width / 2 + r.shift, base / 2)
    }

    func testChipNeverReachesTheNotchAndTheRightWingStaysPut() {
        // Idle / working, tool status off / on (≈3% of a 1512pt screen), chip
        // from a short "5h 3%" to a long model-scoped label.
        for statusExtra: CGFloat in [0, 20, 45, 65] {
            for chip: CGFloat in [40, 60, 90, 130] {
                let g = geometry(chip: chip, statusExtra: statusExtra)
                XCTAssertLessThanOrEqual(g.chipTail + QuotaChipLayout.notchGap, g.notchLeft + 0.001,
                                         "chip \(chip) with status extra \(statusExtra) slides under the notch")
                XCTAssertEqual(g.rightEdge, g.baseRightEdge, accuracy: 0.001,
                               "the right wing must not move — nothing is spent on symmetry")
            }
        }
    }

    func testReserveIsOnlyTheMissingWidth() {
        // Needed: 6 + 27 + 6 + 90 + 4 = 133; room: 41 + 45/2 = 63.5 → 69.5 short.
        let r = QuotaChipLayout.reserve(chipWidth: 90, mascotSize: mascot, wing: wing, statusExtra: 45, hasNotch: true)
        XCTAssertEqual(r.extraWidth, 69.5, accuracy: 0.001)
        XCTAssertEqual(r.shift, -34.75, accuracy: 0.001)
    }

    func testChipThatFitsChangesNothing() {
        // Needed: 6 + 27 + 6 + 10 + 4 = 53; room: 41 + 40/2 = 61.
        XCTAssertEqual(
            QuotaChipLayout.reserve(chipWidth: 10, mascotSize: mascot, wing: wing, statusExtra: 40, hasNotch: true),
            .none
        )
    }

    func testLeftEdgeDoesNotMoveWithStatusReserveOnceTheChipDominates() {
        // Idle → working adds 20pt of status reserve. With the chip already the
        // widest thing on the left, only the right half grows (as on main); the
        // left edge, and the chip with it, must not jump.
        func leftEdge(_ statusExtra: CGFloat) -> CGFloat {
            let r = QuotaChipLayout.reserve(chipWidth: 90, mascotSize: mascot, wing: wing, statusExtra: statusExtra, hasNotch: true)
            return -(notch + wing * 2 + statusExtra + r.extraWidth) / 2 + r.shift
        }
        XCTAssertEqual(leftEdge(45), leftEdge(65), accuracy: 0.001)
    }

    func testNonNotchScreensOnlyAddTheChipWidthAndNeverShift() {
        let r = QuotaChipLayout.reserve(chipWidth: 60, mascotSize: mascot, wing: wing, statusExtra: 65, hasNotch: false)
        XCTAssertEqual(r, QuotaChipLayout.Reserve(extraWidth: 60 + QuotaChipLayout.wingSpacing, shift: 0))
    }
}
