//
//  VibeWindowManagerTests.swift
//  VibeWindowManagerTests
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import CoreGraphics
import Foundation
import Testing
@testable import VibeWindowManager

struct WindowLayoutEngineTests {
    @Test func equalColumnsFillsWidth() {
        let vf = CGRect(x: 100, y: 200, width: 1000, height: 400)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .equalColumns(2), count: 2)
        #expect(slots.count == 2)
        #expect(abs(slots[0].minX - vf.minX) < 1)
        #expect(abs((slots[0].maxX - slots[1].minX)) < 2)
        #expect(abs((slots[0].width + slots[1].width) - vf.width) < 2)
    }

    @Test func equalRowsFillsHeight() {
        let vf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .equalRows(2), count: 2)
        #expect(slots.count == 2)
        #expect(abs((slots[0].height + slots[1].height) - vf.height) < 2)
    }

    @Test func gridFourRects() {
        let vf = CGRect(x: 0, y: 0, width: 400, height: 400)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .grid(4), count: 4)
        #expect(slots.count == 4)
        for s in slots {
            #expect(s.minX >= vf.minX)
            #expect(s.minY >= vf.minY)
            #expect(s.maxX <= vf.maxX + 0.1)
            #expect(s.maxY <= vf.maxY + 0.1)
        }
    }

    @Test func cascadeStaysInVisibleFrame() {
        let vf = CGRect(x: 100, y: 100, width: 800, height: 600)
        let frames = WindowLayoutEngine.cascadeFrames(
            visibleFrame: vf,
            count: 3,
            insetStep: 30,
            margin: 8
        )
        #expect(frames.count == 3)
        for f in frames {
            #expect(f.minX >= vf.minX)
            #expect(f.minY >= vf.minY)
            #expect(f.maxX <= vf.maxX + 0.1)
            #expect(f.maxY <= vf.maxY + 0.1)
        }
    }

    @Test func cascadeLastWindowSitsTopRight() {
        let vf = CGRect(x: 100, y: 100, width: 900, height: 700)
        let frames = WindowLayoutEngine.cascadeFrames(
            visibleFrame: vf,
            count: 4,
            insetStep: 30,
            margin: 8
        )

        #expect(frames.count == 4)
        let last = frames[3]
        let previous = frames[2]

        #expect(abs(last.maxX - (vf.maxX - 8)) < 1.0)
        #expect(abs(last.maxY - (vf.maxY - 8)) < 1.0)
        #expect(abs((last.minX - previous.minX) - 30) < 1.0)
        #expect(abs((last.minY - previous.minY) - 30) < 1.0)
    }

    @Test func fiveWindowColumnsProduceFiveRects() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .equalColumns(5), count: 5)

        #expect(slots.count == 5)
        #expect(abs(slots.map(\.width).reduce(0, +) - vf.width) < 2)
    }

    @Test func fiveWindowGridProducesFiveRects() {
        let vf = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let slots = WindowLayoutEngine.slotRects(visibleFrame: vf, mode: .grid(5), count: 5)

        #expect(slots.count == 5)
        for slot in slots {
            #expect(slot.minX >= vf.minX)
            #expect(slot.minY >= vf.minY)
            #expect(slot.maxX <= vf.maxX + 0.1)
            #expect(slot.maxY <= vf.maxY + 0.1)
        }
    }

    @Test func suggestedModesFollowWindowCount() {
        #expect(TileMode.suggestedModes(forWindowCount: 0).isEmpty)
        #expect(TileMode.suggestedModes(forWindowCount: 2) == [.equalColumns(2), .equalRows(2)])
        #expect(TileMode.suggestedModes(forWindowCount: 3) == [.onePlusTwo, .grid(3), .equalColumns(3), .equalRows(3)])
        #expect(TileMode.suggestedModes(forWindowCount: 5) == [.grid(5), .equalColumns(5)])
    }

    @Test func appKitFrameConvertsToAXTopLeftPosition() {
        let menuBar = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = CGRect(x: 100, y: 700, width: 400, height: 150)

        let point = ScreenGeometry.axPosition(forAppKitFrame: rect, menuBarScreenFrame: menuBar)

        #expect(point.x == 100)
        #expect(point.y == 50)

        let back = ScreenGeometry.appKitFrame(axPosition: point, size: rect.size, menuBarScreenFrame: menuBar)
        #expect(abs(back.minX - rect.minX) < 0.5)
        #expect(abs(back.minY - rect.minY) < 0.5)
        #expect(abs(back.width - rect.width) < 0.5)
        #expect(abs(back.height - rect.height) < 0.5)
    }

    @Test func stageManagerReservesLeadingStripOnMenuBarDisplay() {
        let layoutFrame = ScreenGeometry.layoutFrame(
            visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 860),
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            menuBarScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            isStageManagerEnabled: true
        )

        #expect(layoutFrame.minX == StageManagerSupport.reservedLeadingStripWidth)
        #expect(layoutFrame.width == 1440 - StageManagerSupport.reservedLeadingStripWidth)
    }
}

