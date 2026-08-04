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

struct LSOFListenParserTests {
    /// Shape of real `lsof -nP -iTCP -sTCP:LISTEN -F pcLtPn` output on macOS:
    /// one node listening on 3000 over both families, a wildcard listener, a
    /// portless row and a descriptor block with no `n` line at all.
    static let fixture = """
    p101
    cnode
    Lthomas
    f23
    tIPv4
    PTCP
    n127.0.0.1:3000
    f24
    tIPv6
    PTCP
    n[::1]:3000
    p202
    cpython3.14
    Lthomas
    f7
    tIPv4
    PTCP
    n*:8787
    p303
    ccaddy
    Lroot
    f9
    tIPv4
    PTCP
    n*:*
    f10
    tIPv4
    PTCP
    f11
    tIPv6
    PTCP
    n[::]:443
    """

    @Test func parseReadsEveryListeningDescriptor() {
        let rows = LSOFListenParser.parse(Self.fixture)

        #expect(rows.count == 4)
        #expect(rows[0] == LSOFListenParser.Row(
            pid: 101, command: "node", user: "thomas", address: "127.0.0.1", port: 3000, family: "IPv4"
        ))
        #expect(rows[2] == LSOFListenParser.Row(
            pid: 202, command: "python3.14", user: "thomas", address: "*", port: 8787, family: "IPv4"
        ))
    }

    @Test func parseStripsIPv6Brackets() {
        let rows = LSOFListenParser.parse(Self.fixture)

        #expect(rows[1].address == "::1")
        #expect(rows[1].port == 3000)
        #expect(rows[1].family == "IPv6")
        #expect(rows[3].address == "::")
        #expect(rows[3].port == 443)
    }

    @Test func parseSkipsRowsWithoutANumericPort() {
        let rows = LSOFListenParser.parse(Self.fixture)

        // `n*:*` and the descriptor block with no `n` line both drop out; caddy
        // only survives through its :443 row.
        #expect(rows.filter { $0.pid == 303 }.map(\.port) == [443])
        #expect(LSOFListenParser.splitAddress("*:*")?.port == nil)
        #expect(LSOFListenParser.splitAddress("127.0.0.1")?.port == nil)
        #expect(LSOFListenParser.splitAddress(":3000")?.port == nil)
    }

    @Test func mergeProcessesFoldsEveryPortOfOnePidIntoOneRow() {
        // Docker's shape: one pid, a pile of ports, both families.
        var rows: [LSOFListenParser.Row] = []
        for port in [443, 80, 51001, 8080] {
            rows.append(.init(pid: 88, command: "com.docker.backend", user: "t", address: "*", port: port, family: "IPv4"))
            rows.append(.init(pid: 88, command: "com.docker.backend", user: "t", address: "::", port: port, family: "IPv6"))
        }
        rows.append(.init(pid: 101, command: "node", user: "t", address: "127.0.0.1", port: 3000, family: "IPv4"))

        let listeners = LSOFListenParser.mergeProcesses(rows)

        #expect(listeners.count == 2)
        let docker = listeners.first { $0.pid == 88 }
        #expect(docker?.ports == [80, 443, 8080, 51001])
        #expect(docker?.addresses == ["*", "::"])
        #expect(docker?.command == "com.docker.backend")
        // Ordered by lowest port, so Docker's :80 sorts ahead of node's :3000.
        #expect(listeners.map(\.pid) == [88, 101])
    }

    @Test func mergeProcessesMergesIPv4AndIPv6OfTheSamePort() {
        let listeners = LSOFListenParser.mergeProcesses(LSOFListenParser.parse(Self.fixture))

        #expect(listeners.count == 3)
        #expect(listeners.first { $0.pid == 101 }?.ports == [3000])
        #expect(listeners.first { $0.pid == 101 }?.addresses == ["127.0.0.1", "::1"])
    }
}

