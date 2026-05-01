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
}

private struct MenuBarExtraCommands: View {
    let mainWindowID: String

    @EnvironmentObject private var bridge: VibeBridgeServer
    @Environment(\.openWindow) private var openWindow

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

        Button("Quit VibeWindowManager") {
            NSApp.terminate(nil)
        }
    }
}
