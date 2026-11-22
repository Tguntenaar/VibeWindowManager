import Foundation

/// Cursor 3.31+ stores the desktop login as Electron safe storage (`cursor-safe-storage:v1:`).
/// That blob is the same `v10` AES scheme as Claude's desktop sign-in, keyed by the login
/// Keychain item "Cursor Safe Storage". Read it; fall back to the CLI token only when the
/// desktop session cannot be decrypted. Never write either store.
actor CursorCredentials {
    static let shared = CursorCredentials()
    nonisolated static let safeStorageBlockedKey = "cursorUsage.safeStorageAccessBlocked"
    private var pending: Task<String?, Never>?
    private var pendingID: UUID?
    private var safeStoragePassword: Data?
    private let databasePath: String
    private let readPassword: @Sendable (Bool) async -> Data?

    /// Tests inject a scratch database and a password reader; the app uses Cursor's own store.
    init(databasePath: String = CursorCredentials.databasePath,
         readPassword: @escaping @Sendable (Bool) async -> Data? = { await CursorCredentials.readSafeStoragePassword(allowInteraction: $0) }) {
        self.databasePath = databasePath
        self.readPassword = readPassword
    }

    func accessToken(allowInteraction: Bool = false) async -> String? {
        if let pending {
            let token = await pending.value
            if !allowInteraction { return token }
        }
        let id = UUID()
        let task = Task { await self.load(allowInteraction: allowInteraction) }
        pendingID = id
        pending = task
        let token = await task.value
        if pendingID == id {
            pending = nil
            pendingID = nil
        }
        return token
    }

    nonisolated static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path

    private func load(allowInteraction: Bool) async -> String? {
        let path = databasePath
        guard let desktop = CursorUsageEngine.accessToken(databasePath: path), !desktop.isEmpty else { return nil }
        if !desktop.hasPrefix(CursorDesktopToken.prefix) { return desktop }
        if let token = await desktopSession(desktop, allowInteraction: allowInteraction) { return token }
        guard let account = CursorUsageEngine.databaseValue("cursorAuth/stripeMembershipAuthId", databasePath: path) else { return nil }
        let state = ClaudeKeychain.access(service: "cursor-access-token")
        guard Self.canReadCLIKeychain(state, allowInteraction: allowInteraction,
            blocked: UserDefaults.standard.bool(forKey: "cursorUsage.keychainAccessBlocked")) else { return nil }
        // Automatic polling stays silent. Only the main window's Reconnect button may prompt.
        // Claude's paused-credential flag and credential item are never touched here.
        let result = await ClaudeKeychain.run(["find-generic-password", "-w", "-s", "cursor-access-token", "-a", "cursor-user"], timeout: allowInteraction ? nil : 10)
        guard result.status == 0, let data = result.data, let token = String(data: data, encoding: .utf8) else {
            UserDefaults.standard.set(true, forKey: "cursorUsage.keychainAccessBlocked")
            return nil
        }
        guard Self.validCLIToken(token, account: account, now: Date()) else { return nil }
        UserDefaults.standard.removeObject(forKey: "cursorUsage.keychainAccessBlocked")
        return token
    }

    /// The desktop session wins. A stale in-memory storage password is dropped and read once more.
    private func desktopSession(_ stored: String, allowInteraction: Bool) async -> String? {
        let account = CursorUsageEngine.databaseValue("cursorAuth/stripeMembershipAuthId", databasePath: databasePath)
        let now = Date()
        if let safeStoragePassword,
           let token = CursorDesktopToken.plaintext(stored: stored, password: safeStoragePassword),
           Self.usableDesktopToken(token, account: account, now: now) {
            return token
        }
        safeStoragePassword = nil
        guard let password = await readPassword(allowInteraction),
              let token = CursorDesktopToken.plaintext(stored: stored, password: password),
              Self.usableDesktopToken(token, account: account, now: now) else { return nil }
        safeStoragePassword = password
        return token
    }

    static func readSafeStoragePassword(allowInteraction: Bool) async -> Data? {
        let state = ClaudeKeychain.access(service: CursorDesktopToken.safeStorageService)
        let blocked = UserDefaults.standard.bool(forKey: safeStorageBlockedKey)
        guard canReadSafeStorage(state, allowInteraction: allowInteraction, blocked: blocked) else { return nil }
        var arguments = ["find-generic-password", "-w", "-s", CursorDesktopToken.safeStorageService]
        if case .ready(let account) = state { arguments += ["-a", account] }
        let result = await ClaudeKeychain.run(arguments, timeout: allowInteraction ? nil : 10)
        guard result.status == 0, let data = result.data, !data.isEmpty else {
            UserDefaults.standard.set(true, forKey: safeStorageBlockedKey)
            return nil
        }
        UserDefaults.standard.removeObject(forKey: safeStorageBlockedKey)
        return data
    }

    /// Shown when neither the encrypted desktop session nor the CLI token can be used.
    nonisolated static func loginFailureMessage(storedToken: String?, safeStorage: ClaudeKeychain.Access,
                                                 safeStorageBlocked: Bool) -> String {
        guard storedToken?.hasPrefix(CursorDesktopToken.prefix) == true else {
            return "Cursor usage needs a readable login. Sign in to Cursor Agent (the CLI), then choose Reconnect Cursor here. Opening the desktop app alone does not connect usage."
        }
        switch safeStorage {
        case .locked:
            return "Keychain is locked. Unlock it to read Cursor usage."
        case .missing:
            return "Cursor’s sign-in key is missing. Open Cursor and sign in again."
        case .approvalRequired, .unavailable:
            return "Cursor’s sign-in is encrypted. Choose Reconnect Cursor to allow Keychain access."
        case .ready where safeStorageBlocked:
            return "Cursor’s sign-in is encrypted. Choose Reconnect Cursor to allow Keychain access."
        case .ready:
            return "Open Cursor so it can refresh its sign-in, then choose Reconnect Cursor."
        }
    }

    nonisolated static func canReadSafeStorage(_ state: ClaudeKeychain.Access, allowInteraction: Bool, blocked: Bool) -> Bool {
        switch state {
        case .ready: return allowInteraction || !blocked
        case .locked, .approvalRequired: return allowInteraction
        case .missing, .unavailable: return false
        }
    }

    nonisolated static func usableDesktopToken(_ token: String, account: String?, now: Date) -> Bool {
        guard let claims = claims(token), let subject = claims["sub"] as? String, !subject.isEmpty else { return false }
        if let account, !account.isEmpty, subject != account { return false }
        if let expiration = claims["exp"] as? Double, expiration.isFinite {
            return expiration > now.timeIntervalSince1970 + 60
        }
        return true
    }

    nonisolated static func canReadCLIKeychain(_ state: ClaudeKeychain.Access,
        allowInteraction: Bool, blocked: Bool) -> Bool {
        switch state {
        case .ready(let account): return account == "cursor-user" && (allowInteraction || !blocked)
        case .locked, .approvalRequired: return allowInteraction
        case .missing, .unavailable: return false
        }
    }

    nonisolated static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func validCLIToken(_ token: String, account: String, now: Date) -> Bool {
        guard !account.isEmpty, let claims = claims(token), claims["sub"] as? String == account,
              let expiration = claims["exp"] as? Double, expiration.isFinite,
              expiration > now.timeIntervalSince1970 + 60 else { return false }
        return true
    }
}

/// Electron safe storage blob written by Cursor into `state.vscdb`.
nonisolated enum CursorDesktopToken {
    static let prefix = "cursor-safe-storage:v1:"
    static let safeStorageService = "Cursor Safe Storage"

    static func plaintext(stored: String, password: Data) -> String? {
        guard stored.hasPrefix(prefix) else { return nil }
        guard let data = ClaudeDesktopSession.decrypt(String(stored.dropFirst(prefix.count)), password: password),
              let token = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
