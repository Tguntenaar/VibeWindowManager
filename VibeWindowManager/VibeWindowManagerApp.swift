//
//  VibeWindowManagerApp.swift
//  VibeWindowManager
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import AppKit
import Darwin
import SwiftUI

private enum MainWindowID: String {
    case main = "vibe-main-window"
}

@main
struct VibeWindowManagerApp: App {
    @StateObject private var bridge = VibeBridgeServer()
    init() {
        if Self.isTestHostProcess { return }
        if WindowCLI.shouldRun(arguments: CommandLine.arguments) {
            let exitCode = WindowCLI.run(arguments: CommandLine.arguments)
            Darwin.exit(exitCode)
        }
        // `UserDefaults.bool(forKey:)` is false when the key is **missing**; SwiftUI @AppStorage default
        // true does not write the key, so STT would read OpenAI-pip as off. Register defaults for reads
        // that match the UI (see debug session e5d455, H5).
        UserDefaults.standard.register(defaults: [
            "vibeWhisperOpenAIPip": true,
            VibeAppPersistence.bridgeServerEnabledKey: true,
        ])
        // The menu bar extra lists live localhost servers even when the main window was never
        // opened, so the scanner is owned by the app rather than started from a view's lifecycle.
        LocalServerScanService.shared.startAutoRefresh()
    }

