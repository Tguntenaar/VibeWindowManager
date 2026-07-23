//
//  MediaControlService.swift
//  VibeWindowManager
//
//  Media key forwarding (ported from milgra/macmediakeyforwarder) plus
//  Apple Music launch interception so AirPods play always lands in Spotify.
//

import AppKit
import ApplicationServices
import Combine
import MediaPlayer
import ServiceManagement

@MainActor
final class MediaControlService: ObservableObject {

    static let spotifyBundleID = "com.spotify.client"
    static let musicBundleIDs: Set<String> = ["com.apple.Music", "com.apple.iTunes"]

    // NX_KEYTYPE_* values from IOKit/hidsystem/ev_keymap.h
    private enum MediaKey: Int {
        case play = 16
        case next = 17
        case previous = 18
        case fast = 19
        case rewind = 20
    }

    @Published private(set) var mediaKeyTapActive = false
    @Published private(set) var musicInterceptionActive = false
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var spotifyRunning = false
    @Published private(set) var musicRedirectCount = 0
    @Published private(set) var lastAction: String?
    @Published private(set) var airPodsCaptureActive = false
    @Published private(set) var decoyHoldsNowPlaying = false
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { applyLaunchAtLogin() }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "vibe.media.osascript")

    init() {
        refreshSpotifyRunning()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.refreshSpotifyRunning()
                if let app { self?.handleAppLaunched(app) }
                self?.updateDecoyClaim()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSpotifyRunning()
                self?.updateDecoyClaim()
            }
        })
    }

    // MARK: - Media key forwarding (event tap)

    func setMediaKeysEnabled(_ enabled: Bool) {
        enabled ? startMediaKeyTap() : stopMediaKeyTap()
    }

    private func startMediaKeyTap() {
        guard eventTap == nil else { return }
        accessibilityTrusted = AXIsProcessTrusted()

        let callback: CGEventTapCallBack = { _, type, cgEvent, refcon in
            guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
            let service = Unmanaged<MediaControlService>.fromOpaque(refcon).takeUnretainedValue()
            return service.handleTapEvent(type: type, cgEvent: cgEvent)
        }

        // NX_SYSDEFINED == 14; media keys arrive as system-defined events.
        let mask = CGEventMask(1 << 14)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            mediaKeyTapActive = false
            lastAction = "Could not create event tap — grant Accessibility permission and retry."
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        mediaKeyTapActive = true
    }

    private func stopMediaKeyTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        mediaKeyTapActive = false
    }

    private nonisolated func handleTapEvent(type: CGEventType, cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let tap = self.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard type.rawValue == 14, // NX_SYSDEFINED
              let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.subtype.rawValue == 8
        else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let data1 = nsEvent.data1
        guard let key = MediaKey(rawValue: (data1 & 0xFFFF_0000) >> 16) else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let keyFlags = data1 & 0x0000_FFFF
        let keyIsPressed = ((keyFlags & 0xFF00) >> 8) == 0xA

        if keyIsPressed {
            Task { @MainActor in self.performMediaAction(for: key) }
        }

        // Swallow both press and release so Music/rcd never sees the key.
        return nil
    }

    private func performMediaAction(for key: MediaKey) {
        switch key {
        case .play:
            if spotifyRunning {
                runSpotifyScript("playpause", describe: "Play/pause → Spotify")
            } else {
                openSpotifyAndPlay(reason: "Play key with Spotify closed")
            }
        case .next, .fast:
            runSpotifyScript("next track", describe: "Next track → Spotify")
        case .previous, .rewind:
            runSpotifyScript("previous track", describe: "Previous track → Spotify")
        }
    }

    // MARK: - Apple Music launch interception (AirPods fix)

    func setMusicInterceptionEnabled(_ enabled: Bool) {
        musicInterceptionActive = enabled
    }

    private func handleAppLaunched(_ app: NSRunningApplication) {
        guard musicInterceptionActive,
              let bundleID = app.bundleIdentifier,
              Self.musicBundleIDs.contains(bundleID)
        else { return }
        app.forceTerminate()
        musicRedirectCount += 1
        openSpotifyAndPlay(reason: "Blocked Apple Music launch")
    }

    private func refreshSpotifyRunning() {
        spotifyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyBundleID).isEmpty
    }

    // MARK: - Spotify control

    private func openSpotifyAndPlay(reason: String) {
        // "tell application" launches Spotify when needed, then starts playback.
        runSpotifyScript("play", describe: "\(reason) → launched Spotify and pressed play")
    }

    private func runSpotifyScript(_ command: String, describe: String) {
        lastAction = describe
        let source = "tell application \"Spotify\" to \(command)"
        scriptQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
            try? process.run()
            process.waitUntilExit()
        }
    }

    func refreshPermissions() {
        accessibilityTrusted = AXIsProcessTrusted()
        refreshSpotifyRunning()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        updateDecoyClaim()
    }

    // MARK: - AirPods direct capture (Now Playing decoy)
    //
    // While Spotify is closed, claim the system Now Playing slot with a silent
    // placeholder. AirPods stem clicks then route to our remote-command
    // handlers instead of making macOS launch Apple Music. The claim is
    // dropped the moment Spotify launches so it owns its own routing.

    func setAirPodsCaptureEnabled(_ enabled: Bool) {
        airPodsCaptureActive = enabled
        if enabled {
            registerRemoteCommands()
            updateDecoyClaim()
        } else {
            unregisterRemoteCommands()
            dropNowPlayingClaim()
        }
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let launchHandler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            Task { @MainActor in
                self?.openSpotifyAndPlay(reason: "AirPods click captured")
            }
            return .success
        }
        for command in [center.togglePlayPauseCommand, center.playCommand, center.nextTrackCommand, center.previousTrackCommand] {
            command.isEnabled = true
            command.addTarget(handler: launchHandler)
        }
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in .success }
    }

    private func unregisterRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand, center.nextTrackCommand, center.previousTrackCommand] {
            command.removeTarget(nil)
            command.isEnabled = false
        }
    }

    private func updateDecoyClaim() {
        guard airPodsCaptureActive else { return }
        if spotifyRunning {
            dropNowPlayingClaim()
        } else {
            claimNowPlaying()
        }
    }

    private func claimNowPlaying() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: "Spotify — click to resume",
            MPMediaItemPropertyArtist: "VibeWindowManager",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyPlaybackDuration: 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = .playing
        decoyHoldsNowPlaying = true
    }

    private func dropNowPlayingClaim() {
        guard decoyHoldsNowPlaying else { return }
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        decoyHoldsNowPlaying = false
    }

    // MARK: - Launch at login

    private func applyLaunchAtLogin() {
        let wantEnabled = launchAtLogin
        let isEnabled = SMAppService.mainApp.status == .enabled
        guard wantEnabled != isEnabled else { return }
        do {
            if wantEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastAction = "Login item change failed: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