struct LSOFWorkingDirectoryParserTests {
    /// Real `lsof -a -p … -d cwd -Fn` output: a `p` line, an `fcwd` line the
    /// parser ignores, and the path.
    static let fixture = """
    p653
    fcwd
    n/
    p17832
    fcwd
    n/Users/thomas/Developer/personal/sayso/bridge
    p20275
    fcwd
    n/private/tmp/claude-501/session/scratchpad/pilot
    p99999
    fcwd
    """

    @Test func parseReadsOneDirectoryPerPID() {
        let directories = LSOFWorkingDirectoryParser.parse(Self.fixture)

        #expect(directories.count == 3)
        #expect(directories[653] == "/")
        #expect(directories[17832] == "/Users/thomas/Developer/personal/sayso/bridge")
        #expect(directories[20275] == "/private/tmp/claude-501/session/scratchpad/pilot")
        // A pid whose cwd lsof could not read simply has no entry.
        #expect(directories[99999] == nil)
    }
}

struct ProcessUptimeFormatterTests {
    @Test func nilStartRendersDash() {
        #expect(ProcessUptimeFormatter.text(since: nil, now: Date()) == "—")
    }

    @Test func secondsMinutesAndHours() {
        let now = Date()
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(-18), now: now) == "18s")
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(-42 * 60), now: now) == "42m")
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(-(5 * 3600 + 2 * 60)), now: now) == "5h 2m")
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(-5 * 3600), now: now) == "5h")
    }

    @Test func multiDayUptime() {
        let now = Date()
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(-(3 * 86_400 + 17 * 3600)), now: now) == "3d 17h")
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(-2 * 86_400), now: now) == "2d")
    }

    @Test func clockSkewNeverGoesNegative() {
        let now = Date()
        #expect(ProcessUptimeFormatter.text(since: now.addingTimeInterval(120), now: now) == "0s")
    }
}

struct LocalServerProcessTests {
    @Test func memoryTextFormatsResidentSize() {
        // ps reports rss in kilobytes; the service multiplies by 1024 before it gets here.
        #expect(LocalServerProcess.memoryText(30_576 * 1024).hasSuffix("MB"))
        #expect(LocalServerProcess.memoryText(531_136 * 1024).hasSuffix("MB"))
        #expect(LocalServerProcess.memoryText(4_000_000_000).hasSuffix("GB"))
        // Unknown or nonsense sizes must not render as "0 bytes".
        #expect(LocalServerProcess.memoryText(nil) == "—")
        #expect(LocalServerProcess.memoryText(0) == "—")
    }

    @Test func memoryTextIsDashWhenPsGaveNothing() {
        let server = LocalServerProcess(
            pid: 42, ports: [8080], bindAddresses: ["127.0.0.1"], command: "node", user: "t"
        )
        #expect(server.residentBytes == nil)
        #expect(server.memoryText == "—")
    }

