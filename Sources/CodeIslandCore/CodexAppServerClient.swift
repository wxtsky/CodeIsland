import CoreFoundation
import Foundation
import Network
import OSLog

/// A parsed JSON-RPC envelope received from the Codex app-server.
///
/// The Codex transport carries JSON; the fields below match
/// JSON-RPC 2.0 with a tolerant reading of responses (the server omits the
/// `jsonrpc` marker on successful replies, which is fine for clients).
public struct CodexJSONRPCMessage: Equatable {
    public enum Kind: Equatable {
        case request(method: String, id: CodexRequestID)
        case notification(method: String)
        case response(id: CodexRequestID)
        case error(id: CodexRequestID?, code: Int, message: String)
    }

    public let raw: [String: AnyCodableLike]
    public let kind: Kind

    public init(raw: [String: AnyCodableLike], kind: Kind) {
        self.raw = raw
        self.kind = kind
    }
}

/// Matches JSON-RPC's union type for request/response ids: int or string.
public enum CodexRequestID: Hashable {
    case int(Int64)
    case string(String)

    public static func decode(_ value: Any?) -> CodexRequestID? {
        if let n = value as? Int { return .int(Int64(n)) }
        if let n = value as? Int64 { return .int(n) }
        if let n = value as? NSNumber { return .int(n.int64Value) }
        if let s = value as? String { return .string(s) }
        return nil
    }

    public var jsonValue: Any {
        switch self {
        case .int(let n): return NSNumber(value: n)
        case .string(let s): return s
        }
    }
}

/// Lightweight, untyped wrapper around `Any` so message records round-trip
/// through `Equatable` without forcing the full schema to be modeled here.
public enum AnyCodableLike: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([AnyCodableLike])
    case object([String: AnyCodableLike])

    public static func from(_ value: Any?) -> AnyCodableLike {
        switch value {
        case nil: return .null
        case let v as NSNull: _ = v; return .null
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            if CFNumberIsFloatType(v) { return .double(v.doubleValue) }
            return .int(v.int64Value)
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(AnyCodableLike.from))
        case let v as [String: Any]:
            var out: [String: AnyCodableLike] = [:]
            for (k, val) in v { out[k] = AnyCodableLike.from(val) }
            return .object(out)
        default: return .null
        }
    }

    public var asObject: [String: AnyCodableLike]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

/// Client lifecycle / connection errors surfaced to callers.
public enum CodexAppServerError: Error, Equatable {
    case executableMissing(String)
    case processLaunchFailed(String)
    case daemonSocketUnavailable
    case notConnected
    case writeFailed(String)
}

/// Speaks JSON-RPC 2.0 to a child app-server over stdio or to the shared
/// app-server daemon over a Unix WebSocket. Framing stays here and session
/// routing belongs to the caller.
///
/// Thread safety: `start`, `stop`, `sendRequest`, and `sendNotification` can
/// be called from any thread; I/O is serialized on an internal dispatch queue.
/// Handler closures run on the caller-supplied callback queue (default: main).
public final class CodexAppServerClient: @unchecked Sendable {
    public typealias MessageHandler = @Sendable (CodexJSONRPCMessage) -> Void
    public typealias ExitHandler = @Sendable (Int32) -> Void

    public let executableURL: URL
    public let arguments: [String]
    public let daemonSocketPath: String?
    private let callbackQueue: DispatchQueue
    private let ioQueue: DispatchQueue
    private let log = Logger(subsystem: "com.codeisland", category: "CodexAppServer")

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var connection: NWConnection?
    private var readBuffer: Data = Data()
    private var nextRequestId: Int64 = 1
    private var isStopped: Bool = true

    /// Test seams (internal, reached via @testable): the pipes wired to the
    /// current child process, so tests can assert the EOF path disarms the
    /// readability handlers instead of letting the dispatch source spin.
    private(set) var currentStdoutPipe: Pipe?
    private(set) var currentStderrPipe: Pipe?

    public var onMessage: MessageHandler?
    public var onExit: ExitHandler?

    public init(
        executableURL: URL = URL(fileURLWithPath: CodexAppServerClient.defaultExecutablePath),
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        daemonSocketPath: String? = nil,
        callbackQueue: DispatchQueue = .main
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.daemonSocketPath = daemonSocketPath
        self.callbackQueue = callbackQueue
        self.ioQueue = DispatchQueue(label: "com.codeisland.codex-app-server-io")
    }

