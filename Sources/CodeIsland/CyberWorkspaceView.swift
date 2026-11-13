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

// MARK: - 2. Pixel Retro Palette (Arcade Dev Cartridge / PICO-8 Cyber)
// High-contrast, sharp 1-bit / 2-bit engineering craft with crisp phosphor mint & ice cyan.

private enum RetroArcadePalette {
    static let bgVoid = Color(red: 0.03, green: 0.035, blue: 0.045)     // #08090C Pitch Void
    static let panelBg = Color(red: 0.065, green: 0.08, blue: 0.11)     // #10141C Hardware Panel Fill
    static let slotBg = Color(red: 0.09, green: 0.11, blue: 0.15)      // #171C26 Slot background
    static let slotHover = Color(red: 0.13, green: 0.16, blue: 0.22)   // #212938 Active hover

    // Sharp Pixel Borders
    static let border = Color(red: 0.18, green: 0.23, blue: 0.31)       // #2E3B4F 1px frame border
    static let borderBright = Color(red: 0.28, green: 0.35, blue: 0.46) // #475975 Highlight border

    // Text
    static let textStark = Color(red: 0.96, green: 0.98, blue: 1.0)     // #F5FAFF Pure white
    static let textMuted = Color(red: 0.55, green: 0.62, blue: 0.72)     // #8D9EB8 Slate text
    static let textDim = Color(red: 0.35, green: 0.40, blue: 0.49)       // #59667D Dim micro labels

    // Precision Accents
    static let mint = Color(red: 0.0, green: 1.0, blue: 0.64)           // #00FFA3 Electric Phosphor Mint
    static let cyan = Color(red: 0.22, green: 0.74, blue: 0.97)          // #38BDF8 Ice Cyan
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.02)         // #FFC005 Quest Amber
    static let coral = Color(red: 1.0, green: 0.35, blue: 0.38)         // #FF5961 Dirty Coral
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

