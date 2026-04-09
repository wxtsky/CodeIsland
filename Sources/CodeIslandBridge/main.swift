// ============================================================
// codeisland-bridge — Native Claude Code hook event forwarder
// ============================================================
// Replaces shell script + nc with:
// • Proper JSON parsing (no string manipulation)
// • Deep terminal environment detection (tmux, Kitty, iTerm, Ghostty)
// • Native POSIX socket communication
// • session_id validation (drop events without it)
// • CODEISLAND_SKIP env var support
// • Debug logging (CODEISLAND_DEBUG)
// ============================================================

import Foundation
import Darwin
import CodeIslandCore

// MARK: - Global Safety Net

// Never let a broken pipe kill the bridge — just fail the write silently
signal(SIGPIPE, SIG_IGN)

// Hard deadline: if anything hangs beyond this, bail out cleanly.
// Non-blocking events get 8s; blocking (permission/question) gets no alarm
// since those legitimately wait for user interaction.
// The alarm is armed later once we know the event type.
signal(SIGALRM) { _ in
    _exit(0)  // immediate, no cleanup — we're stuck anyway
}

// MARK: - Helper Functions

func detectTTY() -> String {
    let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
    if fd >= 0 {
        if let name = ttyname(fd) {
            close(fd)
            return String(cString: name)
        }
        close(fd)
    }
    return ""
}

func findBinary(_ name: String) -> String? {
    let searchPaths = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    return searchPaths.first { access($0, X_OK) == 0 }
}

func runCommand(_ path: String, args: [String]) -> String? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (str?.isEmpty == false) ? str : nil
    } catch {
        return nil
    }
}

func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CODEISLAND_DEBUG"] != nil else { return }
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(message)\n"
    let path = "/tmp/codeisland-bridge.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
    }
}

func nonEmptyString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func connectSocket(_ path: String) -> Int32? {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }

    // Suppress per-write SIGPIPE on this socket (belt-and-suspenders with global SIG_IGN)
    var on: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
        path.withCString { _ = strcpy(ptr, $0) }
    }

    // Non-blocking connect with 3s timeout — prevents hanging if the listener is stuck
    let origFlags = fcntl(sock, F_GETFL)
    _ = fcntl(sock, F_SETFL, origFlags | O_NONBLOCK)

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 && errno != EINPROGRESS {
        close(sock)
        return nil
    }

    if result != 0 {
        // Wait for connect to complete (or timeout)
        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, 3000)  // 3 seconds
        if ready <= 0 {
            close(sock)
            return nil
        }
        // Check for socket error
        var sockErr: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &sockErr, &errLen)
        if sockErr != 0 {
            close(sock)
            return nil
        }
    }

    // Restore blocking mode for send/recv
    _ = fcntl(sock, F_SETFL, origFlags)
    return sock
}

func sendAll(_ sock: Int32, data: Data) {
    data.withUnsafeBytes { buf in
        guard let base = buf.baseAddress else { return }
        var sent = 0
        while sent < buf.count {
            let n = send(sock, base + sent, buf.count - sent, 0)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            sent += n
        }
    }
}

func recvAll(_ sock: Int32) -> Data {
    var response = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(sock, &buf, buf.count, 0)
        if n < 0 {
            if errno == EINTR { continue }
            break
        }
        if n == 0 { break }
        response.append(contentsOf: buf[..<n])
    }
    return response
}

// MARK: - Main

let socketPath = SocketPath.path
let env = ProcessInfo.processInfo.environment
let args = CommandLine.arguments

// Parse --source flag (e.g. --source codex)
var sourceTag: String? = nil
if let idx = args.firstIndex(of: "--source"), idx + 1 < args.count {
    sourceTag = args[idx + 1]
}

// Parse --event flag (e.g. --event sessionStart) for CLIs that lack hook_event_name in stdin
var eventTag: String? = nil
if let idx = args.firstIndex(of: "--event"), idx + 1 < args.count {
    eventTag = args[idx + 1]
}

// Quick exit: skip if CODEISLAND_SKIP is set
guard env["CODEISLAND_SKIP"] == nil else { exit(0) }

// Quick exit: socket doesn't exist or isn't a socket
var statBuf = stat()
guard stat(socketPath, &statBuf) == 0, (statBuf.st_mode & S_IFMT) == S_IFSOCK else { exit(0) }

// Safety: arm a short alarm before reading stdin — if the calling process
// forgot to close its pipe, we bail out instead of blocking forever.
alarm(5)
let input = FileHandle.standardInput.readDataToEndOfFile()
alarm(0)  // stdin done, cancel preliminary alarm

guard !input.isEmpty,
      var json = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else {
    exit(0)
}

