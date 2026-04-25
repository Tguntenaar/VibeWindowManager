//
//  VibeWindowManagerApp.swift
//  VibeWindowManager
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import Darwin
import SwiftUI

@main
struct VibeWindowManagerApp: App {
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
        ])
    }

    /// True when the app is a unit test host (Swift Testing / XCTest) — not a terminal `windows` invocation.
    private static var isTestHostProcess: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return CommandLine.arguments.contains { $0.caseInsensitiveCompare("-XCTest") == .orderedSame }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
