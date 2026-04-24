# VibeWindowManager bridge protocol (v1)

## Transport

- **WebSocket** URL: `ws://<mac-hostname-or-ip>:19842/bridge` (default port **19842**; configurable).
- All payloads are **UTF-8 text** WebSocket **text** frames, one **JSON object per message** (not newline-delimited; each WS message is one JSON value).
- **Bonjour** discovery: service type `_vibewm._tcp`, port same as WebSocket. Current implementation advertises the Mac by hostname/service name and the iOS app browses/resolves it automatically on the same LAN.

## Discovery / connect order (iOS client)

The client picks an endpoint in this order on auto-connect:

1. **Tailnet** — if the user has set a Tailnet hostname (Tailscale MagicDNS, e.g. `my-mac.tailxxxx.ts.net`, or the short `<host>`), the client opens `ws://<host>:19842/bridge` directly and runs a **6 s fallback timer**. If it receives a `layout` message within the window, the Tailnet path is kept; otherwise the client cancels the attempt and continues with Bonjour.
2. **Bonjour** — browse `_vibewm._tcp`, resolve, auto-connect to the first service.
3. **Manual** — `host:port` or full `ws://…` entered by the user.

The protocol itself does **not** change across paths; discovery only decides the `host:port` used in the WebSocket URL. Requires Tailscale running on both devices (with MagicDNS on iPhone) for the Tailnet path.

## Client handshake

1. Client connects via WebSocket GET `/bridge`.
2. Server may send a `serverHello` (optional) immediately; client may send `clientHello` after connect.
3. Server repeatedly pushes `layout` when windows change (throttled, ~5–10/s max).
4. Client sends `select`, `selectNext`, `setWindowRect`, `ping`, and optional `transcribe` / `ping`.

## Message types (JSON `type` field)

### `serverHello`

```json
{ "type": "serverHello", "version": 1, "port": 19842 }
```

### `clientHello` (client → server)

```json
{ "type": "clientHello", "version": 1, "client": "VibeWindowManagerIOS" }
```

### `ping` / `pong` (bidirectional)

```json
{ "type": "ping", "t": 1700000000 }
```

```json
{ "type": "pong", "t": 1700000000 }
```

### `layout` (server → client)

`reference` is the **main display** layout area used for normalization (after Stage Manager inset when applicable).  
`windows[].rect` is **normalized 0…1** in **top-left** coordinates (x,y width height) **relative to `reference`**, for drawing in SwiftUI on the phone.

```json
{
  "type": "layout",
  "seq": 42,
  "appName": "Ghostty",
  "bundleId": "com.mitchellh.ghostty",
  "reference": { "x": 0, "y": 0, "width": 1440, "height": 900 },
  "windows": [
    { "id": "abc123", "title": "term", "zIndex": 0, "rect": { "x": 0, "y": 0, "width": 0.5, "height": 1 } }
  ],
  "selectedId": "abc123"
}
```

### `select` (client → server)

Focus the window with the given `windowId` (string from `layout.windows[].id`).

```json
{ "type": "select", "windowId": "abc123" }
```

### `selectNext` (client → server)

Focus the next window in **z-order / list order** (server-defined: same order as `layout.windows`).

```json
{ "type": "selectNext" }
```

### `setWindowRect` (client → server)

Move or resize a window. `rect` uses the **same normalized top-left convention** as `layout.windows[].rect` (relative to the server’s current `reference` / main-display layout frame). The server applies the frame via Accessibility; on failure it may send an `error` message.

```json
{
  "type": "setWindowRect",
  "windowId": "abc123",
  "rect": { "x": 0.1, "y": 0.1, "width": 0.4, "height": 0.5 }
}
```

### `pasteText` (client → server)

Paste **plain text** into the **currently focused** Ghostty window (must match selected terminal after `select`).

```json
{ "type": "pasteText", "text": "hello world" }
```

### `transcribe` (client → server)

**v1:** send **raw PCM** as base64 for convenience (16-bit little-endian mono, 16 kHz) in chunks with optional `end` flag. Server runs STT on the Mac and then performs the same as `pasteText` with the result.

**Chunk:**

```json
{ "type": "transcribe", "format": "pcm_s16le_16000", "base64": "...", "end": false }
```

**End of utterance:**

```json
{ "type": "transcribe", "format": "pcm_s16le_16000", "base64": "", "end": true }
```

**Response** (server → client):

```json
{ "type": "transcribeResult", "text": "typed transcript", "error": null }
```

If STT is not installed, `error` is set and `text` is empty.

### `error` (server → client)

```json
{ "type": "error", "message": "Accessibility not granted" }
```

## Security (LAN)

v1 assumes a **trusted LAN**. For secrets, add TLS (`wss://`) and pairing in a later revision.

If the iOS client cannot open `ws://` to a LAN IP, add **App Transport Security** → `NSAllowsLocalNetworking` in the iOS target’s **Info** (or a merged `Info.plist`) using Xcode, then rebuild.
