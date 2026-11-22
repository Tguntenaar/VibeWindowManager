import CommonCrypto
import Foundation
import Testing
@testable import VibeWindowManager

private final class DashboardClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 2_000_000_000)
    nonisolated func now() -> Date { lock.withLock { value } }
    nonisolated func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}

private actor DashboardCalls {
    private(set) var count = 0
    func hit() { count += 1 }
}

struct CursorDashboardTests {
    nonisolated private func request(_ method: String = "GetCurrentPeriodUsage", token: String = "test") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/" + method)!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func encryptedTokenNeverReachesTransport() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "cursor-safe-storage:v1:encrypted" }) { _ in
            Issue.record("Encrypted storage is not an access token")
            throw URLError(.badURL)
        }
        #expect(result.windows.isEmpty)
        #expect(result.error?.contains("encrypted") == true)
    }

    @Test func automaticCursorReadsNeverPromptAndReconnectCanRecoverFromDenial() {
        for state in [ClaudeKeychain.Access.locked, .approvalRequired, .missing, .unavailable, .ready("other")] {
            #expect(!CursorCredentials.canReadCLIKeychain(state, allowInteraction: false, blocked: false))
        }
        #expect(CursorCredentials.canReadCLIKeychain(.ready("cursor-user"), allowInteraction: false, blocked: false))
        #expect(!CursorCredentials.canReadCLIKeychain(.ready("cursor-user"), allowInteraction: false, blocked: true))
        for state in [ClaudeKeychain.Access.locked, .approvalRequired, .ready("cursor-user")] {
            #expect(CursorCredentials.canReadCLIKeychain(state, allowInteraction: true, blocked: true))
        }
        for state in [ClaudeKeychain.Access.missing, .unavailable, .ready("other")] {
            #expect(!CursorCredentials.canReadCLIKeychain(state, allowInteraction: true, blocked: true))
        }
    }

    @Test func cliTokenMustBeUnexpiredAndMatchTheDesktopAccount() throws {
        func token(_ subject: String, _ expires: Double) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expires])
            return "test." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".test"
        }
        let now = Date(timeIntervalSince1970: 1000)
        #expect(CursorCredentials.validCLIToken(try token("account", 2000), account: "account", now: now))
        #expect(!CursorCredentials.validCLIToken(try token("other", 2000), account: "account", now: now))
        #expect(!CursorCredentials.validCLIToken(try token("account", 1060), account: "account", now: now))
        #expect(!CursorCredentials.validCLIToken("cursor-safe-storage:v1:ciphertext", account: "account", now: now))
    }

    @Test func cacheCoalescesConcurrentRequestsAndExpiresAfterFiveMinutes() async throws {
        let calls = DashboardCalls(), clock = DashboardClock()
        let client = CursorDashboardClient(now: { clock.now() }) { request in
            await calls.hit()
            try await Task.sleep(for: .milliseconds(30))
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        async let one = client.data(for: request())
        async let two = client.data(for: request())
        _ = try await (one, two)
        _ = try await client.data(for: request())
        #expect(await calls.count == 1)
        clock.advance(300)
        _ = try await client.data(for: request())
        #expect(await calls.count == 2)
        _ = try await client.data(for: request(token: "different-account"))
        #expect(await calls.count == 3)
    }

    @Test func rateLimitAppliesAcrossMethodsAndSurvivesRestart() async throws {
        let calls = DashboardCalls(), clock = DashboardClock()
        let suite = "CursorDashboardTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport: CursorDashboardClient.Transport = { request in
            await calls.hit()
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "1800"])!)
        }
        let client = CursorDashboardClient(defaults: defaults, now: { clock.now() }, transport: transport)
        _ = try await client.data(for: request())
        _ = try await client.data(for: request("GetSandUsageStatus"))
        #expect(await calls.count == 1)
        clock.advance(1799)
        let restarted = CursorDashboardClient(defaults: defaults, now: { clock.now() }, transport: transport)
        _ = try await restarted.data(for: request("GetPlanInfo"))
        #expect(await calls.count == 1)
        clock.advance(1)
        _ = try await restarted.data(for: request("GetPlanInfo"))
        #expect(await calls.count == 2)
        #expect((defaults.object(forKey: CursorDashboardClient.cooldownKey) as? Date)?.timeIntervalSince(clock.now()) == 1800)
    }

    @Test func encryptedDesktopSessionDecryptsWithTheSafeStoragePassword() throws {
        let jwt = try jwt(subject: "github|user", expires: 2_000)
        let stored = try seal(jwt, password: "cursor-safe-storage-password")
        let token = CursorDesktopToken.plaintext(stored: stored, password: Data("cursor-safe-storage-password".utf8))
        #expect(token == jwt)
        #expect(CursorDesktopToken.plaintext(stored: stored, password: Data("wrong-password".utf8)) == nil)
        #expect(CursorDesktopToken.plaintext(stored: "plain-token", password: Data("cursor-safe-storage-password".utf8)) == nil)
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(CursorCredentials.usableDesktopToken(jwt, account: "github|user", now: now))
        #expect(!CursorCredentials.usableDesktopToken(jwt, account: "other-account", now: now))
        #expect(!CursorCredentials.usableDesktopToken(try self.jwt(subject: "github|user", expires: 1_050), account: "github|user", now: now))
    }

    @Test func encryptedLoginTellsTheUserToReconnectInsteadOfTheCLI() {
        let stored = "cursor-safe-storage:v1:ciphertext"
        let message = CursorCredentials.loginFailureMessage(storedToken: stored, safeStorage: .approvalRequired, safeStorageBlocked: false)
        #expect(message == "Cursor’s sign-in is encrypted. Choose Reconnect Cursor to allow Keychain access.")
        #expect(CursorCredentials.loginFailureMessage(storedToken: stored, safeStorage: .ready("Cursor"), safeStorageBlocked: true) == message)
        #expect(CursorCredentials.loginFailureMessage(storedToken: nil, safeStorage: .missing, safeStorageBlocked: false).contains("Cursor Agent"))
        #expect(!CursorCredentials.canReadSafeStorage(.approvalRequired, allowInteraction: false, blocked: false))
        #expect(CursorCredentials.canReadSafeStorage(.approvalRequired, allowInteraction: true, blocked: true))
        #expect(CursorCredentials.canReadSafeStorage(.ready("Cursor"), allowInteraction: false, blocked: false))
        #expect(!CursorCredentials.canReadSafeStorage(.ready("Cursor"), allowInteraction: false, blocked: true))
        #expect(!CursorCredentials.canReadSafeStorage(.missing, allowInteraction: true, blocked: false))
    }

    @Test func tokenErrorReplacesTheCLIMessageWhenSupplied() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { nil }, tokenError: {
            "Cursor’s sign-in is encrypted. Choose Reconnect Cursor to allow Keychain access."
        }) { _ in
            Issue.record("A missing credential must not trigger a network request")
            throw URLError(.badURL)
        }
        #expect(result.error == "Cursor’s sign-in is encrypted. Choose Reconnect Cursor to allow Keychain access.")
    }

    private func jwt(subject: String, expires: Double) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expires])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0." + payload + ".sig"
    }

    private func seal(_ plaintext: String, password: String) throws -> String {
        let key = try #require(ClaudeDesktopSession.derivedKey(Data(password.utf8)))
        let plain = Array(plaintext.utf8)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, plain, plain.count, &output, output.count, &moved)
        #expect(status == kCCSuccess)
        var blob = Data("v10".utf8)
        blob.append(contentsOf: output.prefix(moved))
        return CursorDesktopToken.prefix + blob.base64EncodedString()
    }

    @Test func networkFailuresAreAlsoThrottled() async {
        let calls = DashboardCalls()
        let client = CursorDashboardClient { _ in
            await calls.hit()
            throw URLError(.notConnectedToInternet)
        }
        _ = try? await client.data(for: request())
        _ = try? await client.data(for: request())
        #expect(await calls.count == 1)
    }
}

