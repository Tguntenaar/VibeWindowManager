//
//  AXWindowLayoutService.swift
//  VibeWindowManager
//
//  Controls other apps’ windows via Accessibility. Requires the app to be trusted
//  in System Settings → Privacy & Security → Accessibility.
//

import AppKit
import ApplicationServices
import Foundation

// Private, long-stable AX API that returns the CGWindowID for an AXUIElement window.
// Used widely by tiling WMs (yabai, Amethyst) since AXUIElement pointer addresses
// returned by AXUIElementCopyAttributeValue are not stable across calls.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

struct ManagedWindow: Identifiable {
    let id: String
    let element: AXUIElement
    let title: String
    let frame: CGRect?
}

@MainActor
struct AXWindowLayoutService {
    var isProcessTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for accessibility (once) and opens the Privacy pane if the user can grant access.
    func requestAccessibilityIfNeeded() {
        if UserDefaults.standard.bool(forKey: "AXPromptedForAccessibility") == false {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
            UserDefaults.standard.set(true, forKey: "AXPromptedForAccessibility")
        } else {
            _ = AXIsProcessTrusted()
        }
    }

    /// Window elements for a running app, front-to-back order as returned (usually front first).
    func windowElements(for runningApp: NSRunningApplication) throws -> [AXUIElement] {
        try windows(for: runningApp).map(\.element)
    }

