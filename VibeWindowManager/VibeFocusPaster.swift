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
    /// Left / right Command (US QWERTY). Used to hold Command while "V" is pressed.
    private static var commandKey: CGKeyCode { 55 }
    private static var vKey: CGKeyCode { 9 } // kVK_ANSI_V

    static func focus(window: ManagedWindow, app: NSRunningApplication) throws {
        if !app.activate(options: .activateAllWindows) { _ = app.activate(options: .activateIgnoringOtherApps) }
        let e = window.element
        let err = AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        if err != .success { throw LayoutError.cannotSetFrame }
    }

    /// Puts `text` on the pasteboard, then (after the next run-loop turn) posts Cmd+V as real key-down / key-up
    /// so terminal apps and Ghostty receive a normal paste sequence.
    static func pasteClearText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // One tick so the pasteboard and frontmost app are ready; HID apps often miss immediate paste.
        DispatchQueue.main.async {
            postCommandV()
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let d = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: true) {
            d.post(tap: .cghidEventTap)
        }
        if let d = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true) {
            d.flags = .maskCommand
            d.post(tap: .cghidEventTap)
        }
        if let d = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) {
            d.flags = .maskCommand
            d.post(tap: .cghidEventTap)
        }
        if let d = CGEvent(keyboardEventSource: src, virtualKey: commandKey, keyDown: false) {
            d.post(tap: .cghidEventTap)
        }
    }
}
