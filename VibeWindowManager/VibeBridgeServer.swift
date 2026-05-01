//
//  VibeBridgeServer.swift
//  VibeWindowManager
//
//  WebSocket listener, layout push loop, and client message handling.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import Network

@MainActor
final class VibeBridgeServer: ObservableObject {
    private static let defaultPort: UInt16 = 19_842
    private static let bonjourType = "_vibewm._tcp"

    @Published var isRunning = false
    @Published var port: UInt16 = 0
    @Published var lastError: String?
    @Published var serviceName: String = Host.current().localizedName ?? "VibeWindowManager"
    /// App query (e.g. `ghostty`) for listing windows.
    @Published var appQuery: String = "ghostty"
    /// tmux target for `capture-pane -t` (e.g. `0` or `dev:0.0`); see README / PROTOCOL.
    @Published var tmuxTarget: String = UserDefaults.standard.string(forKey: "vibeBridgeTmuxTarget") ?? "" {
        didSet { UserDefaults.standard.set(tmuxTarget, forKey: "vibeBridgeTmuxTarget") }
    }

    private var listener: NWListener?
    private var connections: [UUID: VibeWireConnection] = [:]
    private var layoutTimer: Timer?
    private var seq: UInt64 = 0
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let decoder = JSONDecoder()
    private let mirror = LayoutMirrorService()
    private var axService = AXWindowLayoutService()
    private var transcribePcmBuffer = Data()
    private var lastLayoutJSON: String?
    private var tmuxSeq: UInt64 = 0
    private var lastTmuxTextForDedupe: String?

    private var lastMirrorAppListJSON: String?
    private var lastMirrorAppListFingerprint: String = ""
    private var mirrorAppListSeq: UInt64 = 0

    private var clientWantsWindowStream: Bool = false
    private var windowStreamRR: Int = 0
    private var windowStreamOutSeq: UInt64 = 0
    private var windowStreamInFlight: Bool = false
    /// Last `screencapture` bitmap size (pre-downscale) per window; iOS `nx,ny` are 0…1 in this aspect; can exceed `kCGWindowBounds` (e.g. shadow).
    private var lastStreamFullPixelSize: [String: CGSize] = [:]
    private static let windowStreamMaxW: CGFloat = 1120
    private static let windowStreamJPEGQ: Double = 0.58

    private var selectedId: String?
    private var lastWindows: [ManagedWindow] = []
    private var streamCalibration: VibeStreamCalibrationManager?
    private var lastResolvedApp: NSRunningApplication?
    /// What we last committed on the Mac from `transcribeLive` (only updated after a `runLiveReplace` completion).
    private var lastMacLiveText: String = ""
    /// Latest string from the phone; we apply `liveWanted` until it matches `lastMacLiveText`.
    private var liveWanted: String?
    /// True from `doOneLiveReplace` until the `runLiveReplace` completion runs.
    private var liveReplaceInFlight: Bool = false
    private var liveSessionPrimed: Bool = false
    private var livePrimeWork: DispatchWorkItem?

    func start() {
        guard !isRunning else { return }
        lastError = nil
        axService = AXWindowLayoutService()
        guard axService.isProcessTrusted else {
            lastError = "Enable Accessibility for VibeWindowManager first."
            return
        }
        do {
            guard let p = NWEndpoint.Port(rawValue: Self.defaultPort) else { return }
            let l = try NWListener(using: .tcp, on: p)
            l.service = NWListener.Service(name: serviceName, type: Self.bonjourType)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.onListenerState(state)
                }
            }
            l.newConnectionHandler = { [weak self] c in
                Task { @MainActor in
                    self?.adopt(c)
                }
            }
            l.start(queue: .main)
            listener = l
            isRunning = true
            port = Self.defaultPort
            startLayoutTimer()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func onListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            lastError = nil
        case .failed(let e):
            lastError = e.localizedDescription
            stop()
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    func stop() {
        streamCalibration?.hide()
        streamCalibration = nil
        lastLayoutJSON = nil
        layoutTimer?.invalidate()
        layoutTimer = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
    }

    private func startLayoutTimer() {
        layoutTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pushLayoutIfNeeded()
                self?.pushWindowStreamIfNeeded()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        layoutTimer = t
    }

