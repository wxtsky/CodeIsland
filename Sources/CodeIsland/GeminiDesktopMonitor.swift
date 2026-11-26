import AppKit
import ApplicationServices

/// Gemini exposes task badges in the sidebar and the latest reply in the open
/// conversation. Reading these controls never opens a chat or touches the clipboard.
enum GeminiDesktop {
    static let bundleID = "com.google.GeminiMacOS"

    static let conversationSessionPrefix = "gemini-desktop:chat:"

    enum Phase { case working, ready, attention }
    struct Chat {
        var badge: Phase?
        var generating = false
        var window: CFHashCode?
        var turn: String?
        var turnNumber: Int?
        var reply: String?
        var ambiguous = false
    }
    struct Change {
        let title: String
        let event: String
        var reply: String? = nil
        let sessionID: String

        var payload: [String: String] {
            var fields = ["session_id": sessionID, "session_title": title,
                          "hook_event_name": event, "_source": "gemini", "_term_bundle": bundleID]
            fields["last_assistant_message"] = reply
            return fields
        }
    }

    struct Tracker {
        private struct Active {
            let sessionID: String
            var turn: String?
            var window: CFHashCode?
            var lastSeen: Date
        }
        private var active: [String: Active] = [:]
        private struct Finished {
            let turn: String?
            let number: Int?
            let at: Date
        }
        private var finished: [String: Finished] = [:]
        private var previous: [String: Chat] = [:]
        // Gemini exposes unique sidebar titles but no durable AX conversation
        // identifier. Keep card identity across turns, independently of the
        // short-lived state used to suppress duplicate completion events.
        private var sessionIDsByTitle: [String: String]

        init(sessionIDsByTitle: [String: String] = [:]) {
            self.sessionIDsByTitle = sessionIDsByTitle
        }

        private mutating func sessionID(for title: String) -> String {
            if let existing = sessionIDsByTitle[title] { return existing }
            let id = GeminiDesktop.conversationSessionPrefix + UUID().uuidString
            sessionIDsByTitle[title] = id
            return id
        }

        mutating func reset() -> [Change] {
            defer { active.removeAll(); previous.removeAll(); finished.removeAll() }
            return active.map { Change(title: $0.key, event: "SessionEnd", sessionID: $0.value.sessionID) }
        }

        mutating func update(_ chats: [String: Chat], now: Date = Date()) -> [Change] {
            var changes: [Change] = []
            // Multiple visible conversations share this label. A later unique
            // observation could be either one, so it cannot inherit this card.
            for (title, chat) in chats where chat.ambiguous {
                if let run = active.removeValue(forKey: title) {
                    changes.append(Change(title: title, event: "SessionEnd", sessionID: run.sessionID))
                }
                sessionIDsByTitle.removeValue(forKey: title)
                finished.removeValue(forKey: title)
            }
            finished = finished.filter { now.timeIntervalSince($0.value.at) < 600 }

            // A new chat initially uses the prompt as its window title. Gemini
            // can replace it with a generated title before the final reply.
            for (title, chat) in chats where sessionIDsByTitle[title] == nil {
                guard let window = chat.window, let turn = chat.turn, !turn.isEmpty else { continue }
                let matches = sessionIDsByTitle.keys.filter { old in
                    guard chats[old] == nil else { return false }
                    if let run = active[old], run.window == window {
                        return run.turn == turn || (run.turn == nil && turn.hasPrefix(old))
                    }
                    return previous[old]?.window == window && previous[old]?.turn == turn
                }
                if matches.count == 1, let old = matches.first {
                    sessionIDsByTitle[title] = sessionIDsByTitle.removeValue(forKey: old)
                    active[title] = active.removeValue(forKey: old)
                    finished[title] = finished.removeValue(forKey: old)
                }
            }
            for (title, chat) in chats where !chat.ambiguous {
                if chat.generating || chat.badge == .working {
                    if var run = active[title] {
                        run.turn = chat.turn ?? run.turn
                        run.window = chat.window ?? run.window
                        run.lastSeen = now
                        active[title] = run
                    } else {
                        // Gemini can expose a stale generating control or a working badge
                        // for one snapshot after the settled reply has been announced.
                        if let last = finished[title] {
                            if let turn = chat.turn, last.turn == turn, last.number == chat.turnNumber { continue }
                            if chat.turn == nil, previous[title]?.badge != .working { continue }
                        }
                        finished.removeValue(forKey: title)
                        let start = Change(title: title, event: "UserPromptSubmit", sessionID: sessionID(for: title))
                        active[title] = Active(sessionID: start.sessionID, turn: chat.turn,
                                               window: chat.window, lastSeen: now)
                        changes.append(start)
                    }
                } else if let run = active[title] {
                    let sameTurn = chat.turn != nil && chat.turn == run.turn
                    if chat.badge == .ready || (sameTurn && chat.reply != nil) {
                        changes.append(Change(title: title, event: "Stop", reply: sameTurn || run.turn == nil ? chat.reply : nil, sessionID: run.sessionID))
                        finished[title] = Finished(turn: chat.turn ?? run.turn, number: chat.turnNumber, at: now)
                        active.removeValue(forKey: title)
                    } else if chat.badge == .attention {
                        changes.append(Change(title: title, event: "SessionEnd", sessionID: run.sessionID))
                        active.removeValue(forKey: title)
                    }
                } else if let old = previous[title], let turn = chat.turn, let reply = chat.reply,
                          old.window != nil, old.window == chat.window, old.turn != nil, old.turn != turn,
                          let before = old.turnNumber, let after = chat.turnNumber, after > before {
                    // A short turn can finish between observations of the same open chat.
                    finished[title] = Finished(turn: turn, number: after, at: now)
                    changes.append(Change(title: title, event: "Stop", reply: reply, sessionID: sessionID(for: title)))
                }
            }
            // A closed window, a filtered sidebar or an abandoned turn is no
            // evidence of completion. Retire its old card without a chime.
            for (title, run) in active where now.timeIntervalSince(run.lastSeen) > 60 {
                changes.append(Change(title: title, event: "SessionEnd", sessionID: run.sessionID))
                active.removeValue(forKey: title)
            }
            previous = chats
            return changes
        }
    }

