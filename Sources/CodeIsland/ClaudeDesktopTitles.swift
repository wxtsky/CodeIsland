import Foundation
import CodeIslandCore

/// The titles the Claude desktop app's Code tab gives Claude Code sessions.
///
/// The app keeps one JSON file per session:
///
///     ~/Library/Application Support/Claude/claude-code-sessions/
///         <account>/<org>/local_<id>.json     top-level `cliSessionId`, `title`, …
///
/// `cliSessionId` is the `session_id` Claude Code's hooks send, and `title` is
/// what the app's sidebar shows, renames included. There is no index, so this
/// builds one from the head of each file (`cliSessionId` sits near the top)
/// and parses only the matching file, again only when its modification date
/// changes. Read-only: nothing is ever written below the root.
final class ClaudeDesktopTitles: @unchecked Sendable {
    static let shared = ClaudeDesktopTitles()

    static let rootDirectoryName = "claude-code-sessions"

    private let root: URL
    private let lock = NSLock()
    /// cliSessionId → the session file.
    private var index: [String: URL] = [:]
    /// Every file looked at, by path, with the modification date it had then:
    /// a file still being written is looked at again once it changes.
    private var scanned: [String: Date] = [:]
    private var lastScan: Date = .distantPast
    /// Parsed titles by path, valid while the file's modification date holds.
    private var titles: [String: (modified: Date, title: String?)] = [:]

    private static let headBytes = 16 * 1024
    /// An id not in the index rescans the root at most this often.
    private static let rescanInterval: TimeInterval = 5
    private static let idPattern = try! NSRegularExpression(
        pattern: #""cliSessionId"\s*:\s*"([^"]+)""#)

    init(root: URL = URL(fileURLWithPath: CoworkPaths.claudeSupportDirectory())
            .appendingPathComponent(ClaudeDesktopTitles.rootDirectoryName)) {
        self.root = root
    }

    /// The Code tab title of the session Claude Code knows as `cliSessionId`.
    func title(cliSessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if index[cliSessionId] == nil {
            guard Date().timeIntervalSince(lastScan) >= Self.rescanInterval else { return nil }
            scan()
        }
        guard let url = index[cliSessionId] else { return nil }
        return readTitle(url)
    }

    // MARK: - With `lock` held

    private func scan() {
        lastScan = Date()
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for account in accounts {
            guard let orgs = try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil) else { continue }
            for org in orgs {
                guard let files = try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil) else { continue }
                for file in files
                where file.lastPathComponent.hasPrefix(CoworkPaths.sessionIdPrefix) && file.pathExtension == "json" {
                    let modified = Self.modificationDate(file)
                    if scanned[file.path] == modified { continue }
                    scanned[file.path] = modified
                    if let id = Self.cliSessionId(in: file) { index[id] = file }
                }
            }
        }
    }

    /// Not `URL.resourceValues`: a URL caches those, and would miss a rename.
    private static func modificationDate(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
    }

    static func cliSessionId(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        if let id = firstId(in: head) { return id }
        // Older files keep the key further down: parse the whole file once.
        guard head.count == headBytes,
              let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["cliSessionId"] as? String
    }

    private static func firstId(in data: Data) -> String? {
        // A cut at headBytes can split a character; decoding replaces it.
        let text = String(decoding: data, as: UTF8.self)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = idPattern.firstMatch(in: text, range: range),
              let id = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[id])
    }

    private func readTitle(_ url: URL) -> String? {
        let modified = Self.modificationDate(url)
        if let cached = titles[url.path], cached.modified == modified { return cached.title }
        var title: String?
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = json["title"] as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? nil : trimmed
        }
        titles[url.path] = (modified, title)
        return title
    }
}
