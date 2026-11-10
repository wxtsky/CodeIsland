import XCTest
@testable import CodeIsland

final class SpotifyWebDetectionTests: XCTestCase {

    func testDetectSpotifyWebInBrowsersDefaultSetting() {
        XCTAssertTrue(SettingsDefaults.detectSpotifyWebInBrowsers)
        XCTAssertEqual(SettingsKey.detectSpotifyWebInBrowsers, "detectSpotifyWebInBrowsers")
        _ = SettingsManager.shared
        XCTAssertTrue(UserDefaults.standard.bool(forKey: SettingsKey.detectSpotifyWebInBrowsers))
    }

    func testWebMusicDetectionDefaultIsReadWithoutDependingOnSettingsManager() {
        let suiteName = "codeisland.tests.detectweb"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Key absent: the registered default must apply, not `bool(forKey:)`'s implicit false.
        XCTAssertTrue(NowPlayingManager.isWebMusicDetectionEnabled(defaults: defaults))

        defaults.set(false, forKey: SettingsKey.detectSpotifyWebInBrowsers)
        XCTAssertFalse(NowPlayingManager.isWebMusicDetectionEnabled(defaults: defaults))

        defaults.set(true, forKey: SettingsKey.detectSpotifyWebInBrowsers)
        XCTAssertTrue(NowPlayingManager.isWebMusicDetectionEnabled(defaults: defaults))
    }

    func testProbeJavaScriptIsSafeToEmbedInAppleScriptStringLiteral() {
        // buildBrowserProbeScript interpolates this between double quotes; a stray quote
        // produces an AppleScript syntax error at runtime with no compile-time signal.
        XCTAssertFalse(NowPlayingManager.webMusicDOMProbeJS.contains("\""))
        XCTAssertFalse(NowPlayingManager.webMusicDOMProbeJS.isEmpty)
    }