    /// Build matchers from Gemini's own localized VoiceOver label formats.
    /// Some languages quote the title, and some put the status first.
    struct BadgeLabels {
        struct Pattern {
            let prefix: String
            let suffix: String
            let phase: Phase
        }
        var patterns: [Pattern] = []
        private var navigationLabels: [NSRegularExpression] = []

        init(format: String, labels: [(String, Phase)]) {
            for (label, phase) in labels {
                let template = String(format: format, "__TITLE__", label)
                let parts = template.components(separatedBy: "__TITLE__")
                if parts.count == 2 { patterns.append(Pattern(prefix: parts[0], suffix: parts[1], phase: phase)) }
            }
        }

        init(bundle: Bundle) {
            let languages = CFPreferencesCopyAppValue("AppleLanguages" as CFString, bundleID as CFString) as? [String]
            let locales = Bundle.preferredLocalizations(from: bundle.localizations,
                                                         forPreferences: languages ?? Locale.preferredLanguages)
            for language in Set(locales + ["en"]) {
                guard let path = bundle.path(forResource: language, ofType: "lproj"),
                      let localized = Bundle(path: path) else { continue }
                func value(_ key: String) -> String { localized.localizedString(forKey: key, value: nil, table: "App") }
                let format = value("SIDEBAR_ROW_TASK_BADGE_ACCESSIBILITY_LABEL")
                let labels: [(String, Phase)] = [(value("SIDEBAR_TASK_BADGE_IN_PROGRESS"), .working),
                                                  (value("SIDEBAR_TASK_BADGE_READY"), .ready),
                                                  (value("SIDEBAR_TASK_BADGE_NEEDS_ATTENTION"), .attention)]
                patterns += BadgeLabels(format: format, labels: labels).patterns
                let nav = value("CHAT_NAVIGATION_TURN_ACCESSIBILITY_LABEL")
                let sample = String(format: nav, 12345, "__PROMPT__")
                let pattern = NSRegularExpression.escapedPattern(for: sample)
                    .replacingOccurrences(of: "12345", with: "([0-9]+)")
                    .replacingOccurrences(of: "__PROMPT__", with: ".+")
                if let regex = try? NSRegularExpression(pattern: "^" + pattern + "$", options: .dotMatchesLineSeparators),
                   regex.numberOfCaptureGroups == 1 { navigationLabels.append(regex) }

            }
        }

        func turnNumber(_ label: String) -> Int? {
            let range = NSRange(label.startIndex..., in: label)
            for regex in navigationLabels {
                if let match = regex.firstMatch(in: label, range: range),
                   let number = Range(match.range(at: 1), in: label) { return Int(label[number]) }
            }
            return nil
        }

        func parse(_ label: String) -> (String, Phase)? {
            for p in patterns where label.hasPrefix(p.prefix) && label.hasSuffix(p.suffix)
                    && label.count > p.prefix.count + p.suffix.count {
                return (String(label.dropFirst(p.prefix.count).dropLast(p.suffix.count)), p.phase)
            }
            return nil
        }
    }