// MARK: - 2. Pixel Retro 8-Bit Arcade Cartridge HUD
// Radical layout departure: Handheld Arcade Dev Console (Game Boy / PICO-8 / Analogue Pocket).
// - Top: Dual-cell HUD Cartridge Banner (Project Cartridge [ROM] + Live Branch Gauges)
// - Middle: Asymmetric Split Screen:
//     • [ACTIVE CHECKPOINT / HEAD] Hero Card with bold commit message
//     • [PREVIOUS QUEST LOGS] Compact 2-item history ledger
// - Bottom: Dedicated 8-bit Command Deck with split Action Keys

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
                // Non-Git State (Empty Cartridge)
                VStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Rectangle().fill(RetroArcadePalette.coral).frame(width: 8, height: 8)
                        Text("[ NO CARTRIDGE INSERTED ]")
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(RetroArcadePalette.coral)
                    }

                    Text(manager.currentCwd.isEmpty ? "SELECT WORKSPACE DIRECTORY" : manager.currentCwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RetroArcadePalette.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 20)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        HStack(spacing: 5) {
                            Text("▶")
                                .font(.system(size: 9))
                                .foregroundStyle(RetroArcadePalette.mint)
                            Text("MOUNT REPOSITORY")
                                .font(.system(size: 9.5, weight: .black, design: .monospaced))
                                .foregroundStyle(RetroArcadePalette.textStark)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Rectangle().fill(RetroArcadePalette.slotBg))
                        .overlay(Rectangle().stroke(RetroArcadePalette.mint, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 115)
                .padding(.vertical, 12)

            } else {
                VStack(spacing: 6) {

                    // ========================================================
                    // 1. TOP CARTRIDGE STATUS HUD STRIP
                    // ========================================================
                    HStack(alignment: .center, spacing: 5) {
                        // Cartridge Label
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.chooseWorkspaceFolder()
                        }) {
                            HStack(spacing: 4) {
                                Text("ROM")
                                    .font(.system(size: 8, weight: .black, design: .monospaced))
                                    .foregroundStyle(Color.black)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Rectangle().fill(RetroArcadePalette.mint))

                                Text(manager.projectName.isEmpty ? "CODE" : manager.projectName.uppercased())
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .foregroundStyle(switchHovered ? RetroArcadePalette.mint : RetroArcadePalette.textStark)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(Rectangle().fill(RetroArcadePalette.slotBg))
                            .overlay(Rectangle().stroke(switchHovered ? RetroArcadePalette.mint : RetroArcadePalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { switchHovered = $0 }
                        .help("Swap workspace folder")

                        // Branch & Sync Indicator
                        HStack(spacing: 4) {
                            Text("⎇ \(manager.branch.uppercased())")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroArcadePalette.cyan)
                                .lineLimit(1)

                            if manager.aheadCount > 0 || manager.behindCount > 0 {
                                HStack(spacing: 2) {
                                    if manager.aheadCount > 0 {
                                        Text("↑\(manager.aheadCount)")
                                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.mint)
                                    }
                                    if manager.behindCount > 0 {
                                        Text("↓\(manager.behindCount)")
                                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.coral)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(Rectangle().fill(RetroArcadePalette.slotBg))
                        .overlay(Rectangle().stroke(RetroArcadePalette.border, lineWidth: 1))

                        // Status Gauge
                        if manager.changedFiles.isEmpty {
                            Text("● CAUGHT UP")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroArcadePalette.mint)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 2.5)
                                .background(Rectangle().fill(RetroArcadePalette.mint.opacity(0.12)))
                        } else {
                            Text("▲ \(manager.changedFiles.count) MODS")
                                .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                .foregroundStyle(RetroArcadePalette.amber)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 2.5)
                                .background(Rectangle().fill(RetroArcadePalette.amber.opacity(0.14)))
                        }

                        Spacer(minLength: 2)

                        // Active Session Mascot Cartridge
                        if let session = activeSession {
                            HStack(spacing: 3) {
                                if let icon = cliIcon(source: session.source, size: 9) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 9, height: 9)
                                }
                                Text(session.source.uppercased())
                                    .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                    .foregroundStyle(RetroArcadePalette.textStark)

                                if let model = session.modelLabel ?? session.model, !model.isEmpty {
                                    Text("[\(model)]")
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(RetroArcadePalette.textMuted)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2.5)
                            .background(Rectangle().fill(RetroArcadePalette.slotBg))
                            .overlay(Rectangle().stroke(RetroArcadePalette.border, lineWidth: 1))
                        }

                        // Refresh Tactile Key
                        Button(action: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }) {
                            Text("SYNC")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundStyle(refreshHovered ? Color.black : RetroArcadePalette.textMuted)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2.5)
                                .background(Rectangle().fill(refreshHovered ? RetroArcadePalette.mint : RetroArcadePalette.slotBg))
                                .overlay(Rectangle().stroke(refreshHovered ? RetroArcadePalette.mint : RetroArcadePalette.border, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onHover { refreshHovered = $0 }
                        .help("Reload workspace status")
                    }

                    // ========================================================
                    // 2. QUEST LOG: ASYMMETRIC DUAL-SECTION COMMIT DISPLAY
                    // ========================================================
                    VStack(spacing: 4) {
                        // 2A. ACTIVE CHECKPOINT (HEAD HERO CARD)
                        if let head = latestCommit {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text("▶ HEAD")
                                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                        .foregroundStyle(RetroArcadePalette.mint)

                                    Text("[\(head.hash)]")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(RetroArcadePalette.cyan)

                                    if !head.refs.isEmpty {
                                        Text("{\(head.refs)}")
                                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.amber)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 0)

                                    Text("\(head.author) · \(head.timeAgo)")
                                        .font(.system(size: 8.5, design: .monospaced))
                                        .foregroundStyle(RetroArcadePalette.textDim)
                                }

                                Text(head.message)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroArcadePalette.textStark)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Rectangle().fill(RetroArcadePalette.slotBg))
                            .overlay(
                                Rectangle()
                                    .stroke(RetroArcadePalette.borderBright, lineWidth: 1)
                            )
                        } else {
                            HStack {
                                Text("NO COMMITS RECORDED ON THIS BRANCH")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroArcadePalette.textDim)
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(Rectangle().fill(RetroArcadePalette.slotBg))
                        }

                        // 2B. PREVIOUS ARCHIVES LEDGER (COMPACT 2-LINE STRIP)
                        if !previousCommits.isEmpty {
                            VStack(spacing: 2) {
                                ForEach(previousCommits, id: \.id) { prev in
                                    HStack(spacing: 6) {
                                        Text("•")
                                            .font(.system(size: 8, weight: .black))
                                            .foregroundStyle(RetroArcadePalette.textDim)

                                        Text(prev.hash)
                                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.textMuted)

                                        Text(prev.message)
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.tail)

                                        Spacer(minLength: 0)

                                        Text(prev.timeAgo)
                                            .font(.system(size: 8, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.textDim)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    // ========================================================
                    // 3. TACTILE COMMAND DECK (ACTION BAR)
                    // ========================================================
                    if manager.changedFiles.isEmpty {
                        // Clean Tree State
                        HStack(spacing: 8) {
                            Text(manager.currentCwd)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(RetroArcadePalette.textDim)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundStyle(RetroArcadePalette.mint)
                                    .transition(.opacity)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                NSWorkspace.shared.open(URL(fileURLWithPath: manager.currentCwd))
                            }) {
                                HStack(spacing: 3) {
                                    Text("OPEN FOLDER")
                                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                }
                                .foregroundStyle(openHovered ? Color.black : RetroArcadePalette.textStark)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Rectangle().fill(openHovered ? RetroArcadePalette.mint : RetroArcadePalette.slotBg))
                                .overlay(Rectangle().stroke(openHovered ? RetroArcadePalette.mint : RetroArcadePalette.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { openHovered = $0 }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)

                    } else {
                        // Dirty Working Tree Command Deck
                        VStack(spacing: 4) {
                            // Row 1: Bracket Input Field
                            HStack(spacing: 4) {
                                Text("MSG >")
                                    .font(.system(size: 9, weight: .black, design: .monospaced))
                                    .foregroundStyle(RetroArcadePalette.amber)

                                ZStack(alignment: .leading) {
                                    if manager.proposedCommitMessage.isEmpty {
                                        Text("TYPE COMMIT MESSAGE...")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(RetroArcadePalette.textDim)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $manager.proposedCommitMessage)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(RetroArcadePalette.textStark)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Rectangle().fill(RetroArcadePalette.slotBg))
                            .overlay(Rectangle().stroke(RetroArcadePalette.borderBright, lineWidth: 1))

                            // Row 2: Action Button Deck
                            HStack(spacing: 5) {
                                // Auto Suggest
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        manager.generateAICommitMessage()
                                    }
                                }) {
                                    HStack(spacing: 3) {
                                        Text("✨")
                                            .font(.system(size: 7))
                                        Text("AI DRAFT")
                                            .font(.system(size: 8.5, weight: .black, design: .monospaced))
                                    }
                                    .foregroundStyle(aiHovered ? Color.black : RetroArcadePalette.cyan)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3.5)
                                    .background(Rectangle().fill(aiHovered ? RetroArcadePalette.cyan : RetroArcadePalette.slotBg))
                                    .overlay(Rectangle().stroke(RetroArcadePalette.cyan.opacity(0.6), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .onHover { aiHovered = $0 }
                                .help("Auto-generate conventional commit message")

                                Spacer(minLength: 0)

                                // Commit
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                                }) {
                                    Text(manager.isCommitting ? "SAVING..." : "▶ COMMIT")
                                        .font(.system(size: 9, weight: .black, design: .monospaced))
                                        .foregroundStyle(
                                            manager.proposedCommitMessage.isEmpty
                                                ? RetroArcadePalette.textDim
                                                : (commitHovered ? Color.white : Color.black)
                                        )
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(
                                            Rectangle().fill(
                                                manager.proposedCommitMessage.isEmpty
                                                    ? RetroArcadePalette.slotBg
                                                    : (commitHovered ? RetroArcadePalette.mint.opacity(0.85) : RetroArcadePalette.mint)
                                            )
                                        )
                                        .overlay(
                                            Rectangle().stroke(
                                                manager.proposedCommitMessage.isEmpty
                                                    ? RetroArcadePalette.border
                                                    : RetroArcadePalette.mint,
                                                lineWidth: 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { commitHovered = $0 }

                                // Push
                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                                }) {
                                    HStack(spacing: 2) {
                                        Text("⇡ PUSH")
                                            .font(.system(size: 9, weight: .black, design: .monospaced))
                                    }
                                    .foregroundStyle(pushHovered ? Color.black : RetroArcadePalette.textStark)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Rectangle().fill(pushHovered ? RetroArcadePalette.mint : RetroArcadePalette.slotBg))
                                    .overlay(Rectangle().stroke(pushHovered ? RetroArcadePalette.mint : RetroArcadePalette.border, lineWidth: 1))
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
                Rectangle().fill(RetroArcadePalette.bgVoid)
                // Left 2px Cartridge Edge Accent
                Rectangle()
                    .fill(manager.changedFiles.isEmpty ? RetroArcadePalette.mint : RetroArcadePalette.amber)
                    .frame(width: 2)
            }
            .overlay(
                Rectangle()
                    .stroke(RetroArcadePalette.border, lineWidth: 1.5)
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
