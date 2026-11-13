import SwiftUI
import AppKit
import CodeIslandCore

// MARK: - 1. Modern Minimalist Palette (Obsidian / Zinc)

private enum ModernPalette {
    static let base = Color(red: 0.055, green: 0.065, blue: 0.08)       // #0E1014 deep zinc
    static let surface = Color.white.opacity(0.035)                      // Subtle card fill
    static let border = Color.white.opacity(0.07)                        // Hairline border
    static let borderSubtle = Color.white.opacity(0.05)

    // Text Hierarchy
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.60)
    static let textMuted = Color.white.opacity(0.38)

    // Intentional Accents
    static let sage = Color(red: 0.22, green: 0.78, blue: 0.52)         // Clean / HEAD indicator
    static let amber = Color(red: 0.94, green: 0.64, blue: 0.20)        // Modified / Uncommitted
}

// MARK: - 2. Minimalist Modern Pixel Palette (Tab Phosphor Green & Warm Amber)
// Dominant Accent: Tab Green (Color(red: 0.12, green: 0.84, blue: 0.38)) matching CodeIsland's signature active tabs.
// Deep terminal base, crisp readable typography, and intentional warm amber contrast for modified states.

private enum MinimalPixelPalette {
    static let base = Color(red: 0.04, green: 0.06, blue: 0.05)         // #0A0F0D Deep Terminal Dark
    static let surface = Color(red: 0.07, green: 0.11, blue: 0.09)      // #121C17 Clean slot surface
    static let border = Color(red: 0.13, green: 0.22, blue: 0.17)       // #21382B Hairline 1px border

    // Typography
    static let textWhite = Color(red: 0.95, green: 0.98, blue: 0.96)     // #F2FAF5 Crisp readable white
    static let textMuted = Color(red: 0.52, green: 0.66, blue: 0.58)     // #85A894 Soft sage secondary
    static let textDim = Color(red: 0.30, green: 0.42, blue: 0.35)       // #4D6B59 Dim details

    // Dominant Signature Accent: Tab Green (exact match to CodeIsland active tab)
    static let green = Color(red: 0.12, green: 0.84, blue: 0.38)        // #1FD661 Tab Green

    // Contrast Accent: Warm Amber (Modified / Uncommitted / Behind)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.20)        // #FFB833 Warm Terminal Amber
}

// MARK: - Vector Pixel Art Icon Renderer (9×9 Matrix)

enum WorkspacePixelGlyph {
    case folder
    case branch
    case sparkle
    case push
    case sync
    case check
    case modified
    case commitNode
    case disk
}

struct WorkspacePixelIcon: View {
    let glyph: WorkspacePixelGlyph
    let color: Color
    var pixelSize: CGFloat = 1.2

