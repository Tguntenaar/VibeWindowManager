//
//  WindowStreamCapture.swift
//  VibeWindowManager
//
//  Captures a single window as JPEG via the system screencapture tool (per-window
//  capture). Requires Screen Recording for other apps' windows, same as VNC/screen
//  sharing in practice.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum WindowStreamCapture {
    private static var captureLogCounter: Int = 0

    /// `ManagedWindow` layout ids use the `w-<CGWindowID>` form from `_AXUIElementGetWindow`.
    static func cgWindowID(fromBridgeWindowId s: String) -> CGWindowID? {
        guard s.hasPrefix("w-") else { return nil }
        let n = s.dropFirst(2)
        guard let u = UInt32(n) else { return nil }
        return u
    }

    /// Global rect for the **composited** window layer, same space as `CGEvent` / `screencapture -l` bitmap.
    /// `readFrame` (AX) can differ in size and aspect, which skews stream clicks if used for `nx/ny` mapping.
    static func globalBoundsForStreamClickMapping(cgWindowID: CGWindowID) -> CGRect? {
        // `screencapture -l` targets `cgWindowID`, but `CGWindowListCopyWindowInfo` can return
        // the window *and* on-screen sublayers. `list.first` may be a tiny child (e.g. 10×18), not
        // the same surface as the JPEG — match `kCGWindowNumber` to the id we stream and click.
        let opt: CGWindowListOption = [.optionIncludingWindow, .optionOnScreenOnly]
        guard let list = CGWindowListCopyWindowInfo(opt, cgWindowID) as? [[String: Any]] else { return nil }
        for win in list where cgWindowNumber(in: win) == cgWindowID {
            if let b = win[kCGWindowBounds as String] { return windowBoundsToCGRect(b) }
        }
        return nil
    }

    private static func cgWindowNumber(in win: [String: Any]) -> CGWindowID? {
        if let n = win[kCGWindowNumber as String] as? NSNumber { return n.uint32Value }
        if let n = win[kCGWindowNumber as String] as? Int { return CGWindowID(n) }
        return nil
    }

    private static func windowBoundsToCGRect(_ b: Any) -> CGRect? {
        if let m = b as? [String: Any] { return parseWindowBoundsKeyValue(m) }
        if let d = b as? NSDictionary {
            var m: [String: Any] = [:]
            d.enumerateKeysAndObjects { k, o, _ in
                if let s = k as? String { m[s] = o }
            }
            return parseWindowBoundsKeyValue(m)
        }
        return nil
    }

    private static func parseWindowBoundsKeyValue(_ d: [String: Any]) -> CGRect? {
        func n(_ o: Any?) -> CGFloat? {
            switch o {
            case let x as NSNumber: return CGFloat(x.doubleValue)
            case let x as CGFloat: return x
            default: return nil
            }
        }
        guard let x = n(d["X"] ?? d["x"]),
            let y = n(d["Y"] ?? d["y"]),
            let w = n(d["Width"] ?? d["w"] ?? d["width"]),
            let h = n(d["Height"] ?? d["h"] ?? d["height"])
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Avoid calling `CGRequestScreenCaptureAccess()` on every capture — that runs at high frequency
    /// and can re-open the system prompt even when the user already allowed the app in Settings.
    private static var didRequestScreenCaptureAccessThisRun = false

    static func requestScreenCaptureIfNeeded() {
        if #available(macOS 14.0, *) {
            if CGPreflightScreenCaptureAccess() { return }
            guard !didRequestScreenCaptureAccessThisRun else { return }
            didRequestScreenCaptureAccessThisRun = true
            _ = CGRequestScreenCaptureAccess()
        } else {
            guard !didRequestScreenCaptureAccessThisRun else { return }
            didRequestScreenCaptureAccessThisRun = true
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Resamples JPEG to keep payloads LAN-friendly. Primary capture: `/usr/sbin/screencapture -l<wid>`.
    /// `fullPixelSize` (before `maxWidth` downscale) is the same coordinate span as the stream bitmap for click mapping; it can be a few
    /// dozen pixels larger on each side than `kCGWindowBounds` (shadow), so the bridge **outsets** the CG rect symmetrically to match.
    static func captureJPEG(bridgeWindowId: String, maxWidth: CGFloat, quality: Double) -> (Data?, String?, fullPixelSize: CGSize?) {
        requestScreenCaptureIfNeeded()
        guard let wid = cgWindowID(fromBridgeWindowId: bridgeWindowId) else {
            return (nil, "not a window id (expected w-<id>)", nil)
        }
        guard let fullData = screencaptureWindowJPEGData(windowId: wid) else {
            return (nil, "screencapture failed — check Screen Recording for VibeWindowManager in System Settings", nil)
        }
        let fullPixelSize: CGSize? = {
            guard let img = NSImage(data: fullData), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return nil
            }
            return CGSize(width: cg.width, height: cg.height)
        }()
        // #region agent log
        captureLogCounter &+= 1
        if captureLogCounter % 12 == 1, let fs = fullPixelSize {
            VibeAgentDebugLog.append(
                hypothesisId: "H1_H4",
                location: "WindowStreamCapture.captureJPEG:jpegPixels",
                message: "screencapture output size (pixels before optional downscale)",
                data: [
                    "bridgeWindowId": bridgeWindowId,
                    "pixelW": fs.width, "pixelH": fs.height,
                    "willDownscale": fs.width > maxWidth
                ]
            )
        }
        // #endregion
        guard let rep = downscaleToMaxWidth(data: fullData, maxWidth: maxWidth) else {
            return (encodeJPEG(data: fullData, quality: quality), nil, fullPixelSize)
        }
        return (rep, nil, fullPixelSize)
    }

    private static func screencaptureWindowJPEGData(windowId: CGWindowID) -> Data? {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("vwm-ws-\(windowId)-\(UUID().uuidString).jpg")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = [
            "-x", "-t", "jpg", "-l", String(windowId), path,
        ]
        let err = Pipe()
        p.standardError = err
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        if p.terminationStatus != 0 {
            return nil
        }
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        try? FileManager.default.removeItem(atPath: path)
        return data
    }

    private static func downscaleToMaxWidth(data: Data, maxWidth: CGFloat) -> Data? {
        guard let src = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(src.width)
        let h = CGFloat(src.height)
        guard w > 0, h > 0, maxWidth > 0, w > maxWidth else { return nil }
        let s = maxWidth / w
        let nw = max(1, Int(w * s))
        let nh = max(1, Int(h * s))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: nw,
            height: nh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage() else { return nil }
        return encodeCGImageToJPEG(cg: out, quality: 0.62)
    }

    private static func encodeJPEG(data: Data, quality: Double) -> Data? {
        guard let rep = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return encodeCGImageToJPEG(cg: rep, quality: quality)
    }

    private static func encodeCGImageToJPEG(cg: CGImage, quality: Double) -> Data? {
        let m = NSMutableData()
        let q = max(0.05, min(0.95, quality))
        guard let dest = CGImageDestinationCreateWithData(
            m,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q,
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return m as Data
    }
}
