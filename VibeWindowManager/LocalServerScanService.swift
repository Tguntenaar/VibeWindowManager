//
//  LocalServerScanService.swift
//  VibeWindowManager
//
//  Lists every process on this Mac that is LISTENing on a TCP port — local dev
//  servers, tunnels, agents — by shelling out to lsof and enriching each pid
//  with ps and its working directory, so the menu bar and the main window can
//  show, rank and kill them.
//
//  One row per PROCESS, not per port: a pid that listens on twelve ports (hello
//  Docker) is a single entry whose `ports` carries all of them.
//

import AppKit
import Combine
import Darwin
import Foundation

/// Why a listener is on this Mac, and therefore how interesting it is. The raw
/// values are the sort order: `.scratch` first (the forgotten one-off scripts
/// the user actually wants to find) down to `.selfApp` last.
enum ServerCategory: Int, Comparable, CaseIterable, Sendable {
    case scratch = 0
    case devServer = 1
    case devTool = 2
    case app = 3
    case system = 4
    case selfApp = 5

    static func < (lhs: ServerCategory, rhs: ServerCategory) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .scratch: return "Temporary script"
        case .devServer: return "Dev server"
        case .devTool: return "Dev tooling"
        case .app: return "App"
        case .system: return "macOS service"
        case .selfApp: return "This app"
        }
    }

    /// Folded into the collapsed "Background services" section / submenu.
    var isBackground: Bool {
        switch self {
        case .app, .system, .selfApp: return true
        case .scratch, .devServer, .devTool: return false
        }
    }

    /// Killing ourselves from our own menu is never what the user meant.
    var isKillable: Bool { self != .selfApp }

    /// SF Symbol for the row badge. Kept to symbols that exist on macOS 11 so
    /// the tab and the menu bar can render it without an availability dance.
    var symbolName: String {
        switch self {
        case .scratch: return "exclamationmark.triangle"
        case .devServer: return "hammer"
        case .devTool: return "wrench.and.screwdriver"
        case .app: return "app"
        case .system: return "gearshape"
        case .selfApp: return "macwindow"
        }
    }
}

struct LocalServerProcess: Identifiable, Hashable, Sendable {
    let pid: pid_t
    /// Every port this pid listens on, ascending and deduped.
    let ports: [Int]
    let bindAddresses: [String]
    let command: String
    let user: String
    let commandLine: String
    /// First argv token, when it looks like a path. Note argv is whitespace
    /// split, so a binary living under a directory with a space in it comes
    /// back truncated — classification therefore also looks at `commandLine`.
    let executablePath: String?
    /// From `lsof -d cwd`; nil when the process is unreadable or has none.
    let workingDirectory: String?
    let startedAt: Date?
    /// Resident set size in bytes, from `ps -o rss`. This is what the process is
    /// using right now, not a high-water mark. Nil when ps told us nothing.
    let residentBytes: Int?
    let category: ServerCategory
    /// Git repo name, else the cwd's last component. Only filled in when the
    /// process is actually project-shaped (`.devServer`).
    let projectName: String?

    init(
        pid: pid_t,
        ports: [Int],
        bindAddresses: [String],
        command: String,
        user: String,
        commandLine: String = "",
        executablePath: String? = nil,
        workingDirectory: String? = nil,
        startedAt: Date? = nil,
        residentBytes: Int? = nil,
        category: ServerCategory = .devTool,
        projectName: String? = nil
    ) {
        self.pid = pid
        self.ports = Array(Set(ports)).sorted()
        self.bindAddresses = bindAddresses
        self.command = command
        self.user = user
        self.commandLine = commandLine
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.residentBytes = residentBytes
        self.category = category
        self.projectName = projectName
    }

    var id: pid_t { pid }

    /// The port worth showing in the collapsed row: the lowest port a human
    /// would have typed, i.e. the lowest non-ephemeral one, else just the
    /// lowest. Docker's 80 wins over its handful of high random ports.
    var primaryPort: Int { namedPorts.first ?? ports.first ?? 0 }