    private func pushLayoutIfNeeded() {
        pushMirrorAppListIfNeeded()
        axService = AXWindowLayoutService()
        guard axService.isProcessTrusted else { return }
        let apps = AppQueryResolver.runningRegularApps()
        guard let r = AppQueryResolver.resolve(query: appQuery, in: apps) else { return }
        if r.ambiguous { return }
        guard let app = r.app else { return }
        lastResolvedApp = app
        let screens = NSScreen.screens
        guard let ref = mirror.desktopLayoutFrame(screens: screens), !ref.isEmpty else { return }
        let perScreen = mirror.screenLayoutFrames(screens: screens)
        do {
            var extra: [ManagedWindow] = []
            if let c = streamCalibration, c.isActive {
                try? c.refreshManaged(using: axService)
                if let m = c.managed { extra = [m] }
            }
            let wins = try mirror.windows(for: app)
            var merged: [ManagedWindow] = {
                if extra.isEmpty { return wins }
                var seen = Set(wins.map(\.id))
                var a = wins
                for w in extra where !seen.contains(w.id) {
                    a.append(w)
                    seen.insert(w.id)
                }
                return a
            }()
            // Match iOS/bridge: only windows that get a layout rect (not every AX "window" slot).
            let inLayout = LayoutMirrorService.windowsInLayoutRef(merged, ref: ref)
            lastWindows = inLayout
            if let sid = selectedId, !inLayout.contains(where: { $0.id == sid }) { selectedId = inLayout.first?.id }
            if selectedId == nil { selectedId = inLayout.first?.id }
            guard
                let msg = mirror.layoutMessage(
                    seq: seq,
                    app: app,
                    ref: ref,
                    perScreen: perScreen,
                    windows: wins,
                    additionalWindows: extra,
                    selectedId: selectedId
                )
            else { return }
            seq &+= 1
            guard let data = try? encoder.encode(msg), let json = String(data: data, encoding: .utf8) else { return }
            if json != lastLayoutJSON {
                lastLayoutJSON = json
                broadcast(json)
            }
        } catch {
            lastError = error.localizedDescription
        }
        tryPushCalibrationMessage()
    }

    private func tryPushCalibrationMessage() {
        guard let c = streamCalibration, c.isActive, !c.didBroadcastTarget else { return }
        guard let mw = c.managed, let ex = c.expectedBitmapFraction(ax: axService) else { return }
        let m = BridgeCalibrationTargetMessage(
            windowId: mw.id,
            expectNx: ex.nx,
            expectNy: ex.ny,
            sampleCount: c.sampleCount,
            sampleIndex: c.currentPresentationIndex
        )
        guard let d = try? encoder.encode(m), let s = String(data: d, encoding: .utf8) else { return }
        c.didBroadcastTarget = true
        selectedId = mw.id
        lastLayoutJSON = nil
        broadcast(s)
    }

    private func runOpenCalibrationTarget() {
        if streamCalibration == nil { streamCalibration = VibeStreamCalibrationManager() }
        if let c = streamCalibration {
            c.onRequestClose = { [weak self] in
                self?.runCloseCalibrationTarget()
            }
        }
        streamCalibration?.show()
        lastLayoutJSON = nil
    }

    private func runCloseCalibrationTarget() {
        streamCalibration?.hide()
        streamCalibration = nil
        lastLayoutJSON = nil
    }

