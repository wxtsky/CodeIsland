import AppKit
import CodeIslandCore
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.codeisland", category: "CompletionReply")

// MARK: - Entry point

/// An assistant reply inside a session card — the completion card and the
/// expanded session list.
///
/// Under a reply-line cap (Settings › AI Reply Lines) the reply becomes a
/// clean preview: block syntax is folded into running text, so a capped row
/// never shows `##`, `| --- |` or a fence marker cut off by the ellipsis.
/// Uncapped, the reply renders as full block Markdown. The reply that just
/// finished on the completion card ignores the cap — see CompletionReplyView.
struct AssistantReplyText: View {
    let text: String
    let fontSize: CGFloat
    let lineLimit: Int?
    var isCompletionReply = false

    var body: some View {
        if isCompletionReply {
            CompletionReplyView(text: text, fontSize: fontSize)
        } else if let lineLimit {
            Text(IslandMarkdownInline.preview(text, singleLine: lineLimit == 1))
                .font(IslandMarkdownStyle.font(fontSize))
                .foregroundStyle(IslandMarkdownStyle.body)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .tint(IslandMarkdownStyle.link)
        } else {
            MarkdownBlocksView(blocks: ChatMessageTextFormatter.markdownBlocks(text), fontSize: fontSize)
                .tint(IslandMarkdownStyle.link)
        }
    }
}

// MARK: - Completion card

/// The finished reply on the completion card: the moment someone actually
/// wants to read it, so it always renders in full whatever the line cap.
/// Its height is capped so the card stays inside the panel window; a longer
/// reply scrolls within that area.
private struct CompletionReplyView: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        PanelFittedScrollArea(
            minimumHeight: CompletionReplyMetrics.minimumHeight(lineHeight: IslandMarkdownStyle.lineHeight(fontSize))
        ) {
            MarkdownBlocksView(blocks: ChatMessageTextFormatter.markdownBlocks(text), fontSize: fontSize)
                // One scroll area for the whole reply: code and tables inside
                // show their full height instead of nesting a second
                // vertical scroller.
                .environment(\.islandMarkdownCapsBlockHeight, false)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(IslandMarkdownStyle.link)
    }
}

/// A scroll area that hugs its content and stops growing where the panel
/// window ends — the completion card's reply, a question card's options.
/// Its height is capped by what the window leaves once the rest of the card
/// is laid out (CompletionReplyMetrics.maxHeight); longer content scrolls
/// inside it instead of running off the bottom of the window.
struct PanelFittedScrollArea<Content: View>: View {
    let minimumHeight: CGFloat
    @ViewBuilder let content: Content
    @AppStorage(SettingsKey.maxVisibleSessions) private var maxVisibleSessions = SettingsDefaults.maxVisibleSessions
    @AppStorage(SettingsKey.maxPanelHeight) private var maxPanelHeight = SettingsDefaults.maxPanelHeight
    @Environment(CompletionCardSpace.self) private var space: CompletionCardSpace?

    var body: some View {
        let maxHeight = CompletionReplyMetrics.maxHeight(
            windowHeight: space?.windowHeight ?? 0,
            chrome: space?.chrome,
            maxVisibleSessions: maxVisibleSessions,
            maxPanelHeight: maxPanelHeight,
            minimumHeight: minimumHeight
        )
        ScrollView(.vertical) {
            content
        }
        // Order matters: fixedSize proposes no height, so the ScrollView
        // reports its content's height and the frame clamps that — the area
        // hugs short content and stops growing at maxHeight.
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        // Found in the panel by NotchPanelView, which measures the rest of
        // the card around it (recordsCompletionCardChrome).
        .anchorPreference(key: CompletionReplyBounds.self, value: .bounds) { [$0] }
        .scrollIndicatorsFlash(onAppear: true)
    }
}

/// How much room the completion card has, measured by NotchPanelView: the
/// panel window's height (already clamped to the screen) and the rest of the
/// card around the reply. Observable rather than view state so a change only
/// re-renders the reply that reads it, not the whole panel.
@MainActor
@Observable
final class CompletionCardSpace {
    private(set) var windowHeight: CGFloat = 0
    /// nil until a panel showing a reply has been measured.
    private(set) var chrome: CompletionCardChrome?
    @ObservationIgnored private var refits = CompletionCardRefitLimiter()

