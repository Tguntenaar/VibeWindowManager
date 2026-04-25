//
//  WindowStreamCapture.swift
//  VibeWindowManager
//
//  Captures a single window as JPEG via the system screencapture tool (per-window
//  capture). Requires Screen Recording for other apps' windows, same as VNC/screen
//  sharing in practice.
//

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum WindowStreamCapture {
    /// `ManagedWindow` layout ids use the `w-<CGWindowID>` form from `_AXUIElementGetWindow`.
    static func cgWindowID(fromBridgeWindowId s: String) -> CGWindowID? {
        guard s.hasPrefix("w-") else { return nil }
        let n = s.dropFirst(2)
        guard let u = UInt32(n) else { return nil }
        return u
    }

    static func requestScreenCaptureIfNeeded() {
        if #available(macOS 14.0, *) {
            if !CGPreflightScreenCaptureAccess() {
                _ = CGRequestScreenCaptureAccess()
            }
        } else {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    /// Resamples JPEG to keep payloads LAN-friendly. Primary capture: `/usr/sbin/screencapture -l<wid>`.
    static func captureJPEG(bridgeWindowId: String, maxWidth: CGFloat, quality: Double) -> (Data?, String?) {
        requestScreenCaptureIfNeeded()
        guard let wid = cgWindowID(fromBridgeWindowId: bridgeWindowId) else {
            return (nil, "not a window id (expected w-<id>)")
        }
        guard let fullData = screencaptureWindowJPEGData(windowId: wid) else {
            return (nil, "screencapture failed — check Screen Recording for VibeWindowManager in System Settings")
        }
        guard let rep = downscaleToMaxWidth(data: fullData, maxWidth: maxWidth) else {
            return (encodeJPEG(data: fullData, quality: quality), nil)
        }
        return (rep, nil)
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
