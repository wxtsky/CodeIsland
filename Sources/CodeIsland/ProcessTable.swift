import Foundation
import Darwin
import CodeIslandCore

/// A process as of when it was seen: a pid is only the same process while
/// its start time matches, since the kernel reuses pids.
struct ProcessIdentity: Equatable {
    let pid: pid_t
    let startTime: Date?
}

/// Point reads of the local process table (libproc / sysctl), for session
/// discovery and process liveness. Each is a syscall or two, callable from
/// any thread; the whole-table scans built on them (`AgentProcessFinder`)
/// run off the main actor.
enum ProcessTable {
    static func allProcessIds() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    static func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard len > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    /// Get the current working directory of a process using proc_pidinfo
    static func getCwd(for pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Get the start time of a process using proc_pidinfo
    static func getProcessStartTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// Get command-line arguments for a process via sysctl KERN_PROCARGS2.
    static func getProcessArgs(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        // First 4 bytes = argc (as int32)
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 256 else { return nil }

        // Skip past argc + executable path + padding nulls to reach argv
        var offset = MemoryLayout<Int32>.size
        // Skip executable path
        while offset < size && buffer[offset] != 0 { offset += 1 }
        // Skip null padding
        while offset < size && buffer[offset] == 0 { offset += 1 }

        // Parse null-terminated argv strings
        var args: [String] = []
        var argStart = offset
        for _ in 0..<argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > argStart {
                args.append(String(bytes: buffer[argStart..<offset], encoding: .utf8) ?? "")
            }
            offset += 1
            argStart = offset
        }
        return args
    }

    /// `keys` from another process's environment, read from the same
    /// `KERN_PROCARGS2` block `getProcessArgs` uses. Nil when the process is
    /// gone, another user's, or the kernel withheld the block.
    static func environment(for pid: pid_t, keys: Set<String>) -> [String: String]? {
        guard pid > 1 else { return nil }
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcArgsParser.completeEnvironment(Array(buffer.prefix(size)), keys: keys)
    }

    /// Current ppid of `pid`, or nil if the process is gone / info is unavailable.
    static func parentPid(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The parent to walk up to from `pid`: nil once there is none (ppid 0).
    static func parentPID(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0, info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func liveProcessIdentity(for pid: pid_t) -> ProcessIdentity? {
        guard pid > 0, kill(pid, 0) == 0 else { return nil }
        return ProcessIdentity(pid: pid, startTime: getProcessStartTime(pid))
    }

    static func isLiveProcess(_ process: ProcessIdentity) -> Bool {
        guard process.pid > 0, kill(process.pid, 0) == 0 else { return false }
        guard let expectedStart = process.startTime else { return true }
        return getProcessStartTime(process.pid) == expectedStart
    }

    /// The process a session's recorded pid stands for: the nearest of it
    /// and up to five ancestors whose executable is `source`'s CLI, or the
    /// pid itself when none is (hook shells and wrappers sit in between).
    /// A Claude Code tool (`grep` run as `ugrep` by its binary) is not the
    /// CLI either: the walk goes on to the session that ran it.
    static func trackedProcessIdentity(for pid: pid_t, source: String?) -> ProcessIdentity? {
        guard pid > 0 else { return nil }

        var currentPid: pid_t? = pid
        var visited = Set<pid_t>()
        var firstLiveProcess: ProcessIdentity?

        for _ in 0..<6 {
            guard let candidatePid = currentPid,
                  candidatePid > 0,
                  !visited.contains(candidatePid),
                  let process = liveProcessIdentity(for: candidatePid) else {
                break
            }

            visited.insert(candidatePid)
            if firstLiveProcess == nil {
                firstLiveProcess = process
            }
            if let path = executablePath(for: candidatePid),
               CLIProcessResolver.sourceMatchesExecutablePath(path, source: source),
               !isClaudeCodeTool(candidatePid, source: source) {
                return process
            }
            currentPid = parentPID(for: candidatePid)
        }

        return firstLiveProcess
    }

    private static func isClaudeCodeTool(_ pid: pid_t, source: String?) -> Bool {
        guard SessionSnapshot.normalizedSupportedSource(source) == "claude",
              let argv0 = getProcessArgs(pid)?.first else { return false }
        return AgentProcessFinder.claudeCodeToolNames.contains((argv0 as NSString).lastPathComponent)
    }
}