    func recordWindowHeight(_ height: CGFloat) {
        if windowHeight != height { windowHeight = height }
    }

    func recordChrome(_ measured: CompletionCardChrome, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        // A panel without a reply says nothing about a reply's room.
        guard measured.replies > 0, measured != chrome else { return }
        guard refits.allows(at: now) else {
            if refits.justTripped {
                log.error("completion card re-fit loop stopped at \(measured.height, privacy: .public)pt chrome, \(measured.replies, privacy: .public) replies")
            }
            return
        }
        chrome = measured
    }
}

/// Everything in the expanded panel except its completion replies, and how
/// many replies share the room that leaves. Measured in one layout pass from
/// the panel and the replies in it, so a reply growing or shrinking leaves it
/// unchanged: no reply's cap depends on its own height (#357).
struct CompletionCardChrome: Equatable {
    var height: CGFloat
    var replies: Int
}

/// The bounds of every completion reply in the panel. Normally one.
struct CompletionReplyBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

extension View {
    /// Records this view's height minus the completion replies inside it, both
    /// read from the same layout pass, as the card's chrome in `space`. Put on
    /// the expanded panel, whose replies size themselves from it.
    func recordsCompletionCardChrome(in space: CompletionCardSpace) -> some View {
        backgroundPreferenceValue(CompletionReplyBounds.self) { replies in
            GeometryReader { panel in
                let chrome = CompletionCardChrome(
                    height: replies.reduce(panel.size.height) { $0 - panel[$1].height },
                    replies: replies.count
                )
                Color.clear.onChange(of: chrome, initial: true) { space.recordChrome(chrome) }
            }
        }
    }
}

/// A safety net under the completion card's sizing: caps how often its chrome
/// may change. Settling takes one or two measurements; a layout loop would take
/// thousands a second and hang the main thread, and every hook bridge waiting
/// on it. Past the limit new measurements are dropped until the window has
/// passed, which holds every reply's cap where it is.
struct CompletionCardRefitLimiter {
    static let maxRefits = 8
    static let window: TimeInterval = 1

    private var windowStart = -TimeInterval.infinity
    private var count = 0

    /// True on the first refusal in a window, for logging once.
    var justTripped: Bool { count == Self.maxRefits + 1 }

    /// Whether a new measurement may be taken. `now` is a monotonic time, so
    /// a clock change can't hold the window open.
    mutating func allows(at now: TimeInterval) -> Bool {
        if now - windowStart >= Self.window {
            windowStart = now
            count = 0
        }
        count += 1
        return count <= Self.maxRefits
    }
}

enum CompletionReplyMetrics {
    /// Estimate of everything the card stacks around the reply, used only
    /// until the panel has been measured once.
    static let estimatedChromeHeight: CGFloat = 180
    /// Kept free under the panel so its rounded bottom edge always shows.
    static let bottomMargin: CGFloat = 4
    /// Never squeeze the reply below a few lines.
    static let minimumLines: CGFloat = 3

    static func minimumHeight(lineHeight: CGFloat) -> CGFloat {
        (lineHeight * minimumLines).rounded(.up)
    }

    /// The reply gets whatever the panel window leaves once the rest of the
    /// card is laid out. That rest — notch bar, card header, task progress
    /// (expanded or not), older messages, the recap, the "N sessions" link,
    /// paddings — changes with the notch height, the font size and the
    /// settings, so it is measured, not estimated (CompletionCardChrome). The
    /// window is further capped by the maxPanelHeight setting, which keeps an
    /// auto-opening card from covering half the screen when the session list
    /// is set to "unlimited".
    ///
    /// Content past the window's bottom edge is simply cut, so this is what
    /// keeps the card whole.
    static func maxHeight(
        windowHeight: CGFloat,
        chrome: CompletionCardChrome?,
        maxVisibleSessions: Int,
        maxPanelHeight: Int,
        minimumHeight: CGFloat
    ) -> CGFloat {
        var limit = windowHeight > 0
            ? windowHeight
            : PanelHeightMetrics.desiredHeight(maxVisibleSessions: maxVisibleSessions)
        if maxPanelHeight > 0 {
            limit = min(limit, CGFloat(maxPanelHeight))
        }
        let room = limit - (chrome?.height ?? estimatedChromeHeight) - bottomMargin
        // Replies on screen together share the room. Each taking all of it
        // would count the others as chrome, and they'd chase each other's
        // height without settling (#357).
        let share = room / CGFloat(max(1, chrome?.replies ?? 1))
        return max(minimumHeight, share.rounded(.down))
    }

