import CoreGraphics

/// 单条会话在「消息 1 行」时的行高 + 行间距，作为容纳行数的基本单位。
let standbySessionRowStride: CGFloat = 66

/// 看板标题区 + 顶部内边距的预留高度。
let standbySessionBoardHeaderHeight: CGFloat = 44

/// 消息每多一行增加的高度。
let standbySessionMessageLineHeight: CGFloat = 17

/// 单条会话消息最多显示的行数。
let standbyMaxMessageLines = 3

/// 看板的自适应布局：显示几条会话、每条消息最多几行。
struct StandBySessionBoardLayout: Equatable {
    let visibleCount: Int
    let messageLineLimit: Int
}

/// 依据看板可用高度与会话总数，决定显示几条会话以及每条消息的行数上限。
///
/// 会话少且空间充裕时每条最多 3 行；会话变多时逐步压缩到 1 行；
/// 即使按 1 行也放不下时，只显示能放下的条数（其余由调用方显示「还有 N 个」）。
func standbySessionBoardLayout(boardHeight: CGFloat, sessionCount: Int) -> StandBySessionBoardLayout {
    let usable = max(0, boardHeight - standbySessionBoardHeaderHeight)
    let maxRows = max(1, Int(usable / standbySessionRowStride))
    let visible = max(1, min(sessionCount, maxRows))
    let perRow = usable / CGFloat(visible)
    let extraLines = Int((perRow - standbySessionRowStride) / standbySessionMessageLineHeight)
    let messageLineLimit = min(standbyMaxMessageLines, max(1, 1 + extraLines))
    return StandBySessionBoardLayout(visibleCount: visible, messageLineLimit: messageLineLimit)
}
