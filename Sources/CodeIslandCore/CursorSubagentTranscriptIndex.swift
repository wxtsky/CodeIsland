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
}

/// When fresh walks look up a default-Claude card the index does not
/// resolve: `delays` after the card first went unresolved, then never again.
///
/// A Cursor Task's transcript lands within seconds of its first hook, so a
/// card still unresolved after the last lookup is a real Claude session.
/// Walking on behalf of every such card for as long as it lives would re-read
/// all of `~/.cursor/projects` every so often for as long as Claude Code runs.
public struct CursorSubagentLookupSchedule: Sendable {
    public static let defaultDelays: [TimeInterval] = [0, 5, 15, 45, 120]

    /// When the card first went unresolved.
    public let since: Date
    /// Ascending.
    public let delays: [TimeInterval]
    /// How many of `delays` walks have covered so far.
    public private(set) var lookupsDone = 0

    public init(since: Date, delays: [TimeInterval] = defaultDelays) {
        self.since = since
        self.delays = delays
    }

    /// When the next lookup is due; nil once every lookup is done.
    public var nextLookup: Date? {
        lookupsDone < delays.count ? since.addingTimeInterval(delays[lookupsDone]) : nil
    }

    /// A walk that started at `walkStartedAt` did not find the card. It covers
    /// every lookup due by then (a transcript on disk earlier would still be
    /// there) and none due later, so a walk already running when the card was
    /// first seen leaves it its immediate lookup.
    public mutating func recordMiss(walkStartedAt: Date) {
        let covered = delays.prefix(while: { since.addingTimeInterval($0) <= walkStartedAt }).count
        lookupsDone = max(lookupsDone, covered)
    }
}
