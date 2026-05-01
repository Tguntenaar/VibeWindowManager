//
//  VibeFocusPaster.swift
//  VibeWindowManager
//
//  Activate app, raise window via AX, paste via pasteboard + synthetic Cmd+V.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum VibeFocusPaster {
    /// Left / right Command (US QWERTY). Used to hold Command while "V" is pressed.
    private static var commandKey: CGKeyCode { 55 }
    private static var vKey: CGKeyCode { 9 } // kVK_ANSI_V
    /// Delete / Backspace (left delete) — HIToolbox kVK_Delete.
    private static var backspaceKey: CGKeyCode { 51 }

    static func focus(window: ManagedWindow, app: NSRunningApplication) throws {
        if !app.activate(options: .activateAllWindows) { _ = app.activate(options: .activateIgnoringOtherApps) }
        let e = window.element
        let err = AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        if err != .success { throw LayoutError.cannotSetFrame }
    }

    /// `point` in AppKit global space (y increases upward), matching `NSEvent.mouseLocation` / `CGEvent`.
    static func postLeftClickGlobal(_ point: CGPoint) {
        let src = CGEventSource(stateID: .hidSystemState)
        // Nudge the OS “cursor” to the point first — some apps (web views, text fields) only update
        // hit-testing after a move, and ignore a bare down+up at a stale position.
        if let move = CGEvent(
            mouseEventSource: src,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            move.post(tap: .cghidEventTap)
        }
        if let d = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            d.setIntegerValueField(.mouseEventClickState, value: 1)
            d.post(tap: .cghidEventTap)
        }
        if let d = CGEvent(
            mouseEventSource: src,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            d.setIntegerValueField(.mouseEventClickState, value: 1)
            d.post(tap: .cghidEventTap)
        }
    }

    /// Puts `text` on the pasteboard, then (after the next run-loop turn) posts Cmd+V as real key-down / key-up
    /// so terminal apps and Ghostty receive a normal paste sequence.
    static func pasteClearText(_ text: String, completion: (() -> Void)? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // One tick so the pasteboard and frontmost app are ready; HID apps often miss immediate paste.
        DispatchQueue.main.async {
            postCommandV()
            if let c = completion {
                // Let the frontmost app apply the paste before the next backspace+paste in a live stream.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { c() }
            }
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

    private static func postBackspace() {
        let src = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            if let d = CGEvent(keyboardEventSource: src, virtualKey: backspaceKey, keyDown: keyDown) {
                d.post(tap: .cghidEventTap)
            }
        }
    }

    /// Removes `previous` from the key window by posting one Backspace per `Character` in `previous`, then pastes `new`
    /// (or only deletes if `new` is empty). `completion` runs after the paste (or immediately if `new` is empty).
    static func runLiveReplace(previous: String, new: String, completion: (() -> Void)? = nil) {
        for _ in 0..<previous.count { postBackspace() }
        if new.isEmpty {
            completion?()
        } else {
            pasteClearText(new, completion: completion)
        }
    }
}