    private var matrix: (w: Int, h: Int, data: [UInt8]) {
        switch glyph {
        case .folder:
            return (9, 9, [
                1,1,1,1,0,0,0,0,0,
                1,0,0,1,1,1,1,1,0,
                1,1,1,1,1,1,1,1,1,
                1,0,0,0,0,0,0,0,1,
                1,0,1,1,1,1,1,0,1,
                1,0,0,0,0,0,0,0,1,
                1,0,1,1,1,1,1,0,1,
                1,0,0,0,0,0,0,0,1,
                1,1,1,1,1,1,1,1,1
            ])
        case .branch:
            return (9, 9, [
                0,0,0,1,1,1,0,0,0,
                0,0,0,1,0,1,0,0,0,
                0,0,0,1,1,1,0,1,0,
                0,0,1,0,0,0,1,1,0,
                0,1,0,0,0,0,1,0,0,
                0,1,0,0,0,0,1,0,0,
                1,1,1,0,0,0,1,0,0,
                1,0,1,0,0,0,1,0,0,
                1,1,1,0,0,0,1,0,0
            ])
        case .sparkle:
            return (9, 9, [
                0,0,0,0,1,0,0,0,0,
                0,0,0,1,1,1,0,0,0,
                0,0,1,1,1,1,1,0,0,
                0,1,1,1,1,1,1,1,0,
                1,1,1,1,0,1,1,1,1,
                0,1,1,1,1,1,1,1,0,
                0,0,1,1,1,1,1,0,0,
                0,0,0,1,1,1,0,0,0,
                0,0,0,0,1,0,0,0,0
            ])
        case .push:
            return (9, 9, [
                0,0,0,0,1,0,0,0,0,
                0,0,0,1,1,1,0,0,0,
                0,0,1,1,1,1,1,0,0,
                0,1,1,0,1,0,1,1,0,
                1,1,0,0,1,0,0,1,1,
                0,0,0,0,1,0,0,0,0,
                0,0,0,0,1,0,0,0,0,
                0,0,0,0,1,0,0,0,0,
                1,1,1,1,1,1,1,1,1
            ])
        case .sync:
            return (9, 9, [
                0,0,1,1,1,1,1,0,0,
                0,1,1,0,0,0,1,1,0,
                1,1,0,0,1,0,0,1,1,
                1,1,0,1,1,0,0,0,0,
                1,1,0,0,0,0,1,1,1,
                0,0,0,0,1,1,0,1,1,
                1,1,0,0,1,0,0,1,1,
                0,1,1,0,0,0,1,1,0,
                0,0,1,1,1,1,1,0,0
            ])
        case .check:
            return (9, 9, [
                0,0,0,0,0,0,0,0,1,
                0,0,0,0,0,0,0,1,1,
                0,0,0,0,0,0,1,1,0,
                0,0,0,0,0,1,1,0,0,
                1,0,0,0,1,1,0,0,0,
                1,1,0,1,1,0,0,0,0,
                0,1,1,1,0,0,0,0,0,
                0,0,1,0,0,0,0,0,0,
                0,0,0,0,0,0,0,0,0
            ])
        case .modified:
            return (9, 9, [
                0,0,0,0,1,0,0,0,0,
                0,0,0,1,1,1,0,0,0,
                0,0,0,1,1,1,0,0,0,
                0,0,1,1,0,1,1,0,0,
                0,0,1,1,0,1,1,0,0,
                0,1,1,1,0,1,1,1,0,
                0,1,1,1,1,1,1,1,0,
                1,1,1,1,0,1,1,1,1,
                1,1,1,1,1,1,1,1,1
            ])
        case .commitNode:
            return (9, 9, [
                0,0,1,1,1,1,1,0,0,
                0,1,1,1,1,1,1,1,0,
                1,1,0,0,0,0,0,1,1,
                1,1,0,1,1,1,0,1,1,
                1,1,0,1,1,1,0,1,1,
                1,1,0,1,1,1,0,1,1,
                1,1,0,0,0,0,0,1,1,
                0,1,1,1,1,1,1,1,0,
                0,0,1,1,1,1,1,0,0
            ])
        case .disk:
            return (9, 9, [
                1,1,1,1,1,1,1,1,0,
                1,1,0,0,0,0,1,1,1,
                1,1,0,0,0,0,1,1,1,
                1,1,1,1,1,1,1,1,1,
                1,0,0,0,0,0,0,0,1,
                1,0,1,1,1,1,1,0,1,
                1,0,1,0,0,0,1,0,1,
                1,0,1,0,0,0,1,0,1,
                1,1,1,1,1,1,1,1,1
            ])
        }
    }

