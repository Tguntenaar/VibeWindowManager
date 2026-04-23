//
//  VibeFocusPaster.swift
//  VibeWindowManager
//
//  Activate app, raise window via AX, paste via pasteboard + synthetic Cmd+V.
//

import AppKit
import ApplicationServices
import Foundation

@MainActor
enum VibeFocusPaster {
    private static var pasteKeyCode: CGKeyCode { 9 } // v

    static func focus(window: ManagedWindow, app: NSRunningApplication) throws {
        if !app.activate(options: .activateAllWindows) { _ = app.activate(options: .activateIgnoringOtherApps) }
        let e = window.element
        let err = AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        if err != .success { throw LayoutError.cannotSetFrame }
    }

    static func pasteClearText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        postKeyCommand(key: pasteKeyCode, useCommand: true)
    }

    private static func postKeyCommand(key: CGKeyCode, useCommand: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        var flags: CGEventFlags = []
        if useCommand { flags.insert(.maskCommand) }
        if let d = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) {
            d.flags = flags
            d.post(tap: .cghidEventTap)
        }
        if let u = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) {
            u.flags = flags
            u.post(tap: .cghidEventTap)
        }
    }
}