    /// The message the completion card renders in full: the newest one, when
    /// it's the assistant's — the reply that just finished. Older replies in
    /// the card keep following the line cap.
    static func fullReplyId(in messages: [ChatMessage], isCompletionCard: Bool) -> UUID? {
        guard isCompletionCard, let last = messages.last, !last.isUser else { return nil }
        return last.id
    }

    /// Line cap for the older replies above the finished one: one or two
    /// lines whatever the setting. They are context, and every line they
    /// take is a line less for the reply the card is about.
    static func olderReplyLineLimit(_ setting: Int?) -> Int {
        min(setting ?? 2, 2)
    }

    /// Same for the recap under the chat rows; the tooltip has all of it.
    static let recapLineLimit = 2
}

private struct CapsBlockHeightKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether long code blocks and tables scroll inside their own capped
    /// height. Off inside a view that already scrolls the whole reply.
    var islandMarkdownCapsBlockHeight: Bool {
        get { self[CapsBlockHeightKey.self] }
        set { self[CapsBlockHeightKey.self] = newValue }
    }
}

// MARK: - Style

/// Markdown on the island's black surface. Extends the palette the session
/// cards already use — white at graded opacities plus the green accent —
/// instead of the system's light-mode-first Markdown colours.
enum IslandMarkdownStyle {
    static let body = Color.white.opacity(0.85)
    static let strong = Color.white.opacity(0.95)
    static let muted = Color.white.opacity(0.45)
    static let ordinal = Color.white.opacity(0.55)
    static let hairline = Color.white.opacity(0.14)
    static let quoteBar = Color.white.opacity(0.25)
    static let codeSurface = Color.white.opacity(0.06)
    static let headerSurface = Color.white.opacity(0.08)
    static let stripeSurface = Color.white.opacity(0.03)
    /// Opaque, so a code line scrolled under the language tag doesn't show through.
    static let badgeSurface = Color(white: 0.13)
    static let link = Color(red: 0.45, green: 0.72, blue: 1.0)
    static let inlineCode = Color(red: 0.96, green: 0.74, blue: 0.54)
    static let inlineCodeSurface = Color.white.opacity(0.08)
    static let checked = Color(red: 0.3, green: 0.85, blue: 0.4)

    /// Code and tables sit one point under the prose — the same step the
    /// session card uses for its secondary lines (approval summary, hints).
    static func denseSize(_ fontSize: CGFloat) -> CGFloat { max(10, fontSize - 1) }

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func headingSize(_ level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 3
        case 2: return base + 2
        case 3: return base + 1
        default: return base
        }
    }

    static func blockSpacing(_ fontSize: CGFloat) -> CGFloat { max(3, (fontSize * 0.4).rounded()) }

    private static var lineHeights: [CGFloat: CGFloat] = [:]

    /// Line height of the monospaced system font, to size a scroll area before
    /// SwiftUI has laid its content out.
    static func lineHeight(_ size: CGFloat) -> CGFloat {
        if let cached = lineHeights[size] { return cached }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let height = ceil(NSLayoutManager().defaultLineHeight(for: font))
        lineHeights[size] = height
        return height
    }
}

/// Inline Markdown with the island's code-span colours applied. Kept apart
/// from the Core renderer because colours are SwiftUI attributes; cached for
/// the same reason ChatMessageTextFormatter caches — card bodies re-run on
/// every hover and expand animation.
enum IslandMarkdownInline {
    private static let cacheLimit = 256
    private static var textCache = TextRenderCache<String, AttributedString>(countLimit: cacheLimit)
    private static var truncatingTextCache = TextRenderCache<String, AttributedString>(countLimit: cacheLimit)
    private static var previewCache = TextRenderCache<String, AttributedString>(countLimit: cacheLimit)
    private static var singleLinePreviewCache = TextRenderCache<String, AttributedString>(countLimit: cacheLimit)