    /// True when the app is a unit test host (Swift Testing / XCTest) — not a terminal `windows` invocation.
    private static var isTestHostProcess: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return CommandLine.arguments.contains { $0.caseInsensitiveCompare("-XCTest") == .orderedSame }
    }

    var body: some Scene {
        WindowGroup(id: MainWindowID.main.rawValue) {
            ContentView()
                .environmentObject(bridge)
        }
        .commands {
            CommandMenu("Quick layout") {
                Button("Cascade Cursor (extra display…)") {
                    VibeMenuBarActions.cascadeCursorOnExtraOrMainDisplay()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Vibe", image: "MenuBarExtraIcon") {
            MenuBarExtraCommands(mainWindowID: MainWindowID.main.rawValue)
                .environmentObject(bridge)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private enum VibeMenuBarActions {
    static func cascadeCursorOnExtraOrMainDisplay() {
        if let message = WindowCLI.applyCascadeForAppOnExtraOrMainScreen(appQuery: "cursor") {
            let alert = NSAlert()
            alert.messageText = "Couldn’t cascade Cursor"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Modal confirmation for a destructive signal. Returns true when the user went through with it.
    static func confirmKill(_ server: LocalServerProcess, force: Bool, uptime: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = force
            ? "Force kill “\(server.displayName)”?"
            : "Quit “\(server.displayName)”?"
        alert.informativeText = """
            \(VibeServerMenuFormat.portsSentence(server)) · pid \(server.pid) · up \(uptime)

            \(force
                ? "SIGKILL cannot be caught — the process dies immediately and will not save state or clean up."
                : "SIGTERM asks the process to shut down cleanly.")
            """
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: force ? "Force Kill" : "Quit Process")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyCommand(_ server: LocalServerProcess) {
        let command = server.commandLine.isEmpty ? server.command : server.commandLine
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    static func isLikelyHTTPPort(_ port: Int) -> Bool {
        LocalServerProcess.isLikelyHTTPPort(port)
    }
}

/// Pure label formatting for the menu-bar server entries.
///
/// Everything here returns a plain `String` on purpose: `Menu`/`Button`/`Text` take a
/// `LocalizedStringKey`, which number-formats an interpolated `Int` for the user's locale — port 5000
/// would render as “:5.000” in nl_NL. Swift string interpolation never does that, and passing a
/// `String` picks the verbatim `StringProtocol` overloads of those initialisers.
private enum VibeServerMenuFormat {
    /// `:8787`, or `:80 +11` when the process listens on more ports than the primary one.
    static func portBadge(_ server: LocalServerProcess) -> String {
        let extra = max(server.ports.count - 1, 0)
        return extra > 0 ? ":\(server.primaryPort) +\(extra)" : ":\(server.primaryPort)"
    }

    /// `:8787 — sayso_bridge · Dev server · sayso · 5d 1h · 30 MB`
    static func entryTitle(_ server: LocalServerProcess, uptime: String) -> String {
        var parts = [portBadge(server), "— \(server.displayName)"]
        let subtitle = server.subtitle
        if !subtitle.isEmpty { parts.append("· \(subtitle)") }
        if !uptime.isEmpty { parts.append("· \(uptime)") }
        if server.residentBytes != nil { parts.append("· \(server.memoryText)") }
        return parts.joined(separator: " ")
    }

    /// `80, 443, 8080` — all ports of the process, for the multi-port detail row.
    static func portList(_ server: LocalServerProcess) -> String {
        server.ports.map { "\($0)" }.joined(separator: ", ")
    }

    /// `Port 8787` / `Ports 80, 443` — used inside the kill confirmation.
    static func portsSentence(_ server: LocalServerProcess) -> String {
        server.ports.count > 1 ? "Ports \(portList(server))" : "Port \(server.primaryPort)"
    }
}

private struct MenuBarExtraCommands: View {
    let mainWindowID: String

    @EnvironmentObject private var bridge: VibeBridgeServer
    @ObservedObject private var servers = LocalServerScanService.shared
    @Environment(\.openWindow) private var openWindow

    /// Scratch → dev servers → dev tooling, each tier by uptime descending. Already ranked by the
    /// service, so the menu body only formats.
    private var rankedServers: [LocalServerProcess] { servers.ranked }

    /// Apps, macOS services and this app itself — tucked into a nested submenu at the bottom.
    private var backgroundServers: [LocalServerProcess] { servers.background }

    var body: some View {
        Button("Show Window") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: mainWindowID)
        }

        Toggle("iOS bridge server", isOn: Binding(
            get: { bridge.isRunning },
            set: { on in
                UserDefaults.standard.set(on, forKey: VibeAppPersistence.bridgeServerEnabledKey)
                if on { bridge.start() } else { bridge.stop() }
            }
        ))

        Button("Cascade Cursor (extra display…)") {
            VibeMenuBarActions.cascadeCursorOnExtraOrMainDisplay()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])

        Divider()

        localServersSection

        Divider()

        Button("Quit VibeWindowManager") {
            NSApp.terminate(nil)
        }
    }

    @ViewBuilder
    private var localServersSection: some View {
        let ranked = rankedServers
        let background = backgroundServers
        if ranked.isEmpty, background.isEmpty {
            Button("No listening servers") {}
                .disabled(true)
        } else {
            // The count is the ranked entries only — background services are counted in their own submenu.
            Menu("Local servers (\(String(ranked.count)))") {
                ForEach(ranked) { server in
                    serverMenu(server)
                }

                if !background.isEmpty {
                    Divider()

                    Menu("Background services (\(String(background.count)))") {
                        ForEach(background) { server in
                            serverMenu(server)
                        }
                    }
                }

                Divider()

                Button("Refresh") {
                    servers.refresh()
                }
            }
        }
    }

    @ViewBuilder
    private func serverMenu(_ server: LocalServerProcess) -> some View {
        let uptime = servers.uptimeText(for: server)
        let port = server.primaryPort
        // Plain Strings, never LocalizedStringKey interpolation: port 5000 would render as "5.000".
        Menu(VibeServerMenuFormat.entryTitle(server, uptime: uptime)) {
            // Same rule as `server.isLikelyHTTP` (which is defined on primaryPort) — routed through the
            // one shared implementation on LocalServerProcess so the menu never drifts from the tab.
            if VibeMenuBarActions.isLikelyHTTPPort(port) {
                Button("Open http://localhost:\(String(port))") {
                    VibeMenuBarActions.openInBrowser(port: port)
                }
            }

            Button("Copy command") {
                VibeMenuBarActions.copyCommand(server)
            }

            if server.ports.count > 1 {
                Button("Ports \(VibeServerMenuFormat.portList(server))") {}
                    .disabled(true)
            }

            // .selfApp is never killable — VibeWindowManager will not offer to signal itself.
            if server.category.isKillable {
                Divider()

                Button("Quit process (SIGTERM)") {
                    if VibeMenuBarActions.confirmKill(server, force: false, uptime: uptime) {
                        servers.terminate(server, force: false)
                    }
                }

                Button("Force kill (SIGKILL)") {
                    if VibeMenuBarActions.confirmKill(server, force: true, uptime: uptime) {
                        servers.terminate(server, force: true)
                    }
                }
            }
        }
    }
}