    /// Kernel-assigned ports. They never rank on their own — they are noise the
    /// row carries along.
    var ephemeralPorts: [Int] { ports.filter { $0 >= ServerClassifier.ephemeralPortFloor } }

    var namedPorts: [Int] { ports.filter { $0 < ServerClassifier.ephemeralPortFloor } }

    var isLoopbackOnly: Bool {
        !bindAddresses.isEmpty && bindAddresses.allSatisfy { Self.loopbackAddresses.contains($0) }
    }

    var isExposedToNetwork: Bool {
        bindAddresses.contains { Self.wildcardAddresses.contains($0) }
    }

    var isOwnedByCurrentUser: Bool { user == NSUserName() }

    var displayName: String { Self.displayName(command: command, commandLine: commandLine) }

    /// The "why is this here" line under the display name.
    var subtitle: String {
        switch category {
        case .devServer:
            if let projectName { return "\(category.title) · \(projectName)" }
        case .scratch:
            if let root = ServerClassifier.scratchRoot(
                commandLine: commandLine, executablePath: executablePath, workingDirectory: workingDirectory
            ) {
                return "\(category.title) · \(root)"
            }
        case .devTool:
            // The binary name is the useful half ("adb", "com.docker.backend");
            // the well-known port only has to stand in when lsof gave us nothing.
            let detail = command.isEmpty ? ServerClassifier.knownPortName(primaryPort) : command
            if let detail { return "\(category.title) · \(detail)" }
        case .system:
            if let name = ServerClassifier.knownPortName(primaryPort) { return "\(category.title) · \(name)" }
        case .app, .selfApp:
            break
        }
        return category.title
    }

    static let loopbackAddresses: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]
    static let wildcardAddresses: Set<String> = ["*", "0.0.0.0", "::", "[::]"]

    /// Worth offering an "Open in browser" action for. Guesswork — the point is only to avoid
    /// dangling a browser button in front of a database or an SSH tunnel. Lives here so the tab
    /// and the menu bar never disagree about which ports get the button.
    var isLikelyHTTP: Bool { Self.isLikelyHTTPPort(primaryPort) }

    /// `48 MB`, or "—" when ps gave us no rss. Base-10 units, matching Activity Monitor.
    var memoryText: String { Self.memoryText(residentBytes) }

    static func memoryText(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    static func isLikelyHTTPPort(_ port: Int) -> Bool {
        let known: Set<Int> = [80, 443, 1313, 1337, 3000, 4200, 4321, 5173, 5174, 7777, 7860, 8443, 11434, 19006]
        if known.contains(port) { return true }
        let ranges = [3000...3999, 4000...4999, 5000...5099, 5170...5180, 8000...8999, 9000...9099]
        return ranges.contains { $0.contains(port) }
    }

    /// Longest label the UI should have to lay out.
    static let displayNameLimit = 60

    /// Best short label for a process: the lsof command name plus up to two
    /// meaningful argv tokens (flags, numbers and long absolute paths dropped),
    /// e.g. `node /Users/me/app/node_modules/.bin/next dev` → `node — next dev`.
    /// Pure on purpose so it stays unit-testable.
    static func displayName(command: String, commandLine: String) -> String {
        let base = command.isEmpty ? "process" : command
        var detail: [String] = []

        for token in commandLine.split(separator: " ").dropFirst() {
            guard detail.count < 2 else { break }
            guard !token.hasPrefix("-"), Int(token) == nil else { continue }
            let leaf = token.contains("/") ? String(token.split(separator: "/").last ?? "") : String(token)
            let cleaned = leaf.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard cleaned.count > 1, cleaned.count <= 40, !base.contains(cleaned) else { continue }
            detail.append(cleaned)
        }

        let label = detail.isEmpty ? base : "\(base) — \(detail.joined(separator: " "))"
        guard label.count > displayNameLimit else { return label }
        return String(label.prefix(displayNameLimit - 1)) + "…"
    }

    /// The published order: category ascending, then uptime descending (an
    /// oldest-first `startedAt`), then primary port ascending. Pure so the
    /// ranking can be asserted without running a scan.
    static func rank(_ servers: [LocalServerProcess]) -> [LocalServerProcess] {
        servers.sorted { lhs, rhs in
            if lhs.category != rhs.category { return lhs.category < rhs.category }
            // No start time means "we don't know", which sorts as youngest.
            let lhsStart = lhs.startedAt ?? .distantFuture
            let rhsStart = rhs.startedAt ?? .distantFuture
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            if lhs.primaryPort != rhs.primaryPort { return lhs.primaryPort < rhs.primaryPort }
            return lhs.pid < rhs.pid
        }
    }
}

