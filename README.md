# VibeWindowManager

**VibeWindowManager** is a macOS app and command-line tool for managing window layout and focus—tailored for terminal-heavy setups (e.g. **Ghostty** column splits, app grids, cascade layouts). A **bridge** on your Mac streams live window geometry to a companion [iOS app](https://github.com/Tguntenaar/VibeWindowManagerIOS) so you can see and control layout from an iPhone or iPad on the same network.

## Highlights

- **Layout engine** — Arrange and mirror windows for supported apps; focus and cycle windows from the app or CLI.
- **LAN / Tailnet bridge** — WebSocket server (default `19842`, path `/bridge`) with **Bonjour** discovery (`_vibewm._tcp`) and optional **Tailscale MagicDNS** for off-LAN or split-network setups.
- **Accessibility** — Uses macOS Accessibility APIs; grant permissions when prompted.
- **Command-line** — `windows` (and related) subcommands; see the docs below.

v1 targets a **trusted network** (home/small office). For hardening, treat future `wss://` and pairing as follow-ups.

## Requirements

- **macOS** with a recent **Xcode** (open `VibeWindowManager.xcodeproj`).
- For Ghostty- or app-specific features, have those apps installed as needed.
- For **Tailnet auto-connect** from iOS, **Tailscale** on the Mac (CLI or app) so the bridge UI can show this machine’s **MagicDNS** hostname; iOS still works with **Bonjour-only** on the same Wi‑Fi if you do not use Tailscale.

## Quick start (bridge + iOS)

1. Open the project in Xcode, build, and run the **VibeWindowManager** app.
2. Turn on the **iOS layout bridge** in the app (default app query, port `19842`).
3. On your iPhone or iPad, install and run **[VibeWindowManagerIOS](https://github.com/Tguntenaar/VibeWindowManagerIOS)**. Connect via Tailnet, Bonjour, or manual `IP:19842`.
4. Grant **local network** access on iOS if the system prompt appears.

`windows bridge-dump <app>` prints the same `layout` JSON the bridge sends (useful for debugging).

## Documentation

| Doc | Description |
|-----|-------------|
| [`docs/CLI.md`](docs/CLI.md) | `VibeWindowManager` / `windows` commands |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | WebSocket message types (bridge protocol) |
| [`docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md`](docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md) | Design notes: transport, where speech-to-text runs, phased work |

**Where to implement what:** add **server** behavior (bridge, Bonjour, STT) in this repo. Add **iOS client** features in the [iOS repository](https://github.com/Tguntenaar/VibeWindowManagerIOS). Shared message shapes belong in the protocol doc first, then in code.

## Related repository

- **[VibeWindowManagerIOS](https://github.com/Tguntenaar/VibeWindowManagerIOS)** — Remote layout map, window selection, and connect UI for iPhone / iPad.

If you have both projects cloned as siblings, paths like `../VibeWindowManagerIOS` match that layout.
