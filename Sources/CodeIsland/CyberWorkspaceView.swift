import SwiftUI
import AppKit
import CodeIslandCore

// MARK: - Modern Minimalist Palette (Obsidian / Zinc)

private enum ModernPalette {
    static let base = Color(red: 0.055, green: 0.065, blue: 0.08)       // #0E1014 deep zinc
    static let surface = Color.white.opacity(0.035)                      // Subtle card fill
    static let border = Color.white.opacity(0.07)                        // Hairline border
    static let borderSubtle = Color.white.opacity(0.05)
    
    // Text Hierarchy
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.60)
    static let textMuted = Color.white.opacity(0.38)
    
    // Precise Intentional Accents
    static let sage = Color(red: 0.22, green: 0.78, blue: 0.52)         // Clean state / HEAD indicator
    static let amber = Color(red: 0.94, green: 0.64, blue: 0.20)        // Modified / Uncommitted
}

// MARK: - Pixel Retro 8-Bit Palette (Arcade / Phosphor CRT)

private enum RetroPalette {
    static let base = Color(red: 0.02, green: 0.03, blue: 0.025)        // #050806 CRT deep black
    static let surface = Color(red: 0.04, green: 0.065, blue: 0.05)     // #0A110D
    static let border = Color(red: 0.0, green: 0.90, blue: 0.42).opacity(0.30)
    static let borderAmber = Color(red: 1.0, green: 0.70, blue: 0.0).opacity(0.35)
    
    // Phosphor CRT Accents
    static let green = Color(red: 0.0, green: 0.95, blue: 0.45)         // #00F273 Phosphor Green
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.0)          // #FFB300 Arcade Amber
    static let cyan = Color(red: 0.20, green: 0.85, blue: 1.0)          // #33D6FF Arcade Cyan
    static let textBright = Color(red: 0.85, green: 1.0, blue: 0.90)    // #D9FFE6
    static let textDim = Color(red: 0.0, green: 0.95, blue: 0.45).opacity(0.65)
    static let textMuted = Color.white.opacity(0.40)
}

// MARK: - Modern Git Graph Item View

struct ModernGitGraphItemView: View {
    let commit: GitCommitItem
    let isLatest: Bool
    let isLast: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Visual Git Spine & Clean Node Dot
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

            // Commit Details
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

// MARK: - Modern Active Agent Context Pill

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

                Circle()
                    .fill(session.status == .idle ? ModernPalette.sage : Color.white.opacity(0.70))
                    .frame(width: 4, height: 4)
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
    @Binding var currentTheme: String

    @State private var switchFolderHovered = false
    @State private var refreshHovered = false
    @State private var terminalHovered = false
    @State private var aiHovered = false
    @State private var pushHovered = false
    @State private var themeToggleHovered = false