struct LayoutMirrorServiceTests {
    @Test func normalizeMatchesPreviewAxis() {
        let ref = CGRect(x: 100, y: 200, width: 1000, height: 800)
        let win = CGRect(x: 100, y: 400, width: 500, height: 400)
        let n = LayoutMirrorService.normalize(frame: win, to: ref)!
        #expect(abs(n.x - 0) < 0.001)
        #expect(abs(n.width - 0.5) < 0.001)
        #expect(abs(n.height - 0.5) < 0.001)
        #expect(n.y > 0)
    }
}

@MainActor
struct WindowCLITests {
    @Test func parseListApps() throws {
        let command = try WindowCLI.parse(userArguments: ["list-apps"])
        #expect(command == .listApps)
    }

    @Test func parseBridgeDump() throws {
        let command = try WindowCLI.parse(userArguments: ["bridge-dump", "ghostty"])
        #expect(command == .bridgeDump(appQuery: "ghostty"))
    }

    @Test func parseHelp() throws {
        let command = try WindowCLI.parse(userArguments: ["help"])
        #expect(command == .help)
    }

    @Test func parseCascadeWithPixel() throws {
        let command = try WindowCLI.parse(userArguments: ["cursor", "cascade", "--pixel", "30"])
        #expect(command == .layout(appQuery: "cursor", layout: .cascade, pixel: 30))
    }

    @Test func parseColumns() throws {
        let command = try WindowCLI.parse(userArguments: ["ghostty", "columns"])
        #expect(command == .layout(appQuery: "ghostty", layout: .columns, pixel: nil))
    }

    @Test func shouldRunVibeAppWithOnlyXcodeNSFlags() {
        // Xcode can inject e.g. `-NSShowNonLocalizedStrings` + `YES`; must not enable CLI.
        #expect(
            WindowCLI.shouldRun(
                arguments: ["/x/VibeWindowManager", "-NSShowNonLocalizedStrings", "YES"]
            ) == false
        )
    }

    @Test func shouldRunVibeAppWithListApps() {
        #expect(
            WindowCLI.shouldRun(
                arguments: ["/x/VibeWindowManager", "list-apps"]
            ) == true
        )
    }

    @Test func shouldRunWindowsSymlinkWithNoArgs() {
        #expect(
            WindowCLI.shouldRun(
                arguments: ["/x/windows"]
            ) == true
        )
    }
}

struct LayoutMirrorNormalizeTests {
    @Test func normalizeDenormalizeRoundTrip() {
        let ref = CGRect(x: 100, y: 50, width: 1440, height: 900)
        let frames = [
            CGRect(x: 100, y: 200, width: 400, height: 300),
            CGRect(x: 2000, y: 100, width: 500, height: 600),
        ]
        for f in frames {
            guard let n = LayoutMirrorService.normalize(frame: f, to: ref) else {
                Issue.record("expected normalize for \(f)")
                continue
            }
            let back = LayoutMirrorService.denormalize(bridgeRect: n, to: ref)
            #expect(abs(back.minX - f.minX) < 0.5)
            #expect(abs(back.minY - f.minY) < 0.5)
            #expect(abs(back.width - f.width) < 0.5)
            #expect(abs(back.height - f.height) < 0.5)
        }
    }

