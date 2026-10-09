import Foundation

/// Source-preserving editor for the root Codex hooks feature flag (#354).
/// This is deliberately not a general TOML parser: values remain opaque, and
/// conflicting/unsupported layouts return nil rather than risk a duplicate key.
/// Keep the remote Python editor in RemoteInstaller in sync with this behavior.
public enum CodexHooksConfig {
    public static func enablingHooks(in contents: String) -> String? {
        try? Scanner(contents).enablingHooks()
    }

    private enum Invalid: Error { case layout }

    private struct Flag {
        let statement: Range<Int>
        let key: Range<Int>
        let value: Range<Int>
        let keyCount: Int
    }

    private struct Edit {
        let range: Range<Int>
        let replacement: String
    }

    private struct Scanner {
        let contents: String
        let source: [Unicode.Scalar]

        init(_ contents: String) {
            self.contents = contents
            source = Array(contents.unicodeScalars)
        }

        func enablingHooks(healing: Bool = true) throws -> String {
            let statements = try statements()
            if healing, let healed = try withoutAppendedFeaturesTable(statements) {
                return try Scanner(healed).enablingHooks(healing: false)
            }
            var scope: [String] = []
            var current: Flag?
            var legacy: Flag?
            var featuresHeader: Int?
            var firstTable: Int?
            var rootDottedFeatures = false
            for statement in statements {
                var i = skipSpaces(statement.lowerBound, limit: statement.upperBound)
                guard i < statement.upperBound, ![35, 13, 10].contains(source[i].value) else { continue }
                if source[i] == "[" {
                    let array = i + 1 < statement.upperBound && source[i + 1] == "["
                    let parsed = try key(at: i + (array ? 2 : 1), limit: statement.upperBound)
                    let close = parsed.next
                    guard close < statement.upperBound, source[close] == "]",
                          !array || (close + 1 < statement.upperBound && source[close + 1] == "]"),
                          tail(at: close + (array ? 2 : 1), limit: statement.upperBound) else { throw Invalid.layout }
                    scope = parsed.path
                    guard Array(scope.prefix(2)) != ["features", "hooks"],
                          !(array && scope == ["features"]) else { throw Invalid.layout }
                    if firstTable == nil { firstTable = statement.lowerBound }
                    if scope == ["features"] {
                        guard featuresHeader == nil else { throw Invalid.layout }
                        featuresHeader = statement.upperBound
                    }
                    continue
                }
                let keyStart = i
                let parsed = try key(at: i, limit: statement.upperBound)
                i = parsed.next
                guard i < statement.upperBound, source[i] == "=" else { throw Invalid.layout }
                i = skipSpaces(i + 1, limit: statement.upperBound)
                guard i < statement.upperBound, ![35, 13, 10].contains(source[i].value) else { throw Invalid.layout }
                if scope.isEmpty && parsed.path.count > 1 && parsed.path[0] == "features" { rootDottedFeatures = true }
                let absolute = scope + parsed.path
                guard absolute != ["features"],
                      !(Array(absolute.prefix(2)) == ["features", "hooks"] && absolute.count > 2) else { throw Invalid.layout }
                guard absolute == ["features", "hooks"] || absolute == ["features", "codex_hooks"] else { continue }
                guard let value = ["true", "false"].first(where: {
                    matches($0, at: i, limit: statement.upperBound) && tail(at: i + $0.count, limit: statement.upperBound)
                }) else { throw Invalid.layout }
                let flag = Flag(statement: statement, key: keyStart..<parsed.end, value: i..<(i + value.count), keyCount: parsed.path.count)
                if absolute == ["features", "hooks"] {
                    guard current == nil else { throw Invalid.layout }
                    current = flag
                } else {
                    guard legacy == nil else { throw Invalid.layout }
                    legacy = flag
                }
            }
            // Root dotted `features.*` keys already define the table, so an
            // explicit [features] header too is a duplicate key Codex refuses
            // to load. Don't report such a file as enabled.
            guard featuresHeader == nil || !rootDottedFeatures else { throw Invalid.layout }

            var edits: [Edit] = []
            if let current {
                edits.append(Edit(range: current.value, replacement: "true"))
                if let legacy { edits.append(Edit(range: legacy.statement, replacement: "")) }
            } else if let legacy {
                edits.append(Edit(range: legacy.key, replacement: legacy.keyCount == 1 ? "hooks" : "features.hooks"))
                edits.append(Edit(range: legacy.value, replacement: "true"))
            } else {
                let newline = contents.contains("\r\n") ? "\r\n" : "\n"
                let position: Int
                let addition: String
                if let featuresHeader {
                    position = featuresHeader
                    addition = (position > 0 && source[position - 1] == "\n" ? "" : newline) + "hooks = true" + newline
                } else if let firstTable {
                    position = firstTable
                    addition = "features.hooks = true" + newline
                } else {
                    position = source.count
                    addition = (!source.isEmpty && source.last != "\n" ? newline : "") + "features.hooks = true" + newline
                }
                edits.append(Edit(range: position..<position, replacement: addition))
            }
            var result = source
            for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
                result.replaceSubrange(edit.range, with: edit.replacement.unicodeScalars)
            }
            return String(String.UnicodeScalarView(result))
        }