    var body: some View {
        let (w, h, data) = matrix
        Canvas { context, _ in
            for row in 0..<h {
                for col in 0..<w {
                    if data[row * w + col] == 1 {
                        let rect = CGRect(
                            x: CGFloat(col) * pixelSize,
                            y: CGFloat(row) * pixelSize,
                            width: pixelSize,
                            height: pixelSize
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
        }
        .frame(width: CGFloat(matrix.w) * pixelSize, height: CGFloat(matrix.h) * pixelSize)
    }
}

// MARK: - Modern Git Graph Item

struct ModernGitGraphItemView: View {
    let commit: GitCommitItem
    let isLatest: Bool
    let isLast: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Visual spine + node
            VStack(spacing: 0) {
                ZStack {
                    if isLatest {
                        Circle()
                            .stroke(Color.white.opacity(0.75), lineWidth: 1.5)
                            .frame(width: 9, height: 9)
                        Circle()
                            .fill(ModernPalette.sage)
                            .frame(width: 4, height: 4)
                    } else {
                        Circle()
                            .fill(Color.white.opacity(0.28))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(width: 12, height: 12)

                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 22)
                }
            }
            .frame(width: 12)

            // Commit text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(commit.hash)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isLatest ? Color.white.opacity(0.90) : ModernPalette.textSecondary)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)))

                    if !commit.refs.isEmpty {
                        Text(commit.refs)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.80))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                            )
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Text(commit.author)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(ModernPalette.textSecondary)

                    Text("• \(commit.timeAgo)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(ModernPalette.textMuted)
                }

                Text(commit.message)
                    .font(.system(size: 11.5, weight: isLatest ? .medium : .regular, design: .monospaced))
                    .foregroundStyle(isLatest ? ModernPalette.textPrimary : ModernPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? ModernPalette.surface : Color.clear)
        )
        .onHover { isHovered = $0 }
        .help("\(commit.hash) • \(commit.author)\n\(commit.message)")
    }
}

// MARK: - Modern Active Agent Pill

struct ModernActiveAgentPill: View {
    var appState: AppState
    let cwd: String

    private var activeSession: SessionSnapshot? {
        guard !cwd.isEmpty else { return nil }
        return appState.sessions.values.first { $0.cwd == cwd }
    }

    var body: some View {
        if let session = activeSession {
            HStack(spacing: 5) {
                if let icon = cliIcon(source: session.source, size: 11) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: "cpu")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(ModernPalette.textSecondary)
                }

                let name = session.mascotSource.isEmpty ? session.source.uppercased() : session.mascotSource.uppercased()
                Text(name)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ModernPalette.textPrimary)

                if let model = session.modelLabel ?? session.model, !model.isEmpty {
                    Text("• \(model)")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(ModernPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ModernPalette.borderSubtle, lineWidth: 0.6))
            )
        }
    }
}

// MARK: - 1. Modern Workspace View (Obsidian / Zinc Minimalist)

struct ModernWorkspaceView: View {
    @ObservedObject var manager: WorkspaceMonitorManager
    var appState: AppState

    @State private var switchFolderHovered = false
    @State private var refreshHovered = false
    @State private var terminalHovered = false
    @State private var aiHovered = false
    @State private var pushHovered = false

    private var railColor: Color {
        if !manager.isGitRepo                 { return Color.white.opacity(0.18) }
        else if manager.isCommitting          { return Color.white.opacity(0.60) }
        else if !manager.changedFiles.isEmpty { return ModernPalette.amber }
        else                                  { return ModernPalette.sage }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isGitRepo {
                // Non-Git state
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 20))
                        .foregroundStyle(ModernPalette.textSecondary)

