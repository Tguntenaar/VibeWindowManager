//
//  ScreenGeometry.swift
//  VibeWindowManager
//
//  Helpers for converting between AppKit global screen coordinates and
//  Accessibility global coordinates, plus a small Stage Manager heuristic.
//

import AppKit
import CoreGraphics
import Foundation

enum StageManagerSupport {
    // There is no public API for the exact reserved strip. Keep it conservative.
    static let reservedLeadingStripWidth: CGFloat = 112

    static var isEnabled: Bool {
        UserDefaults(suiteName: "com.apple.WindowManager")?.object(forKey: "GloballyEnabled") as? Bool ?? false
    }
}

enum ScreenGeometry {
    static func menuBarScreen(from screens: [NSScreen]) -> NSScreen? {
        screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
    }

    static func layoutFrame(for screen: NSScreen, allScreens: [NSScreen], isStageManagerEnabled: Bool) -> CGRect {
        layoutFrame(
            visibleFrame: screen.visibleFrame,
            screenFrame: screen.frame,
            menuBarScreenFrame: menuBarScreen(from: allScreens)?.frame,
            isStageManagerEnabled: isStageManagerEnabled
        )
    }

    static func axPosition(forAppKitFrame rect: CGRect, allScreens: [NSScreen]) -> CGPoint {
        axPosition(forAppKitFrame: rect, menuBarScreenFrame: menuBarScreen(from: allScreens)?.frame ?? .zero)
    }

    static func layoutFrame(
        visibleFrame: CGRect,
        screenFrame: CGRect,
        menuBarScreenFrame: CGRect?,
        isStageManagerEnabled: Bool
    ) -> CGRect {
        var frame = visibleFrame

        if isStageManagerEnabled, let menuBarScreenFrame, screenFrame.equalTo(menuBarScreenFrame) {
            let inset = min(StageManagerSupport.reservedLeadingStripWidth, max(0, frame.width / 4))
            frame.origin.x += inset
            frame.size.width -= inset
        }

        return frame.integral
    }

    static func axPosition(forAppKitFrame rect: CGRect, menuBarScreenFrame: CGRect) -> CGPoint {
        CGPoint(x: rect.minX, y: menuBarScreenFrame.maxY - rect.maxY)
    }

    /// Inverse of `axPosition(forAppKitFrame:menuBarScreenFrame:)`: builds an AppKit-global frame
    /// (bottom-left origin, y increasing upward) from AX position + size.
    static func appKitFrame(axPosition p: CGPoint, size s: CGSize, menuBarScreenFrame: CGRect) -> CGRect {
        let maxY = menuBarScreenFrame.maxY - p.y
        let minY = maxY - s.height
        return CGRect(x: p.x, y: minY, width: s.width, height: s.height)
    }
}
