import AppKit
import ServiceManagement

enum AppVersion {
    /// Update this each release. Used as fallback when Info.plist is unavailable (debug builds).
    static let fallback = "1.0.20"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? fallback
    }
}

enum NotchHeightMode: String, CaseIterable {
    case matchNotch = "matchNotch"
    case matchMenuBar = "matchMenuBar"
    case custom = "custom"
}

enum SettingsKey {
    // Language
    static let appLanguage = "appLanguage"                 // "system", "en", "zh", "ja", "ko", "tr"

    // General - System
    static let launchAtLogin = "launchAtLogin"
    static let displayChoice = "displayChoice"             // "auto", "builtin", "main"
    static let allowHorizontalDrag = "allowHorizontalDrag"
    static let panelHorizontalOffset = "panelHorizontalOffset"

    // General - Behavior
    static let hideInFullscreen = "hideInFullscreen"
    static let hideWhenNoSession = "hideWhenNoSession"
    static let smartSuppress = "smartSuppress"
    static let collapseOnMouseLeave = "collapseOnMouseLeave"
    static let autoCollapseAfterSessionJump = "autoCollapseAfterSessionJump"
    static let hapticOnHover = "hapticOnHover"
    static let hapticIntensity = "hapticIntensity"      // 1=light, 2=medium, 3=strong
    static let sessionTimeout = "sessionTimeout"

    // Display
    static let maxPanelHeight = "maxPanelHeight"
    static let maxVisibleSessions = "maxVisibleSessions"
    static let contentFontSize = "contentFontSize"
    static let aiMessageLines = "aiMessageLines"
    static let showAgentDetails = "showAgentDetails"
    static let notchHeightMode = "notchHeightMode"
    static let customNotchHeight = "customNotchHeight"

    // Sound
    static let soundEnabled = "soundEnabled"
    static let soundVolume = "soundVolume"
    static let soundSessionStart = "soundSessionStart"
    static let soundTaskComplete = "soundTaskComplete"
    static let soundTaskError = "soundTaskError"
    static let soundApprovalNeeded = "soundApprovalNeeded"
    static let soundPromptSubmit = "soundPromptSubmit"
    static let soundBoot = "soundBoot"

    // Shortcuts (per-action: shortcut_{action}_enabled, shortcut_{action}_keyCode, shortcut_{action}_modifiers)
    static func shortcutEnabled(_ action: String) -> String { "shortcut_\(action)_enabled" }
    static func shortcutKeyCode(_ action: String) -> String { "shortcut_\(action)_keyCode" }
    static func shortcutModifiers(_ action: String) -> String { "shortcut_\(action)_modifiers" }

    // Custom sound paths (keyed by sound name, e.g. "soundCustomPath_8bit_start")
    static func soundCustomPath(_ soundName: String) -> String { "soundCustomPath_\(soundName)" }

    // Session rotation
    static let rotationInterval = "rotationInterval"

    // Advanced
    static let maxToolHistory = "maxToolHistory"

    // Mascot
    static let mascotSpeed = "mascotSpeed"

    // Session grouping
    static let sessionGroupingMode = "sessionGroupingMode"

    // Tool status display
    static let showToolStatus = "showToolStatus"              // true = detailed, false = simple

    // Island collapsed width scale for non-notch screens (percentage: 50–150, default 100)
    static let collapsedWidthScale = "collapsedWidthScale"

}

struct SettingsDefaults {
    static let displayChoice = "auto"
    static let allowHorizontalDrag = false
    static let panelHorizontalOffset = 0.0
    static let hideInFullscreen = true
    static let hideWhenNoSession = false
    static let smartSuppress = true
    static let collapseOnMouseLeave = true
    static let autoCollapseAfterSessionJump = false
    static let hapticOnHover = false
    static let hapticIntensity = 1          // 1=light
    static let sessionTimeout = 30

    static let maxPanelHeight = 560
    static let maxVisibleSessions = 5
    static let contentFontSize = 11
    static let aiMessageLines = 1
    static let showAgentDetails = false
    static let notchHeightMode = NotchHeightMode.matchNotch.rawValue
    static let customNotchHeight = 37.0

    static let soundEnabled = false
    static let soundVolume = 50
    static let soundSessionStart = true
    static let soundTaskComplete = true
    static let soundTaskError = true
    static let soundApprovalNeeded = true
    static let soundPromptSubmit = false
    static let soundBoot = true

    static let rotationInterval = 5

    static let maxToolHistory = 20

    static let mascotSpeed = 100  // percentage: 0–300, 0 = silent

    static let sessionGroupingMode = "all"

    static let showToolStatus = true

    static let collapsedWidthScale = 100  // percentage
}