// MARK: - Classification

/// Pure, filesystem-light rules that decide which tier a listener belongs to.
/// Split out of the service so every branch is unit-testable without shelling
/// anything out.
enum ServerClassifier {

    /// macOS hands out ephemeral ports from 49152, but plenty of runtimes pick
    /// their own above 32768; treat everything from there up as "not typed by a
    /// human".
    static let ephemeralPortFloor = 32_768

    /// Toolchain daemons: shared, restartable, and — crucially — often started
    /// from inside a project checkout, which is why they are matched *before*
    /// the cwd rules.
    static let toolchainBinaries: Set<String> = [
        "adb", "com.docker.backend", "docker", "dockerd", "ngrok", "cloudflared",
        "mysqld", "postgres", "redis-server", "mongod", "metro", "gradle", "java", "containerd",
    ]

    static let systemPathPrefixes = ["/System", "/usr/libexec", "/usr/sbin", "/Library/Apple"]

    /// `/private/var/folders` is the resolved form lsof actually reports.
    static let scratchRootPrefixes = ["/private/tmp", "/tmp", "/private/var/folders", "/var/folders"]

    /// Agent scratch directories live under a `/scratchpad` component wherever
    /// their parent happens to be.
    static let scratchMarker = "/scratchpad"

    static var developerRoots: [String] {
        let home = NSHomeDirectory()
        return ["Developer", "src", "code", "Projects", "repos", "dev", "work"].map { "\(home)/\($0)" }
    }

    /// First match wins; the order is load-bearing. See the tests for the traps
    /// it is protecting against (adb's cwd is a project, `logserve.py`'s cwd is
    /// a project but its script lives in /tmp).
    static func category(
        command: String,
        commandLine: String,
        executablePath: String?,
        workingDirectory: String?,
        user: String,
        isSelf: Bool
    ) -> ServerCategory {
        _ = user // Part of the shared contract; no rule needs it yet.

        // 1. Us.
        if isSelf { return .selfApp }

        let binary = executablePath ?? firstPathToken(in: commandLine)

        // 2. Toolchain daemons, before anything that looks at the cwd.
        if isToolchain(command: command, executablePath: binary) { return .devTool }

        // 3. Apple's own daemons and network extensions.
        if isSystemExecutable(path: binary, commandLine: commandLine) { return .system }

        // 4. Anything whose cwd *or* script path sits in a scratch directory.
        if scratchRoot(commandLine: commandLine, executablePath: executablePath, workingDirectory: workingDirectory) != nil {
            return .scratch
        }

        // 5. Started from a checkout.
        if let workingDirectory, isDeveloperDirectory(workingDirectory) { return .devServer }

        // 6. Shipped inside an .app bundle.
        if isAppBundle(command: command, path: binary, commandLine: commandLine) { return .app }

        // 7. Unknown daemon — least alarming bucket that is still killable.
        return .devTool
    }

    /// Git repo name, else the working directory's own last component.
    /// `gitRoot` is injectable so tests never need a real checkout.
    static func projectName(
        workingDirectory: String?,
        gitRoot: (String) -> String? = ServerClassifier.gitRoot(for:)
    ) -> String? {
        guard let workingDirectory, workingDirectory != "/", !workingDirectory.isEmpty else { return nil }
        let root = gitRoot(workingDirectory) ?? workingDirectory
        let name = URL(fileURLWithPath: root).lastPathComponent
        return (name.isEmpty || name == "/") ? nil : name
    }

