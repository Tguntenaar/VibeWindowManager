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
import CoreAudio
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
    @Published private(set) var f5NoiseToggleActive = false
    @Published private(set) var lastNoiseMode: String?
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled) {
        didSet { applyLaunchAtLogin() }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "vibe.media.osascript")
    private var mediaKeysWanted = false
    private var f5ToggleWanted = false
    private var noiseToggleBusy = false

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
        mediaKeysWanted = enabled
        rebuildTap()
    }

    func setF5NoiseToggleEnabled(_ enabled: Bool) {
        f5ToggleWanted = enabled
        f5NoiseToggleActive = enabled
        rebuildTap()
    }

    private func rebuildTap() {
        stopMediaKeyTap()
        if mediaKeysWanted || f5ToggleWanted { startMediaKeyTap() }
        mediaKeyTapActive = mediaKeysWanted && eventTap != nil
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
        // Plain key-downs are only tapped when the F5 noise toggle wants them.
        var mask: CGEventMask = 0
        if mediaKeysWanted { mask |= CGEventMask(1 << 14) }
        if f5ToggleWanted { mask |= CGEventMask(1 << CGEventType.keyDown.rawValue) }
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
            f5NoiseToggleActive = false
            lastAction = "Could not create event tap — grant Accessibility permission and retry."
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
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

        if type == .keyDown {
            // Key-downs are only in the tap mask when the F5 noise toggle is on.
            guard cgEvent.getIntegerValueField(.keyboardEventKeycode) == 96, // F5
                  Self.defaultOutputIsAirPodsLike()
            else {
                return Unmanaged.passUnretained(cgEvent)
            }
            if cgEvent.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                Task { @MainActor in self.toggleAirPodsNoiseMode() }
            }
            return nil
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

    // MARK: - F5 → AirPods noise mode toggle
    //
    // There is no public API for AirPods listening modes, so this UI-scripts
    // the Control Center Sound pane (works with the Sound menu icon hidden).
    // The event tap only swallows F5 while AirPods are the default output.

    private nonisolated static func defaultOutputIsAirPodsLike() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown
        else { return false }

        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        else { return false }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
              let cfName = name?.takeRetainedValue()
        else { return false }
        return (cfName as String).localizedCaseInsensitiveContains("AirPods")
    }

    func toggleAirPodsNoiseMode() {
        guard !noiseToggleBusy else { return }
        noiseToggleBusy = true
        lastAction = "F5 — toggling AirPods noise mode…"
        scriptQueue.async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", Self.noiseToggleScript]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            var result = "script-failed"
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "script-failed"
                if result.isEmpty { result = "script-failed" }
            } catch {
                result = "script-failed"
            }
            Task { @MainActor in
                guard let self else { return }
                self.noiseToggleBusy = false
                self.lastNoiseMode = result
                self.lastAction = "AirPods noise mode → \(result)"
            }
        }
    }

    private nonisolated static let noiseToggleScript = """
    tell application "System Events"
        tell application process "ControlCenter"
            set panelOpen to false
            repeat with mbi in menu bar items of menu bar 1
                try
                    if (value of attribute "AXIdentifier" of mbi) is "com.apple.menuextra.controlcenter" then
                        click mbi
                        set panelOpen to true
                        exit repeat
                    end if
                end try
            end repeat
            if not panelOpen then return "no-control-center"
            repeat 10 times
                delay 0.12
                if (count of windows) > 0 then exit repeat
            end repeat
            if (count of windows) is 0 then return "no-panel"
            set volBtn to missing value
            try
                repeat with e in UI elements of group 1 of window 1
                    try
                        if (value of attribute "AXIdentifier" of e) is "controlcenter-volume" then
                            set volBtn to e
                            exit repeat
                        end if
                    end try
                end repeat
            end try
            if volBtn is missing value then
                key code 53
                return "no-volume-button"
            end if
            click volBtn
            delay 0.35
            set sa to missing value
            try
                set sa to scroll area 1 of group 1 of window 1
            end try
            if sa is missing value then
                key code 53
                return "no-sound-pane"
            end if
            set kids to UI elements of sa
            set devID to ""
            set triIndex to -1
            repeat with i from 1 to count of kids
                set e to item i of kids
                try
                    if (role of e) is "AXDisclosureTriangle" then
                        set candID to (value of attribute "AXIdentifier" of e) as string
                        if i < (count of kids) then
                            set cb to item (i + 1) of kids
                            if (role of cb) is "AXCheckBox" and ((value of attribute "AXIdentifier" of cb) as string) is candID then
                                if ((value of cb) as integer) is 1 then
                                    set devID to candID
                                    set triIndex to i
                                    if ((value of e) as integer) is 0 then
                                        click e
                                        delay 0.3
                                    end if
                                    exit repeat
                                end if
                            end if
                        end if
                    end if
                end try
            end repeat
            if triIndex < 1 then
                key code 53
                return "no-active-headphones"
            end if
            set kids to UI elements of sa
            set modeIdxs to {}
            set seenDevice to false
            repeat with i from 1 to count of kids
                set e to item i of kids
                try
                    if ((value of attribute "AXIdentifier" of e) as string) is devID and (role of e) is "AXCheckBox" then
                        if seenDevice then
                            if (count of modeIdxs) < 3 then set end of modeIdxs to i
                        else
                            set seenDevice to true
                        end if
                    end if
                end try
            end repeat
            if (count of modeIdxs) < 3 then
                key code 53
                return "no-noise-modes"
            end if
            set trBox to item (item 1 of modeIdxs) of kids
            set ncBox to item (item 3 of modeIdxs) of kids
            if ((value of ncBox) as integer) is 1 then
                click trBox
                set outMode to "Transparency"
            else
                click ncBox
                set outMode to "Noise Cancellation"
            end if
            delay 0.15
            key code 53
            return outMode
        end tell
    end tell
    """

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