                    Text("NO GIT REPOSITORY DETECTED")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ModernPalette.textPrimary)

                    Text(manager.currentCwd.isEmpty ? "No active workspace folder selected" : manager.currentCwd)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(ModernPalette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9.5))
                            Text("SELECT WORKSPACE FOLDER")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        }
                        .foregroundStyle(Color.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 4.5).fill(Color.white.opacity(0.92)))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .padding(.vertical, 12)

            } else {
                VStack(spacing: 9) {

                    // ── BREADCRUMB HEADER ──────────────────────────────────────
                    HStack(alignment: .center, spacing: 7) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.70))

                            Text(manager.projectName.isEmpty ? "WORKSPACE" : manager.projectName)
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(ModernPalette.textPrimary)
                                .lineLimit(1)

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                manager.chooseWorkspaceFolder()
                            }) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(switchFolderHovered ? Color.white : Color.white.opacity(0.35))
                                    .padding(2.5)
                                    .background(Circle().fill(Color.white.opacity(switchFolderHovered ? 0.12 : 0)))
                            }
                            .buttonStyle(.plain)
                            .onHover { switchFolderHovered = $0 }
                            .help("Switch workspace directory")
                        }

                        Text("/")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.22))

                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.50))

                            Text(manager.branch)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.85))
                                .lineLimit(1)

                            if manager.aheadCount > 0 || manager.behindCount > 0 {
                                HStack(spacing: 2) {
                                    if manager.aheadCount > 0 {
                                        Text("↑\(manager.aheadCount)")
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(0.75))
                                    }
                                    if manager.behindCount > 0 {
                                        Text("↓\(manager.behindCount)")
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(ModernPalette.amber)
                                    }
                                }
                                .padding(.horizontal, 3.5)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.08)))
                            }
                        }

                        Text("·")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.20))

                        if manager.changedFiles.isEmpty {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(ModernPalette.sage)
                                    .frame(width: 4.5, height: 4.5)
                                Text("clean")
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(ModernPalette.textSecondary)
                            }
                        } else {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(ModernPalette.amber)
                                    .frame(width: 4.5, height: 4.5)
                                Text("\(manager.changedFiles.count) modified")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ModernPalette.amber)
                            }
                        }

                        Spacer(minLength: 6)

                        ModernActiveAgentPill(appState: appState, cwd: manager.currentCwd)

                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }) {
                            Group {
                                if manager.isRefreshing {
                                    ProgressView()
                                        .scaleEffect(0.35)
                                        .frame(width: 10, height: 10)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 9, weight: .medium))
                                }
                            }
                            .foregroundStyle(refreshHovered ? Color.white : Color.white.opacity(0.45))
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(refreshHovered ? 0.08 : 0)))
                        }
                        .buttonStyle(.plain)
                        .onHover { refreshHovered = $0 }
                        .help("Refresh git status")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.025))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ModernPalette.borderSubtle, lineWidth: 0.6))
                    )

                    // ── GIT GRAPH TIMELINE ─────────────────────────────────────
                    VStack(alignment: .leading, spacing: 2) {
                        if manager.recentCommits.isEmpty {
                            VStack(spacing: 3) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 13))
                                    .foregroundStyle(ModernPalette.textMuted)
                                Text("No recent commits recorded")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(ModernPalette.textMuted)
                            }
                            .frame(maxWidth: .infinity, minHeight: 55)
                        } else {
                            ForEach(Array(manager.recentCommits.prefix(3).enumerated()), id: \.element.id) { index, commit in
                                ModernGitGraphItemView(
                                    commit: commit,
                                    isLatest: index == 0,
                                    isLast: index == min(2, manager.recentCommits.count - 1)
                                )
                            }
                        }
                    }

                    // ── ACTION BAR ──────────────────────────────────────────────
                    if manager.changedFiles.isEmpty {
                        HStack(spacing: 8) {
                            Text(manager.currentCwd)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(ModernPalette.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ModernPalette.sage)
                                    .transition(.opacity)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                NSWorkspace.shared.open(URL(fileURLWithPath: manager.currentCwd))
                            }) {
                                HStack(spacing: 3.5) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 8.5))
                                    Text("OPEN FOLDER")
                                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                }
                                .foregroundStyle(terminalHovered ? Color.white : ModernPalette.textSecondary)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(terminalHovered ? 0.08 : 0.04)))
                            }
                            .buttonStyle(.plain)
                            .onHover { terminalHovered = $0 }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)

                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        manager.generateAICommitMessage()
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 8.5, weight: .semibold))
                                        Text("AI")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    }
                                    .foregroundStyle(aiHovered ? Color.white : Color.white.opacity(0.80))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4.5)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(aiHovered ? 0.12 : 0.06)))
                                }
                                .buttonStyle(.plain)
                                .onHover { aiHovered = $0 }
                                .help("Auto-generate conventional commit message")

                                ZStack(alignment: .leading) {
                                    if manager.proposedCommitMessage.isEmpty {
                                        Text("Commit message...")
                                            .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                            .foregroundStyle(Color.white.opacity(0.50))
                                            .padding(.horizontal, 8)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $manager.proposedCommitMessage)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                        .foregroundStyle(ModernPalette.textPrimary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4.5)
                                }
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.05))
                                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.7))
                                )

                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                                }) {
                                    Text(manager.isCommitting ? "..." : "Commit")
                                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(manager.proposedCommitMessage.isEmpty ? Color.white.opacity(0.42) : Color.black)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(manager.proposedCommitMessage.isEmpty ? Color.white.opacity(0.08) : Color.white.opacity(0.92))
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)

                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                                }) {
                                    HStack(spacing: 2.5) {
                                        Text("Push")
                                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 7, weight: .bold))
                                    }
                                    .foregroundStyle(pushHovered ? Color.white : ModernPalette.textSecondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(Color.white.opacity(pushHovered ? 0.12 : 0.05))
                                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ModernPalette.borderSubtle, lineWidth: 0.6))
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { pushHovered = $0 }
                            }
                            .padding(.horizontal, 4)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(ModernPalette.sage)
                                    .padding(.horizontal, 6)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9).fill(ModernPalette.base)
                // 1px status rail
                Rectangle().fill(railColor).frame(width: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(ModernPalette.border, lineWidth: 0.8)
            )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - 2. Minimalist Modern Pixel Workspace View