    /// Wrapping text (paragraphs, headings, list items).
    static func text(_ source: String) -> AttributedString {
        textCache.value(for: source) {
            styled(ChatMessageTextFormatter.inlineSpans(source), truncates: false)
        }
    }

    /// Single-line text that may be cut with an ellipsis (table cells).
    static func truncatingText(_ source: String) -> AttributedString {
        truncatingTextCache.value(for: source) {
            styled(ChatMessageTextFormatter.inlineSpans(source), truncates: true)
        }
    }

    /// Keyed by the head a preview is built from, not the whole reply.
    static func preview(_ source: String, singleLine: Bool) -> AttributedString {
        let head = MarkdownPreviewText.previewSource(source)
        if singleLine {
            return singleLinePreviewCache.value(for: head) {
                styled(ChatMessageTextFormatter.markdownPreview(head, singleLine: true), truncates: true)
            }
        }
        return previewCache.value(for: head) {
            styled(ChatMessageTextFormatter.markdownPreview(head, singleLine: false), truncates: true)
        }
    }

    /// SwiftUI draws `.code` runs in the monospaced font — which every island
    /// row already uses — so without a colour inline code would be invisible.
    ///
    /// Text that truncates gets the colour but no background: SwiftUI paints
    /// the backgrounds of the runs it cut off onto the "…", leaving a grey
    /// block at the end of the line.
    static func styled(_ text: AttributedString, truncates: Bool) -> AttributedString {
        var result = text
        let codeRanges = result.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        for range in codeRanges {
            result[range].swiftUI.foregroundColor = IslandMarkdownStyle.inlineCode
            if !truncates {
                result[range].swiftUI.backgroundColor = IslandMarkdownStyle.inlineCodeSurface
            }
        }
        return result
    }

}

// MARK: - Blocks

private struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]
    let fontSize: CGFloat
    /// How many lists enclose these blocks; picks the bullet glyph.
    var listDepth = 0

    var body: some View {
        VStack(alignment: .leading, spacing: IslandMarkdownStyle.blockSpacing(fontSize)) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], fontSize: fontSize, listDepth: listDepth)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let fontSize: CGFloat
    let listDepth: Int

    var body: some View {
        switch block {
        case .heading(_, let text) where text.isEmpty:
            // A lone "#" mid-stream; its text arrives with the next chunk.
            EmptyView()
        case .heading(let level, let text):
            Text(IslandMarkdownInline.text(text))
                .font(IslandMarkdownStyle.font(IslandMarkdownStyle.headingSize(level, base: fontSize), weight: .bold))
                .foregroundStyle(IslandMarkdownStyle.strong)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            // Pinned to its full height: the scroll views of neighbouring code
            // blocks and tables are vertically flexible and would otherwise
            // take the space and truncate the prose.
            Text(IslandMarkdownInline.text(text))
                .font(IslandMarkdownStyle.font(fontSize))
                .foregroundStyle(IslandMarkdownStyle.body)
                .fixedSize(horizontal: false, vertical: true)
        case .list(let list):
            MarkdownListView(list: list, fontSize: fontSize, depth: listDepth)
        case .code(let code):
            MarkdownCodeBlockView(block: code, fontSize: fontSize)
        case .table(let table):
            MarkdownTableView(table: table, fontSize: fontSize)
        case .quote(let blocks):
            MarkdownBlocksView(blocks: blocks, fontSize: fontSize, listDepth: listDepth)
                .opacity(0.72)
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(IslandMarkdownStyle.quoteBar)
                        .frame(width: 2)
                }
        case .thematicBreak:
            Rectangle()
                .fill(IslandMarkdownStyle.hairline)
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let list: MarkdownList
    let fontSize: CGFloat
    let depth: Int

    var body: some View {
        let markers = MarkdownListMarker.markers(for: list, depth: depth)
        VStack(alignment: .leading, spacing: max(2, IslandMarkdownStyle.blockSpacing(fontSize) - 1)) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 5) {
                    MarkdownListMarkerView(marker: markers[index], fontSize: fontSize)
                    MarkdownBlocksView(blocks: list.items[index].blocks, fontSize: fontSize, listDepth: depth + 1)
                }
            }
        }
    }
}