@MainActor
class SettingsManager {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            SettingsKey.displayChoice: SettingsDefaults.displayChoice,
            SettingsKey.allowHorizontalDrag: SettingsDefaults.allowHorizontalDrag,
            SettingsKey.panelHorizontalOffset: SettingsDefaults.panelHorizontalOffset,
            SettingsKey.hideInFullscreen: SettingsDefaults.hideInFullscreen,
            SettingsKey.hideWhenNoSession: SettingsDefaults.hideWhenNoSession,
            SettingsKey.smartSuppress: SettingsDefaults.smartSuppress,
            SettingsKey.collapseOnMouseLeave: SettingsDefaults.collapseOnMouseLeave,
            SettingsKey.autoCollapseAfterSessionJump: SettingsDefaults.autoCollapseAfterSessionJump,
            SettingsKey.hapticOnHover: SettingsDefaults.hapticOnHover,
            SettingsKey.hapticIntensity: SettingsDefaults.hapticIntensity,
            SettingsKey.sessionTimeout: SettingsDefaults.sessionTimeout,
            SettingsKey.maxPanelHeight: SettingsDefaults.maxPanelHeight,
            SettingsKey.maxVisibleSessions: SettingsDefaults.maxVisibleSessions,
            SettingsKey.contentFontSize: SettingsDefaults.contentFontSize,
            SettingsKey.aiMessageLines: SettingsDefaults.aiMessageLines,
            SettingsKey.showAgentDetails: SettingsDefaults.showAgentDetails,
            SettingsKey.notchHeightMode: SettingsDefaults.notchHeightMode,
            SettingsKey.customNotchHeight: SettingsDefaults.customNotchHeight,
            SettingsKey.soundEnabled: SettingsDefaults.soundEnabled,
            SettingsKey.soundVolume: SettingsDefaults.soundVolume,
            SettingsKey.soundSessionStart: SettingsDefaults.soundSessionStart,
            SettingsKey.soundTaskComplete: SettingsDefaults.soundTaskComplete,
            SettingsKey.soundTaskError: SettingsDefaults.soundTaskError,
            SettingsKey.soundApprovalNeeded: SettingsDefaults.soundApprovalNeeded,
            SettingsKey.soundPromptSubmit: SettingsDefaults.soundPromptSubmit,
            SettingsKey.soundBoot: SettingsDefaults.soundBoot,
            SettingsKey.rotationInterval: SettingsDefaults.rotationInterval,
            SettingsKey.maxToolHistory: SettingsDefaults.maxToolHistory,
            SettingsKey.mascotSpeed: SettingsDefaults.mascotSpeed,
            SettingsKey.sessionGroupingMode: SettingsDefaults.sessionGroupingMode,
            SettingsKey.showToolStatus: SettingsDefaults.showToolStatus,
            SettingsKey.collapsedWidthScale: SettingsDefaults.collapsedWidthScale,
        ])
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                // Login item update may fail silently in sandboxed environments
            }
        }
    }

    var displayChoice: String {
        get { defaults.string(forKey: SettingsKey.displayChoice) ?? SettingsDefaults.displayChoice }
        set { defaults.set(newValue, forKey: SettingsKey.displayChoice) }
    }

    var allowHorizontalDrag: Bool {
        get { defaults.bool(forKey: SettingsKey.allowHorizontalDrag) }
        set { defaults.set(newValue, forKey: SettingsKey.allowHorizontalDrag) }
    }

    var panelHorizontalOffset: Double {
        get { defaults.double(forKey: SettingsKey.panelHorizontalOffset) }
        set { defaults.set(newValue, forKey: SettingsKey.panelHorizontalOffset) }
    }

    var hideInFullscreen: Bool {
        get { defaults.bool(forKey: SettingsKey.hideInFullscreen) }
        set { defaults.set(newValue, forKey: SettingsKey.hideInFullscreen) }
    }

    var hideWhenNoSession: Bool {
        get { defaults.bool(forKey: SettingsKey.hideWhenNoSession) }
        set { defaults.set(newValue, forKey: SettingsKey.hideWhenNoSession) }
    }

    var smartSuppress: Bool {
        get { defaults.bool(forKey: SettingsKey.smartSuppress) }
        set { defaults.set(newValue, forKey: SettingsKey.smartSuppress) }
    }

    var collapseOnMouseLeave: Bool {
        get { defaults.bool(forKey: SettingsKey.collapseOnMouseLeave) }
        set { defaults.set(newValue, forKey: SettingsKey.collapseOnMouseLeave) }
    }

    var hapticOnHover: Bool {
        get { defaults.bool(forKey: SettingsKey.hapticOnHover) }
        set { defaults.set(newValue, forKey: SettingsKey.hapticOnHover) }
    }

    var hapticIntensity: Int {
        get { defaults.integer(forKey: SettingsKey.hapticIntensity) }
        set { defaults.set(newValue, forKey: SettingsKey.hapticIntensity) }
    }

    var sessionTimeout: Int {
        get { defaults.integer(forKey: SettingsKey.sessionTimeout) }
        set { defaults.set(newValue, forKey: SettingsKey.sessionTimeout) }
    }

    var maxPanelHeight: Int {
        get { defaults.integer(forKey: SettingsKey.maxPanelHeight) }
        set { defaults.set(newValue, forKey: SettingsKey.maxPanelHeight) }
    }

    var contentFontSize: Int {
        get { defaults.integer(forKey: SettingsKey.contentFontSize) }
        set { defaults.set(newValue, forKey: SettingsKey.contentFontSize) }
    }

    var showAgentDetails: Bool {
        get { defaults.bool(forKey: SettingsKey.showAgentDetails) }
        set { defaults.set(newValue, forKey: SettingsKey.showAgentDetails) }
    }

    var notchHeightMode: NotchHeightMode {
        get {
            let raw = defaults.string(forKey: SettingsKey.notchHeightMode) ?? SettingsDefaults.notchHeightMode
            return NotchHeightMode(rawValue: raw) ?? .matchNotch
        }
        set { defaults.set(newValue.rawValue, forKey: SettingsKey.notchHeightMode) }
    }

    var customNotchHeight: Double {
        get { defaults.double(forKey: SettingsKey.customNotchHeight) }
        set { defaults.set(newValue, forKey: SettingsKey.customNotchHeight) }
    }

    var maxToolHistory: Int {
        get { defaults.integer(forKey: SettingsKey.maxToolHistory) }
        set { defaults.set(newValue, forKey: SettingsKey.maxToolHistory) }
    }

    var rotationInterval: Int {
        get { defaults.integer(forKey: SettingsKey.rotationInterval) }
        set { defaults.set(newValue, forKey: SettingsKey.rotationInterval) }
    }

    var sessionGroupingMode: String {
        get { defaults.string(forKey: SettingsKey.sessionGroupingMode) ?? SettingsDefaults.sessionGroupingMode }
        set { defaults.set(newValue, forKey: SettingsKey.sessionGroupingMode) }
    }
}

