//
//  LayoutMirrorService.swift
//  VibeWindowManager
//
//  Normalizes Ghostty (or any target app) window frames into 0…1 top-left
//  coordinates relative to the main display layout frame.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
struct LayoutMirrorService {
    private let ax = AXWindowLayoutService()

    /// Single-screen v1: main display’s layout area (Stage Manager–aware).
    func mainDisplayLayoutFrame() -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let chosen = NSScreen.main ?? ScreenGeometry.menuBarScreen(from: screens) ?? screens[0]
        return ScreenGeometry.layoutFrame(for: chosen, allScreens: screens, isStageManagerEnabled: StageManagerSupport.isEnabled)
    }

    /// Windows for the resolved app, front-most first.
    func windows(
        for app: NSRunningApplication
    ) throws -> [ManagedWindow] {
        try ax.windows(for: app)
    }

    /// Build one `layout` message; `ref` is usually `mainDisplayLayoutFrame()`.
    func layoutMessage(
        seq: UInt64,
        app: NSRunningApplication,
        ref: CGRect,
        windows: [ManagedWindow],
        selectedId: String?
    ) -> BridgeLayoutMessage? {
        guard !ref.isEmpty, ref.width > 0, ref.height > 0 else { return nil }
        var items: [BridgeWindow] = []
        items.reserveCapacity(windows.count)
        for (i, w) in windows.enumerated() {
            guard let f = w.frame else { continue }
            guard let n = Self.normalize(frame: f, to: ref) else { continue }
            items.append(
                BridgeWindow(
                    id: w.id,
                    title: w.title,
                    zIndex: i,
                    rect: n
                )
            )
        }
        return BridgeLayoutMessage(
            seq: seq,
            appName: app.localizedName,
            bundleId: app.bundleIdentifier,
            reference: BridgeRect(
                x: Double(ref.minX),
                y: Double(ref.minY),
                width: Double(ref.width),
                height: Double(ref.height)
            ),
            windows: items,
            selectedId: selectedId
        )
    }

    /// Maps AppKit window rect + layout reference rect to normalized top-left 0…1 (SwiftUI style).
    nonisolated static func normalize(frame: CGRect, to ref: CGRect) -> BridgeRect? {
        let w = frame.width
        let h = frame.height
        guard w > 0, h > 0 else { return nil }
        // Same top-edge mapping as `LayoutPreviewView` in ContentView: ref.maxY and frame.maxY are AppKit upper edges.
        let nx = (frame.minX - ref.minX) / ref.width
        let ny = (ref.maxY - frame.maxY) / ref.height
        let nw = w / ref.width
        let nh = h / ref.height
        return BridgeRect(x: nx, y: ny, width: nw, height: nh)
    }
}
