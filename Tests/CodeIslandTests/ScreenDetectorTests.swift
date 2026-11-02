import AppKit
import XCTest
@testable import CodeIsland

final class ScreenDetectorTests: XCTestCase {
    func testAutoPreferredIndexUsesActiveWorkScreenBeforeBuiltInScreen() {
        let candidates = [
            ScreenDetector.Candidate(
                frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                hasNotch: true,
                isMain: true
            ),
            ScreenDetector.Candidate(
                frame: NSRect(x: 1512, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: false
            )
        ]

        let index = ScreenDetector.autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: NSRect(x: 1800, y: 100, width: 1000, height: 800)
        )

        XCTAssertEqual(index, 1)
    }

    func testAutoPreferredIndexFallsBackToBuiltInScreenWhenNoActiveWorkScreenExists() {
        let candidates = [
            ScreenDetector.Candidate(
                frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                hasNotch: true,
                isMain: false
            ),
            ScreenDetector.Candidate(
                frame: NSRect(x: 1512, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: true
            )
        ]

        let index = ScreenDetector.autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: nil
        )

        XCTAssertEqual(index, 0)
    }

    func testAutoPreferredIndexFallsBackToMainScreenWhenNoBuiltInScreenExists() {
        let candidates = [
            ScreenDetector.Candidate(
                frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: false
            ),
            ScreenDetector.Candidate(
                frame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
                hasNotch: false,
                isMain: true
            )
        ]

        let index = ScreenDetector.autoPreferredIndex(
            candidates: candidates,
            activeWindowBounds: nil
        )

        XCTAssertEqual(index, 1)
    }

    // MARK: - Window bounds in AppKit coordinates (#384)

    /// A 27" monitor above a MacBook (the MacBook primary). CGWindowList puts
    /// the monitor at negative y; AppKit puts it above y = 982.
    private let builtInPrimary = ScreenDetector.Candidate(
        frame: NSRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true, isMain: false
    )
    private let monitorAbove = ScreenDetector.Candidate(
        frame: NSRect(x: -524, y: 982, width: 2560, height: 1440), hasNotch: false, isMain: true
    )

    func testWindowBoundsAreFlippedAgainstThePrimaryScreen() {
        let cgBounds = CGRect(x: 100, y: -1300, width: 1600, height: 1000)
        XCTAssertEqual(
            ScreenDetector.appKitRect(fromWindowBounds: cgBounds, primaryScreenMaxY: 982),
            CGRect(x: 100, y: 1282, width: 1600, height: 1000)
        )
        // A window filling the primary screen is the screen itself.
        XCTAssertEqual(
            ScreenDetector.appKitRect(fromWindowBounds: CGRect(x: 0, y: 0, width: 1512, height: 982), primaryScreenMaxY: 982),
            builtInPrimary.frame
        )
    }

    /// Compared unconverted, a window on the monitor above landed on no
    /// screen and the island stayed on the MacBook.
    func testAutoFollowsAWindowOnAMonitorAboveTheMacBook() {
        XCTAssertEqual(
            ScreenDetector.autoPreferredIndex(
                candidates: [builtInPrimary, monitorAbove],
                frontWindowListBounds: CGRect(x: 100, y: -1300, width: 1600, height: 1000)
            ),
            1
        )
        // A window on the MacBook keeps it there.
        XCTAssertEqual(
            ScreenDetector.autoPreferredIndex(
                candidates: [builtInPrimary, monitorAbove],
                frontWindowListBounds: CGRect(x: 100, y: 100, width: 1200, height: 700)
            ),
            0
        )
    }

    /// Two monitors side by side, bottoms aligned, the second one shorter: a
    /// window low on it used to resolve to the main monitor beside it.
    func testAutoFollowsAWindowLowOnAShorterMonitorBeside() {
        let primary = ScreenDetector.Candidate(
            frame: NSRect(x: 0, y: 0, width: 2560, height: 1440), hasNotch: false, isMain: true
        )
        let beside = ScreenDetector.Candidate(
            frame: NSRect(x: 2560, y: 0, width: 1920, height: 1080), hasNotch: false, isMain: false
        )
        XCTAssertEqual(
            ScreenDetector.autoPreferredIndex(
                candidates: [primary, beside],
                frontWindowListBounds: CGRect(x: 2700, y: 1100, width: 1000, height: 300)
            ),
            1
        )
    }

