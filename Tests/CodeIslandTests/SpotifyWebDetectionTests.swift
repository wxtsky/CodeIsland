import XCTest
@testable import CodeIsland

final class SpotifyWebDetectionTests: XCTestCase {

    func testDetectSpotifyWebInBrowsersDefaultSetting() {
        XCTAssertTrue(SettingsDefaults.detectSpotifyWebInBrowsers)
        XCTAssertEqual(SettingsKey.detectSpotifyWebInBrowsers, "detectSpotifyWebInBrowsers")
        _ = SettingsManager.shared
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsKey.detectSpotifyWebInBrowsers))
    }

    func testSupportedBrowsersAndWebMusicServicesCatalog() {
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
        XCTAssertEqual(WebMusicService.spotifyWeb.badge(for: .brave), "SPOTIFY · BRAVE")
        XCTAssertEqual(WebMusicService.youtubeMusic.badge(for: .brave), "YT MUSIC · BRAVE")
        XCTAssertEqual(WebMusicService.appleMusicWeb.badge(for: .safari), "APPLE MUSIC · SAFARI")

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

    func testTier1DOMOutputParsingSpotifyWeb() {
        let raw = "DOM|||spotify|||Midnight City|||M83|||Hurry Up, We're Dreaming|||1:15|||4:03|||https://i.scdn.co/image/abc123|||playing"
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
        XCTAssertEqual(snapshot?.source, .webMusic(service: .spotifyWeb, browser: .brave))
        XCTAssertEqual(snapshot?.source.displayBadge, "SPOTIFY · BRAVE")
        XCTAssertEqual(snapshot?.isJSBridgeAvailable, true)
    }

    func testTier1DOMOutputParsingYouTubeMusic() {
        let raw = "DOM|||ytmusic|||Get Lucky (Official Audio)|||Daft Punk - Topic|||Random Access Memories|||64.25|||248.5|||https://lh3.googleusercontent.com/art123|||playing"
        let snapshot = NowPlayingManager.parseBrowserScriptOutput(
            raw,
            browser: .chrome,
            previousSnapshot: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.title, "Get Lucky (Official Audio)")
        XCTAssertEqual(snapshot?.artist, "Daft Punk - Topic")
        XCTAssertEqual(snapshot?.album, "Random Access Memories")
        XCTAssertEqual(snapshot?.position, 64.25)
        XCTAssertEqual(snapshot?.duration, 248.5)
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.source, .webMusic(service: .youtubeMusic, browser: .chrome))
        XCTAssertEqual(snapshot?.source.displayBadge, "YT MUSIC · CHROME")
        XCTAssertEqual(snapshot?.isJSBridgeAvailable, true)
    }

    func testTier1DOMOutputParsingAppleMusicWeb() {
        let raw = "DOM|||applemusic|||Severance Main Titles|||Theodore Shapiro|||Severance (Apple TV+ Original Series Soundtrack)|||0:45|||1:38|||https://is1-ssl.mzstatic.com/image/thumb/art.jpg|||playing"
        let snapshot = NowPlayingManager.parseBrowserScriptOutput(
            raw,
            browser: .safari,
            previousSnapshot: nil
        )

        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.title, "Severance Main Titles")
        XCTAssertEqual(snapshot?.artist, "Theodore Shapiro")
        XCTAssertEqual(snapshot?.position, 45.0)
        XCTAssertEqual(snapshot?.duration, 98.0)
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.source, .webMusic(service: .appleMusicWeb, browser: .safari))
        XCTAssertEqual(snapshot?.source.displayBadge, "APPLE MUSIC · SAFARI")
    }

    func testTier1DOMRemainingDurationCalculation() {
        let raw = "DOM|||spotify|||Starboy|||The Weeknd|||Starboy|||1:30|||-2:00|||https://i.scdn.co/image/xyz|||playing"
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

    func testTier2FallbackTabTitleParsingAcrossServices() {
        // Spotify Web fallback
        let spotifyRaw = "FALLBACK|||spotify|||Blinding Lights • The Weeknd"
        let spotifySnap = NowPlayingManager.parseBrowserScriptOutput(
            spotifyRaw,
            browser: .chrome,
            previousSnapshot: nil
        )
        XCTAssertEqual(spotifySnap?.title, "Blinding Lights")
        XCTAssertEqual(spotifySnap?.artist, "The Weeknd")
        XCTAssertEqual(spotifySnap?.source, .webMusic(service: .spotifyWeb, browser: .chrome))
        XCTAssertEqual(spotifySnap?.isJSBridgeAvailable, false)

        // YouTube Music fallback
        let ytRaw = "FALLBACK|||ytmusic|||Numb • Linkin Park - YouTube Music"
        let ytSnap = NowPlayingManager.parseBrowserScriptOutput(
            ytRaw,
            browser: .brave,
            previousSnapshot: nil
        )
        XCTAssertEqual(ytSnap?.title, "Numb")
        XCTAssertEqual(ytSnap?.artist, "Linkin Park")
        XCTAssertEqual(ytSnap?.source, .webMusic(service: .youtubeMusic, browser: .brave))
        XCTAssertEqual(ytSnap?.isJSBridgeAvailable, false)

        // Apple Music Web fallback
        let amRaw = "FALLBACK|||applemusic|||Veridis Quo • Daft Punk — Apple Music"
        let amSnap = NowPlayingManager.parseBrowserScriptOutput(
            amRaw,
            browser: .safari,
            previousSnapshot: nil
        )
        XCTAssertEqual(amSnap?.title, "Veridis Quo")
        XCTAssertEqual(amSnap?.artist, "Daft Punk")
        XCTAssertEqual(amSnap?.source, .webMusic(service: .appleMusicWeb, browser: .safari))
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

        let raw = "FALLBACK|||spotify|||Spotify – Web Player: Music for everyone"
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

    func testLyricsMetadataSanitizerRemovesYouTubeNoise() {
        let cleaned1 = NowPlayingManager.sanitizeForLyricsSearch(
            title: "Blinding Lights (Official Music Video)",
            artist: "The Weeknd - Topic"
        )
        XCTAssertEqual(cleaned1.title, "Blinding Lights")
        XCTAssertEqual(cleaned1.artist, "The Weeknd")

        let cleaned2 = NowPlayingManager.sanitizeForLyricsSearch(
            title: "Midnight City [Official Audio]",
            artist: "M83VEVO"
        )
        XCTAssertEqual(cleaned2.title, "Midnight City")
        XCTAssertEqual(cleaned2.artist, "M83")

        let cleaned3 = NowPlayingManager.sanitizeForLyricsSearch(
            title: "Creep (Official Lyric Video) [HD]",
            artist: "Radiohead"
        )
        XCTAssertEqual(cleaned3.title, "Creep")
        XCTAssertEqual(cleaned3.artist, "Radiohead")
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
        let playingYTMusic = PlaybackSnapshot(
            title: "Active YT Music Song",
            artist: "YT Artist",
            album: "Album B",
            position: 14.0,
            duration: 195.0,
            artworkURLOrPath: "https://lh3.googleusercontent.com/yt",
            isPlaying: true,
            source: .webMusic(service: .youtubeMusic, browser: .brave),
            isJSBridgeAvailable: true
        )

        let chosen = NowPlayingManager.resolvePreferredSnapshot(
            candidates: [pausedDesktop, playingYTMusic],
            lastActiveSource: .spotifyDesktop
        )

        XCTAssertEqual(chosen?.source, .webMusic(service: .youtubeMusic, browser: .brave))
        XCTAssertEqual(chosen?.title, "Active YT Music Song")
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
