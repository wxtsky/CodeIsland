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

// MARK: - 2. Pixel Retro Palette (Teenage Engineering / Analogue Pocket Sleek Cyber)
// High-contrast, ultra-crisp monochrome slate with electric mint / ice cyan precision accents.
// No muddy brown CRT amber, no blurry neon glow. Pure 1-bit / 2-bit engineering craft.

private enum PixelDeckPalette {
    static let base = Color(red: 0.035, green: 0.04, blue: 0.055)       // #090A0E deep OLED obsidian
    static let surface = Color(red: 0.07, green: 0.085, blue: 0.115)    // #12161D modular slot fill
    static let surfaceHover = Color(red: 0.10, green: 0.12, blue: 0.16) // #1A1F29 active hover
    static let border = Color(red: 0.16, green: 0.20, blue: 0.27)       // #293345 1px crisp border
    static let borderMuted = Color(red: 0.11, green: 0.13, blue: 0.18)  // #1C212E slot divider

    // Typography
    static let textStark = Color(red: 0.97, green: 0.98, blue: 1.0)     // #F8FAFC pure crisp white
    static let textSlate = Color(red: 0.58, green: 0.64, blue: 0.72)     // #94A3B8 secondary data
    static let textDim = Color(red: 0.35, green: 0.40, blue: 0.48)       // #59667A muted labels

    // Precision Accents
    static let mint = Color(red: 0.0, green: 1.0, blue: 0.64)           // #00FFA3 electric cyber mint
    static let ice = Color(red: 0.22, green: 0.74, blue: 0.97)          // #38BDF8 cool ice cyan
    static let coral = Color(red: 1.0, green: 0.35, blue: 0.38)         // #FF5961 modified / warning
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

// MARK: - 2. Pixel Retro Hardware Deck View
// Inspired by Teenage Engineering OP-1 / Analogue Pocket / Nothing OS.
// Sharp 1-bit rectangular geometry with high-contrast obsidian & electric cyber mint accents.
// Architecture: Modular Hardware Deck (Slot Header -> Precision Commit Track -> Tactile Command Bar).

// MARK: Pixel Commit Track Item

private struct PixelCommitTrackItemView: View {
    let commit: GitCommitItem
    let isLatest: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Precision Pixel Stepper Node
            ZStack {
                if isLatest {
                    // Active HEAD Node: Sharp 7x7 outer square with electric mint center
                    Rectangle()
                        .stroke(PixelDeckPalette.mint, lineWidth: 1.2)
                        .frame(width: 8, height: 8)
                    Rectangle()
                        .fill(PixelDeckPalette.mint)
                        .frame(width: 4, height: 4)
                } else {
                    // Previous commits: subtle hollow 1-bit pixel square
                    Rectangle()
                        .stroke(PixelDeckPalette.border, lineWidth: 1)
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 10, height: 10)

            // Sharp Hash Pill
            Text(commit.hash)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isLatest ? PixelDeckPalette.mint : PixelDeckPalette.textSlate)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(Rectangle().fill(isLatest ? PixelDeckPalette.mint.opacity(0.12) : PixelDeckPalette.surface))
                .overlay(Rectangle().stroke(isLatest ? PixelDeckPalette.mint.opacity(0.40) : PixelDeckPalette.border, lineWidth: 0.75))

            // Branch / Tag Badge (if exists)
            if !commit.refs.isEmpty {
                Text(commit.refs)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(PixelDeckPalette.ice)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(Rectangle().fill(PixelDeckPalette.ice.opacity(0.12)))
                    .overlay(Rectangle().stroke(PixelDeckPalette.ice.opacity(0.45), lineWidth: 0.75))
                    .lineLimit(1)
            }

            // Commit Message
            Text(commit.message)
                .font(.system(size: 11, weight: isLatest ? .medium : .regular, design: .monospaced))
                .foregroundStyle(isLatest ? PixelDeckPalette.textStark : PixelDeckPalette.textSlate)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Author and Relative Time
            HStack(spacing: 4) {
                Text(commit.author)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(PixelDeckPalette.textDim)

                Text("· \(commit.timeAgo)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(PixelDeckPalette.textDim)
            }
            .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(isHovered ? PixelDeckPalette.surfaceHover : Color.clear)
                if isHovered {
                    Rectangle()
                        .fill(PixelDeckPalette.mint)
                        .frame(width: 2)
                }
            }
        )
        .overlay(
            Rectangle()
                .stroke(isHovered ? PixelDeckPalette.border : Color.clear, lineWidth: 0.75)
        )
        .onHover { isHovered = $0 }
        .help("\(commit.hash) · \(commit.author)\n\(commit.message)")
    }
}

// MARK: Pixel Modular Deck Header

private struct PixelDeckHeaderView: View {
    @ObservedObject var manager: WorkspaceMonitorManager
    var appState: AppState

    @State private var switchHovered = false
    @State private var refreshHovered = false