/// What sits in front of a list item. Built outside the view body: the
/// padding arithmetic is exactly the kind of ViewBuilder expression that
/// slowed the hover-expand animation in #141.
struct MarkdownListMarker: Equatable {
    /// "•", or a right-aligned "1." padded to the list's widest number so
    /// item text lines up in the monospaced font.
    var label: String?
    var checkbox: MarkdownListItem.Checkbox?

    static let bullets = ["•", "◦", "▪"]

    static func markers(for list: MarkdownList, depth: Int) -> [MarkdownListMarker] {
        let lastNumber = list.start + max(0, list.items.count - 1)
        let width = max(String(list.start).count, String(lastNumber).count)
        return list.items.enumerated().map { index, item in
            let label: String?
            if list.isOrdered {
                let number = String(list.start + index)
                label = String(repeating: " ", count: max(0, width - number.count)) + number + "."
            } else {
                // GitHub drops the bullet in front of a checkbox; so do we.
                label = item.checkbox == nil ? bullets[depth % bullets.count] : nil
            }
            return MarkdownListMarker(label: label, checkbox: item.checkbox)
        }
    }
}

private struct MarkdownListMarkerView: View {
    let marker: MarkdownListMarker
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            if let label = marker.label {
                Text(label)
                    .font(IslandMarkdownStyle.font(fontSize))
                    .foregroundStyle(IslandMarkdownStyle.ordinal)
            }
            if let checkbox = marker.checkbox {
                Text(Image(systemName: checkbox == .checked ? "checkmark.square.fill" : "square"))
                    .font(.system(size: fontSize))
                    .foregroundStyle(checkbox == .checked ? IslandMarkdownStyle.checked : IslandMarkdownStyle.muted)
            }
        }
        .fixedSize()
    }
}

// MARK: - Scrolling

private extension View {
    /// Shared behaviour of the code and table scroll areas.
    ///
    /// Content pins to the top-leading corner: a two-axis ScrollView otherwise
    /// centres content narrower than itself. The horizontal scroller is
    /// `.never` rather than `.hidden`: under "show scroll bars: always" (or
    /// with a mouse attached) `.hidden` still reserves a strip under every
    /// overflowing block — a dead band in a card this compact, and one the
    /// panel's first size pass doesn't account for. The clipped right edge
    /// already says there's more; trackpad or shift-scroll still pans.
    func islandMarkdownScrolling() -> some View {
        defaultScrollAnchor(.topLeading)
            .scrollIndicators(.never, axes: .horizontal)
    }
}

// MARK: - Code blocks

/// Precomputed sizing for a code block: long samples scroll inside a capped
/// height rather than stretching the card off the screen, and absurdly long
/// ones are cut so layout cost stays bounded (the copy button still copies
/// all of it).
struct MarkdownCodeLayout: Equatable {
    static let visibleLines = 14
    static let renderedLines = 800

    let text: String
    let hiddenLines: Int
    let scrollsVertically: Bool

    /// - Parameter capsHeight: false inside a view that already scrolls the
    ///   whole reply (see islandMarkdownCapsBlockHeight).
    init(code: String, capsHeight: Bool = true) {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.renderedLines {
            text = lines.prefix(Self.renderedLines).joined(separator: "\n")
            hiddenLines = lines.count - Self.renderedLines
        } else {
            text = code
            hiddenLines = 0
        }
        scrollsVertically = capsHeight && lines.count > Self.visibleLines
    }
}

private struct MarkdownCodeBlockView: View {
    let block: MarkdownCodeBlock
    let fontSize: CGFloat
    @Environment(\.islandMarkdownCapsBlockHeight) private var capsHeight
    @State private var hovering = false
    @State private var copied = false

    private var codeSize: CGFloat { IslandMarkdownStyle.denseSize(fontSize) }
    private static let padding: CGFloat = 7

