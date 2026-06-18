import CoreGraphics

/// 单个会话行的视觉步进高度（行高约 58 + 行间距 8），用于按可用高度估算可见行数。
let standbySessionRowStride: CGFloat = 66

/// 看板标题区 + 顶部内边距的预留高度。
let standbySessionBoardHeaderHeight: CGFloat = 44

/// 看板区宽度达到该阈值时使用双列。
let standbyTwoColumnMinWidth: CGFloat = 560

/// 看板区列数：宽度达到阈值用双列，否则单列。
func standbyColumnCount(boardWidth: CGFloat) -> Int {
    boardWidth >= standbyTwoColumnMinWidth ? 2 : 1
}

/// 根据看板区可用尺寸，计算最多可见的会话行数（每列至少 1 行）。
func standbyVisibleSessionCount(boardSize: CGSize) -> Int {
    let columns = standbyColumnCount(boardWidth: boardSize.width)
    let usableHeight = max(0, boardSize.height - standbySessionBoardHeaderHeight)
    let rowsPerColumn = max(1, Int(usableHeight / standbySessionRowStride))
    return rowsPerColumn * columns
}
