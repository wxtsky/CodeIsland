# Specification: Multi-Browser Web Music Detection (Spotify, YouTube Music, Apple Music) & Smart Playback Priority

**Status:** `ready-for-agent`  
**Branch:** `feat/#3-spotify-web-browser-detection`

---

## Problem Statement

Users who listen to music via web players (**Spotify Web** at `open.spotify.com`, **YouTube Music** at `music.youtube.com`, or **Apple Music Web** at `music.apple.com`) inside macOS browsers (Safari, Brave Browser, Google Chrome, Arc, or Microsoft Edge) instead of standalone desktop apps receive no music integration in CodeIsland:

1. The Notch Music HUD remains idle (`No track` / `Idle`), and the sub-notch floating synced lyrics bar never appears for web-based music sessions.
2. Users cannot see album artwork, track progress, or real-time synced lyrics while coding with Spotify Web, YouTube Music, or Apple Music Web open in a background browser tab.
3. Users cannot control playback (Play/Pause, Next, Previous, or interactive scrubber seek) from the Notch HUD for browser-hosted music sessions.
4. YouTube Music track titles and artist names frequently include video metadata noise (such as `(Official Music Video)`, `(Official Audio)`, `[Lyrics]`, or `- Topic` channel suffixes) that cause exact-match lyric lookups against `lrclib.net` to fail.
5. When multiple media apps or tabs are open simultaneously (for example, Spotify Desktop is open in the background but paused while Apple Music, YouTube Music Web, or Spotify Web is actively playing), a static check order locks onto the first running application even if it is paused, masking the player that is actually playing music.

---

## Solution

Extend CodeIsland's Now Playing engine and Music HUD with a **Multi-Browser Web Music Bridge** (supporting Spotify Web, YouTube Music Web, and Apple Music Web), **Smart Track Metadata Sanitization for Lyrics**, and **Smart Active-Source Priority**:

1. **Multi-Service & Multi-Browser Detection**:
   - Automatically detect and synchronize with **Spotify Web** (`open.spotify.com`), **YouTube Music Web** (`music.youtube.com`), and **Apple Music Web** (`music.apple.com`) across **Safari**, **Brave Browser**, **Google Chrome**, **Arc**, and **Microsoft Edge** in a single unified pass per running browser.
   - Continue supporting native **Spotify Desktop** (`com.spotify.client`) and **Apple Music Desktop** (`com.apple.Music`).
2. **Hybrid 2-Tier Browser Extraction**:
   - **Tier 1 (Full DOM / Media Element Sync)**: When browser JavaScript execution via Apple Events is permitted, extract complete playback telemetry directly from the web player (`title`, `artist`, `album`, `artworkURL`, `playerPosition`, `trackDuration`, and `isPlaying`) via service-specific DOM/MediaSession/HTML5 `<video>`/`<audio>`/MusicKit bridges, and enable full remote playback control (Play/Pause, Next, Previous, and interactive scrubber seeking).
   - **Tier 2 (Tab Title Fallback + Inline Guidance)**: When a running browser has an active music tab but *"Allow JavaScript from Apple Events"* is not yet enabled, gracefully fall back to parsing the browser tab title, retain track state when paused, and display a concise setup hint explaining how to enable full DOM sync.
3. **Smart Track Metadata Sanitizer for Synced Lyrics**:
   - Clean noisy video suffixes (`(Official Music Video)`, `(Official Audio)`, `[Lyrics]`, `(Visualizer)`, etc.) from track titles and strip YouTube auto-generated `- Topic` / `VEVO` suffixes from artist names before querying `lrclib.net`.
4. **Smart Active-Source Priority**:
   - Prioritize any source currently in the `Playing` state (`Spotify Desktop` > `Apple Music Desktop` > `Spotify Web` > `YouTube Music Web` > `Apple Music Web`). When all sources are paused, retain the most recently active source (`lastActiveSource`).
