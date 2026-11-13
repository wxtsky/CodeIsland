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

// MARK: - 2. Authentic Cyber Pixel Palette (Vibrant Arcade Cyberpunk)
// Rich retro palette inspired by classic 8-bit / 16-bit arcade hardware:
// Deep pitch black with neon cyan (#00F5D4), cyber pink (#FF2E93), and electric amber (#FFD166).

private enum CyberPixelPalette {
    static let base = Color(red: 0.04, green: 0.05, blue: 0.07)         // #0A0D12 Deep cyber black
    static let cardBg = Color(red: 0.07, green: 0.09, blue: 0.13)       // #121721 Panel fill
    static let cardHover = Color(red: 0.10, green: 0.13, blue: 0.18)    // #1A212E Card hover
    static let border = Color(red: 0.18, green: 0.24, blue: 0.33)       // #2E3D54 Pixel border
    static let borderBright = Color(red: 0.0, green: 0.96, blue: 0.83)  // #00F5D4 Active stroke

    // Neon Accents
    static let cyan = Color(red: 0.0, green: 0.96, blue: 0.83)          // #00F5D4 Cyber Cyan (Primary)
    static let pink = Color(red: 1.0, green: 0.18, blue: 0.58)          // #FF2E93 Cyber Pink (Branch / Ref)
    static let yellow = Color(red: 1.0, green: 0.82, blue: 0.40)        // #FFD166 Coin Amber (Modified)
    static let green = Color(red: 0.12, green: 0.92, blue: 0.45)        // #1FEB73 1-Up Green (Clean)

    // Text
    static let textWhite = Color(red: 0.98, green: 0.99, blue: 1.0)     // Crisp foreground
    static let textMuted = Color(red: 0.60, green: 0.68, blue: 0.78)     // Secondary data
    static let textDim = Color(red: 0.38, green: 0.44, blue: 0.54)       // Muted details
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
    var pixelSize: CGFloat = 1.3

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

// MARK: - 2. Authentic Cyber Pixel Retro Workspace View
// Features bespoke 9x9 Vector Pixel Art Icons, Arcade Neon Cyan & Pink palette,
// and a structured Cyberdeck layout that feels completely authentic and premium.

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

    private var latestCommit: GitCommitItem? {
        manager.recentCommits.first
    }