    private func snapshot(
        _ source: PlaybackSourceKind,
        title: String,
        isPlaying: Bool,
        position: Double = 0,
        duration: Double = 200,
        jsBridge: Bool = true
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            title: title,
            artist: "Artist",
            album: "Album",
            position: position,
            duration: duration,
            artworkURLOrPath: "",
            isPlaying: isPlaying,
            source: source,
            isJSBridgeAvailable: jsBridge
        )
    }

    func testSmartSourcePriorityIsExplicitNotArrayOrder() {
        // The same pair of playing candidates must resolve identically in either order.
        let yt = snapshot(.webMusic(service: .youtubeMusic, browser: .brave), title: "YT Song", isPlaying: true)
        let spotify = snapshot(.webMusic(service: .spotifyWeb, browser: .brave), title: "Spotify Song", isPlaying: true)

        let chosenA = NowPlayingManager.resolvePreferredSnapshot(candidates: [yt, spotify], lastActiveSource: nil)
        let chosenB = NowPlayingManager.resolvePreferredSnapshot(candidates: [spotify, yt], lastActiveSource: nil)

        XCTAssertEqual(chosenA?.source, .webMusic(service: .spotifyWeb, browser: .brave))
        XCTAssertEqual(chosenB?.source, .webMusic(service: .spotifyWeb, browser: .brave))
        XCTAssertEqual(chosenA?.title, "Spotify Song")
        XCTAssertEqual(chosenB?.title, "Spotify Song")
    }

    func testSmartSourcePriorityPrefersDesktopAppOverPlayingWeb() {
        let web = snapshot(.webMusic(service: .youtubeMusic, browser: .brave), title: "Web Song", isPlaying: true)
        let desktop = snapshot(.spotifyDesktop, title: "Desktop Song", isPlaying: true)

        let chosen = NowPlayingManager.resolvePreferredSnapshot(candidates: [web, desktop], lastActiveSource: nil)

        XCTAssertEqual(chosen?.source, .spotifyDesktop)
        XCTAssertEqual(chosen?.title, "Desktop Song")
    }

    func testSmartSourcePriorityRanksWebServicesWhenAllPaused() {
        let apple = snapshot(.webMusic(service: .appleMusicWeb, browser: .safari), title: "Apple Song", isPlaying: false)
        let yt = snapshot(.webMusic(service: .youtubeMusic, browser: .safari), title: "YT Song", isPlaying: false)

        let chosen = NowPlayingManager.resolvePreferredSnapshot(candidates: [apple, yt], lastActiveSource: nil)

        XCTAssertEqual(chosen?.source, .webMusic(service: .youtubeMusic, browser: .safari))
    }

    @MainActor
    func testTitleOnlySnapshotDoesNotFabricatePlaybackProgress() throws {
        let manager = NowPlayingManager()
        let titleOnly = snapshot(
            .webMusic(service: .spotifyWeb, browser: .brave),
            title: "No JS Song",
            isPlaying: true,
            jsBridge: false
        )

        manager.applySnapshot(titleOnly)

        XCTAssertTrue(manager.isPlaying)
        XCTAssertTrue(manager.isBrowserJSHintVisible)
        XCTAssertEqual(manager.playerPosition, 0, accuracy: 0.001)

        // A Tier 1 snapshot starts the 0.5s interpolation timer; a title-only one must not,
        // otherwise the HUD reports a position it never observed.
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(manager.playerPosition, 0, accuracy: 0.001)
    }

    @MainActor
    func testTitleOnlySnapshotKeepsObservedPositionWhenTrackUnchanged() {
        let manager = NowPlayingManager()
        let tier1 = snapshot(
            .webMusic(service: .spotifyWeb, browser: .brave),
            title: "Same Song",
            isPlaying: true,
            position: 42
        )
        manager.applySnapshot(tier1)
        XCTAssertEqual(manager.playerPosition, 42, accuracy: 0.001)

        let tier2 = snapshot(
            .webMusic(service: .spotifyWeb, browser: .brave),
            title: "Same Song",
            isPlaying: true,
            position: 0,
            jsBridge: false
        )
        manager.applySnapshot(tier2)

        // Losing the JS bridge must not rewind a position we already observed.
        XCTAssertEqual(manager.playerPosition, 42, accuracy: 0.001)
    }

    @MainActor
    func testResetToIdleClearsStalePlaybackState() {
        let manager = NowPlayingManager()
        manager.applySnapshot(snapshot(
            .webMusic(service: .spotifyWeb, browser: .brave),
            title: "Stale Song",
            isPlaying: true,
            position: 90
        ))
        XCTAssertEqual(manager.title, "Stale Song")

        manager.resetToIdle()

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.title, "")
        XCTAssertEqual(manager.artist, "")
        XCTAssertEqual(manager.player, "")
        XCTAssertEqual(manager.playerPosition, 0, accuracy: 0.001)
        XCTAssertEqual(manager.trackDuration, 0, accuracy: 0.001)
        XCTAssertNil(manager.activeSource)
        XCTAssertFalse(manager.isBrowserJSHintVisible)
    }

    @MainActor
    func testSeekIsIgnoredWhenTheProbeCannotObservePosition() {
        let manager = NowPlayingManager()
        manager.applySnapshot(snapshot(
            .webMusic(service: .spotifyWeb, browser: .brave),
            title: "No JS Song",
            isPlaying: true,
            position: 0,
            duration: 200,
            jsBridge: false
        ))

        manager.seek(to: 120)

        // The click cannot land without the JS bridge, so the scrubber must not move.
        XCTAssertEqual(manager.playerPosition, 0, accuracy: 0.001)
    }

    @MainActor
    func testSeekMovesTheScrubberWhenTheProbeCanObservePosition() {
        let manager = NowPlayingManager()
        manager.applySnapshot(snapshot(
            .webMusic(service: .spotifyWeb, browser: .brave),
            title: "JS Song",
            isPlaying: true,
            position: 10,
            duration: 200
        ))

        manager.seek(to: 120)

        XCTAssertEqual(manager.playerPosition, 120, accuracy: 0.001)
    }

    func testFetchGateAllowsOnlyOneProbeInFlight() {
        let gate = FetchGate()
        XCTAssertTrue(gate.begin())
        // Polls arriving while a probe runs are dropped rather than queued: a browser stuck on a
        // modal dialog would otherwise pile work up, and stale results would freeze the HUD.
        XCTAssertFalse(gate.begin())
        XCTAssertFalse(gate.begin())

        gate.finish()
        XCTAssertTrue(gate.begin())
    }

    func testProbeLineServiceTagIsReadBeforeParsing() {
        XCTAssertEqual(
            NowPlayingManager.serviceTag(inProbeLine: "DOM|||ytmusic|||Numb|||Linkin Park|||Meteora|||1:00|||3:00||||||playing"),
            .youtubeMusic
        )
        XCTAssertEqual(
            NowPlayingManager.serviceTag(inProbeLine: "FALLBACK|||applemusic|||Veridis Quo • Daft Punk — Apple Music"),
            .appleMusicWeb
        )
        XCTAssertEqual(
            NowPlayingManager.serviceTag(inProbeLine: "FALLBACK|||Blinding Lights • The Weeknd"),
            .spotifyWeb
        )
        XCTAssertNil(NowPlayingManager.serviceTag(inProbeLine: ""))
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

        // The VEVO strip must not depend on how long the artist name is.
        let cleaned4 = NowPlayingManager.sanitizeForLyricsSearch(title: "Waterloo", artist: "ABBA VEVO")
        XCTAssertEqual(cleaned4.artist, "ABBA")
        let cleaned5 = NowPlayingManager.sanitizeForLyricsSearch(title: "Waterloo", artist: "ABBAVEVO")
        XCTAssertEqual(cleaned5.artist, "ABBA")

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