        /// CodeIsland 1.0.35 and earlier appended `[features]` + `hooks = true`
        /// at EOF whenever its line regex missed the flag or the header, even
        /// when root dotted `features.*` keys or a spelling such as
        /// `[features] # note` already defined that table: a duplicate key that
        /// stops Codex from starting (#354). Returns the document without that
        /// block (and the blank line before it), or nil unless the file ends
        /// with exactly that shape on top of an existing features table.
        func withoutAppendedFeaturesTable(_ statements: [Range<Int>]) throws -> String? {
            var featuresDefined = false
            var lastHeader: Int?
            for (index, statement) in statements.enumerated() {
                let i = skipSpaces(statement.lowerBound, limit: statement.upperBound)
                guard i < statement.upperBound, ![35, 13, 10].contains(source[i].value) else { continue }
                if source[i] == "[" {
                    // Every header but the final one may be the earlier definition.
                    if let previous = lastHeader, try isFeaturesHeader(statements[previous]) { featuresDefined = true }
                    lastHeader = index
                } else if lastHeader == nil {
                    let path = try key(at: i, limit: statement.upperBound).path
                    if path.count > 1 && path[0] == "features" { featuresDefined = true }
                }
            }
            guard featuresDefined, let lastHeader else { return nil }
            let header = statements[lastHeader]
            let open = skipSpaces(header.lowerBound, limit: header.upperBound)
            guard matches("[features]", at: open, limit: header.upperBound),
                  isBlank(open + 10..<header.upperBound) else { return nil }
            var flags = 0
            for statement in statements[(lastHeader + 1)...] where !isBlank(statement) {
                let first = skipSpaces(statement.lowerBound, limit: statement.upperBound)
                guard source[first] != "#" else { return nil }
                let assignment = try key(at: first, limit: statement.upperBound)
                guard assignment.path == ["hooks"], assignment.next < statement.upperBound,
                      source[assignment.next] == "=" else { return nil }
                let value = skipSpaces(assignment.next + 1, limit: statement.upperBound)
                guard ["true", "false"].contains(where: {
                    matches($0, at: value, limit: statement.upperBound)
                        && isBlank(value + $0.unicodeScalars.count..<statement.upperBound)
                }) else { return nil }
                flags += 1
            }
            guard flags == 1 else { return nil }
            var start = header.lowerBound
            if lastHeader > 0, isBlank(statements[lastHeader - 1]) { start = statements[lastHeader - 1].lowerBound }
            return String(String.UnicodeScalarView(source[..<start]))
        }

        /// `[features]` in any spelling (quoted, spaced, commented); not `[[features]]`.
        func isFeaturesHeader(_ statement: Range<Int>) throws -> Bool {
            let open = skipSpaces(statement.lowerBound, limit: statement.upperBound)
            guard open + 1 < statement.upperBound, source[open + 1] != "[" else { return false }
            let parsed = try key(at: open + 1, limit: statement.upperBound)
            return parsed.path == ["features"] && parsed.next < statement.upperBound && source[parsed.next] == "]"
        }

        func isBlank(_ range: Range<Int>) -> Bool {
            source[range].allSatisfy { [32, 9, 13, 10].contains($0.value) }
        }