// Copilot CLI adaptation: its stdin JSON lacks session_id and hook_event_name.
// Normalize Copilot's camelCase payload and pass through sessionId when present.
if sourceTag == "copilot" {
    if json["hook_event_name"] == nil, let event = eventTag {
        json["hook_event_name"] = event
    }
    if json["session_id"] == nil, let sessionId = nonEmptyString(json["sessionId"]) {
        json["session_id"] = sessionId
    }
    // Map Copilot-specific field names to internal conventions
    if let toolName = json["toolName"] as? String {
        json["tool_name"] = toolName
    }
    if let toolArgsStr = json["toolArgs"] as? String,
       let argsData = toolArgsStr.data(using: .utf8),
       let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
        json["tool_input"] = argsObj
    }
}

// Validate: must have non-empty session_id
guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
    debugLog("no session_id, dropping")
    exit(0)
}

// Event type detection
let eventName = json["hook_event_name"] as? String ?? ""
let isPermission = eventName == "PermissionRequest"
let isQuestion = (eventName == "Notification" || eventName == "afterAgentThought")
    && json["question"] as? String != nil
let isBlocking = isPermission || isQuestion

debugLog("event=\(eventName) session=\(sessionId) permission=\(isPermission) question=\(isQuestion)")

// Arm deadline for env collection + connect + send (protects all events).
// For blocking events, this is disarmed right before the long recvAll wait.
alarm(8)

// --- Deep terminal environment collection ---
// Terminal app identification (only include when present)
if let termApp = env["TERM_PROGRAM"], !termApp.isEmpty {
    json["_term_app"] = termApp
}
if let termBundle = env["__CFBundleIdentifier"], !termBundle.isEmpty {
    json["_term_bundle"] = termBundle
}

// iTerm2 session — extract GUID after "w0t0p0:" prefix for AppleScript matching
if let iterm = env["ITERM_SESSION_ID"], !iterm.isEmpty {
    if let colonIdx = iterm.firstIndex(of: ":") {
        json["_iterm_session"] = String(iterm[iterm.index(after: colonIdx)...])
    } else {
        json["_iterm_session"] = iterm
    }
}

// Kitty window
if let kitty = env["KITTY_WINDOW_ID"], !kitty.isEmpty {
    json["_kitty_window"] = kitty
}

// tmux detection — deep info collection
if let tmux = env["TMUX"], !tmux.isEmpty {
    json["_tmux"] = tmux
    if let pane = env["TMUX_PANE"], !pane.isEmpty {
        json["_tmux_pane"] = pane
        // Get client TTY — use explicit path (hook PATH may lack homebrew)
        if let tmuxBin = findBinary("tmux"),
           let clientTTY = runCommand(tmuxBin, args: ["display-message", "-p", "-t", pane, "-F", "#{client_tty}"]) {
            json["_tmux_client_tty"] = clientTTY
        }
    }
}

// TTY path
let tty = detectTTY()
if !tty.isEmpty {
    json["_tty"] = tty
}

// cmux surface / workspace (env vars injected by cmux)
// cmux auto-injects CMUX_SURFACE_ID and CMUX_WORKSPACE_ID into each terminal on launch
// Bridge simply carries them into the payload during env collection; no extra process calls needed
if let cmuxSurface = env["CMUX_SURFACE_ID"], !cmuxSurface.isEmpty {
    json["_cmux_surface_id"] = cmuxSurface
}
if let cmuxWorkspace = env["CMUX_WORKSPACE_ID"], !cmuxWorkspace.isEmpty {
    json["_cmux_workspace_id"] = cmuxWorkspace
}

// Source tag (e.g. "codex" when called via --source codex)
if let source = sourceTag {
    json["_source"] = source
}

// Parent PID — the CLI process that spawned this hook (works for any CLI)
json["_ppid"] = getppid()

// --- Serialize enriched JSON ---
guard let enriched = try? JSONSerialization.data(withJSONObject: json) else { exit(1) }

// --- Connect to Unix socket ---
guard let sock = connectSocket(socketPath) else {
    debugLog("socket connect failed")
    exit(0)
}

// Set socket timeouts
var sendTv = timeval(tv_sec: isBlocking ? 86400 : 3, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &sendTv, socklen_t(MemoryLayout<timeval>.size))
// Recv timeout: server responds within ms, but allow headroom for main-thread scheduling
var recvTv = timeval(tv_sec: isBlocking ? 86400 : 3, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &recvTv, socklen_t(MemoryLayout<timeval>.size))

// Send enriched event data
sendAll(sock, data: enriched)

// Signal end of write (half-close → server sees EOF)
shutdown(sock, SHUT_WR)

// Blocking events wait for user interaction (minutes/hours) — disarm the deadline.
// Non-blocking events keep the alarm; SO_RCVTIMEO (3s) + alarm(8) double-protect.
if isBlocking {
    alarm(0)
}

// Wait for server response — critical: without this, close() races ahead
// of NWListener's main-thread handler and the event is lost
let response = recvAll(sock)

// Blocking events: forward response to stdout for Claude Code
if isBlocking && !response.isEmpty {
    FileHandle.standardOutput.write(response)
}

close(sock)
exit(0)
