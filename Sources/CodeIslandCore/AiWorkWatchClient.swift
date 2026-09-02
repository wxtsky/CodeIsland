import Foundation

/// A parsed Agentix daemon V2 frame (`ResponseEnvelopeV2` or `StreamEventV2`).
///
/// Unlike Codex app-server (classic JSON-RPC notifications), the Agentix daemon
/// speaks a custom NDJSON envelope with a top-level `kind` of `"response"` or
/// `"event"`. See agentix `crates/common/src/rpc_protocol.rs`.
public struct AiWorkFrame: Equatable {
    public enum Kind: Equatable {
        case response(operation: String, ok: Bool)
        case event(name: String, phase: String?)
        case unknown
    }

    public let raw: [String: AnyCodableLike]
    public let kind: Kind

    public init(raw: [String: AnyCodableLike], kind: Kind) {
        self.raw = raw
        self.kind = kind
    }

    public var dataObject: [String: AnyCodableLike]? {
        raw["data"]?.asObject
    }

    public var metaObject: [String: AnyCodableLike]? {
        raw["meta"]?.asObject
    }

    /// Prefer `meta.session_id`, then `data.session.session_id`, then `data.session_id`.
    public var sessionId: String? {
        if let sid = metaObject?["session_id"]?.asString, !sid.isEmpty { return sid }
        if let sid = dataObject?["session"]?.asObject?["session_id"]?.asString, !sid.isEmpty {
            return sid
        }
        if let sid = dataObject?["session_id"]?.asString, !sid.isEmpty { return sid }
        return nil
    }

    public var eventName: String? {
        if case .event(let name, _) = kind { return name }
        return nil
    }
}

public enum AiWorkWatchError: Error, Equatable {
    case socketMissing(String)
    case notConnected
    case connectFailed(String)
    case writeFailed(String)
}

