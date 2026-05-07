import Foundation

/// Protocol contract for the Buddy LCD companion device.
///
/// BLE service / characteristics:
/// - Service:        `0000beef-0000-1000-8000-00805f9b34fb`
/// - Write (host→Buddy, WRITE_NR): `0000beef-0001-1000-8000-00805f9b34fb`
/// - Notify (Buddy→host):          `0000beef-0002-1000-8000-00805f9b34fb`
///
/// Downlink agent frame (≤ 20 bytes):
///   byte[0] = sourceId (0..15, MascotID)
///   byte[1] = statusId (0..4, MascotStatusCode)
///   byte[2] = toolLen  (0..17)
///   byte[3..] = toolName UTF-8 (truncated to 17 bytes)
///
/// Downlink workspace frame (≤ 20 bytes):
///   byte[0] = 0xFC
///   byte[1] = workspaceLen (0..18)
///   byte[2..] = workspace UTF-8 (truncated to 18 bytes)
///
/// Downlink message preview frame (≤ 20 bytes):
///   byte[0] = 0xFB
///   byte[1] = messageIndex (0-based)
///   byte[2] = messageCount
///   byte[3] = flagsAndLen (bit7 = isUser, low7 = textLen)
///   byte[4..] = preview UTF-8 (truncated to 16 bytes)
///
/// Brightness config frame:
///   byte[0] = 0xFE
///   byte[1] = brightness percentage (10..100)
///
/// Screen orientation config frame:
///   byte[0] = 0xFD
///   byte[1] = orientation (0=up, 1=down)
///
/// Uplink (button notify / notification action):
///   1 byte = currently displayed mascot sourceId (focus request), or
///   1 byte = control opcode (approve / deny / skip).
///
/// Buddy firmware exits AGENT mode after 60 s with no writes, so the host
/// should resend the current frame periodically (≥ every 30 s, 5 s is the
/// recommended sync interval).
public enum ESP32Protocol {
    public static let serviceUUID = "0000beef-0000-1000-8000-00805f9b34fb"
    public static let writeCharacteristicUUID = "0000beef-0001-1000-8000-00805f9b34fb"
    public static let notifyCharacteristicUUID = "0000beef-0002-1000-8000-00805f9b34fb"

    public static let advertisedDeviceName = "Buddy"
    public static let maxToolNameBytes = 17
    public static let maxFrameBytes = 3 + maxToolNameBytes
    public static let maxWorkspaceNameBytes = 18
    public static let maxWorkspaceFrameBytes = 2 + maxWorkspaceNameBytes
    public static let maxMessagePreviewBytes = 16
    public static let maxMessagePreviewFrameBytes = 4 + maxMessagePreviewBytes
    public static let brightnessFrameMarker: UInt8 = 0xFE
    public static let orientationFrameMarker: UInt8 = 0xFD
    public static let workspaceFrameMarker: UInt8 = 0xFC
    public static let messagePreviewFrameMarker: UInt8 = 0xFB
    public static let approveCurrentPermissionMarker: UInt8 = 0xF0
    public static let denyCurrentPermissionMarker: UInt8 = 0xF1
    public static let skipCurrentQuestionMarker: UInt8 = 0xF2
    public static let minBrightnessPercent: UInt8 = 10
    public static let maxBrightnessPercent: UInt8 = 100
    public static let defaultBrightnessPercent: UInt8 = 70
    /// Firmware's Bluetooth inactivity timeout (ms). Host should stay well under this.
    public static let firmwareInactivityTimeoutMs: Int = 60_000

    public static func clampedBrightnessPercent(_ percent: Double) -> UInt8 {
        guard percent.isFinite else { return defaultBrightnessPercent }
        let rounded = Int(percent.rounded())
        let minValue = Int(minBrightnessPercent)
        let maxValue = Int(maxBrightnessPercent)
        return UInt8(min(max(rounded, minValue), maxValue))
    }
}

public enum BuddyControlCommand: UInt8, Equatable, Sendable {
    case approveCurrentPermission = 0xF0
    case denyCurrentPermission = 0xF1
    case skipCurrentQuestion = 0xF2
}

public enum BuddyUplinkEvent: Equatable, Sendable {
    case focus(MascotID)
    case command(BuddyControlCommand)