    @Test func displayNamePrefersMeaningfulArgvTokens() {
        #expect(LocalServerProcess.displayName(
            command: "node",
            commandLine: "/opt/homebrew/bin/node /Users/t/app/node_modules/.bin/next dev"
        ) == "node — next dev")

        #expect(LocalServerProcess.displayName(
            command: "python3.14",
            commandLine: "/opt/homebrew/bin/python3.14 -m http.server 8787"
        ) == "python3.14 — http.server")
    }

    @Test func displayNameFallsBackToCommand() {
        #expect(LocalServerProcess.displayName(command: "rapportd", commandLine: "/usr/libexec/rapportd") == "rapportd")
        #expect(LocalServerProcess.displayName(command: "node", commandLine: "") == "node")
        // Every argument is a flag, so nothing is worth appending.
        #expect(LocalServerProcess.displayName(command: "caddy", commandLine: "/usr/bin/caddy --config -") == "caddy")
    }

    @Test func displayNameStaysShort() {
        let long = LocalServerProcess.displayName(
            command: "node",
            commandLine: "/usr/bin/node /srv/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ccc"
        )

        #expect(long.count <= LocalServerProcess.displayNameLimit)
        #expect(long.hasSuffix("…"))
    }

    @Test func bindAddressFlagsAndIdentity() {
        let loopback = LocalServerProcess(
            pid: 101, ports: [3000], bindAddresses: ["127.0.0.1", "::1"],
            command: "node", user: "thomas"
        )
        let exposed = LocalServerProcess(
            pid: 202, ports: [8787], bindAddresses: ["*"],
            command: "python3.14", user: "thomas"
        )

        // One row per process now, so the identity is just the pid.
        #expect(loopback.id == 101)
        #expect(loopback.isLoopbackOnly)
        #expect(!loopback.isExposedToNetwork)
        #expect(!exposed.isLoopbackOnly)
        #expect(exposed.isExposedToNetwork)
    }

    @Test func portsAreSortedAndDeduped() {
        let docker = LocalServerProcess(
            pid: 88, ports: [443, 80, 443, 51001, 8080], bindAddresses: ["*"],
            command: "com.docker.backend", user: "thomas"
        )

        #expect(docker.ports == [80, 443, 8080, 51001])
    }

    @Test func primaryPortPrefersANonEphemeralPort() {
        let cursorHelper = LocalServerProcess(
            pid: 3902, ports: [58387, 35223], bindAddresses: ["127.0.0.1"],
            command: "Cursor Helper (Plugin)", user: "thomas"
        )
        let docker = LocalServerProcess(
            pid: 88, ports: [51001, 80, 443], bindAddresses: ["*"],
            command: "com.docker.backend", user: "thomas"
        )

        // Nothing under the ephemeral floor, so the lowest port stands in.
        #expect(cursorHelper.primaryPort == 35223)
        #expect(cursorHelper.namedPorts.isEmpty)
        #expect(cursorHelper.ephemeralPorts == [35223, 58387])
        // 80 is what a human would have typed; 51001 is the kernel's doing.
        #expect(docker.primaryPort == 80)
        #expect(docker.namedPorts == [80, 443])
        #expect(docker.ephemeralPorts == [51001])
        #expect(docker.isLikelyHTTP)
    }

    @Test func primaryPortSurvivesAnEmptyPortList() {
        let empty = LocalServerProcess(pid: 1, ports: [], bindAddresses: [], command: "x", user: "thomas")

        #expect(empty.primaryPort == 0)
        #expect(!empty.isLikelyHTTP)
    }
}

struct ServerCategoryTests {
    @Test func orderIsScratchFirstAndSelfLast() {
        #expect(ServerCategory.allCases.sorted() == [.scratch, .devServer, .devTool, .app, .system, .selfApp])
        #expect(ServerCategory.scratch < ServerCategory.system)
    }

    @Test func backgroundAndKillableFlags() {
        #expect(ServerCategory.allCases.filter(\.isBackground) == [.app, .system, .selfApp])
        #expect(ServerCategory.allCases.filter { !$0.isKillable } == [.selfApp])
        #expect(ServerCategory.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbolName.isEmpty })
    }
}

/// Every branch of the classifier, checked against processes that were really
/// listening on this Mac when the rules were written.
struct ServerClassifierTests {
    static let home = NSHomeDirectory()
    static let pyenv = "\(home)/.pyenv/versions/3.12.1/bin/python3"

    static func classify(
        command: String,
        commandLine: String,
        workingDirectory: String? = nil,
        user: String = "thomas",
        isSelf: Bool = false
    ) -> ServerCategory {
        ServerClassifier.category(
            command: command,
            commandLine: commandLine,
            executablePath: ServerClassifier.firstPathToken(in: commandLine),
            workingDirectory: workingDirectory,
            user: user,
            isSelf: isSelf
        )
    }