/// Connects to an Agentix daemon Unix socket and speaks newline-delimited V2
/// frames. Used by CodeIsland to subscribe to `sessions.watch` for AiWork
/// GUI / TUI task status (read-only).
///
/// Thread safety: `start`, `stop`, and `sendRequest` may be called from any
/// thread; I/O is serialized on an internal queue. Handler closures run on the
/// caller-supplied callback queue (default: main).
public final class AiWorkWatchClient: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (AiWorkFrame) -> Void
    public typealias ExitHandler = @Sendable () -> Void

    public let socketPath: String
    private let callbackQueue: DispatchQueue
    private let ioQueue: DispatchQueue

    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer: Data = Data()
    private var nextRequestId: Int64 = 1
    private var isStopped: Bool = true
    private var didSignalExit: Bool = false

    public var onFrame: FrameHandler?
    public var onExit: ExitHandler?

    public init(
        socketPath: String,
        callbackQueue: DispatchQueue = .main
    ) {
        self.socketPath = socketPath
        self.callbackQueue = callbackQueue
        self.ioQueue = DispatchQueue(label: "com.codeisland.aiwork-watch-io")
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return socketFD >= 0 && !isStopped
    }

    // MARK: - Lifecycle

    public func start() throws {
        lock.lock()
        if socketFD >= 0, !isStopped {
            lock.unlock()
            return
        }
        guard FileManager.default.fileExists(atPath: socketPath) else {
            lock.unlock()
            throw AiWorkWatchError.socketMissing(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lock.unlock()
            throw AiWorkWatchError.connectFailed("socket() failed: \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        if pathBytes.count > MemoryLayout.size(ofValue: addr.sun_path) {
            close(fd)
            lock.unlock()
            throw AiWorkWatchError.connectFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, b) in pathBytes.enumerated() {
                    dest[i] = b
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            let err = errno
            close(fd)
            lock.unlock()
            throw AiWorkWatchError.connectFailed("connect(\(socketPath)) failed: \(err)")
        }

        // Non-blocking reads driven by DispatchSource.
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        self.socketFD = fd
        self.readBuffer.removeAll(keepingCapacity: true)
        self.isStopped = false
        self.didSignalExit = false

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailable()
        }
        source.setCancelHandler { [weak self] in
            // Own the captured `fd` rather than re-reading socketFD: stop() clears
            // socketFD *before* cancelling, so re-reading it here always saw -1 and
            // the descriptor was never closed. unaryCall() calls stop() on every RPC,
            // so that leaked one fd per call until RLIMIT_NOFILE.
            if let self {
                self.lock.lock()
                if self.socketFD == fd { self.socketFD = -1 }
                self.lock.unlock()
            }
            close(fd)
        }
        self.readSource = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        isStopped = true
        let source = readSource
        readSource = nil
        let fd = socketFD
        socketFD = -1
        lock.unlock()

        source?.cancel()
        // If the source was never created / already cancelled, close directly.
        if source == nil, fd >= 0 {
            close(fd)
        }
    }

    // MARK: - Send

    @discardableResult
    public func sendRequest(method: String, params: Any? = nil) throws -> Int64 {
        let id: Int64
        lock.lock()
        id = nextRequestId
        nextRequestId &+= 1
        lock.unlock()

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let params {
            body["params"] = params
        } else {
            body["params"] = [String: Any]()
        }
        try writeEnvelope(body)
        return id
    }

    /// Subscribe to the daemon's global session event bus.
    @discardableResult
    public func watchSessions(watchAckId: String? = nil) throws -> Int64 {
        var params: [String: Any] = [:]
        if let watchAckId { params["watchAckId"] = watchAckId }
        return try sendRequest(method: "sessions.watch", params: params)
    }

    private func writeEnvelope(_ body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        var payload = data
        payload.append(0x0A)

        lock.lock()
        guard !isStopped, socketFD >= 0 else {
            lock.unlock()
            throw AiWorkWatchError.notConnected
        }
        let fd = socketFD
        lock.unlock()

        var written = 0
        let bytes = [UInt8](payload)
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: written), bytes.count - written, 0)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw AiWorkWatchError.writeFailed("send failed: \(errno)")
            }
            if n == 0 {
                throw AiWorkWatchError.writeFailed("send returned 0")
            }
            written += n
        }
    }

    // MARK: - Receive

    private func readAvailable() {
        lock.lock()
        let fd = socketFD
        let stopped = isStopped
        lock.unlock()
        guard !stopped, fd >= 0 else { return }

        var tmp = [UInt8](repeating: 0, count: 65_536)
        while true {
            let capacity = tmp.count
            let n = tmp.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return Darwin.recv(fd, base, capacity, 0)
            }
            if n > 0 {
                ingest(data: Data(tmp[0..<n]))
                continue
            }
            if n == 0 {
                handleDisconnect()
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            if errno == EINTR {
                continue
            }
            handleDisconnect()
            return
        }
    }

    /// A peer that never sends a newline would otherwise grow readBuffer without
    /// bound. Unlike the Codex client — whose peer is a child process CodeIsland
    /// spawned — the Agentix daemon is an independent process, so cap it and drop
    /// the connection rather than absorb unbounded data.
    private static let maxBufferedBytes = 8 * 1024 * 1024

    private func ingest(data: Data) {
        readBuffer.append(data)
        if readBuffer.count > Self.maxBufferedBytes {
            readBuffer.removeAll(keepingCapacity: false)
            handleDisconnect()
            return
        }
        let parsed = AiWorkWatchClient.drainFrames(buffer: &readBuffer)
        guard !parsed.isEmpty else { return }
        for frame in parsed {
            let handler = self.onFrame
            callbackQueue.async { handler?(frame) }
        }
    }

    private func handleDisconnect() {
        lock.lock()
        if isStopped || didSignalExit {
            lock.unlock()
            return
        }
        didSignalExit = true
        isStopped = true
        // Hand the fd to the cancel handler and clear it here too, so a stop()
        // racing this path sees -1 and cannot close the same descriptor twice.
        socketFD = -1
        let source = readSource
        readSource = nil
        let handler = onExit
        lock.unlock()

        source?.cancel()
        callbackQueue.async { handler?() }
    }

    // MARK: - Pure parser (exposed for tests)

    public static func drainFrames(buffer: inout Data) -> [AiWorkFrame] {
        var results: [AiWorkFrame] = []
        let newline: UInt8 = 0x0A
        var searchStart = buffer.startIndex

        while searchStart < buffer.endIndex {
            guard let newlineIndex = buffer[searchStart..<buffer.endIndex].firstIndex(of: newline) else {
                break
            }
            let lineBytes = buffer[searchStart..<newlineIndex]
            if !lineBytes.isEmpty, let parsed = parseFrame(Data(lineBytes)) {
                results.append(parsed)
            }
            searchStart = buffer.index(after: newlineIndex)
        }

        if searchStart == buffer.startIndex { return results }
        if searchStart >= buffer.endIndex {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer = Data(buffer[searchStart..<buffer.endIndex])
        }
        return results
    }

    public static func parseFrame(_ data: Data) -> AiWorkFrame? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw = AnyCodableLike.from(obj).asObject ?? [:]
        let kindLabel = (obj["kind"] as? String) ?? ""

        switch kindLabel {
        case "response":
            let operation = (obj["operation"] as? String) ?? ""
            let ok = (obj["ok"] as? Bool) ?? false
            return AiWorkFrame(raw: raw, kind: .response(operation: operation, ok: ok))
        case "event":
            let eventObj = obj["event"] as? [String: Any]
            let name = (eventObj?["name"] as? String) ?? ""
            let phase = eventObj?["phase"] as? String
            return AiWorkFrame(raw: raw, kind: .event(name: name, phase: phase))
        default:
            if obj["error"] != nil || obj["result"] != nil || obj["method"] != nil {
                return AiWorkFrame(raw: raw, kind: .unknown)
            }
            return nil
        }
    }

    // MARK: - Path helpers

    /// Owning agent of a daemon session id shaped `channel:agent:uuid`
    /// (e.g. `acp:coder:<uuid>` -> `coder`). nil when the id carries no agent.
    public static func agentId(fromDaemonSessionId id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// Default Agentix state directory (`$AGENTIX_STATE_DIR` or `~/.agentix`).
    public static func defaultStateDir(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> String {
        if let env = environment["AGENTIX_STATE_DIR"], !env.isEmpty {
            return env
        }
        return homeDirectory + "/.agentix"
    }

    /// Discover running daemon sockets under `{stateDir}/run/*/agent.sock`
    /// that also have an `agent.ready` marker.
    public static func discoverReadyDaemons(
        stateDir: String? = nil,
        fileManager: FileManager = .default
    ) -> [(agentId: String, socketPath: String)] {
        let root = stateDir ?? defaultStateDir()
        let runDir = root + "/run"
        guard let entries = try? fileManager.contentsOfDirectory(atPath: runDir) else {
            return []
        }
        var results: [(agentId: String, socketPath: String)] = []
        for name in entries.sorted() {
            if name == "runtime" { continue }
            let agentDir = runDir + "/" + name
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: agentDir, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let sock = agentDir + "/agent.sock"
            let ready = agentDir + "/agent.ready"
            guard fileManager.fileExists(atPath: sock),
                  fileManager.fileExists(atPath: ready) else {
                continue
            }
            results.append((agentId: name, socketPath: sock))
        }
        return results
    }

    /// Perform a one-shot unary RPC on a fresh connection and return the
    /// response frame (or nil on failure / timeout). Used for backfill via
    /// `sessions.list` / `agent.stats` without disturbing the watch stream.
    public static func unaryCall(
        socketPath: String,
        method: String,
        params: Any? = nil,
        timeoutSeconds: TimeInterval = 5.0
    ) -> AiWorkFrame? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var response: AiWorkFrame?
            var finished = false
            let group = DispatchGroup()

            func finish(_ frame: AiWorkFrame?) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                response = frame
                group.leave()
            }
        }

        let box = Box()
        box.group.enter()

        let client = AiWorkWatchClient(
            socketPath: socketPath,
            callbackQueue: DispatchQueue(label: "com.codeisland.aiwork-unary")
        )
        client.onFrame = { frame in
            // Match the response to the request we sent. The daemon echoes the
            // method name in `operation` (see ResponseEnvelopeV2), and this
            // connection carries exactly one request, so a mismatch means the
            // frame is not ours. Error detail on ok:false stays reachable through
            // `frame.raw`.
            if case .response(let operation, _) = frame.kind, operation == method {
                box.finish(frame)
            }
        }
        client.onExit = {
            box.finish(nil)
        }

        do {
            try client.start()
            try client.sendRequest(method: method, params: params ?? [String: Any]())
        } catch {
            client.stop()
            return nil
        }

        let wait = box.group.wait(timeout: .now() + timeoutSeconds)
        client.stop()
        if wait == .timedOut { return nil }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.response
    }
}

