import XCTest
import SwiftUI
import AppKit
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class PrayerScreenshotTests: XCTestCase {
    func testRenderPrayerScreenshots() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outDir = env["PRAYER_SHOT_DIR"] else {
            return
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let manager = PrayerTimeManager.shared
        UserDefaults.standard.set(true, forKey: SettingsKey.prayerEnabled)
        UserDefaults.standard.set("kemenag", forKey: SettingsKey.prayerCalculationMethod)
        UserDefaults.standard.set("manual", forKey: SettingsKey.prayerLocationMode)
        UserDefaults.standard.set("jakarta", forKey: SettingsKey.prayerManualCityId)
        manager.forceRecalculate()

        let state = AppState()
        state.surface = .sessionList

        let screen = StageScreen.macBook14
        let renderWidth: CGFloat = 780
        let renderHeight: CGFloat = 360
        let view = NotchPanelView(
            appState: state,
            hasNotch: true,
            notchHeight: screen.notchHeight,
            notchW: screen.notchWidth,
            screenWidth: screen.screenWidth,
            initialTab: .prayer
        )
        .environment(\.mascotStaticTime, 5.2)
        .environment(\.colorScheme, .dark)
        .frame(width: renderWidth, height: renderHeight)

        // 1. NIGHT SHOT (simulating 20:44:28 matching review mockup)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Jakarta")!
        var nightComps = cal.dateComponents([.year, .month, .day], from: Date())
        nightComps.hour = 20
        nightComps.minute = 44
        nightComps.second = 28
        let nightDate = cal.date(from: nightComps) ?? Date()
        manager.simulatedDate = nightDate
        manager.tick(now: nightDate)

        let nightFull = try OffscreenRender.hosted(view, size: CGSize(width: renderWidth, height: renderHeight), appearance: .darkAqua)
        let nightTrimmed = try OffscreenRender.trimmedToContent(nightFull)

        let nightStage = Stage(
            panel: nightTrimmed.image,
            panelHeight: nightTrimmed.height,
            layout: StageLayout(width: 860, bottomMargin: 24, menuItems: true),
            screen: screen,
            wallpaper: .dark,
            clock: "Wed 20:44"
        )
        if let nightImg = OffscreenRender.rasterize(nightStage),
           let nightPng = NSBitmapImageRep(cgImage: nightImg).representation(using: .png, properties: [:]) {
            let nightPath = "\(outDir)/prayer-ui-night.png"
            try nightPng.write(to: URL(fileURLWithPath: nightPath))
            print("Successfully written night screenshot to: \(nightPath)")
        }

        // 2. DAY SHOT (current real time)
        manager.simulatedDate = nil
        manager.tick(now: Date())
        let dayFull = try OffscreenRender.hosted(view, size: CGSize(width: renderWidth, height: renderHeight), appearance: .darkAqua)
        let dayTrimmed = try OffscreenRender.trimmedToContent(dayFull)

        let dayStage = Stage(
            panel: dayTrimmed.image,
            panelHeight: dayTrimmed.height,
            layout: StageLayout(width: 860, bottomMargin: 24, menuItems: true),
            screen: screen,
            wallpaper: .dark,
            clock: "Wed 11:30"
        )
        if let dayImg = OffscreenRender.rasterize(dayStage),
           let dayPng = NSBitmapImageRep(cgImage: dayImg).representation(using: .png, properties: [:]) {
            let dayPath = "\(outDir)/prayer-ui-day.png"
            try dayPng.write(to: URL(fileURLWithPath: dayPath))
            print("Successfully written day screenshot to: \(dayPath)")
        }
    }
}
