# VibeWindowManager (macOS)

macOS app and CLI for app/window layout (e.g. Ghostty columns, Cursor cascade). This repo is the **control plane** for a planned remote: window geometry, focus, future LAN bridge, and on-Mac speech-to-text for dictation into the active terminal.

## Companion iOS app

**VibeWindowManagerIOS** (sibling project: `../VibeWindowManagerIOS` when both repos are cloned next to each other). The iOS app is the **remote UI + microphone**; it does not replace the Mac for Accessibility or STT (see research doc).

## Documentation

- [`docs/CLI.md`](docs/CLI.md) — `VibeWindowManager` / `windows` commands
- [`docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md`](docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md) — Mac ↔ iPhone transport, where STT runs, and phased implementation

When you add a real protocol, document message formats under `docs/` here first, then implement the client in the iOS project.

**Bridge (implemented):** Start **Bridge server** in the Mac app’s “iOS layout bridge” section (default app query `ghostty`, port `19842`, WebSocket path `/bridge`). The Mac advertises itself via **Bonjour** as `_vibewm._tcp`, so the iOS app can discover it automatically on the same LAN; manual `IP:19842` still works. `windows bridge-dump <app>` prints the same `layout` JSON as one line of debugging.