    @Test func selfWinsOverEverythingElse() {
        #expect(Self.classify(
            command: "VibeWindowManager",
            commandLine: "/Applications/VibeWindowManager.app/Contents/MacOS/VibeWindowManager",
            isSelf: true
        ) == .selfApp)
    }

    @Test func toolchainBinariesBeatTheirProjectWorkingDirectory() {
        // THE ordering trap: adb's cwd is a real checkout, but adb is not that
        // project's dev server — rule 2 has to fire before the cwd rules.
        #expect(Self.classify(
            command: "adb",
            commandLine: "adb -L tcp:5037 fork-server server --reply-fd 4",
            workingDirectory: "\(Self.home)/Developer/yourcollegecontact/college-contact-mobile"
        ) == .devTool)

        // Same trap the other way round: Docker lives in an .app bundle, but it
        // is tooling, not an app.
        #expect(Self.classify(
            command: "com.docker.backend",
            commandLine: "/Applications/Docker.app/Contents/MacOS/com.docker.backend services"
        ) == .devTool)
    }

    @Test func appleDaemonsAndNetworkExtensionsAreSystem() {
        #expect(Self.classify(command: "rapportd", commandLine: "/usr/libexec/rapportd") == .system)
        #expect(Self.classify(
            command: "ControlCenter",
            commandLine: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        ) == .system)
        // An .appex inside a third-party bundle is still a system extension.
        #expect(Self.classify(
            command: "IPNExtension",
            commandLine: "/Applications/Tailscale.app/Contents/PlugIns/IPNExtension.appex/Contents/MacOS/IPNExtension"
        ) == .system)
    }

    @Test func scratchDirectoriesOutrankEverythingBelowThem() {
        #expect(Self.classify(
            command: "python3.12",
            commandLine: "\(Self.pyenv) /tmp/corsserve.py 8765 /private/tmp/session/scratchpad/pilot",
            workingDirectory: "/private/tmp/claude-501/session/scratchpad/pilot/evaluating_roi"
        ) == .scratch)

        // A `/scratchpad` component anywhere counts, even off a non-tmp parent.
        #expect(Self.classify(
            command: "python3.12",
            commandLine: "\(Self.pyenv) serve.py",
            workingDirectory: "\(Self.home)/Library/Caches/agent/scratchpad/run-4"
        ) == .scratch)
    }

    @Test func scratchWinsFromAnArgvPathEvenWhenTheCwdIsAProject() {
        // logserve.py: cwd is a real checkout, but the script itself lives in
        // /tmp — it is a one-off, not that project's server.
        #expect(Self.classify(
            command: "python3.12",
            commandLine: "\(Self.pyenv) /tmp/logserve.py 8766 /tmp/cookielog.txt",
            workingDirectory: "\(Self.home)/Developer/yourcollegecontact/submagic-pipeline"
        ) == .scratch)
    }

    @Test func scratchRootsMatchOnPathComponents() {
        #expect(ServerClassifier.isUnder("/tmp/logserve.py", root: "/tmp"))
        #expect(ServerClassifier.isUnder("/tmp", root: "/tmp"))
        // `/tmpfoo` is not in /tmp.
        #expect(!ServerClassifier.isUnder("/tmpfoo/x", root: "/tmp"))
        #expect(ServerClassifier.scratchRoot(
            commandLine: "\(Self.pyenv) /tmp/logserve.py", executablePath: Self.pyenv, workingDirectory: nil
        ) == "/tmp")
        #expect(ServerClassifier.scratchRoot(
            commandLine: "\(Self.pyenv) -m http.server", executablePath: Self.pyenv,
            workingDirectory: "/private/tmp/session/scratchpad"
        ) == "/private/tmp")
        #expect(ServerClassifier.scratchRoot(
            commandLine: "node server.js", executablePath: nil, workingDirectory: "\(Self.home)/Developer/x"
        ) == nil)
    }

    @Test func checkoutsAreDevServers() {
        #expect(Self.classify(
            command: "python3.12",
            commandLine: "\(Self.home)/Developer/personal/sayso/bridge/.venv/bin/python3 -m sayso_bridge",
            workingDirectory: "\(Self.home)/Developer/personal/sayso/bridge"
        ) == .devServer)

        #expect(Self.classify(
            command: "python3.12",
            commandLine: "\(Self.pyenv) -m http.server -d public 8899",
            workingDirectory: "\(Self.home)/Developer/personal/thomasguntenaar.com"
        ) == .devServer)
    }

    @Test func appBundlesAndElectronHelpersAreApps() {
        #expect(Self.classify(command: "Spotify", commandLine: "/Applications/Spotify.app/Contents/MacOS/Spotify") == .app)
        #expect(Self.classify(
            command: "Raycast", commandLine: "/Applications/Raycast.app/Contents/MacOS/Raycast UPDATED_VERSION AUTOMATIC_UPDATE"
        ) == .app)
        // Bundle path with a space in it: argv[0] comes back truncated, so the
        // full command line has to carry the match.
        #expect(Self.classify(
            command: "figma_agent",
            commandLine: "\(Self.home)/Library/Application Support/Figma/FigmaAgent.app/Contents/MacOS/figma_agent"
        ) == .app)
        // Chromium helpers report no argv[0] path at all.
        #expect(Self.classify(
            command: "Cursor Helper (Plugin)",
            commandLine: "Cursor Helper (Plugin): extension-host (user) yourcollegecontact [13-107]"
        ) == .app)
    }

    @Test func unknownDaemonsFallBackToDevTooling() {
        #expect(Self.classify(command: "caddy", commandLine: "/opt/homebrew/bin/caddy run") == .devTool)
        #expect(Self.classify(command: "", commandLine: "") == .devTool)
    }

    @Test func projectNamePrefersTheGitRoot() {
        // sayso's checkout root is one level above the cwd.
        let name = ServerClassifier.projectName(
            workingDirectory: "\(Self.home)/Developer/personal/sayso/bridge",
            gitRoot: { _ in "\(Self.home)/Developer/personal/sayso" }
        )
        #expect(name == "sayso")
    }

    @Test func projectNameFallsBackToTheWorkingDirectory() {
        #expect(ServerClassifier.projectName(
            workingDirectory: "\(Self.home)/Developer/personal/thomasguntenaar.com", gitRoot: { _ in nil }
        ) == "thomasguntenaar.com")
        #expect(ServerClassifier.projectName(workingDirectory: nil, gitRoot: { _ in nil }) == nil)
        #expect(ServerClassifier.projectName(workingDirectory: "/", gitRoot: { _ in nil }) == nil)
    }

    @Test func gitRootWalksUpWithFileManagerOnly() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-gitroot-\(UUID().uuidString)")
        let nested = base.appendingPathComponent("packages/api/src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(ServerClassifier.gitRoot(for: nested.path) == nil)

        try FileManager.default.createDirectory(
            at: base.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        #expect(ServerClassifier.gitRoot(for: nested.path) == base.standardizedFileURL.path)
    }

    @Test func knownPortNames() {
        #expect(ServerClassifier.knownPortName(7000) == "AirPlay Receiver")
        #expect(ServerClassifier.knownPortName(5000) == "AirPlay Receiver")
        #expect(ServerClassifier.knownPortName(5037) == "adb")
        #expect(ServerClassifier.knownPortName(59374) == "Handoff")
        #expect(ServerClassifier.knownPortName(11434) == "Ollama")
        #expect(ServerClassifier.knownPortName(8899) == nil)
    }

    @Test func ephemeralFloorIsThirtyTwoK() {
        #expect(ServerClassifier.ephemeralPortFloor == 32_768)
    }
}

