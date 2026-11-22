import CommonCrypto
import Foundation
import SQLite3
import Testing
@testable import VibeWindowManager

/// Covers Cursor's encrypted desktop login end to end against a scratch `state.vscdb`.
/// Every password and token here is a fixture; the real Keychain is never read.
struct CursorDesktopSessionTests {
    private static let password = "fixture-safe-storage-password"

    // MARK: Actor flow

    @Test func decryptsTheDesktopSessionAndReadsThePasswordOnlyOnce() async throws {
        let token = try jwt(subject: "auth0|user", expires: farFuture)
        let db = try Database(["cursorAuth/accessToken": try seal(token, password: Self.password),
                               "cursorAuth/stripeMembershipAuthId": "auth0|user"])
        let reads = Reads(Data(Self.password.utf8))
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == token)
        #expect(await credentials.accessToken() == token)
        #expect(await reads.log == [false])
    }

    @Test func aRotatedStoragePasswordIsReadAgain() async throws {
        let first = try jwt(subject: "auth0|user", expires: farFuture)
        let second = try jwt(subject: "auth0|user", expires: farFuture + 1)
        let db = try Database(["cursorAuth/accessToken": try seal(first, password: "old-password")])
        let reads = Reads(Data("old-password".utf8), Data("new-password".utf8))
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == first)
        try db.set("cursorAuth/accessToken", try seal(second, password: "new-password"))
        #expect(await credentials.accessToken() == second)
        #expect(await reads.log == [false, false])
    }

    @Test func aWrongPasswordIsNeitherAcceptedNorCached() async throws {
        let token = try jwt(subject: "auth0|user", expires: farFuture)
        let db = try Database(["cursorAuth/accessToken": try seal(token, password: Self.password)])
        let reads = Reads(Data("wrong-password".utf8), Data("wrong-password".utf8))
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == nil)
        #expect(await credentials.accessToken() == nil)
        #expect(await reads.log.count == 2)
    }

    @Test func anUnreadablePasswordYieldsNoToken() async throws {
        let token = try jwt(subject: "auth0|user", expires: farFuture)
        let db = try Database(["cursorAuth/accessToken": try seal(token, password: Self.password)])
        let reads = Reads()
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == nil)
        #expect(await reads.log == [false])
    }

    @Test func anExpiredDesktopSessionIsNotSentToCursor() async throws {
        let expired = try jwt(subject: "auth0|user", expires: Date().timeIntervalSince1970 - 10)
        let db = try Database(["cursorAuth/accessToken": try seal(expired, password: Self.password)])
        let reads = Reads(Data(Self.password.utf8))
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == nil)
    }

    @Test func reconnectAsksForKeychainAccessInteractively() async throws {
        let token = try jwt(subject: "auth0|user", expires: farFuture)
        let db = try Database(["cursorAuth/accessToken": try seal(token, password: Self.password)])
        let reads = Reads(Data(Self.password.utf8))
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken(allowInteraction: true) == token)
        #expect(await reads.log == [true])
    }

    @Test func anUnencryptedLegacyTokenNeverTouchesTheKeychain() async throws {
        let db = try Database(["cursorAuth/accessToken": "legacy-plain-token"])
        let reads = Reads()
        let credentials = CursorCredentials(databasePath: db.path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == "legacy-plain-token")
        #expect(await reads.log.isEmpty)
    }

    @Test func aMissingCursorInstallYieldsNoTokenAndNoKeychainRead() async {
        let reads = Reads()
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let credentials = CursorCredentials(databasePath: path, readPassword: { await reads.next($0) })
        #expect(await credentials.accessToken() == nil)
        #expect(await reads.log.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: Pure helpers

    @Test func plaintextTrimsAndRejectsEmptyOrCorruptBlobs() throws {
        let key = Data(Self.password.utf8)
        #expect(CursorDesktopToken.plaintext(stored: try seal("token\n", password: Self.password), password: key) == "token")
        #expect(CursorDesktopToken.plaintext(stored: try seal("  \n", password: Self.password), password: key) == nil)
        #expect(CursorDesktopToken.plaintext(stored: CursorDesktopToken.prefix + "not base64!", password: key) == nil)
        #expect(CursorDesktopToken.plaintext(stored: CursorDesktopToken.prefix + Data("v10short".utf8).base64EncodedString(), password: key) == nil)
        #expect(CursorDesktopToken.plaintext(stored: try seal("token", password: Self.password), password: Data()) == nil)
    }

    @Test func desktopTokenValidation() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(CursorCredentials.usableDesktopToken(try jwt(subject: "auth0|user", expires: nil), account: "auth0|user", now: now))
        #expect(CursorCredentials.usableDesktopToken(try jwt(subject: "auth0|user", expires: 5_000), account: nil, now: now))
        #expect(CursorCredentials.usableDesktopToken(try jwt(subject: "auth0|user", expires: 5_000), account: "", now: now))
        #expect(!CursorCredentials.usableDesktopToken(try jwt(subject: "", expires: 5_000), account: nil, now: now))
        #expect(!CursorCredentials.usableDesktopToken(try jwt(subject: nil, expires: 5_000), account: nil, now: now))
        #expect(!CursorCredentials.usableDesktopToken("not-a-jwt", account: nil, now: now))
    }

    @Test func everyKeychainStateHasAnActionableMessage() {
        let stored = CursorDesktopToken.prefix + "ciphertext"
        func message(_ state: ClaudeKeychain.Access, blocked: Bool = false) -> String {
            CursorCredentials.loginFailureMessage(storedToken: stored, safeStorage: state, safeStorageBlocked: blocked)
        }
        #expect(message(.locked).contains("Keychain is locked"))
        #expect(message(.missing).contains("sign in again"))
        #expect(message(.unavailable).contains("Reconnect Cursor"))
        #expect(message(.ready("Cursor Key")).contains("Open Cursor"))
        #expect(CursorCredentials.loginFailureMessage(storedToken: "plain", safeStorage: .ready("Cursor Key"),
                                                      safeStorageBlocked: false).contains("Cursor Agent"))
    }

    @Test func onlyReconnectMayPromptForTheStoragePassword() {
        #expect(!CursorCredentials.canReadSafeStorage(.locked, allowInteraction: false, blocked: false))
        #expect(CursorCredentials.canReadSafeStorage(.locked, allowInteraction: true, blocked: false))
        #expect(!CursorCredentials.canReadSafeStorage(.unavailable, allowInteraction: true, blocked: false))
        #expect(CursorCredentials.canReadSafeStorage(.ready("Cursor Key"), allowInteraction: true, blocked: true))
    }

    @Test func withoutATokenErrorTheCLIGuidanceRemains() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { nil }, tokenError: { nil }) { _ in
            Issue.record("A missing credential must not trigger a network request")
            throw URLError(.badURL)
        }
        #expect(result.error?.contains("Cursor Agent") == true)
    }

    // MARK: Fixtures

    private var farFuture: Double { Date().timeIntervalSince1970 + 86_400 }

    private func jwt(subject: String?, expires: Double?) throws -> String {
        var claims: [String: Any] = [:]
        if let subject { claims["sub"] = subject }
        if let expires { claims["exp"] = expires }
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0." + payload + ".sig"
    }

    /// Electron safeStorage as Cursor writes it: prefix + base64("v10" + AES-128-CBC).
    private func seal(_ plaintext: String, password: String) throws -> String {
        let key = try #require(ClaudeDesktopSession.derivedKey(Data(password.utf8)))
        let plain = Array(plaintext.utf8)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, plain, plain.count, &output, output.count, &moved)
        try #require(status == kCCSuccess)
        var blob = Data("v10".utf8)
        blob.append(contentsOf: output.prefix(moved))
        return CursorDesktopToken.prefix + blob.base64EncodedString()
    }
}

/// Hands out queued passwords (nil once empty) and records whether each read could prompt.
private actor Reads {
    private var queue: [Data]
    private(set) var log: [Bool] = []
    init(_ keys: Data...) { queue = keys }
    func next(_ allowInteraction: Bool) -> Data? {
        log.append(allowInteraction)
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// A throwaway `state.vscdb` with Cursor's ItemTable layout, removed when the test ends.
private final class Database {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vscdb").path

    init(_ values: [String: String]) throws {
        try exec("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        for (key, value) in values { try set(key, value) }
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func set(_ key: String, _ value: String) throws {
        try exec("INSERT INTO ItemTable VALUES ('\(key)', '\(value)')")
    }

    private func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}
