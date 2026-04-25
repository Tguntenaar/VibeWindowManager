# Research: Ghostty layout mirroring, Mac ↔ iPhone control, and voice-to-agent

This document frames a **local-first** system: a **horizontal iPhone/iPad** app with a **black canvas** and **low-opacity white fill / solid white border** “tiles” that mirror **Ghostty** window positions; **one tile selected**; **phone actions** (window cycle, push-to-talk dictation) drive behavior on the **Mac** (focus window, type into the right terminal, optionally start a coding agent).

It is **research and tradeoffs**, not a committed design.

### Repositories (split on purpose)

| Role | Codebase | Responsibility |
|------|----------|----------------|
| **Mac app** | `VibeWindowManager/` (this documentation lives here) | Window enumeration & layouts (`docs/CLI.md`), Accessibility focus/typing, future **LAN bridge** + **STT** on the Mac. |
| **iOS app** | `VibeWindowManagerIOS/` | Landscape remote UI (tiles, selection, mic capture), **Network.framework** / WebSocket **client** to the Mac. |

Check out both next to each other, e.g. `…/VibeWindowManager` and `…/VibeWindowManagerIOS`, so relative paths in each repo’s `README.md` line up. The **protocol and JSON shapes** for layout/audio should be documented in the Mac project first, then implemented on iOS.

---

## 1. What the Mac must own (and why a phone-only app is not enough)

| Concern | Why Mac |
|--------|---------|
| **Accurate Ghostty window geometry** | macOS APIs (`CGWindowList`, Accessibility) see real frames, stacking, and which window is key. The phone cannot. |
| **Focusing a specific terminal and typing** | Needs **synthesized keyboard events** (or a controlled pipeline) with **Accessibility** permission; the focused window must be the target Ghostty instance. |
| **Starting “an agent” in a given terminal** | That is **shell state** in that tty/session. The reliable approach is: **focus that window**, then **inject keystrokes or paste** (or use terminal multiplexer control if you standardize on tmux/screen and explicit commands). There is no stable public “Ghostty API” equivalent to iOS’s remote control; you own the script contract (`claude`, `cursor` CLI, etc.). |
| **Heavy STT and optional LLM for cleanup** | Easier to run **Whisper-class** models, batch or streaming, without draining the phone. |

**Conclusion:** treat the **Mac as the control plane and execution plane**; the **phone is a remote UI + microphone** (and optional speaker).

---

## 2. Ghostty / window layout on the Mac (existing direction)

You already have **CLI layout** surface (`VibeWindowManager ghostty columns`, etc. in `docs/CLI.md`). For a **live map**, you additionally need:

- **Per-window rectangles** in **global screen coordinates** (or normalized 0…1 on the containing display) via `CGWindowListCopyWindowInfo` and/or **Accessibility** (`AXUIElement` for position/size when available).
- **Which window is “selected”** on the phone should usually track **key window** among Ghostty windows, unless you decouple: “phone selection” vs “OS focus” (recommended to **sync focus** when the user changes selection on the phone, so volume-down dictation always targets the intended terminal).
- **Normalization for the phone:** map a chosen **reference rectangle** (e.g. main display or union of all displays) to the phone’s **landscape** aspect ratio. If your physical layout is **only columns** on one screen, the map should still **preserve column structure**; letterbox or crop explicitly so “columns on desktop = columns on phone.”

**Performance:** 5–10 Hz for layout is enough; window moves are not sub-millisecond events.

---

## 3. Mac ↔ iPhone: transport and discovery

Requirements: **low latency** for layout + **bidirectional** control; **audio uplink** for dictation; **no cloud required** (optional later).

| Option | Role | Pros | Cons |
|--------|------|------|------|
| **TLS WebSocket (JSON + binary audio)** on LAN | One connection, easy debugging | Simple, one port, browsers/tools friendly | You implement framing, backpressure, reconnect |
| **TCP + length-prefixed messages** (same payloads) | Same as WS without WS overhead | Minimal deps | Slightly more boilerplate |
| **Multipeer Connectivity** (Apple) | P2P | No router config in ideal cases | Can be **flaky** on some networks; more opaque than raw TCP |
| **WebRTC** | Real-time | Great for **media** if you go full duplex later | Heavier setup for a first local prototype |
| **Bluetooth LE** | Small control only | — | **Poor** for continuous audio and layout; treat as out of scope for v1. |

**Practical v1:** **WebSocket or raw TCP** over **Wi‑Fi**, with **Bonjour** (`_yourapp._tcp`) for discovery and an optional **pairing PIN** the first time.

**Update rates:**

- **Layout state:** 5–10 Hz, or on-change (diff) when a window’s frame or z-order changes.
- **Audio:** stream **16 kHz or 16–48 kHz mono PCM** or **Opus** frames; **Opus** saves bandwidth; **PCM** is simpler to implement first.

**Security (LAN):** even on a home LAN, use **TLS** (Paired cert or pre-shared key) if anything sensitive is spoken or typed; otherwise you accept LAN sniffing risk.

---

## 4. Voice-to-text: where the model should run

### Recommendation for your use case: **STT on the Mac (primary path)**

