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
    /// Retained for legacy call sites; bridge paths use `desktopLayoutFrame` so the mirror
    /// coordinate space does not flip when focus moves between displays.
    func mainDisplayLayoutFrame() -> CGRect? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let chosen = NSScreen.main ?? ScreenGeometry.menuBarScreen(from: screens) ?? screens[0]
        return ScreenGeometry.layoutFrame(for: chosen, allScreens: screens, isStageManagerEnabled: StageManagerSupport.isEnabled)
    }

    /// Per-screen Stage-Manager-adjusted layout frames in AppKit global coordinates, matching
    /// the geometry used to build `desktopLayoutFrame`.
    func screenLayoutFrames(screens: [NSScreen]) -> [CGRect] {
        let stage = StageManagerSupport.isEnabled
        return screens.map {
            ScreenGeometry.layoutFrame(for: $0, allScreens: screens, isStageManagerEnabled: stage)
        }
    }

    /// Union bounding rect of every screen's layout frame — a stable desktop-wide coordinate
    /// space that does not change when focus moves between displays.
    func desktopLayoutFrame(screens: [NSScreen]) -> CGRect? {
        let frames = screenLayoutFrames(screens: screens).filter { !$0.isEmpty }
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Windows for the resolved app, front-most first.
    func windows(
        for app: NSRunningApplication
    ) throws -> [ManagedWindow] {
        try ax.windows(for: app)
    }

    /// Subset of `windows` that actually appear in the bridge layout: has a frame and normalizes into `ref`
    /// (e.g. excludes AX noise / windows with no layout rect so they don’t appear on iOS).
    ///
    /// Sorted spatially (top-to-bottom, then left-to-right) so the ordering is stable across AX Z-order
    /// changes. Without this, every call to `kAXRaiseAction` rotates the raised window to index 0 in the
    /// AX windows list, which would make "Next" cycle only between the two most-recently-focused windows
    /// and cause iOS tiles to visually swap on every focus change.
    static func windowsInLayoutRef(_ windows: [ManagedWindow], ref: CGRect) -> [ManagedWindow] {
        guard !ref.isEmpty, ref.width > 0, ref.height > 0 else { return [] }
        let kept = windows.compactMap { w -> ManagedWindow? in
            guard let f = w.frame else { return nil }
            guard Self.normalize(frame: f, to: ref) != nil else { return nil }
            return w
        }
        return kept.sorted { a, b in
            let fa = a.frame ?? .zero
            let fb = b.frame ?? .zero
            if fa.minY != fb.minY { return fa.minY < fb.minY }
            if fa.minX != fb.minX { return fa.minX < fb.minX }
            return a.id < b.id
        }
    }

    /// Build one `layout` message; `ref` is usually `desktopLayoutFrame(screens:)` — the union of
    /// every display's layout frame so coordinates stay stable as focus moves between displays.
    /// `perScreen` is the list of each physical display's layout frame in the same AppKit global
    /// space as `ref`; they get normalized against `ref` and emitted as `screens[]`.
    func layoutMessage(
        seq: UInt64,
        app: NSRunningApplication,
        ref: CGRect,
        perScreen: [CGRect],
        windows: [ManagedWindow],
        additionalWindows: [ManagedWindow] = [],
        selectedId: String?
    ) -> BridgeLayoutMessage? {
        guard !ref.isEmpty, ref.width > 0, ref.height > 0 else { return nil }
        let merged: [ManagedWindow] = {
            if additionalWindows.isEmpty { return windows }
            var ids = Set(windows.map(\.id))
            var a = windows
            for w in additionalWindows where !ids.contains(w.id) {
                a.append(w)
                ids.insert(w.id)
            }
            return a
        }()
        let layoutWins = Self.windowsInLayoutRef(merged, ref: ref)
        // `windows[]` stays spatially sorted (stable tile / list order). `zIndex` must follow AX
        // front-to-back so overlapping mirror tiles match real stacking for hit testing (iOS).
        let layoutIds = Set(layoutWins.map(\.id))
        let axFrontToBackInLayout: [ManagedWindow] = merged.filter { layoutIds.contains($0.id) }
        let stackCount = axFrontToBackInLayout.count
        var stackZById: [String: Int] = [:]
        for (axPos, w) in axFrontToBackInLayout.enumerated() {
            // `merged` is AX order (front first). Higher SwiftUI zIndex = closer to the user.
            stackZById[w.id] = max(0, stackCount - 1 - axPos)
        }
        var items: [BridgeWindow] = []
        items.reserveCapacity(layoutWins.count)
        for (i, w) in layoutWins.enumerated() {
            guard let f = w.frame, let n = Self.normalize(frame: f, to: ref) else { continue }
            items.append(
                BridgeWindow(
                    id: w.id,
                    title: w.title,
                    zIndex: stackZById[w.id] ?? i,
                    rect: n
                )
            )
        }
        let screenRects = perScreen.compactMap { Self.normalize(frame: $0, to: ref) }
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
            screens: screenRects,
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

    /// Inverse of `normalize`: builds an AppKit-global frame from normalized bridge coords and the same `ref`.
    nonisolated static func denormalize(bridgeRect: BridgeRect, to ref: CGRect) -> CGRect {
        let nw = CGFloat(bridgeRect.width)
        let nh = CGFloat(bridgeRect.height)
        let w = nw * ref.width
        let h = nh * ref.height
        let minX = ref.minX + CGFloat(bridgeRect.x) * ref.width
        let maxY = ref.maxY - CGFloat(bridgeRect.y) * ref.height
        let minY = maxY - h
        return CGRect(x: minX, y: minY, width: w, height: h)
    }
}
