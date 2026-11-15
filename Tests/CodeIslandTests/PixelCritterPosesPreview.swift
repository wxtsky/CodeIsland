import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland

/// Opt-in strip of the Pixel critter's seven poses for Clawd and Dex, large
/// and at notch size. Skipped unless CRITTER_POSES_PNG is set:
///
///     CRITTER_POSES_PNG=/tmp/critter.png swift test --filter PixelCritterPosesPreview
@MainActor
final class PixelCritterPosesPreview: XCTestCase {
    func testRenderPoses() throws {
        guard let out = ProcessInfo.processInfo.environment["CRITTER_POSES_PNG"] else {
            throw XCTSkip("CRITTER_POSES_PNG not set")
        }
        _ = NSApplication.shared
        let poses: [(String, MascotAgentStatus, MascotOutcome?)] = [
            ("idle", .idle, nil), ("thinking", .processing, nil), ("running", .running, nil),
            ("approval", .waitingApproval, nil), ("question", .waitingQuestion, nil),
            ("done", .idle, .done), ("error", .idle, .error),
        ]
        let strip = HStack(spacing: 18) {
            ForEach(Array(poses.enumerated()), id: \.offset) { _, p in
                VStack(spacing: 6) {
                    PixelCritterView(status: p.1, outcome: p.2, size: 96, style: .clawd)
                    HStack(spacing: 4) {
                        PixelCritterView(status: p.1, outcome: p.2, size: 24, style: .clawd)
                        PixelCritterView(status: p.1, outcome: p.2, size: 24, style: .dex)
                    }
                    PixelCritterView(status: p.1, outcome: p.2, size: 96, style: .dex)
                    Text(p.0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
                }
            }
        }
        .environment(\.mascotSpeed, 0)
        .padding(16)
        .background(Color.black)
        let image = try OffscreenRender.hosted(strip, size: CGSize(width: 860, height: 300))
        try OffscreenRender.writePNG(image, to: out)
    }
}
