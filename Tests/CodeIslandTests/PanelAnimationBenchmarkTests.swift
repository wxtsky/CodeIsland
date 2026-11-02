import AppKit
import SwiftUI
import XCTest
import ScreenCaptureKit
import CoreMedia
import CoreVideo
@testable import CodeIsland
import CodeIslandCore

/// Opt-in, synthetic sessions only. Real SwiftUI panel, autonomous transitions,
/// main-thread layout durations and ScreenCaptureKit edge timestamps.
@MainActor
final class PanelAnimationBenchmarkTests: XCTestCase {
    func testRecordTransitions() async throws {
        guard let directory = ProcessInfo.processInfo.environment["PANEL_BENCH_DIR"] else {
            throw XCTSkip("PANEL_BENCH_DIR not set")
        }
        _ = NSApplication.shared
        let sandbox = DefaultsSandbox(keys: DefaultsSandbox.allSettingsKeys)
        defer { sandbox.restore() }
        UserDefaults.standard.set("comfortable", forKey: SettingsKey.sessionListDensity)
        UserDefaults.standard.set(false, forKey: SettingsKey.showUsageStats)
        MascotAnimationGate.shared.setPanelVisible(false)
        defer { MascotAnimationGate.shared.setPanelVisible(true) }
        let state = AppState()
        let count = Int(ProcessInfo.processInfo.environment["PANEL_BENCH_COUNT"] ?? "3") ?? 3
        for i in 0..<max(1, count) {
            var s = SessionSnapshot(startTime: Date().addingTimeInterval(-600))
            s.source = "codex"; s.cwd = "/tmp/panel-benchmark/project-\(i)"
            s.gitBranch = "main"; s.status = i == 0 && ProcessInfo.processInfo.environment["PANEL_BENCH_IDLE"] != "1" ? .running : .idle
            s.addRecentMessage(ChatMessage(isUser: true, text: "Investigate the animation performance and preserve the comfortable layout."))
            s.addRecentMessage(ChatMessage(isUser: false, text: "Measure frame intervals with deterministic session content, then compare the rendering work before and after each isolated change."))
            if s.status == .running { s.currentTool = "Read"; s.toolDescription = "Sources/Panel.swift" }
            state.sessions["bench-\(i)"] = s
        }
        state.activeSessionId = "bench-0"; state.refreshDerivedState(); state.surface = .collapsed
        let root = NotchPanelView(appState: state, hasNotch: true, notchHeight: 32, notchW: 185, screenWidth: 1470)
            .environment(\.mascotStaticTime, 5.2)
            .environment(\.mascotAnimationsActive, false)
        let control = ProcessInfo.processInfo.environment["PANEL_BENCH_CONTROL"] == "1"
        let host = BenchmarkHostingView(rootView: control ? AnyView(BenchmarkControl(state: state)) : AnyView(root))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 510)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 620, height: 510), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false
        window.contentView = host; window.title = "CodeIsland Animation Benchmark"; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let contents = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(contents.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration(); config.width = 620; config.height = 510
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60); config.queueDepth = 5
        config.showsCursor = false; config.pixelFormat = kCVPixelFormatType_32BGRA
        let recorder = BenchmarkFrameRecorder()
        let queue = DispatchQueue(label: "benchmark.frames")
        let filter: SCContentFilter
        if ProcessInfo.processInfo.environment["PANEL_CAPTURE_MODE"] == "display" {
            let display = try XCTUnwrap(contents.displays.first)
            filter = SCContentFilter(display: display, including: [target])
            config.sourceRect = target.frame
            config.backgroundColor = CGColor(gray: 1, alpha: 1)
        } else {
            filter = SCContentFilter(desktopIndependentWindow: target)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        var events = ["host_time,event"]
        var ticks = ["host_time"]
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in ticks.append("\(CACurrentMediaTime())") }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        for i in 0..<8 {
            events.append("\(CACurrentMediaTime()),open-\(i)")
            withAnimation(NotchAnimation.open) { state.surface = .sessionList }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            events.append("\(CACurrentMediaTime()),close-\(i)")
            withAnimation(NotchAnimation.close) { state.surface = .collapsed }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        timer.invalidate(); try await stream.stopCapture()
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try events.joined(separator: "\n").write(toFile: directory + "/events.csv", atomically: true, encoding: .utf8)
        try ticks.joined(separator: "\n").write(toFile: directory + "/ticks.csv", atomically: true, encoding: .utf8)
        try host.layouts.joined(separator: "\n").write(toFile: directory + "/layouts.csv", atomically: true, encoding: .utf8)
        try queue.sync { try recorder.rows.joined(separator: "\n").write(toFile: directory + "/frames.csv", atomically: true, encoding: .utf8) }
    }
}

private final class BenchmarkHostingView: NotchHostingView<AnyView> {
    var layouts = ["host_time,duration_ms"]
    override func layout() {
        let start = CACurrentMediaTime()
        super.layout()
        layouts.append("\(start),\((CACurrentMediaTime() - start) * 1000)")
    }
}

private final class BenchmarkFrameRecorder: NSObject, SCStreamOutput {
    var rows = ["time,status,edge,blackpixels"]
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        let status = info?[.status] as? Int ?? -1
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let data = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels), w = CVPixelBufferGetWidth(pixels), h = CVPixelBufferGetHeight(pixels)
        var edge = 0, count = 0
        for y in 0..<h {
            var dark = 0
            for x in [w/2-4, w/2, w/2+4] {
                let i = y*stride+x*4
                if data[i]<35 && data[i+1]<35 && data[i+2]<35 && data[i+3]>180 { dark += 1 }
            }
            if dark >= 2 { edge = y; count += 1 }
        }
        rows.append("\(CMTimeGetSeconds(buffer.presentationTimeStamp)),\(status),\(edge),\(count)")
    }
}

private struct BenchmarkControl: View {
    let state: AppState
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.black)
                .frame(width: state.surface.isExpanded ? 580 : 320,
                       height: state.surface.isExpanded ? 300 : 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
