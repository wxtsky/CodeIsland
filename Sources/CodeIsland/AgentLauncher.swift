// Agent 调用执行器：负责向目标 Agent 发送 Prompt
import AppKit
import CodeIslandCore
import CoreGraphics
import os.log

@MainActor
class AgentLauncher {
    static let shared = AgentLauncher()
    private static let log = Logger(subsystem: "com.codeisland", category: "AgentLauncher")

    // MARK: - Public API

    func launch(
        rule: CollaborationRule,
        sourceAgent: String,
        context: String,
        cwd: String?,
        targetSession: SessionSnapshot? = nil
    ) {
        let language = L10n.shared.effectiveLanguage
        let prompt = PromptTemplateManager.buildPrompt(
            rule: rule,
            sourceAgent: sourceAgent,
            context: context,
            language: language
        )

        if rule.targetAgent.isIDE {
            launchIDEAgent(target: rule.targetAgent, prompt: prompt, cwd: cwd, targetSession: targetSession)
        } else {
            launchCLIAgent(target: rule.targetAgent, prompt: prompt, cwd: cwd, targetSession: targetSession)
        }
    }

    // MARK: - CLI Agent (clipboard + paste into existing session, or new Terminal)

    private func launchCLIAgent(target: AgentTargetType, prompt: String, cwd: String?, targetSession: SessionSnapshot?) {
        if let session = targetSession {
            Self.log.info("Injecting prompt into existing \(target.rawValue) session via clipboard+paste")
            pastePromptIntoSession(session: session, prompt: prompt)
            return
        }

        // Fallback: no existing session, open in Terminal.app
        guard let binary = target.findBinary() else {
            Self.log.error("CLI binary not found for \(target.rawValue)")
            return
        }

        Self.log.info("No existing session found, launching \(target.rawValue) in Terminal.app")
        let dir = cwd ?? NSHomeDirectory()
        func shellEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "'", with: "'\\''")
        }
        let cmd = "cd '\(shellEscape(dir))' && CODEISLAND_SKIP=1 '\(shellEscape(binary))' -p '\(shellEscape(prompt))'"
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        Task.detached {
            guard let script = NSAppleScript(source: appleScript) else { return }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            await MainActor.run {
                if error != nil {
                    Self.log.error("Terminal AppleScript failed")
                } else {
                    Self.log.info("CLI agent \(target.rawValue) launched in Terminal.app")
                }
            }
        }
    }

    // MARK: - IDE Agent (Cursor: ⌘I, CodeBuddy: ⌃⌘I pipeline)

    private func launchIDEAgent(target: AgentTargetType, prompt: String, cwd: String?, targetSession: SessionSnapshot?) {
        // Activate correct window via session or bundle ID
        if let session = targetSession {
            TerminalActivator.activate(session: session)
        } else {
            // No session — activate by bundle ID
            for bid in target.appBundleIds {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    break
                }
            }
        }

        switch target {
        case .cursor:
            launchCursorAgent(prompt: prompt)
        case .codebuddy:
            launchCodeBuddyAgent(prompt: prompt, cwd: cwd)
        default:
            Self.log.warning("IDE agent \(target.rawValue) not yet supported")
        }
    }

    // MARK: - Cursor: ⌘I opens inline chat, paste prompt, Enter

    private func launchCursorAgent(prompt: String) {
        Self.log.info("Launching Cursor agent via ⌘I + clipboard paste")

        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        Task.detached {
            // Wait for window activation
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                let src = CGEventSource(stateID: .hidSystemState)
                // ⌘I to open Cursor Composer/Chat
                Self.postKey(src: src, keyCode: 34, flags: .maskCommand)
            }
            // Wait for chat panel to open
            try? await Task.sleep(nanoseconds: 800_000_000)
            await MainActor.run {
                // ⌘V paste
                Self.postKey(src: CGEventSource(stateID: .hidSystemState), keyCode: 9, flags: .maskCommand)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                // Enter to submit
                Self.postKey(src: CGEventSource(stateID: .hidSystemState), keyCode: 36)
            }
            // Restore clipboard
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                if let old = oldContents {
                    pasteboard.clearContents()
                    pasteboard.setString(old, forType: .string)
                }
            }
        }
    }

    // MARK: - CodeBuddy: write file in project dir -> buddycn -r -> ⌘A -> ⌃⌘I -> "." -> Enter

    private func launchCodeBuddyAgent(prompt: String, cwd: String?) {
        let home = NSHomeDirectory()
        let buddycn = ["\(home)/.codebuddy/bin/buddycn"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }

        guard let buddycn else {
            Self.log.error("buddycn CLI not found")
            return
        }

        let dir = cwd ?? NSTemporaryDirectory()
        let tmpFile = (dir as NSString).appendingPathComponent(
            ".codeisland-collab-\(Int(Date().timeIntervalSince1970)).txt"
        )

        Self.log.info("Launching CodeBuddy agent in \(dir)")

        Task.detached {
            do {
                try prompt.write(toFile: tmpFile, atomically: true, encoding: .utf8)

                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: buddycn)
                proc.arguments = ["-r", tmpFile]
                try proc.run()
                proc.waitUntilExit()

                try await Task.sleep(nanoseconds: 1_500_000_000)

                await MainActor.run {
                    Self.simulateCodeBuddyChat()
                }

                try await Task.sleep(nanoseconds: 3_000_000_000)
                try? FileManager.default.removeItem(atPath: tmpFile)
            } catch {
                await MainActor.run {
                    Self.log.error("Failed to launch CodeBuddy: \(error.localizedDescription)")
                }
            }
        }
    }

    // CodeBuddy keyboard sequence: ⌘A -> ⌃⌘I -> "." -> Enter
    private static func simulateCodeBuddyChat() {
        let src = CGEventSource(stateID: .hidSystemState)
        // ⌘A select all
        postKey(src: src, keyCode: 0x00, flags: .maskCommand)
        usleep(300_000)
        // ⌃⌘I add to CodeBuddy chat
        postKey(src: src, keyCode: 34, flags: [.maskCommand, .maskControl])
        usleep(1_500_000)
        // "." + Enter via osascript to activate send
        runOsascript("tell application \"System Events\" to tell process \"Electron\" to keystroke \".\"")
        usleep(300_000)
        runOsascript("tell application \"System Events\" to tell process \"Electron\" to key code 36")
    }

    // MARK: - Shared: paste prompt into a terminal session

    private func pastePromptIntoSession(session: SessionSnapshot, prompt: String) {
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        TerminalActivator.activate(session: session)

        Task.detached {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                Self.postKey(src: CGEventSource(stateID: .hidSystemState), keyCode: 9, flags: .maskCommand)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            await MainActor.run {
                Self.postKey(src: CGEventSource(stateID: .hidSystemState), keyCode: 36)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                if let old = oldContents {
                    pasteboard.clearContents()
                    pasteboard.setString(old, forType: .string)
                }
            }
        }
    }

    // MARK: - Key simulation helpers

    static func postKey(src: CGEventSource?, keyCode: CGKeyCode, flags: CGEventFlags = []) {
        if let kd = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
           let ku = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            if !flags.isEmpty { kd.flags = flags; ku.flags = flags }
            kd.post(tap: .cghidEventTap)
            ku.post(tap: .cghidEventTap)
        }
    }

    private static func runOsascript(_ script: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
    }
}
