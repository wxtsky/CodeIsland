import AppKit
import Observation
import SwiftUI
import XCTest
@testable import CodeIsland

@MainActor
final class RetainedPanelLifecycleTests: XCTestCase {
    @Observable
    final class Model {
        var expanded = false
        var text = "Read Implementation.swift"
    }

    final class CountingHost<Content: View>: NSHostingView<Content> {
        var layouts = 0
        override func layout() {
            super.layout()
            layouts += 1
        }
    }

    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() {
        windows.forEach { $0.contentView = nil }
        windows = []
        super.tearDown()
    }

    func testHiddenLiveTextUpdatesDoNotRunBlurAnimations() {
        struct Scene: View {
            let model: Model
            var body: some View {
                VStack(spacing: 0) {
                    FrameClock(interval: 0.05) { now in Text("bar \(Int(now * 20))") }
                    CollapsiblePanelContent(expanded: model.expanded, width: 580) {
                        MorphText(text: model.text)
                    }
                }
            }
        }
        let model = Model()
        let host = install(Scene(model: model))
        pump(host, for: 0.4)
        host.layouts = 0
        let start = Date()
        var changes = 0
        pump(host, for: 2) {
            if Date().timeIntervalSince(start) >= Double(changes) * 0.3 {
                changes += 1
                model.text = "Update file \(changes) Implementation.swift"
            }
        }
        XCTAssertGreaterThan(changes, 5)
        XCTAssertLessThanOrEqual(host.layouts, 75, "hidden live text drives display-rate blur animations")

        model.expanded = true
        pump(host, for: 0.3)
        host.layouts = 0
        model.text = "Visible text still morphs"
        pump(host, for: 0.3)
        XCTAssertGreaterThan(host.layouts, 8, "revealed text lost its morph animation")
    }

    func testHiddenCallbackCancelsValidationBeforeQuickReopen() {
        final class Seen {
            var checks = 0
            var disappears = 0
            var outcome: JumpValidationOutcome?
            var task: Task<Void, Never>?
        }
        struct Scene: View {
            let model: Model
            let seen: Seen
            var body: some View {
                CollapsiblePanelContent(expanded: model.expanded, width: 580) {
                    Text("session")
                        .onPanelContentHidden { seen.task?.cancel() }
                        .onDisappear { seen.disappears += 1 }
                }
            }
        }
        let model = Model(), seen = Seen()
        model.expanded = true
        let host = install(Scene(model: model, seen: seen))
        pump(host, for: 0.2)
        seen.task = Task {
            seen.outcome = await evaluateJumpValidation(delays: [120_000_000]) {
                seen.checks += 1
                return true
            }
        }
        defer { seen.task?.cancel() }
        model.expanded = false
        pump(host, for: 0.03)
        model.expanded = true
        pump(host, for: 0.25)
        XCTAssertEqual(seen.disappears, 0, "the regression requires a retained view")
        XCTAssertEqual(seen.outcome, .cancelled)
        XCTAssertEqual(seen.checks, 0, "a stale validation can still affect the reopened list")
    }

    func testCancellingAnActiveShakeStopsNonzeroOffsetWrites() {
        var writes: [CGFloat] = []
        let offset = Binding<CGFloat>(get: { writes.last ?? 0 }, set: { writes.append($0) })
        let host = install(Text("shake"))
        let task = Task { await JumpAnimationHelper.runShake(offset: offset) }
        defer { task.cancel() }
        pump(host, for: 0.01)
        XCTAssertFalse(writes.isEmpty)
        task.cancel()
        let beforeReset = writes.count
        offset.wrappedValue = 0 // SessionCard's hide cleanup.
        pump(host, for: 0.15)
        XCTAssertTrue(writes.dropFirst(beforeReset).allSatisfy { $0 == 0 },
                      "a cancelled shake still animates the retained card")
        XCTAssertEqual(offset.wrappedValue, 0)
    }

    private func install<V: View>(_ view: V) -> CountingHost<V> {
        let host = CountingHost(rootView: view)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 510)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        windows.append(window)
        return host
    }

    private func pump(_ host: NSView, for seconds: TimeInterval, step: () -> Void = {}) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            step()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
    }
}