    /// Default location of the Codex binary bundled with the desktop app.
    public static let defaultExecutablePath = "/Applications/Codex.app/Contents/Resources/codex"

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return process?.isRunning == true || connection != nil
    }

    // MARK: - Lifecycle

    public func start() throws {
        if let daemonSocketPath {
            try startDaemonConnection(path: daemonSocketPath)
            return
        }
        lock.lock()
        if process?.isRunning == true {
            lock.unlock()
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            lock.unlock()
            throw CodexAppServerError.executableMissing(executableURL.path)
        }

        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = stdinPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF — the server closed stdout (usually: exited). Unhook, or the
                // dispatch source re-invokes this handler in a tight loop forever,
                // pinning a core (#278 class of bug).
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.async { self?.ingest(data: data) }
        }
        // Drain stderr to avoid filling the pipe buffer. We don't route it anywhere
        // by default; users who want the diagnostic stream can hook onto .onExit and
        // read the handle separately.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                // EOF — same spin hazard as stdout above.
                handle.readabilityHandler = nil
            }
        }

        proc.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            self?.ioQueue.async { self?.handleProcessExit(status: status) }
        }

        do {
            try proc.run()
        } catch {
            lock.unlock()
            throw CodexAppServerError.processLaunchFailed("\(error)")
        }

        self.process = proc
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.currentStdoutPipe = stdoutPipe
        self.currentStderrPipe = stderrPipe
        self.readBuffer.removeAll(keepingCapacity: true)
        self.isStopped = false
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        isStopped = true
        let proc = process
        let stdin = stdinHandle
        let socket = connection
        process = nil
        stdinHandle = nil
        connection = nil
        lock.unlock()

        socket?.cancel()
        try? stdin?.close()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }

    private func startDaemonConnection(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard connection == nil else { return }
        guard let resolvedPath = Self.trustedDaemonSocket(path: path) else {
            throw CodexAppServerError.daemonSocketUnavailable
        }

        let socket = CodexUnixWebSocket.makeConnection(path: resolvedPath)
        connection = socket
        isStopped = false
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket else { return }
            switch state {
            case .ready:
                self.log.info(" Connected to the Codex Desktop daemon")
                self.receiveDaemonMessage(from: socket)
            case .failed, .cancelled:
                self.handleDaemonDisconnect(socket)
            default:
                break
            }
        }
        log.info(" Connecting to the Codex Desktop daemon")
        socket.start(queue: ioQueue)
        ioQueue.asyncAfter(deadline: .now() + 5) { [weak self, weak socket] in
            guard let self, let socket, socket.state != .ready else { return }
            self.handleDaemonDisconnect(socket)
        }
    }

    static func trustedDaemonSocket(path: String) -> String? {
        let controlDirectory = (path as NSString).deletingLastPathComponent
        guard isPrivateDirectory(controlDirectory) else { return nil }
        if SocketPath.holder(of: path) == .thisUser { return path }

        // Codex shortens the control socket path on macOS with an alias into
        // its private per-user temp directory. Connect to the verified target.
        let daemonDirectory = "/private/tmp/codex-daemon-\(getuid())"
        guard let alias = SocketPath.lstat(path), alias.st_uid == getuid(), alias.st_mode & S_IFMT == S_IFLNK,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
              (destination as NSString).deletingLastPathComponent == daemonDirectory,
              isPrivateDirectory(daemonDirectory), SocketPath.holder(of: destination) == .thisUser else { return nil }
        return destination
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        guard let directory = SocketPath.lstat(path) else { return false }
        return directory.st_uid == getuid() && directory.st_mode & S_IFMT == S_IFDIR && directory.st_mode & 0o077 == 0
    }

    private func receiveDaemonMessage(from socket: NWConnection) {
        socket.receiveMessage { [weak self, weak socket] data, context, _, error in
            guard let self, let socket else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || context == nil || metadata?.opcode == .close {
                self.handleDaemonDisconnect(socket)
                return
            }
            if metadata?.opcode == .text, let data, let message = Self.parseMessage(data) {
                let handler = self.onMessage
                self.callbackQueue.async { handler?(message) }
            }
            self.receiveDaemonMessage(from: socket)
        }
    }

    private func handleDaemonDisconnect(_ socket: NWConnection) {
        lock.lock()
        guard connection === socket else {
            lock.unlock()
            return
        }
        connection = nil
        isStopped = true
        let handler = onExit
        lock.unlock()

        log.info(" Disconnected from the Codex Desktop daemon")
        socket.cancel()
        callbackQueue.async { handler?(1) }
    }

    // MARK: - Send

    /// Send a JSON-RPC request and return the id used.
    @discardableResult
    public func sendRequest(method: String, params: Any? = nil) throws -> CodexRequestID {
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
        if let params { body["params"] = params }
        try writeEnvelope(body)
        return .int(id)
    }

    public func sendNotification(method: String, params: Any? = nil) throws {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params { body["params"] = params }
        try writeEnvelope(body)
    }

    /// Reply to a server-to-client JSON-RPC *request* (the server sends these for
    /// e.g. `item/tool/requestUserInput`). The `id` must echo the request's id.
    /// `result` is JSON-serializable (Dictionary/Array/scalar) or nil for `{}`.
    public func sendResponse(id: CodexRequestID, result: Any?) throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": result ?? [String: Any](),
        ]
        try writeEnvelope(body)
    }

    /// Send `initialize` with a minimal ClientInfo payload. Codex always expects
    /// this before any other thread / turn calls will work.
    @discardableResult
    public func initializeHandshake(clientName: String, clientVersion: String, experimentalAPI: Bool = false) throws -> CodexRequestID {
        let capabilities: Any = experimentalAPI ? ["experimentalApi": true] : NSNull()
        return try sendRequest(method: "initialize", params: [
            "clientInfo": ["name": clientName, "version": clientVersion],
            "capabilities": capabilities
        ])
    }

    private func writeEnvelope(_ body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])

        lock.lock()
        let socket = connection
        let handle = stdinHandle
        lock.unlock()

        if let socket {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "codex-json-rpc", metadata: [metadata])
            socket.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self, weak socket] error in
                guard error != nil, let socket else { return }
                self?.handleDaemonDisconnect(socket)
            })
            return
        }

        guard let handle else { throw CodexAppServerError.notConnected }
        var payload = data
        payload.append(0x0A)  // newline terminator
        do {
            try handle.write(contentsOf: payload)
        } catch {
            throw CodexAppServerError.writeFailed("\(error)")
        }
    }

    // MARK: - Receive

    private func ingest(data: Data) {
        readBuffer.append(data)
        let parsed = CodexAppServerClient.drainMessages(buffer: &readBuffer)
        guard !parsed.isEmpty else { return }
        for message in parsed {
            let handler = self.onMessage
            callbackQueue.async { handler?(message) }
        }
    }

    private func handleProcessExit(status: Int32) {
        lock.lock()
        if isStopped {
            lock.unlock()
            return
        }
        isStopped = true
        process = nil
        stdinHandle = nil
        let handler = onExit
        lock.unlock()
        callbackQueue.async { handler?(status) }
    }

    // MARK: - Pure parser (exposed for tests)

    /// Consume as many complete newline-delimited JSON messages as possible
    /// from the buffer. Trailing partial bytes remain in the buffer untouched.
    public static func drainMessages(buffer: inout Data) -> [CodexJSONRPCMessage] {
        var results: [CodexJSONRPCMessage] = []
        let newline: UInt8 = 0x0A
        var searchStart = buffer.startIndex

        while searchStart < buffer.endIndex {
            guard let newlineIndex = buffer[searchStart..<buffer.endIndex].firstIndex(of: newline) else {
                break
            }
            let lineBytes = buffer[searchStart..<newlineIndex]
            if !lineBytes.isEmpty, let parsed = parseMessage(Data(lineBytes)) {
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

    /// Turn a single JSON object string into a `CodexJSONRPCMessage`, or return
    /// nil when the payload is not a recognizable envelope.
    public static func parseMessage(_ data: Data) -> CodexJSONRPCMessage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let raw = AnyCodableLike.from(obj).asObject ?? [:]

        if let errorPayload = obj["error"] as? [String: Any] {
            let code = (errorPayload["code"] as? Int)
                ?? (errorPayload["code"] as? NSNumber).map(\.intValue)
                ?? 0
            let message = (errorPayload["message"] as? String) ?? ""
            return CodexJSONRPCMessage(
                raw: raw,
                kind: .error(id: CodexRequestID.decode(obj["id"]), code: code, message: message)
            )
        }

        if let method = obj["method"] as? String {
            if let id = CodexRequestID.decode(obj["id"]) {
                return CodexJSONRPCMessage(raw: raw, kind: .request(method: method, id: id))
            } else {
                return CodexJSONRPCMessage(raw: raw, kind: .notification(method: method))
            }
        }

        if let id = CodexRequestID.decode(obj["id"]) {
            return CodexJSONRPCMessage(raw: raw, kind: .response(id: id))
        }
        return nil
    }
}
