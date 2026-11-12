import Foundation
import Combine
import SwiftUI
import AppKit

// MARK: - Git Models

public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let filename: String
    public let status: String // "M", "A", "D", "??", "R"
    public let isStaged: Bool

    public init(path: String, filename: String, status: String, isStaged: Bool) {
        self.path = path
        self.filename = filename
        self.status = status
        self.isStaged = isStaged
    }

    public var statusLabel: String {
        switch status {
        case "M": return "MODIFIED"
        case "A": return "ADDED"
        case "D": return "DELETED"
        case "??": return "UNTRACKED"
        case "R": return "RENAMED"
        default: return status
        }
    }

    public var statusColor: Color {
        switch status {
        case "M": return Color(red: 0.96, green: 0.62, blue: 0.04) // Neon Amber
        case "A", "??": return Color(red: 0.0, green: 0.90, blue: 0.46) // Emerald
        case "D": return Color(red: 1.0, green: 0.16, blue: 0.53) // Magenta/Red
        default: return Color(white: 0.6)
        }
    }
}

public struct GitCommitItem: Identifiable, Equatable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let message: String
    public let author: String
    public let timeAgo: String
    public let refs: String

    public init(hash: String, message: String, author: String, timeAgo: String, refs: String = "") {
        self.hash = hash
        self.message = message
        self.author = author
        self.timeAgo = timeAgo
        self.refs = refs.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
    }
}

// MARK: - Workspace Monitor Manager

@MainActor
public final class WorkspaceMonitorManager: ObservableObject {
    public static let shared = WorkspaceMonitorManager()

    @Published public var currentCwd: String = ""
    @Published public var projectName: String = "Workspace"
    @Published public var branch: String = "main"
    @Published public var isGitRepo: Bool = false
    @Published public var aheadCount: Int = 0
    @Published public var behindCount: Int = 0
    @Published public var insertions: Int = 0
    @Published public var deletions: Int = 0
    @Published public var changedFiles: [GitFileChange] = []
    @Published public var recentCommits: [GitCommitItem] = []
    @Published public var isExpandedDetail: Bool = false
    @Published public var isRefreshing: Bool = false
    @Published public var proposedCommitMessage: String = ""
    @Published public var isCommitting: Bool = false
    @Published public var commitStatusMessage: String? = nil
    @Published public var isUserPinned: Bool = UserDefaults.standard.bool(forKey: "workspaceIsUserPinned")

