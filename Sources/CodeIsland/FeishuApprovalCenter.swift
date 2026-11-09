import Foundation
import Security
import CodeIslandCore

/// Outbound Feishu long connection for Codex permission cards.
///
/// The helper process is the only thing that speaks to Feishu. This type
/// decides. A card button names one request id and either allow-once or deny.
/// Chat text, another Feishu account, a replay, or a request that is already
/// gone never becomes an allow.
@MainActor
final class FeishuApprovalCenter: ObservableObject {
    static let shared = FeishuApprovalCenter()

    @Published private(set) var statusText = ""
    @Published private(set) var isPaired = false
    @Published private(set) var hasSecret = false
    @Published private(set) var pairCandidateOpenID: String?
    @Published private(set) var online = false

    private weak var appState: AppState?
    private var process: Process?
    private var input: FileHandle?
    private var splitter = LineSplitter()
    private var generation = 0
    private var restartAttempt = 0
    private var notices: [UUID: Notice] = [:]
    private let writer = DispatchQueue(label: "com.codeisland.feishu-approval.write")

    private init() {
        refreshIdentity()
        if statusText.isEmpty {
            statusText = Self.text(
                "未连接。填写企业自建应用的 App ID 和 App Secret 后保存。",
                "Not connected. Enter the self-built app's App ID and App Secret, then save."
            )
        }
    }

    func attach(_ appState: AppState) {
        self.appState = appState
    }

    func refreshIdentity() {
        hasSecret = FeishuSecretStore.load() != nil
        let openID = UserDefaults.standard.string(forKey: SettingsKey.feishuApprovalOpenID) ?? ""
        isPaired = !openID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func startIfConfigured() {
        refreshIdentity()
        guard UserDefaults.standard.bool(forKey: SettingsKey.feishuApprovalEnabled) else { return }
        let appID = (UserDefaults.standard.string(forKey: SettingsKey.feishuApprovalAppID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty, FeishuSecretStore.load() != nil else {
            statusText = Self.text(
                "已打开，但还没有可用的 App ID 和 App Secret。",
                "Enabled, but there is no App ID and App Secret yet."
            )
            return
        }
        spawn()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: SettingsKey.feishuApprovalEnabled)
        if enabled {
            startIfConfigured()
        } else {
            stop()
            online = false
            statusText = Self.text(
                "已关闭。待批的命令仍留在这台 Mac 上，不会自动允许。",
                "Turned off. Pending commands stay on this Mac and are not allowed automatically."
            )
        }
    }

    func save(appID: String, secretInput: String) {
        let trimmedID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            statusText = Self.text("请填写 App ID。", "Enter the App ID.")
            return
        }
        let typed = secretInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            guard FeishuSecretStore.save(typed) else {
                statusText = Self.text("钥匙串没有收下 App Secret。", "Keychain did not store the App Secret.")
                return
            }
        } else if FeishuSecretStore.load() == nil {
            statusText = Self.text(
                "请填写 App Secret。它只写入钥匙串，不进配置文件。",
                "Enter the App Secret. It is stored in the Keychain, not in preferences."
            )
            return
        }
        UserDefaults.standard.set(trimmedID, forKey: SettingsKey.feishuApprovalAppID)
        UserDefaults.standard.set(true, forKey: SettingsKey.feishuApprovalEnabled)
        hasSecret = true
        stop()
        spawn()
    }

    func clearSecret() {
        FeishuSecretStore.delete()
        hasSecret = false
        stop()
        statusText = Self.text("已从钥匙串删除 App Secret。", "Removed the App Secret from the Keychain.")
    }

    func armBind() {
        guard process?.isRunning == true else {
            statusText = Self.text("先保存凭证并连上飞书，再开始绑定。", "Save the credentials and connect before binding.")
            return
        }
        send(["op": "arm_bind"])
        statusText = Self.text(
            "请用要绑定的飞书给机器人发一条私聊。文字不会批准命令。",
            "Send the bot a private message from the Feishu account you want to bind. Text is never an approval."
        )
    }

    func confirmBind() {
        guard let openID = pairCandidateOpenID?.trimmingCharacters(in: .whitespacesAndNewlines), !openID.isEmpty else {
            return
        }
        UserDefaults.standard.set(openID, forKey: SettingsKey.feishuApprovalOpenID)
        isPaired = true
        pairCandidateOpenID = nil
        send(["op": "bind", "open_id": openID])
        statusText = Self.text("已绑定。之后只有这个账号的按钮有效。", "Bound. Only this account's buttons count.")
        flush()
    }

