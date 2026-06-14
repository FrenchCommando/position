app to monitor my position and the position of my friends

apps from marketplace do work, but I can just build my own, so that it's completely custom

# topics

- battery consumption: **each app pays its own background-location cost.** The earlier assumption — "maps already monitors position, so this is nearly free" — is wrong: a separate app receives its own location updates and draws its own battery. Mitigate with Google's best practices (significant-change / batched updates, publish on movement rather than a fixed timer), but real cadence/battery numbers are TBD and only measurable on-device (Android, the primary testable target).

- backend relying on free third-party infra: **Nostr relays** - each user publishes its (encrypted) position as a replaceable event - friends fetch the latest event per pubkey when viewing - identity is just a keypair, no accounts, no servers to run, no per-operation quota
    - two layers of privacy: **encrypted payload** (shared group key) protects content; the rest is metadata on public relays, accepted as the cost of free hosted infra
    - relays are best-effort: publish to several so no single one is load-bearing

# architecture

The phone can't hold a connection open in the background, and we don't want alerts while the app is closed — so the design is **connect-on-open for viewing, brief outbound publish for sending**. There is **no always-on server** and nothing to keep highly available.

- **Sending (background):** the OS wakes the app on a significant location change → app briefly connects to a few relays, publishes one encrypted position event, disconnects. A short outbound burst, which the OS permits in the background — not a held connection.
- **Viewing (foreground):** open the app → connect to the relays → fetch the latest position event for each friend's pubkey → show the map and live-update while open → close → disconnect.
- **No FCM/push** (we don't want closed-app alerts), **no home-server traffic**, **no accounts**.

## platforms & clients

**Targets are Android, iOS, and web** (desktop dropped). Each is a full, symmetric peer — it publishes its own position *and* renders everyone else's. No platform is merely a viewer.

- **The background constraint above is mobile-only.** Web has no background-wake budget to fight; it simply publishes while open. The "brief outbound burst in a wake window" concern applies to phones.
- **iOS is a target but cannot be validated by the author** (no Apple device). Its background-publish behaviour is a genuine but *deferred* unknown — to be checked later via TestFlight, a friend's iPhone, or Mac CI. It is **not** the project's go/no-go gate; **Android is the primary tested platform**.
- **Location is a pluggable source**, not something the core reaches out and grabs:

  ```
  LocationSource (interface) ──► emits Position {lat, lon, t}
     ├── ManualLocationSource     // web / tests: manual (tap to move)
     └── GeolocatorLocationSource // mobile: real fix + movement stream
  ```

  The core publishes whatever `LocationSource` emits. Phone-only concerns (real fixes, background triggers, battery) stay isolated to this one swappable layer, tested on the actual phone. Uses the `geolocator` plugin on mobile.

## data plane — Nostr

- Each user publishes its position as a **replaceable event** (NIP-01 replaceable / NIP-33 addressable, d-tag = group id). "Replaceable" means each new event overwrites the user's previous one, so a relay holds only the latest position per user per group — last-known is free and there's no history pile to manage.
- Payload is **encrypted** with the shared **group key** (see key management) and tagged with the key **epoch**. Relays and anyone reading the feed see only opaque blobs.
- Payload is tiny (~50 B raw, ~200 B encoded per fix), so relay load is trivial; cadence and battery are the only real constraints (see battery topic). Publish on movement events, not on a fixed timer.
- **Redundancy over reliability:** publish to 3–4 relays and read from the same set, taking the freshest event per friend. No single relay is load-bearing, which is how we tolerate public relays being best-effort.

## coordination — over Nostr, no server

The control plane (group membership, key distribution) rides on Nostr too, so there's still nothing to host. The group is defined by a **shared group key** and the **set of member pubkeys** each client caches.

- **Wrapped-key distribution** is just more events: a member wraps the group key to a recipient's pubkey and publishes it as an addressable event (d-tag = recipient pubkey + epoch), encrypted to that recipient. The relay holds it until the recipient next connects and fetches it — the same async store-and-forward the Pi used to provide, now from relays.
- **Epoch serialization without a CAS authority** is the one thing relays can't do (no compare-and-swap). If two members re-key concurrently and fork the epoch, clients resolve it by a **deterministic rule** — e.g. for a given superseded epoch, the re-key event with the lowest event id wins; the loser re-keys again on top. Rare (only on membership change) and self-healing.
- **Optional hardening:** if convention-based epoch resolution ever proves fragile, a tiny endpoint (the Pi, on its custom domain) can serve as a CAS authority for epoch transitions only — idle otherwise, never in the data path. Out of scope unless the deterministic rule misbehaves.

## key management

Goal: relays and non-members see only ciphertext. The group key lives **only on member devices** — it is never published in the clear; relays only ever hold wrapped (encrypted-to-a-pubkey) blobs.

- **Identity keypair = the Nostr key.** Each device's keypair *is* its Nostr identity — no separate identity layer. Private key never leaves the device; the pubkey is the public identifier friends know you by.
    - **Per-device, decided.** Identity is per *device*, not per person: your phone and your laptop are **two members, two dots**, each joining the group separately and each receiving the group key wrapped to it. The accepted cost is multiple dots for one person; the benefit is the private key is born and dies on its device with **no cross-device key transfer** ever. (Per-person identity — one key shared across your devices — was considered and rejected; it would buy one-dot-per-person at the cost of securely syncing a private key between devices.)
    - **Storage** is per-platform via `flutter_secure_storage`, one API but differing real security: **mobile** = hardware-backed keystore (Android Keystore / iOS Keychain, strongest); **web** = the weak tier — secp256k1 keys can't use non-extractable WebCrypto, so the private key lives as recoverable bytes in IndexedDB, readable by any JS on the page. Acceptable for a friend group, but named.
- **Group key wrapped per member.** The position payload is encrypted with a symmetric **group key** tagged with an **epoch**. The group key itself is never shared raw — a member wraps it to each other member's pubkey (NIP-44 / sealed-box style) and publishes the wrapped blobs as events. Only that member's private key can unwrap it.
- **Symmetric authority — any member can invite or remove.** No owner role; every member holds the current group key, so any member can wrap it for a newcomer or mint a new one. The group is a true peer set. Consequence to accept: any member can also evict any other member (including the original creator) — the price of symmetry, appropriate for a friend group rather than an owned resource.
- **Joining is asynchronous.** Relays are the mailbox; newcomer and accepter never need to be online together:
    1. The newcomer shares their **public key** with an existing member through a channel the member trusts (in person, a text, a QR scan). Getting the key directly is what stops a relay or man-in-the-middle swapping it — there's no separate "fingerprint" object, you just use the real key.
    2. The member adds that key: wraps the current group key to it and publishes the wrapped blob.
    3. The newcomer, next time online, fetches the wrapped blob, unwraps, and starts publishing/reading.

    Trust is federated: a newcomer's key is vouched for by whichever member accepts them, and the group trusts that transitively.

    **Implemented (updated 2026-06-14):** the member pastes the newcomer's key and taps Add; the newcomer's app auto-adopts the wrapped key. Adoption is now **trust-on-first-use** — the first key (when you have no group yet) is trusted, but afterwards only a sender already in your roster can hand you a new key, so a stranger can't push a higher-epoch key to hijack your session. The stronger guard — only adopt a key from a pubkey you pre-shared out of band — is still not built; TOFU leaves a narrow first-use window. See [NOTES.md](NOTES.md) for the current build state.
- **Removal = re-key (epoch++).** Any member mints a new group key, wraps it only to the *remaining* members, and publishes the wrapped blobs. The removed member never receives the new key, so their next read is of a feed they can no longer decrypt. Payloads carry the epoch so clients know which key applies across the seam. Distribution is async: a member offline during a re-key fetches their wrapped new key on next connect (addressable events keyed by epoch, latest wins).

There is no channel to rotate anymore — on Nostr, revocation is purely a re-key. Verifying a newcomer's public key through a channel you trust (anything but the relay) is the one irreducible manual step, and it's what keeps relays out of the trust path for confidentiality.

## visibility model

**Symmetric within a group** — decided by the key design, not a free choice. Everyone holding the group key decrypts every position published under that group, so a single shared key *is* symmetric visibility. Per-pair grants would require per-recipient encryption (each fix encrypted separately to each viewer), discarding the one-event-many-readers efficiency and the whole shared-key model.

For partial visibility, use **multiple groups** instead — each with its own group key and its own d-tag, and a user can belong to several. That keeps "symmetric within a group" uniform and reuses every mechanism above (join, re-key) per group.

## retention

**Last-known only, for free — no policy needed.** Position events are *replaceable*, so each relay keeps just the latest per user per group; old positions are overwritten, not accumulated. There is no encrypted track piling up anywhere, so there's no TTL to set and nothing to prune.

- If a **history/track** feature is ever wanted, it means publishing regular (non-replaceable) events and relying on relay retention — which on Nostr is **best-effort and varies per relay**, not a guaranteed window. Getting a dependable bounded track would mean running our own relay (reintroducing infra) or accepting lossy history. Deliberately out of scope; default is last-known only.

## nostr feasibility

The model fits the constraints exactly: free, no accounts, no servers, no metered quota, and the per-device keypair design *is* the Nostr identity. The risks are reliability-shaped, not account-shaped.

- **Pure-Dart crypto is available** — no native FFI, no C++ build, no TDLib, no app-store disclosure obligations, no real-account login or ban risk.
- **Real risks:**
    - Relay reliability/retention is best-effort — mitigated by publishing to and reading from several relays.
    - Mobile background publish must complete in the OS's short wake window after a location event — a brief connect → publish → close. Validating on iOS is deferred (no Apple device); Android is verified directly.
    - No delivery guarantee or ordering authority — hence the deterministic epoch-fork resolution above.

# stack & build approach

**No separate spike.** Building the app directly is the test — testing on-device is part of development, and a throwaway PoC would mean writing the crypto/relay code twice. The first iterations stay small (a single-device round-trip before any map or peers) but live inside the real codebase.

- **Two-package workspace.** A plain-Dart **`core`** package (no Flutter dependency) holds the Nostr client, event signing, NIP-44, and key management — so `dart test` exercises the data plane on the dev machine in milliseconds with no emulator, and the core can't reach into UI. The Flutter app depends on it.
- **Nostr via the NDK library (`ndk`).** The core uses the maintained NDK package for everything Nostr: events, BIP-340 signing/verification, the relay client (`Ndk` / `ndk.broadcast` / `ndk.requests.subscription`), and **real NIP-44** (`Nip44.encryptMessage`) for wrapping the group key to a pubkey. The symmetric group-payload encryption stays a direct ChaCha20-Poly1305 AEAD from the vetted `cryptography` package (NIP-44 is pairwise; the group key is symmetric). _(History: an earlier version hand-rolled the event layer, relay client, and a bespoke ECDH sealed box. That was do-it-yourself bias — relay/event/encryption are exactly what a maintained library does well. NDK confirmed on web + NIP-44 + custom/addressable kinds, so we adopted it. Earlier "NDK too heavy" was an under-researched rationalization.)_
    - **Cost of NDK:** it ships a native **Rust** event-verifier behind a build hook, so every compile (`dart test`, APK) needs a Rust toolchain installed, even though we use the pure-Dart `Bip340EventVerifier` and never call the Rust one. Web skips the native hook. Accepted as the price of not maintaining transport/crypto ourselves.
- **Map:** `flutter_map` + OpenStreetMap tiles — free, no API key, no billing, pure-Dart rendering on Android/iOS/web. (`google_maps_flutter` rejected: needs a billed API key and is weak on web.)
- **State management:** `riverpod` — its `StreamProvider`/`AsyncNotifier` map exactly onto "relay subscription → AsyncValue&lt;positions&gt; → UI" with loading/error handled for free.
- **Location:** `geolocator` on mobile, behind the `LocationSource` interface above; manual (tap-to-move) source on web.
- **First validation built:** a keypair → sign → NIP-44 wrap → unwrap → relay round-trip, run from `dart test` in `core`. If a crypto dep proves broken, swap it before building further.
