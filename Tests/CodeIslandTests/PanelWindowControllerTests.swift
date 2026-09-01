import AppKit
import XCTest
@testable import CodeIsland

final class PanelWindowControllerTests: XCTestCase {
    func testSpaceTransitionKeepsPanelVisibleUntilFullscreenDetectionSettles() {
        XCTAssertFalse(PanelSpaceTransitionPolicy.immediateFullscreenLatch)
        XCTAssertGreaterThan(PanelSpaceTransitionPolicy.fullscreenEvaluationDelay, 0)
    }

    func testSettledSpaceUsesDetectedFullscreenState() {
        XCTAssertTrue(PanelSpaceTransitionPolicy.settledFullscreenLatch(isFullscreen: true))
        XCTAssertFalse(PanelSpaceTransitionPolicy.settledFullscreenLatch(isFullscreen: false))
    }

    /// `.managed` tells Spaces the window belongs to exactly one Space and should be
    /// reassigned as the user switches — the opposite membership model from
    /// `.canJoinAllSpaces`. Combining them is what produced the drop-out/reappear
    /// glitch during a Space swipe: `.stationary` (pinned like the menu bar, no
    /// transition participation) is the correct pairing with `.canJoinAllSpaces`.
    func testPanelStaysPinnedAcrossSpaceTransitionsInsteadOfBeingSpaceManaged() {
        let behavior = PanelWindowBehavior.collectionBehavior

        XCTAssertTrue(behavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(behavior.contains(.stationary))
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(behavior.contains(.ignoresCycle))
        XCTAssertFalse(behavior.contains(.managed))
        XCTAssertFalse(behavior.contains(.canJoinAllApplications))
    }

    func testScreenHopMotionUsesMoreVisibleTiming() {
        let motion = PanelWindowController.screenHopMotion()

        XCTAssertEqual(motion.outgoingOffset, 18)
        XCTAssertEqual(motion.incomingOffset, 30)
        XCTAssertEqual(motion.fadeOutDuration, 0.14, accuracy: 0.001)
        XCTAssertEqual(motion.incomingPauseDuration, 0.06, accuracy: 0.001)
        XCTAssertEqual(motion.fadeInDuration, 0.34, accuracy: 0.001)
    }

    func testScreenHopFramesRetractOldFrameAndDropIntoNewFrame() {
        let oldFrame = NSRect(x: 100, y: 820, width: 420, height: 180)
        let newFrame = NSRect(x: 1800, y: 900, width: 420, height: 180)

        let frames = PanelWindowController.screenHopFrames(
            oldFrame: oldFrame,
            newFrame: newFrame
        )

        XCTAssertEqual(frames.outgoing.origin.x, oldFrame.origin.x)
        XCTAssertEqual(frames.outgoing.origin.y, oldFrame.origin.y + 18)
        XCTAssertEqual(frames.outgoing.size, oldFrame.size)

        XCTAssertEqual(frames.incoming.origin.x, newFrame.origin.x)
        XCTAssertEqual(frames.incoming.origin.y, newFrame.origin.y + 30)
        XCTAssertEqual(frames.incoming.size, newFrame.size)
    }
}
