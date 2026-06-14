# position_core

The Nostr data plane and key management for the [Position](../../README.md) app: a plain-Dart package (no Flutter dependency) holding identity keypairs, event signing, group-key encryption, and NIP-44 wrapping. Because it has no Flutter dependency, `dart test` exercises the whole data plane on the dev machine in milliseconds — no emulator.

Built on [`ndk`](https://pub.dev/packages/ndk) for everything Nostr (events, BIP-340 signing/verification, relay client, NIP-44).

> **Note:** `ndk` ships a native Rust event-verifier behind a build hook, so `dart test` requires a **Rust toolchain** installed.

## Concepts

- **Identity** is a secp256k1 `KeyPair` (NDK's), one per device. The private key is a 64-hex string; the x-only public key is what friends know you by.
- **A `GroupSession`** is one group at one key epoch: a group id plus a 32-byte symmetric `groupKey`. Position payloads are encrypted once with this key (one event, many readers). The key itself is distributed by NIP-44-wrapping it to each member's pubkey.
- **Two event kinds** (NIP-33 addressable, parameterized-replaceable):
  - `kPositionKind` (30078) — an encrypted position fix, `d`-tag = group id.
  - `kWrappedKeyKind` (30079) — the group key wrapped to one recipient, `d`-tag = `recipientPub:epoch`.

Position payloads use **ChaCha20-Poly1305** AEAD (the group key is symmetric); key-wrapping uses **NIP-44** (pairwise, to a pubkey).

## Usage

```dart
import 'package:position_core/position_core.dart';

// Identity — one keypair per device.
final me = generateKeyPair();
// later, reload from secure storage:
final restored = keyPairFromPrivateHex(privateHex);

// Create a group and publish a position.
final group = GroupSession.create('friends');
final posEvent = await group.buildPositionEvent(me, Position(48.85, 2.35, 1700000000));
// ...broadcast posEvent to relays via Ndk...

// Read a friend's position back.
final position = await group.decodePositionEvent(incomingEvent);

// Invite a friend: wrap the group key to their pubkey.
final wrapped = await group.buildWrappedKeyEvent(me, friendPubHex);
// Friend's side: unwrap it.
final key = await GroupSession.openWrappedKey(friendKeyPair, myPubHex, wrapped);

// Remove a friend: re-key and wrap the new key to everyone who stays.
final next = group.rekey(); // epoch + 1
```

## Public API

- `generateKeyPair()`, `keyPairFromPrivateHex(hex)`, `signEvent(keyPair, event)` — identity helpers over NDK's `KeyPair`.
- `Position(lat, lon, t)` with `toJson` / `fromJson`.
- `GroupSession` — `create`, `rekey`, `buildPositionEvent`, `decodePositionEvent`, `buildWrappedKeyEvent`, static `openWrappedKey`, static `tagValue`.
- Re-exported from `ndk`: `Ndk`, `NdkConfig`, `Filter`, `Nip01Event`, `Bip340EventVerifier`, `MemCacheManager`, `KeyPair`.

## Testing

```sh
dart pub get
dart test            # full suite
dart test -x network # skip the live-relay round-trip (as CI does)
```
