import AppKit
import XCTest
@testable import CodeIsland

final class PanelWindowControllerTests: XCTestCase {
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

    /// A click on a button, a row or the card's background must leave key
    /// status with the app in front: the island needs no keyboard for it.
    func testClickOutsideATextFieldDoesNotMakeThePanelKey() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let button = NSButton(title: "Allow", target: nil, action: nil)
        container.addSubview(button)

        XCTAssertFalse(PanelKeyPolicy.mayBecomeKey(forClickOn: nil))
        XCTAssertFalse(PanelKeyPolicy.mayBecomeKey(forClickOn: container))
        XCTAssertFalse(PanelKeyPolicy.mayBecomeKey(forClickOn: button))
    }

    /// Text on the card is drawn with non-editable fields; reading it is not typing.
    func testClickOnALabelDoesNotMakeThePanelKey() {
        XCTAssertFalse(PanelKeyPolicy.mayBecomeKey(forClickOn: NSTextField(labelWithString: "Run tests?")))
    }

    /// A question card's typed answer is the one place the island needs the keyboard.
    func testClickInAnEditableTextFieldMakesThePanelKey() {
        XCTAssertTrue(PanelKeyPolicy.mayBecomeKey(forClickOn: NSTextField(string: "")))
        XCTAssertTrue(PanelKeyPolicy.mayBecomeKey(forClickOn: NSTextView()))
    }

    /// The hit view is often a subview of the field (its cell's editor or a
    /// SwiftUI wrapper), so the check walks up to the field.
    func testClickInsideAnEditableTextFieldsSubviewMakesThePanelKey() {
        let field = NSTextField(string: "")
        let inner = NSView()
        field.addSubview(inner)

        XCTAssertTrue(PanelKeyPolicy.mayBecomeKey(forClickOn: inner))
    }
}