    private var previousCommits: [GitCommitItem] {
        Array(manager.recentCommits.dropFirst().prefix(2))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isGitRepo {
                // Non-Git State
                VStack(spacing: 9) {
                    HStack(spacing: 7) {
                        WorkspacePixelIcon(glyph: .modified, color: CyberPixelPalette.pink, pixelSize: 1.6)
                        Text("NO REPOSITORY ATTACHED")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .foregroundStyle(CyberPixelPalette.pink)
                    }

                    Text(manager.currentCwd.isEmpty ? "SELECT WORKSPACE DIRECTORY" : manager.currentCwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(CyberPixelPalette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        HStack(spacing: 6) {
                            WorkspacePixelIcon(glyph: .folder, color: Color.black, pixelSize: 1.3)
                            Text("MOUNT WORKSPACE")
                                .font(.system(size: 9.5, weight: .heavy, design: .monospaced))
                                .foregroundStyle(Color.black)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Rectangle().fill(CyberPixelPalette.cyan))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 115)
                .padding(.vertical, 12)

            } else {
                VStack(spacing: 7) {

                    // ========================================================
                    // 1. TOP RETRO CYBER HEADER STRIP (WITH PIXEL ICONS)
                    // ========================================================
                    HStack(alignment: .center, spacing: 6) {
                        // Project Identity Badge with Pixel Folder Icon
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.chooseWorkspaceFolder()
                        }) {
                            HStack(spacing: 5) {
                                WorkspacePixelIcon(glyph: .folder, color: switchHovered ? Color.white : CyberPixelPalette.cyan, pixelSize: 1.2)

                                Text(manager.projectName.isEmpty ? "WORKSPACE" : manager.projectName.uppercased())
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(switchHovered ? Color.white : CyberPixelPalette.textWhite)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Rectangle().fill(CyberPixelPalette.cardBg))
                            .overlay(Rectangle().stroke(switchHovered ? CyberPixelPalette.cyan : CyberPixelPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { switchHovered = $0 }
                        .help("Swap workspace folder")

                        // Branch Chip with Pixel Branch Icon & Pink Accent
                        HStack(spacing: 5) {
                            WorkspacePixelIcon(glyph: .branch, color: CyberPixelPalette.pink, pixelSize: 1.2)

                            Text(manager.branch)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(CyberPixelPalette.textWhite)
                                .lineLimit(1)

                            if manager.aheadCount > 0 || manager.behindCount > 0 {
                                HStack(spacing: 2) {
                                    if manager.aheadCount > 0 {
                                        Text("↑\(manager.aheadCount)")
                                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.cyan)
                                    }
                                    if manager.behindCount > 0 {
                                        Text("↓\(manager.behindCount)")
                                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.yellow)
                                    }
                                }
                                .padding(.horizontal, 3)
                                .padding(.vertical, 0.5)
                                .background(Rectangle().fill(Color.black.opacity(0.5)))
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Rectangle().fill(CyberPixelPalette.cardBg))
                        .overlay(Rectangle().stroke(CyberPixelPalette.border, lineWidth: 1))

                        // State Badge (Pixel Check vs Pixel Warning)
                        if manager.changedFiles.isEmpty {
                            HStack(spacing: 4) {
                                WorkspacePixelIcon(glyph: .check, color: CyberPixelPalette.green, pixelSize: 1.1)
                                Text("CLEAN")
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(CyberPixelPalette.green)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3.5)
                            .background(Rectangle().fill(CyberPixelPalette.green.opacity(0.12)))
                            .overlay(Rectangle().stroke(CyberPixelPalette.green.opacity(0.4), lineWidth: 1))
                        } else {
                            HStack(spacing: 4) {
                                WorkspacePixelIcon(glyph: .modified, color: CyberPixelPalette.yellow, pixelSize: 1.1)
                                Text("\(manager.changedFiles.count) MODS")
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(CyberPixelPalette.yellow)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3.5)
                            .background(Rectangle().fill(CyberPixelPalette.yellow.opacity(0.12)))
                            .overlay(Rectangle().stroke(CyberPixelPalette.yellow.opacity(0.4), lineWidth: 1))
                        }

                        Spacer(minLength: 4)

                        // Active Agent Hardware Pill
                        if let session = activeSession {
                            HStack(spacing: 4) {
                                if let icon = cliIcon(source: session.source, size: 9.5) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 9.5, height: 9.5)
                                }
                                Text(session.source.uppercased())
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(CyberPixelPalette.textWhite)

                                if let model = session.modelLabel ?? session.model, !model.isEmpty {
                                    Text("[\(model)]")
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(CyberPixelPalette.cyan)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3.5)
                            .background(Rectangle().fill(CyberPixelPalette.cardBg))
                            .overlay(Rectangle().stroke(CyberPixelPalette.border, lineWidth: 1))
                        }

                        // Pixel Sync / Refresh Button
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }) {
                            WorkspacePixelIcon(
                                glyph: .sync,
                                color: refreshHovered ? Color.white : CyberPixelPalette.textMuted,
                                pixelSize: 1.2
                            )
                            .padding(4)
                            .background(Rectangle().fill(refreshHovered ? CyberPixelPalette.cyan.opacity(0.3) : CyberPixelPalette.cardBg))
                            .overlay(Rectangle().stroke(refreshHovered ? CyberPixelPalette.cyan : CyberPixelPalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { refreshHovered = $0 }
                        .help("Reload workspace status")
                    }

                    // ========================================================
                    // 2. RETRO COMMIT TIMELINE DECK (FEATURED HEAD + LOG STRIP)
                    // ========================================================
                    VStack(spacing: 4) {
                        // 2A. ACTIVE HEAD COMMIT (FEATURED CYBER CARD)
                        if let head = latestCommit {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    // Pixel Commit Node
                                    WorkspacePixelIcon(glyph: .commitNode, color: CyberPixelPalette.cyan, pixelSize: 1.2)

                                    // Hash Pill
                                    Text(head.hash)
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundStyle(CyberPixelPalette.cyan)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Rectangle().fill(CyberPixelPalette.cyan.opacity(0.12)))

                                    if !head.refs.isEmpty {
                                        Text(head.refs)
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.pink)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Rectangle().fill(CyberPixelPalette.pink.opacity(0.10)))
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 0)

                                    Text("\(head.author) · \(head.timeAgo)")
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(CyberPixelPalette.textDim)
                                }

                                Text(head.message)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(CyberPixelPalette.textWhite)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Rectangle().fill(CyberPixelPalette.cardBg))
                            .overlay(
                                Rectangle()
                                    .stroke(CyberPixelPalette.borderBright.opacity(0.6), lineWidth: 1)
                            )
                        } else {
                            HStack {
                                Text("NO COMMITS FOUND ON THIS BRANCH")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(CyberPixelPalette.textDim)
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Rectangle().fill(CyberPixelPalette.cardBg))
                        }

                        // 2B. PREVIOUS ARCHIVES (COMPACT CYBER LOGS)
                        if !previousCommits.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(previousCommits, id: \.id) { prev in
                                    HStack(spacing: 6) {
                                        Rectangle()
                                            .fill(CyberPixelPalette.border)
                                            .frame(width: 4, height: 4)

                                        Text(prev.hash)
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.textMuted)

                                        Text(prev.message)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Spacer(minLength: 0)

                                        Text(prev.timeAgo)
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.textDim)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }

                    // ========================================================
                    // 3. RETRO COMMAND PAD (INPUT + PIXEL ACTION BUTTONS)
                    // ========================================================
                    if manager.changedFiles.isEmpty {
                        // Clean Tree Bar
                        HStack(spacing: 8) {
                            Text(manager.currentCwd)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(CyberPixelPalette.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    .foregroundStyle(CyberPixelPalette.green)
                                    .transition(.opacity)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                NSWorkspace.shared.open(URL(fileURLWithPath: manager.currentCwd))
                            }) {
                                HStack(spacing: 4) {
                                    WorkspacePixelIcon(glyph: .folder, color: openHovered ? Color.black : CyberPixelPalette.cyan, pixelSize: 1.1)
                                    Text("OPEN FOLDER")
                                        .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                }
                                .foregroundStyle(openHovered ? Color.black : CyberPixelPalette.textWhite)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Rectangle().fill(openHovered ? CyberPixelPalette.cyan : CyberPixelPalette.cardBg))
                                .overlay(Rectangle().stroke(openHovered ? CyberPixelPalette.cyan : CyberPixelPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { openHovered = $0 }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)

                    } else {
                        // Uncommitted Changes Command Console
                        VStack(spacing: 4) {
                            // Row 1: Pixel Input Bar
                            HStack(spacing: 5) {
                                WorkspacePixelIcon(glyph: .sparkle, color: CyberPixelPalette.cyan, pixelSize: 1.1)

                                ZStack(alignment: .leading) {
                                    if manager.proposedCommitMessage.isEmpty {
                                        Text("COMMIT MESSAGE...")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(CyberPixelPalette.textDim)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $manager.proposedCommitMessage)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(CyberPixelPalette.textWhite)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Rectangle().fill(CyberPixelPalette.cardBg))
                            .overlay(Rectangle().stroke(CyberPixelPalette.border, lineWidth: 1))

                            // Row 2: Pixel Buttons Deck
                            HStack(spacing: 6) {
                                // AI Button with Pixel Sparkle Icon
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        manager.generateAICommitMessage()
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        WorkspacePixelIcon(glyph: .sparkle, color: aiHovered ? Color.black : CyberPixelPalette.pink, pixelSize: 1.1)
                                        Text("AI DRAFT")
                                            .font(.system(size: 8.5, weight: .heavy, design: .monospaced))
                                    }
                                    .foregroundStyle(aiHovered ? Color.black : CyberPixelPalette.pink)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Rectangle().fill(aiHovered ? CyberPixelPalette.pink : CyberPixelPalette.pink.opacity(0.12)))
                                    .overlay(Rectangle().stroke(CyberPixelPalette.pink.opacity(0.6), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .onHover { aiHovered = $0 }
                                .help("Auto-generate conventional commit message")

                                Spacer(minLength: 0)

                                // Commit Button with Pixel Disk Icon
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                                }) {
                                    HStack(spacing: 4) {
                                        WorkspacePixelIcon(
                                            glyph: .disk,
                                            color: manager.proposedCommitMessage.isEmpty ? CyberPixelPalette.textDim : Color.black,
                                            pixelSize: 1.1
                                        )
                                        Text(manager.isCommitting ? "..." : "COMMIT")
                                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    }
                                    .foregroundStyle(
                                        manager.proposedCommitMessage.isEmpty
                                            ? CyberPixelPalette.textDim
                                            : (commitHovered ? Color.white : Color.black)
                                    )
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4.5)
                                    .background(
                                        Rectangle().fill(
                                            manager.proposedCommitMessage.isEmpty
                                                ? CyberPixelPalette.cardBg
                                                : (commitHovered ? CyberPixelPalette.cyan.opacity(0.8) : CyberPixelPalette.cyan)
                                        )
                                    )
                                    .overlay(
                                        Rectangle().stroke(
                                            manager.proposedCommitMessage.isEmpty
                                                ? CyberPixelPalette.border
                                                : CyberPixelPalette.cyan,
                                            lineWidth: 1
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { commitHovered = $0 }

                                // Push Button with Pixel Push Icon
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                                }) {
                                    HStack(spacing: 4) {
                                        WorkspacePixelIcon(
                                            glyph: .push,
                                            color: pushHovered ? Color.black : CyberPixelPalette.textWhite,
                                            pixelSize: 1.1
                                        )
                                        Text("PUSH")
                                            .font(.system(size: 9, weight: .heavy, design: .monospaced))
                                    }
                                    .foregroundStyle(pushHovered ? Color.black : CyberPixelPalette.textWhite)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4.5)
                                    .background(Rectangle().fill(pushHovered ? CyberPixelPalette.cyan : CyberPixelPalette.cardBg))
                                    .overlay(Rectangle().stroke(pushHovered ? CyberPixelPalette.cyan : CyberPixelPalette.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { pushHovered = $0 }
                            }
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                Rectangle().fill(CyberPixelPalette.base)
                // Left 2px Cyber Cyan Rail
                Rectangle()
                    .fill(manager.changedFiles.isEmpty ? CyberPixelPalette.cyan : CyberPixelPalette.yellow)
                    .frame(width: 2)
            }
            .overlay(
                Rectangle()
                    .stroke(CyberPixelPalette.border, lineWidth: 1.5)
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
