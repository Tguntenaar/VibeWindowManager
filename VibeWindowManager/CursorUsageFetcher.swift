import Foundation
import CoreFoundation
import SQLite3

/// Uses the same read-only DashboardService calls as Cursor's usage panel.
/// Cursor owns login and token refresh. Never logs or copies credentials to disk.
struct CursorUsageFetcher: UsageFetching {
    func fetch() async -> ProviderUsage {
        let snapshot = await CursorUsageEngine.fetch(
            tokenLookup: { await CursorCredentials.shared.accessToken() },
            tokenError: {
                let stored = CursorUsageEngine.accessToken(databasePath: CursorCredentials.databasePath)
                let access = ClaudeKeychain.access(service: CursorDesktopToken.safeStorageService)
                let blocked = UserDefaults.standard.bool(forKey: CursorCredentials.safeStorageBlockedKey)
                return CursorCredentials.loginFailureMessage(storedToken: stored, safeStorage: access,
                                                             safeStorageBlocked: blocked)
            }
        )
        return ProviderUsage(provider: .cursor, planName: snapshot.planName,
            windows: snapshot.windows.map {
                UsageWindow(label: $0.label, usedPercent: $0.percent, resetsAt: $0.reset)
            }, fetchedAt: Date(), errorMessage: snapshot.error)
    }
}

nonisolated enum CursorUsageEngine {
    struct Window: Sendable {
        let label: String
        let percent: Double
        let reset: Date?
    }
    struct Snapshot: Sendable {
        var planName: String?
        var windows: [Window] = []
        var error: String?
    }
    enum FetchError: Error { case status(Int), invalidResponse }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    @concurrent static func fetch(
        tokenLookup: @Sendable () async -> String? = { await CursorCredentials.shared.accessToken() },
        tokenError: @Sendable () async -> String? = { nil },
        transport: @escaping Transport = { try await CursorDashboardClient.shared.data(for: $0) }
    ) async -> Snapshot {
        guard !Task.isCancelled else {
            return Snapshot(error: "Cursor usage refresh was cancelled.")
        }
        guard let token = await tokenLookup(), !token.isEmpty else {
            let fallback = "Cursor usage needs a readable login. Sign in to Cursor Agent (the CLI), then choose Reconnect Cursor here. Opening the desktop app alone does not connect usage."
            return Snapshot(error: await tokenError() ?? fallback)
        }
        guard !token.hasPrefix("cursor-safe-storage:") else {
            return Snapshot(error: "Cursor’s saved login is encrypted. Sign in to Cursor Agent to connect usage.")
        }
        do {
            async let usage = request("GetCurrentPeriodUsage", token: token, transport: transport)
            // A plan-label failure must not hide valid limits.
            async let info = try? request("GetPlanInfo", token: token, transport: transport)
            let usageJSON = try await usage
            let infoJSON = await info ?? [:]
            try Task.checkCancellation()
            return parse(usageJSON, info: infoJSON)
        } catch is CancellationError {
            return Snapshot(error: "Cursor usage refresh was cancelled.")
        } catch FetchError.status(let status) {
            switch status {
            case 401, 403: return Snapshot(error: "Cursor rejected the usage login. Reconnect Cursor Agent.")
            case 429: return Snapshot(error: "Cursor usage is rate-limited — try again in a few minutes.")
            default: return Snapshot(error: "Cursor usage request failed (HTTP \(status)).")
            }
        } catch {
            return Snapshot(error: "Couldn't load Cursor usage. Open Cursor and try refreshing.")
        }
    }

    static func accessToken(databasePath: String) -> String? {
        databaseValue("cursorAuth/accessToken", databasePath: databasePath)
    }

    static func databaseValue(_ key: String, databasePath: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database,
            "SELECT value FROM ItemTable WHERE key = ? LIMIT 1",
            -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: bytes)
    }

    static func request(_ method: String, token: String, transport: Transport) async throws -> [String: Any] {
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/\(method)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        try Task.checkCancellation()
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw FetchError.status(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.invalidResponse
        }
        return json
    }

    static func parse(_ json: [String: Any], info: [String: Any] = [:]) -> Snapshot {
        let planInfo = info["planInfo"] as? [String: Any] ?? [:]
        var result = Snapshot(planName: planInfo["planName"] as? String)
        let reset = date(planInfo["includedUsageResetsAt"]) ?? date(json["billingCycleEnd"])
        if let plan = json["planUsage"] as? [String: Any] {
            // The current API exposes separate Auto and API pools. These percentages
            // take precedence over the legacy dollar allowance (which can exceed 100%).
            for (key, label) in [("autoPercentUsed", "Auto"), ("apiPercentUsed", "API")] {
                if let percent = number(plan[key]) {
                    result.windows.append(Window(label: label, percent: clamped(percent), reset: reset))
                }
            }
            if result.windows.isEmpty {
                let label = (planInfo["includedUsagePeriod"] as? String) == "INCLUDED_USAGE_PERIOD_WEEKLY"
                    ? "Weekly" : "Plan"
                if let percent = number(plan["totalPercentUsed"]) {
                    result.windows.append(Window(label: label, percent: clamped(percent), reset: reset))
                } else if let limit = number(plan["limit"]), limit > 0 {
                    if let used = plan["includedSpend"] == nil ? 0 : number(plan["includedSpend"]) {
                        result.windows.append(Window(label: label, percent: clamped(used / limit * 100), reset: reset))
                    }
                }
            }
        }
        if let spend = json["spendLimitUsage"] as? [String: Any],
           let limit = number(spend["individualLimit"]), limit > 0,
           let used = spend["individualUsed"] == nil ? 0 : number(spend["individualUsed"]) {
            result.windows.append(Window(label: "On-demand", percent: clamped(used / limit * 100),
                reset: date(json["billingCycleEnd"])))
        }
        if result.windows.isEmpty { result.error = "No usage limits reported by Cursor for this account." }
        return result
    }

    private static func clamped(_ value: Double) -> Double { min(100, max(0, value)) }
    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let string = value as? String { number = Double(string) }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            number = value.doubleValue
        } else { number = nil }
        guard let number, number.isFinite else { return nil }
        return number
    }
    private static func date(_ value: Any?) -> Date? {
        guard let milliseconds = number(value), milliseconds > 0 else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