    func unbind() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.feishuApprovalOpenID)
        isPaired = false
        pairCandidateOpenID = nil
        send(["op": "unbind"])
        statusText = Self.text("已解除绑定。新的审批不会发到飞书。", "Unbound. New approvals are not sent to Feishu.")
    }

    func offer(
        id: UUID,
        source: String,
        tool: String,
        cwd: String,
        command: String,
        sessionId: String
    ) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.feishuApprovalEnabled) else { return }
        notices[id] = Notice(
            source: PushMessageFormatter.clean(source, limit: 40) ?? "",
            tool: PushMessageFormatter.clean(tool, limit: 120) ?? "",
            cwd: PushMessageFormatter.clean(cwd, limit: 400) ?? "",
            command: PushMessageFormatter.clean(command, limit: 1500) ?? "",
            sessionId: PushMessageFormatter.clean(sessionId, limit: 80) ?? ""
        )
        flush()
    }

    func noteFinished(id: UUID, decision: String) {
        notices.removeValue(forKey: id)
        guard process?.isRunning == true else { return }
        let normalized = (decision == "allow" || decision == "deny") ? decision : "gone"
        send(["op": "resolved", "request_id": id.uuidString, "decision": normalized])
    }

    private func spawn() {
        generation += 1
        let token = generation
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        input = nil
        online = false
        guard let executable = Self.helperURL() else {
            statusText = Self.text(
                "找不到 feishu-bridge。请安装带飞书审批 helper 的这个包。",
                "feishu-bridge is missing. Install the build that contains the Feishu approval helper."
            )
            return
        }
        guard let secret = FeishuSecretStore.load() else {
            statusText = Self.text("钥匙串里没有 App Secret。", "No App Secret is in the Keychain.")
            return
        }
        let appID = (UserDefaults.standard.string(forKey: SettingsKey.feishuApprovalAppID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return }
        let openID = UserDefaults.standard.string(forKey: SettingsKey.feishuApprovalOpenID) ?? ""

        let proc = Process()
        proc.executableURL = executable
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        splitter = LineSplitter()
        outPipe.fileHandleForReading.readabilityHandler = { [splitter] handle in
            let data = handle.availableData
            let lines = splitter.append(data)
            if lines.isEmpty && !data.isEmpty { return }
            Task { @MainActor in
                guard self.generation == token else { return }
                for line in lines { self.consume(line) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        proc.terminationHandler = { _ in
            Task { @MainActor in
                guard self.generation == token else { return }
                self.process = nil
                self.input = nil
                self.online = false
                self.scheduleRestart()
            }
        }
        do {
            try proc.run()
        } catch {
            statusText = Self.text("飞书 helper 没有启动。", "The Feishu helper did not start.")
            return
        }
        process = proc
        input = inPipe.fileHandleForWriting
        statusText = Self.text("正在连接飞书长连接。", "Connecting to Feishu.")
        send([
            "op": "configure",
            "app_id": appID,
            "app_secret": secret,
            "open_id": openID.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
    }

    private func stop() {
        generation += 1
        online = false
        let running = process
        process = nil
        input = nil
        running?.terminate()
    }

    private func scheduleRestart() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.feishuApprovalEnabled) else { return }
        restartAttempt += 1
        let delay = min(30, max(2, restartAttempt * 2))
        let token = generation
        statusText = Self.text(
            "飞书连接断了，\(delay) 秒后重试。断线不会自动允许。",
            "Feishu disconnected. Retrying in \(delay)s. A disconnect does not allow anything."
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard self.generation == token, self.process == nil else { return }
            guard UserDefaults.standard.bool(forKey: SettingsKey.feishuApprovalEnabled) else { return }
            self.spawn()
        }
    }

    private func flush() {
        guard online, isPaired, process?.isRunning == true else { return }
        for id in Array(notices.keys) {
            guard var notice = notices[id], !notice.sent else { continue }
            send([
                "op": "card",
                "request_id": id.uuidString,
                "source": notice.source,
                "tool": notice.tool,
                "cwd": notice.cwd,
                "command": notice.command,
                "session": notice.sessionId,
            ])
            notice.sent = true
            notices[id] = notice
        }
    }

    private func consume(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String else { return }
        switch op {
        case "status":
            let state = object["state"] as? String ?? ""
            let detail = object["detail"] as? String ?? ""
            online = state == "online"
            if online { restartAttempt = 0 }
            statusText = detail.isEmpty ? state : detail
            if online { flush() }
        case "pair_candidate":
            let openID = (object["open_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !openID.isEmpty, !isPaired else { return }
            pairCandidateOpenID = openID
            statusText = Self.text(
                "收到私聊。确认是你的账号后点「绑定这个账号」。",
                "A private message arrived. Confirm it is your account, then bind it."
            )
        case "card_action":
            apply(object)
        case "log":
            if let message = object["message"] as? String, !message.isEmpty {
                statusText = message
            }
        default:
            break
        }
    }

    private func apply(_ object: [String: Any]) {
        let decision = object["decision"] as? String ?? ""
        guard decision == "allow" || decision == "deny" else { return }
        guard let rawID = object["request_id"] as? String, let id = UUID(uuidString: rawID) else { return }
        let openID = (object["open_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let paired = (UserDefaults.standard.string(forKey: SettingsKey.feishuApprovalOpenID) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paired.isEmpty, openID == paired else { return }
        let applied: Bool
        if decision == "allow" {
            applied = appState?.approvePermission(requestId: id) ?? false
        } else {
            applied = appState?.denyPermission(requestId: id) ?? false
        }
        if !applied {
            noteFinished(id: id, decision: "gone")
        }
    }

    private func send(_ object: [String: Any]) {
        guard let handle = input, process?.isRunning == true,
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var line = data
        line.append(0x0A)
        writer.async {
            try? handle.write(contentsOf: line)
        }
    }

    private static func helperURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["CODEISLAND_FEISHU_BRIDGE"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/feishu-bridge"))
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("feishu-bridge"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    private static func text(_ zh: String, _ en: String) -> String {
        L10n.shared.effectiveLanguage.hasPrefix("zh") ? zh : en
    }
}

private struct Notice {
    var source: String
    var tool: String
    var cwd: String
    var command: String
    var sessionId: String
    var sent = false
}

private final class LineSplitter: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let chunk = pending.subdata(in: pending.startIndex..<newline)
            let next = pending.index(after: newline)
            pending = next < pending.endIndex ? pending.subdata(in: next..<pending.endIndex) : Data()
            guard let text = String(data: chunk, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines
    }
}

enum FeishuSecretStore {
    private static let service = "com.codeisland.app.feishu-approval"
    private static let account = "app-secret"

    static func save(_ secret: String) -> Bool {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(secret.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return secret?.isEmpty == false ? secret : nil
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
