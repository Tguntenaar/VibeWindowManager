//
//  MediaTabView.swift
//  VibeWindowManager
//
//  Media key forwarding + AirPods → Spotify redirect controls.
//

import SwiftUI

struct MediaTabView: View {
    @ObservedObject var media: MediaControlService
    @AppStorage("vibeMediaKeysEnabled") private var mediaKeysEnabled: Bool = false
    @AppStorage("vibeMusicRedirectEnabled") private var musicRedirectEnabled: Bool = false
    @AppStorage("vibeAirPodsCaptureEnabled") private var airPodsCaptureEnabled: Bool = false
    @AppStorage("vibeF5NoiseToggleEnabled") private var f5NoiseToggleEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Media keys & AirPods")
                        .font(.title2.weight(.semibold))
                    Text("Route the keyboard media keys and the AirPods stem click to Spotify instead of Apple Music — including when Spotify isn't running yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $mediaKeysEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Forward media keys to Spotify")
                                .font(.subheadline.weight(.medium))
                            Text("Play/pause, next and previous keys always control Spotify. If Spotify is closed, the play key launches it and starts playback.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    if mediaKeysEnabled && !media.accessibilityTrusted {
                        Label("Accessibility permission is required for the key tap. Grant it in System Settings → Privacy & Security → Accessibility, then toggle off and on.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Divider()

                    Toggle(isOn: $airPodsCaptureEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Capture AirPods clicks directly")
                                .font(.subheadline.weight(.medium))
                            Text("While Spotify is closed, this app holds the system Now Playing slot so a stem click routes here and launches Spotify — Apple Music never opens. Released automatically whenever Spotify is running.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    Toggle(isOn: $musicRedirectEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Redirect Apple Music to Spotify (fallback)")
                                .font(.subheadline.weight(.medium))
                            Text("Safety net: if Apple Music still opens for any reason, quit it immediately, launch Spotify and start playback. Turn this off if you ever want to use Apple Music.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    Toggle(isOn: $f5NoiseToggleEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("F5 toggles Noise Cancellation ↔ Transparency")
                                .font(.subheadline.weight(.medium))
                            Text("While AirPods are the active output, F5 switches between Noise Cancellation and Transparency (via Control Center). Without AirPods, F5 behaves normally.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Divider()

                    Toggle(isOn: $media.launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at login")
                                .font(.subheadline.weight(.medium))
                            Text("Start VibeWindowManager automatically so media keys and AirPods routing work right after login.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Status")
                        .font(.headline)
                    statusRow(ok: media.mediaKeyTapActive, on: "Media key tap active", off: "Media key tap inactive")
                    statusRow(ok: media.accessibilityTrusted, on: "Accessibility granted", off: "Accessibility not granted")
                    statusRow(ok: media.spotifyRunning, on: "Spotify is running", off: "Spotify is not running")
                    if media.airPodsCaptureActive {
                        statusRow(ok: media.decoyHoldsNowPlaying, on: "Holding Now Playing slot (AirPods clicks come here)", off: "Now Playing slot released (Spotify owns routing)")
                    }
                    if media.f5NoiseToggleActive, let mode = media.lastNoiseMode {
                        Text("Last F5 toggle: \(mode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if media.musicRedirectCount > 0 {
                        Text("Blocked Apple Music \(media.musicRedirectCount)× this session")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let action = media.lastAction {
                        Text("Last action: \(action)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh") { media.refreshPermissions() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)

                Label("If MacMediaKeyForwarder is still running (it opens at login), quit it and remove it from Login Items — otherwise both apps grab the media keys.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            media.refreshPermissions()
            media.setMediaKeysEnabled(mediaKeysEnabled)
            media.setMusicInterceptionEnabled(musicRedirectEnabled)
            media.setAirPodsCaptureEnabled(airPodsCaptureEnabled)
            media.setF5NoiseToggleEnabled(f5NoiseToggleEnabled)
        }
        .onChange(of: mediaKeysEnabled) { _, enabled in
            media.setMediaKeysEnabled(enabled)
        }
        .onChange(of: f5NoiseToggleEnabled) { _, enabled in
            media.setF5NoiseToggleEnabled(enabled)
        }
        .onChange(of: musicRedirectEnabled) { _, enabled in
            media.setMusicInterceptionEnabled(enabled)
        }
        .onChange(of: airPodsCaptureEnabled) { _, enabled in
            media.setAirPodsCaptureEnabled(enabled)
        }
    }

    private func statusRow(ok: Bool, on: String, off: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(ok ? on : off)
                .font(.subheadline)
                .foregroundStyle(ok ? .primary : .secondary)
        }
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
