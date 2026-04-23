# Shipping VibeWindowManager (notarized + DMG)

This app is intended for **direct distribution** (Developer ID) or personal use, **not** the Mac App Store. Window control of other applications requires full Accessibility; the App Sandbox is disabled for the main target.

## Prerequisites

- Apple **Developer ID Application** identity in your keychain
- A machine logged into a **paid Apple developer** account (for notarization)

## 1. Archive and export

- In Xcode: **Product → Archive**, then **Distribute App** → **Developer ID**, export a signed `.app` (or a Developer ID + notarized app export).

## 2. Notarize

- Zip the app: `VibeWindowManager.app` inside a zip, or notarize the built product with `xcrun notarytool submit ...` and your App Store Connect API key or app-specific password.
- On success, **staple** the ticket: `xcrun stapler staple VibeWindowManager.app`

## 3. DMG (optional)

- Use [create-dmg](https://github.com/create-dmg/create-dmg) or **Disk Utility** to create a read-only image containing `VibeWindowManager.app` and a symlink to `Applications`.
- If you re-sign the DMG, notarize the **new** artifact; disk images for distribution are often notarized in place of the raw zip.

## 4. Hardened Runtime

- `ENABLE_HARDENED_RUNTIME` should remain **YES** for notarization, consistent with the project setting.

## Note

- If `codesign` fails with *resource fork, Finder information, or similar detritus*, clear extended attributes on the bundle: e.g. `xattr -cr VibeWindowManager.app`
