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

    // Intentional Accents
    static let sage = Color(red: 0.22, green: 0.78, blue: 0.52)         // Clean / HEAD indicator
    static let amber = Color(red: 0.94, green: 0.64, blue: 0.20)        // Modified / Uncommitted
}

// MARK: - Pixel Retro Palette (Amber Phosphor CRT)
// Amber phosphor: warm, aged, distinctly terminal — not radioactive green
// Different from Modern in every dimension: hue family, information density, typography rhythm

private enum RetroPalette {
    static let base = Color(red: 0.04, green: 0.035, blue: 0.02)        // #0A0908 amber CRT black
    static let scanline = Color(red: 0.12, green: 0.10, blue: 0.06)     // subtle scanline row bg

    // Amber phosphor brightness levels
    static let hi   = Color(red: 1.00, green: 0.72, blue: 0.20)         // #FFB833 — bright amber (HEAD, active)
    static let mid  = Color(red: 0.80, green: 0.55, blue: 0.14)         // #CC8C23 — mid phosphor
    static let dim  = Color(red: 0.55, green: 0.38, blue: 0.09)         // #8C6017 — dim phosphor
    static let border = Color(red: 1.00, green: 0.72, blue: 0.20).opacity(0.22)

    // Status
    static let ok   = Color(red: 1.00, green: 0.72, blue: 0.20)         // bright amber — clean
    static let warn = Color(red: 1.00, green: 0.44, blue: 0.14)         // #FF7024 — modified/dirty
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
                // 1px status rail — craft-floor: no colored border above 1px on list items
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

// MARK: - 2. Pixel Retro 8-Bit Workspace View
// Design: Amber phosphor CRT terminal.
// Information architecture is fundamentally different from Modern:
//   - Header: 2-line scanline STATUS STRIP (not a breadcrumb — density over breadth)
//   - Git log: terminal `git log --oneline` with gutter line numbers, no vertical spine
//   - Action bar: prompt-line format `>_ commit message [commit] [push]`
// Rules: ALL Rectangle() — zero RoundedRectangle, zero Circle

// MARK: Retro Terminal Log Row

private struct RetroLogRow: View {
    let lineNum: Int
    let commit: GitCommitItem
    let isLatest: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            // Line number gutter — right-aligned, fixed width
            Text(String(format: "%02d", lineNum))
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundStyle(isHovered ? RetroPalette.mid : RetroPalette.dim)
                .frame(width: 22, alignment: .trailing)
                .padding(.trailing, 8)

            // Hash — sharp, highlighted for HEAD
            Text(commit.hash)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(isLatest ? RetroPalette.hi : RetroPalette.mid)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Rectangle().fill(isLatest ? RetroPalette.hi.opacity(0.12) : Color.clear))
                .overlay(Rectangle().stroke(isLatest ? RetroPalette.hi.opacity(0.35) : Color.clear, lineWidth: 0.75))

            // Ref badge
            if !commit.refs.isEmpty {
                Text(commit.refs)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(RetroPalette.hi)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Rectangle().fill(RetroPalette.hi.opacity(0.10)))
                    .overlay(Rectangle().stroke(RetroPalette.hi.opacity(0.40), lineWidth: 0.75))
                    .padding(.leading, 4)
                    .lineLimit(1)
            }

            // Message — takes remaining space
            Text(commit.message)
                .font(.system(size: 10.5, weight: isLatest ? .medium : .regular, design: .monospaced))
                .foregroundStyle(isLatest ? RetroPalette.hi : RetroPalette.mid)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 7)

            Spacer(minLength: 4)

            // Author + time — right side, dim
            Text("\(commit.author)  \(commit.timeAgo)")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(RetroPalette.dim)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(isHovered ? RetroPalette.scanline : Color.clear)
        .onHover { isHovered = $0 }
        .help("\(commit.hash) · \(commit.author)\n\(commit.message)")
    }
}

// MARK: Retro Two-Line Status Strip

private struct RetroStatusStrip: View {
    let manager: WorkspaceMonitorManager
    let appState: AppState
    let onSwitchFolder: () -> Void
    let onRefresh: () -> Void

    @State private var switchHovered = false
    @State private var refreshHovered = false

    private var activeSession: SessionSnapshot? {
        guard !manager.currentCwd.isEmpty else { return nil }
        return appState.sessions.values.first { $0.cwd == manager.currentCwd }
    }

    private var statusText: String {
        if manager.isCommitting                    { return "PUSHING" }
        else if !manager.changedFiles.isEmpty      { return "MODIFIED \(manager.changedFiles.count)" }
        else                                       { return "CLEAN" }
    }

