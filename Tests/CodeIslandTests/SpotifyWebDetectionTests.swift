import XCTest
@testable import CodeIsland

final class SpotifyWebDetectionTests: XCTestCase {

    func testDetectSpotifyWebInBrowsersDefaultSetting() {
        XCTAssertTrue(SettingsDefaults.detectSpotifyWebInBrowsers)
        XCTAssertEqual(SettingsKey.detectSpotifyWebInBrowsers, "detectSpotifyWebInBrowsers")
        _ = SettingsManager.shared
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsKey.detectSpotifyWebInBrowsers))
    }

    func testSupportedBrowsersCatalog() {
        let browsers = SpotifyWebBrowser.allCases
        XCTAssertEqual(browsers.map(\.bundleIdentifier), [
            "com.apple.Safari",
            "com.brave.Browser",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "com.microsoft.edgemac"
        ])
        XCTAssertEqual(SpotifyWebBrowser.brave.shortBadge, "SPOTIFY · BRAVE")
        XCTAssertEqual(SpotifyWebBrowser.safari.shortBadge, "SPOTIFY · SAFARI")
        XCTAssertEqual(SpotifyWebBrowser.chrome.shortBadge, "SPOTIFY · CHROME")
        XCTAssertEqual(SpotifyWebBrowser.arc.shortBadge, "SPOTIFY · ARC")
        XCTAssertEqual(SpotifyWebBrowser.edge.shortBadge, "SPOTIFY · EDGE")
        for browser in browsers {
            XCTAssertFalse(browser.jsPermissionHint.isEmpty)
        }
    }

    func testParseTimecode() {
        XCTAssertEqual(NowPlayingManager.parseTimecode("0:00"), 0.0)
        XCTAssertEqual(NowPlayingManager.parseTimecode("1:25"), 85.0)
        XCTAssertEqual(NowPlayingManager.parseTimecode("03:05"), 185.0)
        XCTAssertEqual(NowPlayingManager.parseTimecode("1:02:03"), 3723.0)
        XCTAssertEqual(NowPlayingManager.parseTimecode("42.5"), 42.5)
        XCTAssertEqual(NowPlayingManager.parseTimecode("-1:10"), -70.0)
        XCTAssertNil(NowPlayingManager.parseTimecode(""))
    }

    func testTier1DOMOutputParsing() {
        let raw = "DOM|||Midnight City|||M83|||Hurry Up, We're Dreaming|||1:15|||4:03|||https://i.scdn.co/image/abc123|||playing"
        let snapshot = NowPlayingManager.parseBrowserScriptOutput(
            raw,
            browser: .brave,
            previousSnapshot: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.title, "Midnight City")
        XCTAssertEqual(snapshot?.artist, "M83")
        XCTAssertEqual(snapshot?.album, "Hurry Up, We're Dreaming")
        XCTAssertEqual(snapshot?.position, 75.0)
        XCTAssertEqual(snapshot?.duration, 243.0)
        XCTAssertEqual(snapshot?.artworkURLOrPath, "https://i.scdn.co/image/abc123")
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.source, .spotifyWeb(.brave))
        XCTAssertEqual(snapshot?.isJSBridgeAvailable, true)
    }

    func testTier1DOMRemainingDurationCalculation() {
        // When Spotify Web displays remaining time (e.g. "-2:00" at position "1:30"), total duration is 3:30 (210s)
        let raw = "DOM|||Starboy|||The Weeknd|||Starboy|||1:30|||-2:00|||https://i.scdn.co/image/xyz|||playing"
        let snapshot = NowPlayingManager.parseBrowserScriptOutput(
            raw,
            browser: .safari,
            previousSnapshot: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.position, 90.0)
        XCTAssertEqual(snapshot?.duration, 210.0)
        XCTAssertEqual(snapshot?.source, .spotifyWeb(.safari))
    }

    func testTier2FallbackTabTitleParsingWhenPlaying() {
        let raw = "FALLBACK|||Blinding Lights • The Weeknd"
        let snapshot = NowPlayingManager.parseBrowserScriptOutput(
            raw,
            browser: .chrome,
            previousSnapshot: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.title, "Blinding Lights")
        XCTAssertEqual(snapshot?.artist, "The Weeknd")
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.isJSBridgeAvailable, false)
        XCTAssertEqual(snapshot?.source, .spotifyWeb(.chrome))
    }

    func testTier2FallbackRetainsPreviousTrackAsPausedWhenTabTitleRevertsToGenericSpotify() {
        let previous = PlaybackSnapshot(
            title: "Blinding Lights",
            artist: "The Weeknd",
            album: "",
            position: 48.0,
            duration: 200.0,
            artworkURLOrPath: "",
            isPlaying: true,
            source: .spotifyWeb(.chrome),
            isJSBridgeAvailable: false
        )

        let raw = "FALLBACK|||Spotify – Web Player: Music for everyone"
        let snapshot = NowPlayingManager.parseBrowserScriptOutput(
            raw,
            browser: .chrome,
            previousSnapshot: previous
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.title, "Blinding Lights")
        XCTAssertEqual(snapshot?.artist, "The Weeknd")
        XCTAssertEqual(snapshot?.position, 48.0)
        XCTAssertEqual(snapshot?.duration, 200.0)
        XCTAssertEqual(snapshot?.isPlaying, false)
        XCTAssertEqual(snapshot?.isJSBridgeAvailable, false)
    }

    func testSmartSourcePriorityPrefersActivelyPlayingWebOverPausedDesktop() {
        let pausedDesktop = PlaybackSnapshot(
            title: "Old Desktop Song",
            artist: "Desktop Artist",
            album: "Album A",
            position: 120.0,
            duration: 240.0,
            artworkURLOrPath: "",
            isPlaying: false,
            source: .spotifyDesktop,
            isJSBridgeAvailable: true
        )
        let playingWeb = PlaybackSnapshot(
            title: "Active Browser Song",
            artist: "Browser Artist",
            album: "Album B",
            position: 14.0,
            duration: 195.0,
            artworkURLOrPath: "https://i.scdn.co/image/web",
            isPlaying: true,
            source: .spotifyWeb(.brave),
            isJSBridgeAvailable: true
        )

        let chosen = NowPlayingManager.resolvePreferredSnapshot(
            candidates: [pausedDesktop, playingWeb],
            lastActiveSource: .spotifyDesktop
        )

        XCTAssertEqual(chosen?.source, .spotifyWeb(.brave))
        XCTAssertEqual(chosen?.title, "Active Browser Song")
        XCTAssertEqual(chosen?.isPlaying, true)
    }

    func testSmartSourcePriorityRetainsLastActiveSourceWhenAllPaused() {
        let pausedDesktop = PlaybackSnapshot(
            title: "Old Desktop Song",
            artist: "Desktop Artist",
            album: "Album A",
            position: 120.0,
            duration: 240.0,
            artworkURLOrPath: "",
            isPlaying: false,
            source: .spotifyDesktop,
            isJSBridgeAvailable: true
        )
        let pausedWeb = PlaybackSnapshot(
            title: "Paused Browser Song",
            artist: "Browser Artist",
            album: "Album B",
            position: 55.0,
            duration: 195.0,
            artworkURLOrPath: "",
            isPlaying: false,
            source: .spotifyWeb(.brave),
            isJSBridgeAvailable: true
        )

        let chosen = NowPlayingManager.resolvePreferredSnapshot(
            candidates: [pausedDesktop, pausedWeb],
            lastActiveSource: .spotifyWeb(.brave)
        )

        XCTAssertEqual(chosen?.source, .spotifyWeb(.brave))
        XCTAssertEqual(chosen?.title, "Paused Browser Song")
        XCTAssertEqual(chosen?.isPlaying, false)
    }
}