@MainActor
struct GrokBotUsageTests {
    @Test func weeklyAllowanceIsSeparateFromCursorPools() {
        let result = GrokBotUsageFetcher.parse(["usagePercent": 1.087989,
            "nextResetTimestampUtc": "2026-10-29T13:01:50.943Z", "grokPlanLabel": "Grok Bot Plan"])
        #expect(result.provider == .grokBot)
        #expect(result.windows.map(\.label) == ["Weekly"])
        #expect(result.windows.first?.usedPercent == 1.087989)
        #expect(result.windows.first?.resetsAt == Date(timeIntervalSince1970: 1793278910.943))
        #expect(result.errorMessage == nil)
    }

    @Test func unifiedPlansExplicitlyIdentifySharedAllowance() {
        let result = GrokBotUsageFetcher.parse(["usagePercent": 25, "isUnified": true, "cursorPlanName": "Pro"])
        #expect(result.windows.map(\.label) == ["Weekly · shared"])
        #expect(result.planName == "Pro")
    }

    @Test func absentMalformedAndPooledAllowancesAreNotInvented() {
        for json in [[:], ["usagePercent": true], ["usagePercent": Double.nan],
                     ["usagePercent": 20, "usesPooledEnterpriseAllowance": true]] as [[String: Any]] {
            #expect(GrokBotUsageFetcher.parse(json).windows.isEmpty)
        }
    }