// Clean, minimal, low cognitive load. Zero clutter.
// Palette: Deep Midnight Navy with Electric Ice Cyan (#38BDF8) & Emerald Sage (#34D399).
// Crisp vector pixel art icons, generous breathing room, no nested boxes.

struct PixelRetroWorkspaceView: View {
    @ObservedObject var manager: WorkspaceMonitorManager
    var appState: AppState

    @State private var switchHovered = false
    @State private var refreshHovered = false
    @State private var aiHovered = false
    @State private var commitHovered = false
    @State private var pushHovered = false
    @State private var openHovered = false

    private var activeSession: SessionSnapshot? {
        guard !manager.currentCwd.isEmpty else { return nil }
        return appState.sessions.values.first { $0.cwd == manager.currentCwd }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isGitRepo {
                // Non-Git State: Minimal & Clean
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        WorkspacePixelIcon(glyph: .folder, color: MinimalPixelPalette.green, pixelSize: 1.3)
                        Text("NO REPOSITORY DETECTED")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(MinimalPixelPalette.textWhite)
                    }

                    Text(manager.currentCwd.isEmpty ? "Select a project directory" : manager.currentCwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(MinimalPixelPalette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        HStack(spacing: 6) {
                            WorkspacePixelIcon(glyph: .folder, color: Color.black, pixelSize: 1.1)
                            Text("CHOOSE FOLDER")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.black)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4.5)
                        .background(Rectangle().fill(MinimalPixelPalette.green))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 105)
                .padding(.vertical, 10)

            } else {
                VStack(spacing: 8) {

                    // ========================================================
                    // 1. MINIMAL HEADER STRIP (CLEAN, SPACIOUS, UNCLUTTERED)
                    // ========================================================
                    HStack(alignment: .center, spacing: 6) {
                        // Project Name + Switcher
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.chooseWorkspaceFolder()
                        }) {
                            HStack(spacing: 5) {
                                WorkspacePixelIcon(
                                    glyph: .folder,
                                    color: switchHovered ? Color.white : MinimalPixelPalette.green,
                                    pixelSize: 1.2
                                )

                                Text(manager.projectName.isEmpty ? "WORKSPACE" : manager.projectName)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(switchHovered ? Color.white : MinimalPixelPalette.textWhite)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .onHover { switchHovered = $0 }
                        .help("Switch workspace directory")

                        Text("·")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(MinimalPixelPalette.textDim)

                        // Branch
                        HStack(spacing: 4) {
                            WorkspacePixelIcon(glyph: .branch, color: MinimalPixelPalette.green.opacity(0.85), pixelSize: 1.1)

                            Text(manager.branch)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(MinimalPixelPalette.green)
                                .lineLimit(1)

                            if manager.aheadCount > 0 || manager.behindCount > 0 {
                                HStack(spacing: 2) {
                                    if manager.aheadCount > 0 {
                                        Text("↑\(manager.aheadCount)")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(MinimalPixelPalette.green)
                                    }
                                    if manager.behindCount > 0 {
                                        Text("↓\(manager.behindCount)")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(MinimalPixelPalette.amber)
                                    }
                                }
                            }
                        }

                        Text("·")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(MinimalPixelPalette.textDim)

                        // State (Clean vs Modified)
                        if manager.changedFiles.isEmpty {
                            HStack(spacing: 3.5) {
                                WorkspacePixelIcon(glyph: .check, color: MinimalPixelPalette.green, pixelSize: 1.0)
                                Text("clean")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(MinimalPixelPalette.green)
                            }
                        } else {
                            HStack(spacing: 3.5) {
                                WorkspacePixelIcon(glyph: .modified, color: MinimalPixelPalette.amber, pixelSize: 1.0)
                                Text("\(manager.changedFiles.count) modified")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(MinimalPixelPalette.amber)
                            }
                        }

                        Spacer(minLength: 4)

                        // Active Agent Pill
                        if let session = activeSession {
                            HStack(spacing: 4) {
                                if let icon = cliIcon(source: session.source, size: 9) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 9, height: 9)
                                }
                                Text(session.source.uppercased())
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(MinimalPixelPalette.textWhite)

                                if let model = session.modelLabel ?? session.model, !model.isEmpty {
                                    Text("[\(model)]")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(MinimalPixelPalette.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Rectangle().fill(MinimalPixelPalette.surface))
                        }

                        // Refresh Button
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }) {
                            WorkspacePixelIcon(
                                glyph: .sync,
                                color: refreshHovered ? MinimalPixelPalette.green : MinimalPixelPalette.textDim,
                                pixelSize: 1.1
                            )
                            .padding(2)
                        }
                        .buttonStyle(.plain)
                        .onHover { refreshHovered = $0 }
                        .help("Refresh git status")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)

