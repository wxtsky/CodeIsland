# Specification: Spotify Web Browser Detection & Smart Playback Priority

**Status:** `ready-for-agent`  
**Branch:** `feat/#3-spotify-web-browser-detection`

---

## Problem Statement

Users who listen to music via Spotify Web Player (`open.spotify.com`) inside macOS web browsers (Safari, Brave Browser, Google Chrome, Arc, or Microsoft Edge) instead of installing the standalone Spotify desktop client receive no music integration in CodeIsland. When playing tracks in a browser tab:

1. The Notch Music HUD remains idle (`No track` / `Idle`), and the sub-notch floating synced lyrics bar never appears.
2. Users cannot see album artwork, track progress, or real-time synced lyrics while coding with Spotify Web open in a background browser tab.
3. Users cannot control playback (Play/Pause, Next, Previous, or interactive scrubber seek) from the Notch HUD for browser-hosted Spotify sessions.
4. Additionally, when multiple media apps are open simultaneously (for example, Spotify Desktop is open in the background but paused while Apple Music or Spotify Web is actively playing), the existing static check order always locks onto the first running application (`Spotify Desktop`) even if it is paused, masking the player that is actually playing music.

---

## Solution

Extend CodeIsland's Now Playing engine and Music HUD with a **Multi-Browser Spotify Web Bridge** and **Smart Active-Source Priority**:

1. **Multi-Browser Detection (`open.spotify.com`)**: Automatically detect and synchronize with Spotify Web Player tabs across **Safari**, **Brave Browser**, **Google Chrome**, **Arc**, and **Microsoft Edge**.
2. **Hybrid 2-Tier Browser Extraction**:
   - **Tier 1 (Full DOM Sync)**: When browser JavaScript execution via Apple Events is permitted, extract complete playback telemetry directly from the Spotify Web DOM (`title`, `artist`, `album`, `artworkURL`, `playerPosition`, `trackDuration`, and `isPlaying`) and enable full remote playback control (Play/Pause, Next, Previous, and interactive scrubber seeking).
   - **Tier 2 (Tab Title Fallback + Inline Guidance)**: When a running browser has an active `open.spotify.com` tab but *"Allow JavaScript from Apple Events"* is not yet enabled in that browser, gracefully fall back to parsing the browser tab title for track and artist metadata, estimate progress for lyrics, and surface a concise one-line setup hint explaining how to enable full DOM sync in that browser.
3. **Smart Active-Source Priority**: Replace the rigid static source check with an active-first priority resolver. Any source currently in the `Playing` state takes precedence (`Spotify Desktop` > `Apple Music` > `Spotify Web Browser`). When all sources are paused, CodeIsland retains the most recently active source rather than overwriting it with an unrelated idle player.
4. **Adaptive Lightweight Polling**: Poll running browsers every `3.0 seconds` while idle (only when browser detection is enabled and at least one supported browser process is running), and automatically transition to the `1.5 second` sync cadence during active playback.
5. **HUD Source Identity, Click-to-Focus & Settings Control**:
   - Display a specific source badge in the Music HUD (e.g., `SPOTIFY · BRAVE`, `SPOTIFY · SAFARI`, `SPOTIFY · CHROME`, `SPOTIFY · ARC`, `SPOTIFY · EDGE`).
   - Allow clicking the album artwork or source badge in the Music HUD to focus the active media player application or bring the corresponding browser tab to the foreground.
   - Provide a **"Detect Spotify Web in Browsers"** toggle (enabled by default) under the **Music & Synced Lyrics** section in Settings.

---

## User Stories