    /// Two displays side-by-side: main at origin, external to the right. The desktop union covers
    /// both, windows on either display normalize into the union's unit square, and denormalize
    /// round-trips back to the original AppKit frame.
    @Test func twoScreenUnionNormalizeDenormalizeRoundTrip() {
        // Main: 1440x900 at origin. External: 1920x1080 right of main, top-aligned at y=0 bottom-left
        // (AppKit global, bottom-left origin). Union bounding rect covers both.
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let union = main.union(external)
        #expect(union.origin == .zero)
        #expect(union.width == 3360)
        #expect(union.height == 1080)

        // Window on external display, centered.
        let winOnExternal = CGRect(x: 1440 + 300, y: 200, width: 600, height: 500)
        guard let nExt = LayoutMirrorService.normalize(frame: winOnExternal, to: union) else {
            Issue.record("expected normalize for external window")
            return
        }
        // x should be > main_width/union_width = 1440/3360 ≈ 0.4286.
        #expect(nExt.x > 0.42)
        #expect(nExt.x < 1.0)
        let backExt = LayoutMirrorService.denormalize(bridgeRect: nExt, to: union)
        #expect(abs(backExt.minX - winOnExternal.minX) < 0.5)
        #expect(abs(backExt.minY - winOnExternal.minY) < 0.5)
        #expect(abs(backExt.width - winOnExternal.width) < 0.5)
        #expect(abs(backExt.height - winOnExternal.height) < 0.5)

        // Window on main display round-trips too.
        let winOnMain = CGRect(x: 100, y: 100, width: 400, height: 300)
        guard let nMain = LayoutMirrorService.normalize(frame: winOnMain, to: union) else {
            Issue.record("expected normalize for main window")
            return
        }
        #expect(nMain.x >= 0 && nMain.x < 0.43)
        let backMain = LayoutMirrorService.denormalize(bridgeRect: nMain, to: union)
        #expect(abs(backMain.minX - winOnMain.minX) < 0.5)
        #expect(abs(backMain.minY - winOnMain.minY) < 0.5)

        // Per-screen rects normalize inside the union.
        guard
            let nMainScreen = LayoutMirrorService.normalize(frame: main, to: union),
            let nExtScreen = LayoutMirrorService.normalize(frame: external, to: union)
        else {
            Issue.record("expected normalize for per-screen rects")
            return
        }
        #expect(abs(nMainScreen.x - 0) < 1e-6)
        #expect(abs(nMainScreen.width - (1440.0 / 3360.0)) < 1e-6)
        #expect(abs(nExtScreen.x - (1440.0 / 3360.0)) < 1e-6)
        #expect(abs(nExtScreen.width - (1920.0 / 3360.0)) < 1e-6)
        // External is taller than main; main top-edge sits `(1080-900)/1080` below the union top.
        #expect(abs(nMainScreen.y - (180.0 / 1080.0)) < 1e-6)
        #expect(abs(nExtScreen.y - 0) < 1e-6)
    }
}

struct TmuxPaneCaptureTests {
    @Test func applyLineLimitKeepsTailLines() {
        let raw = "a\nb\nc\nd\ne"
        let (t, trunc) = TmuxPaneCapture.applyLineAndByteLimits(raw, lineLimit: 2)
        #expect(t == "d\ne")
        #expect(trunc == true)
    }

    @Test func applyLineLimitNoTruncationWhenFits() {
        let raw = "a\nb"
        let (t, trunc) = TmuxPaneCapture.applyLineAndByteLimits(raw, lineLimit: 10)
        #expect(t == "a\nb")
        #expect(trunc == false)
    }

    @Test func utf8ByteSuffixAsciiTail() {
        let s = String(repeating: "a", count: 500) + "ENDMARK"
        let (out, trunc) = TmuxPaneCapture.utf8ByteSuffix(s, maxBytes: 12)
        #expect(trunc == true)
        #expect(out.utf8.count <= 12)
        #expect(out.hasSuffix("RK") || out.hasSuffix("MARK"))
    }

    @Test func decodeClientMessageRequestTmuxPane() throws {
        let json = #"{"type":"requestTmuxPane","lines":200}"#
        let any = try decodeClientMessage(from: json)
        let r = any as? BridgeRequestTmuxPane
        #expect(r != nil)
        #expect(r?.lines == 200)
    }

    @Test func decodeClientMessageTranscribeChunk() throws {
        let json = #"{"type":"transcribe","format":"pcm_s16le_16000","base64":"qqo=","end":false}"#
        let any = try decodeClientMessage(from: json)
        let r = any as? BridgeTranscribe
        #expect(r != nil)
        #expect(r?.format == "pcm_s16le_16000")
        #expect(r?.end == false)
        #expect(r?.base64 == "qqo=")
    }

    @Test func decodeClientMessageTranscribeLive() throws {
        let json = #"{"type":"transcribeLive","text":"hello world"}"#
        let any = try decodeClientMessage(from: json)
        let r = any as? BridgeTranscribeLive
        #expect(r != nil)
        #expect(r?.text == "hello world")
    }
}