    public init?(payload: Data) {
        guard let first = payload.first else { return nil }
        if let mascot = MascotID(rawValue: first) {
            self = .focus(mascot)
            return
        }
        if let command = BuddyControlCommand(rawValue: first) {
            self = .command(command)
            return
        }
        return nil
    }
}

/// Physical screen orientation for Buddy.
public enum BuddyScreenOrientation: String, CaseIterable, Identifiable, Sendable {
    case up
    case down

    public var id: String { rawValue }

    public var wireValue: UInt8 {
        switch self {
        case .up: return 0
        case .down: return 1
        }
    }

    public init(settingsValue: String?) {
        switch settingsValue {
        case Self.down.rawValue: self = .down
        default: self = .up
        }
    }

    public init(wireValue: UInt8) {
        switch wireValue {
        case 1: self = .down
        default: self = .up
        }
    }
}

/// Mascot slot on Buddy (0..15). The index is the on-wire `sourceId`.
public enum MascotID: UInt8, CaseIterable, Sendable {
    case claude = 0
    case codex = 1
    case gemini = 2
    case cursor = 3
    case copilot = 4
    case trae = 5
    case qoder = 6
    case droid = 7            // "Factory Droid"
    case codebuddy = 8
    case stepfun = 9
    case opencode = 10
    case qwen = 11
    case antigravity = 12
    case workbuddy = 13
    case hermes = 14
    case kimi = 15

    /// Canonical source name used throughout CodeIsland (matches
    /// `SessionSnapshot.supportedSources` keys).
    public var sourceName: String {
        switch self {
        case .claude:       return "claude"
        case .codex:        return "codex"
        case .gemini:       return "gemini"
        case .cursor:       return "cursor"
        case .copilot:      return "copilot"
        case .trae:         return "trae"
        case .qoder:        return "qoder"
        case .droid:        return "droid"
        case .codebuddy:    return "codebuddy"
        case .stepfun:      return "stepfun"
        case .opencode:     return "opencode"
        case .qwen:         return "qwen"
        case .antigravity:  return "antigravity"
        case .workbuddy:    return "workbuddy"
        case .hermes:       return "hermes"
        case .kimi:         return "kimi"
        }
    }

    /// Fold a CodeIsland source string (including aliases like `traecn`,
    /// `traecli`, `codybuddycn`, `factory`, `ag`) into one of the 16 slots
    /// supported by the Buddy firmware.
    public init?(sourceName: String?) {
        guard let raw = sourceName,
              let canonical = SessionSnapshot.normalizedSupportedSource(raw) else {
            return nil
        }
        switch canonical {
        case "claude":                               self = .claude
        case "codex":                                self = .codex
        case "gemini":                               self = .gemini
        case "cursor", "cursor-cli":                 self = .cursor
        case "copilot":                              self = .copilot
        case "trae", "traecn", "traecli":            self = .trae
        case "qoder", "qoder-cli":                   self = .qoder
        case "droid":                                self = .droid
        case "codebuddy", "codybuddycn":             self = .codebuddy
        case "stepfun":                              self = .stepfun
        case "opencode":                             self = .opencode
        case "qwen":                                 self = .qwen
        case "antigravity":                          self = .antigravity
        case "workbuddy":                            self = .workbuddy
        case "hermes":                               self = .hermes
        case "kimi":                                 self = .kimi
        default:                                     return nil
        }
    }
}

/// On-wire status code. Matches the Buddy firmware's `statusToScene` table:
/// 0 → SLEEP, 1/2 → WORK (toolName is drawn), 3/4 → ALERT.
public enum MascotStatusCode: UInt8, Sendable {
    case idle = 0
    case processing = 1
    case running = 2
    case waitingApproval = 3
    case waitingQuestion = 4

    public init(_ status: AgentStatus) {
        switch status {
        case .idle:              self = .idle
        case .processing:        self = .processing
        case .running:           self = .running
        case .waitingApproval:   self = .waitingApproval
        case .waitingQuestion:   self = .waitingQuestion
        }
    }
}

/// Encoded frame ready to ship over the BLE write characteristic.
public struct MascotFramePayload: Equatable, Sendable {
    public let mascot: MascotID
    public let status: MascotStatusCode
    public let toolName: String?

    public init(mascot: MascotID, status: MascotStatusCode, toolName: String? = nil) {
        self.mascot = mascot
        self.status = status
        self.toolName = toolName
    }