1. As a developer listening to Spotify Web in Brave Browser, I want CodeIsland to automatically detect the currently playing song and artist, so that I can see track info and floating synced lyrics below my MacBook notch without installing the Spotify desktop app.
2. As a developer listening to Spotify Web in Safari, I want CodeIsland to read the current playback timestamp and duration from the web player, so that my floating lyrics and Notch HUD lyrics stay accurately synchronized with the song.
3. As a developer listening to Spotify Web in Google Chrome, Arc, or Microsoft Edge, I want the same automatic detection and lyric synchronization, so that my choice of macOS browser is seamlessly supported.
4. As a user viewing the Music HUD, I want to see a clear source badge indicating which browser is playing Spotify (such as `SPOTIFY · BRAVE` or `SPOTIFY · SAFARI`), so that I immediately know where the audio is coming from.
5. As a user with Spotify Web playing in a background browser tab, I want to click Play/Pause, Next Track, and Previous Track in the CodeIsland Music HUD, so that I can control playback without leaving my IDE or hunting for the browser tab.
6. As a user with Spotify Web playing in a browser, I want to drag or click the interactive scrubber bar in the CodeIsland Music HUD to seek to a specific timestamp in the song, so that both the web player audio and the synced lyrics jump to that exact position.
7. As a user with Spotify Web playing in a browser, I want the song's album cover artwork to appear in the collapsed notch wing, the mini peek toast banner, and the expanded Music HUD, so that the visual experience matches native desktop players.
8. As a user who has not yet enabled *"Allow JavaScript from Apple Events"* in my browser, I want CodeIsland to still detect the playing song title and artist from the browser tab title, so that basic track recognition and lyrics lookup work out of the box.
9. As a user in Tier 2 fallback mode (where browser JavaScript Apple Events are disabled), I want to see a subtle, non-intrusive hint showing the exact browser menu path to enable JavaScript from Apple Events, so that I know how to unlock accurate timestamp scrubbing and playback controls.
10. As a user who has Spotify Desktop open and paused in the background while actively playing music in Spotify Web (or Apple Music), I want CodeIsland to prioritize the player that is actively playing, so that the HUD and floating lyrics reflect what I am actually hearing.
11. As a user who pauses a song in Spotify Web while another paused player is open in the background, I want CodeIsland to keep displaying the song I just paused rather than unexpectedly switching to a different idle app, so that I can resume my track from the HUD.
12. As a user who clicks on the album artwork or source badge in the Music HUD, I want CodeIsland to activate the corresponding player app or focus the browser window/tab hosting `open.spotify.com`, so that I can quickly jump to the full player interface.
13. As a user who never uses Spotify Web and does not want macOS browser automation permission prompts, I want a **"Detect Spotify Web in Browsers"** toggle in Settings under **Music & Synced Lyrics**, so that I can disable browser probing at any time.
14. As a laptop user working on battery power with no music playing, I want browser detection to skip any browser that is not currently running and use lightweight idle intervals, so that background CPU and energy impact remain negligible.
15. As a user scrubbing or switching tracks in Spotify Web, I want the sub-notch floating lyric line and track change toast to update smoothly and reset position cleanly on track changes, so that lyrics never get stuck at the end of the previous track.

---

## Implementation Decisions

1. **Supported Browser Catalog & Identifier Contract**
   - Define a value type representing supported browsers in priority order:
     - **Safari** (`com.apple.Safari`, badge `SPOTIFY · SAFARI`, scripting family: WebKit `do JavaScript`)
     - **Brave Browser** (`com.brave.Browser`, badge `SPOTIFY · BRAVE`, scripting family: Chromium `execute active tab ... javascript`)
     - **Google Chrome** (`com.google.Chrome`, badge `SPOTIFY · CHROME`, scripting family: Chromium)
     - **Arc** (`company.thebrowser.Browser`, badge `SPOTIFY · ARC`, scripting family: Chromium)
     - **Microsoft Edge** (`com.microsoft.edgemac`, badge `SPOTIFY · EDGE`, scripting family: Chromium)
   - Only browsers whose bundle identifier is currently present in `NSRunningApplication.runningApplications(withBundleIdentifier:)` (and not terminated) are probed.

2. **Playback Source Model & Smart Active-Source Priority**
   - Represent candidate snapshots uniformly across Desktop and Web sources:
     ```swift
     enum PlaybackSourceKind: Equatable, Sendable {
         case spotifyDesktop
         case appleMusic
         case spotifyWeb(browserBundleID: String, browserName: String)
     }

     struct PlaybackSnapshot: Equatable, Sendable {
         let title: String
         let artist: String
         let album: String
         let position: Double
         let duration: Double
         let artworkURLOrPath: String
         let isPlaying: Bool
         let source: PlaybackSourceKind
         let isJSBridgeAvailable: Bool
     }
     ```
   - **Selection Rule (`resolvePreferredSnapshot`)**:
     1. Among all candidate snapshots with non-empty `title`, if one or more candidates have `isPlaying == true`, select the highest-priority playing candidate (`spotifyDesktop` > `appleMusic` > `spotifyWeb`).
     2. If no candidate is currently playing, prefer the candidate matching the previously active `PlaybackSourceKind` (sticky last-active player).
     3. Otherwise, select the first non-empty candidate in priority order.

