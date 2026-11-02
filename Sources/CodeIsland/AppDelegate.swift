import AppKit
import SwiftUI
import os.log
import CodeIslandCore

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let log = Logger(subsystem: "com.codeisland", category: "AppDelegate")

    var panelController: PanelWindowController?
    private var hookServer: HookServer?
    private var hookRecoveryTimer: Timer?
    private var lastHookCheck: Date = .distantPast
    private let hotKeyManager = GlobalHotKeyManager()
    private var localShortcutMonitor: Any?
    /// Another island already serves this hook socket: this one quits at
    /// launch, and touches nothing of the other's on the way out — its
    /// socket, its hosts' sockets, its saved sessions.
    private var standingAside = false
    let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything else: the launch Apple Event that says "login
        // item" is only current during this synchronous call.
        let isLoginLaunch = LaunchContext.isCurrentLaunchAtLogin()
        if let problem = RuntimeEnvironment.isolationProblem(ProcessInfo.processInfo.environment) {
            Self.log.error("\(problem, privacy: .public): quitting")
            standingAside = true
            NSApp.terminate(nil)
            return
        }
        let isolated = RuntimeEnvironment.isIsolated
        // One island per hook socket. A second one — `open -n`, a second copy
        // of the app — would take the socket from the first, which would go
        // on unheard, and remove its hosts' sockets. An island on a
        // CODEISLAND_SOCKET_PATH of its own is another socket's.
        if let other = HookSocketListener.islandListening(at: HookServer.socketPath) {
            Self.log.error("Another CodeIsland (pid \(other)) already serves \(HookServer.socketPath, privacy: .public): this one quits and leaves it alone")
            standingAside = true
            NSApp.terminate(nil)
            return
        }
        ProcessInfo.processInfo.disableAutomaticTermination("CodeIsland must stay running")
        ProcessInfo.processInfo.disableSuddenTermination()
        // Pre-set app icon so Dock/menu bar use the packaged bundle icon.
        NSApp.applicationIconImage = SettingsWindowController.bundleAppIcon()
        SettingsWindowController.shared.appState = appState
        StatusItemController.shared.startObserving()
        // Start HookServer BEFORE installing hooks into CLI configs.
        // If we write settings.json first, Claude Code picks up the new hooks
        // immediately but the socket isn't listening yet — PermissionRequest
        // hooks get no response and Claude Code denies them.
        // launchd's 256 descriptors are few for an app holding a socket per
        // waiting hook.
        HookSocketListener.raiseDescriptorLimit()
        // A path another user took first fails it: HookSocketHealth logs who
        // holds it, shows it in Settings and tries again later.
        let server = HookServer(appState: appState)
        hookServer = server
        HookSocketHealth.shared.start(server)
        RemoteManager.shared.onDisconnect = { [weak appState] hostId in
            appState?.removeRemoteSessions(hostId: hostId)
        }
        // Each remote host's hooks arrive on a socket of its own, bound when
        // the host connects: the socket, not the payload, names the host.
        RemoteManager.shared.hookSockets = RemoteHookSockets(appState: appState)

        // Prewarm the usage footer off the launch path — first panel expansion
        // then shows data immediately instead of popping in a beat later.
        if !isolated {
            Task { @MainActor [weak appState] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                appState?.refreshClaudeUsageIfStale()
            }
        }

        // Hook installation does subprocess version detection plus disk I/O —
        // keep it off the main thread so app launch isn't blocked even when a
        // CLI binary hangs. See #139.
        if isolated {
            Self.log.notice("Isolated (CODEISLAND_ISOLATED=1): no hooks installed, no sessions discovered, no remote hosts connected")
        } else {
            Task.detached(priority: .userInitiated) {
                if ConfigInstaller.install() {
                    Self.log.info("Hooks installed")
                } else {
                    Self.log.warning("Failed to install hooks")
                }
            }
        }

        // Watch system sleep/wake so the mascot animations pause and re-anchor
        // their periodic schedules instead of pinning a core after wake (#225).
        MascotAnimationGate.shared.start()
        // Lock / screen saver / display sleep → event sounds hold off.
        SceneMuteMonitor.shared.start()
        // Back at the screen: follow-ups held back meanwhile go out now.
        // Gone from it: approvals / questions a push skipped while the user
        // was still there go to the phone now.
        SceneMuteMonitor.shared.onQuietChanged = { [weak appState] isQuiet in
            if isQuiet {
                PushNotifier.shared.userLeft()
            } else {
                appState?.followUps.wake()
            }
        }
        // Follow-up reminders also reach the phone / chat push channels.
        appState.connectPushToFollowUps()

        panelController = PanelWindowController(appState: appState)
        panelController?.showPanel()

        if !isolated {
            appState.startSessionDiscovery()
            appState.startCodexAppServerWatcher()
            appState.startAiWorkWatcher()
            appState.startCoworkWatcher()
            RemoteManager.shared.startup()
        }

        // Buddy bridge (opt-in): mirrors the Dynamic Island onto the companion
        // device and routes its button press back to TerminalActivator.
        ESP32StatePublisher.shared.attach(appState)
        ESP32BridgeManager.shared.onFocusRequest = { [weak appState] mascot in
            guard let appState else { return }
            ESP32FocusCoordinator.handle(mascot: mascot, appState: appState)
        }
        ESP32BridgeManager.shared.onControlCommand = { [weak appState] command in
            guard let appState else { return }
            // The hardware Buddy shows whatever is featured and has no session
            // id on the wire, so it keeps acting on the head of the queue.
            appState.handleBuddyControlCommand(command)
        }
        AppleCompanionPublisher.shared.attach(appState)
        AppleCompanionPublisher.shared.onFocusRequest = { [weak appState] mascot in
            guard let appState else { return }
            ESP32FocusCoordinator.handle(mascot: mascot, appState: appState)
        }
        AppleCompanionPublisher.shared.onControlCommand = { [weak appState] command, sessionId in
            guard let appState else { return }
            appState.handleBuddyControlCommand(command, expectedSessionId: sessionId)
        }
        AppleCompanionPublisher.shared.onQuestionAnswer = { [weak appState] answer, sessionId in
            guard let appState else { return }
            appState.answerCompanionQuestion(answer, expectedSessionId: sessionId)
        }
        let buddyEnabled = UserDefaults.standard.bool(forKey: SettingsKey.esp32BridgeEnabled)
        let buddySyncInterval = UserDefaults.standard.double(forKey: SettingsKey.esp32HeartbeatSeconds)
        let buddyBrightness = UserDefaults.standard.double(forKey: SettingsKey.buddyScreenBrightnessPercent)
        let buddyScreenOrientation = BuddyScreenOrientation(
            settingsValue: UserDefaults.standard.string(forKey: SettingsKey.buddyScreenOrientation)
        )
        ESP32StatePublisher.shared.configure(
            enabled: buddyEnabled,
            heartbeatSeconds: buddySyncInterval > 0 ? buddySyncInterval : SettingsDefaults.esp32HeartbeatSeconds,
            brightnessPercent: buddyBrightness > 0 ? buddyBrightness : SettingsDefaults.buddyScreenBrightnessPercent,
            screenOrientation: buddyScreenOrientation
        )
        let appleCompanionEnabled = UserDefaults.standard.bool(forKey: SettingsKey.appleCompanionEnabled)
        let appleCompanionHeartbeat = UserDefaults.standard.double(forKey: SettingsKey.appleCompanionHeartbeatSeconds)
        AppleCompanionPublisher.shared.configure(
            enabled: appleCompanionEnabled,
            heartbeatSeconds: appleCompanionHeartbeat > 0 ? appleCompanionHeartbeat : SettingsDefaults.appleCompanionHeartbeatSeconds
        )

        // Hooks auto-recovery: periodic + app activation trigger
        if !isolated {
            hookRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkAndRepairHooks()
                }
            }
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.checkAndRepairHooks()
                }
            }
        }

        #if DEBUG
        // Preview mode: inject mock data if --preview flag is present
        if let scenario = DebugHarness.requestedScenario() {
            Self.log.debug("Loading scenario: \(scenario.rawValue)")
            DebugHarness.apply(scenario, to: appState)
            // --collapsed keeps the bar collapsed, for checking the compact layout.
            if DebugHarness.keepsCollapsed { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                if appState.surface == .collapsed {
                    withAnimation(NotchAnimation.pop) {
                        appState.surface = .sessionList
                    }
                }
            }
            return
        }
        #endif

        // Sparkle runs scheduled checks itself on the cadence declared in
        // Info.plist (SUScheduledCheckInterval). Start the updater once — it
        // no-ops for Homebrew-installed builds (brew owns those upgrades).
        if !isolated {
            UpdateChecker.shared.start()
        }

        // The jingle confirms a launch the user just made; at login it is
        // noise on every boot for everyone with Launch at Login on.
        if isLoginLaunch {
            Self.log.info("Launched at login — skipping boot sound")
        } else {
            SoundManager.shared.playBoot()
        }
        setupGlobalShortcut()

        // Boot animation: brief expand to confirm app is running
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard appState.surface == .collapsed else { return }
            withAnimation(NotchAnimation.pop) {
                appState.surface = .sessionList
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if case .sessionList = appState.surface {
                withAnimation(NotchAnimation.close) {
                    appState.surface = .collapsed
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Explicitly reopening the menu-bar app should expose its real settings,
        // not ask SwiftUI to synthesize a placeholder Settings scene.
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nothing was started; what is on disk is the other island's.
        guard !standingAside else { return }
        hookRecoveryTimer?.invalidate()
        teardownGlobalShortcut()
        appState.saveSessions()
        RemoteManager.shared.shutdown()
        hookServer?.stop()
        appState.stopCodexAppServerWatcher()
        appState.stopAiWorkWatcher()
        appState.stopSessionDiscovery()
    }

    // MARK: - Global Shortcuts

    func setupGlobalShortcut() {
        teardownGlobalShortcut()

        // Collect all enabled shortcut bindings, skip duplicates (first wins)
        var bindings: [(keyCode: UInt16, mods: NSEvent.ModifierFlags, action: ShortcutAction)] = []
        var seen: Set<String> = []
        for action in ShortcutAction.allCases {
            guard action.isEnabled else { continue }
            let b = action.binding
            let key = "\(b.keyCode)-\(b.modifiers.rawValue)"
            guard seen.insert(key).inserted else { continue }
            bindings.append((b.keyCode, b.modifiers, action))
        }
        guard !bindings.isEmpty else { return }

        // Global path: Carbon RegisterEventHotKey fires from any frontmost app
        // and — unlike an NSEvent global keyboard monitor — needs no
        // Accessibility permission. This is the primary handler. See #217.
        for b in bindings {
            hotKeyManager.register(keyCode: b.keyCode, modifiers: b.mods) { [weak self] in
                Task { @MainActor in self?.executeShortcut(b.action) }
            }
        }

        // Local monitor: same-app fallback so the shortcut still works (and is
        // swallowed) while CodeIsland's own panel/settings window is focused.
        let localHandler: (NSEvent) -> Bool = { [weak self] event in
            let eventMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for b in bindings where event.keyCode == b.keyCode && eventMods == b.mods {
                Task { @MainActor in self?.executeShortcut(b.action) }
                return true
            }
            return false
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            localHandler(event) ? nil : event
        }
    }

    private func teardownGlobalShortcut() {
        hotKeyManager.unregisterAll()
        if let m = localShortcutMonitor { NSEvent.removeMonitor(m) }
        localShortcutMonitor = nil
    }

    private func executeShortcut(_ action: ShortcutAction) {
        switch action {
        // Whatever the press opens comes to the user: onto the display they
        // work on, and up over a fullscreen app Hide in Fullscreen hid it
        // behind (#384).
        case .togglePanel:
            let away = panelController?.isIslandAwayFromUser ?? false
            if appState.togglePanelFromShortcut(islandAway: away) != .collapsed {
                panelController?.bringIslandIntoSight()
            }
        // Card shortcuts act only on the card on screen (#308); with the
        // request hidden they open its card instead of acting unseen.
        case .approve, .approveAlways, .deny, .skipQuestion:
            let onScreen = panelController?.isIslandOnScreen ?? true
            if case .opened = appState.performCardShortcut(action, islandOnScreen: onScreen) {
                panelController?.bringIslandIntoSight()
            }
        case .jumpToTerminal:
            if let id = appState.activeSessionId, let session = appState.sessions[id] {
                TerminalActivator.activate(session: session, sessionId: id)
            }
        }
    }

    private func checkAndRepairHooks() {
        guard Date().timeIntervalSince(lastHookCheck) > 60 else { return }
        lastHookCheck = Date()
        // A socket that could not start (its path taken) may start now.
        HookSocketHealth.shared.retryIfDown()
        // verifyAndRepair walks every enabled CLI and rewrites settings on
        // disk — keep it off the main thread so the activation observer (fires
        // on every app switch) can't stutter the UI. See #139.
        Task.detached(priority: .background) {
            let repaired = ConfigInstaller.verifyAndRepair()
            if !repaired.isEmpty {
                Self.log.info("Auto-repaired hooks for: \(repaired.joined(separator: ", "))")
            }
        }
    }

}
