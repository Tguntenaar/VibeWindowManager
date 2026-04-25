//
//  AwayRemoteDesktopView.swift
//  VibeWindowManager
//
//  away-from-desk: copyable VNC (Screen Sharing) URLs for iPhone/iPad clients.
//  The Mac remains the source of truth; the phone is a remote display + use the
//  iOS bridge tab for layout mirror and mic/Whisper.
//

import AppKit
import SwiftUI

/// Default TCP port for macOS Screen Sharing (VNC).
private enum VNCEndpoint {
    static let port = 5900

    static func urlString(host: String) -> String {
        "vnc://\(host):\(port)"
    }
}

struct AwayRemoteDesktopView: View {
    /// First enumerated LAN IPv4 (same source as the bridge tab).
    let primaryLANAddress: String?
    let tailnetSelf: TailscaleSelfStatus?
    let tailnetChecked: Bool
    let onRefresh: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote desktop (VNC)")
                        .font(.title2.weight(.semibold))
                    Text(
                        "The Mac stays the source of truth: your shell, tmux, files, and projects stay on this machine. Use an iPhone or iPad VNC app as the screen in another room, then over Tailnet when you’re off-LAN. When you sit back down, the work is still here."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Text("Use the Layout and iOS bridge tabs for tile mirroring, tmux text, and microphone → Whisper. This tab is only for full-screen Screen Sharing (VNC) pixels.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                vncPrerequisitesCard
                copyRowsCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vncPrerequisitesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before you connect")
                .font(.headline)
            Text("Turn on Screen Sharing (or Remote Management) on this Mac so a VNC client can connect—typically port \(VNCEndpoint.port). You may be prompted for your macOS user name and password from the iOS app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open Sharing settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing?") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh network", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var copyRowsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect from iPhone or iPad")
                .font(.headline)
            Text("Install a VNC app (e.g. Screens, Jump Desktop, VNC Viewer), then paste a URL below, or type the host and port \(VNCEndpoint.port) manually.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            vncRow(
                title: "Tailscale (off-LAN, recommended)",
                subtitle: tailnetSubtitle,
                hostForURL: tailnetHost,
                systemImage: "network.badge.shield.half.filled",
                tint: .green
            )
            vncRow(
                title: "Same Wi‑Fi (LAN)",
                subtitle: primaryLANAddress.map { "IPv4: \($0)" } ?? "Not detected on this network.",
                hostForURL: primaryLANAddress,
                systemImage: "wifi",
                tint: .secondary
            )
            if let ip = tailnetSelf?.ipv4, !ip.isEmpty {
                vncRow(
                    title: "Tailscale IP (100.x)",
                    subtitle: "Alternative if MagicDNS is slow to resolve: \(ip)",
                    hostForURL: ip,
                    systemImage: "link",
                    tint: .secondary
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var tailnetHost: String? {
        guard let s = tailnetSelf else { return nil }
        let h = s.dnsName.isEmpty ? s.hostName : s.dnsName
        return h.isEmpty ? s.ipv4 : h
    }

    private var tailnetSubtitle: String {
        guard let s = tailnetSelf else {
            return tailnetChecked
                ? "Tailscale not detected. Install the Mac app and sign in, or use LAN below."
                : "Checking…"
        }
        let name = s.dnsName.isEmpty ? s.hostName : s.dnsName
        if !name.isEmpty { return "Hostname: \(name)" }
        if let v = s.ipv4 { return "IP: \(v)" }
        return "Connected"
    }

    @ViewBuilder
    private func vncRow(
        title: String,
        subtitle: String,
        hostForURL: String?,
        systemImage: String,
        tint: Color
    ) -> some View {
        let vnc = hostForURL.map { VNCEndpoint.urlString(host: $0) }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let u = vnc {
                    Text(u)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let u = vnc {
                Button {
                    onCopy(u)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy VNC URL")
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
            }
        }
    }
}
