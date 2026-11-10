import Foundation
import Combine
import AppKit
import SwiftUI
import ApplicationServices

// MARK: - Synced Lyric Model

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Double
    let text: String
}

// MARK: - Supported Web Browsers & Playback Source Models

enum SpotifyWebBrowser: String, CaseIterable, Equatable, Sendable {
    case safari = "com.apple.Safari"
    case brave = "com.brave.Browser"
    case chrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"
    case edge = "com.microsoft.edgemac"

    var bundleIdentifier: String { rawValue }

    var applicationName: String {
        switch self {
        case .safari: return "Safari"
        case .brave: return "Brave Browser"
        case .chrome: return "Google Chrome"
        case .arc: return "Arc"
        case .edge: return "Microsoft Edge"
        }
    }

    var shortBadge: String {
        switch self {
        case .safari: return "SPOTIFY · SAFARI"
        case .brave: return "SPOTIFY · BRAVE"
        case .chrome: return "SPOTIFY · CHROME"
        case .arc: return "SPOTIFY · ARC"
        case .edge: return "SPOTIFY · EDGE"
        }
    }

    var isSafari: Bool {
        self == .safari
    }

    var jsPermissionHint: String {
        switch self {
        case .safari:
            return "Enable Safari → Develop → Allow JavaScript from Apple Events for full sync & controls"
        case .brave:
            return "Enable Brave → View → Developer → Allow JavaScript from Apple Events for full sync & controls"
        case .chrome:
            return "Enable Chrome → View → Developer → Allow JavaScript from Apple Events for full sync & controls"
        case .arc:
            return "Enable Arc → View → Developer → Allow JavaScript from Apple Events for full sync & controls"
        case .edge:
            return "Enable Edge → View → Developer → Allow JavaScript from Apple Events for full sync & controls"
        }
    }
}

enum PlaybackSourceKind: Equatable, Sendable {
    case spotifyDesktop
    case appleMusic
    case spotifyWeb(SpotifyWebBrowser)

    var displayBadge: String {
        switch self {
        case .spotifyDesktop:
            return "Spotify"
        case .appleMusic:
            return "Music"
        case .spotifyWeb(let browser):
            return browser.shortBadge
        }
    }
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

/// Observes currently playing tracks from Apple Music, Spotify Desktop, and Spotify Web in macOS browsers.
/// Event-driven for native apps with adaptive lightweight polling for web browsers.
@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var isPlaying: Bool = false
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var player: String = "" // "Spotify", "Music", or "SPOTIFY · BRAVE", etc.
    @Published var artworkURL: String = ""
    @Published var artworkImage: NSImage?
    @Published var playerPosition: Double = 0
    @Published var trackDuration: Double = 0
    @Published var showToast: Bool = false
    @Published var lyrics: [LyricLine] = []
    @Published var currentLyricIndex: Int = 0
    @Published var lyricsLoading: Bool = false
    @Published var activeSource: PlaybackSourceKind?
    @Published var isBrowserJSHintVisible: Bool = false
    @Published var browserJSHintText: String = ""

    private var toastDismissTimer: Timer?
    private var progressTimer: Timer?
    private var idleDiscoveryTimer: Timer?
    private var lastFetchedLyricsKey: String = ""
    private var lastBrowserSnapshots: [SpotifyWebBrowser: PlaybackSnapshot] = [:]

    init() {
        setupObservers()
        guard !RuntimeEnvironment.isRunningTests else { return }
        requestAutomationPermissionIfNeeded()
        fetchPlaybackDetails()
        startIdleDiscoveryTimer()
    }

    func requestAutomationPermissionIfNeeded() {
        guard !RuntimeEnvironment.isRunningTests else { return }
        let targets = ["com.spotify.client", "com.apple.Music"]
        for target in targets {
            let desc = NSAppleEventDescriptor(bundleIdentifier: target)
            if let aeDescPtr = desc.aeDesc {
                var addressDesc = aeDescPtr.pointee
                _ = AEDeterminePermissionToAutomateTarget(&addressDesc, typeWildCard, typeWildCard, true)
                AEDisposeDesc(&addressDesc)
            }
        }
    }

