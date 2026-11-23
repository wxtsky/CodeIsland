// ============================================================
// codeisland-bridge — Native Claude Code hook event forwarder
// ============================================================
// Replaces shell script + nc with:
// • Proper JSON parsing (no string manipulation)
// • Deep terminal environment detection (tmux, Kitty, iTerm, Ghostty)
// • Native POSIX socket communication
// • session_id validation (drop events without it)
// • CODEISLAND_SKIP env var support
// • A log, /tmp/codeisland-bridge.log (BridgeLog): a line per hook with
//   what it was — event, source, session id, tool, the names of its fields,
//   whether it waits for an answer — never what it said. Whole payloads
//   (prompts, commands, tool output) only with CODEISLAND_DEBUG=1. Kept
//   under ~5 MB, with one older `.1`.
//
// What a hook means is HookIntake's call (CodeIslandCore), the one
// interpretation every edge shares: the bridge gathers the facts it reads —
// argv, environment, stdin, process tree — and delivers what it returns.
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

func executablePath(for pid: pid_t) -> String? {
    var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
    guard len > 0 else { return nil }
    return String(cString: pathBuffer)
}

func parentPID(of pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard ret > 0, info.pbi_ppid > 0 else { return nil }
    return pid_t(info.pbi_ppid)
}

func buildAncestry(startingAt pid: pid_t, maxDepth: Int = 6) -> [(pid: pid_t, executablePath: String?)] {
    guard pid > 0 else { return [] }
    var result: [(pid: pid_t, executablePath: String?)] = []
    var current: pid_t? = pid
    var visited = Set<pid_t>()

    while let currentPid = current, currentPid > 0, result.count < maxDepth, !visited.contains(currentPid) {
        visited.insert(currentPid)
        result.append((pid: currentPid, executablePath: executablePath(for: currentPid)))
        current = parentPID(of: currentPid)
    }

    return result
}

func processArguments(for pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    return ProcArgsParser.parse(Array(buffer.prefix(size)))?.arguments ?? []
}

func bundleIdentifier(forExecutable path: String) -> String? {
    guard let appPath = HostHarnessResolver.outermostAppBundlePath(forExecutable: path) else { return nil }
    return Bundle(path: appPath)?.bundleIdentifier
}

func connectSocket(_ path: String, timeoutMs: Int32 = 3000) -> Int32? {
    let sock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }

    // Suppress per-write SIGPIPE on this socket (belt-and-suspenders with global SIG_IGN)
    var on: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    // sun_path holds 104 bytes; a longer path would overrun it.
    guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        close(sock)
        return nil
    }
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
        let ready = poll(&pfd, 1, timeoutMs)
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
let bridgeLog = BridgeLog(environment: env)

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

// Google Antigravity refuses the tool call when its PreToolUse hook prints no
// decision, so answer before any of the early exits below can leave stdout
// empty (island not running, CODEISLAND_SKIP, a deadline). The island only
// observes Antigravity tool calls; the decision stays with Antigravity (#339).
var wroteImmediateStdout = false
func writeImmediateStdout(_ stdout: String?) {
    guard !wroteImmediateStdout, let stdout else { return }
    wroteImmediateStdout = true
    FileHandle.standardOutput.write(Data(stdout.utf8))
}
writeImmediateStdout(HookIntake.immediateStdout(sourceTag: sourceTag, eventName: eventTag))

// Quick exit: CODEISLAND_SKIP, or a hook Grok imported from another agent's config
guard HookIntake.admits(sourceTag: sourceTag, environment: env) else { exit(0) }

// Quick exit: no socket of this user's at the path. Either the island isn't
// running, or someone else took the path, and a socket of theirs would get
// the event and could answer it (SocketPath.Holder).
guard SocketPath.holder(of: socketPath) == .thisUser else { exit(0) }

// Safety: arm a short alarm before reading stdin — if the calling process
// forgot to close its pipe, we bail out instead of blocking forever.
alarm(5)
let input = FileHandle.standardInput.readDataToEndOfFile()
alarm(0)  // stdin done, cancel preliminary alarm
let stdinObject = HookIntake.stdinObject(input, sourceTag: sourceTag)
// The whole payload only under CODEISLAND_DEBUG=1. What HookIntake leaves out
// of the event (Hermes's copy of the conversation) stays out of it even then.
if bridgeLog.logsPayloads {
    if HookIntake.dropsPartsOfStdin(sourceTag: sourceTag),
       let stdinObject,
       let data = try? JSONSerialization.data(withJSONObject: stdinObject),
       let inputStr = String(data: data, encoding: .utf8) {
        bridgeLog.payload("raw input: \(inputStr)")
    } else if let inputStr = String(data: input, encoding: .utf8) {
        bridgeLog.payload("raw input: \(inputStr)")
    }
}