    var body: some View {
        let layout = MarkdownCodeLayout(code: block.code, capsHeight: capsHeight)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(layout.scrollsVertically ? [.horizontal, .vertical] : .horizontal) {
                Text(layout.text)
                    .font(IslandMarkdownStyle.font(codeSize))
                    .foregroundStyle(IslandMarkdownStyle.body)
                    .fixedSize()
                    .padding(Self.padding)
            }
            .islandMarkdownScrolling()
            .frame(height: layout.scrollsVertically ? scrollHeight : nil)
            .fixedSize(horizontal: false, vertical: !layout.scrollsVertically)
            if layout.hiddenLines > 0 {
                Text("⋯ +\(layout.hiddenLines)")
                    .font(IslandMarkdownStyle.font(codeSize))
                    .foregroundStyle(IslandMarkdownStyle.muted)
                    .padding(.horizontal, Self.padding)
                    .padding(.bottom, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(IslandMarkdownStyle.codeSurface))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(IslandMarkdownStyle.hairline, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) { badge }
        .onHover { hovering = $0 }
    }

    private var scrollHeight: CGFloat {
        CGFloat(MarkdownCodeLayout.visibleLines) * IslandMarkdownStyle.lineHeight(codeSize) + Self.padding * 2
    }

    /// Language tag at rest, copy button on hover.
    @ViewBuilder private var badge: some View {
        if hovering {
            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: max(9, fontSize - 2), weight: .semibold))
                    .foregroundStyle(copied ? IslandMarkdownStyle.checked : IslandMarkdownStyle.strong)
                    .frame(width: 20, height: 18)
                    .background(RoundedRectangle(cornerRadius: 4).fill(IslandMarkdownStyle.badgeSurface))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.shared["copy_code"])
            .padding(4)
        } else if let language = block.language {
            Text(language)
                .font(IslandMarkdownStyle.font(max(8, fontSize - 3), weight: .medium))
                .foregroundStyle(IslandMarkdownStyle.muted)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(IslandMarkdownStyle.badgeSurface))
                .padding(4)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - Tables

/// One cell of a rendered table, flattened row-major so the grid layout sees
/// a plain list of subviews.
struct MarkdownTableCell: Identifiable {
    let id: Int
    let text: AttributedString
    /// Full cell text for the hover tooltip; nil when the cell is short
    /// enough that it can't have been truncated.
    let tooltip: String?
    let isHeader: Bool
    let alignment: Alignment
    let isStriped: Bool
    let drawsTrailingRule: Bool
    let drawsBottomRule: Bool
}

struct MarkdownTableModel {
    static let visibleRows = 12
    static let renderedRows = 200

    let columnCount: Int
    let cells: [MarkdownTableCell]
    let bodyRowCount: Int
    let hiddenRows: Int

    init(table: MarkdownTable, tooltipThreshold: Int) {
        let rows = Array(table.rows.prefix(Self.renderedRows))
        let allRows = [table.header] + rows
        let columns = table.columnCount
        var cells: [MarkdownTableCell] = []
        cells.reserveCapacity(allRows.count * columns)
        for (rowIndex, row) in allRows.enumerated() {
            for (column, source) in row.enumerated() {
                let text = IslandMarkdownInline.truncatingText(source)
                let plain = String(text.characters)
                cells.append(MarkdownTableCell(
                    id: rowIndex * columns + column,
                    text: text,
                    tooltip: plain.count > tooltipThreshold ? plain : nil,
                    isHeader: rowIndex == 0,
                    alignment: Self.alignment(table.alignments[column]),
                    isStriped: rowIndex > 0 && rowIndex % 2 == 0,
                    drawsTrailingRule: column < columns - 1,
                    drawsBottomRule: rowIndex < allRows.count - 1
                ))
            }
        }
        self.columnCount = columns
        self.cells = cells
        self.bodyRowCount = rows.count
        self.hiddenRows = table.rows.count - rows.count
    }

