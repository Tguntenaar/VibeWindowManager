//
//  ContentView.swift
//  VibeWindowManager
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import AppKit
import SwiftUI

private enum MainTab: Hashable {
    case layout
    case bridge
    case away
}

enum LayoutProposal: Hashable {
    case tile(TileMode)
    case cascade

    var label: String {
        switch self {
        case .tile(let mode):
            return mode.label
        case .cascade:
            return "Cascade"
        }
    }
}

struct ContentView: View {
    @StateObject private var bridge = VibeBridgeServer()
    @State private var service = AXWindowLayoutService()
    @State private var runningApps: [AppChoice] = []
    @State private var windows: [ManagedWindow] = []
    @State private var selectedAppPID: pid_t?
    @State private var screenIndex: Int = 0
    @State private var selectedProposal: LayoutProposal?
    @State private var cascadeInsetStep: Double = CascadeDefaults.insetStep
    @State private var lastError: String?
    @State private var tailnetSelf: TailscaleSelfStatus?
    @State private var tailnetChecked: Bool = false
    @State private var primaryLANIPv4: LANIPv4Enumerator.Entry?
    @AppStorage("vibeWhisperBinaryPath") private var whisperBinaryPath: String = ""
    @AppStorage("vibeWhisperModelPath") private var whisperModelPath: String = ""
    @AppStorage("vibeWhisperLanguage") private var whisperLanguage: String = "en"
    @AppStorage("vibeWhisperOpenAIPip") private var useOpenAIWhisperPip: Bool = true
    @State private var mainTab: MainTab = .layout
    @State private var networkSectionExpanded: Bool = true
    @State private var sttSectionExpanded: Bool = false
    @State private var displayConfigurationRevision: Int = 0

