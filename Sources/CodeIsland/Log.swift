import Foundation
import os

struct CodeIslandLogger {
    private let logger: Logger

    init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    static var isDebugLoggingEnabled: Bool {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }

    func debug(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
            logger.debug("\(message(), privacy: .public)")
        #endif
    }

    func info(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
            logger.info("\(message(), privacy: .public)")
        #endif
    }

    func warning(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
            logger.warning("\(message(), privacy: .public)")
        #endif
    }

    func error(_ message: @autoclosure @escaping () -> String) {
        #if DEBUG
            logger.error("\(message(), privacy: .public)")
        #endif
    }
}

enum CodeIslandLog {
    private static let debugEventsEnvKey = "CODE_ISLAND_DEBUG_EVENTS"
    private static let releaseTruthyDebugEventValues: Set<String> = ["1", "true", "yes", "on"]
    private static let isDebugBuild: Bool = {
        #if DEBUG
            true
        #else
            false
        #endif
    }()

    static func isDebugEventLoggingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = isDebugBuild
    ) -> Bool {
        if isDebugBuild {
            return true
        }
        guard let rawValue = environment[debugEventsEnvKey] else {
            return false
        }
        return releaseTruthyDebugEventValues.contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func serializedJSONString(fromJSONObject object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return String(describing: object)
        }
        return text
    }

    static func serializedJSONString(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let normalized = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
            let text = String(data: normalized, encoding: .utf8)
        {
            return text
        }
        return String(data: data, encoding: .utf8) ?? "<non-utf8-data>"
    }

    static func jsonValue(from data: Data) -> Any {
        if let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object)
        {
            return object
        }
        return String(data: data, encoding: .utf8) ?? "<non-utf8-data>"
    }

    private static let startupTime = Date()

    private static var debugTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH:mm:ss"
        return formatter
    }()

    static func defaultDebugLogURL(
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        startupTime: Date = startupTime
    ) -> URL {
        let timestamp = debugTimestampFormatter.string(from: startupTime)
        return URL(fileURLWithPath: currentDirectoryPath)
            .appendingPathComponent(".log", isDirectory: true)
            .appendingPathComponent("debug-events.\(timestamp).ndjson")
    }

    static func appendDebugEvent(
        _ event: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool = isDebugBuild,
        logURL: URL = defaultDebugLogURL()
    ) {
        guard isDebugEventLoggingEnabled(environment: environment, isDebugBuild: isDebugBuild),
            JSONSerialization.isValidJSONObject(event),
            let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        else {
            return
        }

        let fm = FileManager.default
        let url = logURL
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }

        var line = data
        line.append(0x0A)

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
    }

    static func nowISO8601() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
    }
}

enum HookLogMessage {
    static func hookEventReceived(sessionId: String, eventName: String, payload: String) -> String {
        "Hook event received sid=\(sessionId) event=\(eventName) payload=\(payload)"
    }

    static func permissionRequest(_ action: String, sessionId: String, toolName: String, payload: String)
        -> String
    {
        "PermissionRequest \(action) sid=\(sessionId) tool=\(toolName) payload=\(payload)"
    }

    static func askUserQuestion(_ action: String, sessionId: String, payload: String) -> String {
        "AskUserQuestion \(action) sid=\(sessionId) payload=\(payload)"
    }

    static func questionNotification(_ action: String, sessionId: String, payload: String) -> String {
        "Question notification \(action) sid=\(sessionId) payload=\(payload)"
    }

    static func permissionRequestResolved(sessionId: String, decision: String, data: String) -> String {
        "PermissionRequest resolved sid=\(sessionId) decision=\(decision) data=\(data)"
    }

    static func permissionRequestAutoApproveResponse(sessionId: String, data: String) -> String {
        "PermissionRequest auto-approve response sid=\(sessionId) data=\(data)"
    }

    static func questionResolved(sessionId: String, action: String, data: String) -> String {
        "Question resolved sid=\(sessionId) action=\(action) data=\(data)"
    }

    static func parseFailed(raw: String) -> String {
        "Hook payload parse failed raw=\(raw)"
    }

    static func unsupportedSourceDropped(payload: String) -> String {
        "Dropping unsupported source payload=\(payload)"
    }

    static func hookResponse(data: String) -> String {
        "Hook response data=\(data)"
    }
}