3. **Hybrid 2-Tier Browser Extraction Contract**
   - In a single AppleScript pass per running browser, locate the first tab whose URL contains `open.spotify.com`.
   - **Tier 1 (DOM JavaScript Telemetry)**:
     - Attempt to execute a compact, self-contained JavaScript snippet on the matched `open.spotify.com` tab that reads:
       - Track name from `[data-testid="context-item-info-title"]` or `navigator.mediaSession.metadata.title`
       - Artist name from `[data-testid="context-item-info-subtitles"]` or `navigator.mediaSession.metadata.artist`
       - Album name from `navigator.mediaSession.metadata.album`
       - Artwork URL from `navigator.mediaSession.metadata.artwork` or `[data-testid="cover-art-image"]`
       - Playback position and duration (in seconds) from `[data-testid="playback-position"]` and `[data-testid="playback-duration"]` or `[data-testid="playback-progressbar"]`
       - Playing state from `navigator.mediaSession.playbackState === "playing"` or the play/pause button `aria-label` / `data-testid="control-button-playpause"`
     - Returns `isJSBridgeAvailable = true`.
   - **Tier 2 (Tab Title Fallback)**:
     - If JavaScript execution throws an AppleScript error (because *"Allow JavaScript from Apple Events"* is off in that browser), catch the error inside the AppleScript block and return the tab's title string with a `FALLBACK` marker (`isJSBridgeAvailable = false`).
     - Parse Spotify Web tab titles:
       - When playing, Spotify Web formats the tab title as `"<Track> • <Artist>"` (bullet `•` or middle dot `·`).
       - When paused or idle on the landing page, Spotify Web sets the tab title to `"Spotify – Web Player..."` or `"Spotify"`. If the title matches the generic idle header while a previous track was loaded from the same browser source, preserve the last known track title/artist in a paused state.

4. **Browser Playback Controls & Seeking**
   - When the active source is `.spotifyWeb`:
     - `togglePlayPause()` clicks `[data-testid="control-button-playpause"]` in the matched `open.spotify.com` tab (or falls back to media session / space key dispatch).
     - `nextTrack()` clicks `[data-testid="control-button-skip-forward"]`.
     - `previousTrack()` clicks `[data-testid="control-button-skip-back"]`.
     - `seek(to:)` seeks the Spotify Web progress range input (`[data-testid="playback-progressbar"] input[type="range"]`) or video/audio media element to the target timestamp.
   - Expose `activateCurrentPlayer()` on `NowPlayingManager` so clicking the HUD header/artwork brings `Spotify.app`, `Music.app`, or the specific browser window and `open.spotify.com` tab to the front.

5. **Adaptive Idle & Active Polling**
   - Maintain an idle discovery timer (`3.0 seconds`) that runs when no track is actively playing. If `detectSpotifyWebInBrowsers` is disabled and neither Desktop Spotify nor Apple Music is running, no AppleScript is executed.
   - When any source is actively playing (`isPlaying == true`), the `0.5s` progress interpolation timer and `1.5s` sync poll keep playback position, seeks, and lyrics synchronized.

6. **Settings & HUD Presentation**
   - Add `detectSpotifyWebInBrowsers` (`Bool`, default `true`) to `SettingsKey`, `SettingsDefaults`, and `SettingsManager`.
   - Add the **"Detect Spotify Web in Browsers"** toggle (and a brief helper note about browser JS permissions when applicable) to the **Music & Synced Lyrics** section in Settings.
   - Update `CyberMusicHUDView` to display `nowPlaying.sourceDisplayLabel` (e.g. `SPOTIFY · BRAVE`), allow clicking the track header / artwork to focus the active player or browser tab, and show a subtle inline tooltip/banner if a browser tab is detected in Tier 2 fallback mode (`JS off`).

---

## Testing Decisions

1. **Primary Testing Seam**
   - We test through `NowPlayingManager`'s parsing, source-priority resolution, and browser script response handling using injectable script/snapshot evaluation rather than launching real browser processes during unit tests.
   - Good tests assert **external observable behavior** on `NowPlayingManager` (`title`, `artist`, `player`, `isPlaying`, `playerPosition`, `trackDuration`, `isBrowserJSHintVisible`) and pure decision outputs given combinations of Desktop and Web player states.

2. **Modules Under Test**
   - `NowPlayingManager` (source priority resolution across Desktop Spotify, Apple Music, and Browser Spotify Web; Tier 1 DOM payload parsing; Tier 2 tab-title fallback parsing; paused state retention; time string parsing `m:ss` / `h:mm:ss`).
   - `Settings` / `SettingsManager` (registration and default value of `detectSpotifyWebInBrowsers`).

3. **Prior Art in the Codebase**
   - `FloatingLyricPresetTests` for music setting model invariants and defaults verification.
   - `AppleScriptRunnerTests` for out-of-process script evaluation boundaries and test isolation without triggering macOS system automation dialogs during `swift test`.

---

## Out of Scope

- Non-Spotify web media players (such as YouTube Music, SoundCloud, Bandcamp, or general HTML5 video tabs).
- Firefox support via AppleScript (Firefox on macOS does not expose a standard AppleScript tab/JavaScript dictionary without a custom browser WebExtension).
- Private `MediaRemote.framework` entitlement workarounds broken on macOS 15.4+.

---

## Further Notes

- In Chromium-based browsers (Brave, Chrome, Arc, Edge), users enable full Tier 1 DOM sync via menu bar: **View → Developer → Allow JavaScript from Apple Events**.
- In Safari, users enable full Tier 1 DOM sync via menu bar: **Develop → Allow JavaScript from Smart Search Field** (or **Allow JavaScript from Apple Events**).