    private func adopt(_ c: NWConnection) {
        let id = UUID()
        let wire = VibeWireConnection(
            c,
            label: "VibeWire.\(id.uuidString)"
        ) { [weak self] text in
            self?.handleClientJSON(text)
        } onClosed: { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = wire
        wire.start()
        if let d = try? encoder.encode(BridgeServerHello(version: 1, port: Self.defaultPort)),
            let s = String(data: d, encoding: .utf8) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak wire] in
                wire?.sendJSONText(s)
                guard let self else { return }
                // New clients need `mirrorAppList` even if the set of PIDs is unchanged.
                self.lastMirrorAppListJSON = nil
                self.pushMirrorAppListIfNeeded()
            }
        }
    }

    private func broadcast(_ json: String) {
        for w in connections.values { w.sendJSONText(json) }
    }

    private func sendToAllConnections(_ object: some Encodable) {
        guard let d = try? encoder.encode(object), let s = String(data: d, encoding: .utf8) else { return }
        broadcast(s)
    }

    private func handleClientJSON(_ s: String) {
        let data = Data(s.utf8)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let type = (obj["type"] as? String) ?? ""
        switch type {
        case BridgeMessageType.ping.rawValue:
            if let t = (try? decoder.decode(BridgePing.self, from: data))?.t {
                sendToAllConnections(BridgePong(t: t))
            }
        case BridgeMessageType.select.rawValue:
            if let w = (try? decoder.decode(BridgeSelect.self, from: data))?.windowId {
                selectedId = w
                runSelectFocus(to: w)
            }
        case BridgeMessageType.selectNext.rawValue:
            runSelectNext()
        case BridgeMessageType.pasteText.rawValue:
            if let t = (try? decoder.decode(BridgePasteText.self, from: data))?.text {
                runPaste(t)
            }
        case BridgeMessageType.transcribe.rawValue:
            runTranscribe(data: data)
        case BridgeMessageType.transcribeLive.rawValue:
            if let m = try? decoder.decode(BridgeTranscribeLive.self, from: data) {
                runTranscribeLive(m.text)
            }
        case BridgeMessageType.setWindowRect.rawValue:
            do {
                let msg = try decoder.decode(BridgeSetWindowRect.self, from: data)
                runSetWindowRect(windowId: msg.windowId, rect: msg.rect)
            } catch {
                let msg = "setWindowRect JSON: \(error.localizedDescription)"
                lastError = msg
                sendToAllConnections(BridgeErrorMessage(message: msg))
            }
        case BridgeMessageType.requestTmuxPane.rawValue:
            do {
                let msg = try decoder.decode(BridgeRequestTmuxPane.self, from: data)
                runRequestTmuxPane(requestedLines: msg.lines)
            } catch {
                let msg = "requestTmuxPane JSON: \(error.localizedDescription)"
                lastError = msg
                sendToAllConnections(BridgeErrorMessage(message: msg))
            }
        case BridgeMessageType.setMirrorAppQuery.rawValue:
            if let msg = try? decoder.decode(BridgeSetMirrorAppQuery.self, from: data) {
                let id = msg.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !id.isEmpty {
                    appQuery = id
                    lastLayoutJSON = nil
                    selectedId = nil
                    lastWindows = []
                }
            }
        case BridgeMessageType.setWindowStreamEnabled.rawValue:
            if let m = try? decoder.decode(BridgeSetWindowStreamEnabled.self, from: data) {
                clientWantsWindowStream = m.enabled
                if !m.enabled { windowStreamInFlight = false }
            }
        case BridgeMessageType.windowStreamClick.rawValue:
            if let m = try? decoder.decode(BridgeWindowStreamClick.self, from: data) {
                // #region agent log
                VibeAgentDebugLog.append(
                    hypothesisId: "H3",
                    location: "VibeBridgeServer.handleClientJSON:windowStreamClick",
                    message: "wire nx/ny as decoded from iPad",
                    data: ["windowId": m.windowId, "nx": m.nx, "ny": m.ny]
                )
                // #endregion
                runWindowStreamClick(windowId: m.windowId, nx: m.nx, ny: m.ny)
            }
        case BridgeMessageType.openCalibrationTarget.rawValue:
            if (try? decoder.decode(BridgeClientOpenCalibration.self, from: data)) != nil {
                runOpenCalibrationTarget()
            }
        case BridgeMessageType.closeCalibrationTarget.rawValue:
            if (try? decoder.decode(BridgeClientCloseCalibration.self, from: data)) != nil {
                runCloseCalibrationTarget()
            }
        default:
            break
        }
    }

    /// AppKit window frames / CG window bounds use **points**; screencapture JPEG pixel size must be divided by this.
    private static func screenBackingScale(containing p: CGPoint) -> CGFloat {
        for s in NSScreen.screens {
            if s.frame.contains(p) { return s.backingScaleFactor }
        }
        return NSScreen.main?.backingScaleFactor ?? 2.0
    }

    private func runWindowStreamClick(windowId: String, nx: Double, ny: Double) {
        if let c = streamCalibration, c.isActive {
            try? c.refreshManaged(using: axService)
            let isCalWindow =
                c.managed?.id == windowId
                || lastWindows.contains(where: { $0.id == windowId && $0.title == VibeStreamCalibrationManager.title })
            if isCalWindow {
                // #region agent log
                VibeAgentDebugLog.append(
                    hypothesisId: "H_cal",
                    location: "VibeBridgeServer.runWindowStreamClick:calibrationAdvance",
                    message: "cal window tap; no synthetic click to desktop",
                    data: ["windowId": windowId, "wireNx": nx, "wireNy": ny]
                )
                // #endregion
                c.advanceToNextTargetAfterIpadSample()
                lastLayoutJSON = nil
                tryPushCalibrationMessage()
                return
            }
        }
        guard let w = lastWindows.first(where: { $0.id == windowId }) else { return }
        // Each layout window may belong to a different app (e.g. mirrored Ghostty + bridge “Click calibration”).
        // Activating `lastResolvedApp` only was wrong for merged windows: clicks never hit the intended surface.
        let owningApp: NSRunningApplication
        var pid: pid_t = 0
        if AXUIElementGetPid(w.element, &pid) == .success, let a = NSRunningApplication(processIdentifier: pid) {
            owningApp = a
        } else if let fallback = lastResolvedApp {
            owningApp = fallback
        } else {
            return
        }
        do {
            try VibeFocusPaster.focus(window: w, app: owningApp)
        } catch {
            lastError = error.localizedDescription
            return
        }
        selectedId = windowId
        let nx2 = min(1, max(0, nx))
        let ny2 = min(1, max(0, ny))
        let axFrame = axService.readFrame(w.element)
        let winCgId = WindowStreamCapture.cgWindowID(fromBridgeWindowId: windowId)
        let boundsFromCG: CGRect? = winCgId.flatMap { WindowStreamCapture.globalBoundsForStreamClickMapping(cgWindowID: $0) }
        guard var frame = boundsFromCG ?? axFrame else { return }
        var mapSource = boundsFromCG != nil ? "cgWindow" : "ax"
        var halfOutsetX: CGFloat = 0
        var dHeightAnchorDown: CGFloat = 0
        if let ps = lastStreamFullPixelSize[windowId] {
            // `ps` is **device pixel** size of the screencapture JPEG. `frame` (CG/AX) is in **AppKit points**.
            // Comparing pixels to points (or mixing `ps.width` into `frame.origin`) skews Y/X on Retina and
            // can shove the mapped point off-screen — no cyan ring, clicks “too high” / on the wrong edge.
            let scale = Self.screenBackingScale(containing: CGPoint(x: frame.midX, y: frame.midY))
            let wPts = CGFloat(ps.width) / scale
            let hPts = CGFloat(ps.height) / scale
            let dW = wPts - frame.width
            let dH = hPts - frame.height
            // Small positive deltas: shadow / border around the window in the capture vs CG bounds.
            if dW > 0.5 {
                halfOutsetX = dW / 2
                frame.origin.x = frame.midX - wPts / 2
                frame.size.width = wPts
            }
            if dH > 0.5 {
                dHeightAnchorDown = dH
                let top = frame.maxY
                frame.size.height = hPts
                frame.origin.y = top - frame.height
            }
            if dW > 0.5 || dH > 0.5 {
                mapSource = boundsFromCG != nil ? "cgWindow+bitmapSize" : "ax+bitmapSize"
            }
        }
        let x = frame.minX + nx2 * frame.width
        let y = frame.maxY - ny2 * frame.height
        let point = CGPoint(x: x, y: y)
        // #region agent log
        let scr = NSScreen.screens.first { NSPointInRect(point, $0.frame) } ?? NSScreen.main
        let psw = lastStreamFullPixelSize[windowId].map { Double($0.width) } ?? 0
        let psh = lastStreamFullPixelSize[windowId].map { Double($0.height) } ?? 0
        VibeAgentDebugLog.append(
            hypothesisId: "H1_H2",
            location: "VibeBridgeServer.runWindowStreamClick:mappedPoint",
            message: "readFrame vs CGWindow for stream click mapping",
            data: [
                "windowId": windowId, "title": w.title, "mapSource": mapSource,
                "fullPixelW": psw, "fullPixelH": psh, "outsetHalfX": Double(halfOutsetX), "heightGrowDown": Double(dHeightAnchorDown),
                "wireNx": nx, "wireNy": ny, "clampedNx": nx2, "clampedNy": ny2,
                "frameMinX": frame.minX, "frameMinY": frame.minY, "frameW": frame.width, "frameH": frame.height, "frameMaxY": frame.maxY,
                "axFrameW": axFrame.map { Double($0.width) } ?? 0, "axFrameH": axFrame.map { Double($0.height) } ?? 0,
                "globalX": x, "globalY": y,
                "screenBacking": Double(scr?.backingScaleFactor ?? 0),
                "screenFrameW": Double(scr?.frame.size.width ?? 0)
            ]
        )
        // #endregion
        // Let the window server / app actually front the window before injecting a click (text fields, terminal, web).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            VibeFocusPaster.postLeftClickGlobal(point)
            VibeStreamClickRipple.show(at: point)
        }
    }

    private func pushWindowStreamIfNeeded() {
        guard clientWantsWindowStream, !connections.isEmpty, !lastWindows.isEmpty, !windowStreamInFlight else { return }
        let n = lastWindows.count
        let idx = windowStreamRR % n
        windowStreamRR &+= 1
        let wid = lastWindows[idx].id
        windowStreamInFlight = true
        let maxW = Self.windowStreamMaxW
        let q = Self.windowStreamJPEGQ
        Task.detached(priority: .userInitiated) {
            let (jpeg, err, fullPx) = WindowStreamCapture.captureJPEG(bridgeWindowId: wid, maxWidth: maxW, quality: q)
            let b64: String? = jpeg.map { $0.base64EncodedString() }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.windowStreamInFlight = false
                if let s = fullPx { self.lastStreamFullPixelSize[wid] = s }
                guard self.clientWantsWindowStream, !self.connections.isEmpty else { return }
                self.windowStreamOutSeq &+= 1
                let msg = BridgeWindowStreamMessage(
                    seq: self.windowStreamOutSeq,
                    windowId: wid,
                    format: "jpeg",
                    base64: b64,
                    error: err
                )
                guard let d = try? self.encoder.encode(msg), let s = String(data: d, encoding: .utf8) else { return }
                self.broadcast(s)
            }
        }
    }

    private static let mirrorListSkipBundleIds: Set<String> = [
        "com.thomasguntenaar.VibeWindowManager",
    ]

    private func runningAppsForMirrorList() -> [NSRunningApplication] {
        AppQueryResolver.runningRegularApps().filter { app in
            app.bundleIdentifier.map { !Self.mirrorListSkipBundleIds.contains($0) } ?? true
        }
    }

    private static func mirrorIconPNG48Base64(for app: NSRunningApplication) -> String? {
        guard let src = app.icon else { return nil }
        let s = NSSize(width: 48, height: 48)
        let img = NSImage(size: s)
        img.lockFocus()
        src.draw(in: NSRect(origin: .zero, size: s), from: .zero, operation: .copy, fraction: 1.0)
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return png.base64EncodedString()
    }

    private func pushMirrorAppListIfNeeded() {
        let apps = runningAppsForMirrorList()
        let fp = apps.map { "\($0.processIdentifier)" }.sorted().joined(separator: ",")
        let needRebuild = (fp != lastMirrorAppListFingerprint) || (lastMirrorAppListJSON == nil)
        if !needRebuild { return }
        lastMirrorAppListFingerprint = fp
        var items: [BridgeMirrorAppEntry] = []
        items.reserveCapacity(apps.count)
        for a in apps {
            let name = a.localizedName ?? "App"
            let bid = a.bundleIdentifier ?? "\(a.processIdentifier)"
            let ico = Self.mirrorIconPNG48Base64(for: a)
            items.append(BridgeMirrorAppEntry(name: name, bundleId: bid, iconPNGBase64: ico))
        }
        let msg = BridgeMirrorAppListMessage(seq: mirrorAppListSeq, apps: items)
        mirrorAppListSeq &+= 1
        guard let data = try? encoder.encode(msg), let json = String(data: data, encoding: .utf8) else { return }
        if json == lastMirrorAppListJSON { return }
        lastMirrorAppListJSON = json
        broadcast(json)
    }

    private func runRequestTmuxPane(requestedLines: Int?) {
        let target = tmuxTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty {
            tmuxSeq &+= 1
            sendToAllConnections(
                BridgeTmuxPaneMessage(
                    seq: tmuxSeq,
                    text: "",
                    error: "tmux target not configured (set it in the Mac app)",
                    truncated: false
                )
            )
            return
        }
        var lineLimit = TmuxPaneCapture.defaultLineLimit
        if let l = requestedLines, l > 0 {
            lineLimit = min(l, TmuxPaneCapture.maxLineLimit)
        }
        Task {
            let result = await TmuxPaneCapture.capturePane(target: target, lineLimit: lineLimit)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if result.error == nil, !result.text.isEmpty, result.text == self.lastTmuxTextForDedupe {
                    return
                }
                if result.error == nil {
                    self.lastTmuxTextForDedupe = result.text.isEmpty ? nil : result.text
                }
                self.tmuxSeq &+= 1
                self.sendToAllConnections(
                    BridgeTmuxPaneMessage(
                        seq: self.tmuxSeq,
                        text: result.text,
                        error: result.error,
                        truncated: result.truncated
                    )
                )
            }
        }
    }

    private static let remoteResizeMinWidth: CGFloat = 200
    private static let remoteResizeMinHeight: CGFloat = 120

    private func runSetWindowRect(windowId: String, rect: BridgeRect) {
        func fail(_ message: String) {
            lastError = message
            sendToAllConnections(BridgeErrorMessage(message: message))
        }
        guard let app = lastResolvedApp else {
            fail("setWindowRect: no resolved app (is the Mac bridge showing a layout?)")
            return
        }
        guard axService.isProcessTrusted else {
            fail("setWindowRect: Accessibility not granted for VibeWindowManager on the Mac")
            return
        }
        let screens = NSScreen.screens
        guard let ref = mirror.desktopLayoutFrame(screens: screens), !ref.isEmpty else {
            fail("setWindowRect: could not read desktop layout frame")
            return
        }
        let global = LayoutMirrorService.denormalize(bridgeRect: rect, to: ref)
        let clamped = Self.clampFrame(global, minW: Self.remoteResizeMinWidth, minH: Self.remoteResizeMinHeight)
        let wins: [ManagedWindow]
        do {
            wins = try mirror.windows(for: app)
        } catch {
            fail("setWindowRect: cannot list windows — \(error.localizedDescription)")
            return
        }
        guard let w = wins.first(where: { $0.id == windowId }) else {
            fail("setWindowRect: unknown window id \(windowId)")
            return
        }
        do {
            try axService.setFrame(w.element, clamped, allScreens: screens)
            selectedId = windowId
            lastLayoutJSON = nil
        } catch {
            let msg = error.localizedDescription
            lastError = msg
            sendToAllConnections(BridgeErrorMessage(message: msg))
        }
    }

    private static func clampFrame(_ r: CGRect, minW: CGFloat, minH: CGFloat) -> CGRect {
        var r = r
        if r.width < minW { r.size.width = minW }
        if r.height < minH { r.size.height = minH }
        return r
    }

    private func runSelectFocus(to id: String) {
        guard let app = lastResolvedApp,
              let w = lastWindows.first(where: { $0.id == id })
        else { return }
        do {
            try VibeFocusPaster.focus(window: w, app: app)
        } catch { lastError = error.localizedDescription }
    }

    private func runSelectNext() {
        guard !lastWindows.isEmpty else { return }
        let n = lastWindows.count
        let next: String
        if let s = selectedId, let i = lastWindows.firstIndex(where: { $0.id == s }) {
            next = lastWindows[(i + 1) % n].id
        } else {
            next = lastWindows[0].id
        }
        selectedId = next
        runSelectFocus(to: next)
    }

    private func runPaste(_ text: String) {
        guard let app = lastResolvedApp,
              let w = lastWindows.first(where: { $0.id == (selectedId ?? "") }) ?? lastWindows.first
        else { return }
        do {
            try VibeFocusPaster.focus(window: w, app: app)
            // Target must be key before synthetic Cmd+V; an immediate paste often goes nowhere.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                VibeFocusPaster.pasteClearText(text)
            }
        } catch { lastError = error.localizedDescription }
    }

    private func runTranscribeLive(_ text: String) {
        if text == lastMacLiveText, !liveReplaceInFlight, livePrimeWork == nil { return }
        liveWanted = text
        startLiveApplyIfIdle()
    }

    private func startLiveApplyIfIdle() {
        guard !liveReplaceInFlight, livePrimeWork == nil, let want = liveWanted, want != lastMacLiveText else { return }
        guard let app = lastResolvedApp,
              let w = lastWindows.first(where: { $0.id == (selectedId ?? "") }) ?? lastWindows.first
        else { return }
        do {
            try VibeFocusPaster.focus(window: w, app: app)
        } catch {
            lastError = error.localizedDescription
            return
        }
        if !liveSessionPrimed {
            liveSessionPrimed = true
            let item = DispatchWorkItem { [weak self] in
                self?.livePrimeWork = nil
                self?.doOneLiveReplace()
            }
            livePrimeWork = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        } else {
            doOneLiveReplace()
        }
    }

    private func doOneLiveReplace() {
        liveReplaceInFlight = true
        guard let want = liveWanted, want != lastMacLiveText else {
            liveReplaceInFlight = false
            startLiveApplyIfIdle()
            return
        }
        let prev = lastMacLiveText
        VibeFocusPaster.runLiveReplace(previous: prev, new: want) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Always match `lastMacLiveText` to the string we just installed; skipping here desyncs
                // the next backspace+paste and produces interleaved text (e.g. "It'It's …").
                self.lastMacLiveText = want
                self.liveReplaceInFlight = false
                if self.liveWanted != nil {
                    self.startLiveApplyIfIdle()
                }
            }
        }
    }

    private func clearOnMacIfLive() {
        guard !lastMacLiveText.isEmpty,
              let app = lastResolvedApp,
              let w = lastWindows.first(where: { $0.id == (selectedId ?? "") }) ?? lastWindows.first
        else { return }
        let prev = lastMacLiveText
        do {
            try VibeFocusPaster.focus(window: w, app: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                VibeFocusPaster.runLiveReplace(previous: prev, new: "") {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if self.lastMacLiveText == prev { self.lastMacLiveText = "" }
                    }
                }
            }
        } catch { lastError = error.localizedDescription }
    }

    private func runFinalOrClearAfterTranscribe(sttText: String, sttError: String?) {
        if liveReplaceInFlight {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.runFinalOrClearAfterTranscribe(sttText: sttText, sttError: sttError)
            }
            return
        }
        livePrimeWork?.cancel()
        livePrimeWork = nil
        liveSessionPrimed = false
        liveWanted = nil
        if let e = sttError, !e.isEmpty {
            if e.hasPrefix("STT:") { lastError = e }
            clearOnMacIfLive()
            lastMacLiveText = ""
            return
        }
        if sttText.isEmpty {
            clearOnMacIfLive()
            lastMacLiveText = ""
            return
        }
        guard let app = lastResolvedApp,
              let w = lastWindows.first(where: { $0.id == (selectedId ?? "") }) ?? lastWindows.first
        else { return }
        do {
            try VibeFocusPaster.focus(window: w, app: app)
            let prev = lastMacLiveText
            lastMacLiveText = ""
            let final = sttText + "\n"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                VibeFocusPaster.runLiveReplace(previous: prev, new: final)
            }
        } catch { lastError = error.localizedDescription }
    }

    /// Clears live-transcribe state and notifies the client that no audio was captured.
    private func finishTranscribeEmptyPcm() {
        if liveReplaceInFlight {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.finishTranscribeEmptyPcm()
            }
            return
        }
        livePrimeWork?.cancel()
        livePrimeWork = nil
        liveSessionPrimed = false
        liveWanted = nil
        clearOnMacIfLive()
        lastMacLiveText = ""
        sendToAllConnections(BridgeTranscribeResult(text: "", error: "No audio captured."))
    }

    private func runTranscribe(data: Data) {
        do {
            let tr = try decoder.decode(BridgeTranscribe.self, from: data)
            if !tr.base64.isEmpty, let chunk = Data(base64Encoded: tr.base64) {
                transcribePcmBuffer.append(chunk)
            }
            if !tr.end { return }
            let pcm = transcribePcmBuffer
            transcribePcmBuffer.removeAll(keepingCapacity: true)
            if pcm.isEmpty {
                if liveReplaceInFlight {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                        self?.finishTranscribeEmptyPcm()
                    }
                    return
                }
                finishTranscribeEmptyPcm()
                return
            }
            Task {
                let (text, err) = await VibeSTTService.transcribePcmS16leMono16k(pcm: pcm)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.sendToAllConnections(BridgeTranscribeResult(text: text, error: err))
                    self.runFinalOrClearAfterTranscribe(sttText: text, sttError: err)
                }
            }
        } catch {
            sendToAllConnections(BridgeTranscribeResult(text: "", error: error.localizedDescription))
        }
    }
}