struct LocalServerSubtitleTests {
    @Test func devServerNamesItsProject() {
        let sayso = LocalServerProcess(
            pid: 17832, ports: [8765], bindAddresses: ["127.0.0.1"], command: "python3.12", user: "thomas",
            category: .devServer, projectName: "sayso"
        )

        #expect(sayso.subtitle == "Dev server · sayso")
    }

    @Test func scratchNamesTheScratchRoot() {
        let corsserve = LocalServerProcess(
            pid: 20275, ports: [8765], bindAddresses: ["*"], command: "python3.12", user: "thomas",
            commandLine: "/usr/bin/python3 /tmp/corsserve.py 8765",
            workingDirectory: "/private/tmp/session/scratchpad/pilot",
            category: .scratch
        )

        #expect(corsserve.subtitle == "Temporary script · /private/tmp")
    }

    @Test func devToolNamesItsBinary() {
        let adb = LocalServerProcess(
            pid: 64728, ports: [5037], bindAddresses: ["127.0.0.1"], command: "adb", user: "thomas",
            category: .devTool
        )

        #expect(adb.subtitle == "Dev tooling · adb")
    }

    @Test func systemServiceNamesItsKnownPort() {
        let controlCenter = LocalServerProcess(
            pid: 12983, ports: [7000, 5000], bindAddresses: ["*"], command: "ControlCenter", user: "thomas",
            category: .system
        )
        let tailscale = LocalServerProcess(
            pid: 1643, ports: [34945, 60077], bindAddresses: ["*"], command: "IPNExtension", user: "thomas",
            category: .system
        )

        #expect(controlCenter.subtitle == "macOS service · AirPlay Receiver")
        // No known port, so the tier name is all there is to say.
        #expect(tailscale.subtitle == "macOS service")
    }

