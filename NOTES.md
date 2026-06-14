# Notes

Running engineering log. Design rationale lives in [VISION.md](VISION.md).

## Implemented (as of 2026-06-14)
- **Identity** — per-device secp256k1 keypair (NDK), stored in `flutter_secure_storage`, generated on first run. The private key never leaves the device.
- **Group** — single hard-coded group id `friends`; one symmetric group key (ChaCha20-Poly1305), epoch-tagged. **Convention: exactly one person creates the group; everyone else joins by being added** (you paste their pubkey, your app wraps the key to them). Two creators → fork (each holds a different epoch-1 key) → they can't see each other. Recover with **Leave group**, then have the other person re-add you.
- **Key distribution** — NIP-44-wrap the group key to each member's pubkey, published as addressable events. Adoption is gated: a **first-time invite** (a key arriving when you're not in a group) surfaces as an **Accept/Decline banner** on the map — you're never pulled into a group silently. A **re-key** from a sender already in your roster is adopted automatically (epoch-guarded; you're already in the group). A key from an unknown sender while you're in a group is ignored. Accept persists; Decline is in-memory only, so a declined invite re-prompts after an app restart (the relay re-delivers it). This replaces the old silent trust-on-first-use auto-adopt.
- **Relays** — publish to and read from 4 (`damus`, `nos.lol`, `primal`, `offchain.pub`). Broadcasts are awaited; publishes/invites report how many relays accepted.
- **Names** — each device sets its own display name; it rides inside the *encrypted* position payload (never public metadata) and labels that person's dot + roster row.
- **Map** — OSM tiles via `flutter_map`. Friends' dots come from the relay; your own dot is shown locally on web (manual source) before/without publishing. Recenter FAB fits everyone. Names label dots; last-updated time appears in the roster only.
- **Logs tab** — in-memory activity log (publishes + ack counts, key adoptions, positions received, invites, re-keys, errors). Newest-first, capped 300, clearable. Built to answer "is it reaching a relay?".
- **Background publishing (Android)** — `flutter_background_service`: a sticky location foreground service (`background_task.dart`) runs geolocator's movement stream (15 m) and publishes each fix, surviving backgrounding and swipe-kill (Android restarts the service). Each publish runs the headless path in `background_publish.dart` (read keys from storage → encrypt → broadcast → disconnect). Configured once in `main()`; started/stopped with live sharing. Foreground/web sharing uses the manual/foreground path, not the service, so there's no double-publishing.

## Deploy — direct phone install
- CI builds a **release** APK. It's debug-signed (`android/app/build.gradle.kts`), so it installs like the debug build but is ~15 MB instead of ~100 MB.
- On `main`, CI publishes it as a **GitHub Release** (`softprops/action-gh-release`, tag `build-<run_number>`). Install from the phone: open `github.com/FrenchCommando/position/releases/latest` and tap the APK — no zip, no Phone Link.
- PR runs upload a plain `position-apk` artifact instead of publishing a release.
- The job has `permissions: contents: write` for the release.

## App icon
- `assets/app_icon.svg` → PNG via `npx sharp-cli` → `flutter_launcher_icons` (Android/iOS/web).
- Regenerate: `tool/generate_icon.bat` (Windows) or `tool/generate_icon.sh` (Unix). Config under `flutter_launcher_icons:` in `pubspec.yaml`.

## Gotchas / known limits
- **The Android build is validated by CI, not locally.** (We switched off `background_locator_2`, which was unmaintained and failed AGP 8 with a missing `namespace`, to the maintained `flutter_background_service`.) If the native build breaks, CI's APK step fails and no release publishes — that's the signal.
- **"Allow all the time" location permission is required** for background publishing. The app only requests while-in-use, so grant background access manually in Android settings.
- **iOS background is unvalidated** (no Apple device).
- **`packages/core/build/` was untracked** from git; `**/build/` added to `.gitignore` so sub-package build output can't be committed again.
- **Color API:** use `.withValues(alpha:)`, not the legacy `.withOpacity()`.