    private var statusRailColor: Color {
        if !manager.isGitRepo {
            return Color.white.opacity(0.18)
        } else if manager.isCommitting {
            return Color.white.opacity(0.60)
        } else if !manager.changedFiles.isEmpty {
            return ModernPalette.amber
        } else {
            return ModernPalette.sage
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isGitRepo {
                // Non-Git Workspace State
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
                    // ==========================================
                    // 1. UNIFIED BREADCRUMB HEADER
                    // ==========================================
                    HStack(alignment: .center, spacing: 7) {
                        // Project Identity
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

                        // Breadcrumb Divider
                        Text("/")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.22))

                        // Branch & Sync Indicator
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

                        // Inline Status Indicator (Clean / Modified)
                        Text("•")
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

                        // Quick Theme Switcher Pill (Modern -> 8-Bit)
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            withAnimation(.easeInOut(duration: 0.22)) {
                                currentTheme = WorkspaceHUDTheme.pixelRetro.rawValue
                            }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arcade.stick")
                                    .font(.system(size: 8))
                                Text("8-BIT")
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(themeToggleHovered ? Color.white : Color.white.opacity(0.50))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.white.opacity(themeToggleHovered ? 0.12 : 0.05)))
                        }
                        .buttonStyle(.plain)
                        .onHover { themeToggleHovered = $0 }
                        .help("Switch to 8-Bit Retro Pixel Theme")

                        // Right Toolbar: Active Agent & Refresh
                        ModernActiveAgentPill(appState: appState, cwd: manager.currentCwd)

                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }) {
                            HStack(spacing: 3) {
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

                    // ==========================================
                    // 2. HERO: GIT GRAPH COMMIT TIMELINE
                    // ==========================================
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
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(manager.recentCommits.prefix(3).enumerated()), id: \.element.id) { index, commit in
                                    ModernGitGraphItemView(
                                        commit: commit,
                                        isLatest: index == 0,
                                        isLast: index == min(2, manager.recentCommits.count - 1)
                                    )
                                }
                            }
                        }
                    }

                    // ==========================================
                    // 3. ACTION BAR (NON-DUPLICATED)
                    // ==========================================
                    if manager.changedFiles.isEmpty {
                        // Clean state footer: path hint & quick actions
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
                                let url = URL(fileURLWithPath: manager.currentCwd)
                                NSWorkspace.shared.open(url)
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
                        // Quick Action Studio Bar (when uncommitted changes exist)
                        HStack(spacing: 6) {
                            // AI Suggest Button
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

                            // Commit Input Field with High-Contrast Readable Placeholder
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

                            // Commit Button
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

                            // Push Button
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(ModernPalette.base)

                // Left 2.5px refined status accent rail
                Rectangle()
                    .fill(statusRailColor)
                    .frame(width: 2.5)
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

// MARK: - 2. Pixel Retro 8-Bit Workspace View (Arcade / Phosphor Terminal)

struct PixelRetroWorkspaceView: View {
    @ObservedObject var manager: WorkspaceMonitorManager
    var appState: AppState
    @Binding var currentTheme: String

    @State private var switchFolderHovered = false
    @State private var refreshHovered = false
    @State private var terminalHovered = false
    @State private var aiHovered = false
    @State private var commitHovered = false
    @State private var pushHovered = false
    @State private var themeToggleHovered = false

    private var activeSession: SessionSnapshot? {
        guard !manager.currentCwd.isEmpty else { return nil }
        return appState.sessions.values.first { $0.cwd == manager.currentCwd }
    }

    private var statusPhosphorColor: Color {
        if !manager.isGitRepo {
            return Color.white.opacity(0.3)
        } else if manager.isCommitting {
            return RetroPalette.cyan
        } else if !manager.changedFiles.isEmpty {
            return RetroPalette.amber
        } else {
            return RetroPalette.green
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !manager.isGitRepo {
                // Retro Non-Git State
                VStack(spacing: 8) {
                    PixelText(text: "NO GIT REPO DETECTED", color: RetroPalette.amber, pixelSize: 1.8)
                        .frame(height: 12)

                    Text(manager.currentCwd.isEmpty ? "[ NO WORKSPACE FOLDER SELECTED ]" : "[ \(manager.currentCwd) ]")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(RetroPalette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 20)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        HStack(spacing: 4) {
                            Text("[")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.green.opacity(0.7))
                            Text("SELECT WORKSPACE FOLDER")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.green)
                            Text("]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.green.opacity(0.7))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Rectangle().fill(RetroPalette.surface))
                        .overlay(Rectangle().strokeBorder(RetroPalette.green.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    // ==========================================
                    // 1. RETRO 8-BIT ARCADE BANNER HEADER
                    // ==========================================
                    HStack(alignment: .center, spacing: 6) {
                        // Dot Matrix Section Header
                        PixelText(text: "WORKSPACE", color: RetroPalette.green, pixelSize: 1.6)
                            .frame(height: 10)

                        Text("::")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(RetroPalette.green.opacity(0.35))

                        // Project Folder Tag [DIR: NAME]
                        HStack(spacing: 3) {
                            Text("[DIR: \(manager.projectName.uppercased())]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.textBright)
                                .lineLimit(1)

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                manager.chooseWorkspaceFolder()
                            }) {
                                Text("⟲")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(switchFolderHovered ? RetroPalette.green : RetroPalette.textDim)
                            }
                            .buttonStyle(.plain)
                            .onHover { switchFolderHovered = $0 }
                            .help("Switch workspace folder")
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Rectangle().fill(Color.black.opacity(0.5)))
                        .overlay(Rectangle().strokeBorder(RetroPalette.border, lineWidth: 1))

                        // Branch Tag [BR: NAME]
                        HStack(spacing: 3) {
                            Text("[BR: \(manager.branch.uppercased())]")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.cyan)
                                .lineLimit(1)

                            if manager.aheadCount > 0 || manager.behindCount > 0 {
                                HStack(spacing: 2) {
                                    if manager.aheadCount > 0 {
                                        Text("↑\(manager.aheadCount)")
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(RetroPalette.green)
                                    }
                                    if manager.behindCount > 0 {
                                        Text("↓\(manager.behindCount)")
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(RetroPalette.amber)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Rectangle().fill(Color.black.opacity(0.5)))
                        .overlay(Rectangle().strokeBorder(RetroPalette.cyan.opacity(0.3), lineWidth: 1))

                        // Working Tree Status Badge
                        if manager.changedFiles.isEmpty {
                            Text("[★ CLEAN]")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Rectangle().fill(RetroPalette.green.opacity(0.12)))
                                .overlay(Rectangle().strokeBorder(RetroPalette.green.opacity(0.45), lineWidth: 1))
                        } else {
                            Text("[▲ \(manager.changedFiles.count) MOD]")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.amber)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Rectangle().fill(RetroPalette.amber.opacity(0.12)))
                                .overlay(Rectangle().strokeBorder(RetroPalette.amber.opacity(0.55), lineWidth: 1))
                        }

                        Spacer(minLength: 4)

                        // Quick Theme Switcher Pill (8-Bit -> Modern)
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            withAnimation(.easeInOut(duration: 0.22)) {
                                currentTheme = WorkspaceHUDTheme.modern.rawValue
                            }
                        }) {
                            Text("[MODERN]")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(themeToggleHovered ? Color.white : RetroPalette.textDim)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Rectangle().fill(Color.black.opacity(0.4)))
                                .overlay(Rectangle().strokeBorder(Color.white.opacity(themeToggleHovered ? 0.35 : 0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { themeToggleHovered = $0 }
                        .help("Switch to Modern Minimalist Theme")

                        // Active Agent Pill
                        if let session = activeSession {
                            HStack(spacing: 3) {
                                Text("■")
                                    .font(.system(size: 7))
                                    .foregroundStyle(session.status == .idle ? RetroPalette.green : RetroPalette.cyan)
                                Text("[\(session.source.uppercased())]")
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroPalette.textBright)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Rectangle().fill(Color.black.opacity(0.4)))
                            .overlay(Rectangle().strokeBorder(RetroPalette.border, lineWidth: 0.8))
                        }

                        // Retro Refresh Button
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }) {
                            Text(manager.isRefreshing ? "[...]" : "[⟳]")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(refreshHovered ? Color.white : RetroPalette.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Rectangle().fill(Color.black.opacity(0.4)))
                                .overlay(Rectangle().strokeBorder(RetroPalette.green.opacity(refreshHovered ? 0.8 : 0.4), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { refreshHovered = $0 }
                        .help("Reload git status")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Rectangle().fill(Color.black.opacity(0.6)))
                    .overlay(Rectangle().strokeBorder(RetroPalette.border, lineWidth: 1))

                    // ==========================================
                    // 2. HERO: 8-BIT ARCADE COMMIT TIMELINE
                    // ==========================================
                    VStack(alignment: .leading, spacing: 3) {
                        if manager.recentCommits.isEmpty {
                            VStack(spacing: 3) {
                                Text("[ NO COMMITS IN REPO LOG ]")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroPalette.textDim)
                            }
                            .frame(maxWidth: .infinity, minHeight: 50)
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(manager.recentCommits.prefix(3).enumerated()), id: \.element.id) { index, commit in
                                    HStack(alignment: .top, spacing: 8) {
                                        // 8-bit Spine & Node
                                        VStack(spacing: 0) {
                                            if index == 0 {
                                                Text("■")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(RetroPalette.green)
                                            } else {
                                                Text("▫")
                                                    .font(.system(size: 8, weight: .regular))
                                                    .foregroundStyle(RetroPalette.textDim)
                                            }

                                            if index < min(2, manager.recentCommits.count - 1) {
                                                Rectangle()
                                                    .fill(RetroPalette.green.opacity(0.20))
                                                    .frame(width: 1, height: 18)
                                            }
                                        }
                                        .frame(width: 10)

                                        // Commit Content
                                        VStack(alignment: .leading, spacing: 1.5) {
                                            HStack(spacing: 5) {
                                                Text("[#\(commit.hash)]")
                                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                    .foregroundStyle(index == 0 ? RetroPalette.green : RetroPalette.cyan)

                                                if !commit.refs.isEmpty {
                                                    Text("<\(commit.refs)>")
                                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                                        .foregroundStyle(RetroPalette.amber)
                                                        .lineLimit(1)
                                                }

                                                Spacer(minLength: 0)

                                                Text("\(commit.author.uppercased()) // \(commit.timeAgo.uppercased())")
                                                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                                    .foregroundStyle(RetroPalette.textDim)
                                            }

                                            Text(commit.message)
                                                .font(.system(size: 11, weight: index == 0 ? .semibold : .regular, design: .monospaced))
                                                .foregroundStyle(index == 0 ? RetroPalette.textBright : RetroPalette.textDim)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                            }
                        }
                    }

                    // ==========================================
                    // 3. ACTION BAR (ARCADE COMMAND DECK)
                    // ==========================================
                    if manager.changedFiles.isEmpty {
                        // Clean state: Retro terminal path
                        HStack(spacing: 8) {
                            Text("ROOT: \(manager.currentCwd)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(RetroPalette.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text("[✓ \(status.uppercased())]")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroPalette.green)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                let url = URL(fileURLWithPath: manager.currentCwd)
                                NSWorkspace.shared.open(url)
                            }) {
                                Text("[ OPEN FOLDER ]")
                                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(terminalHovered ? Color.black : RetroPalette.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Rectangle().fill(terminalHovered ? RetroPalette.green : Color.clear))
                                    .overlay(Rectangle().strokeBorder(RetroPalette.green, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { terminalHovered = $0 }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                    } else {
                        // Quick Action Studio Bar (when uncommitted changes exist)
                        HStack(spacing: 5) {
                            // Arcade AI Suggest Button
                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    manager.generateAICommitMessage()
                                }
                            }) {
                                Text("[✦ AI MSG]")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(aiHovered ? Color.black : RetroPalette.cyan)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(Rectangle().fill(aiHovered ? RetroPalette.cyan : Color.clear))
                                    .overlay(Rectangle().strokeBorder(RetroPalette.cyan, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { aiHovered = $0 }
                            .help("Auto-generate conventional commit message")

                            // Arcade Prompt Input Field
                            HStack(spacing: 4) {
                                Text(">")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroPalette.green)

                                ZStack(alignment: .leading) {
                                    if manager.proposedCommitMessage.isEmpty {
                                        Text("COMMIT MESSAGE...")
                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                            .foregroundStyle(RetroPalette.green.opacity(0.40))
                                            .allowsHitTesting(false)
                                    }

                                    TextField("", text: $manager.proposedCommitMessage)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                                        .foregroundStyle(RetroPalette.textBright)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Rectangle().fill(Color.black.opacity(0.6)))
                            .overlay(Rectangle().strokeBorder(RetroPalette.green.opacity(0.4), lineWidth: 1))

                            // Arcade COMMIT Button (Inverted Solid)
                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                            }) {
                                Text(manager.isCommitting ? "[...]" : "[ COMMIT ]")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(manager.proposedCommitMessage.isEmpty ? Color.white.opacity(0.3) : Color.black)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Rectangle()
                                            .fill(manager.proposedCommitMessage.isEmpty ? Color.white.opacity(0.08) : (commitHovered ? Color(red: 0.3, green: 1.0, blue: 0.6) : RetroPalette.green))
                                    )
                                    .overlay(
                                        Rectangle()
                                            .strokeBorder(manager.proposedCommitMessage.isEmpty ? Color.white.opacity(0.15) : RetroPalette.green, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                            .onHover { commitHovered = $0 }

                            // Arcade PUSH Button
                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                            }) {
                                Text(manager.isCommitting ? "[...]" : "[ PUSH ↑ ]")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(pushHovered ? Color.black : RetroPalette.textBright)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Rectangle().fill(pushHovered ? RetroPalette.textBright : Color.clear))
                                    .overlay(Rectangle().strokeBorder(RetroPalette.textBright.opacity(0.5), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                            .onHover { pushHovered = $0 }
                        }
                        .padding(.horizontal, 4)

                        if let status = manager.commitStatusMessage {
                            Text("[STATUS: \(status.uppercased())]")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.green)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(RetroPalette.base)

                // Left 3px retro phosphor status rail
                Rectangle()
                    .fill(statusPhosphorColor)
                    .frame(width: 3)
            }
            .overlay(
                Rectangle()
                    .strokeBorder(RetroPalette.border, lineWidth: 1)
            )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Main Cyber Workspace View Container (Switches Between Themes)

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
                PixelRetroWorkspaceView(manager: manager, appState: appState, currentTheme: $workspaceHUDTheme)
            } else {
                ModernWorkspaceView(manager: manager, appState: appState, currentTheme: $workspaceHUDTheme)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: workspaceHUDTheme)
        .onAppear {
            manager.resolveAndRefreshWorkspace(appState: appState)
        }
    }
}