// MARK: - Status mapping helpers (pure)

public enum AiWorkStatusMapper {
    /// Map a daemon stream event name onto CodeIsland's AgentStatus.
    /// Returns nil when the event should not change status (e.g. diagnostics).
    public static func status(forEventName name: String) -> AgentStatus? {
        switch name {
        case "stream.approval_required",
             "stream.plan_confirmation_required":
            return .waitingApproval
        case "stream.question_required":
            return .waitingQuestion
        case "stream.tool_call":
            return .running
        case "stream.tool_result",
             "stream.approval_resolved",
             "stream.plan_confirmation_resolved",
             "stream.question_resolved":
            return .processing
        case "stream.started",
             "stream.progress",
             "stream.thinking_delta",
             "stream.text_delta",
             "stream.ack",
             "stream.fallback_started":
            return .processing
        case "stream.completed",
             "stream.failed",
             "stream.aborted":
            return .idle
        default:
            return nil
        }
    }

    /// Whether a terminal event should enqueue a completion card.
    public static func isTerminalEvent(_ name: String) -> Bool {
        switch name {
        case "stream.completed", "stream.failed", "stream.aborted":
            return true
        default:
            return false
        }
    }

    /// Extract a short tool label from a `stream.tool_call` data payload.
    public static func toolName(from data: [String: AnyCodableLike]?) -> String? {
        guard let data else { return nil }
        if let display = toolDisplayObject(from: data) {
            if let title = display["title"]?.asString, !title.isEmpty {
                // Prefer the short tool name when title is a long "name: detail".
                if let name = display["tool_name"]?.asString ?? data["name"]?.asString,
                   !name.isEmpty {
                    return name
                }
                return title
            }
            if let name = display["tool_name"]?.asString, !name.isEmpty { return name }
        }
        if let name = data["name"]?.asString, !name.isEmpty { return name }
        if let title = data["title"]?.asString, !title.isEmpty { return title }
        if let tool = data["tool"]?.asString, !tool.isEmpty { return tool }
        if let toolName = data["tool_name"]?.asString, !toolName.isEmpty { return toolName }
        return nil
    }

