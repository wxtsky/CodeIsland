import Foundation

/// Every Cursor Agent Task transcript under `~/.cursor/projects`, keyed by the
/// Task's session id (`…/agent-transcripts/<parentId>/subagents/<id>.jsonl`).
///
/// Rebranding a default-Claude card that is really a Cursor Task needs to know
/// whether such a file exists for the card's id. Walking every project's
/// transcript tree per card per lookup ran on the main actor on every hook
/// event and every discovery scan; with a few hundred MB of Cursor history it
/// pinned the main thread. One walk builds this index off the main actor, and
/// a lookup is a dictionary read.
public struct CursorSubagentTranscriptIndex: Sendable {
    /// When the walk that produced this index started. A transcript written
    /// after this instant may be missing from it.
    public let builtAt: Date
    private let pathsBySessionId: [String: [String]]

    public init(pathsBySessionId: [String: [String]], builtAt: Date) {
        self.pathsBySessionId = pathsBySessionId
        self.builtAt = builtAt
    }

    /// Walk `<home>/.cursor/projects/*/agent-transcripts` once and index every
    /// `subagents/<id>.jsonl`, at any depth below `agent-transcripts`.
    public static func scan(
        home: String,
        fm: FileManager = .default,
        now: Date = Date()
    ) -> CursorSubagentTranscriptIndex {
        let projectsRoot = "\(home)/.cursor/projects"
        var paths: [String: [String]] = [:]
        for project in (try? fm.contentsOfDirectory(atPath: projectsRoot)) ?? [] {
            let base = "\(projectsRoot)/\(project)/agent-transcripts"
            guard let enumerator = fm.enumerator(atPath: base) else { continue }
            while let rel = enumerator.nextObject() as? String {
                guard rel.hasSuffix(".jsonl") else { continue }
                let components = rel.split(separator: "/", omittingEmptySubsequences: false)
                guard components.count >= 2,
                      components[components.count - 2] == "subagents" else { continue }
                let sessionId = String(components[components.count - 1].dropLast(".jsonl".count))
                guard !sessionId.isEmpty else { continue }
                paths[sessionId, default: []].append("\(base)/\(rel)")
            }
        }
        return CursorSubagentTranscriptIndex(pathsBySessionId: paths, builtAt: now)
    }

    public func contains(sessionId: String) -> Bool {
        transcriptPath(sessionId: sessionId, preferredBase: nil) != nil
    }

    /// The Task transcript for `sessionId`, preferring one under
    /// `preferredBase` (the card's own project) when several projects hold it.
    public func transcriptPath(sessionId: String, preferredBase: String?) -> String? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let paths = pathsBySessionId[trimmed], !paths.isEmpty else {
            return nil
        }
        if let preferredBase,
           let preferred = paths.first(where: { $0.hasPrefix(preferredBase + "/") }) {
            return preferred
        }
        return paths.first
    }

    /// Lookups a card gets soon after it is first seen: once on sight, once
    /// more `promptRecheckInterval` later in case its transcript landed just
    /// after its first hook. After that the card is almost certainly a real
    /// Claude session and is re-checked only every `settledRefreshInterval`.
    public static let promptLookups = 2
    public static let promptRecheckInterval: TimeInterval = 5
    public static let settledRefreshInterval: TimeInterval = 60

    /// When the next walk may start for cards the current index does not
    /// resolve, given how many walks already missed each of them. Nil when no
    /// card is waiting on one.
    public static func nextRebuildDate(
        lastBuiltAt: Date?,
        unresolvedMissCounts: [Int]
    ) -> Date? {
        guard !unresolvedMissCounts.isEmpty else { return nil }
        guard let lastBuiltAt else { return .distantPast }
        let awaitingPromptLookup = unresolvedMissCounts.contains { $0 < promptLookups }
        return lastBuiltAt.addingTimeInterval(
            awaitingPromptLookup ? promptRecheckInterval : settledRefreshInterval
        )
    }
}
