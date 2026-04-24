//
//  TailscaleDetector.swift
//  VibeWindowManager
//
//  Best-effort reader for the local Tailnet MagicDNS name of this Mac.
//  Used by the bridge UI so the user can copy the hostname to the iOS app.
//  Requires the Tailscale CLI (installed by the Tailscale Mac app or Homebrew).
//  App is not sandboxed, so Process can exec the binary directly.
//

import Foundation

struct TailscaleSelfStatus {
    /// Full MagicDNS name, e.g. `my-mac.tailxxxx.ts.net` (trailing dot stripped).
    let dnsName: String
    /// Short hostname, e.g. `my-mac`.
    let hostName: String
    /// First Tailscale IPv4 if present (usually `100.x.y.z`).
    let ipv4: String?
}

enum TailscaleDetector {
    private static let candidatePaths: [String] = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// Returns the first existing `tailscale` binary path, or `nil` if the CLI is not installed.
    static func cliPath() -> String? {
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    /// Runs `tailscale status --json` and parses `Self`. Returns `nil` on any failure
    /// (CLI missing, tailscaled not running, not logged in).
    static func readSelf() -> TailscaleSelfStatus? {
        guard let bin = cliPath() else { return nil }
        let out = Pipe()
        let err = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["status", "--json"]
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let me = root["Self"] as? [String: Any]
        else { return nil }
        let dns = (me["DNSName"] as? String)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? ""
        let host = (me["HostName"] as? String) ?? ""
        let ips = me["TailscaleIPs"] as? [String] ?? []
        let ipv4 = ips.first(where: { $0.contains(".") && !$0.contains(":") })
        guard !dns.isEmpty || !host.isEmpty else { return nil }
        return TailscaleSelfStatus(dnsName: dns, hostName: host, ipv4: ipv4)
    }
}