    private static func alignment(_ alignment: MarkdownTableAlignment) -> Alignment {
        switch alignment {
        case .automatic, .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private enum TableMetrics {
    static let cellPadding: CGFloat = 7
    static let rowPadding: CGFloat = 3
    /// Cells longer than this many characters may be truncated, so they get
    /// a tooltip with the full text; shorter ones skip the tracking area.
    static let tooltipThreshold = 20
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let fontSize: CGFloat
    @Environment(\.islandMarkdownCapsBlockHeight) private var capsHeight

    private var cellSize: CGFloat { IslandMarkdownStyle.denseSize(fontSize) }
    /// About 24 characters: wide enough for a file path or a short phrase,
    /// narrow enough that two or three columns fit the card without scrolling.
    private var maxColumnWidth: CGFloat { (cellSize * 0.6 * 24).rounded() + TableMetrics.cellPadding * 2 }

    var body: some View {
        let model = MarkdownTableModel(table: table, tooltipThreshold: TableMetrics.tooltipThreshold)
        let scrollsVertically = capsHeight && model.bodyRowCount > MarkdownTableModel.visibleRows
        VStack(alignment: .leading, spacing: 3) {
            ScrollView(scrollsVertically ? [.horizontal, .vertical] : .horizontal) {
                MarkdownTableLayout(columnCount: model.columnCount, maxColumnWidth: maxColumnWidth) {
                    ForEach(model.cells) { cell in
                        MarkdownTableCellView(cell: cell, fontSize: cellSize)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(IslandMarkdownStyle.hairline, lineWidth: 0.5))
            }
            .islandMarkdownScrolling()
            .frame(height: scrollsVertically ? scrollHeight : nil)
            .fixedSize(horizontal: false, vertical: !scrollsVertically)
            if model.hiddenRows > 0 {
                Text("⋯ +\(model.hiddenRows)")
                    .font(IslandMarkdownStyle.font(cellSize))
                    .foregroundStyle(IslandMarkdownStyle.muted)
            }
        }
    }

    private var scrollHeight: CGFloat {
        let row = IslandMarkdownStyle.lineHeight(cellSize) + TableMetrics.rowPadding * 2
        return CGFloat(MarkdownTableModel.visibleRows + 1) * row
    }
}

private struct MarkdownTableCellView: View {
    let cell: MarkdownTableCell
    let fontSize: CGFloat

    var body: some View {
        Text(cell.text)
            .font(IslandMarkdownStyle.font(fontSize, weight: cell.isHeader ? .semibold : .regular))
            .foregroundStyle(cell.isHeader ? IslandMarkdownStyle.strong : IslandMarkdownStyle.body)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, TableMetrics.cellPadding)
            .padding(.vertical, TableMetrics.rowPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cell.alignment)
            .background(background)
            .overlay(alignment: .trailing) {
                if cell.drawsTrailingRule {
                    Rectangle().fill(IslandMarkdownStyle.hairline).frame(width: 0.5)
                }
            }
            .overlay(alignment: .bottom) {
                if cell.drawsBottomRule {
                    Rectangle().fill(IslandMarkdownStyle.hairline).frame(height: 0.5)
                }
            }
            .modifier(OptionalHelp(text: cell.tooltip))
    }

    private var background: Color {
        if cell.isHeader { return IslandMarkdownStyle.headerSurface }
        return cell.isStriped ? IslandMarkdownStyle.stripeSurface : .clear
    }
}

private struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// Sizes each column to its widest cell, capped at `maxColumnWidth`, then
/// proposes every cell exactly its column's width so an over-long cell
/// truncates with an ellipsis. SwiftUI's Grid can't do that inside a
/// horizontal ScrollView: it proposes no width there, and a cell capped with
/// `.frame(maxWidth:)` then overflows its column instead of truncating.
struct MarkdownTableLayout: Layout {
    let columnCount: Int
    let maxColumnWidth: CGFloat

    struct Metrics {
        var columnWidths: [CGFloat] = []
        var rowHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Metrics {
        measure(subviews)
    }

    func updateCache(_ cache: inout Metrics, subviews: Subviews) {
        cache = measure(subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics) -> CGSize {
        CGSize(width: cache.columnWidths.reduce(0, +), height: cache.rowHeights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics) {
        var y = bounds.minY
        for (row, height) in cache.rowHeights.enumerated() {
            var x = bounds.minX
            for (column, width) in cache.columnWidths.enumerated() {
                let index = row * columnCount + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: height)
                )
                x += width
            }
            y += height
        }
    }

    private func measure(_ subviews: Subviews) -> Metrics {
        guard columnCount > 0, !subviews.isEmpty else { return Metrics() }
        var widths = Array(repeating: CGFloat(0), count: columnCount)
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified).width
            widths[index % columnCount] = max(widths[index % columnCount], min(ideal, maxColumnWidth))
        }
        widths = widths.map { $0.rounded(.up) }

        let rowCount = (subviews.count + columnCount - 1) / columnCount
        var heights = Array(repeating: CGFloat(0), count: rowCount)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columnCount], height: nil)).height
            heights[index / columnCount] = max(heights[index / columnCount], height.rounded(.up))
        }
        return Metrics(columnWidths: widths, rowHeights: heights)
    }
}
