//
//  ContentView.swift
//  VibeWindowManager
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import AppKit
import SwiftUI

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
    @State private var service = AXWindowLayoutService()
    @State private var runningApps: [AppChoice] = []
    @State private var windows: [ManagedWindow] = []
    @State private var selectedAppPID: pid_t?
    @State private var screenIndex: Int = 0
    @State private var selectedProposal: LayoutProposal?
    @State private var cascadeInsetStep: Double = CascadeDefaults.insetStep
    @State private var lastError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VibeWindowManager")
                        .font(.headline)
                    let trusted = service.isProcessTrusted
                    let stageManagerEnabled = StageManagerSupport.isEnabled
                    HStack {
                        Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(trusted ? .green : .yellow)
                        Text(trusted
                             ? "Accessibility: granted"
                             : "Accessibility: not granted — add this app in System Settings")
                    }
                    .font(.subheadline)
                    Text(stageManagerEnabled ? "Stage Manager: enabled" : "Stage Manager: disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Request access…") {
                    service.requestAccessibilityIfNeeded()
                    refreshStatus()
                    refreshWindows()
                }
                Button("Open Settings") {
                    openAccessibilitySettings()
                }
                Button("Refresh") {
                    service = AXWindowLayoutService()
                    refreshAppsList()
                    refreshWindows()
                }
            }

            Picker("Target app", selection: $selectedAppPID) {
                ForEach(runningApps) { app in
                    Text(app.label).tag(app.pid)
                }
            }
            .disabled(runningApps.isEmpty)

            Picker("Display", selection: $screenIndex) {
                ForEach(availableScreens().indices, id: \.self) { i in
                    Text(screenLabel(availableScreens()[i], index: i)).tag(i)
                }
            }

            GroupBox("Suggested layouts") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(splitSummaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if availableProposals.isEmpty {
                        Text("Grant Accessibility and select an app to inspect its windows.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                            ForEach(availableProposals, id: \.self) { proposal in
                                Button(proposal.label) {
                                    selectedProposal = proposal
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(selectedProposal == proposal ? .accentColor : .gray.opacity(0.5))
                            }
                        }
                    }
                }
            }

            GroupBox("Preview") {
                if let preview = currentPreviewLayout, let visibleFrame = screenLayoutRect() {
                    HStack(alignment: .top, spacing: 16) {
                        LayoutPreviewView(
                            visibleFrame: visibleFrame,
                            frames: preview.frames,
                            windows: windows
                        )
                        .frame(minWidth: 380, idealWidth: 440, minHeight: 260, idealHeight: 300)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Window order")
                                .font(.headline)
                            Text("Top item goes into the first preview slot. Reorder before applying.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if selectedProposal == .cascade {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text("Cascade offset")
                                        Spacer()
                                        Text("\(Int(cascadeInsetStep)) px")
                                            .foregroundStyle(.secondary)
                                    }
                                    Slider(value: $cascadeInsetStep, in: 0...120, step: 1)
                                }
                            }

                            if windows.isEmpty {
                                Text("No movable windows detected.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ScrollView {
                                    VStack(spacing: 8) {
                                        ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                                            HStack {
                                                Text("\(index + 1).")
                                                    .foregroundStyle(.secondary)
                                                Text(window.title)
                                                    .lineLimit(1)
                                                Spacer()
                                                Button {
                                                    moveWindow(from: index, offset: -1)
                                                } label: {
                                                    Image(systemName: "arrow.up")
                                                }
                                                .disabled(index == 0)

                                                Button {
                                                    moveWindow(from: index, offset: 1)
                                                } label: {
                                                    Image(systemName: "arrow.down")
                                                }
                                                .disabled(index == windows.count - 1)
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }
                                .frame(maxHeight: 220)
                            }

                            Button("Apply \(preview.proposal.label)") {
                                applySelectedProposal()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(preview.frames.isEmpty || windows.isEmpty)
                        }
                        .frame(minWidth: 280)
                    }
                } else {
                    Text("Pick a proposal to see a preview, rearrange the window order, then click Apply.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let e = lastError {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 540)
        .onAppear {
            refreshAppsList()
            refreshStatus()
            refreshWindows()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            service = AXWindowLayoutService()
            refreshAppsList()
            refreshWindows()
        }
        .onChange(of: selectedAppPID) { _, _ in
            refreshWindows()
        }
        .onChange(of: screenIndex) { _, _ in
            normalizeSelectedProposal()
        }
    }

    private func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
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

#Preview {
    ContentView()
}
