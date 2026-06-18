import CoreGraphics

/// 单个会话行的视觉步进高度（行高约 58 + 行间距 8），用于按可用高度估算可见行数。
let standbySessionRowStride: CGFloat = 66

/// 看板标题区 + 顶部内边距的预留高度。
let standbySessionBoardHeaderHeight: CGFloat = 44

/// 根据看板区可用高度，计算单列最多可见的会话行数（至少 1 行）。
func standbyVisibleSessionCount(boardHeight: CGFloat) -> Int {
    let usableHeight = max(0, boardHeight - standbySessionBoardHeaderHeight)
    return max(1, Int(usableHeight / standbySessionRowStride))
}