    @Test func appsAndSelfFallBackToTheTierName() {
        let spotify = LocalServerProcess(
            pid: 22005, ports: [57621], bindAddresses: ["*"], command: "Spotify", user: "thomas", category: .app
        )
        let selfApp = LocalServerProcess(
            pid: 28522, ports: [51000], bindAddresses: ["127.0.0.1"], command: "VibeWindowManager", user: "thomas",
            category: .selfApp
        )

        #expect(spotify.subtitle == "App")
        #expect(selfApp.subtitle == "This app")
    }
}

struct LocalServerRankingTests {
    static func server(
        _ pid: pid_t, _ category: ServerCategory, ports: [Int] = [3000], ageHours: Double = 1
    ) -> LocalServerProcess {
        LocalServerProcess(
            pid: pid, ports: ports, bindAddresses: ["127.0.0.1"], command: "p\(pid)", user: "thomas",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 - ageHours * 3600),
            category: category
        )
    }

    @Test func categoryComesFirstAndBackgroundSinksToTheBottom() {
        let ranked = LocalServerProcess.rank([
            Self.server(5, .selfApp),
            Self.server(4, .system),
            Self.server(3, .app),
            Self.server(2, .devTool),
            Self.server(1, .devServer),
            Self.server(0, .scratch),
        ])

        #expect(ranked.map(\.pid) == [0, 1, 2, 3, 4, 5])
    }

    @Test func uptimeDescendsInsideATier() {
        // A dev server up for three days outranks one started a minute ago.
        let ranked = LocalServerProcess.rank([
            Self.server(10, .devServer, ports: [3000], ageHours: 0.02),
            Self.server(11, .devServer, ports: [9999], ageHours: 72),
            Self.server(12, .devServer, ports: [4000], ageHours: 5),
        ])

        #expect(ranked.map(\.pid) == [11, 12, 10])
    }

    @Test func primaryPortBreaksTiesAfterUptime() {
        let ranked = LocalServerProcess.rank([
            Self.server(20, .devTool, ports: [8080], ageHours: 3),
            Self.server(21, .devTool, ports: [40000, 3306], ageHours: 3),
            Self.server(22, .devTool, ports: [59000], ageHours: 3),
        ])

        // 3306 is the non-ephemeral port of pid 21, so it leads; pid 22 only has
        // an ephemeral one, which still sorts as its primary.
        #expect(ranked.map(\.pid) == [21, 20, 22])
    }

    @Test func unknownStartTimeSortsAsYoungest() {
        let unknown = LocalServerProcess(
            pid: 30, ports: [3000], bindAddresses: ["*"], command: "x", user: "thomas", category: .devServer
        )
        let ranked = LocalServerProcess.rank([unknown, Self.server(31, .devServer, ageHours: 0.001)])

        #expect(ranked.map(\.pid) == [31, 30])
    }

    @Test func rankedAndBackgroundSplitOnTheCategoryFlag() {
        let all = [
            Self.server(0, .scratch), Self.server(1, .devServer), Self.server(2, .devTool),
            Self.server(3, .app), Self.server(4, .system), Self.server(5, .selfApp),
        ]

        #expect(all.filter { !$0.category.isBackground }.map(\.pid) == [0, 1, 2])
        #expect(all.filter { $0.category.isBackground }.map(\.pid) == [3, 4, 5])
    }
}
