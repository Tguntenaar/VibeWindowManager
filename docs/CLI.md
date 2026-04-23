# VibeWindowManager CLI

The app binary now supports terminal commands directly.

## Usage

```bash
VibeWindowManager list-apps
VibeWindowManager bridge-dump ghostty
VibeWindowManager cursor cascade --pixel 30
VibeWindowManager ghostty columns
VibeWindowManager brave grid
VibeWindowManager help
```

## `windows` command

If you want the shorter `windows ...` form, symlink the app binary into your `PATH`:

```bash
ln -sf /Applications/VibeWindowManager.app/Contents/MacOS/VibeWindowManager /usr/local/bin/windows
```

Then you can run:

```bash
windows list-apps
windows cursor cascade --pixel 30
windows ghostty columns
windows brave grid
windows help
```

## `bridge-dump <app>`

Prints a single `layout` JSON document (as used by the iOS bridge) to stdout for a running app, e.g. `ghostty`. Same Accessibility rules as other commands. See `docs/PROTOCOL.md` for the wire format.

## Notes

- App matching is fuzzy, so `cursor`, `ghostty`, and bundle-id fragments work.
- `list-apps` shows running regular apps and, when Accessibility is granted, their movable window counts.
- Layouts use the current main display and respect the app's Stage Manager spacing heuristic.
- Accessibility permission is still required for moving windows.
