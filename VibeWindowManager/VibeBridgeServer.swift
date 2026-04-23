//
//  VibeBridgeServer.swift
//  VibeWindowManager
//
//  WebSocket listener, layout push loop, and client message handling.
//

import AppKit
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
    private let stt = VibeSTTService()
    private var lastLayoutJSON: String?

    private var selectedId: String?
    private var lastWindows: [ManagedWindow] = []
    private var lastResolvedApp: NSRunningApplication?

    func start() {
        guard !isRunning else { return }
        lastError = nil
        axService = AXWindowLayoutService()
        guard axService.isProcessTrusted else {
            // #region agent log
            AgentDebugLog.log(hypothesisId: "H3", location: "VibeBridgeServer.start", message: "abort_not_trusted", data: [:])
            // #endregion
            lastError = "Enable Accessibility for VibeWindowManager first."
            return
        }
        do {
            // #region agent log
            AgentDebugLog.log(
                hypothesisId: "H3",
                location: "VibeBridgeServer.start",
                message: "listener_creating",
                data: [
                    "port": String(Self.defaultPort),
                    "bonjour": Self.bonjourType,
                ]
            )
            // #endregion
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
        // #region agent log
        let stateStr: String
        switch state {
        case .ready: stateStr = "ready"
        case .failed(let e): stateStr = "failed:\(e.localizedDescription)"
        case .cancelled: stateStr = "cancelled"
        case .setup: stateStr = "setup"
        case .waiting(let e): stateStr = "waiting:\(e.localizedDescription)"
        @unknown default: stateStr = "unknown"
        }
        AgentDebugLog.log(hypothesisId: "H3", location: "VibeBridgeServer.onListenerState", message: "state", data: ["state": stateStr])
        // #endregion
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
            }
        }
        RunLoop.main.add(t, forMode: .common)
        layoutTimer = t
    }

    private func pushLayoutIfNeeded() {
        axService = AXWindowLayoutService()
        guard axService.isProcessTrusted else { return }
        let apps = AppQueryResolver.runningRegularApps()
        guard let r = AppQueryResolver.resolve(query: appQuery, in: apps) else { return }
        if r.ambiguous { return }
        guard let app = r.app else { return }
        lastResolvedApp = app
        let ref: CGRect
        if let f = mirror.mainDisplayLayoutFrame() { ref = f }
        else { return }
        if ref.isEmpty { return }
        do {
            let wins = try mirror.windows(for: app)
            lastWindows = wins
            if let sid = selectedId, !wins.contains(where: { $0.id == sid }) { selectedId = wins.first?.id }
            if selectedId == nil { selectedId = wins.first?.id }
            guard
                let msg = mirror.layoutMessage(
                    seq: seq,
                    app: app,
                    ref: ref,
                    windows: wins,
                    selectedId: selectedId
                )
            else { return }
            seq &+= 1
            guard let data = try? encoder.encode(msg), let json = String(data: data, encoding: .utf8) else { return }
            if json == lastLayoutJSON { return }
            lastLayoutJSON = json
            broadcast(json)
        } catch { /* no-op */ }
    }

    private func adopt(_ c: NWConnection) {
        // #region agent log
        AgentDebugLog.log(hypothesisId: "H4", location: "VibeBridgeServer.adopt", message: "new_tcp", data: ["connections": String(connections.count)])
        // #endregion
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak wire] in
                wire?.sendJSONText(s)
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
        default:
            break
        }
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
            VibeFocusPaster.pasteClearText(text)
        } catch { lastError = error.localizedDescription }
    }

    private func runTranscribe(data: Data) {
        do {
            let tr = try decoder.decode(BridgeTranscribe.self, from: data)
            if let (text, err) = stt.process(base64: tr.base64, end: tr.end) {
                sendToAllConnections(BridgeTranscribeResult(text: text, error: err))
                if err == nil, !text.isEmpty { runPaste(text) }
            }
        } catch {
            sendToAllConnections(BridgeTranscribeResult(text: "", error: error.localizedDescription))
        }
    }
}
