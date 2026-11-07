import Foundation
import Combine
import AppKit
import SwiftUI

// MARK: - Synced Lyric Model

struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let timestamp: Double
    let text: String
}

/// Observes currently playing tracks from Apple Music and Spotify via macOS DistributedNotificationCenter and AppleScript.
/// Zero background overhead when idle, event-driven with smooth progress updates and lyrics when active.
@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var isPlaying: Bool = false
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var player: String = "" // "Music" or "Spotify"
    @Published var artworkURL: String = ""
    @Published var artworkImage: NSImage?
    @Published var playerPosition: Double = 0
    @Published var trackDuration: Double = 0
    @Published var showToast: Bool = false
    @Published var lyrics: [LyricLine] = []
    @Published var currentLyricIndex: Int = 0
    @Published var lyricsLoading: Bool = false

    private var toastDismissTimer: Timer?
    private var progressTimer: Timer?
    private var lastFetchedLyricsKey: String = ""

    init() {
        setupObservers()
        fetchPlaybackDetails()
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

        updateBasicInfo(
            playing: playing,
            title: trackTitle,
            artist: trackArtist,
            album: trackAlbum,
            source: "Music",
            position: rawPos > 0 ? rawPos : nil,
            duration: rawDuration > 0 ? rawDuration : nil
        )
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

        updateBasicInfo(
            playing: playing,
            title: trackTitle,
            artist: trackArtist,
            album: trackAlbum,
            source: "Spotify",
            position: rawPos > 0 ? rawPos : nil,
            duration: rawDuration > 0 ? rawDuration : nil
        )
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
        if let position = position {
            self.playerPosition = position
            self.updateCurrentLyricIndex()
        }

        if playing {
            startProgressTimer()
            if trackChanged {
                triggerToast()
                fetchLyrics(title: title, artist: artist)
            }
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

    // MARK: - Playback Progress & Fetching

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

                // Every 10 ticks (5 seconds), poll AppleScript to prevent clock drift
                if tickCount % 10 == 0 {
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

    func fetchPlaybackDetails() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isSpotifyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").contains { !$0.isTerminated }
            let isMusicRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").contains { !$0.isTerminated }

            var output: String?
            var detectedSource = "Spotify"

            // Direct AppleScript targeting Spotify without brittle System Events wrapper
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
                output = Self.runAppleScript(spotifyScript)
                detectedSource = "Spotify"
            }

            // Direct AppleScript targeting Apple Music without System Events wrapper
            if (output == nil || output?.isEmpty == true) && isMusicRunning {
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
                output = Self.runAppleScript(musicScript)
                detectedSource = "Music"
            }

            guard let rawOutput = output, !rawOutput.isEmpty else { return }
            let parts = rawOutput.components(separatedBy: "|||")
            guard parts.count >= 7 else { return }

            let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let album = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let posStr = parts[3].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
            let durStr = parts[4].replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespacesAndNewlines)
            let artPathOrUrl = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
            let state = parts[6].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let pos = Double(posStr) ?? 0
            let dur = Double(durStr) ?? 0
            let playing = (state == "playing")

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.title = title
                self.artist = artist
                self.album = album
                if pos > 0 || self.playerPosition == 0 {
                    self.playerPosition = pos
                }
                if dur > 0 {
                    self.trackDuration = dur
                }
                self.isPlaying = playing
                self.player = detectedSource

                if playing {
                    self.startProgressTimer()
                } else {
                    self.stopProgressTimer()
                }

                self.updateCurrentLyricIndex()

                // Load artwork if changed
                if self.artworkURL != artPathOrUrl {
                    self.artworkURL = artPathOrUrl
                    self.loadArtwork(from: artPathOrUrl)
                }

                // Fetch lyrics if not loaded
                if self.lyrics.isEmpty && !title.isEmpty {
                    self.fetchLyrics(title: title, artist: artist)
                }
            }
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

    // MARK: - Playback Controls

    func togglePlayPause() {
        let app = player.isEmpty ? "Spotify" : player
        let script = "tell application \"\(app)\" to playpause"
        _ = Self.runAppleScript(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.fetchPlaybackDetails()
        }
    }

    func nextTrack() {
        let app = player.isEmpty ? "Spotify" : player
        let script = "tell application \"\(app)\" to next track"
        _ = Self.runAppleScript(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.fetchPlaybackDetails()
            self?.triggerToast()
        }
    }

    func previousTrack() {
        let app = player.isEmpty ? "Spotify" : player
        let script = "tell application \"\(app)\" to previous track"
        _ = Self.runAppleScript(script)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.fetchPlaybackDetails()
            self?.triggerToast()
        }
    }

    func seek(to position: Double) {
        let app = player.isEmpty ? "Spotify" : player
        let script = "tell application \"\(app)\" to set player position to \(position)"
        _ = Self.runAppleScript(script)
        self.playerPosition = position
        updateCurrentLyricIndex()
    }

    nonisolated private static func runAppleScript(_ script: String) -> String? {
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