    @Test(arguments: [2, 3, 99])
    func cacheIsScopedToActiveAccountAndRejectsExpiredOrResetReadings(schema: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ key: String, _ value: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(GrokBotUsageCache.filename(key)))
        }
        let now = Date(timeIntervalSince1970: 2000)
        let accountKey = "sand.client.slice.account.github%7Ctest.weekly-usage.cache"
        try write("sand.client.slice.client-meta.account-slot", ["schemaVersion": 1, "value": "github|test"])
        func snapshot(readAt: Double = 1999000, reset: Double = 3000000, expires: Double = 4000000, team: Any = NSNull()) -> [String: Any] {
            ["schemaVersion": schema, "value": ["kind": "present", "selectedTeamId": team,
                "reading": ["readAtMs": readAt, "usage": ["percentUsed": 12, "nextResetMs": reset]], "expiresAtMs": expires]]
        }
        try write(accountKey, snapshot())
        let context = GrokBotUsageCache.load(root: root, now: now)
        #expect(context.account == "github|test")
        if schema == 99 {
            #expect(context.usage == nil)
            #expect(!context.personalAccount)
            return
        }
        #expect(context.personalAccount)
        #expect(context.usage?.windows.first?.usedPercent == 12)
        #expect(context.usage?.sourceNote == "From Grok Bot")
        #expect(context.usage?.fetchedAt == Date(timeIntervalSince1970: 1999))
        try write(accountKey, snapshot(team: 123))
        #expect(!GrokBotUsageCache.load(root: root, now: now).personalAccount)
        try write(accountKey, snapshot(expires: 1999000))
        #expect(GrokBotUsageCache.load(root: root, now: now).usage == nil)
        try write(accountKey, snapshot(reset: 1999000))
        #expect(GrokBotUsageCache.load(root: root, now: now).usage == nil)
        try write(accountKey, snapshot(readAt: 2200000))
        #expect(GrokBotUsageCache.load(root: root, now: now).usage == nil)
        try write(accountKey, snapshot())
        try write("sand.client.slice.client-meta.account-slot", ["schemaVersion": 1, "value": "other"])
        #expect(GrokBotUsageCache.load(root: root, now: now).usage == nil)
    }

    @Test func grokResultReachesItsOwnServiceCard() async {
        struct Fetcher: UsageFetching {
            func fetch() async -> ProviderUsage { GrokBotUsageFetcher.parse(["usagePercent": 12]) }
        }
        let service = UsageLimitsService(fetchers: [.grokBot: Fetcher()])
        service.refresh()
        for _ in 0..<100 where service.isRefreshing { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(service.grokBot?.windows.first?.usedPercent == 12)
        #expect(service.usage(for: .grokBot) == service.grokBot)
        #expect(service.cursor == nil)
    }
}