    /// Build a frame from a canonical source string + CodeIsland AgentStatus.
    /// Returns `nil` if `source` doesn't fold to a known mascot slot.
    public init?(source: String?, status: AgentStatus, toolName: String? = nil) {
        guard let mascot = MascotID(sourceName: source) else { return nil }
        self.init(mascot: mascot, status: MascotStatusCode(status), toolName: toolName)
    }

    /// Serialize to the on-wire byte layout.
    /// Tool name is always UTF-8 and byte-truncated to `maxToolNameBytes`;
    /// the truncation may split a multi-byte codepoint — acceptable since the
    /// Buddy uses the bytes only for a marquee label.
    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(ESP32Protocol.maxFrameBytes)
        data.append(mascot.rawValue)
        data.append(status.rawValue)

        let toolBytes: [UInt8]
        if let toolName, !toolName.isEmpty {
            let raw = Array(toolName.utf8)
            if raw.count > ESP32Protocol.maxToolNameBytes {
                toolBytes = Array(raw.prefix(ESP32Protocol.maxToolNameBytes))
            } else {
                toolBytes = raw
            }
        } else {
            toolBytes = []
        }
        data.append(UInt8(toolBytes.count))
        data.append(contentsOf: toolBytes)
        return data
    }
}

public struct BuddyWorkspacePayload: Equatable, Sendable {
    public let workspaceName: String?

    public init(workspaceName: String?) {
        let trimmed = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workspaceName = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(ESP32Protocol.maxWorkspaceFrameBytes)
        data.append(ESP32Protocol.workspaceFrameMarker)
        let bytes = Self.truncatedUTF8Bytes(workspaceName, limit: ESP32Protocol.maxWorkspaceNameBytes)
        data.append(UInt8(bytes.count))
        data.append(contentsOf: bytes)
        return data
    }

    private static func truncatedUTF8Bytes(_ text: String?, limit: Int) -> [UInt8] {
        guard let text, !text.isEmpty else { return [] }
        return Array(text.utf8.prefix(limit))
    }
}

public struct BuddyMessagePreviewPayload: Equatable, Sendable {
    public let index: UInt8
    public let total: UInt8
    public let isUser: Bool
    public let text: String?

    public init(index: UInt8, total: UInt8, isUser: Bool, text: String?) {
        self.index = index
        self.total = total
        self.isUser = isUser
        self.text = Self.normalizedPreviewText(text)
    }

    public init(index: Int, total: Int, isUser: Bool, text: String?) {
        self.init(index: UInt8(max(0, min(255, index))), total: UInt8(max(0, min(255, total))), isUser: isUser, text: text)
    }

    public func encode() -> Data {
        var data = Data()
        data.reserveCapacity(ESP32Protocol.maxMessagePreviewFrameBytes)
        data.append(ESP32Protocol.messagePreviewFrameMarker)
        data.append(index)
        data.append(total)
        let bytes = Array((text ?? "").utf8.prefix(ESP32Protocol.maxMessagePreviewBytes))
        let flags = (isUser ? 0x80 : 0x00) | UInt8(bytes.count)
        data.append(flags)
        data.append(contentsOf: bytes)
        return data
    }

    private static func normalizedPreviewText(_ text: String?) -> String? {
        guard let text,
              text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil
        else {
            return nil
        }
        return text
    }
}

/// Encoded Buddy screen brightness config.
///
/// Kept as a 2-byte frame so older firmware treats it as an ignored short
/// payload instead of misreading it as an agent status update.
public struct BuddyBrightnessPayload: Equatable, Sendable {
    public let percent: UInt8

    public init(percent: Double) {
        self.percent = ESP32Protocol.clampedBrightnessPercent(percent)
    }

    public init(percent: UInt8) {
        self.percent = ESP32Protocol.clampedBrightnessPercent(Double(percent))
    }

    public func encode() -> Data {
        Data([ESP32Protocol.brightnessFrameMarker, percent])
    }
}

/// Encoded Buddy screen orientation config.
public struct BuddyScreenOrientationPayload: Equatable, Sendable {
    public let orientation: BuddyScreenOrientation

    public init(orientation: BuddyScreenOrientation) {
        self.orientation = orientation
    }

    public func encode() -> Data {
        Data([ESP32Protocol.orientationFrameMarker, orientation.wireValue])
    }
}