// MARK: - Shortcut Actions

struct ShortcutBinding {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(Self.keyCodeToString(keyCode))
        return parts.joined()
    }

    static func keyCodeToString(_ code: UInt16) -> String {
        let map: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 109: "F10", 111: "F12", 103: "F11",
            118: "F4", 120: "F2", 122: "F1",
        ]
        return map[code] ?? "?"
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case togglePanel
    case approve
    case approveAlways
    case deny
    case skipQuestion
    case jumpToTerminal

    var id: String { rawValue }

    var defaultBinding: ShortcutBinding? {
        switch self {
        case .togglePanel:    return ShortcutBinding(keyCode: 34, modifiers: [.command, .shift]) // ⌘⇧I
        case .approve:        return ShortcutBinding(keyCode: 0,  modifiers: [.command, .shift]) // ⌘⇧A
        case .deny:           return ShortcutBinding(keyCode: 2,  modifiers: [.command, .shift]) // ⌘⇧D
        case .approveAlways:  return nil
        case .skipQuestion:   return nil
        case .jumpToTerminal: return nil
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .togglePanel: return true
        default: return false
        }
    }

    var isEnabled: Bool {
        let key = SettingsKey.shortcutEnabled(rawValue)
        if UserDefaults.standard.object(forKey: key) == nil { return defaultEnabled }
        return UserDefaults.standard.bool(forKey: key)
    }

    var binding: ShortcutBinding {
        let kcKey = SettingsKey.shortcutKeyCode(rawValue)
        let modKey = SettingsKey.shortcutModifiers(rawValue)
        let fallback = defaultBinding ?? ShortcutBinding(keyCode: 0, modifiers: [.command, .shift])
        let keyCode = UInt16(UserDefaults.standard.object(forKey: kcKey) != nil
            ? UserDefaults.standard.integer(forKey: kcKey)
            : Int(fallback.keyCode))
        let modRaw = UserDefaults.standard.object(forKey: modKey) != nil
            ? UInt(UserDefaults.standard.integer(forKey: modKey))
            : fallback.modifiers.rawValue
        return ShortcutBinding(
            keyCode: keyCode,
            modifiers: NSEvent.ModifierFlags(rawValue: modRaw).intersection(.deviceIndependentFlagsMask)
        )
    }

    func setBinding(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        UserDefaults.standard.set(Int(keyCode), forKey: SettingsKey.shortcutKeyCode(rawValue))
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: SettingsKey.shortcutModifiers(rawValue))
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.shortcutEnabled(rawValue))
    }

    /// Returns the other action that conflicts with this one's binding, if any.
    func conflictingAction() -> ShortcutAction? {
        guard isEnabled else { return nil }
        let myBinding = binding
        for other in Self.allCases where other != self && other.isEnabled {
            let otherBinding = other.binding
            if otherBinding.keyCode == myBinding.keyCode && otherBinding.modifiers == myBinding.modifiers {
                return other
            }
        }
        return nil
    }
}