    /// Walks the directory tree up looking for a `.git` entry. Deliberately
    /// FileManager-only: shelling out to `git` for every listener on every
    /// eight-second refresh would be absurd, and `git` may not even be there.
    static func gitRoot(for directory: String) -> String? {
        let fileManager = FileManager.default
        var url = URL(fileURLWithPath: directory).standardizedFileURL
        var depth = 0

        while url.path != "/", depth < 64 {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
            depth += 1
        }
        return nil
    }

    /// The scratch root that matched, so the subtitle can say *which* one.
    static func scratchRoot(commandLine: String, executablePath: String?, workingDirectory: String?) -> String? {
        var candidates: [String] = []
        if let workingDirectory { candidates.append(workingDirectory) }
        if let executablePath { candidates.append(executablePath) }
        candidates.append(contentsOf: commandLine.split(separator: " ").map(String.init).filter { $0.contains("/") })

        for candidate in candidates {
            if let root = scratchRootPrefixes.first(where: { isUnder(candidate, root: $0) }) { return root }
            if candidate.contains("\(scratchMarker)/") || candidate.hasSuffix(scratchMarker) { return scratchMarker }
        }
        return nil
    }

    static func isDeveloperDirectory(_ directory: String) -> Bool {
        if gitRoot(for: directory) != nil { return true }
        return developerRoots.contains { isUnder(directory, root: $0) }
    }

    static func isToolchain(command: String, executablePath: String?) -> Bool {
        var names = [command]
        if let executablePath { names.append(URL(fileURLWithPath: executablePath).lastPathComponent) }
        return names.contains { toolchainBinaries.contains($0) }
    }

    static func isSystemExecutable(path: String?, commandLine: String) -> Bool {
        // Network extensions (.appex) can live anywhere, including inside a
        // third-party bundle — Tailscale's IPNExtension is the local example.
        if path?.contains(".appex") == true || commandLine.contains(".appex/") { return true }
        guard let path else { return false }
        return systemPathPrefixes.contains { isUnder(path, root: $0) }
    }

    static func isAppBundle(command: String, path: String?, commandLine: String) -> Bool {
        // Electron/Chromium helpers ("Cursor Helper (Plugin): extension-host …")
        // report no argv[0] path at all, so the process name is the only tell.
        if command.contains(" Helper") { return true }
        for candidate in [path, commandLine].compactMap({ $0 }) {
            if candidate.contains("/Applications/") || candidate.contains(".app/Contents/MacOS/") { return true }
        }
        return false
    }

    static let knownPorts: [Int: String] = [
        80: "HTTP",
        443: "HTTPS",
        3306: "MySQL",
        5000: "AirPlay Receiver",
        5037: "adb",
        5432: "PostgreSQL",
        6379: "Redis",
        7000: "AirPlay Receiver",
        11434: "Ollama",
        27017: "MongoDB",
        59374: "Handoff",
    ]

    static func knownPortName(_ port: Int) -> String? { knownPorts[port] }

    /// argv[0] when it looks like a path at all.
    static func firstPathToken(in commandLine: String) -> String? {
        guard let first = commandLine.split(separator: " ").first, first.contains("/") else { return nil }
        return String(first)
    }

    /// Path-component-aware prefix test, so `/tmpfoo` is not "under" `/tmp`.
    static func isUnder(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix("\(root)/")
    }
}

// MARK: - Pure parsing helpers

/// Parses the line-oriented `lsof -F` field output. `p`/`c`/`L` lines open a
/// process block and apply to every following `f` (file descriptor) block until
/// the next `p`; each fd block carries `t` (family), `P` (protocol) and
/// `n` (`address:port`).
enum LSOFListenParser {
    struct Row: Equatable, Sendable {
        let pid: pid_t
        let command: String
        let user: String
        let address: String
        let port: Int
        let family: String
    }

