//
//  AppQueryResolver.swift
//  VibeWindowManager
//
//  Shared fuzzy app matching (mirrors WindowCLI heuristics for bridge/CLI use).
//

import AppKit
import Foundation

struct AppQueryResolution: Sendable {
    let app: NSRunningApplication?
    let candidates: [NSRunningApplication]
    let ambiguous: Bool
}

enum AppQueryResolver {
    /// Short token for fuzzy `resolve` and bridge UI; same rules as the Mac "Mirror app" icon row.
    static func bridgeQueryToken(for app: NSRunningApplication) -> String {
        if let bid = app.bundleIdentifier {
            let parts = bid.split(separator: ".")
            if let last = parts.last, !last.isEmpty {
                return String(last)
            }
        }
        return (app.localizedName ?? "app")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
    }

    static func runningRegularApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    static func resolve(query: String, in apps: [NSRunningApplication]) -> AppQueryResolution? {
        let scored = apps.compactMap { app -> (NSRunningApplication, Int)? in
            guard let score = matchScore(query: query, app: app) else { return nil }
            return (app, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return (lhs.0.localizedName ?? "") < (rhs.0.localizedName ?? "")
            }
            return lhs.1 > rhs.1
        }
        guard let first = scored.first else { return nil }
        let top = first.1
        let cands = scored.filter { $0.1 == top }.map(\.0)
        return AppQueryResolution(app: cands.first, candidates: cands, ambiguous: cands.count > 1)
    }

    private static func matchScore(query: String, app: NSRunningApplication) -> Int? {
        let q = normalized(query)
        let name = normalized(app.localizedName ?? "")
        let bundle = normalized(app.bundleIdentifier ?? "")
        if q.isEmpty { return nil }
        if q == name { return 500 }
        if q == bundle { return 490 }
        if bundle.hasSuffix(".\(q)") { return 480 }
        if name.hasPrefix(q) { return 400 }
        if bundle.hasPrefix(q) { return 390 }
        if name.contains(q) { return 300 }
        if bundle.contains(q) { return 290 }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