| Runs on | Pros | Cons |
|---------|------|------|
| **Mac** | Can run **Whisper medium/large**, streaming stacks, and optional **VAD** without killing phone battery; one place to upgrade models; easy logs | Adds Wi‑Fi dependency for the audio stream; must handle latency (usually fine on LAN) |
| **iPhone (Apple Speech / on-device where available)** | Low round-trip for partial results; no audio upload | Weaker on **rare file paths, package names, and code-ish tokens**; Apple may **redact** or limit in some modes; “agent workflow” is still Mac-side |

**Hybrid (later):** phone does **VAD + compression**; Mac does **decode**; optional **second-pass** on a phrase boundary for a cleaner final paste.

### “Models” and coding-agent lingo (plain facts)

- There is **no widely adopted specialist public model** whose only job is “coding agent vocabulary.” **Quality is mostly:** (1) a **strong general ASR** (Whisper family, etc.), (2) **custom vocabulary** / **hotword** support where the stack allows it, (3) **language/locale** set correctly, and (4) for **brands and repo names**, you may still need **light post-processing** (replace known mistakes, or a tiny LLM to normalize symbols—adds latency; use sparingly).
- **OpenAI Whisper** (especially **large-v3** or your preferred variant): strong **general** accuracy; not real-time in the original design; use **faster-whisper**, **whisper.cpp**, or **stream**-oriented frontends for continuous dictation.
- **Streaming** stacks matter more than a magical “Claude lingo” checkpoint: for **true live** typing, you need **partial results**; pure batch Whisper is a poor fit without a streaming layer.
- **Parakeet / NVIDIA Riva / cloud streaming**: viable if you accept **vendor + network**; good for productization, not for “air-gapped local only.”

**Cursor / Claude in the terminal:** the STT output is **just text**. The hard parts are: **sending it to the correct window**, **pasting vs keystrokes**, and **not breaking shell mode** (insert vs normal mode if you ever use vim-style, etc.).

---

## 5. Injecting text and “start the agent if not running”

**Inject text**

- **Frontmost target:** after focusing the right Ghostty window, **CGEvent**-based key injection or **IOHID**-level typing (requires **Accessibility**). **Paste** (Cmd+V) is often more reliable for **long** phrases if you set the pasteboard on the Mac side.
- **Order of operations:** focus window → (optional) click inside pane) → **type or paste**.

**“Start the agent if not running”**

- This is **not a generic OS feature**. You need a **deterministic contract**, e.g.:
  - Always use **tmux** sessions per “logical terminal,” and a **named command** to attach/run `claude` or `cursor` agent; or
  - A **small shell script** on the Mac that the bridge calls per window id (if you can map window → tty), which is **brittle** without discipline.
- **Practical approach:** **documented macros**: e.g. “if this Ghostty title contains `claude`, send Enter / `claude` / etc.” is **fragile**; better: **one keystroke** bound inside Ghostty/terminal that your bridge triggers after focus.

**Expect iteration:** the reliable UX is “**focus + paste user dictation**”; “**ensure agent**” is a **second project phase** with explicit **shell/tmux** conventions.

---

## 6. iPhone: volume up / volume down for custom actions (critical constraint)

- **iOS does not offer a supported, clean API** to repurpose the **hardware volume buttons** for arbitrary app features the way many users expect. Camera and some media use cases are special-cased; **HIG**-safe apps usually avoid hijacking volume.
- **Workarounds** (each imperfect): hidden `MPVolumeView` tricks, or accepting that volume changes also change system volume; **Guideline** risk if you ship to the **App Store**.
- **Practical product split:**
  - **Testbed / local dev:** volume buttons with hacks may be acceptable to you.
  - **App Store path:** use **on-screen** “next window” and **push-to-talk** buttons, **Back Tap**, or **Siri Shortcuts** / **Action button** (hardware where available) as alternatives.

**Disclose in design:** if volume-driven UX is non-negotiable, plan for **ad hoc distribution** (TestFlight with known limitations) or **Mac Catalyst / web remote** for control.

---

## 7. Suggested phased implementation (efficient order)

1. **Mac service:** enumerate Ghostty windows, normalize layout JSON, **focus** by id, **paste** text into focused Ghostty. Validate with a **local web page** or **CLI** before the phone.
2. **LAN bridge:** WebSocket + Bonjour; push layout at 5–10 Hz; receive **audio** and run **STT on Mac**; return **optional** partial transcripts for UI.
3. **iOS:** landscape black UI, tiles, selection highlight; use **tappable** or **gesture** controls first; add **volume** if platform constraints allow.
4. **Agent bootstrap:** only after (1)–(3) are stable, add **your** specific **shell/agent** contract.

---

## 8. Open questions (to resolve before hardcoding)

- **One Ghostty process vs many** windows and how you want **identities** in JSON (window id, title, pid, display).
- **Multi-monitor:** mirror **all** displays on one phone map vs **per-display** pages.
- **Security model:** cert pinning vs PIN on first connect.
- **STT stack:** `whisper.cpp` streaming vs a commercial streaming API vs Apple Speech on device for v0.

---

## References (categories, not an endorsement list)

- macOS: `CGWindowListCopyWindowInfo`, `AXUIElement` APIs, `CGEvent` posting (Accessibility).
- iOS: `AVAudioSession`, `URLSession` / `NWConnection`, `Network.framework` + Bonjour.
- STT: Whisper project and derivatives (faster-whisper, whisper.cpp); compare streaming add-ons; Apple `Speech` framework for on-device.

This file should stay **updated** as you pick concrete stacks (e.g. exact WebSocket library on Mac and iOS, exact Whisper runtime).