    private var lastRefreshTime: Date = .distantPast
    private var refreshTask: Task<Void, Never>? = nil

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "lastWorkspaceCwd"),
           !saved.isEmpty, FileManager.default.fileExists(atPath: saved) {
            self.currentCwd = saved
            self.projectName = (saved as NSString).lastPathComponent
            refresh(force: true)
        }
    }

    public func updateCwdIfNeeded(_ cwd: String?, forceUserPinned: Bool = false) {
        guard let cwd = cwd, !cwd.isEmpty else { return }
        // If user manually chose/pinned a workspace, do not overwrite with background agent hooks
        if isUserPinned && !forceUserPinned && cwd != currentCwd {
            return
        }
        if forceUserPinned {
            isUserPinned = true
            UserDefaults.standard.set(true, forKey: "workspaceIsUserPinned")
        }
        if cwd != currentCwd || !isGitRepo {
            currentCwd = cwd
            projectName = (cwd as NSString).lastPathComponent
            UserDefaults.standard.set(cwd, forKey: "lastWorkspaceCwd")
            refresh(force: true)
        }
    }

    /// Ultra-fast, zero-leak workspace resolution directly from active agent sessions and memory
    func resolveAndRefreshWorkspace(appState: AppState) {
        // If user pinned a workspace, always respect it
        if isUserPinned && !currentCwd.isEmpty && FileManager.default.fileExists(atPath: currentCwd) {
            refresh(force: false)
            return
        }

        let isConfigDir = { (path: String) -> Bool in
            path.hasSuffix("/.gemini/config") || path.hasSuffix("/.config") || path.contains("/.gemini/")
        }

        // 1. Instant In-Memory: Active agent session cwd
        if let sid = appState.activeSessionId, let cwd = appState.sessions[sid]?.cwd,
           !cwd.isEmpty, !isConfigDir(cwd), FileManager.default.fileExists(atPath: cwd) {
            updateCwdIfNeeded(cwd)
            return
        }

        // 2. Instant In-Memory: Any running session cwd
        for session in appState.sessions.values {
            if let cwd = session.cwd, !cwd.isEmpty, !isConfigDir(cwd), FileManager.default.fileExists(atPath: cwd) {
                updateCwdIfNeeded(cwd)
                return
            }
        }

        // 3. Current active workspace if already set
        if !currentCwd.isEmpty && FileManager.default.fileExists(atPath: currentCwd) {
            refresh(force: false)
            return
        }

        // 4. Saved workspace in UserDefaults
        if let saved = UserDefaults.standard.string(forKey: "lastWorkspaceCwd"),
           !saved.isEmpty, !isConfigDir(saved), FileManager.default.fileExists(atPath: saved) {
            updateCwdIfNeeded(saved)
            return
        }
    }

    public func chooseWorkspaceFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.level = .floating
        panel.title = "Select Git Workspace / Project Folder"
        panel.prompt = "Choose Workspace"

        if panel.runModal() == .OK, let url = panel.url {
            updateCwdIfNeeded(url.path, forceUserPinned: true)
        }
    }

    func resetToAutoDetect(appState: AppState? = nil) {
        isUserPinned = false
        UserDefaults.standard.set(false, forKey: "workspaceIsUserPinned")
        if let appState = appState {
            resolveAndRefreshWorkspace(appState: appState)
        } else {
            refresh(force: true)
        }
    }

    public func refresh(force: Bool = false) {
        guard !currentCwd.isEmpty else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastRefreshTime) < 1.5 {
            return
        }
        lastRefreshTime = now

        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .userInitiated) { [weak self, cwd = currentCwd] in
            guard let self else { return }
            await MainActor.run { [weak self] in
                self?.isRefreshing = true
            }

            let gitBinary = "/usr/bin/git"
            let fm = FileManager.default

            // 1. Check if git repo exists
            var isDir: ObjCBool = false
            let hasGit = fm.fileExists(atPath: cwd + "/.git", isDirectory: &isDir)

            if !hasGit {
                // Check git rev-parse inside
                let revData = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "rev-parse", "--is-inside-work-tree"], timeout: 2.5)
                let inside = revData.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
                guard inside else {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.isGitRepo = false
                        self.isRefreshing = false
                    }
                    return
                }
            }

            // 2. Fetch branch & remote tracking (ahead/behind) & changed files
            var branchName = "main"
            var ahead = 0
            var behind = 0
            var files: [GitFileChange] = []

            if let statusData = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "status", "--porcelain=v1", "-b"], timeout: 3.5),
               let statusText = String(data: statusData, encoding: .utf8) {
                let lines = statusText.components(separatedBy: "\n")
                for line in lines {
                    if line.hasPrefix("##") {
                        // e.g. ## main...origin/main [ahead 1, behind 2]
                        let branchInfo = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                        if let dotsIdx = branchInfo.range(of: "...") {
                            branchName = String(branchInfo[..<dotsIdx.lowerBound])
                        } else if let spaceIdx = branchInfo.range(of: " ") {
                            branchName = String(branchInfo[..<spaceIdx.lowerBound])
                        } else {
                            branchName = branchInfo
                        }
                        if let aheadIdx = branchInfo.range(of: "ahead ") {
                            let sub = branchInfo[aheadIdx.upperBound...]
                            ahead = Int(sub.prefix(while: { $0.isNumber })) ?? 0
                        }
                        if let behindIdx = branchInfo.range(of: "behind ") {
                            let sub = branchInfo[behindIdx.upperBound...]
                            behind = Int(sub.prefix(while: { $0.isNumber })) ?? 0
                        }
                    } else if line.count >= 3 {
                        let code = String(line.prefix(2)).trimmingCharacters(in: .whitespaces)
                        let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        if !path.isEmpty {
                            let filename = (path as NSString).lastPathComponent
                            files.append(GitFileChange(
                                path: path,
                                filename: filename,
                                status: code.isEmpty ? "M" : code,
                                isStaged: line.hasPrefix("M ") || line.hasPrefix("A ")
                            ))
                        }
                    }
                }
            }

            // 3. Fetch diff shortstat (insertions & deletions)
            var ins = 0
            var del = 0
            if let diffData = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "diff", "--shortstat"], timeout: 3.0),
               let diffText = String(data: diffData, encoding: .utf8) {
                if let insIdx = diffText.range(of: "insertion") {
                    let sub = diffText[..<insIdx.lowerBound].trimmingCharacters(in: .whitespaces)
                    let numStr = sub.components(separatedBy: ",").last?.components(separatedBy: " ").filter({ !$0.isEmpty }).last ?? ""
                    ins = Int(numStr) ?? 0
                }
                if let delIdx = diffText.range(of: "deletion") {
                    let sub = diffText[..<delIdx.lowerBound].trimmingCharacters(in: .whitespaces)
                    let numStr = sub.components(separatedBy: ",").last?.components(separatedBy: " ").filter({ !$0.isEmpty }).last ?? ""
                    del = Int(numStr) ?? 0
                }
            }

            // 4. Fetch recent commits (last 12 for git graph)
            var commits: [GitCommitItem] = []
            if let logData = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "log", "-n", "12", "--pretty=format:%h|||%s|||%an|||%ar|||%d"], timeout: 3.5),
               let logText = String(data: logData, encoding: .utf8) {
                let lines = logText.components(separatedBy: "\n")
                for line in lines where !line.isEmpty {
                    let parts = line.components(separatedBy: "|||")
                    if parts.count >= 4 {
                        commits.append(GitCommitItem(
                            hash: parts[0],
                            message: parts[1],
                            author: parts[2],
                            timeAgo: parts[3],
                            refs: parts.count >= 5 ? parts[4] : ""
                        ))
                    }
                }
            }

            let finalBranch = branchName
            let finalAhead = ahead
            let finalBehind = behind
            let finalIns = ins
            let finalDel = del
            let finalFiles = files
            let finalCommits = commits

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isGitRepo = true
                self.branch = finalBranch
                self.aheadCount = finalAhead
                self.behindCount = finalBehind
                self.insertions = finalIns
                self.deletions = finalDel
                self.changedFiles = finalFiles
                self.recentCommits = finalCommits
                self.isRefreshing = false
            }
        }
    }

    // MARK: - AI Smart Git Commit

    public func generateAICommitMessage() {
        guard !changedFiles.isEmpty else {
            proposedCommitMessage = "chore: clean up workspace"
            return
        }

        let paths = changedFiles.map(\.path)
        let statuses = changedFiles.map(\.status)

        // Detect primary type
        let isFix = statuses.contains("M") && paths.contains { $0.lowercased().contains("fix") || $0.lowercased().contains("bug") }
        let isDocs = paths.allSatisfy { $0.hasSuffix(".md") || $0.hasSuffix(".txt") }
        let isTest = paths.allSatisfy { $0.contains("Test") || $0.contains("test") }

        let type: String
        if isDocs {
            type = "docs"
        } else if isTest {
            type = "test"
        } else if isFix {
            type = "fix"
        } else if statuses.contains("A") || statuses.contains("??") {
            type = "feat"
        } else {
            type = "refactor"
        }

        // Detect primary scope
        var scope = "workspace"
        if paths.contains(where: { $0.contains("Music") || $0.contains("Lyric") }) {
            scope = "music"
        } else if paths.contains(where: { $0.contains("Workspace") || $0.contains("Git") }) {
            scope = "workspace"
        } else if paths.contains(where: { $0.contains("Notch") || $0.contains("Panel") }) {
            scope = "notch"
        } else if paths.contains(where: { $0.contains("Theme") || $0.contains("Style") }) {
            scope = "theme"
        } else if paths.contains(where: { $0.contains("Settings") }) {
            scope = "settings"
        } else if let first = paths.first {
            let base = (first as NSString).lastPathComponent.components(separatedBy: ".").first ?? "core"
            scope = String(base.prefix(12).lowercased())
        }

        // Summary subject
        let count = changedFiles.count
        let subject: String
        if count == 1, let file = changedFiles.first {
            subject = "\(file.status == "A" ? "add" : "update") \(file.filename)"
        } else {
            subject = "update \(count) files across \(scope)"
        }

        proposedCommitMessage = "\(type)(\(scope)): \(subject)"
    }

    public func executeCommit(message: String, push: Bool = false) {
        guard !message.isEmpty, isGitRepo, !currentCwd.isEmpty else { return }
        isCommitting = true
        commitStatusMessage = "Staging & committing..."
        let cwd = currentCwd

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let gitBinary = "/usr/bin/git"
            // 1. git add -A
            _ = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "add", "-A"], timeout: 6)

            // 2. git commit -m message
            _ = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "commit", "-m", message], timeout: 8)

            // 3. Optional push
            if push {
                await MainActor.run { [weak self] in
                    self?.commitStatusMessage = "Pushing to remote..."
                }
                _ = ProcessRunner.run(path: gitBinary, args: ["-C", cwd, "push"], timeout: 15)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isCommitting = false
                self.commitStatusMessage = push ? "Committed & pushed!" : "Committed successfully!"
                self.proposedCommitMessage = ""
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                self.refresh(force: true)

                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    self?.commitStatusMessage = nil
                }
            }
        }
    }
}