    /// One listening process, with every port it holds.
    struct Listener: Equatable, Sendable {
        let pid: pid_t
        let ports: [Int]
        let addresses: [String]
        let command: String
        let user: String
    }

    static func parse(_ lsofFieldOutput: String) -> [Row] {
        var rows: [Row] = []
        var pid: pid_t?
        var command = ""
        var user = ""
        var family = ""
        var proto = ""
        var name: String?

        func flushDescriptor() {
            defer {
                family = ""
                proto = ""
                name = nil
            }
            guard let pid, let name, proto.isEmpty || proto == "TCP",
                  let endpoint = splitAddress(name)
            else { return }
            rows.append(Row(
                pid: pid,
                command: command,
                user: user,
                address: endpoint.address,
                port: endpoint.port,
                family: family
            ))
        }

        for rawLine in lsofFieldOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p":
                flushDescriptor()
                pid = pid_t(value)
                command = ""
                user = ""
            case "c": command = value
            case "L": user = value
            case "f": flushDescriptor()
            case "t": family = value
            case "P": proto = value
            case "n": name = value
            default: continue
            }
        }
        flushDescriptor()
        return rows
    }

    /// One entry per pid: every port and every bind address of one process fold
    /// into a single `Listener`. Ports ascending and deduped; the list is
    /// ordered by lowest port then pid so it is stable before ranking.
    static func mergeProcesses(_ rows: [Row]) -> [Listener] {
        var order: [pid_t] = []
        var byPID: [pid_t: (ports: [Int], addresses: [String], command: String, user: String)] = [:]

        for row in rows {
            if var existing = byPID[row.pid] {
                if !existing.ports.contains(row.port) { existing.ports.append(row.port) }
                if !existing.addresses.contains(row.address) { existing.addresses.append(row.address) }
                if existing.command.isEmpty { existing.command = row.command }
                if existing.user.isEmpty { existing.user = row.user }
                byPID[row.pid] = existing
            } else {
                order.append(row.pid)
                byPID[row.pid] = (ports: [row.port], addresses: [row.address], command: row.command, user: row.user)
            }
        }

        return order
            .compactMap { pid -> Listener? in
                guard let entry = byPID[pid] else { return nil }
                return Listener(
                    pid: pid,
                    ports: entry.ports.sorted(),
                    addresses: entry.addresses,
                    command: entry.command,
                    user: entry.user
                )
            }
            .sorted { ($0.ports.first ?? 0, $0.pid) < ($1.ports.first ?? 0, $1.pid) }
    }

    /// `*:8787` → (`*`, 8787), `127.0.0.1:3000` → (`127.0.0.1`, 3000),
    /// `[::1]:3000` → (`::1`, 3000). Nil when the port is not numeric.
    static func splitAddress(_ name: String) -> (address: String, port: Int)? {
        guard let separator = name.lastIndex(of: ":") else { return nil }
        guard let port = Int(name[name.index(after: separator)...]), port > 0 else { return nil }
        var address = String(name[..<separator])
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        guard !address.isEmpty else { return nil }
        return (address, port)
    }
}

/// Parses `lsof -a -p <pids> -d cwd -Fn`, which is the same field format with
/// only `p` (pid), `f` (always `cwd`) and `n` (the path) lines.
enum LSOFWorkingDirectoryParser {
    static func parse(_ lsofFieldOutput: String) -> [pid_t: String] {
        var directories: [pid_t: String] = [:]
        var pid: pid_t?

        for rawLine in lsofFieldOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = rawLine.first else { continue }
            let value = String(rawLine.dropFirst())
            switch tag {
            case "p": pid = pid_t(value)
            case "n":
                guard let pid, !value.isEmpty, directories[pid] == nil else { continue }
                directories[pid] = value
            default: continue
            }
        }
        return directories
    }
}

