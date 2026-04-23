//
//  WindowCLI.swift
//  VibeWindowManager
//
//  Terminal entrypoint for listing apps and applying layouts without the GUI.
//

import AppKit
import Foundation

enum WindowCLICommand: Equatable {
    case help
    case listApps
    case bridgeDump(appQuery: String)
    case layout(appQuery: String, layout: WindowCLILayout, pixel: CGFloat?)
}

enum WindowCLILayout: String, Equatable {
    case columns
    case rows
    case grid
    case cascade
    case onePlusTwo = "one-plus-two"
}

enum WindowCLIParseError: Error, LocalizedError {
    case missingLayout
    case missingAppQuery
    case unknownLayout(String)
    case missingPixelValue
    case invalidPixelValue(String)
    case unknownOption(String)

    var errorDescription: String? {
        switch self {
        case .missingLayout:
            return "Missing layout. Try `windows help`."
        case .missingAppQuery:
            return "Missing app name for bridge-dump. Example: `windows bridge-dump ghostty`."
        case .unknownLayout(let value):
            return "Unknown layout `\(value)`. Try `windows help`."
        case .missingPixelValue:
            return "Missing value for `--pixel`."
        case .invalidPixelValue(let value):
            return "Invalid pixel value `\(value)`."
        case .unknownOption(let value):
            return "Unknown option `\(value)`."
        }
    }
}

@MainActor
enum WindowCLI {
    static func shouldRun(arguments: [String] = CommandLine.arguments) -> Bool {
        let invocation = invocationContext(arguments: arguments)
        // Only the `windows` CLI symlink is always a terminal session (incl. no args => help).
        // The .app is GUI unless there are *real* CLI args after stripping Xcode/Apple flags.
        if invocation.isWindowsSymlink { return true }
        return !invocation.userArguments.isEmpty
    }