    private var statusColor: Color {
        if manager.isCommitting                    { return RetroPalette.mid }
        else if !manager.changedFiles.isEmpty      { return RetroPalette.warn }
        else                                       { return RetroPalette.ok }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── ROW 1: project + branch + refresh ───────────────────
            HStack(spacing: 0) {
                Button(action: onSwitchFolder) {
                    HStack(spacing: 4) {
                        Text(manager.projectName.isEmpty ? "WORKSPACE" : manager.projectName.uppercased())
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(switchHovered ? RetroPalette.hi : RetroPalette.mid)
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(switchHovered ? RetroPalette.hi : RetroPalette.dim)
                    }
                }
                .buttonStyle(.plain)
                .onHover { switchHovered = $0 }
                .help("Switch workspace folder")

                Text("  /  ")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(RetroPalette.dim)

                HStack(spacing: 3) {
                    Text(manager.branch)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RetroPalette.mid)
                        .lineLimit(1)

                    if manager.aheadCount > 0 {
                        Text("↑\(manager.aheadCount)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(RetroPalette.ok)
                    }
                    if manager.behindCount > 0 {
                        Text("↓\(manager.behindCount)")
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(RetroPalette.warn)
                    }
                }

                Spacer(minLength: 6)

                Button(action: onRefresh) {
                    Group {
                        if manager.isRefreshing {
                            ProgressView()
                                .scaleEffect(0.32)
                                .frame(width: 9, height: 9)
                        } else {
                            Text("R")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                        }
                    }
                    .foregroundStyle(refreshHovered ? RetroPalette.hi : RetroPalette.dim)
                    .frame(width: 16, height: 16)
                    .background(Rectangle().fill(refreshHovered ? RetroPalette.hi.opacity(0.12) : Color.clear))
                }
                .buttonStyle(.plain)
                .onHover { refreshHovered = $0 }
                .help("Reload git status")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Rectangle().fill(RetroPalette.border).frame(height: 1)

            // ── ROW 2: status + active agent + cwd ──────────────────
            HStack(spacing: 0) {
                Text(statusText)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)

                Text("|")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(RetroPalette.dim)

                if let session = activeSession {
                    let name = session.mascotSource.isEmpty ? session.source.uppercased() : session.mascotSource.uppercased()
                    HStack(spacing: 4) {
                        if let icon = cliIcon(source: session.source, size: 10) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 10, height: 10)
                        }
                        Text(name)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(RetroPalette.mid)

                        if let model = session.modelLabel ?? session.model, !model.isEmpty {
                            Text(model)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(RetroPalette.dim)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                } else {
                    Text("  NO AGENT")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RetroPalette.dim)
                        .padding(.horizontal, 8)
                }

                Spacer(minLength: 0)

                Text(manager.currentCwd)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(RetroPalette.dim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
            }
        }
        .background(Rectangle().fill(RetroPalette.scanline))
        .overlay(Rectangle().stroke(RetroPalette.border, lineWidth: 1))
    }
}

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
                // ── NO GIT STATE ──────────────────────────────────────────
                VStack(spacing: 10) {
                    Text("NO GIT REPO")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(RetroPalette.warn)

                    Text(manager.currentCwd.isEmpty ? "NO WORKSPACE SELECTED" : manager.currentCwd)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(RetroPalette.dim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 20)

                    Button(action: {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                        manager.chooseWorkspaceFolder()
                    }) {
                        Text(">_ SELECT WORKSPACE")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(RetroPalette.hi)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4.5)
                            .background(Rectangle().fill(Color.clear))
                            .overlay(Rectangle().stroke(RetroPalette.mid, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .padding(.vertical, 12)

            } else {
                VStack(spacing: 0) {

                    // ── TWO-LINE SCANLINE STATUS STRIP ───────────────────────
                    RetroStatusStrip(
                        manager: manager,
                        appState: appState,
                        onSwitchFolder: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.chooseWorkspaceFolder()
                        },
                        onRefresh: {
                            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                            manager.refresh(force: true)
                        }
                    )

                    // ── TERMINAL GIT LOG ─────────────────────────────────────
                    // No vertical spine. Gutter line numbers are the navigational anchor.
                    VStack(alignment: .leading, spacing: 0) {
                        if manager.recentCommits.isEmpty {
                            HStack(spacing: 8) {
                                Text("00")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(RetroPalette.dim)
                                    .frame(width: 22, alignment: .trailing)
                                Text("no commits recorded")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(RetroPalette.dim)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
                        } else {
                            ForEach(Array(manager.recentCommits.prefix(3).enumerated()), id: \.element.id) { index, commit in
                                RetroLogRow(
                                    lineNum: index + 1,
                                    commit: commit,
                                    isLatest: index == 0
                                )
                                if index < min(2, manager.recentCommits.count - 1) {
                                    Rectangle()
                                        .fill(RetroPalette.border.opacity(0.5))
                                        .frame(height: 1)
                                        .padding(.leading, 30)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)

                    Rectangle().fill(RetroPalette.border).frame(height: 1)

                    // ── PROMPT ACTION BAR ────────────────────────────────────
                    // Terminal prompt: `>_ [action] [input] [commit] [push]`
                    if manager.changedFiles.isEmpty {
                        HStack(spacing: 8) {
                            Text(">_")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(RetroPalette.ok)
                                .padding(.leading, 10)

                            Text("working tree clean")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(RetroPalette.mid)

                            Spacer(minLength: 0)

                            if let status = manager.commitStatusMessage {
                                Text(status)
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(RetroPalette.ok)
                                    .transition(.opacity)
                            }

                            Button(action: {
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                NSWorkspace.shared.open(URL(fileURLWithPath: manager.currentCwd))
                            }) {
                                Text("open")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(openHovered ? RetroPalette.base : RetroPalette.mid)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Rectangle().fill(openHovered ? RetroPalette.mid : Color.clear))
                                    .overlay(Rectangle().stroke(RetroPalette.mid.opacity(0.6), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .onHover { openHovered = $0 }
                            .padding(.trailing, 10)
                        }
                        .padding(.vertical, 5)

                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 0) {
                                Text(">_")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(RetroPalette.warn)
                                    .padding(.leading, 10)
                                    .padding(.trailing, 6)

                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        manager.generateAICommitMessage()
                                    }
                                }) {
                                    Text("AI")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(aiHovered ? RetroPalette.base : RetroPalette.mid)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3.5)
                                        .background(Rectangle().fill(aiHovered ? RetroPalette.mid : Color.clear))
                                        .overlay(Rectangle().stroke(RetroPalette.mid.opacity(0.5), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .onHover { aiHovered = $0 }
                                .help("Auto-generate conventional commit message")
                                .padding(.trailing, 5)

                                ZStack(alignment: .leading) {
                                    if manager.proposedCommitMessage.isEmpty {
                                        Text("commit message...")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(RetroPalette.dim)
                                            .padding(.horizontal, 6)
                                            .allowsHitTesting(false)
                                    }
                                    TextField("", text: $manager.proposedCommitMessage)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(RetroPalette.hi)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 4)
                                }
                                .background(
                                    Rectangle()
                                        .fill(Color.clear)
                                        .overlay(Rectangle().stroke(RetroPalette.border, lineWidth: 0.75))
                                )
                                .padding(.trailing, 5)

                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: false)
                                }) {
                                    Text(manager.isCommitting ? "..." : "commit")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(
                                            manager.proposedCommitMessage.isEmpty
                                                ? RetroPalette.dim
                                                : (commitHovered ? RetroPalette.base : RetroPalette.hi)
                                        )
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3.5)
                                        .background(
                                            Rectangle().fill(
                                                manager.proposedCommitMessage.isEmpty
                                                    ? Color.clear
                                                    : (commitHovered ? RetroPalette.hi : Color.clear)
                                            )
                                        )
                                        .overlay(
                                            Rectangle().stroke(
                                                manager.proposedCommitMessage.isEmpty
                                                    ? RetroPalette.dim.opacity(0.4)
                                                    : RetroPalette.hi.opacity(0.7),
                                                lineWidth: 1
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { commitHovered = $0 }
                                .padding(.trailing, 4)

                                Button(action: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                                    manager.executeCommit(message: manager.proposedCommitMessage, push: true)
                                }) {
                                    HStack(spacing: 2) {
                                        Text("push")
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        Image(systemName: "arrow.up")
                                            .font(.system(size: 7, weight: .bold))
                                    }
                                    .foregroundStyle(pushHovered ? RetroPalette.base : RetroPalette.mid)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3.5)
                                    .background(Rectangle().fill(pushHovered ? RetroPalette.mid : Color.clear))
                                    .overlay(Rectangle().stroke(RetroPalette.mid.opacity(0.5), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(manager.isCommitting || manager.proposedCommitMessage.isEmpty)
                                .onHover { pushHovered = $0 }
                                .padding(.trailing, 10)
                            }
                            .padding(.vertical, 5)

                            if let status = manager.commitStatusMessage {
                                HStack(spacing: 6) {
                                    Text(">_")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(RetroPalette.ok)
                                    Text(status)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(RetroPalette.ok)
                                }
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                                .transition(.opacity)
                            }
                        }
                    }
                }
            }
        }
        .background(
            Rectangle()
                .fill(RetroPalette.base)
                .overlay(Rectangle().stroke(RetroPalette.border, lineWidth: 1))
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
