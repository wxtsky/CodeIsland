import CodeIslandCore
import OSLog

/// A shared daemon broadcasts thread status. The request itself is delivered
/// only to subscribers, so join a Desktop thread when it has a pending question.
@MainActor
final class CodexDesktopQuestionSubscriptions {
    private enum Pending {
        case loadedThreads
        case read(threadId: String)
        case resume(threadId: String)
        case unsubscribe(threadId: String)
    }

    private let client: CodexAppServerClient
    private let initializeId: CodexRequestID
    private let log = Logger(subsystem: "com.codeisland", category: "CodexDesktopQuestions")
    private var pending: [CodexRequestID: Pending] = [:]
    private var reading = Set<String>()
    private var subscribed = Set<String>()

    init(client: CodexAppServerClient, initializeId: CodexRequestID) {
        self.client = client
        self.initializeId = initializeId
    }

    /// Consume routing replies and allow only known Desktop question requests
    /// to reach the UI. Other app-server clients may share the same daemon.
    func admits(_ message: CodexJSONRPCMessage) -> Bool {
        let params = message.raw["params"]?.asObject ?? [:]
        switch message.kind {
        case .response(let id):
            if id == initializeId {
                do {
                    try client.sendNotification(method: "initialized")
                    log.info(" Checking for questions already open in Codex Desktop")
                    request("thread/loaded/list", params: [:], tracking: .loadedThreads)
                } catch {
                    log.error(" Could not complete the Codex daemon handshake")
                }
            } else if let operation = pending.removeValue(forKey: id) {
                applyResponse(message.raw["result"]?.asObject ?? [:], operation: operation)
            }
            return false
        case .error(let id, let code, _):
            if let id, let operation = pending.removeValue(forKey: id) {
                switch operation {
                case .read(let threadId):
                    reading.remove(threadId)
                case .resume(let threadId):
                    subscribed.remove(threadId)
                case .loadedThreads, .unsubscribe:
                    break
                }
                log.error(" Codex Desktop question routing failed with RPC code \(code)")
            }
            return false
        case .request(let method, _):
            guard method == "item/tool/requestUserInput", let threadId = params["threadId"]?.asString else { return false }
            return subscribed.contains(threadId)
        case .notification(let method):
            return applyNotification(method, params: params)
        }
    }

    private func applyNotification(_ method: String, params: [String: AnyCodableLike]) -> Bool {
        if method == "thread/started" {
            guard let thread = params["thread"]?.asObject, Self.isDesktop(thread) else { return false }
            if Self.isWaiting(thread["status"]?.asObject), let threadId = thread["id"]?.asString {
                subscribe(threadId: threadId)
            }
            return true
        }
        guard let threadId = params["threadId"]?.asString else { return false }
        switch method {
        case "thread/status/changed":
            let status = params["status"]?.asObject
            if Self.isWaiting(status) {
                read(threadId: threadId)
            } else if let type = status?["type"]?.asString, type != "active" {
                unsubscribe(threadId: threadId)
            }
        case "turn/completed":
            unsubscribe(threadId: threadId)
        case "thread/closed":
            subscribed.remove(threadId)
        default:
            break
        }
        return true
    }

    private func applyResponse(_ result: [String: AnyCodableLike], operation: Pending) {
        switch operation {
        case .loadedThreads:
            if case .array(let ids)? = result["data"] {
                for threadId in ids.compactMap(\.asString) { read(threadId: threadId) }
            }
            if let cursor = result["nextCursor"]?.asString {
                request("thread/loaded/list", params: ["cursor": cursor], tracking: .loadedThreads)
            }
        case .read(let threadId):
            reading.remove(threadId)
            guard let thread = result["thread"]?.asObject, thread["id"]?.asString == threadId,
                  Self.isDesktop(thread), Self.isWaiting(thread["status"]?.asObject) else { return }
            subscribe(threadId: threadId)
        case .resume, .unsubscribe:
            break
        }
    }

    private func read(threadId: String) {
        guard !subscribed.contains(threadId), !reading.contains(threadId) else { return }
        if request("thread/read", params: ["threadId": threadId, "includeTurns": false], tracking: .read(threadId: threadId)) {
            reading.insert(threadId)
        }
    }

    private func subscribe(threadId: String) {
        guard !subscribed.contains(threadId) else { return }
        if request("thread/resume", params: ["threadId": threadId, "excludeTurns": true], tracking: .resume(threadId: threadId)) {
            subscribed.insert(threadId)
            log.info(" Subscribed to a waiting Codex Desktop thread")
        }
    }

    private func unsubscribe(threadId: String) {
        guard subscribed.remove(threadId) != nil else { return }
        request("thread/unsubscribe", params: ["threadId": threadId], tracking: .unsubscribe(threadId: threadId))
    }

    @discardableResult
    private func request(_ method: String, params: [String: Any], tracking: Pending) -> Bool {
        do {
            let id = try client.sendRequest(method: method, params: params)
            pending[id] = tracking
            return true
        } catch {
            log.error(" Could not send Codex daemon request \(method, privacy: .public)")
            return false
        }
    }

    private static func isDesktop(_ thread: [String: AnyCodableLike]) -> Bool {
        CodexDiscovery.codexThreadOrigin(
            originator: thread["originator"]?.asString,
            source: thread["source"]?.asString,
            isSubagentSource: thread["source"]?.asObject != nil
        ) == .desktop
    }

    private static func isWaiting(_ status: [String: AnyCodableLike]?) -> Bool {
        guard status?["type"]?.asString == "active", case .array(let flags)? = status?["activeFlags"] else { return false }
        return flags.contains(.string("waitingOnUserInput"))
    }
}