guard !input.isEmpty, let stdinObject else {
    bridgeLog.note("stdin is not a JSON object (\(input.count) bytes, source=\(BridgeLog.field(sourceTag ?? "-"))), dropping")
    exit(0)
}

// Resolve process ancestry once — used for both session_id fallback (#148) and
// _ppid resolution downstream. Some CLIs execute hooks through `sh -c`, so
// `getppid()` is a transient shell rather than the long-lived CLI process.
let immediateParentPID = getppid()
let ancestry = buildAncestry(startingAt: immediateParentPID)

let facts = HookIntake.Facts(
    sourceTag: sourceTag,
    eventTag: eventTag,
    environment: env.filter { HookIntake.environmentKeys.contains($0.key) },
    parentPID: Int32(immediateParentPID),
    ancestry: ancestry.map { ancestor in
        HookIntake.Ancestor(
            pid: Int32(ancestor.pid),
            executablePath: ancestor.executablePath,
            arguments: { processArguments(for: ancestor.pid) },
            bundleIdentifier: { ancestor.executablePath.flatMap(bundleIdentifier(forExecutable:)) }
        )
    },
    workingDirectory: { FileManager.default.currentDirectoryPath },
    tty: { detectTTY() },
    homeDirectory: { FileManager.default.homeDirectoryForCurrentUser.path },
    stdinDigest: { CursorHookPayload.deliveryDigest(of: input) },
    tmuxClientTTY: { pane in
        // Get client TTY — use explicit path (hook PATH may lack homebrew)
        guard let tmuxBin = findBinary("tmux") else { return nil }
        return runCommand(tmuxBin, args: ["display-message", "-p", "-t", pane, "-F", "#{client_tty}"])
    },
    fileExists: { FileManager.default.fileExists(atPath: $0) }
)

guard var intake = HookIntake(stdin: stdinObject, facts: facts) else {
    bridgeLog.note("no session_id, dropping: source=\(BridgeLog.field(sourceTag ?? "-")) keys=\(BridgeLog.keyList(Array(stdinObject.keys)))")
    exit(0)
}
if intake.sessionIdIsFallback {
    bridgeLog.note("session_id missing, generated fallback id: \(BridgeLog.field(intake.sessionId))")
}

// agy wired through Gemini-style hooks names the event on stdin, not in --event.
writeImmediateStdout(intake.immediateStdout)

let isBlocking = intake.waitsForAnswer
bridgeLog.note(BridgeLog.hookLine(
    eventName: intake.eventName,
    normalizedEventName: intake.normalizedEventName,
    source: intake.source,
    sessionId: intake.sessionId,
    toolName: HookEvent(json: intake.payload)?.toolName,
    payloadKeys: Array(stdinObject.keys),
    blocking: isBlocking
))

// Arm deadline for env collection + connect + send (protects all events).
// For blocking events, this is disarmed right before the long recvAll wait.
alarm(isBlocking ? 8 : 4)

// --- Deep terminal environment collection ---
intake.addTerminalContext()

// --- Serialize enriched JSON ---
guard let enriched = try? JSONSerialization.data(withJSONObject: intake.payload) else { exit(0) }

// --- Connect to Unix socket ---
if intake.deliveryDelay > 0 {
    // Delay slightly to give the terminal TTY time to display the prompt
    // before showing the notch approval card.
    usleep(useconds_t(intake.deliveryDelay * 1_000_000))
}
let connectTimeoutMs: Int32 = isBlocking ? 3000 : 1000
guard let sock = connectSocket(socketPath, timeoutMs: connectTimeoutMs) else {
    bridgeLog.note("socket connect failed")
    exit(0)
}
// The listener must be this user's too: outside sticky /tmp, the file checked
// above may have been replaced since.
guard SocketPath.peerIsUser(sock) else {
    bridgeLog.note("socket listener is another user's, not sending")
    close(sock)
    exit(0)
}

// Set socket timeouts
var sendTv = timeval(tv_sec: isBlocking ? 86400 : 1, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &sendTv, socklen_t(MemoryLayout<timeval>.size))
// Recv timeout: server responds within ms, but allow headroom for main-thread scheduling
var recvTv = timeval(tv_sec: isBlocking ? 86400 : 1, tv_usec: 0)
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

// Blocking events: forward response to stdout, in the form the agent reads
if let stdout = intake.stdout(forAnswer: response) {
    if stdout != response {
        bridgeLog.note("formatted hook response: source=\(BridgeLog.field(intake.source ?? "-")) event=\(BridgeLog.field(intake.normalizedEventName))")
    }
    FileHandle.standardOutput.write(stdout)
}

close(sock)
exit(0)
