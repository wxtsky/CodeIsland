import CryptoKit
import Foundation
import Network

/// Codex Desktop's shared daemon serves WebSockets on a Unix domain socket.
/// Network.framework handles the frames. An HTTP upgrade framer supplies
/// the host and request target, which a pathname endpoint alone cannot.
enum CodexUnixWebSocket {
    private static let messageLimit = 16 * 1024 * 1024

    static func makeConnection(path: String) -> NWConnection {
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.skipHandshake = true
        webSocket.maximumMessageSize = messageLimit
        parameters.defaultProtocolStack.applicationProtocols = [
            webSocket, NWProtocolFramer.Options(definition: CodexWebSocketUpgrade.definition),
        ]
        return NWConnection(to: .unix(path: path), using: parameters)
    }
}

final class CodexWebSocketUpgrade: NWProtocolFramerImplementation {
    static let label = "Codex Unix WebSocket Upgrade"
    static let definition = NWProtocolFramer.Definition(implementation: CodexWebSocketUpgrade.self)
    private static let headerLimit = 8 * 1024
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
    private var minimumBytes = 1

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        let request = "GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(key)\r\n\r\n"
        framer.writeOutput(data: Data(request.utf8))
        return .willMarkReady
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        var bytesSeen = 0
        var isValid: Bool?
        _ = framer.parseInput(minimumIncompleteLength: minimumBytes, maximumLength: Self.headerLimit) { buffer, _ in
            guard let buffer else { return 0 }
            bytesSeen = buffer.count
            let data = Data(buffer)
            guard let end = data.range(of: Self.headerEnd) else { return 0 }
            isValid = Self.accepts(String(decoding: data[..<end.lowerBound], as: UTF8.self), key: key)
            return end.upperBound
        }
        if isValid == true {
            framer.markReady()
            framer.passThroughInput()
            framer.passThroughOutput()
            return 0
        }
        if isValid == false || bytesSeen >= Self.headerLimit {
            framer.markFailed(error: .posix(.EPROTO))
            return 0
        }
        minimumBytes = max(minimumBytes, bytesSeen + 1)
        return minimumBytes
    }

    static func accepts(_ header: String, key: String) -> Bool {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first,
              first.split(separator: " ").prefix(2).map(String.init) == ["HTTP/1.1", "101"] else { return false }
        var fields: [String: [String]] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return false }
            fields[parts[0].lowercased(), default: []].append(parts[1].trimmingCharacters(in: .whitespaces))
        }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return fields["sec-websocket-accept"] == [Data(digest).base64EncodedString()]
            && fields["upgrade"]?.map { $0.lowercased() } == ["websocket"]
            && fields["connection", default: []].flatMap { $0.lowercased().split(separator: ",") }
                .contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        do {
            try framer.writeOutputNoCopy(length: messageLength)
        } catch {
            framer.markFailed(error: .posix(.EIO))
        }
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
