//
//  LANIPv4Enumerator.swift
//  VibeWindowManager
//
//  Lists non-loopback IPv4 addresses on typical LAN interfaces (excludes utun/awdl
//  and Tailscale-style 100.x addresses so the bridge UI stays readable).
//

import Darwin
import Foundation

enum LANIPv4Enumerator {
    struct Entry: Hashable, Sendable {
        let interface: String
        let address: String
    }

    nonisolated static func allEntries() -> [Entry] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var collected: [Entry] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let iface = ptr {
            defer { ptr = iface.pointee.ifa_next }

            let flags = Int32(iface.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }
            guard let namePtr = iface.pointee.ifa_name else { continue }
            let ifName = String(cString: namePtr)
            guard interfaceIsLikelyLAN(ifName) else { continue }
            guard let sa = iface.pointee.ifa_addr else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(sa.pointee.sa_len)
            guard getnameinfo(sa, len, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostname)
            guard ip != "127.0.0.1" else { continue }
            if ip.hasPrefix("100.") { continue }

            collected.append(Entry(interface: ifName, address: ip))
        }

        return sortEntries(collected)
    }

    private nonisolated static func interfaceIsLikelyLAN(_ name: String) -> Bool {
        if name.hasPrefix("lo") { return false }
        if name.hasPrefix("utun") { return false }
        if name.hasPrefix("awdl") { return false }
        if name.hasPrefix("llw") { return false }
        if name.hasPrefix("feth") { return false }
        if name == "bridge0" { return false }
        return true
    }

    private nonisolated static func sortEntries(_ entries: [Entry]) -> [Entry] {
        let order = ["en0": 0, "en1": 1, "en2": 2, "en3": 3, "en4": 4, "en5": 5]
        return entries.sorted { a, b in
            let oa = order[a.interface] ?? 100
            let ob = order[b.interface] ?? 100
            if oa != ob { return oa < ob }
            if a.interface != b.interface { return a.interface < b.interface }
            return a.address < b.address
        }
    }
}
