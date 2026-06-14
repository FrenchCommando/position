# position

A custom location-sharing app for a small group of friends — monitor your own position and your friends' positions on a map. No accounts, no servers to run, and no metered backend: identity is a keypair and the data plane rides on public **Nostr** relays.

See [VISION.md](VISION.md) for the full design rationale.

## How it works

- **Identity is a Nostr keypair, per device.** Your phone and laptop are two separate members (two dots). The private key is born and dies on its device — no cross-device key transfer. Stored via `flutter_secure_storage` (hardware keystore on mobile, IndexedDB on web).
- **Positions ride on Nostr.** Each member publishes its position as an encrypted, *replaceable* event, so each relay holds only the latest fix per member per group. Friends fetch the latest event per pubkey when viewing.
- **No always-on connection.** Mobile publishes in a brief outbound burst when the OS wakes the app on a significant location change, then disconnects. Viewing connects only while the app is open. No FCM/push, no closed-app alerts.
- **Redundancy over reliability.** Publish to and read from 3–4 relays; no single relay is load-bearing.

### Encryption & groups

- Position payloads are encrypted with a shared **group key** (ChaCha20-Poly1305 AEAD), tagged with an **epoch**. Relays and non-members see only ciphertext.
- The group key is distributed by wrapping it to each member's pubkey (NIP-44) and publishing the wrapped blobs as events — async store-and-forward, no server.
- **Symmetric within a group:** everyone holding the group key sees every position. Any member can invite (wrap the key to a newcomer) or remove (re-key, epoch++). For partial visibility, use multiple groups.

## Architecture

Two-package workspace:

- **`packages/core`** — plain-Dart package (no Flutter dependency) holding the Nostr client, event signing, NIP-44 wrapping, and key management. Runs under `dart test` in milliseconds, no emulator.
- **`lib/`** — the Flutter app, depends on `core`, renders the map and UI.

Location is a pluggable `LocationSource`: `GeolocatorLocationSource` on mobile, a manual tap-to-move source on web and in tests.

## Stack

- **Nostr:** [`ndk`](https://pub.dev/packages/ndk) — events, BIP-340 signing/verification, relay client, and NIP-44 encryption.
- **Map:** `flutter_map` + OpenStreetMap tiles (no API key, no billing).
- **State:** `flutter_riverpod`.
- **Location:** `geolocator` on mobile.
- **Crypto:** `cryptography` (ChaCha20-Poly1305 for the symmetric group payload).

## Targets

Android, iOS, and web — each a full peer that both publishes and renders. **Android is the primary tested platform.** iOS background-publish behaviour is a deferred unknown (no Apple device available to the author).

## Building

> **Note:** `ndk` ships a native Rust event-verifier behind a build hook, so every compile (`dart test`, APK) needs a **Rust toolchain** installed. Web builds skip the native hook.

```sh
# App dependencies
flutter pub get

# Core package tests (skip the live-relay test)
cd packages/core && dart pub get && dart test -x network

# Analyze + widget tests
flutter analyze
flutter test

# Debug APK
flutter build apk --debug
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs all of the above on every push and PR.