    /// Human-readable one-line detail for the notch process row.
    public static func toolDescription(from data: [String: AnyCodableLike]?) -> String? {
        guard let data else { return nil }
        if let display = toolDisplayObject(from: data) {
            if let title = display["title"]?.asString, !title.isEmpty {
                return truncate(title, max: 160)
            }
            if case .object(let fields) = display["primary_fields"] {
                let parts = fields.compactMap { key, value -> String? in
                    guard let text = value.asString, !text.isEmpty else { return nil }
                    return "\(key)=\(text)"
                }
                if !parts.isEmpty {
                    return truncate(parts.sorted().joined(separator: " "), max: 160)
                }
            }
        }
        if let command = data["input"]?.asObject?["command"]?.asString, !command.isEmpty {
            return truncate(command, max: 160)
        }
        if let query = data["input"]?.asObject?["query"]?.asString, !query.isEmpty {
            return truncate(query, max: 160)
        }
        if let path = data["input"]?.asObject?["path"]?.asString, !path.isEmpty {
            return truncate(path, max: 160)
        }
        return toolName(from: data).map { truncate($0, max: 80) }
    }

    public static func progressText(from data: [String: AnyCodableLike]?) -> String? {
        guard let data else { return nil }
        if let text = data["text"]?.asString, !text.isEmpty {
            return truncate(text, max: 160)
        }
        if let signal = data["readable_summary"]?.asObject?["signal"]?.asString, !signal.isEmpty {
            return truncate(signal, max: 160)
        }
        return nil
    }

