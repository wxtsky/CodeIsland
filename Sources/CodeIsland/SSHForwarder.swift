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
