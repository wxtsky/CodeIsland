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

    func connect(host: RemoteHost, localSocketPath: String) {
        disconnect()

        generation &+= 1
        let currentGeneration = generation
        status = .connecting

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = buildArguments(host: host, localSocketPath: localSocketPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderr = Pipe()
        process.standardError = stderr
        stderrPipe = stderr

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.generation == currentGeneration else { return }
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

    private func buildArguments(host: RemoteHost, localSocketPath: String) -> [String] {
        var args: [String] = [
            "-N",
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "StreamLocalBindMask=0000",
        ]

        if let port = host.port {
            args += ["-p", String(port)]
        }

        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }

        args += ["-R", "\(host.remoteSocketPath):\(localSocketPath)"]
        args.append(host.sshTarget)
        return args
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
