import Foundation

@MainActor
final class SSHForwarder {
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    private(set) var status: Status = .disconnected {
        didSet {
            guard oldValue != status else { return }
            onStatusChange?(status)
        }
    }

    var onStatusChange: ((Status) -> Void)?

    private var process: Process?
    private var stderrPipe: Pipe?
    private var generation: UInt64 = 0

    func connect(host: RemoteHost, localSocketPath: String, remoteSocketPath: String) {
        disconnect()

        let target = host.sshTarget
        guard !target.isEmpty else {
            status = .failed("invalid host")
            return
        }

        generation &+= 1
        let currentGeneration = generation
        status = .connecting

        // Remove stale remote socket left over from a previous tunnel.
        // macOS system SSH (LibreSSL) does not honour StreamLocalBindUnlink=yes
        // for -R remote forwarding, so a leftover socket causes "remote port
        // forwarding failed" on reconnect.  See #206.
        cleanupStaleRemoteSocket(host: host, remoteSocketPath: remoteSocketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = buildArguments(host: host, localSocketPath: localSocketPath, remoteSocketPath: remoteSocketPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.environment = buildEnvironment(host: host)

        let stderr = Pipe()
        process.standardError = stderr
        stderrPipe = stderr

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == currentGeneration else { return }
                // Release the stderr pipe/handler the moment the child exits. If we leave the
                // readabilityHandler registered, the closed FD keeps getting poked and the
                // handler is invoked in a tight loop, pinning CPU at 100% when ssh disconnects.
                self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                self.stderrPipe = nil
                self.process = nil
                if case .disconnected = self.status { return }
                let code = proc.terminationStatus
                self.status = .failed("ssh exited (\(code))")
            }
        }

        do {
            try process.run()
            self.process = process
            startStderrMonitor(stderr, generation: currentGeneration)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak process] in
                guard let self else { return }
                guard self.generation == currentGeneration else { return }
                guard let process else { return }
                if process.isRunning {
                    self.status = .connected
                } else if case .connecting = self.status {
                    self.status = .failed("ssh exited (\(process.terminationStatus))")
                }
            }
        } catch {
            self.process = nil
            self.stderrPipe = nil
            status = .failed("ssh launch failed")
        }
    }

    func disconnect() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil

        if let process {
            status = .disconnected
            if process.isRunning {
                process.terminate()
            }
        } else {
            status = .disconnected
        }
        self.process = nil
    }

    /// Remove a stale Unix-domain socket on the remote host before forwarding.
    ///
    /// macOS system SSH (`/usr/bin/ssh`, LibreSSL build) ignores
    /// `StreamLocalBindUnlink=yes` for `-R` (remote) forwarding.  When a tunnel
    /// drops the listen socket is left behind and reconnect fails with
    /// "remote port forwarding failed for listen path …".  A quick `rm -f`
    /// over SSH sidesteps the issue.  See issue #206.
    private func cleanupStaleRemoteSocket(host: RemoteHost, remoteSocketPath: String) {
        guard !host.sshTarget.isEmpty else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        proc.arguments = Self.cleanupArguments(host: host, remoteSocketPath: remoteSocketPath)
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.environment = buildEnvironment(host: host)

        try? proc.run()
        proc.waitUntilExit()
    }

    /// Build SSH arguments that remove a stale remote socket file.
    /// Extracted for testability.  See `cleanupStaleRemoteSocket`.
    static func cleanupArguments(host: RemoteHost, remoteSocketPath: String) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]
        if let port = host.port {
            args += ["-p", String(port)]
        }
        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }
        args += [host.sshTarget, "rm", "-f", remoteSocketPath]
        return args
    }

    private func buildArguments(host: RemoteHost, localSocketPath: String, remoteSocketPath: String) -> [String] {
        var args: [String] = [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "StreamLocalBindMask=0000",
            // Never reuse or spawn a multiplexing master connection (#190): a shared
            // ControlMaster makes `ssh -N` hand the forward to the master and exit 0
            // immediately, which we'd misread as a failed tunnel. Force a dedicated
            // connection that stays alive for the lifetime of this forwarder.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
        ]

        if let port = host.port {
            args += ["-p", String(port)]
        }

        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }

        args += ["-R", "\(remoteSocketPath):\(localSocketPath)"]
        args.append(host.sshTarget)
        return args
    }

    /// Merge the host-specific SSH_AUTH_SOCK (if any) into the spawn environment so
    /// agents fronted by a password manager (1Password, Bitwarden, etc.) can sign
    /// the handshake even when the GUI app didn't inherit the env var from a shell.
    /// See issue #81.
    private func buildEnvironment(host: RemoteHost) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let trimmed = host.authSocket.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = (trimmed as NSString).expandingTildeInPath
            env["SSH_AUTH_SOCK"] = expanded
        }
        return env
    }

    private func startStderrMonitor(_ pipe: Pipe, generation: UInt64) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }

            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == generation else { return }
                if case .connecting = self.status {
                    self.status = .failed(message)
                }
            }
        }
    }
}