    public static func progressLabel(from data: [String: AnyCodableLike]?, eventName: String) -> String {
        if let phase = data?["phase"]?.asString, !phase.isEmpty {
            return compactPhaseLabel(phase)
        }
        switch eventName {
        case "stream.thinking_delta": return "thinking"
        case "stream.text_delta": return "reply"
        case "stream.progress": return "progress"
        case "stream.fallback_started": return "fallback"
        case "stream.ack": return "ack"
        default: return "working"
        }
    }

    public static func compactPhaseLabel(_ phase: String) -> String {
        switch phase {
        case "context_build": return "context"
        case "llm_request": return "llm"
        case "llm_streaming": return "llm"
        case "tool_execution": return "tool"
        case "post_processing": return "post"
        case "provider_waiting": return "waiting"
        case "provider_retrying": return "retry"
        default:
            return truncate(phase.replacingOccurrences(of: "_", with: " "), max: 24)
        }
    }

    public static func truncate(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return String(text.prefix(max - 1)) + "…"
    }

    private static func toolDisplayObject(from data: [String: AnyCodableLike]) -> [String: AnyCodableLike]? {
        if let direct = data["agentix.tool_display.v1"]?.asObject { return direct }
        if let meta = data["_meta"]?.asObject {
            if let v = meta["agentix.tool_display.v1"]?.asObject { return v }
            if let agentix = meta["agentix"]?.asObject,
               let v = agentix["tool_display"]?.asObject ?? agentix["tool_display.v1"]?.asObject {
                return v
            }
        }
        return nil
    }

    /// Display label aligned with Hooks settings: `AiWork` / `AiWork CLI`.
    ///
    /// Prefer `client_type` from `sessions.get`. The daemon still emits
    /// `DTCoderGUI` / `DTCoderTUI`; accept `AiWork*` as well after the rename.
    /// Modern `aiwork`/`aiwork tui` attaches via ACP, so both GUI and TUI
    /// session ids often share the `acp:` prefix — prefix alone is not enough.
    public static func sourceLabel(
        forDaemonSessionId sessionId: String?,
        clientType: String? = nil
    ) -> String {
        if let label = label(forClientType: clientType) {
            return label
        }
        guard let sessionId else { return "AiWork" }
        if sessionId.hasPrefix("cli:") { return "AiWork CLI" }
        if sessionId.hasPrefix("acp:") { return "AiWork" }
        if sessionId.hasPrefix("gateway:") { return "AiWork" }
        return "AiWork"
    }

    public static func label(forClientType clientType: String?) -> String? {
        guard let raw = clientType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw {
        case "DTCoderGUI", "DTCoderGui", "AiWorkGUI", "AiWorkGui":
            return "AiWork"
        case "DTCoderTUI", "DTCoderTui", "DTCoderCLI", "DTCoderCli",
             "AiWorkTUI", "AiWorkTui", "AiWorkCLI", "AiWorkCli":
            return "AiWork CLI"
        default:
            break
        }
        let lower = raw.lowercased()
        if lower.contains("tui") || lower.contains("cli") { return "AiWork CLI" }
        if lower.contains("gui") { return "AiWork" }
        return nil
    }