    private func setupObservers() {
        let center = DistributedNotificationCenter.default()

        // Apple Music observer
        center.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAppleMusicNotification(notification)
            }
        }

        // Spotify observer
        center.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleSpotifyNotification(notification)
            }
        }
    }

    private func extractDouble(from dict: [AnyHashable: Any], keys: [String]) -> Double? {
        for key in keys {
            if let val = dict[key] {
                if let num = val as? NSNumber {
                    return num.doubleValue
                } else if let d = val as? Double {
                    return d
                } else if let i = val as? Int {
                    return Double(i)
                } else if let s = val as? String, let parsed = Double(s) {
                    return parsed
                }
            }
        }
        return nil
    }

    private func handleAppleMusicNotification(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let state = info["Player State"] as? String ?? ""
        let playing = (state == "Playing")

        let trackTitle = info["Name"] as? String ?? ""
        let trackArtist = info["Artist"] as? String ?? ""
        let trackAlbum = info["Album"] as? String ?? ""

        var rawDuration = extractDouble(from: info, keys: ["Total Time", "Duration"]) ?? 0
        if rawDuration > 1000 {
            rawDuration /= 1000.0
        }

        let rawPos = extractDouble(from: info, keys: ["Player Position", "Position"]) ?? 0

        if playing || activeSource == .appleMusic || activeSource == nil {
            activeSource = .appleMusic
            isBrowserJSHintVisible = false
            browserJSHintText = ""
            updateBasicInfo(
                playing: playing,
                title: trackTitle,
                artist: trackArtist,
                album: trackAlbum,
                source: PlaybackSourceKind.appleMusic.displayBadge,
                position: rawPos,
                duration: rawDuration > 0 ? rawDuration : nil
            )
        }
        fetchPlaybackDetails()
    }

    private func handleSpotifyNotification(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let state = info["Player State"] as? String ?? ""
        let playing = (state == "Playing")

        let trackTitle = info["Name"] as? String ?? ""
        let trackArtist = info["Artist"] as? String ?? ""
        let trackAlbum = info["Album"] as? String ?? ""

        var rawDuration = extractDouble(from: info, keys: ["Duration", "duration", "Total Time"]) ?? 0
        if rawDuration > 1000 {
            rawDuration /= 1000.0
        }

        var rawPos = extractDouble(from: info, keys: ["Playback Position", "Position", "position", "Player Position"]) ?? 0
        if rawPos > 1000 && rawDuration > 0 && rawPos > rawDuration {
            rawPos /= 1000.0
        }

        if playing || activeSource == .spotifyDesktop || activeSource == nil {
            activeSource = .spotifyDesktop
            isBrowserJSHintVisible = false
            browserJSHintText = ""
            updateBasicInfo(
                playing: playing,
                title: trackTitle,
                artist: trackArtist,
                album: trackAlbum,
                source: PlaybackSourceKind.spotifyDesktop.displayBadge,
                position: rawPos,
                duration: rawDuration > 0 ? rawDuration : nil
            )
        }
        fetchPlaybackDetails()
    }

    private func updateBasicInfo(
        playing: Bool,
        title: String,
        artist: String,
        album: String,
        source: String,
        position: Double? = nil,
        duration: Double? = nil
    ) {
        let trackChanged = (self.title != title || self.artist != artist) && !title.isEmpty
        self.isPlaying = playing
        self.title = title
        self.artist = artist
        self.album = album
        self.player = source

        if let duration = duration, duration > 0 {
            self.trackDuration = duration
        }

        if trackChanged {
            self.playerPosition = position ?? 0.0
            self.currentLyricIndex = 0
            self.lyrics = []
            triggerToast()
            fetchLyrics(title: title, artist: artist)
        } else if let position = position {
            self.playerPosition = position
            self.updateCurrentLyricIndex()
        }

        // Clamp: position can never exceed duration
        if self.trackDuration > 0 && self.playerPosition > self.trackDuration {
            self.playerPosition = 0.0
            self.updateCurrentLyricIndex()
        }

        if playing {
            startProgressTimer()
        } else {
            stopProgressTimer()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                showToast = false
            }
            toastDismissTimer?.invalidate()
        }
    }

    func triggerToast() {
        toastDismissTimer?.invalidate()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            showToast = true
        }
        toastDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    self?.showToast = false
                }
            }
        }
    }

    // MARK: - Playback Progress & Adaptive Polling

    private func startIdleDiscoveryTimer() {
        idleDiscoveryTimer?.invalidate()
        idleDiscoveryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, !self.isPlaying else { return }
                self.fetchPlaybackDetails()
            }
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        var tickCount = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isPlaying else { return }
                tickCount += 1

                if self.trackDuration > 0 {
                    if self.playerPosition < self.trackDuration {
                        self.playerPosition = min(self.trackDuration, self.playerPosition + 0.5)
                    }
                } else {
                    self.playerPosition += 0.5
                }
                self.updateCurrentLyricIndex()

                // Every 3 ticks (1.5 seconds), poll AppleScript to detect seeks and sync position
                if tickCount % 3 == 0 {
                    self.fetchPlaybackDetails()
                }
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    var currentLyricText: String {
        guard !lyrics.isEmpty else { return "" }
        if let line = lyrics.first(where: { $0.id == currentLyricIndex }) {
            return line.text
        }
        if currentLyricIndex >= 0 && currentLyricIndex < lyrics.count {
            return lyrics[currentLyricIndex].text
        }
        return ""
    }

    private func updateCurrentLyricIndex() {
        guard !lyrics.isEmpty else { return }
        let offset = UserDefaults.standard.double(forKey: SettingsKey.lyricSyncOffset)
        let effectiveTime = max(0, playerPosition + offset)
        if let idx = lyrics.lastIndex(where: { $0.timestamp <= effectiveTime }) {
            let targetId = lyrics[idx].id
            if self.currentLyricIndex != targetId {
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.currentLyricIndex = targetId
                }
            }
        } else {
            let firstId = lyrics.first?.id ?? 0
            if self.currentLyricIndex != firstId {
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.currentLyricIndex = firstId
                }
            }
        }
    }

    // MARK: - Pure Parsing & Priority Helpers

    nonisolated static func parseTimecode(_ raw: String) -> Double? {
        let trimmed = raw.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var sign: Double = 1.0
        var body = trimmed
        if body.hasPrefix("-") || body.hasPrefix("−") {
            sign = -1.0
            body = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        if body.contains(":") {
            let parts = body.components(separatedBy: ":")
            if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                return sign * (m * 60.0 + s)
            } else if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
                return sign * (h * 3600.0 + m * 60.0 + s)
            }
            return nil
        }

        if let val = Double(body) {
            return sign * val
        }
        return nil
    }

    nonisolated static func parseSpotifyTabTitle(_ rawTitle: String) -> (title: String, artist: String)? {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        if lower == "spotify" || lower.hasPrefix("spotify – web player") || lower.hasPrefix("spotify - web player") || lower.hasPrefix("spotify — web player") {
            return nil
        }

        let separators = [" • ", " · "]
        for sep in separators {
            if let range = trimmed.range(of: sep) {
                let track = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                var artistPart = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                for suffix in [" - Spotify", " – Spotify", " | Spotify"] {
                    if artistPart.lowercased().hasSuffix(suffix.lowercased()) {
                        artistPart = String(artistPart.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                if !track.isEmpty {
                    return (track, artistPart)
                }
            }
        }
        return nil
    }

    nonisolated static func parseBrowserScriptOutput(
        _ rawOutput: String,
        browser: SpotifyWebBrowser,
        previousSnapshot: PlaybackSnapshot?
    ) -> PlaybackSnapshot? {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.components(separatedBy: "|||")
        guard let mode = parts.first else { return nil }

        if mode == "DOM", parts.count >= 8 {
            let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let album = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let posRaw = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let durRaw = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let artUrl = parts[6].trimmingCharacters(in: .whitespacesAndNewlines)
            let state = parts[7].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            guard !title.isEmpty else { return nil }

            let pos = max(0.0, parseTimecode(posRaw) ?? 0.0)
            let parsedDur = parseTimecode(durRaw) ?? 0.0
            let duration: Double
            if parsedDur < 0 {
                duration = pos + abs(parsedDur)
            } else {
                duration = parsedDur
            }

            return PlaybackSnapshot(
                title: title,
                artist: artist,
                album: album,
                position: pos,
                duration: duration,
                artworkURLOrPath: artUrl,
                isPlaying: state == "playing",
                source: .spotifyWeb(browser),
                isJSBridgeAvailable: true
            )
        } else if mode == "FALLBACK", parts.count >= 2 {
            let tabTitle = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = parseSpotifyTabTitle(tabTitle) {
                let sameTrack = (previousSnapshot?.title == parsed.title && previousSnapshot?.artist == parsed.artist)
                return PlaybackSnapshot(
                    title: parsed.title,
                    artist: parsed.artist,
                    album: sameTrack ? (previousSnapshot?.album ?? "") : "",
                    position: sameTrack ? (previousSnapshot?.position ?? 0.0) : 0.0,
                    duration: sameTrack ? (previousSnapshot?.duration ?? 0.0) : 0.0,
                    artworkURLOrPath: sameTrack ? (previousSnapshot?.artworkURLOrPath ?? "") : "",
                    isPlaying: true,
                    source: .spotifyWeb(browser),
                    isJSBridgeAvailable: false
                )
            } else if let prev = previousSnapshot, prev.source == .spotifyWeb(browser), !prev.title.isEmpty {
                return PlaybackSnapshot(
                    title: prev.title,
                    artist: prev.artist,
                    album: prev.album,
                    position: prev.position,
                    duration: prev.duration,
                    artworkURLOrPath: prev.artworkURLOrPath,
                    isPlaying: false,
                    source: .spotifyWeb(browser),
                    isJSBridgeAvailable: false
                )
            }
        }
        return nil
    }

    nonisolated static func resolvePreferredSnapshot(
        candidates: [PlaybackSnapshot],
        lastActiveSource: PlaybackSourceKind?
    ) -> PlaybackSnapshot? {
        let valid = candidates.filter { !$0.title.isEmpty }
        guard !valid.isEmpty else { return nil }

        // 1. Any actively playing source wins in priority order
        if let playingCandidate = valid.first(where: { $0.isPlaying }) {
            return playingCandidate
        }

        // 2. When all sources are paused, retain the most recently active source
        if let lastSource = lastActiveSource,
           let stickyCandidate = valid.first(where: { $0.source == lastSource }) {
            return stickyCandidate
        }

        // 3. Fallback to first valid candidate
        return valid.first
    }

    // MARK: - AppleScript Builders

    nonisolated private static let spotifyDOMProbeJS: String =
        "(function(){try{" +
        "var ms=navigator.mediaSession&&navigator.mediaSession.metadata;" +
        "var tEl=document.querySelector('[data-testid=context-item-info-title]');" +
        "var aEl=document.querySelector('[data-testid=context-item-info-subtitles]');" +
        "var title=(tEl&&tEl.textContent?tEl.textContent.trim():'')||(ms&&ms.title?ms.title:'');" +
        "var artist=(aEl&&aEl.textContent?aEl.textContent.trim():'')||(ms&&ms.artist?ms.artist:'');" +
        "var album=(ms&&ms.album?ms.album:'');" +
        "var art='';" +
        "if(ms&&ms.artwork&&ms.artwork.length>0){art=ms.artwork[ms.artwork.length-1].src||'';}" +
        "if(!art){var img=document.querySelector('[data-testid=cover-art-image]');if(img&&img.src){art=img.src;}}" +
        "var posEl=document.querySelector('[data-testid=playback-position]');" +
        "var durEl=document.querySelector('[data-testid=playback-duration]');" +
        "var pos=posEl&&posEl.textContent?posEl.textContent.trim():'0:00';" +
        "var dur=durEl&&durEl.textContent?durEl.textContent.trim():'0:00';" +
        "var btn=document.querySelector('[data-testid=control-button-playpause]');" +
        "var lbl=btn?(btn.getAttribute('aria-label')||''):'';" +
        "var isPlaying=false;" +
        "if(lbl.toLowerCase()==='pause'){isPlaying=true;}" +
        "else if(lbl.toLowerCase()==='play'){isPlaying=false;}" +
        "else if(navigator.mediaSession&&navigator.mediaSession.playbackState==='playing'){isPlaying=true;}" +
        "else if(document.title.indexOf('•')!==-1){isPlaying=true;}" +
        "if(!title&&document.title.indexOf('•')!==-1){" +
        "var parts=document.title.split('•');" +
        "title=parts[0].trim();" +
        "artist=parts.slice(1).join('•').replace(/- Spotify.*$/i,'').trim();" +
        "}" +
        "var pState=isPlaying?'playing':'paused';" +
        "return 'DOM|||'+title+'|||'+artist+'|||'+album+'|||'+pos+'|||'+dur+'|||'+art+'|||'+pState;" +
        "}catch(e){return 'FALLBACK|||'+document.title;}})()"

    nonisolated static func buildBrowserProbeScript(for browser: SpotifyWebBrowser) -> String {
        if browser.isSafari {
            return """
            tell application "\(browser.applicationName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set tabUrl to URL of t
                            if tabUrl contains "open.spotify.com" then
                                set tabTitle to name of t
                                try
                                    set domRes to do JavaScript "\(spotifyDOMProbeJS)" in t
                                    if domRes is not missing value and domRes is not "" then
                                        return domRes
                                    end if
                                end try
                                return "FALLBACK|||" & tabTitle
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
        } else {
            return """
            tell application "\(browser.applicationName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set tabUrl to URL of t
                            if tabUrl contains "open.spotify.com" then
                                set tabTitle to title of t
                                try
                                    set domRes to execute t javascript "\(spotifyDOMProbeJS)"
                                    if domRes is not missing value and domRes is not "" then
                                        return domRes
                                    end if
                                end try
                                return "FALLBACK|||" & tabTitle
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
        }
    }

    nonisolated static func buildBrowserActionScript(for browser: SpotifyWebBrowser, jsExpression: String) -> String {
        if browser.isSafari {
            return """
            tell application "\(browser.applicationName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (URL of t) contains "open.spotify.com" then
                                do JavaScript "\(jsExpression)" in t
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
        } else {
            return """
            tell application "\(browser.applicationName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (URL of t) contains "open.spotify.com" then
                                execute t javascript "\(jsExpression)"
                                return "ok"
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return ""
            """
        }
    }

    // MARK: - Fetching Playback Details

    func fetchPlaybackDetails() {
        guard !RuntimeEnvironment.isRunningTests else { return }
        let detectWeb = UserDefaults.standard.bool(forKey: SettingsKey.detectSpotifyWebInBrowsers)
        let lastSource = self.activeSource
        let previousWebSnapshots = self.lastBrowserSnapshots

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isSpotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").contains { !$0.isTerminated }
            let isMusicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").contains { !$0.isTerminated }
            let runningBrowsers: [SpotifyWebBrowser] = detectWeb
                ? SpotifyWebBrowser.allCases.filter { browser in
                    NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).contains { !$0.isTerminated }
                }
                : []

            guard isSpotifyRunning || isMusicRunning || !runningBrowsers.isEmpty else { return }

            var candidates: [PlaybackSnapshot] = []
            var updatedWebSnapshots = previousWebSnapshots

            // 1. Desktop Spotify
            if isSpotifyRunning {
                let spotifyScript = """
                tell application "Spotify"
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackPos to player position
                    set trackDur to (duration of current track) / 1000
                    try
                        set artUrl to artwork url of current track
                    on error
                        set artUrl to ""
                    end try
                    set pState to player state as string
                    return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackPos & "|||" & trackDur & "|||" & artUrl & "|||" & pState
                end tell
                """
                if let rawOutput = Self.runAppleScript(spotifyScript),
                   let snapshot = Self.parseDesktopOutput(rawOutput, source: .spotifyDesktop) {
                    candidates.append(snapshot)
                }
            }

            // 2. Apple Music
            if isMusicRunning {
                let musicScript = """
                tell application "Music"
                    set trackName to name of current track
                    set trackArtist to artist of current track
                    set trackAlbum to album of current track
                    set trackPos to player position
                    set trackDur to duration of current track
                    set pState to player state as string
                    try
                        if exists (artwork 1 of current track) then
                            set theData to data of artwork 1 of current track
                            set theFile to (open for access POSIX file "/tmp/codeisland_music_art.png" with write permission)
                            set eof theFile to 0
                            write theData to theFile
                            close access theFile
                        end if
                    on error
                        try
                            close access file "/tmp/codeisland_music_art.png"
                        end try
                    end try
                    return trackName & "|||" & trackArtist & "|||" & trackAlbum & "|||" & trackPos & "|||" & trackDur & "|||/tmp/codeisland_music_art.png|||" & pState
                end tell
                """
                if let rawOutput = Self.runAppleScript(musicScript),
                   let snapshot = Self.parseDesktopOutput(rawOutput, source: .appleMusic) {
                    candidates.append(snapshot)
                }
            }

            // 3. Running Web Browsers (open.spotify.com)
            for browser in runningBrowsers {
                let probeScript = Self.buildBrowserProbeScript(for: browser)
                if let rawOutput = Self.runAppleScript(probeScript),
                   let snapshot = Self.parseBrowserScriptOutput(
                       rawOutput,
                       browser: browser,
                       previousSnapshot: previousWebSnapshots[browser]
                   ) {
                    updatedWebSnapshots[browser] = snapshot
                    candidates.append(snapshot)
                }
            }

            guard let chosen = Self.resolvePreferredSnapshot(candidates: candidates, lastActiveSource: lastSource) else {
                return
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.lastBrowserSnapshots = updatedWebSnapshots
                self.applySnapshot(chosen)
            }
        }
    }

    nonisolated private static func parseDesktopOutput(_ rawOutput: String, source: PlaybackSourceKind) -> PlaybackSnapshot? {
        guard !rawOutput.isEmpty else { return nil }
        let parts = rawOutput.components(separatedBy: "|||")
        guard parts.count >= 7 else { return nil }

        let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let posStr = parts[3].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let durStr = parts[4].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
        let artPathOrUrl = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
        let state = parts[6].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let pos = Double(posStr) ?? 0
        let dur = Double(durStr) ?? 0
        let playing = (state == "playing")

        return PlaybackSnapshot(
            title: title,
            artist: artist,
            album: album,
            position: pos,
            duration: dur,
            artworkURLOrPath: artPathOrUrl,
            isPlaying: playing,
            source: source,
            isJSBridgeAvailable: true
        )
    }

    func applySnapshot(_ chosen: PlaybackSnapshot) {
        let trackChanged = (self.title != chosen.title || self.artist != chosen.artist) && !chosen.title.isEmpty

        self.activeSource = chosen.source
        self.player = chosen.source.displayBadge

        if case .spotifyWeb(let browser) = chosen.source, !chosen.isJSBridgeAvailable {
            self.isBrowserJSHintVisible = true
            self.browserJSHintText = browser.jsPermissionHint
        } else {
            self.isBrowserJSHintVisible = false
            self.browserJSHintText = ""
        }

        self.title = chosen.title
        self.artist = chosen.artist
        self.album = chosen.album

        if chosen.duration > 0 {
            self.trackDuration = chosen.duration
        }

        if trackChanged {
            self.playerPosition = max(0.0, chosen.position)
            self.currentLyricIndex = 0
            self.lyrics = []
            if chosen.isPlaying {
                self.triggerToast()
            }
            self.fetchLyrics(title: chosen.title, artist: chosen.artist)
        } else if chosen.isJSBridgeAvailable && chosen.position >= 0 {
            if abs(self.playerPosition - chosen.position) > 0.75 || self.playerPosition == 0 {
                self.playerPosition = chosen.position
                self.updateCurrentLyricIndex()
            }
        }

        if self.trackDuration > 0 && self.playerPosition > self.trackDuration {
            self.playerPosition = 0.0
            self.updateCurrentLyricIndex()
        }

        self.isPlaying = chosen.isPlaying
        if chosen.isPlaying {
            self.startProgressTimer()
        } else {
            self.stopProgressTimer()
        }

        self.updateCurrentLyricIndex()

        // Load artwork if changed
        if self.artworkURL != chosen.artworkURLOrPath {
            self.artworkURL = chosen.artworkURLOrPath
            self.loadArtwork(from: chosen.artworkURLOrPath)
        }

        // Fetch lyrics if not loaded
        if self.lyrics.isEmpty && !chosen.title.isEmpty {
            self.fetchLyrics(title: chosen.title, artist: chosen.artist)
        }
    }

    private func loadArtwork(from pathOrUrl: String) {
        guard !pathOrUrl.isEmpty else {
            self.artworkImage = nil
            return
        }

        if pathOrUrl.hasPrefix("http") {
            guard let url = URL(string: pathOrUrl) else { return }
            URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
                if let data = data, let img = NSImage(data: data) {
                    Task { @MainActor in
                        self?.artworkImage = img
                    }
                }
            }.resume()
        } else if FileManager.default.fileExists(atPath: pathOrUrl) {
            if let img = NSImage(contentsOfFile: pathOrUrl) {
                self.artworkImage = img
            }
        }
    }

    // MARK: - Lyrics Engine

    func fetchLyrics(title: String, artist: String) {
        let key = "\(title):::\(artist)"
        guard key != lastFetchedLyricsKey && !title.isEmpty else { return }
        lastFetchedLyricsKey = key
        lyricsLoading = true

        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let encodedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            lyricsLoading = false
            return
        }

        var primaryUrlString = "https://lrclib.net/api/get?track_name=\(encodedTitle)&artist_name=\(encodedArtist)"
        let shouldIncludeDuration = trackDuration > 0
        if shouldIncludeDuration {
            primaryUrlString += "&duration=\(Int(trackDuration))"
        }

        guard let primaryUrl = URL(string: primaryUrlString) else {
            lyricsLoading = false
            return
        }

        let fallbackUrl = URL(string: "https://lrclib.net/api/get?track_name=\(encodedTitle)&artist_name=\(encodedArtist)")
        requestLyricsURL(url: primaryUrl, fallbackUrl: shouldIncludeDuration ? fallbackUrl : nil)
    }

    private func requestLyricsURL(url: URL, fallbackUrl: URL?) {
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                if let fallback = fallbackUrl {
                    Task { @MainActor [weak self] in
                        self?.requestLyricsURL(url: fallback, fallbackUrl: nil)
                    }
                } else {
                    Task { @MainActor in self?.lyricsLoading = false }
                }
                return
            }

            var parsed: [LyricLine] = []
            if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
                parsed = Self.parseLRC(synced)
            } else if let plain = json["plainLyrics"] as? String, !plain.isEmpty {
                let rawLines = plain.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                parsed = rawLines.enumerated().map { LyricLine(id: $0.offset, timestamp: Double($0.offset) * 4.0, text: $0.element) }
            }

            if parsed.isEmpty, let fallback = fallbackUrl {
                Task { @MainActor [weak self] in
                    self?.requestLyricsURL(url: fallback, fallbackUrl: nil)
                }
                return
            }

            Task { @MainActor in
                self?.lyricsLoading = false
                self?.lyrics = parsed
                if let self = self {
                    if self.trackDuration <= 0, let lastTs = parsed.last?.timestamp, lastTs > 0 {
                        self.trackDuration = lastTs + 5.0
                    }
                    self.updateCurrentLyricIndex()
                }
            }
        }.resume()
    }

    nonisolated private static func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let rawLines = lrc.components(separatedBy: .newlines)
        var idCounter = 0
        for line in rawLines {
            guard line.hasPrefix("["), let closingBracket = line.firstIndex(of: "]") else { continue }
            let timePart = String(line[line.index(after: line.startIndex)..<closingBracket])
            let textPart = String(line[line.index(after: closingBracket)...]).trimmingCharacters(in: .whitespaces)
            let timeParts = timePart.components(separatedBy: ":")
            if timeParts.count == 2,
               let min = Double(timeParts[0]),
               let sec = Double(timeParts[1]) {
                let total = min * 60 + sec
                if !textPart.isEmpty {
                    lines.append(LyricLine(id: idCounter, timestamp: total, text: textPart))
                    idCounter += 1
                }
            }
        }
        return lines
    }

    // MARK: - Playback Controls & Focus

    func activateCurrentPlayer() {
        guard !RuntimeEnvironment.isRunningTests else { return }
        switch activeSource {
        case .appleMusic:
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first?.activate()
        case .spotifyDesktop, .none:
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first?.activate()
        case .spotifyWeb(let browser):
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleIdentifier).first?.activate()
            let focusScript: String
            if browser.isSafari {
                focusScript = """
                tell application "\(browser.applicationName)"
                    activate
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                if (URL of t) contains "open.spotify.com" then
                                    set current tab of w to t
                                    set index of w to 1
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end tell
                """
            } else {
                focusScript = """
                tell application "\(browser.applicationName)"
                    activate
                    repeat with w in windows
                        set tabIdx to 1
                        repeat with t in tabs of w
                            try
                                if (URL of t) contains "open.spotify.com" then
                                    set active tab index of w to tabIdx
                                    set index of w to 1
                                    return
                                end if
                            end try
                            set tabIdx to tabIdx + 1
                        end repeat
                    end repeat
                end tell
                """
            }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.runAppleScript(focusScript)
            }
        }
    }

    func togglePlayPause() {
        if case .spotifyWeb(let browser) = activeSource {
            let js = "(function(){var b=document.querySelector('[data-testid=control-button-playpause]');if(b){b.click();}})()"
            let script = Self.buildBrowserActionScript(for: browser, jsExpression: js)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.runAppleScript(script)
            }
        } else {
            let app = (activeSource == .appleMusic || player == "Music") ? "Music" : "Spotify"
            let script = "tell application \"\(app)\" to playpause"
            _ = Self.runAppleScript(script)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.fetchPlaybackDetails()
        }
    }

    func nextTrack() {
        if case .spotifyWeb(let browser) = activeSource {
            let js = "(function(){var b=document.querySelector('[data-testid=control-button-skip-forward]');if(b){b.click();}})()"
            let script = Self.buildBrowserActionScript(for: browser, jsExpression: js)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.runAppleScript(script)
            }
        } else {
            let app = (activeSource == .appleMusic || player == "Music") ? "Music" : "Spotify"
            let script = "tell application \"\(app)\" to next track"
            _ = Self.runAppleScript(script)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.fetchPlaybackDetails()
            self?.triggerToast()
        }
    }

    func previousTrack() {
        if case .spotifyWeb(let browser) = activeSource {
            let js = "(function(){var b=document.querySelector('[data-testid=control-button-skip-back]');if(b){b.click();}})()"
            let script = Self.buildBrowserActionScript(for: browser, jsExpression: js)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.runAppleScript(script)
            }
        } else {
            let app = (activeSource == .appleMusic || player == "Music") ? "Music" : "Spotify"
            let script = "tell application \"\(app)\" to previous track"
            _ = Self.runAppleScript(script)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.fetchPlaybackDetails()
            self?.triggerToast()
        }
    }

    func seek(to position: Double) {
        if case .spotifyWeb(let browser) = activeSource {
            guard trackDuration > 0 else { return }
            let fraction = min(1.0, max(0.0, position / trackDuration))
            let js = String(
                format: "(function(){var bar=document.querySelector('[data-testid=playback-progressbar]')||document.querySelector('[data-testid=progress-bar]');if(bar){var r=bar.getBoundingClientRect();var x=r.left+r.width*%.6f;var y=r.top+r.height/2;['mousedown','mouseup','click'].forEach(function(ev){bar.dispatchEvent(new MouseEvent(ev,{bubbles:true,cancelable:true,view:window,clientX:x,clientY:y}));});}})()",
                fraction
            )
            let script = Self.buildBrowserActionScript(for: browser, jsExpression: js)
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Self.runAppleScript(script)
            }
        } else {
            let app = (activeSource == .appleMusic || player == "Music") ? "Music" : "Spotify"
            let script = "tell application \"\(app)\" to set player position to \(position)"
            _ = Self.runAppleScript(script)
        }
        self.playerPosition = position
        updateCurrentLyricIndex()
    }

    nonisolated private static func runAppleScript(_ script: String) -> String? {
        guard !RuntimeEnvironment.isRunningTests else { return nil }
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if error == nil {
                return result.stringValue
            }
        }
        return nil
    }
}
