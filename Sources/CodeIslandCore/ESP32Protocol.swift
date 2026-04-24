import Foundation

/// Protocol contract for the ESP32 "real-buddy" LCD companion device.
///
/// BLE service / characteristics:
/// - Service:        `0000beef-0000-1000-8000-00805f9b34fb`
/// - Write (host→ESP32, WRITE_NR): `0000beef-0001-1000-8000-00805f9b34fb`
/// - Notify (ESP32→host):          `0000beef-0002-1000-8000-00805f9b34fb`
///
/// Downlink frame (≤ 20 bytes):
///   byte[0] = sourceId (0..15, MascotID)
///   byte[1] = statusId (0..4, MascotStatusCode)
///   byte[2] = toolLen  (0..17)
///   byte[3..] = toolName UTF-8 (truncated to 17 bytes)
///
/// Uplink (button notify):
///   1 byte = currently displayed mascot sourceId (focus request).
///
/// ESP32 firmware exits AGENT mode after 60 s with no writes, so the host
/// should resend the current frame periodically (≥ every 30 s, 5 s is the
/// recommended heartbeat).
public enum ESP32Protocol {
    public static let serviceUUID = "0000beef-0000-1000-8000-00805f9b34fb"
    public static let writeCharacteristicUUID = "0000beef-0001-1000-8000-00805f9b34fb"
    public static let notifyCharacteristicUUID = "0000beef-0002-1000-8000-00805f9b34fb"

    public static let advertisedDeviceName = "real-buddy"
    public static let maxToolNameBytes = 17
    public static let maxFrameBytes = 3 + maxToolNameBytes
    /// Firmware's BLE inactivity timeout (ms). Host should stay well under this.
    public static let firmwareInactivityTimeoutMs: Int = 60_000
}

/// Mascot slot on the ESP32 (0..15). The index is the on-wire `sourceId`.
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
    /// supported by the ESP32 firmware.
    public init?(sourceName: String?) {
        guard let raw = sourceName,
              let canonical = SessionSnapshot.normalizedSupportedSource(raw) else {
            return nil
        }
        switch canonical {
        case "claude":                               self = .claude
        case "codex":                                self = .codex
        case "gemini":                               self = .gemini
        case "cursor":                               self = .cursor
        case "copilot":                              self = .copilot
        case "trae", "traecn", "traecli":            self = .trae
        case "qoder":                                self = .qoder
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

/// On-wire status code. Matches the ESP32 firmware's `statusToScene` table:
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
    /// ESP32 uses the bytes only for a marquee label.
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