    /// CodeIsland `source` key: GUI → `aiwork`, TUI/CLI → `aiwork-cli`.
    /// GUI and CLI/TUI get separate keys so each surface toggles independently.
    public static func codeIslandSource(
        clientType: String?,
        daemonSessionId: String? = nil
    ) -> String {
        if let label = label(forClientType: clientType) {
            return label == "AiWork CLI" ? "aiwork-cli" : "aiwork"
        }
        // Legacy session-id prefixes when client_type is not hydrated yet.
        if let daemonSessionId, daemonSessionId.hasPrefix("cli:") {
            return "aiwork-cli"
        }
        return "aiwork"
    }

    /// Whether a `sessions.list` entry looks actively busy (for backfill).
    public static func isActiveListEntry(_ entry: [String: AnyCodableLike]) -> Bool {
        if let status = entry["status"]?.asString {
            switch status {
            case "waiting_approval",
                 "waiting_plan_confirmation",
                 "running":
                return true
            default:
                break
            }
        }
        if let phase = entry["readable_summary"]?.asObject?["phase"]?.asString {
            switch phase {
            case "idle", "none", "":
                break
            default:
                return true
            }
        }
        if entry["external_turn"]?.asObject != nil {
            return true
        }
        return false
    }

    public static func agentStatus(fromListEntry entry: [String: AnyCodableLike]) -> AgentStatus {
        if let status = entry["status"]?.asString {
            switch status {
            case "waiting_approval", "waiting_plan_confirmation":
                return .waitingApproval
            case "running":
                return .running
            default:
                break
            }
        }
        if let waitingFor = entry["external_turn"]?.asObject?["waiting_for"]?.asString,
           waitingFor == "question" {
            return .waitingQuestion
        }
        if let phase = entry["readable_summary"]?.asObject?["phase"]?.asString {
            switch phase {
            case "waiting_answer":
                return .waitingQuestion
            case "waiting_approval", "waiting_plan_confirmation":
                return .waitingApproval
            case "tool_execution":
                return .running
            case "idle":
                return .idle
            default:
                return .processing
            }
        }
        if entry["external_turn"]?.asObject != nil {
            return .processing
        }
        return .processing
    }

    /// Whether a locally non-idle AiWork session should be forced idle because
    /// the daemon no longer reports it in `active_request_details`.
    public static func shouldForceIdleSession(
        daemonSessionId: String,
        lastActivity: Date,
        busyDaemonIds: Set<String>,
        now: Date = Date(),
        grace: TimeInterval = 8
    ) -> Bool {
        if busyDaemonIds.contains(daemonSessionId) { return false }
        // Grace avoids racing a turn that just started before stats refresh.
        return now.timeIntervalSince(lastActivity) > grace
    }

    /// Session ids currently executing a turn, from `agent.stats`.
    /// Returns `nil` when the RPC fails so callers do not treat "unreachable"
    /// as "nothing is busy" and mass-idle every session.
    public static func fetchBusyDaemonSessionIds(socketPath: String) -> Set<String>? {
        guard let stats = AiWorkWatchClient.unaryCall(
            socketPath: socketPath,
            method: "agent.stats",
            params: [String: Any](),
            timeoutSeconds: 3
        ), case .response(_, true) = stats.kind else {
            return nil
        }

        var busy = Set<String>()
        if case .array(let rows) = stats.dataObject?["active_request_details"] {
            for row in rows {
                guard let obj = row.asObject else { continue }
                if let sid = obj["session_id"]?.asString ?? obj["sessionId"]?.asString,
                   !sid.isEmpty {
                    busy.insert(sid)
                }
            }
        }
        return busy
    }
}
