import Foundation

@MainActor
final class RemoteManager: ObservableObject {
    static let shared = RemoteManager()

    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var connectionStatus: [String: SSHForwarder.Status] = [:]
    @Published private(set) var installRunning: [String: Bool] = [:]
    @Published private(set) var lastMessage: [String: String] = [:]

    var onDisconnect: ((String) -> Void)?

    private var forwarders: [String: SSHForwarder] = [:]
    private let defaults = UserDefaults.standard
    private let hostsKey = "remoteHosts"

    private init() {
        load()
    }

    func startup() {
        for host in hosts where host.autoConnect {
            connect(id: host.id)
        }
    }

    func shutdown() {
        for host in hosts {
            disconnect(id: host.id)
        }
    }

    func addHost(_ host: RemoteHost) {
        hosts.append(host)
        save()
    }

    func updateHost(_ host: RemoteHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        let wasConnected = (connectionStatus[host.id] == .connected)
        hosts[index] = host
        save()
        if wasConnected {
            reconnect(id: host.id)
        }
    }

    func removeHost(id: String) {
        disconnect(id: id)
        hosts.removeAll { $0.id == id }
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        lastMessage[id] = nil
        save()
    }

    func reconnect(id: String) {
        disconnect(id: id)
        connect(id: id)
    }

    func connect(id: String) {
        guard let host = hosts.first(where: { $0.id == id }) else { return }

        let forwarder = forwarders[id] ?? SSHForwarder()
        forwarders[id] = forwarder
        forwarder.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.handleStatusChange(status, for: host)
            }
        }

        connectionStatus[id] = .connecting
        lastMessage[id] = host.displayAddress

        Task {
            await RemoteInstaller.cleanupRemoteSocket(host: host)
            await MainActor.run {
                forwarder.connect(host: host, localSocketPath: HookServer.socketPath)
            }
        }
    }

    func disconnect(id: String) {
        forwarders[id]?.disconnect()
        forwarders[id] = nil
        connectionStatus[id] = .disconnected
        installRunning[id] = false
        onDisconnect?(id)
    }

    private func handleStatusChange(_ status: SSHForwarder.Status, for host: RemoteHost) {
        connectionStatus[host.id] = status

        switch status {
        case .connected:
            Task { await installHooks(for: host) }
        case .failed(let message):
            installRunning[host.id] = false
            lastMessage[host.id] = message
            onDisconnect?(host.id)
        case .disconnected:
            installRunning[host.id] = false
            onDisconnect?(host.id)
        case .connecting:
            break
        }
    }

    private func installHooks(for host: RemoteHost) async {
        installRunning[host.id] = true
        let result = await RemoteInstaller.installAll(host: host)
        installRunning[host.id] = false
        lastMessage[host.id] = result.message
        if !result.ok {
            connectionStatus[host.id] = .failed(result.message)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: hostsKey),
              let decoded = try? JSONDecoder().decode([RemoteHost].self, from: data) else {
            hosts = []
            return
        }
        hosts = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(hosts) else { return }
        defaults.set(data, forKey: hostsKey)
    }
}