    /// The usual MacBook-and-monitor layout, tops aligned: a window in the
    /// part of the monitor below the MacBook's height.
    func testAutoFollowsAWindowLowOnATallerMonitorBeside() {
        let monitor = ScreenDetector.Candidate(
            frame: NSRect(x: 1512, y: -458, width: 2560, height: 1440), hasNotch: false, isMain: false
        )
        XCTAssertEqual(
            ScreenDetector.autoPreferredIndex(
                candidates: [builtInPrimary, monitor],
                frontWindowListBounds: CGRect(x: 1600, y: 1100, width: 1200, height: 300)
            ),
            1
        )
    }

    // MARK: - Fullscreen on the island's display (#384)

    /// A fullscreen app on the monitor beside the MacBook: larger than the
    /// MacBook's screen, which is all the size check asked.
    func testAFullscreenWindowOnAnotherDisplayIsNotFullscreenOnTheIslands() {
        let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let monitor = NSRect(x: 1512, y: -458, width: 2560, height: 1440)
        let fullscreenOnMonitor = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        XCTAssertTrue(ScreenDetector.isFullscreen(
            onScreenFrame: monitor, windowListBounds: [fullscreenOnMonitor], primaryScreenMaxY: 982
        ))
        XCTAssertFalse(ScreenDetector.isFullscreen(
            onScreenFrame: builtIn, windowListBounds: [fullscreenOnMonitor], primaryScreenMaxY: 982
        ))
        // With another window of the app on the MacBook, as a second
        // terminal window is.
        XCTAssertFalse(ScreenDetector.isFullscreen(
            onScreenFrame: builtIn,
            windowListBounds: [CGRect(x: 100, y: 100, width: 1200, height: 700), fullscreenOnMonitor],
            primaryScreenMaxY: 982
        ))
    }

    func testAFullscreenWindowOnAnIdenticalMonitorBesideIsNotFullscreenOnTheIslands() {
        let left = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = NSRect(x: 1920, y: 0, width: 1920, height: 1080)
        let fullscreenOnRight = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(ScreenDetector.isFullscreen(
            onScreenFrame: right, windowListBounds: [fullscreenOnRight], primaryScreenMaxY: 1080
        ))
        XCTAssertFalse(ScreenDetector.isFullscreen(
            onScreenFrame: left, windowListBounds: [fullscreenOnRight], primaryScreenMaxY: 1080
        ))
    }

    func testAFullscreenWindowOnAMonitorAboveIsFullscreenThere() {
        let fullscreenAbove = CGRect(x: -524, y: -1440, width: 2560, height: 1440)
        XCTAssertTrue(ScreenDetector.isFullscreen(
            onScreenFrame: monitorAbove.frame, windowListBounds: [fullscreenAbove], primaryScreenMaxY: 982
        ))
        XCTAssertFalse(ScreenDetector.isFullscreen(
            onScreenFrame: builtInPrimary.frame, windowListBounds: [fullscreenAbove], primaryScreenMaxY: 982
        ))
    }

    func testAMaximizedWindowIsNotFullscreen() {
        let monitor = NSRect(x: 1512, y: -458, width: 2560, height: 1440)
        let belowMenuBar = NSRect(x: 1512, y: -458, width: 2560, height: 1415)
        XCTAssertFalse(ScreenDetector.windowCoversScreen(belowMenuBar, screenFrame: monitor))
        XCTAssertFalse(ScreenDetector.windowCoversScreen(belowMenuBar, screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982)))
    }

    /// Fullscreen apps on a notched MacBook sit below the notch, as before.
    func testAFullscreenAppBelowTheNotchDoesNotCoverTheNotchedScreen() {
        let builtIn = NSRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertFalse(ScreenDetector.windowCoversScreen(NSRect(x: 0, y: 0, width: 1512, height: 950), screenFrame: builtIn))
    }

    func testAFullscreenWindowAtFractionalCoordinatesCovers() {
        let monitor = NSRect(x: 1512, y: -458, width: 2560, height: 1440)
        XCTAssertTrue(ScreenDetector.windowCoversScreen(
            NSRect(x: 1511.5, y: -458.5, width: 2560, height: 1440), screenFrame: monitor
        ))
    }
}
