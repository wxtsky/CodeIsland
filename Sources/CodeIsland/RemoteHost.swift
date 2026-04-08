import Foundation

struct RemoteHost: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var host: String
    var user: String
    var port: Int?
    var identityFile: String
    var autoConnect: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        host: String,
        user: String = "",
        port: Int? = nil,
        identityFile: String = "",
        autoConnect: Bool = false
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.autoConnect = autoConnect
    }

    var sshTarget: String {
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedUser.isEmpty {
            return host.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "\(trimmedUser)@\(host.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    var remoteSocketPath: String { "/tmp/codeisland.sock" }

    var displayAddress: String {
        if let port {
            return "\(sshTarget):\(port)"
        }
        return sshTarget
    }
}