5. **HUD Source Identity, Click-to-Focus & Settings Control**:
   - Display a specific source badge in the Music HUD (`SPOTIFY · BRAVE`, `YT MUSIC · BRAVE`, `APPLE MUSIC · SAFARI`, `SPOTIFY`, `MUSIC`, etc.).
   - Allow clicking the album artwork or source badge in the Music HUD to focus the active desktop app or bring the corresponding browser window and music tab to the foreground.
   - Provide a unified **"Detect Web Music Players in Browsers"** toggle (enabled by default) under **Music & Synced Lyrics** in Settings.

---

## User Stories

1. As a developer listening to Spotify Web, YouTube Music, or Apple Music Web in Brave, Safari, Chrome, Arc, or Edge, I want CodeIsland to automatically detect the currently playing song and artist, so that I can see track info and floating synced lyrics below my MacBook notch.
2. As a YouTube Music listener, I want CodeIsland to read exact sub-second timestamps from the HTML5 video stream and clean video suffixes like `(Official Audio)` or `- Topic` when fetching lyrics, so that `lrclib.net` returns accurate synced lyrics.
3. As an Apple Music user on macOS, I want seamless support whether I play songs through the native macOS `Music.app` or through `music.apple.com` in my browser, so that both workflows are supported.
4. As a user viewing the Music HUD, I want to see a clear source badge indicating both the service and browser (such as `SPOTIFY · BRAVE`, `YT MUSIC · CHROME`, or `APPLE MUSIC · SAFARI`), so that I immediately know where the audio is coming from.
5. As a user with a web music player running in a background browser tab, I want to click Play/Pause, Next Track, and Previous Track in the CodeIsland Music HUD, so that I can control playback without leaving my IDE.
6. As a user with Spotify Web, YouTube Music, or Apple Music Web playing in a browser, I want to drag or click the interactive scrubber bar in the CodeIsland Music HUD to seek to a specific timestamp in the song, so that both the web player audio and the synced lyrics jump to that exact position.
7. As a user with a web music player open, I want the song's album cover artwork to appear in the collapsed notch wing, the mini peek toast banner, and the expanded Music HUD.
8. As a user who has not yet enabled *"Allow JavaScript from Apple Events"* in my browser, I want CodeIsland to still detect the playing song from the browser tab title and show a non-intrusive tooltip explaining how to enable full JavaScript sync.
9. As a user who has multiple music players or tabs open simultaneously (e.g., Spotify Desktop paused while YouTube Music Web is playing), I want CodeIsland to prioritize the source that is actively playing.
10. As a user who pauses a song in a web player while another paused player is open in the background, I want CodeIsland to keep displaying the song I just paused rather than switching to a different idle app.
11. As a user who clicks on the album artwork or source badge in the Music HUD, I want CodeIsland to activate the corresponding desktop app or focus the exact browser window and tab hosting the active web music player.
12. As a user who wants control over browser probing, I want a **"Detect Web Music Players in Browsers"** toggle in Settings under **Music & Synced Lyrics**.

---

## Implementation Decisions

1. **Web Music Services & Supported Browser Catalog**
   - Define `WebMusicService` in priority order:
     - `.spotifyWeb` (`open.spotify.com`, badge prefix `SPOTIFY`)
     - `.youtubeMusic` (`music.youtube.com`, badge prefix `YT MUSIC`)
     - `.appleMusicWeb` (`music.apple.com`, badge prefix `APPLE MUSIC`)
   - Define `SpotifyWebBrowser` in priority order:
     - `.safari` (`com.apple.Safari`), `.brave` (`com.brave.Browser`), `.chrome` (`com.google.Chrome`), `.arc` (`company.thebrowser.Browser`), `.edge` (`com.microsoft.edgemac`).
   - Represent playback sources via `PlaybackSourceKind`:
     ```swift
     enum PlaybackSourceKind: Equatable, Sendable {
         case spotifyDesktop
         case appleMusic
         case webMusic(service: WebMusicService, browser: SpotifyWebBrowser)
     }
     ```

