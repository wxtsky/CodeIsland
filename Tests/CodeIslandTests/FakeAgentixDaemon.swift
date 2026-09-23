import Foundation

/// In-process stand-in for an Agentix daemon, so AiWork tests never touch a
/// real daemon on the developer's machine.
///
/// Lays out `<stateDir>/run/<agentId>/agent.sock` + `agent.ready` exactly as
/// `AiWorkWatchClient.discoverReadyDaemons` expects, and answers the first
/// request line of each connection according to `behavior`.
final class FakeAgentixDaemon: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Reply with this NDJSON line, then close.
        case reply(String)
        /// Read the request, then close without replying.
        case close
        /// Read the request and hold the connection open until `stop()`.
        case hang
    }

    let stateDir: String
    let socketPath: String

    private let listenFD: Int32
    private let respond: @Sendable (_ method: String) -> Behavior
    private let queue = DispatchQueue(label: "test.fake-agentix")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var connections = 0
    private var requestedMethods: [String] = []
    private var heldFDs: [Int32] = []
    private var stopped = false

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections
    }

    var methods: [String] {
        lock.lock(); defer { lock.unlock() }
        return requestedMethods
    }

    init(agentId: String = "coder", respond: @escaping @Sendable (_ method: String) -> Behavior) throws {
        // sun_path is 104 bytes on Darwin. NSTemporaryDirectory() (/var/folders/…)
        // plus run/<agent>/agent.sock can overflow it, so use a short /tmp root.
        stateDir = "/tmp/ci-agentix-\(UUID().uuidString.prefix(8))"
        let agentDir = stateDir + "/run/" + agentId
        try FileManager.default.createDirectory(atPath: agentDir, withIntermediateDirectories: true)
        socketPath = agentDir + "/agent.sock"
        self.respond = respond

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = b }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 64) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        FileManager.default.createFile(atPath: agentDir + "/agent.ready", contents: Data("1".utf8))

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    deinit {
        stop()
    }

    /// Close the listener and every held connection, and remove the state dir.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let held = heldFDs
        heldFDs.removeAll()
        let source = self.source
        self.source = nil
        lock.unlock()

        source?.cancel()
        for fd in held { close(fd) }
        try? FileManager.default.removeItem(atPath: stateDir)
    }

    private func acceptPending() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { return }
            lock.lock()
            connections += 1
            lock.unlock()
            // Darwin's accept() inherits O_NONBLOCK from the listener; serve() wants
            // blocking reads, bounded by a receive timeout so a silent peer can't
            // wedge the test. SO_NOSIGPIPE keeps a reply to a peer that already
            // timed out from killing the test process.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global().async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        var request = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !request.contains(0x0A) {
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { break }
            request.append(contentsOf: chunk[0..<n])
        }
        let line = request.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        let method = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["method"] as? String ?? ""

        lock.lock()
        requestedMethods.append(method)
        let isStopped = stopped
        lock.unlock()
        if isStopped { close(fd); return }

        switch respond(method) {
        case .reply(let json):
            let bytes = Array((json + "\n").utf8)
            _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            close(fd)
        case .close:
            close(fd)
        case .hang:
            lock.lock()
            if stopped {
                lock.unlock()
                close(fd)
            } else {
                heldFDs.append(fd)
                lock.unlock()
            }
        }
    }
}