    var body: some View {
        TabView(selection: $mainTab) {
            layoutTab
                .tag(MainTab.layout)
                .tabItem { Label("Layout", systemImage: "rectangle.split.2x1") }
            bridgeTab
                .tag(MainTab.bridge)
                .tabItem { Label("iOS bridge", systemImage: "antenna.radiowaves.left.and.right") }
            awayTab
                .tag(MainTab.away)
                .tabItem { Label("Away", systemImage: "display.2") }
        }
        .tabViewStyle(.automatic)
        .background {
            LinearGradient(
                colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear {
            refreshAppsList()
            refreshStatus()
            refreshWindows()
            refreshNetworkHints()
            if !bridge.isRunning {
                bridge.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service = AXWindowLayoutService()
            refreshAppsList()
            refreshWindows()
            refreshNetworkHints()
        }
        .onChange(of: selectedAppPID) { _, _ in
            refreshWindows()
        }
        .onChange(of: screenIndex) { _, _ in
            normalizeSelectedProposal()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displayConfigurationRevision &+= 1
        }
        .onChange(of: mainTab) { _, new in
            if new == .away { refreshNetworkHints() }
        }
    }

    @ViewBuilder
    private var layoutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                layoutHeaderRow
                layoutTargetCard
                layoutProposalsCard
                layoutPreviewCard
                if let e = lastError {
                    Text(e)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var layoutHeaderRow: some View {
        let trusted = service.isProcessTrusted
        let stageOn = StageManagerSupport.isEnabled
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Arrange windows")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Group {
                        if trusted {
                            Label("Accessibility granted", systemImage: "checkmark.circle.fill")
                        } else {
                            Label("Accessibility required", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(trusted ? Color.green.opacity(0.14) : Color.orange.opacity(0.14))
                    )
                    Text(stageOn ? "Stage Manager on" : "Stage Manager off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
            }
            Spacer(minLength: 12)
            Menu {
                Button("Request accessibility…") {
                    service.requestAccessibilityIfNeeded()
                    refreshStatus()
                    refreshWindows()
                }
                Button("Open Accessibility settings") {
                    openAccessibilitySettings()
                }
            } label: {
                Label("Access", systemImage: "lock.shield")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.large)
            Button {
                service = AXWindowLayoutService()
                refreshAppsList()
                refreshWindows()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var layoutTargetCard: some View {
        let screens = availableScreens()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Target")
                .font(.headline)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("App")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Click an app to list its windows.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    RunningAppIconGrid(apps: runningApps, selectedPID: $selectedAppPID)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Click a screen to choose where to apply layouts.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    DisplayArrangementMap(
                        screens: screens,
                        selectedIndex: $screenIndex,
                        label: screenLabel
                    )
                    .id(displayConfigurationRevision)
                    if !screens.isEmpty, screenIndex < screens.count {
                        Text("Selected: \(screenLabel(screens[screenIndex], index: screenIndex))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var layoutProposalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested layouts")
                .font(.headline)
            Text(splitSummaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if availableProposals.isEmpty {
                Text("Grant Accessibility and select an app to inspect its windows.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 100, maximum: 132), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(availableProposals, id: \.self) { proposal in
                        LayoutProposalThumbnail(
                            proposal: proposal,
                            windowCount: max(1, windows.count),
                            isSelected: selectedProposal == proposal
                        ) {
                            selectedProposal = proposal
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    @ViewBuilder
    private var layoutPreviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview & apply")
                .font(.headline)
            if let preview = currentPreviewLayout, let visibleFrame = screenLayoutRect() {
                HStack(alignment: .top, spacing: 16) {
                    LayoutPreviewView(
                        visibleFrame: visibleFrame,
                        frames: preview.frames,
                        windows: windows
                    )
                    .frame(minWidth: 360, idealWidth: 420, minHeight: 250, idealHeight: 290)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Window order")
                            .font(.subheadline.weight(.semibold))
                        Text("The top row maps to the first region in the preview.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if selectedProposal == .cascade {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Cascade offset")
                                    Spacer()
                                    Text("\(Int(cascadeInsetStep)) pt")
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $cascadeInsetStep, in: 0...120, step: 1)
                            }
                        }

                        if windows.isEmpty {
                            Text("No movable windows detected.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                        HStack(spacing: 8) {
                                            Text("\(index + 1).")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                                .frame(width: 20, alignment: .trailing)
                                            Text(window.title)
                                                .lineLimit(1)
                                            Spacer()
                                            Button {
                                                moveWindow(from: index, offset: -1)
                                            } label: {
                                                Image(systemName: "arrow.up")
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(index == 0)
                                            Button {
                                                moveWindow(from: index, offset: 1)
                                            } label: {
                                                Image(systemName: "arrow.down")
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(index == windows.count - 1)
                                        }
                                        .padding(.vertical, 6)
                                        if index < windows.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                        }

                        Button {
                            applySelectedProposal()
                        } label: {
                            Label("Apply \(preview.proposal.label)", systemImage: "checkmark.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(preview.frames.isEmpty || windows.isEmpty)
                    }
                    .frame(minWidth: 260, alignment: .leading)
                }
            } else {
                Text("Choose a layout above to preview regions, then reorder windows and apply.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }

    @ViewBuilder
    private var bridgeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("iOS layout bridge")
                        .font(.title2.weight(.semibold))
                    Text("Mirrors layout to the iPhone or iPad app. On the same LAN, the device can discover this Mac via Bonjour, or use a manual WebSocket URL.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Connection")
                                .font(.headline)
                            Text("Manual URL if needed: `ws://192.168.x.x:\(bridgeWebSocketPort)/bridge`")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Mirror app")
                                    .font(.subheadline.weight(.medium))
                                Text("Layout from that app is mirrored to the phone.")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                BridgeAppQueryIconRow(
                                    apps: runningApps.filter { !$0.isPlaceholder },
                                    appQuery: $bridge.appQuery
                                )
                            }
                            TextField("tmux target (e.g. 0, mysess:0.0)", text: $bridge.tmuxTarget)
                                .textFieldStyle(.roundedBorder)
                            Text("Must match `tmux list-sessions` / `list-windows`.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing) {
                            Toggle("Server on", isOn: Binding(
                                get: { bridge.isRunning },
                                set: { on in
                                    if on { bridge.start() } else { bridge.stop() }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.large)
                        }
                    }
                    if let e = bridge.lastError {
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)

                DisclosureGroup(isExpanded: $networkSectionExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        localIPv4Row
                        tailnetHostRow
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Network & discovery", systemImage: "network")
                        .font(.headline)
                }
                .padding(14)
                .background(cardBackground)

                DisclosureGroup(isExpanded: $sttSectionExpanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("iPhone can send audio from a tile; this Mac runs Whisper and types into the frontmost window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("OpenAI Whisper (pip: openai-whisper)", isOn: $useOpenAIWhisperPip)
                        Text(
                            useOpenAIWhisperPip
                            ? "Binary: `which whisper` in Terminal. Model name: base, small, or turbo (cached under ~/.cache/whisper)."
                            : "whisper.cpp: `whisper-cli` or `main` build; model = path to a .ggml .bin file."
                        )
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        TextField(
                            useOpenAIWhisperPip
                            ? "Path to whisper"
                            : "whisper.cpp binary",
                            text: $whisperBinaryPath
                        )
                        .textFieldStyle(.roundedBorder)
                        TextField(
                            useOpenAIWhisperPip
                            ? "Model name"
                            : "Model file path",
                            text: $whisperModelPath
                        )
                        .textFieldStyle(.roundedBorder)
                        TextField("Language (e.g. en, empty = auto)", text: $whisperLanguage)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Speech-to-text (Whisper)", systemImage: "waveform")
                        .font(.headline)
                }
                .padding(14)
                .background(cardBackground)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var awayTab: some View {
        AwayRemoteDesktopView(
            primaryLANAddress: primaryLANIPv4?.address,
            tailnetSelf: tailnetSelf,
            tailnetChecked: tailnetChecked,
            onRefresh: refreshNetworkHints,
            onCopy: copyStringToPasteboard
        )
    }

    private func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    private func copyStringToPasteboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }

    @ViewBuilder
    private var localIPv4Row: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac (LAN)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let p = primaryLANIPv4 {
                    Text(p.address)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("None detected — connect Wi‑Fi or Ethernet, or use refresh.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if let host = primaryLANIPv4?.address {
                    copyStringToPasteboard(bridgeWebSocketURL(host: host))
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(primaryLANIPv4 == nil)
            .opacity(primaryLANIPv4 == nil ? 0.35 : 1)
            .help("Copy WebSocket URL (ws://…/bridge)")
        }
    }

    /// Matches `VibeBridgeServer.defaultPort` when the listener has not reported a port yet.
    private var bridgeWebSocketPort: Int {
        Int(bridge.port == 0 ? 19_842 : bridge.port)
    }

    private func bridgeWebSocketURL(host: String) -> String {
        "ws://\(host):\(bridgeWebSocketPort)/bridge"
    }

    @ViewBuilder
    private var tailnetHostRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "network.badge.shield.half.filled")
                .font(.body)
                .foregroundStyle(tailnetSelf == nil ? Color.secondary : Color.green)
                .frame(width: 22, alignment: .center)
            if let s = tailnetSelf {
                let display = s.dnsName.isEmpty ? s.hostName : s.dnsName
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailnet hostname")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(display)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    copyStringToPasteboard(display)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy hostname to clipboard")
            } else if tailnetChecked {
                Text("Tailscale not found (install the app or CLI). A manual LAN IP or Bonjour still works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Checking Tailscale…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                refreshNetworkHints()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh LAN and Tailscale")
        }
    }

    private func refreshNetworkHints() {
        primaryLANIPv4 = LANIPv4Enumerator.allEntries().first
        refreshTailnet()
    }

    private func refreshTailnet() {
        tailnetChecked = false
        Task.detached(priority: .utility) {
            let result = TailscaleDetector.readSelf()
            await MainActor.run {
                tailnetSelf = result
                tailnetChecked = true
            }
        }
    }

    private func refreshAppsList() {
        let skip = Set([
            "com.thomasguntenaar.VibeWindowManager",
        ])
        let all = NSWorkspace.shared.runningApplications
        let list = all
            .filter { $0.activationPolicy == .regular }
            .filter { $0.bundleIdentifier.map { !skip.contains($0) } ?? true }
            .sorted { a, b in
                (a.localizedName ?? "") < (b.localizedName ?? "")
            }
        var choices = list.map { AppChoice(running: $0) }
        if choices.isEmpty { choices = [AppChoice(placeholder: "No apps")] }
        runningApps = choices
        if let pid = selectedAppPID, !choices.compactMap(\.pid).contains(pid) {
            selectedAppPID = choices.first?.pid
        } else if selectedAppPID == nil, let f = choices.first, !f.isPlaceholder {
            selectedAppPID = f.pid
        }
    }

    private func availableScreens() -> [NSScreen] { NSScreen.screens }

    private func screenLabel(_ s: NSScreen, index i: Int) -> String {
        let n = s.localizedName
        if s == NSScreen.main {
            return "Main display — \(n)"
        }
        return "Display \(i + 1) — \(n)"
    }

    private func screenLayoutRect() -> CGRect? {
        let screens = availableScreens()
        guard !screens.isEmpty, screenIndex < screens.count else { return nil }
        return ScreenGeometry.layoutFrame(
            for: screens[screenIndex],
            allScreens: screens,
            isStageManagerEnabled: StageManagerSupport.isEnabled
        )
    }

    private func currentRunningApp() -> NSRunningApplication? {
        guard let pid = selectedAppPID,
              let found = runningApps.first(where: { $0.pid == pid }),
              !found.isPlaceholder,
              let a = found.application
        else { return nil }
        return a
    }

    private func applySelectedProposal() {
        lastError = nil
        let screens = availableScreens()
        guard let visibleFrame = screenLayoutRect(), let proposal = selectedProposal else { return }
        do {
            switch proposal {
            case .tile(let mode):
                try service.applyTile(visibleFrame: visibleFrame, mode: mode, to: windows.map(\.element), allScreens: screens)
            case .cascade:
                try service.applyCascade(
                    visibleFrame: visibleFrame,
                    to: windows.map(\.element),
                    allScreens: screens,
                    insetStep: cascadeInsetStep
                )
            }
            refreshWindows()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshStatus() {
        let s = AXWindowLayoutService()
        service = s
        if !s.isProcessTrusted { service.requestAccessibilityIfNeeded() }
    }

    private func refreshWindows() {
        guard service.isProcessTrusted, let app = currentRunningApp() else {
            windows = []
            selectedProposal = nil
            return
        }
        do {
            windows = try service.windows(for: app)
            normalizeSelectedProposal()
        } catch {
            windows = []
            selectedProposal = nil
        }
    }

    private func normalizeSelectedProposal() {
        let proposals = availableProposals
        guard !proposals.isEmpty else {
            selectedProposal = nil
            return
        }
        if let selectedProposal, proposals.contains(selectedProposal) {
            return
        }
        selectedProposal = proposals.first
    }

    private func moveWindow(from index: Int, offset: Int) {
        let destination = index + offset
        guard windows.indices.contains(index), windows.indices.contains(destination) else { return }
        let moved = windows.remove(at: index)
        windows.insert(moved, at: destination)
    }

    private var availableProposals: [LayoutProposal] {
        let tileProposals = TileMode.suggestedModes(forWindowCount: windows.count).map(LayoutProposal.tile)
        return windows.isEmpty ? tileProposals : tileProposals + [.cascade]
    }

    private var currentPreviewLayout: PreviewLayout? {
        guard let proposal = selectedProposal, let visibleFrame = screenLayoutRect() else { return nil }
        switch proposal {
        case .tile(let mode):
            return PreviewLayout(
                proposal: proposal,
                frames: WindowLayoutEngine.slotRects(visibleFrame: visibleFrame, mode: mode, count: windows.count)
            )
        case .cascade:
            return PreviewLayout(
                proposal: proposal,
                frames: WindowLayoutEngine.cascadeFrames(
                    visibleFrame: visibleFrame,
                    count: windows.count,
                    insetStep: cascadeInsetStep,
                    margin: CascadeDefaults.margin
                )
            )
        }
    }

    private var splitSummaryText: String {
        guard let app = currentRunningApp() else {
            return "Select an app to inspect its windows."
        }
        guard service.isProcessTrusted else {
            return "Accessibility access is required before window counts can be detected."
        }
        if windows.isEmpty {
            return "\(app.localizedName ?? "App"): no movable windows detected."
        }
        return "\(app.localizedName ?? "App"): \(windows.count) window\(windows.count == 1 ? "" : "s") detected."
    }
}

// MARK: - Display arrangement (spatial picker)

/// Renders `NSScreen.frame` in global desktop space, proportionally, like Displays in System Settings. Tap a monitor to set `selectedIndex`.
private struct DisplayArrangementMap: View {
    let screens: [NSScreen]
    @Binding var selectedIndex: Int
    let label: (NSScreen, Int) -> String

    var body: some View {
        Group {
            if screens.isEmpty {
                Text("No displays found.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                let union = Self.unionOfFrames(screens)
                GeometryReader { proxy in
                    let w = max(union.width, 1)
                    let h = max(union.height, 1)
                    let scale = min(proxy.size.width / w, proxy.size.height / h)
                    let contentW = w * scale
                    let contentH = h * scale
                    let offsetX = (proxy.size.width - contentW) * 0.5
                    let offsetY = (proxy.size.height - contentH) * 0.5
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35))
                            .frame(width: contentW, height: contentH)
                            .offset(x: offsetX, y: offsetY)
                        ForEach(screens.indices, id: \.self) { index in
                            let screen = screens[index]
                            let preview = Self.previewRect(union: union, appKitFrame: screen.frame)
                            let isMain = screen == NSScreen.main
                            let isSelected = index == selectedIndex
                            Button {
                                selectedIndex = index
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(isSelected
                                            ? Color.accentColor.opacity(0.32)
                                            : Color(nsColor: .controlBackgroundColor))
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(
                                            isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.9),
                                            lineWidth: isSelected ? 2.5 : 1
                                        )
                                    VStack(spacing: 2) {
                                        if isMain {
                                            HStack(spacing: 2) {
                                                Image(systemName: "star.fill")
                                                Text("Main")
                                            }
                                            .font(.system(size: 7, weight: .semibold, design: .rounded))
                                            .foregroundStyle(.secondary)
                                        }
                                        Text(Self.inlineTitle(for: index, screen: screen, fullLabel: label(screen, index)))
                                            .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                                            .lineLimit(3)
                                            .multilineTextAlignment(.center)
                                            .minimumScaleFactor(0.5)
                                    }
                                    .padding(4)
                                }
                            }
                            .buttonStyle(.plain)
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .frame(width: preview.width * scale, height: preview.height * scale)
                            .offset(
                                x: offsetX + preview.minX * scale,
                                y: offsetY + preview.minY * scale
                            )
                            .accessibilityLabel(label(screen, index))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 150)
            }
        }
        .onAppear { clampIndex() }
        .onChange(of: screens.count) { _, _ in clampIndex() }
    }

    private func clampIndex() {
        guard !screens.isEmpty else { return }
        if selectedIndex >= screens.count {
            selectedIndex = max(0, screens.count - 1)
        }
    }

    private static func inlineTitle(for index: Int, screen: NSScreen, fullLabel: String) -> String {
        let n = screen.localizedName
        if !n.isEmpty { return n }
        if let range = fullLabel.range(of: " — ") { return String(fullLabel[range.upperBound...]) }
        return "Display \(index + 1)"
    }

    private static func unionOfFrames(_ screens: [NSScreen]) -> CGRect {
        guard let first = screens.first else { return .zero }
        return screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
    }

    /// AppKit global frames (Y up) → SwiftUI top-left, Y down, relative to the union of all screens.
    private static func previewRect(union: CGRect, appKitFrame: CGRect) -> CGRect {
        CGRect(
            x: appKitFrame.minX - union.minX,
            y: union.maxY - appKitFrame.maxY,
            width: appKitFrame.width,
            height: appKitFrame.height
        )
    }
}

// MARK: - App icon grid

private struct RunningAppIconGrid: View {
    let apps: [AppChoice]
    @Binding var selectedPID: pid_t?

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 80, maximum: 104), spacing: 10, alignment: .top)]

    var body: some View {
        Group {
            if apps.isEmpty {
                Text("No running apps found.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(apps) { choice in
                            if choice.isPlaceholder {
                                appPlaceholderCell(choice)
                            } else {
                                appIconCell(choice)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    @ViewBuilder
    private func appPlaceholderCell(_ choice: AppChoice) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "app.dashed")
                .font(.title)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .frame(width: 48, height: 48)
            Text(choice.label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
    }

    @ViewBuilder
    private func appIconCell(_ choice: AppChoice) -> some View {
        let selected = (choice.pid == selectedPID) && (choice.pid != nil)
        Button {
            if let pid = choice.pid {
                selectedPID = pid
            }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if let img = appIconImage(for: choice) {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(1, contentMode: .fit)
                    } else {
                        Image(systemName: "app.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(shortAppTitle(choice))
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 28, alignment: .top)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 100)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.45),
                        lineWidth: selected ? 2 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.label)
    }

    private func appIconImage(for choice: AppChoice) -> NSImage? {
        if let i = choice.application?.icon { return i }
        guard let b = choice.application?.bundleURL else { return nil }
        return NSWorkspace.shared.icon(forFile: b.path)
    }

    private func shortAppTitle(_ choice: AppChoice) -> String {
        if let n = choice.application?.localizedName, !n.isEmpty { return n }
        if let s = choice.label.split(separator: "(").first {
            return String(s).trimmingCharacters(in: .whitespaces)
        }
        return "App"
    }
}

/// One horizontal row of app icons; sets `appQuery` to a token `AppQueryResolver` can match.
private struct BridgeAppQueryIconRow: View {
    let apps: [AppChoice]
    @Binding var appQuery: String

    var body: some View {
        if apps.isEmpty {
            Text("No apps running — start an app, then pick it for mirroring.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(apps) { choice in
                        if let app = choice.application, choice.pid != nil {
                            let selected = isQueryActive(for: app)
                            bridgeIconButton(choice: choice, app: app, selected: selected)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func bridgeIconButton(choice: AppChoice, app: NSRunningApplication, selected: Bool) -> some View {
        Button {
            appQuery = AppQueryResolver.bridgeQueryToken(for: app)
        } label: {
            Group {
                if let i = app.icon {
                    Image(nsImage: i)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1, contentMode: .fit)
                } else if let p = app.bundleURL?.path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: p))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1, contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.4),
                        lineWidth: selected ? 2 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .help(choice.label)
        .accessibilityLabel(choice.label)
    }

    private func isQueryActive(for app: NSRunningApplication) -> Bool {
        let all = AppQueryResolver.runningRegularApps()
        guard let r = AppQueryResolver.resolve(query: appQuery, in: all) else { return false }
        if r.ambiguous { return false }
        return r.app?.processIdentifier == app.processIdentifier
    }

}

private struct AppChoice: Identifiable {
    let id: String
    let pid: pid_t?
    let label: String
    let application: NSRunningApplication?
    var isPlaceholder: Bool { application == nil }

    init(running: NSRunningApplication) {
        let p = running.processIdentifier
        self.id = "pid-\(p)"
        self.pid = p
        self.application = running
        self.label = (running.localizedName ?? "App") + (running.bundleIdentifier.map { " (\($0))" } ?? "")
    }

    init(placeholder: String) {
        self.id = "no-apps"
        self.pid = nil
        self.label = placeholder
        self.application = nil
    }
}

private struct PreviewLayout {
    let proposal: LayoutProposal
    let frames: [CGRect]
}

private struct LayoutPreviewView: View {
    let visibleFrame: CGRect
    let frames: [CGRect]
    let windows: [ManagedWindow]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let scale = min(size.width / visibleFrame.width, size.height / visibleFrame.height)
            let previewSize = CGSize(width: visibleFrame.width * scale, height: visibleFrame.height * scale)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: previewSize.width, height: previewSize.height)

                ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                    let rect = scaledRect(frame, scale: scale)
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.18))
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                Text(windowTitle(at: index))
                                    .font(.caption2)
                                    .lineLimit(2)
                            }
                            .padding(8)
                        }
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
    }

    private func scaledRect(_ frame: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (frame.minX - visibleFrame.minX) * scale,
            y: (visibleFrame.maxY - frame.maxY) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private func windowTitle(at index: Int) -> String {
        guard windows.indices.contains(index) else { return "Window \(index + 1)" }
        return windows[index].title
    }
}

// MARK: - Suggested layout thumbnails (mini previews)

/// Small **visual** preview: uses `WindowLayoutEngine` in a *large enough* AppKit frame.
/// **Note:** `slotRects` requires `visibleFrame.width/height > 1`; a 1×1 "unit" frame made every layout fall back to a single square.
private struct LayoutProposalThumbnail: View {
    let proposal: LayoutProposal
    let windowCount: Int
    let isSelected: Bool
    let onSelect: () -> Void

    /// Tile / grid: square works; must satisfy `WindowLayoutEngine`’s `> 1` guard.
    private static let engineFrameTile = CGRect(x: 0, y: 0, width: 200, height: 200)
    /// Cascade enforces a minimum window size (≈160×120); a tall enough frame is required or math collapses.
    private static let engineFrameCascade = CGRect(x: 0, y: 0, width: 480, height: 360)
    private static let paneGutter: CGFloat = 0.02
    private static let thumbSize: CGFloat = 76

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                let vf = engineVisibleFrame
                let rects = panes
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.45),
                                    Color(nsColor: .quaternaryLabelColor).opacity(0.18),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.75)
                        }
                    ForEach(Array(rects.enumerated()), id: \.offset) { index, frame in
                        let r = toSwiftUIRect(frame, visibleFrame: vf, into: CGSize(width: Self.thumbSize, height: Self.thumbSize))
                        let cr = min(4, max(2, min(r.width, r.height) * 0.1))
                        let o = 1.0 - Double(index) * 0.1
                        RoundedRectangle(cornerRadius: cr, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(0.45 * o + 0.1),
                                        Color.accentColor.opacity(0.2 * o + 0.1),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: cr, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 0.8)
                            }
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                .frame(width: Self.thumbSize, height: Self.thumbSize)
                .clipped()
                .accessibilityElement(children: .ignore)

                Text(proposal.label)
                    .font(.caption2)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.1)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.65)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.5),
                        lineWidth: isSelected ? 2 : 0.5
                    )
            }
            .shadow(color: isSelected ? Color.accentColor.opacity(0.18) : .clear, radius: isSelected ? 4 : 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(proposal.label)
    }

    private var engineVisibleFrame: CGRect {
        switch proposal {
        case .cascade: return Self.engineFrameCascade
        case .tile: return Self.engineFrameTile
        }
    }

    private var panes: [CGRect] {
        let c = max(1, windowCount)
        let vf = engineVisibleFrame
        let raw: [CGRect] = {
            switch proposal {
            case .tile(let mode):
                return WindowLayoutEngine.slotRects(visibleFrame: vf, mode: mode, count: c)
            case .cascade:
                return WindowLayoutEngine.cascadeFrames(
                    visibleFrame: vf,
                    count: c,
                    insetStep: 22,
                    margin: 16
                )
            }
        }()
        if raw.isEmpty { return [vf] }
        return raw.map { r in
            r.insetBy(
                dx: r.width * Self.paneGutter,
                dy: r.height * Self.paneGutter
            )
        }
    }

    private func toSwiftUIRect(_ frame: CGRect, visibleFrame vf: CGRect, into size: CGSize) -> CGRect {
        let sx = size.width / max(vf.width, 0.0001)
        let sy = size.height / max(vf.height, 0.0001)
        return CGRect(
            x: (frame.minX - vf.minX) * sx,
            y: (vf.maxY - frame.maxY) * sy,
            width: frame.width * sx,
            height: frame.height * sy
        )
    }
}

#Preview {
    ContentView()
}
