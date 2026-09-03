import Foundation

/// The Claude Code OAuth login, as Claude Code itself stores it.
public struct ClaudeOAuthCredential: Equatable, Sendable {
    public let accessToken: String
    public let subscriptionType: String?
    public let expiresAt: Date?

    public init(accessToken: String, subscriptionType: String? = nil, expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.subscriptionType = subscriptionType
        self.expiresAt = expiresAt
    }
}

/// Read-only access to the Claude Code login. Never refreshes the token —
/// rotating it from here would invalidate the copy Claude Code holds, so an
/// expired token simply means "run Claude Code once".
public enum ClaudeCredentialStore {
    /// Keychain generic-password service Claude Code writes on macOS.
    public static let keychainService = "Claude Code-credentials"

    /// `{"claudeAiOauth":{"accessToken":…,"subscriptionType":…,"expiresAt":ms}}`
    public static func parse(_ data: Data) -> ClaudeOAuthCredential? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date?
        if let ms = oauth["expiresAt"] as? NSNumber {
            expires = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        return ClaudeOAuthCredential(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String,
            expiresAt: expires
        )
    }

    /// Raw item data from the login keychain, read through `/usr/bin/security`.
    ///
    /// Claude Code stores the item with that same tool, so `security` is on
    /// the item's access list and reads it silently. `SecItemCopyMatching`
    /// from our own process would instead raise the "wants to use your
    /// confidential information" prompt — and, for an ad-hoc signed build,
    /// raise it again after every rebuild.
    public static func readKeychain(service: String = keychainService, timeout: TimeInterval = 5) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if proc.isRunning { proc.terminate(); return nil }
        guard proc.terminationStatus == 0 else { return nil }
        // `-w` prints the secret followed by a newline.
        var bytes = data
        while let last = bytes.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") { bytes.removeLast() }
        return bytes.isEmpty ? nil : bytes
    }

    /// File fallback (`~/.claude/.credentials.json`) used by Claude Code where
    /// no keychain is available.
    public static func readFile(claudeHome: String = ClaudeConfigPaths.configDir()) -> Data? {
        FileManager.default.contents(atPath: claudeHome + "/.credentials.json")
    }

    public static func load() -> ClaudeOAuthCredential? {
        if let data = readKeychain(), let cred = parse(data) { return cred }
        if let data = readFile(), let cred = parse(data) { return cred }
        return nil
    }
}

public enum ClaudeQuotaClientError: Error, Equatable {
    /// No Claude Code login found (not signed in, or keychain access denied).
    case noCredential
    /// Token rejected — expired or revoked; Claude Code refreshes it on next run.
    case unauthorized
    case rateLimited
    case http(Int)
    case transport(String)
    case parse
}

public enum ClaudeQuotaClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public static func request(token: String) -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CodeIsland", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Map an HTTP response to a snapshot or a typed error.
    public static func interpret(data: Data, response: URLResponse, now: Date = Date()) throws -> ClaudeQuotaSnapshot {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            do { return try ClaudeQuotaSnapshot.parse(data, fetchedAt: now) }
            catch { throw ClaudeQuotaClientError.parse }
        case 401, 403: throw ClaudeQuotaClientError.unauthorized
        case 429: throw ClaudeQuotaClientError.rateLimited
        default: throw ClaudeQuotaClientError.http(status)
        }
    }

    /// One fetch. The credential is re-read every call so a token Claude Code
    /// rotated in the meantime is picked up without any state here.
    public static func fetch(
        credential: @escaping @Sendable () -> ClaudeOAuthCredential? = ClaudeCredentialStore.load,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> ClaudeQuotaSnapshot {
        // Off the caller's actor: SecItemCopyMatching blocks while macOS shows
        // its keychain access prompt, and that must never stall the UI. A GCD
        // queue rather than a detached Task — the blocking call must not sit
        // on a cooperative-pool thread either.
        let loaded: ClaudeOAuthCredential? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: credential()) }
        }
        guard let cred = loaded else { throw ClaudeQuotaClientError.noCredential }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request(token: cred.accessToken))
        } catch {
            throw ClaudeQuotaClientError.transport(error.localizedDescription)
        }
        return try interpret(data: data, response: response, now: now)
    }
}