enum ProcessUptimeFormatter {
    static func text(since: Date?, now: Date) -> String {
        guard let since else { return "—" }
        let seconds = Int(max(0, now.timeIntervalSince(since)))

        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 {
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
    }
}

// MARK: - Service

@MainActor
final class LocalServerScanService: ObservableObject {

    static let shared = LocalServerScanService()

    /// Fully ranked: category ascending, uptime descending, primary port
    /// ascending — background services therefore always sit at the end.
    @Published private(set) var servers: [LocalServerProcess] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastError: String?

    /// The listeners worth showing up front.
    var ranked: [LocalServerProcess] { servers.filter { !$0.category.isBackground } }

    /// `.app` / `.system` / `.selfApp`, for the collapsed section or submenu.
    var background: [LocalServerProcess] { servers.filter { $0.category.isBackground } }

    private let scanQueue = DispatchQueue(label: "vibe.servers.scan")
    private var refreshTimer: Timer?
    private var pendingRefresh: Task<Void, Never>?
    private var isMenuTracking = false
    private var deferredOutcome: ScanOutcome?

    private struct ScanOutcome: Sendable {
        let servers: [LocalServerProcess]
        let error: String?
    }

    init() {
        // Publishing into an open menu makes SwiftUI rebuild it under the pointer: the item labels
        // carry a live uptime and the parent carries a live count, so a refresh mid-interaction
        // reshuffles the menu and can drop the submenu the user is aiming at. Hold results back
        // while any menu is tracking and flush them the moment it closes.
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMenuTracking = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.endMenuTracking() }
        }
    }

    private func endMenuTracking() {
        isMenuTracking = false
        if let outcome = deferredOutcome {
            deferredOutcome = nil
            apply(outcome)
        }
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            let outcome = Self.performScan()
            Task { @MainActor in self?.apply(outcome) }
        }
    }

    func startAutoRefresh(interval: TimeInterval = 8) {
        stopAutoRefresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // .common so the timer keeps firing while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    @discardableResult
    func terminate(_ server: LocalServerProcess, force: Bool = false) -> Bool {
        guard server.category.isKillable else {
            lastError = "\(server.displayName) is VibeWindowManager itself, so it will not be quit from here."
            return false
        }
        let sent = kill(server.pid, force ? SIGKILL : SIGTERM)
        let succeeded = sent == 0
        if !succeeded {
            let reason = String(cString: strerror(errno))
            lastError = "Could not \(force ? "force quit" : "quit") \(server.displayName) (pid \(server.pid)): \(reason)"
        }
        scheduleRefresh(after: 1)
        return succeeded
    }

    func uptimeText(for server: LocalServerProcess, now: Date = Date()) -> String {
        ProcessUptimeFormatter.text(since: server.startedAt, now: now)
    }

    private func apply(_ outcome: ScanOutcome) {
        isScanning = false
        guard !isMenuTracking else {
            deferredOutcome = outcome
            return
        }
        servers = outcome.servers
        lastError = outcome.error
        lastScan = Date()
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: - Off-main-thread scan

    private nonisolated static func performScan() -> ScanOutcome {
        let lsofPath = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsofPath) else {
            return ScanOutcome(servers: [], error: "\(lsofPath) is missing, so listening ports cannot be read.")
        }

        let lsof = runTool(lsofPath, ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLtPn"])
        guard let output = lsof.output, !output.isEmpty else {
            let detail = lsof.failure ?? "lsof returned no output."
            return ScanOutcome(servers: [], error: "Could not list listening ports: \(detail)")
        }

        let listeners = LSOFListenParser.mergeProcesses(LSOFListenParser.parse(output))
        guard !listeners.isEmpty else { return ScanOutcome(servers: [], error: nil) }

        let pids = listeners.map(\.pid)
        let details = processDetails(for: pids)
        let directories = workingDirectories(for: pids)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath().path

        let servers = listeners.map { entry -> LocalServerProcess in
            let detail = details[entry.pid]
            let commandLine = detail?.commandLine ?? ""
            let executablePath = ServerClassifier.firstPathToken(in: commandLine)
            let workingDirectory = directories[entry.pid]
            let isSelf = entry.pid == selfPID || (executablePath != nil && executablePath == selfExecutable)

            let category = ServerClassifier.category(
                command: entry.command,
                commandLine: commandLine,
                executablePath: executablePath,
                workingDirectory: workingDirectory,
                user: entry.user,
                isSelf: isSelf
            )
            // Only dev servers get a project label; a scratch script's directory
            // is noise and a daemon's cwd is usually `/`.
            let projectName = category == .devServer
                ? ServerClassifier.projectName(workingDirectory: workingDirectory)
                : nil

            return LocalServerProcess(
                pid: entry.pid,
                ports: entry.ports,
                bindAddresses: entry.addresses,
                command: entry.command,
                user: entry.user,
                commandLine: commandLine,
                executablePath: executablePath,
                workingDirectory: workingDirectory,
                startedAt: detail?.startedAt,
                residentBytes: detail?.residentBytes,
                category: category,
                projectName: projectName
            )
        }
        return ScanOutcome(servers: LocalServerProcess.rank(servers), error: nil)
    }

    /// One batched `ps -o pid=,rss=,lstart=,command= -p 1,2,3` for every pid we saw.
    /// `command=` stays last because it is the only field that can contain spaces.
    private nonisolated static func processDetails(for pids: [pid_t]) -> [pid_t: ProcessDetail] {
        guard !pids.isEmpty else { return [:] }
        let ps = runTool("/bin/ps", ["-o", "pid=,rss=,lstart=,command=", "-p", pids.map(String.init).joined(separator: ",")])
        guard let output = ps.output else { return [:] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        var details: [pid_t: ProcessDetail] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = line.drop { $0 == " " }
            let digits = rest.prefix { $0.isNumber }
            guard let pid = pid_t(digits) else { continue }
            rest = rest.dropFirst(digits.count)

            // `rss` is resident set size in kilobytes.
            rest = rest.drop { $0 == " " }
            let rssDigits = rest.prefix { $0.isNumber }
            let residentBytes = Int(rssDigits).map { $0 * 1024 }
            rest = rest.dropFirst(rssDigits.count)

            // `lstart` is five whitespace-separated fields: "Thu Jul  2 19:04:31 2026".
            var stamp: [String] = []
            for _ in 0..<5 {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { break }
                stamp.append(String(rest[..<end]))
                rest = rest[end...]
            }
            let commandLine = String(rest.drop { $0 == " " })
            let startedAt = stamp.count == 5 ? formatter.date(from: stamp.joined(separator: " ")) : nil
            details[pid] = ProcessDetail(startedAt: startedAt, commandLine: commandLine, residentBytes: residentBytes)
        }
        return details
    }

    struct ProcessDetail: Sendable {
        let startedAt: Date?
        let commandLine: String
        let residentBytes: Int?
    }

    /// One batched `lsof -a -p 1,2,3 -d cwd -Fn`. Processes we may not inspect
    /// simply come back missing, which is the same as "unknown".
    private nonisolated static func workingDirectories(for pids: [pid_t]) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let lsof = runTool("/usr/sbin/lsof", ["-a", "-p", pids.map(String.init).joined(separator: ","), "-d", "cwd", "-Fn"])
        guard let output = lsof.output else { return [:] }
        return LSOFWorkingDirectoryParser.parse(output)
    }

    private nonisolated static func runTool(_ path: String, _ arguments: [String]) -> (output: String?, failure: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return (nil, error.localizedDescription)
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8)
        let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // lsof exits non-zero for harmless warnings, so stdout wins when present.
        if stdout?.isEmpty == false { return (stdout, nil) }
        let failure = (stderr?.isEmpty == false) ? stderr : "\(path) exited with status \(process.terminationStatus)."
        return (stdout, failure)
    }
}
