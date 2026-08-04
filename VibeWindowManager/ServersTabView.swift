//
//  ServersTabView.swift
//  VibeWindowManager
//
//  Lists every process listening on a TCP port on this Mac — one row per process, ranked so the
//  forgotten dev servers float to the top and background services fold away — with a guarded kill.
//

import AppKit
import SwiftUI

struct ServersTabView: View {
    @ObservedObject var scanner: LocalServerScanService

    @AppStorage("vibeServersShowOtherUsers") private var showOtherUsers: Bool = false
    @AppStorage("vibeServersShowBackground") private var showBackground: Bool = false
    @State private var searchText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controlsCard
                if let error = scanner.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                serverListCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The scan loop is app-wide (the menu bar needs it too), so leaving the tab only drops the
        // cadence back to the default — it must never stop the shared scanner.
        .onAppear { scanner.startAutoRefresh(interval: 4) }
        .onDisappear { scanner.startAutoRefresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Local servers")
                    .font(.title2.weight(.semibold))
                Text("Every process listening on a TCP port on this Mac — dev servers, tunnels and daemons, ranked so the ones you forgot about come first. Kill anything squatting on a port you need.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                scanner.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(scanner.isScanning)
            .help("Rescan listening TCP ports")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Controls

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Filter by port, name, project or command", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear filter")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08))
                        )
                )
                .frame(maxWidth: 320)

                Spacer(minLength: 8)

                if scanner.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Toggle(isOn: $showOtherUsers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show other users' processes")
                        .font(.subheadline.weight(.medium))
                    Text("Off by default: only servers started by your login account are listed. System daemons run as other users and usually should not be killed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 6) {
                Text(scanCountSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = scanner.lastScan {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    HStack(spacing: 3) {
                        Text("Last scanned")
                        Text(last, style: .relative)
                        Text("ago")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var scanCountSummary: String {
        let processes = filteredRanked.count + filteredBackground.count
        let ports = (filteredRanked + filteredBackground).reduce(0) { $0 + $1.ports.count }
        let processText = "\(processes) process\(processes == 1 ? "" : "es")"
        let portText = "\(ports) port\(ports == 1 ? "" : "s")"
        // Resident sizes overlap (shared libraries are counted in every process), so this total
        // reads high — it is a rough sense of scale, hence the "≈".
        let resident = (filteredRanked + filteredBackground).compactMap(\.residentBytes).reduce(0, +)
        guard resident > 0 else { return "\(processText) · \(portText)" }
        return "\(processText) · \(portText) · ≈\(LocalServerProcess.memoryText(resident)) resident"
    }

    // MARK: - List

    private var serverListCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Listening processes")
                .font(.headline)

            if filteredRanked.isEmpty && filteredBackground.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if filteredRanked.isEmpty {
                        Text("Nothing but background services right now.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        categoryGroups(for: filteredRanked)
                    }

                    if !filteredBackground.isEmpty {
                        Divider()
                        backgroundSection
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var backgroundSection: some View {
        DisclosureGroup(isExpanded: backgroundExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                categoryGroups(for: filteredBackground)
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.2")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                // `Text` takes a LocalizedStringKey, so an interpolated Int would be number-formatted
                // for the current locale. Counts here are small, but keep the String(...) habit.
                Text("Background services (\(String(filteredBackground.count)))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .help("Apps, macOS services and VibeWindowManager itself — almost never what you are looking for.")
    }

    /// Collapsed by default and remembered, but a live search force-opens it so matches are never
    /// hidden behind a closed triangle.
    private var backgroundExpanded: Binding<Bool> {
        Binding(
            get: { showBackground || !trimmedQuery.isEmpty },
            set: { showBackground = $0 }
        )
    }

    @ViewBuilder
    private func categoryGroups(for servers: [LocalServerProcess]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Self.groupedByCategory(servers)) { group in
                VStack(alignment: .leading, spacing: 0) {
                    categoryHeader(group.category, count: group.servers.count)
                    ForEach(Array(group.servers.enumerated()), id: \.element.id) { index, server in
                        ServerRow(scanner: scanner, server: server)
                        if index < group.servers.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func categoryHeader(_ category: ServerCategory, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.symbolName)
                .font(.caption2)
            Text(category.title)
                .font(.caption.weight(.medium))
            Text(String(count))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 1)
        }
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(emptyStateTitle, systemImage: "server.rack")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(emptyStateDetail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var emptyStateTitle: String {
        if scanner.isScanning && scanner.servers.isEmpty { return "Scanning…" }
        if !trimmedQuery.isEmpty { return "No matching servers" }
        return "Nothing is listening"
    }

    private var emptyStateDetail: String {
        if scanner.isScanning && scanner.servers.isEmpty {
            return "Reading the list of listening TCP sockets."
        }
        if !trimmedQuery.isEmpty {
            return "No listening process matches “\(searchText)”. Clear the filter to see everything."
        }
        if !showOtherUsers && !scanner.servers.isEmpty {
            return "Nothing you own is listening. Turn on “Show other users' processes” to include system daemons."
        }
        return "No process on this Mac is currently listening on a TCP port. Start a dev server and it shows up here within a few seconds."
    }

    // MARK: - Filtering

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private var filteredRanked: [LocalServerProcess] {
        filter(scanner.ranked)
    }

    private var filteredBackground: [LocalServerProcess] {
        filter(scanner.background)
    }

    private func filter(_ servers: [LocalServerProcess]) -> [LocalServerProcess] {
        let query = trimmedQuery.lowercased()
        return servers.filter { server in
            guard showOtherUsers || server.isOwnedByCurrentUser else { return false }
            guard !query.isEmpty else { return true }
            if server.ports.contains(where: { String($0).contains(query) }) { return true }
            if server.displayName.lowercased().contains(query) { return true }
            if server.subtitle.lowercased().contains(query) { return true }
            if let project = server.projectName, project.lowercased().contains(query) { return true }
            if server.category.title.lowercased().contains(query) { return true }
            if server.command.lowercased().contains(query) { return true }
            if server.commandLine.lowercased().contains(query) { return true }
            if server.user.lowercased().contains(query) { return true }
            return server.bindAddresses.contains { $0.lowercased().contains(query) }
        }
    }

    /// Runs of one category, in the order the scanner already ranked them — never re-sorts.
    fileprivate struct CategoryGroup: Identifiable {
        let category: ServerCategory
        let servers: [LocalServerProcess]
        var id: Int { category.rawValue }
    }

    fileprivate static func groupedByCategory(_ servers: [LocalServerProcess]) -> [CategoryGroup] {
        var groups: [CategoryGroup] = []
        for server in servers {
            if let last = groups.last, last.category == server.category {
                groups[groups.count - 1] = CategoryGroup(
                    category: last.category,
                    servers: last.servers + [server]
                )
            } else {
                groups.append(CategoryGroup(category: server.category, servers: [server]))
            }
        }
        return groups
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

// MARK: - Row

private struct ServerRow: View {
    @ObservedObject var scanner: LocalServerScanService
    let server: LocalServerProcess

    @State private var confirmingKill: Bool = false
    @State private var didCopy: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            portColumn

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(server.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if server.isExposedToNetwork {
                        exposedBadge
                    }
                }

                // The "why is this here" line — quieter than the name, louder than the metadata.
                Text(server.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    Text("pid \(String(server.pid))")
                        .monospacedDigit()
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("up \(scanner.uptimeText(for: server))")
                    if server.residentBytes != nil {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(server.memoryText)
                            .monospacedDigit()
                            .help("Resident memory in use right now")
                    }
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(server.bindAddresses.isEmpty ? "—" : server.bindAddresses.joined(separator: ", "))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !server.isOwnedByCurrentUser {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(server.user)
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if !commandText.isEmpty {
                    Text(commandText)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(commandText)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .padding(.top, 1)
        }
        .padding(.vertical, 8)
        .confirmationDialog(
            "Stop “\(server.displayName)” on port \(String(server.primaryPort))?",
            isPresented: $confirmingKill,
            titleVisibility: .visible
        ) {
            Button("Quit (SIGTERM)") {
                scanner.terminate(server, force: false)
            }
            Button("Force kill (SIGKILL)", role: .destructive) {
                scanner.terminate(server, force: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("pid \(String(server.pid)) · \(server.command) · \(portSentence) · running as \(server.user). SIGTERM lets it shut down cleanly; SIGKILL is immediate and may lose unsaved work.")
        }
    }

    // MARK: Ports

    /// The primary port stays prominent; everything else this pid listens on rides along in a
    /// compact second line so a 12-port Docker row never wraps.
    private var portColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            // `Text`/`Menu`/`.help`/`.confirmationDialog` take a LocalizedStringKey, which
            // number-formats an interpolated Int for the current locale — port 5000 renders as
            // "5.000". Ports and pids are identifiers, never numbers: always use `String(...)`.
            Text(String(server.primaryPort))
                .font(.title3.monospaced().weight(.semibold))
            if let extras = extraPortsText {
                Text(extras)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let overflow = overflowPortsText {
                Text(overflow)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: 112, alignment: .trailing)
        .help(portsHelp)
    }

    private var otherPorts: [Int] {
        server.ports.filter { $0 != server.primaryPort }
    }

    private var extraPortsText: String? {
        let others = otherPorts
        guard !others.isEmpty else { return nil }
        let shown = others.prefix(2).map { ":\(String($0))" }.joined(separator: ", ")
        return "+ \(shown)"
    }

    private var overflowPortsText: String? {
        guard otherPorts.count > 2 else { return nil }
        return "… (\(String(server.ports.count)) ports)"
    }

    private var portsHelp: String {
        guard server.ports.count > 1 else { return "TCP port \(String(server.primaryPort))" }
        let list = server.ports.map { String($0) }.joined(separator: ", ")
        return "Listening on \(String(server.ports.count)) TCP ports: \(list)"
    }

    private var portSentence: String {
        server.ports.count > 1
            ? "ports \(server.ports.map { String($0) }.joined(separator: ", "))"
            : "port \(String(server.primaryPort))"
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if server.isLikelyHTTP {
                Button {
                    openInBrowser()
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open http://localhost:\(String(server.primaryPort))")
            }

            Button {
                copyCommand()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(commandText.isEmpty)
            .help("Copy the full command line")

            if server.category.isKillable {
                Button(role: .destructive) {
                    confirmingKill = true
                } label: {
                    Label("Kill", systemImage: "xmark.octagon")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Stop this process")
            } else {
                Text("this app")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .help("This is VibeWindowManager itself — quit it from the menu bar instead.")
            }
        }
    }

    private var exposedBadge: some View {
        Label("Exposed", systemImage: "exclamationmark.triangle.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(0.14))
            )
            .help("Bound to all interfaces — anyone on your network can reach this port.")
    }

    private var commandText: String {
        server.commandLine.isEmpty ? server.command : server.commandLine
    }

    private func copyCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(commandText, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            didCopy = false
        }
    }

    private func openInBrowser() {
        guard let url = URL(string: "http://localhost:\(server.primaryPort)") else { return }
        NSWorkspace.shared.open(url)
    }
}
