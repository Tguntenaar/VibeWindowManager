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
        if WindowCLI.shouldRun(arguments: CommandLine.arguments) {
            let exitCode = WindowCLI.run(arguments: CommandLine.arguments)
            Darwin.exit(exitCode)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