    func windows(for runningApp: NSRunningApplication) throws -> [ManagedWindow] {
        guard isProcessTrusted else {
            throw LayoutError.notTrusted
        }
        let appEl = AXUIElementCreateApplication(runningApp.processIdentifier)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &value)
        guard err == .success, let any = value else {
            throw LayoutError.cannotListWindows(AXError(rawValue: err.rawValue) ?? .cannotComplete)
        }
        let array: [AXUIElement]
        if let swiftArr = any as? [AXUIElement] {
            array = swiftArr
        } else if let a = any as? NSArray {
            array = (0..<a.count).map { a[$0] as! AXUIElement }
        } else {
            throw LayoutError.cannotListWindows(AXError(rawValue: err.rawValue) ?? .cannotComplete)
        }
        return array
            .filter(shouldLayoutWindow)
            .map { element in
                ManagedWindow(
                    id: windowIdentifier(for: element),
                    element: element,
                    title: windowTitle(for: element),
                    frame: readFrame(element)
                )
            }
    }

    private func shouldLayoutWindow(_ w: AXUIElement) -> Bool {
        guard let role = try? copyString(w, kAXRoleAttribute as CFString), role == (kAXWindowRole as String) else {
            return false
        }
        if let sr = try? copyString(w, kAXSubroleAttribute as CFString) {
            if sr == (kAXSystemFloatingWindowSubrole as String) { return false }
        }
        if (try? copyBool(w, kAXMinimizedAttribute as CFString)) == true { return false }
        return true
    }

    private func copyString(_ el: AXUIElement, _ attr: CFString) throws -> String? {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, attr, &v)
        guard e == .success else { return nil }
        return (v as? String)
    }

    private func copyBool(_ el: AXUIElement, _ attr: CFString) throws -> Bool? {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, attr, &v)
        guard e == .success, let c = v else { return nil }
        if let b = c as? Bool { return b }
        if let n = c as? NSNumber { return n.boolValue }
        if CFGetTypeID(c) == CFBooleanGetTypeID() { return CFBooleanGetValue(c as! CFBoolean) }
        return nil
    }

    private func windowTitle(for element: AXUIElement) -> String {
        if let title = try? copyString(element, kAXTitleAttribute as CFString) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "Untitled window"
    }

    /// Stable per-window identifier. AX returns a fresh `AXUIElementRef` object each call, so raw pointer
    /// addresses cannot be used as wire IDs — they churn on every 6 Hz push. `_AXUIElementGetWindow` is a
    /// long-standing private API (used by yabai, Amethyst, etc.) that returns the `CGWindowID`, which is
    /// stable for the window's lifetime.
    private func windowIdentifier(for element: AXUIElement) -> String {
        var wid: CGWindowID = 0
        if _AXUIElementGetWindow(element, &wid) == .success, wid != 0 {
            return "w-\(wid)"
        }
        let opaque = Unmanaged.passUnretained(element).toOpaque()
        return String(describing: opaque)
    }

    /// Sets full frame. The incoming `rect` is in AppKit global coordinates; AX uses a top-left origin.
    func setFrame(_ win: AXUIElement, _ rect: CGRect, allScreens: [NSScreen]) throws {
        guard isProcessTrusted else { throw LayoutError.notTrusted }
        var p = ScreenGeometry.axPosition(forAppKitFrame: rect, allScreens: allScreens)
        var s = rect.size
        guard let pVal = axValueFor(point: p), let sVal = axValueFor(size: s) else { throw LayoutError.cannotSetFrame }
        // Size first, then position: some UIs need size before a safe origin move
        var sErr = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sVal)
        var pErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pVal)
        if pErr == .success, sErr == .success { return }
        // Retry opposite order
        pErr = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pVal)
        sErr = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sVal)
        if pErr == .success, sErr == .success { return }
        throw LayoutError.cannotSetFrame
    }

    /// Size for layout decisions (cascade), from AX position and size.
    func readFrame(_ win: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &size) == .success,
              let p = valueToPoint(pos),
              let s = valueToSize(size) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // MARK: - High-level

    /// Applies tiling to the first N windows. Windows beyond `slots.count` are unchanged.
    func applyTile(visibleFrame: CGRect, mode: TileMode, to windows: [AXUIElement], allScreens: [NSScreen]) throws {
        let slots = WindowLayoutEngine.slotRects(visibleFrame: visibleFrame, mode: mode, count: windows.count)
        for (i, win) in windows.enumerated() where i < slots.count {
            try setFrame(win, slots[i], allScreens: allScreens)
        }
    }

    func applyCascade(visibleFrame: CGRect, to windows: [AXUIElement], allScreens: [NSScreen], insetStep: CGFloat) throws {
        let frames = WindowLayoutEngine.cascadeFrames(
            visibleFrame: visibleFrame,
            count: windows.count,
            insetStep: insetStep,
            margin: CascadeDefaults.margin
        )
        for (i, win) in windows.enumerated() where i < frames.count {
            try setFrame(win, frames[i], allScreens: allScreens)
        }
    }
}

// MARK: - Errors

enum LayoutError: Error, LocalizedError {
    case notTrusted
    case cannotListWindows(AXError)
    case cannotSetFrame
    var errorDescription: String? {
        switch self {
        case .notTrusted: return "Enable VibeWindowManager in System Settings → Privacy & Security → Accessibility."
        case .cannotListWindows(let e): return "Could not read windows from the app. (\(e.rawValue))"
        case .cannotSetFrame: return "Could not move or resize a window. The app may block accessibility."
        }
    }
}

// MARK: - AX value helpers (nonisolated; CF calls)

private func axValueFor(point: CGPoint) -> AXValue? {
    var p = point
    return AXValueCreate(.cgPoint, &p)
}

private func axValueFor(size: CGSize) -> AXValue? {
    var s = size
    return AXValueCreate(.cgSize, &s)
}

private func valueToPoint(_ v: CFTypeRef?) -> CGPoint? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    guard AXValueGetType(v as! AXValue) == .cgPoint else { return nil }
    AXValueGetValue(v as! AXValue, .cgPoint, &p)
    return p
}

private func valueToSize(_ v: CFTypeRef?) -> CGSize? {
    guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    guard AXValueGetType(v as! AXValue) == .cgSize else { return nil }
    AXValueGetValue(v as! AXValue, .cgSize, &s)
    return s
}

