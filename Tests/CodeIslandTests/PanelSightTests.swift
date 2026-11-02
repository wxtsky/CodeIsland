import XCTest
@testable import CodeIsland

/// Where a shortcut finds the island (#384): hidden over a fullscreen app,
/// or up on another display than the one the user works on, it is brought
/// to them rather than taken as seen.
final class PanelSightTests: XCTestCase {

    // MARK: - Hide in Fullscreen

    func testTheLatchHidesTheIslandOnlyWithTheSettingOn() {
        var hide = PanelFullscreenHide()
        XCTAssertFalse(hide.hidesIsland(hideInFullscreen: true))
        hide.latch()
        XCTAssertTrue(hide.hidesIsland(hideInFullscreen: true))
        XCTAssertFalse(hide.hidesIsland(hideInFullscreen: false))
    }

    func testAShortcutRevealsTheIslandUntilItCollapses() {
        var hide = PanelFullscreenHide()
        hide.latch()
        hide.reveal()
        XCTAssertFalse(hide.hidesIsland(hideInFullscreen: true))
        // Another fullscreen Space while it is open keeps it up.
        hide.latch()
        XCTAssertFalse(hide.hidesIsland(hideInFullscreen: true))

        hide.islandCollapsed()
        XCTAssertTrue(hide.hidesIsland(hideInFullscreen: true), "closed again, it hides again")
    }

    func testLeavingFullscreenEndsTheReveal() {
        var hide = PanelFullscreenHide()
        hide.latch()
        hide.reveal()
        hide.unlatch()
        XCTAssertFalse(hide.isRevealed)
        hide.latch()
        XCTAssertTrue(hide.hidesIsland(hideInFullscreen: true), "the next fullscreen app hides it again")
    }

    /// Nothing was hidden: the press reveals nothing, and a fullscreen app
    /// that comes up later still hides the island.
    func testARevealWithoutTheLatchDoesNothing() {
        var hide = PanelFullscreenHide()
        hide.reveal()
        XCTAssertFalse(hide.isRevealed)
        hide.latch()
        XCTAssertTrue(hide.hidesIsland(hideInFullscreen: true))
    }

    // MARK: - Away from the user

    func testAnIslandHiddenOverAFullscreenAppIsAway() {
        XCTAssertTrue(PanelSight.isAway(
            hiddenInFullscreen: true, isShown: false, userIsOnIsland: false, isOnWorkingDisplay: true
        ))
    }

    func testAnIslandOnTheWorkingDisplayIsInSight() {
        XCTAssertFalse(PanelSight.isAway(
            hiddenInFullscreen: false, isShown: true, userIsOnIsland: false, isOnWorkingDisplay: true
        ))
    }

    /// The window in front moved to the other display and the island has
    /// not followed yet.
    func testAnIslandOnAnotherDisplayIsAway() {
        XCTAssertTrue(PanelSight.isAway(
            hiddenInFullscreen: false, isShown: true, userIsOnIsland: false, isOnWorkingDisplay: false
        ))
    }

    /// Typing into its card or pointing at it, the user is on the island,
    /// wherever the window in front is.
    func testAnIslandTheUserIsOnIsInSight() {
        XCTAssertFalse(PanelSight.isAway(
            hiddenInFullscreen: false, isShown: true, userIsOnIsland: true, isOnWorkingDisplay: false
        ))
    }

    /// Hidden with no session running there is nothing to bring, and the
    /// window list is not read for it.
    func testAnIslandHiddenForNoSessionIsNotAway() {
        var displayLookedUp = false
        XCTAssertFalse(PanelSight.isAway(
            hiddenInFullscreen: false, isShown: false, userIsOnIsland: false,
            isOnWorkingDisplay: { displayLookedUp = true; return false }()
        ))
        XCTAssertFalse(displayLookedUp)
    }
}