                    // ========================================================
                    // 2. MINIMAL GIT TIMELINE (TOP 2 COMMITS WITH PIXEL NODES)
                    // ========================================================
                    VStack(alignment: .leading, spacing: 3) {
                        if manager.recentCommits.isEmpty {
                            Text("No recent commits")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(MinimalPixelPalette.textDim)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(Array(manager.recentCommits.prefix(2).enumerated()), id: \.element.id) { index, commit in
                                HStack(alignment: .center, spacing: 6) {
                                    // Pixel Node
                                    if index == 0 {
                                        // HEAD: Sharp Tab Green Node
                                        Rectangle()
                                            .fill(MinimalPixelPalette.green)
                                            .frame(width: 5, height: 5)
                                    } else {
                                        // Previous: Hollow Dim Node
                                        Rectangle()
                                            .stroke(MinimalPixelPalette.green.opacity(0.35), lineWidth: 1)
                                            .frame(width: 4, height: 4)
                                    }

                                    // Hash Pill
                                    Text(commit.hash)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(index == 0 ? MinimalPixelPalette.green : MinimalPixelPalette.textMuted)
                                        .padding(.horizontal, 3.5)
                                        .padding(.vertical, 1)
                                        .background(Rectangle().fill(MinimalPixelPalette.surface))

                                    // Message
                                    Text(commit.message)
                                        .font(.system(size: 10.5, weight: index == 0 ? .medium : .regular, design: .monospaced))
                                        .foregroundStyle(index == 0 ? MinimalPixelPalette.textWhite : MinimalPixelPalette.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.tail)

                                    Spacer(minLength: 2)

                                    // Time
                                    Text(commit.timeAgo)
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(MinimalPixelPalette.textDim)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    // ========================================================
                    // 3. ACTION BAR (CLEAN, MINIMAL, INTEGRATED)
                    // ========================================================
                    if manager.changedFiles.isEmpty {
                        // Clean State: Path Hint & Open Button
                        HStack(spacing: 8) {
                            Text(manager.currentCwd)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(MinimalPixelPalette.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(MinimalPixelPalette.green)
                                    .transition(.opacity)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                NSWorkspace.shared.open(URL(fileURLWithPath: manager.currentCwd))
                            }) {
                                HStack(spacing: 4) {
                                    WorkspacePixelIcon(glyph: .folder, color: openHovered ? Color.black : MinimalPixelPalette.green, pixelSize: 1.0)
                                    Text("OPEN")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(openHovered ? Color.black : MinimalPixelPalette.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Rectangle().fill(openHovered ? MinimalPixelPalette.green : MinimalPixelPalette.surface))
                                .overlay(Rectangle().stroke(MinimalPixelPalette.green.opacity(0.4), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { openHovered = $0 }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)

                    } else {
                        // Uncommitted Input Row: Sleek & Compact
                        HStack(spacing: 5) {
                            // AI Suggest Button
                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    manager.generateAICommitMessage()
                                }
                            }) {
                                HStack(spacing: 3) {
                                    WorkspacePixelIcon(glyph: .sparkle, color: aiHovered ? Color.black : MinimalPixelPalette.green, pixelSize: 1.0)
                                    Text("AI")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(aiHovered ? Color.black : MinimalPixelPalette.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3.5)
                                .background(Rectangle().fill(aiHovered ? MinimalPixelPalette.green : MinimalPixelPalette.surface))
                                .overlay(Rectangle().stroke(MinimalPixelPalette.green.opacity(0.5), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { aiHovered = $0 }
                            .help("Auto-generate conventional commit message")

                            // Input Box
                            ZStack(alignment: .leading) {
                                if manager.proposedCommitMessage.isEmpty {
                                    Text("Commit message...")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(MinimalPixelPalette.textDim)
                                        .padding(.horizontal, 6)
                                        .allowsHitTesting(false)
                                }
                                TextField("", text: $manager.proposedCommitMessage)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                                    .foregroundStyle(MinimalPixelPalette.textWhite)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3.5)
                            }
                            .background(Rectangle().fill(MinimalPixelPalette.surface))
                            .overlay(Rectangle().stroke(MinimalPixelPalette.border, lineWidth: 1))

                            // Commit Button
                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                            }) {
                                HStack(spacing: 3) {
                                    WorkspacePixelIcon(
                                        glyph: .disk,
                                        color: manager.proposedCommitMessage.isEmpty ? MinimalPixelPalette.textDim : Color.black,
                                        pixelSize: 1.0
                                    )
                                    Text("Commit")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(
                                    manager.proposedCommitMessage.isEmpty
                                        ? MinimalPixelPalette.textDim
                                        : (commitHovered ? Color.white : Color.black)
                                )
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(
                                    Rectangle().fill(
                                        manager.proposedCommitMessage.isEmpty
                                            ? MinimalPixelPalette.surface
                                            : (commitHovered ? MinimalPixelPalette.green.opacity(0.85) : MinimalPixelPalette.green)
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                            .onHover { commitHovered = $0 }

                            // Push Button
                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                            }) {
                                HStack(spacing: 3) {
                                    WorkspacePixelIcon(
                                        glyph: .push,
                                        color: pushHovered ? Color.black : MinimalPixelPalette.textWhite,
                                        pixelSize: 1.0
                                    )
                                    Text("Push")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(pushHovered ? Color.black : MinimalPixelPalette.textWhite)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3.5)
                                .background(Rectangle().fill(pushHovered ? MinimalPixelPalette.green : MinimalPixelPalette.surface))
                                .overlay(Rectangle().stroke(pushHovered ? MinimalPixelPalette.green : MinimalPixelPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                            .onHover { pushHovered = $0 }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                Rectangle().fill(MinimalPixelPalette.base)
                // Left 1.5px Tab Green / Amber Status Rail
                Rectangle()
                    .fill(manager.changedFiles.isEmpty ? MinimalPixelPalette.green : MinimalPixelPalette.amber)
                    .frame(width: 1.5)
            }
            .overlay(
                Rectangle()
                    .stroke(MinimalPixelPalette.border, lineWidth: 1)
            )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Main Container (Theme Router — driven by Settings only)

struct CyberWorkspaceView: View {
    @ObservedObject var manager: WorkspaceMonitorManager
    var appState: AppState
    @AppStorage(SettingsKey.workspaceHUDTheme) private var workspaceHUDTheme = SettingsDefaults.workspaceHUDTheme

    init(manager: WorkspaceMonitorManager, appState: AppState) {
        self.manager = manager
        self.appState = appState
    }

    var body: some View {
        Group {
            if workspaceHUDTheme == WorkspaceHUDTheme.pixelRetro.rawValue {
                PixelRetroWorkspaceView(manager: manager, appState: appState)
            } else {
                ModernWorkspaceView(manager: manager, appState: appState)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: workspaceHUDTheme)
        .onAppear {
            manager.resolveAndRefreshWorkspace(appState: appState)
        }
    }
}
