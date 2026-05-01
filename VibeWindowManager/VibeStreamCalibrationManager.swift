//
//  VibeStreamCalibrationManager.swift
//  VibeWindowManager
//
//  Full-screen white “Click calibration” with a target dot; dot jumps to a new random spot
//  after each iPad-reported sample so you can test drift vs. linearity across the surface.
//

import AppKit
import Foundation

@MainActor
final class VibeStreamCalibrationManager {
    static let title = "Click calibration"
    static let defaultSampleCount = 5
    private static let dotRadius: CGFloat = 9
    private static let edgeMarginNorm: Double = 0.08

    private var window: NSWindow?
    private var dotView: VibeCalibrationDotView?
    private(set) var managed: ManagedWindow?
    /// `true` until we broadcast a `calibrationTarget` for the **current** dot position.
    var didBroadcastTarget = false
    /// 0…sampleCount-1; matches the next `calibrationTarget.sampleIndex` for the visible dot.
    private(set) var currentPresentationIndex: Int = 0
    var sampleCount: Int = 5

    var onRequestClose: (() -> Void)?

    var isActive: Bool { window != nil }

    func show() {
        didBroadcastTarget = false
        currentPresentationIndex = 0
        managed = nil
        window?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let r = screen.frame
        let w = NSWindow(
            contentRect: r,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.title = Self.title
        w.isReleasedWhenClosed = false
        w.setFrame(r, display: true)
        w.isOpaque = true
        w.backgroundColor = .white
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = VibeCalibrationDotView(frame: NSRect(origin: .zero, size: r.size), dotRadius: Self.dotRadius)
        v.onClose = { [weak self] in
            self?.onRequestClose?()
        }
        w.contentView = v
        v.autoresizingMask = [.width, .height]
        dotView = v
        v.placeDotRandomly(margin: Self.edgeMarginNorm)
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    /// After each iPad raw tap (not after the last sample), move the dot and allow re-broadcasting.
    func advanceToNextTargetAfterIpadSample() {
        guard currentPresentationIndex < sampleCount - 1 else { return }
        currentPresentationIndex &+= 1
        didBroadcastTarget = false
        dotView?.placeDotRandomly(margin: Self.edgeMarginNorm)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        dotView = nil
        managed = nil
        didBroadcastTarget = false
        currentPresentationIndex = 0
    }

    /// Refresh the AX-facing window after layout; call from the bridge’s layout tick.
    func refreshManaged(using ax: AXWindowLayoutService) throws {
        guard let me = ourRunningApp() else { return }
        let wins = try ax.windows(for: me)
        managed = wins.first { $0.title == Self.title }
    }

    /// Center of the dark dot in **screen** (AppKit global) space.
    private func dotCenterGlobal() -> CGPoint? {
        guard let w = window, let v = w.contentView as? VibeCalibrationDotView else { return nil }
        return v.dotCenterInScreen()
    }

    /// Same convention as the bridge click-injection: top-left of the window’s bitmap in 0…1.
    func expectedBitmapFraction(ax: AXWindowLayoutService) -> (nx: Double, ny: Double)? {
        guard let mw = managed, let f = ax.readFrame(mw.element) else { return nil }
        guard let g = dotCenterGlobal() else { return nil }
        let w = f.width, h = f.height
        guard w > 0, h > 0 else { return nil }
        let nx = (g.x - f.minX) / w
        let ny = (f.maxY - g.y) / h
        return (min(1, max(0, nx)), min(1, max(0, ny)))
    }

    private func ourRunningApp() -> NSRunningApplication? {
        for a in NSWorkspace.shared.runningApplications {
            if a.processIdentifier == ProcessInfo.processInfo.processIdentifier { return a }
        }
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).first
    }
}

// MARK: - White full-screen + dot (top-left 0,1, matches stream JPEG + windowStreamClick)

private final class VibeCalibrationDotView: NSView {
    private let dotR: CGFloat
    /// Center in 0…1, origin top-left of bounds (isFlipped).
    private var normCenterX: CGFloat = 0.5
    private var normCenterY: CGFloat = 0.5
    var onClose: (() -> Void)?

    init(frame: NSRect, dotRadius: CGFloat) {
        self.dotR = dotRadius
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Random dot position with normalized margin from edges (center stays inside).
    func placeDotRandomly(margin: Double) {
        let m = CGFloat(margin)
        let span = 1 as CGFloat - 2 * m
        guard span > 0.02 else { return }
        normCenterX = m + span * .random(in: 0...1)
        normCenterY = m + span * .random(in: 0...1)
        needsDisplay = true
    }

    func dotCenterInScreen() -> CGPoint? {
        guard let w = window else { return nil }
        let b = bounds
        guard b.width > 0, b.height > 0 else { return nil }
        let local = NSPoint(
            x: normCenterX * b.width,
            y: normCenterY * b.height
        )
        let inWindow = convert(local, to: nil)
        return w.convertToScreen(NSRect(origin: inWindow, size: .zero)).origin
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let c = NSPoint(
            x: normCenterX * bounds.width,
            y: normCenterY * bounds.height
        )
        let r = dotR
        let dot = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dot).fill()
        // Small close control (emergency) — iPad “Cancel” is primary.
        let label = "Close"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let sz = attr.size()
        let pad: CGFloat = 8
        let tr = NSRect(
            x: bounds.maxX - sz.width - pad * 2,
            y: pad,
            width: sz.width + pad * 2,
            height: sz.height + pad * 2
        )
        NSColor.black.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: tr, xRadius: 6, yRadius: 6).fill()
        attr.draw(
            in: NSRect(
                x: tr.minX + pad,
                y: tr.minY + pad * 0.5,
                width: sz.width,
                height: sz.height
            )
        )
    }

    /// Hit-test the Close pill (top-right).
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeButtonFrame().contains(p) {
            onClose?()
        }
        super.mouseDown(with: event)
    }

    private func closeButtonFrame() -> NSRect {
        let label = "Close"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular)
        ]
        let attr = NSAttributedString(string: label, attributes: attrs)
        let sz = attr.size()
        let pad: CGFloat = 8
        return NSRect(
            x: bounds.maxX - sz.width - pad * 2,
            y: pad,
            width: sz.width + pad * 2,
            height: sz.height + pad * 2
        )
    }
}