        /// Newlines inside strings or nested array/inline-table values do not
        /// start a new statement. Ranges retain comments and line endings.
        func statements() throws -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var stack: [Unicode.Scalar] = []
            var start = 0
            var i = 0
            while i < source.count {
                let ch = source[i]
                if ch == "\"" || ch == "'" {
                    i = try string(at: i, limit: source.count, multiline: true).end
                    continue
                }
                if ch == "#" {
                    while i < source.count && source[i] != "\n" { i += 1 }
                    continue
                }
                if ch == "[" || ch == "{" {
                    stack.append(ch)
                } else if ch == "]" || ch == "}" {
                    guard stack.popLast() == (ch == "]" ? "[" : "{") else { throw Invalid.layout }
                } else if ch == "\r" {
                    guard i + 1 < source.count, source[i + 1] == "\n" else { throw Invalid.layout }
                } else if isControl(ch) {
                    throw Invalid.layout
                }
                if ch == "\n" && stack.isEmpty {
                    ranges.append(start..<(i + 1))
                    start = i + 1
                }
                i += 1
            }
            guard stack.isEmpty else { throw Invalid.layout }
            if start < source.count { ranges.append(start..<source.count) }
            return ranges
        }

        func key(at start: Int, limit: Int) throws -> (path: [String], end: Int, next: Int) {
            var path: [String] = []
            var i = start
            while true {
                i = skipSpaces(i, limit: limit)
                guard i < limit else { throw Invalid.layout }
                if source[i] == "\"" || source[i] == "'" {
                    let parsed = try string(at: i, limit: limit)
                    path.append(parsed.value)
                    i = parsed.end
                } else {
                    let begin = i
                    while i < limit && isBareKey(source[i]) { i += 1 }
                    guard i > begin else { throw Invalid.layout }
                    path.append(String(String.UnicodeScalarView(source[begin..<i])))
                }
                let end = i
                i = skipSpaces(i, limit: limit)
                if i == limit || source[i] != "." { return (path, end, i) }
                i += 1
            }
        }

        func string(at start: Int, limit: Int, multiline: Bool = false) throws -> (end: Int, value: String) {
            let quote = source[start]
            let triple = start + 2 < limit && source[start + 1] == quote && source[start + 2] == quote
            guard !triple || multiline else { throw Invalid.layout }
            var i = start + (triple ? 3 : 1)
            var out: [Unicode.Scalar] = []
            while i < limit {
                let ch = source[i]
                if ch == quote {
                    var end = i + 1
                    if triple {
                        while end < limit && source[end] == quote { end += 1 }
                        let count = end - i
                        if count < 3 {
                            out.append(contentsOf: repeatElement(quote, count: count))
                            i = end
                            continue
                        }
                        guard count <= 5 else { throw Invalid.layout }
                        out.append(contentsOf: repeatElement(quote, count: count - 3))
                    }
                    return (end, String(String.UnicodeScalarView(out)))
                }
                if ch == "\\" && quote == "\"" {
                    i += 1
                    guard i < limit else { throw Invalid.layout }
                    let escaped = source[i]
                    if triple && [32, 9, 13, 10].contains(escaped.value) {
                        var sawNewline = false
                        while i < limit && [32, 9, 13, 10].contains(source[i].value) {
                            if source[i] == "\r" {
                                guard i + 1 < limit, source[i + 1] == "\n" else { throw Invalid.layout }
                            }
                            sawNewline = sawNewline || source[i] == "\n"
                            i += 1
                        }
                        guard sawNewline else { throw Invalid.layout }
                        continue
                    }
                    let escapes: [Unicode.Scalar: Unicode.Scalar] = ["b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{C}", "r": "\r", "\"": "\"", "\\": "\\"]
                    if let value = escapes[escaped] {
                        out.append(value)
                        i += 1
                        continue
                    }
                    if escaped == "u" || escaped == "U" {
                        let end = i + (escaped == "u" ? 5 : 9)
                        guard end <= limit else { throw Invalid.layout }
                        let digits = String(String.UnicodeScalarView(source[(i + 1)..<end]))
                        guard digits.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }),
                              let value = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(value) else { throw Invalid.layout }
                        out.append(scalar)
                        i = end
                        continue
                    }
                    throw Invalid.layout
                }
                guard triple || (ch != "\r" && ch != "\n"), !isControl(ch) else { throw Invalid.layout }
                if ch == "\r" {
                    guard i + 1 < limit, source[i + 1] == "\n" else { throw Invalid.layout }
                }
                out.append(ch)
                i += 1
            }
            throw Invalid.layout
        }

        func skipSpaces(_ start: Int, limit: Int) -> Int {
            var i = start
            while i < limit && (source[i] == " " || source[i] == "\t") { i += 1 }
            return i
        }

        func tail(at start: Int, limit: Int) -> Bool {
            var i = start
            while i < limit && [32, 9, 13, 10].contains(source[i].value) { i += 1 }
            return i == limit || source[i] == "#"
        }

        func matches(_ text: String, at start: Int, limit: Int) -> Bool {
            let scalars = Array(text.unicodeScalars)
            return start + scalars.count <= limit && source[start..<(start + scalars.count)].elementsEqual(scalars)
        }

        func isBareKey(_ ch: Unicode.Scalar) -> Bool {
            (48...57).contains(ch.value) || (65...90).contains(ch.value) || (97...122).contains(ch.value) || ch == "_" || ch == "-"
        }

        func isControl(_ ch: Unicode.Scalar) -> Bool {
            (ch.value < 32 && ![9, 13, 10].contains(ch.value)) || ch.value == 127
        }
    }
}