    @discardableResult
    static func run(arguments: [String] = CommandLine.arguments) -> Int32 {
        let invocation = invocationContext(arguments: arguments)

        do {
            let command = try parse(userArguments: invocation.userArguments)
            switch command {
            case .help:
                print(helpText(binaryName: invocation.helpBinaryName))
                return 0
            case .listApps:
                return listApps()
            case let .bridgeDump(appQuery):
                return bridgeDump(appQuery: appQuery)
            case let .layout(appQuery, layout, pixel):
                return applyLayout(appQuery: appQuery, layout: layout, pixel: pixel)
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n\n", stderr)
            fputs(helpText(binaryName: invocation.helpBinaryName), stderr)
            return 2
        }
    }

    static func parse(userArguments: [String]) throws -> WindowCLICommand {
        guard !userArguments.isEmpty else { return .help }

        let first = userArguments[0].lowercased()
        if ["help", "--help", "-h"].contains(first) {
            return .help
        }
        if first == "list-apps" {
            return .listApps
        }
        if first == "bridge-dump" {
            guard userArguments.count >= 2 else {
                throw WindowCLIParseError.missingAppQuery
            }
            return .bridgeDump(appQuery: userArguments[1])
        }

        guard userArguments.count >= 2 else {
            throw WindowCLIParseError.missingLayout
        }

        let appQuery = userArguments[0]
        guard let layout = WindowCLILayout(rawValue: userArguments[1].lowercased()) else {
            throw WindowCLIParseError.unknownLayout(userArguments[1])
        }

        var pixel: CGFloat?
        var index = 2
        while index < userArguments.count {
            let option = userArguments[index]
            switch option {
            case "--pixel":
                guard index + 1 < userArguments.count else {
                    throw WindowCLIParseError.missingPixelValue
                }
                let value = userArguments[index + 1]
                guard let numeric = Double(value) else {
                    throw WindowCLIParseError.invalidPixelValue(value)
                }
                pixel = CGFloat(numeric)
                index += 2
            default:
                throw WindowCLIParseError.unknownOption(option)
            }
        }

        return .layout(appQuery: appQuery, layout: layout, pixel: pixel)
    }

    // MARK: - Runtime

    private static func listApps() -> Int32 {
        let workspaceApps = runningApps()
        let service = AXWindowLayoutService()

        for app in workspaceApps {
            let name = app.localizedName ?? "Unknown"
            let bundle = app.bundleIdentifier ?? "-"
            let suffix: String

            if service.isProcessTrusted {
                let count = (try? service.windows(for: app).count) ?? 0
                suffix = "\(count) window\(count == 1 ? "" : "s")"
            } else {
                suffix = "grant Accessibility for window counts"
            }

            print("\(name) | \(bundle) | \(suffix)")
        }

        return 0
    }

    private static func bridgeDump(appQuery: String) -> Int32 {
        let service = AXWindowLayoutService()
        guard service.isProcessTrusted else {
            fputs("error: Enable VibeWindowManager in System Settings -> Privacy & Security -> Accessibility first.\n", stderr)
            return 1
        }
        let apps = runningApps()
        guard let r = AppQueryResolver.resolve(query: appQuery, in: apps) else {
            fputs("error: Could not find a running app matching `\(appQuery)`.\n", stderr)
            return 1
        }
        if r.ambiguous {
            let names = r.candidates.map { $0.localizedName ?? ($0.bundleIdentifier ?? "Unknown") }.joined(separator: ", ")
            fputs("error: `\(appQuery)` is ambiguous. Matches: \(names)\n", stderr)
            return 1
        }
        guard let app = r.app else { return 1 }
        let mirror = LayoutMirrorService()
        let ref: CGRect
        if let f = mirror.mainDisplayLayoutFrame() { ref = f }
        else {
            fputs("error: No layout frame (display?).\n", stderr)
            return 1
        }
        if ref.isEmpty {
            fputs("error: Empty reference rect.\n", stderr)
            return 1
        }
        do {
            let windows = try mirror.windows(for: app)
            if let msg = mirror.layoutMessage(
                seq: 0,
                app: app,
                ref: ref,
                windows: windows,
                selectedId: windows.first?.id
            ) {
                let e = JSONEncoder()
                e.outputFormatting = [.sortedKeys, .prettyPrinted]
                if let d = try? e.encode(msg), let s = String(data: d, encoding: .utf8) {
                    print(s)
                }
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }
        return 0
    }

    private static func applyLayout(appQuery: String, layout: WindowCLILayout, pixel: CGFloat?) -> Int32 {
        let service = AXWindowLayoutService()
        guard service.isProcessTrusted else {
            fputs("error: Enable VibeWindowManager in System Settings -> Privacy & Security -> Accessibility first.\n", stderr)
            return 1
        }

        let apps = runningApps()
        guard let match = resolveApp(query: appQuery, in: apps) else {
            fputs("error: Could not find a running app matching `\(appQuery)`.\n", stderr)
            return 1
        }

        if match.ambiguous {
            let names = match.candidates.map { $0.localizedName ?? ($0.bundleIdentifier ?? "Unknown") }.joined(separator: ", ")
            fputs("error: `\(appQuery)` is ambiguous. Matches: \(names)\n", stderr)
            return 1
        }

        guard let app = match.app else {
            fputs("error: Could not resolve app `\(appQuery)`.\n", stderr)
            return 1
        }

        let windows = (try? service.windows(for: app)) ?? []
        guard !windows.isEmpty else {
            fputs("error: No movable windows found for \(app.localizedName ?? appQuery).\n", stderr)
            return 1
        }

        guard let visibleFrame = selectedVisibleFrame() else {
            fputs("error: No usable display found.\n", stderr)
            return 1
        }

        let screens = NSScreen.screens

        do {
            switch layout {
            case .columns:
                try service.applyTile(
                    visibleFrame: visibleFrame,
                    mode: .equalColumns(windows.count),
                    to: windows.map(\.element),
                    allScreens: screens
                )
            case .rows:
                try service.applyTile(
                    visibleFrame: visibleFrame,
                    mode: .equalRows(windows.count),
                    to: windows.map(\.element),
                    allScreens: screens
                )
            case .grid:
                try service.applyTile(
                    visibleFrame: visibleFrame,
                    mode: .grid(windows.count),
                    to: windows.map(\.element),
                    allScreens: screens
                )
            case .onePlusTwo:
                try service.applyTile(
                    visibleFrame: visibleFrame,
                    mode: .onePlusTwo,
                    to: windows.map(\.element),
                    allScreens: screens
                )
            case .cascade:
                try service.applyCascade(
                    visibleFrame: visibleFrame,
                    to: windows.map(\.element),
                    allScreens: screens,
                    insetStep: pixel ?? CascadeDefaults.insetStep
                )
            }
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            return 1
        }

        print("Applied \(layout.rawValue) to \(windows.count) window\(windows.count == 1 ? "" : "s") of \(app.localizedName ?? appQuery).")
        return 0
    }

    // MARK: - Matching

    private static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private static func selectedVisibleFrame() -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let chosen = NSScreen.main ?? ScreenGeometry.menuBarScreen(from: screens) ?? screens[0]
        return ScreenGeometry.layoutFrame(for: chosen, allScreens: screens, isStageManagerEnabled: StageManagerSupport.isEnabled)
    }

    private static func resolveApp(query: String, in apps: [NSRunningApplication]) -> AppResolution? {
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
        let topScore = first.1
        let candidates = scored.filter { $0.1 == topScore }.map(\.0)
        return AppResolution(app: candidates.first, candidates: candidates, ambiguous: candidates.count > 1)
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

    // MARK: - Help

    private static func helpText(binaryName: String) -> String {
        """
        Usage:
          \(binaryName) list-apps
          \(binaryName) bridge-dump <app>
          \(binaryName) <app> columns
          \(binaryName) <app> rows
          \(binaryName) <app> grid
          \(binaryName) <app> one-plus-two
          \(binaryName) <app> cascade [--pixel 30]
          \(binaryName) help

        Examples:
          \(binaryName) list-apps
          \(binaryName) cursor cascade --pixel 30
          \(binaryName) ghostty columns
          \(binaryName) brave grid

        Notes:
          - App matching is fuzzy. `cursor`, `ghostty`, and bundle id fragments work.
          - The CLI uses the same Accessibility permission as the GUI app.
          - Layouts are applied on the current main display and respect Stage Manager spacing.
        """
    }

    private static func invocationContext(arguments: [String]) -> InvocationContext {
        let executable = URL(fileURLWithPath: arguments.first ?? "windows").lastPathComponent
        let rawUser = Array(arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
        let userArguments = filterProcessEnvironmentArguments(rawUser)
        let helpBinaryName: String
        if executable == "VibeWindowManager" {
            helpBinaryName = "windows"
        } else {
            helpBinaryName = executable
        }
        return InvocationContext(
            helpBinaryName: helpBinaryName,
            userArguments: userArguments,
            isWindowsSymlink: executable == "windows"
        )
    }

    /// Strips common Xcode / Obj‑C process arguments (e.g. `-NSShowNonLocalizedStrings` + `YES`) so
    /// they are not misinterpreted as `windows <app> <layout>`. Also strips `-XCTest` + the bundle path
    /// when the .app is used as a unit test host.
    private static func filterProcessEnvironmentArguments(_ userArguments: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < userArguments.count {
            let a = userArguments[i]
            if a.hasPrefix("-NS") {
                if i + 1 < userArguments.count, !userArguments[i + 1].hasPrefix("-") {
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            if a.caseInsensitiveCompare("-XCTest") == .orderedSame {
                if i + 1 < userArguments.count, !userArguments[i + 1].hasPrefix("-") {
                    i += 2
                } else {
                    i += 1
                }
                continue
            }
            out.append(a)
            i += 1
        }
        return out
    }
}

private struct AppResolution {
    let app: NSRunningApplication?
    let candidates: [NSRunningApplication]
    let ambiguous: Bool
}

private struct InvocationContext {
    let helpBinaryName: String
    let userArguments: [String]
    let isWindowsSymlink: Bool
}
