import CodeIslandCore
import Foundation
import Network

private let log = CodeIslandLogger(subsystem: "com.codeisland", category: "HookServer")

@MainActor
class HookServer {
    private let appState: AppState
    nonisolated static var socketPath: String { SocketPath.path }
    private var listener: NWListener?

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up stale socket
        unlink(HookServer.socketPath)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: HookServer.socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                // Restrict socket to current user only (0o700)
                chmod(HookServer.socketPath, 0o700)
                log.info("HookServer listening on \(HookServer.socketPath)")
            case .failed(let error):
                log.error("HookServer failed: \(error.localizedDescription)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(HookServer.socketPath)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 1_048_576  // 1MB safety limit

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads
                if data.count > Self.maxPayloadSize {
                    log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    /// Internal tools that are safe to auto-approve without user confirmation.
    private static let autoApproveTools: Set<String> = [
        "TaskCreate", "TaskUpdate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
        "TodoRead", "TodoWrite",
        "EnterPlanMode", "ExitPlanMode",
    ]

    private func processRequest(data: Data, connection: NWConnection) {
        CodeIslandLog.appendDebugEvent([
            "ts": CodeIslandLog.nowISO8601(),
            "kind": "hook_request_raw",
            "socketPath": HookServer.socketPath,
            "payload": CodeIslandLog.jsonValue(from: data),
        ])

        guard let event = HookEvent(from: data) else {
            log.error(
                "\(HookLogMessage.parseFailed(raw: CodeIslandLog.serializedJSONString(from: data)))"
            )
            sendResponse(connection: connection, data: Data("{\"error\":\"parse_failed\"}".utf8))
            return
        }

        CodeIslandLog.appendDebugEvent([
            "ts": CodeIslandLog.nowISO8601(),
            "kind": "hook_request_parsed",
            "sessionId": event.sessionId ?? "default",
            "eventName": event.eventName,
            "toolName": event.toolName ?? "",
            "payload": event.rawJSON,
        ])

        if let rawSource = event.rawJSON["_source"] as? String,
            SessionSnapshot.normalizedSupportedSource(rawSource) == nil
        {
            log.debug(
                "\(HookLogMessage.unsupportedSourceDropped(payload: CodeIslandLog.serializedJSONString(fromJSONObject: event.rawJSON)))"
            )
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        if event.eventName == "PermissionRequest" {
            let sessionId = event.sessionId ?? "default"
            log.info(
                "\(HookLogMessage.permissionRequest("routed", sessionId: sessionId, toolName: event.toolName ?? "unknown", payload: CodeIslandLog.serializedJSONString(fromJSONObject: event.rawJSON)))"
            )

            // Auto-approve safe internal tools without showing UI
            if let toolName = event.toolName, Self.autoApproveTools.contains(toolName) {
                log.info(
                    "PermissionRequest auto-approved sid=\(sessionId) tool=\(toolName)"
                )
                let response = #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
                log.info(
                    "\(HookLogMessage.permissionRequestAutoApproveResponse(sessionId: sessionId, data: CodeIslandLog.serializedJSONString(from: Data(response.utf8))))"
                )
                sendResponse(connection: connection, data: Data(response.utf8))
                return
            }

            // AskUserQuestion is a question, not a permission — route to QuestionBar
            if event.toolName == "AskUserQuestion" {
                log.info(
                    "\(HookLogMessage.askUserQuestion("routed", sessionId: sessionId, payload: CodeIslandLog.serializedJSONString(fromJSONObject: event.rawJSON)))"
                )
                monitorPeerDisconnect(connection: connection, sessionId: sessionId)
                Task {
                    let responseBody = await withCheckedContinuation { continuation in
                        appState.handleAskUserQuestion(event, continuation: continuation)
                    }
                    self.sendResponse(connection: connection, data: responseBody)
                }
                return
            }
            monitorPeerDisconnect(connection: connection, sessionId: sessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handlePermissionRequest(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }
        } else if EventNormalizer.normalize(event.eventName) == "Notification",
                  QuestionPayload.from(event: event) != nil {
            let questionSessionId = event.sessionId ?? "default"
            log.info(
                "\(HookLogMessage.questionNotification("routed", sessionId: questionSessionId, payload: CodeIslandLog.serializedJSONString(fromJSONObject: event.rawJSON)))"
            )
            monitorPeerDisconnect(connection: connection, sessionId: questionSessionId)
            Task {
                let responseBody = await withCheckedContinuation { continuation in
                    appState.handleQuestion(event, continuation: continuation)
                }
                self.sendResponse(connection: connection, data: responseBody)
            }
        } else {
            appState.handleEvent(event)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    /// Per-connection state used by the disconnect monitor.
    /// `responded` flips to true once we've sent the response, so our own
    /// `connection.cancel()` inside `sendResponse` does not masquerade as a
    /// peer disconnect.
    private final class ConnectionContext {
        var responded: Bool = false
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    /// Watch for bridge process disconnect — indicates the bridge process actually died
    /// (e.g. user Ctrl-C'd Claude Code), NOT a normal half-close.
    ///
    /// Previously this used `connection.receive(min:1, max:1)` which triggered on EOF.
    /// But the bridge always does `shutdown(SHUT_WR)` after sending the request (see
    /// CodeIslandBridge/main.swift), which produces an immediate EOF on the read side.
    /// That caused every PermissionRequest to be auto-drained as `deny` before the UI
    /// card was even visible. We now rely on `stateUpdateHandler` transitioning to
    /// `cancelled`/`failed` — which only happens on real socket teardown, not half-close.
    private func monitorPeerDisconnect(connection: NWConnection, sessionId: String) {
        let context = ConnectionContext()
        connectionContexts[ObjectIdentifier(connection)] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    if !context.responded {
                        self.appState.handlePeerDisconnect(sessionId: sessionId)
                    }
                    self.connectionContexts.removeValue(forKey: ObjectIdentifier(connection))
                default:
                    break
                }
            }
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        log.info("\(HookLogMessage.hookResponse(data: CodeIslandLog.serializedJSONString(from: data)))")
        CodeIslandLog.appendDebugEvent([
            "ts": CodeIslandLog.nowISO8601(),
            "kind": "hook_response",
            "payload": CodeIslandLog.jsonValue(from: data),
        ])
        // Mark as responded BEFORE cancel() so the disconnect monitor ignores our own teardown.
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