    private var activeSession: SessionSnapshot? {
        guard !manager.currentCwd.isEmpty else { return nil }
        return appState.sessions.values.first { $0.cwd == manager.currentCwd }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // Workspace Identity Chip
            Button(action: {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                manager.chooseWorkspaceFolder()
            }) {
                HStack(spacing: 5) {
                    Rectangle()
                        .fill(PixelDeckPalette.mint)
                        .frame(width: 4, height: 4)

                    Text(manager.projectName.isEmpty ? "WORKSPACE" : manager.projectName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(switchHovered ? Color.white : PixelDeckPalette.textStark)
                        .lineLimit(1)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(switchHovered ? PixelDeckPalette.mint : PixelDeckPalette.textDim)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(Rectangle().fill(PixelDeckPalette.surface))
                .overlay(Rectangle().stroke(switchHovered ? PixelDeckPalette.mint.opacity(0.6) : PixelDeckPalette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { switchHovered = $0 }
            .help("Switch workspace folder")

            // Branch & Sync Chip
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(PixelDeckPalette.textSlate)

                Text(manager.branch)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(PixelDeckPalette.textStark)
                    .lineLimit(1)

                if manager.aheadCount > 0 || manager.behindCount > 0 {
                    HStack(spacing: 2) {
                        if manager.aheadCount > 0 {
                            Text("↑\(manager.aheadCount)")
                                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                .foregroundStyle(PixelDeckPalette.mint)
                        }
                        if manager.behindCount > 0 {
                            Text("↓\(manager.behindCount)")
                                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                .foregroundStyle(PixelDeckPalette.coral)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Rectangle().fill(Color.black.opacity(0.4)))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(Rectangle().fill(PixelDeckPalette.surface))
            .overlay(Rectangle().stroke(PixelDeckPalette.border, lineWidth: 1))

            // State Badge (Clean vs Modified)
            if manager.changedFiles.isEmpty {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(PixelDeckPalette.mint)
                        .frame(width: 4, height: 4)
                    Text("CLEAN")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(PixelDeckPalette.mint)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(Rectangle().fill(PixelDeckPalette.mint.opacity(0.08)))
                .overlay(Rectangle().stroke(PixelDeckPalette.mint.opacity(0.35), lineWidth: 1))
            } else {
                HStack(spacing: 4) {
                    Rectangle()
                        .fill(PixelDeckPalette.coral)
                        .frame(width: 4, height: 4)
                    Text("\(manager.changedFiles.count) MODIFIED")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(PixelDeckPalette.coral)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3.5)
                .background(Rectangle().fill(PixelDeckPalette.coral.opacity(0.08)))
                .overlay(Rectangle().stroke(PixelDeckPalette.coral.opacity(0.4), lineWidth: 1))
            }

            Spacer(minLength: 4)

            // Active Agent Hardware Badge
            if let session = activeSession {
                HStack(spacing: 4.5) {
                    if let icon = cliIcon(source: session.source, size: 9.5) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 9.5, height: 9.5)
                    }
                    let name = session.mascotSource.isEmpty ? session.source.uppercased() : session.mascotSource.uppercased()
                    Text(name)
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundStyle(PixelDeckPalette.textStark)

                    if let model = session.modelLabel ?? session.model, !model.isEmpty {
                        Text("· \(model)")
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(PixelDeckPalette.textSlate)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Rectangle().fill(PixelDeckPalette.surface))
                .overlay(Rectangle().stroke(PixelDeckPalette.border, lineWidth: 1))
            }

            // Tactile Refresh Button
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
                            .font(.system(size: 8.5, weight: .bold))
                    }
                }
                .foregroundStyle(refreshHovered ? PixelDeckPalette.mint : PixelDeckPalette.textSlate)
                .frame(width: 18, height: 18)
                .background(Rectangle().fill(refreshHovered ? PixelDeckPalette.surfaceHover : PixelDeckPalette.surface))
                .overlay(Rectangle().stroke(refreshHovered ? PixelDeckPalette.mint.opacity(0.6) : PixelDeckPalette.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { refreshHovered = $0 }
            .help("Refresh git status")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Rectangle().fill(PixelDeckPalette.base))
        .overlay(Rectangle().stroke(PixelDeckPalette.borderMuted, lineWidth: 1))
    }
}

// MARK: - 2. Pixel Retro Hardware Deck Main View

struct PixelRetroWorkspaceView: View {
    @ObservedObject var manager: WorkspaceMonitorManager
    var appState: AppState

    @State private var aiHovered = false
    @State private var commitHovered = false
    @State private var pushHovered = false
    @State private var openHovered = false

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isGitRepo {
                // Non-Git State
                VStack(spacing: 10) {
                    Text("NO GIT REPOSITORY")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundStyle(PixelDeckPalette.coral)

                    Text(manager.currentCwd.isEmpty ? "NO WORKSPACE SELECTED" : manager.currentCwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(PixelDeckPalette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        HStack(spacing: 5) {
                            Rectangle()
                                .fill(PixelDeckPalette.mint)
                                .frame(width: 4, height: 4)
                            Text("SELECT WORKSPACE FOLDER")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(PixelDeckPalette.textStark)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Rectangle().fill(PixelDeckPalette.surface))
                        .overlay(Rectangle().stroke(PixelDeckPalette.mint.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .padding(.vertical, 12)

            } else {
                VStack(spacing: 6) {

                    // ── 1. MODULAR HARDWARE DECK HEADER ────────────────────────
                    PixelDeckHeaderView(manager: manager, appState: appState)

                    // ── 2. PRECISION GIT COMMIT TRACK ──────────────────────────
                    VStack(alignment: .leading, spacing: 2) {
                        if manager.recentCommits.isEmpty {
                            HStack(spacing: 6) {
                                Rectangle()
                                    .stroke(PixelDeckPalette.border, lineWidth: 1)
                                    .frame(width: 6, height: 6)
                                Text("No recent commits recorded")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(PixelDeckPalette.textDim)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
                        } else {
                            ForEach(Array(manager.recentCommits.prefix(3).enumerated()), id: \.element.id) { index, commit in
                                PixelCommitTrackItemView(
                                    commit: commit,
                                    isLatest: index == 0
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 2)

                    // ── 3. TACTILE COMMAND CONSOLE BAR ─────────────────────────
                    if manager.changedFiles.isEmpty {
                        // Clean Tree Console
                        HStack(spacing: 8) {
                            Text(manager.currentCwd)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(PixelDeckPalette.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(PixelDeckPalette.mint)
                                    .transition(.opacity)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                NSWorkspace.shared.open(URL(fileURLWithPath: manager.currentCwd))
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 8))
                                    Text("OPEN DIRECTORY")
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                }
                                .foregroundStyle(openHovered ? Color.black : PixelDeckPalette.textStark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Rectangle().fill(openHovered ? PixelDeckPalette.mint : PixelDeckPalette.surface))
                                .overlay(Rectangle().stroke(openHovered ? PixelDeckPalette.mint : PixelDeckPalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { openHovered = $0 }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)

                    } else {
                        // Quick Action Hardware Controls
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                // AI Chip Button
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        manager.generateAICommitMessage()
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 8, weight: .bold))
                                        Text("AI")
                                            .font(.system(size: 9, weight: .black, design: .monospaced))
                                    }
                                    .foregroundStyle(aiHovered ? Color.black : PixelDeckPalette.mint)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(Rectangle().fill(aiHovered ? PixelDeckPalette.mint : PixelDeckPalette.mint.opacity(0.12)))
                                    .overlay(Rectangle().stroke(PixelDeckPalette.mint.opacity(0.5), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .onHover { aiHovered = $0 }
                                .help("Auto-generate conventional commit message")

                                // Sharp Commit Input Field
                                ZStack(alignment: .leading) {
                                    if manager.proposedCommitMessage.isEmpty {
                                        Text("Commit changes...")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(PixelDeckPalette.textDim)
                                            .padding(.horizontal, 7)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $manager.proposedCommitMessage)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(PixelDeckPalette.textStark)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                }
                                .background(Rectangle().fill(PixelDeckPalette.surface))
                                .overlay(Rectangle().stroke(PixelDeckPalette.border, lineWidth: 1))

                                // Solid High-Contrast Commit Button
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                                }) {
                                    Text(manager.isCommitting ? "..." : "COMMIT")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundStyle(
                                            manager.proposedCommitMessage.isEmpty
                                                ? PixelDeckPalette.textDim
                                                : (commitHovered ? Color.white : Color.black)
                                        )
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4.5)
                                        .background(
                                            Rectangle().fill(
                                                manager.proposedCommitMessage.isEmpty
                                                    ? PixelDeckPalette.surface
                                                    : (commitHovered ? PixelDeckPalette.mint.opacity(0.85) : PixelDeckPalette.mint)
                                            )
                                        )
                                        .overlay(
                                            Rectangle().stroke(
                                                manager.proposedCommitMessage.isEmpty
                                                    ? PixelDeckPalette.border
                                                    : PixelDeckPalette.mint,
                                                lineWidth: 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { commitHovered = $0 }

                                // Sharp Push Button
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                                }) {
                                    HStack(spacing: 3) {
                                        Text("PUSH")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 7, weight: .black))
                                    }
                                    .foregroundStyle(pushHovered ? PixelDeckPalette.mint : PixelDeckPalette.textSlate)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4.5)
                                    .background(Rectangle().fill(pushHovered ? PixelDeckPalette.surfaceHover : PixelDeckPalette.surface))
                                    .overlay(Rectangle().stroke(pushHovered ? PixelDeckPalette.mint.opacity(0.6) : PixelDeckPalette.border, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { pushHovered = $0 }
                            }
                            .padding(.horizontal, 4)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(PixelDeckPalette.mint)
                                    .padding(.horizontal, 6)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                Rectangle().fill(PixelDeckPalette.base)
                // Left 1.5px cyber mint precision rail
                Rectangle()
                    .fill(manager.changedFiles.isEmpty ? PixelDeckPalette.mint : PixelDeckPalette.coral)
                    .frame(width: 1.5)
            }
            .overlay(Rectangle().stroke(PixelDeckPalette.border, lineWidth: 1))
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
