//
//  VibeStreamClickRipple.swift
//  VibeWindowManager
//
//  Brief ring at the global point of a stream-injected click (iPad → Mac), similar to the iOS ripple.
//

import AppKit
import Foundation

@MainActor
enum VibeStreamClickRipple {
    private static let diameter: CGFloat = 44
    private static weak var last: NSWindow?

    /// `appKitPoint` is AppKit global (origin bottom-left, y up), same as `NSEvent.mouseLocation` / `CGEvent`.
    static func show(at appKitPoint: CGPoint) {
        let d = Self.diameter
        let r = d * 0.5
        var ox = appKitPoint.x - r
        var oy = appKitPoint.y - r
        if let sc = NSScreen.screens.first(where: { NSPointInRect(appKitPoint, $0.frame) }) {
            let vf = sc.frame
            ox = min(max(ox, vf.minX), vf.maxX - d)
            oy = min(max(oy, vf.minY), vf.maxY - d)
        }
        let frame = NSRect(x: ox, y: oy, width: d, height: d)
        last?.orderOut(nil)
        last = nil

        let win = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = StreamClickRippleView(frame: NSRect(origin: .zero, size: frame.size))
        win.contentView = v
        win.isReleasedWhenClosed = false
        win.alphaValue = 1
        last = win
        win.setFrame(frame, display: true, animate: false)
        win.setIsVisible(true)
        v.needsDisplay = true
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        v.playFade { [weak win] in
            win?.orderOut(nil)
        }
    }
}

private final class StreamClickRippleView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Intentionally not layer-backed: `wantsLayer = true` can skip `draw(_:)` in some
        // configurations, which would make the ring invisible.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 1.5
        let o = bounds.insetBy(dx: inset, dy: inset)
        NSColor.cyan.withAlphaComponent(0.9).setStroke()
        let p = NSBezierPath(ovalIn: o)
        p.lineWidth = 2
        p.stroke()
    }

    func playFade(_ done: @escaping () -> Void) {
        alphaValue = 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.42
            self.animator().alphaValue = 0
        }, completionHandler: {
            done()
        })
    }
}