2. **Unified Single-Pass Browser Probe & Service-Specific DOM Extraction**
   - In a single AppleScript execution per running browser, inspect tabs matching `open.spotify.com`, `music.youtube.com`, or `music.apple.com`:
     - **Spotify Web (`open.spotify.com`)**: Reads `[data-testid="context-item-info-title"]`, `[data-testid="context-item-info-subtitles"]`, `navigator.mediaSession.metadata`, `[data-testid="playback-position"]`, `[data-testid="playback-duration"]`, and `[data-testid="control-button-playpause"]`.
     - **YouTube Music (`music.youtube.com`)**: Reads `document.querySelector('video')` for exact `currentTime`, `duration`, and `!paused`; reads track/artist/album/artwork from `navigator.mediaSession.metadata` and `<ytmusic-player-bar>` (`.title.ytmusic-player-bar`, `.byline.ytmusic-player-bar`).
     - **Apple Music Web (`music.apple.com`)**: Reads `MusicKit.getInstance()` and/or `document.querySelector('audio')` + `navigator.mediaSession.metadata` for title, artist, album, artwork, playback time, duration, and playing state.
   - If JavaScript execution is disabled in the browser, catch the error in AppleScript and emit `FALLBACK|||<service>|||<tabTitle>`.

3. **Lyrics Query Sanitization (`sanitizeForLyricsSearch`)**
   - Provide a pure function `NowPlayingManager.sanitizeForLyricsSearch(title:artist:) -> (title: String, artist: String)` that strips common video suffixes (`(Official Music Video)`, `(Official Video)`, `(Official Audio)`, `(Lyrics)`, `(Lyric Video)`, `(Visualizer)`, `[Official Video]`, `[Lyrics]`, etc.) and artist suffixes (`- Topic`, `VEVO`) before querying `lrclib.net`.

4. **Service-Specific Playback Controls & Seeking**
   - Route `togglePlayPause()`, `nextTrack()`, `previousTrack()`, `seek(to:)`, and `activateCurrentPlayer()` according to the active `WebMusicService`:
     - **Spotify Web**: clicks `[data-testid="control-button-*"]` and dispatches mouse seek events on `[data-testid="playback-progressbar"]`.
     - **YouTube Music**: clicks `#play-pause-button`, `.next-button`, `.previous-button`, and seeks directly via `document.querySelector('video').currentTime = position`.
     - **Apple Music Web**: invokes `MusicKit.getInstance()` playback/seek methods with fallback to `<audio>` element and playback control buttons.

---

## Testing Decisions

1. **Primary Testing Seam**
   - Test external behavior and pure parsing/priority/sanitization contracts on `NowPlayingManager` without launching real browsers or triggering macOS automation dialogs during `swift test`.
2. **Modules Under Test**
   - `NowPlayingManager`:
     - Tier 1 DOM output parsing for Spotify Web, YouTube Music Web, and Apple Music Web.
     - Tier 2 fallback tab-title parsing across services and paused-track retention.
     - Multi-source priority resolution (`resolvePreferredSnapshot`) across Desktop and Web sources.
     - Lyrics metadata sanitization (`sanitizeForLyricsSearch`) for noisy YouTube Music titles and `- Topic` artists.
   - `Settings` / `SettingsManager`: default registration of `detectSpotifyWebInBrowsers`.

---

## Out of Scope

- Non-music general video tabs (such as regular `youtube.com/watch` non-music videos or Twitch streams).
- Firefox AppleScript integration (Firefox lacks a standard macOS AppleScript tab/JS dictionary).

---

## Further Notes

- In Chromium browsers (Brave, Chrome, Arc, Edge), enable Tier 1 DOM sync via: **View → Developer → Allow JavaScript from Apple Events**.
- In Safari, enable Tier 1 DOM sync via: **Develop → Allow JavaScript from Apple Events**.