    /// All AX calls run on the monitor's utility task. Traverse the window
    /// chrome and the tail of the transcript; never walk the message history.
    struct Reader {
        let labels: BadgeLabels
        func read(pid: pid_t) -> [String: Chat]? {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let windows: [AXUIElement] = app.ax("AXWindows") else { return nil }
            var chats: [String: Chat] = [:]
            var ambiguous = Set<String>()
            var openTitles = Set<String>()
            for window in windows {
                let windowTitle = window.string("AXTitle")
                let title = windowTitle.hasPrefix("Gemini - ") ? String(windowTitle.dropFirst(9)) : (windowTitle == "Gemini" ? "Gemini" : "")
                var selected = Chat()
                var transcript: [AXUIElement] = []
                var seen = Set<String>()
                func visit(_ element: AXUIElement, depth: Int) {
                    guard depth <= 8 else { return }
                    let role = element.role
                    if role == "AXOutline" {
                        let rows: [AXUIElement] = element.ax("AXVisibleRows") ?? []
                        for row in rows {
                            guard let cell = row.children.first, let button = cell.children.first,
                                  button.role == "AXButton" else { continue }
                            let label = button.string("AXDescription")
                            let parsed = labels.parse(label)
                            let key = parsed?.0 ?? label
                            if !seen.insert(key).inserted { ambiguous.insert(key) }
                            if let (name, badge) = parsed {
                                chats[name, default: Chat()].badge = badge
                            } else if chats[key] == nil {
                                // Seeing the old title still in the sidebar distinguishes a
                                // switch to another chat from an automatic title change.
                                chats[key] = Chat()
                            }
                        }
                        return
                    }
                    if role == "AXButton" {
                        if element.string("AXIdentifier") == "stop_button" { selected.generating = true }
                        if let n = labels.turnNumber(element.string("AXDescription")) {
                            selected.turnNumber = max(selected.turnNumber ?? 0, n)
                        }
                        return
                    }
                    guard ["AXWindow", "AXGroup", "AXSplitGroup", "AXScrollArea"].contains(role) else { return }
                    let children = element.children
                    if let first = children.first, first.role == "AXRow" {
                        transcript = children
                        return
                    }
                    for child in children { visit(child, depth: depth + 1) }
                }
                visit(window, depth: 0)
                // Recheck identity after reading remote UI across process boundaries.
                if window.string("AXTitle") == windowTitle && !title.isEmpty {
                    if !openTitles.insert(title).inserted { ambiguous.insert(title) }
                    let tail = readTail(transcript)
                    selected.window = CFHash(window)
                    selected.turn = tail.turn
                    selected.reply = tail.reply
                    selected.badge = chats[title]?.badge
                    chats[title] = selected
                }
            }
            for name in ambiguous { chats[name] = Chat(ambiguous: true) }
            return chats
        }

        private func readTail(_ rows: [AXUIElement]) -> (turn: String?, reply: String?) {
            var reply: String?
            for row in rows.reversed().prefix(12) {
                guard let cell = row.children.first, let group = cell.children.first else { continue }
                let content = group.children
                if let heading = content.first(where: { $0.role == "AXHeading" }) {
                    let prompt = heading.string("AXDescription")
                    if !prompt.isEmpty { return (String(prompt.prefix(160)), reply) }
                    continue
                }
                guard reply == nil else { continue }
                // Feedback actions identify a settled assistant row. A thought,
                // tool approval, user heading or older answer is not a preview.
                let hasFeedback = content.contains { item in
                    item.role == "AXGroup" && item.children.contains {
                        $0.string("AXIdentifier").hasPrefix("thumb-up-")
                    }
                }
                guard hasFeedback else { continue }
                let body = content.first { item in
                    let role = item.role
                    return ["AXStaticText", "AXGroup", "AXTextArea", "AXButton"].contains(role)
                        && (role != "AXButton" || item.string("AXIdentifier").contains("copy-button"))
                        && !item.string("AXDescription").isEmpty
                }
                let text = (body?.string("AXDescription") ?? cell.string("AXDescription"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply = String(text.prefix(600)) }
            }
            return (nil, nil)
        }
    }
}

private extension AXUIElement {
    func ax<T>(_ key: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, key as CFString, &value) == .success else { return nil }
        return value as? T
    }
    func string(_ key: String) -> String { ax(key) ?? "" }
    var role: String { string("AXRole") }
    var children: [AXUIElement] { ax("AXChildren") ?? [] }
}

extension GeminiDesktop {
    /// Owns no timer on the UI thread. An isolated launch never starts this task.
    static func observe(sessionIDsByTitle: [String: String] = [:], deliver: @escaping @Sendable ([Change]) async -> Void) async {
        var tracker = Tracker(sessionIDsByTitle: sessionIDsByTitle)
        var process: pid_t?
        var reader: Reader?
        while !Task.isCancelled {
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            let pid = app?.processIdentifier
            if process != pid || !AXIsProcessTrusted() {
                let removals = tracker.reset()
                if !removals.isEmpty { await deliver(removals) }
                reader = nil
                process = pid
            }
            if let pid, AXIsProcessTrusted() {
                if reader == nil, let url = app?.bundleURL, let bundle = Bundle(url: url) {
                    reader = Reader(labels: BadgeLabels(bundle: bundle))
                }
                if let chats = reader?.read(pid: pid), !Task.isCancelled {
                    let changes = tracker.update(chats)
                    if !changes.isEmpty { await deliver(changes) }
                }
            }
            try? await Task.sleep(nanoseconds: pid == nil ? 8_000_000_000 : 2_000_000_000)
        }
    }
}
