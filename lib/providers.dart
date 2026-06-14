import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:position_core/position_core.dart';

import 'background_task.dart';
import 'location_source.dart';
import 'log.dart';

const _storage = FlutterSecureStorage();
const _groupId = 'friends';

/// Publish to and read from several relays so no single one is load-bearing
/// (VISION: redundancy over reliability — public relays are best-effort).
const _relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://offchain.pub',
];

/// Broadcast an event and wait for relay confirmation. Returns how many relays
/// accepted it; 0 means it never landed anywhere and the caller should surface
/// that rather than report success.
Future<int> _publish(Ndk ndk, Nip01Event event) async {
  final resp = ndk.broadcast.broadcast(nostrEvent: event);
  final acks = await resp.broadcastDoneFuture;
  return acks.where((r) => r.broadcastSuccessful).length;
}

/// Short pubkey for log/UI lines.
String _short(String pubHex) =>
    pubHex.length <= 8 ? pubHex : '${pubHex.substring(0, 8)}…';

/// This device's identity keypair — loaded from secure storage, generated and
/// persisted on first run. The private key never leaves the device.
final identityProvider = FutureProvider<KeyPair>((ref) async {
  final existing = await _storage.read(key: 'priv');
  if (existing != null) return keyPairFromPrivateHex(existing);
  final kp = generateKeyPair();
  await _storage.write(key: 'priv', value: kp.privateKey!);
  return kp;
});

/// The shared NDK instance — relay client, signing, NIP-44, verification.
/// Connects lazily on first request and verifies inbound events itself.
final ndkProvider = Provider<Ndk>((ref) {
  return Ndk(NdkConfig(
    eventVerifier: Bip340EventVerifier(),
    cache: MemCacheManager(),
    bootstrapRelays: _relays,
  ));
});

final locationSourceProvider = Provider<LocationSource>((ref) => createLocationSource());

/// This device's own current location, shown locally so you see your own dot
/// without having to publish or even be in a group. Manual/web source only —
/// it's free there; on mobile we don't spin up GPS just to view (yields null),
/// so your dot appears once you start sharing.
final myLocalPositionProvider = StreamProvider<Position?>((ref) async* {
  final src = ref.read(locationSourceProvider);
  if (src is! ManualLocationSource) {
    yield null;
    return;
  }
  yield await src.current();
  yield* src.positions();
});

/// This device's self-chosen display name, shown to friends on their map. Empty
/// until set. Stored locally; published inside each encrypted position payload.
final myNameProvider = AsyncNotifierProvider<MyNameController, String>(MyNameController.new);

class MyNameController extends AsyncNotifier<String> {
  @override
  Future<String> build() async => (await _storage.read(key: 'name')) ?? '';

  Future<void> setName(String name) async {
    final n = name.trim();
    await _storage.write(key: 'name', value: n);
    state = AsyncData(n);
    // Republish so friends pick up the new name (no-op if not in a group).
    await ref.read(publisherProvider).publishNow();
  }
}

/// The current group session, or null if this device isn't in a group yet.
final groupProvider = AsyncNotifierProvider<GroupController, GroupSession?>(GroupController.new);

class GroupController extends AsyncNotifier<GroupSession?> {
  @override
  Future<GroupSession?> build() async {
    final keyHex = await _storage.read(key: 'groupkey');
    if (keyHex == null) return null;
    final epoch = int.tryParse(await _storage.read(key: 'groupepoch') ?? '1') ?? 1;
    return GroupSession(
      groupId: _groupId,
      epoch: epoch,
      groupKey: Uint8List.fromList(hex.decode(keyHex)),
    );
  }

  Future<void> createGroup() async {
    final s = GroupSession.create(_groupId);
    await _persist(s);
    state = AsyncData(s);
    ref.read(logProvider.notifier).add('created group (epoch ${s.epoch})');
  }

  /// Adopt a group key unwrapped from a member's wrapped-key event. Epoch-guarded
  /// so a stale or already-known key can't roll a re-key back. (Convention: one
  /// person creates the group; everyone else joins by being added — so a joiner's
  /// epoch is 0 and adoption goes through.)
  Future<void> adopt(Uint8List key, int epoch) async {
    final current = state.asData?.value?.epoch ?? 0;
    if (epoch <= current) return;
    final s = GroupSession(groupId: _groupId, epoch: epoch, groupKey: key);
    await _persist(s);
    state = AsyncData(s);
  }

  /// Invite a friend by wrapping the current group key to their pubkey and
  /// publishing it; they adopt it on their next connect.
  Future<void> addFriend(String friendPubHex) async {
    final s = state.asData?.value;
    if (s == null) throw StateError('not in a group yet');
    final kp = await ref.read(identityProvider.future);
    final ndk = ref.read(ndkProvider);
    final acks = await _publish(ndk, await s.buildWrappedKeyEvent(kp, friendPubHex));
    if (acks == 0) {
      ref.read(logProvider.notifier).add('invite failed: no relay accepted', level: LogLevel.error);
      throw StateError('no relay accepted the invite — check your connection');
    }
    await ref.read(membersProvider.notifier).add(friendPubHex);
    ref.read(logProvider.notifier).add('invited ${_short(friendPubHex)} → $acks relay(s)');
  }

  /// Leave the group: drop our key and roster. Recovery for a fork (you both
  /// created a group) — leave, then get added by the other person.
  Future<void> leaveGroup() async {
    await _storage.delete(key: 'groupkey');
    await _storage.delete(key: 'groupepoch');
    await ref.read(membersProvider.notifier).clear();
    state = const AsyncData(null);
    ref.read(logProvider.notifier).add('left the group');
  }

  /// Remove a member: mint a new key at the next epoch and wrap it to everyone
  /// *except* the removed pubkey, who can no longer decrypt new positions.
  Future<void> removeMember(String pubHex) async {
    final s = state.asData?.value;
    if (s == null) throw StateError('not in a group yet');
    final members = ref.read(membersProvider).asData?.value ?? const [];
    final remaining = members.where((m) => m != pubHex).toList();
    final next = s.rekey();
    final kp = await ref.read(identityProvider.future);
    final ndk = ref.read(ndkProvider);
    for (final m in remaining) {
      await _publish(ndk, await next.buildWrappedKeyEvent(kp, m));
    }
    await _persist(next);
    await ref.read(membersProvider.notifier).remove(pubHex);
    state = AsyncData(next);
    ref.read(logProvider.notifier)
        .add('removed ${_short(pubHex)} — re-keyed to epoch ${next.epoch}');
  }

  Future<void> _persist(GroupSession s) async {
    await _storage.write(key: 'groupkey', value: hex.encode(s.groupKey));
    await _storage.write(key: 'groupepoch', value: '${s.epoch}');
  }
}

/// The group roster — pubkeys this device knows are in the group. Its own
/// provider so updating it doesn't restart the positions stream. Excludes me.
final membersProvider = AsyncNotifierProvider<MembersController, List<String>>(MembersController.new);

class MembersController extends AsyncNotifier<List<String>> {
  @override
  Future<List<String>> build() async {
    final raw = await _storage.read(key: 'members');
    if (raw == null) return const [];
    return (jsonDecode(raw) as List).cast<String>();
  }

  Future<void> add(String pubHex) async {
    final me = (await ref.read(identityProvider.future)).publicKey;
    if (pubHex == me) return;
    final cur = state.asData?.value ?? const [];
    if (cur.contains(pubHex)) return;
    final next = [...cur, pubHex];
    await _storage.write(key: 'members', value: jsonEncode(next));
    state = AsyncData(next);
  }

  Future<void> remove(String pubHex) async {
    final cur = state.asData?.value ?? const [];
    if (!cur.contains(pubHex)) return;
    final next = cur.where((m) => m != pubHex).toList();
    await _storage.write(key: 'members', value: jsonEncode(next));
    state = AsyncData(next);
  }

  Future<void> clear() async {
    await _storage.delete(key: 'members');
    state = const AsyncData([]);
  }
}

/// A group key wrapped to me that I haven't accepted yet — a join offer awaiting
/// an explicit Accept/Decline, so I'm never pulled into a group silently.
class PendingInvite {
  final String senderPub;
  final Uint8List key;
  final int epoch;
  const PendingInvite(this.senderPub, this.key, this.epoch);
}

/// Join offers awaiting the user's decision. The key inbox routes first-time
/// invites here instead of adopting them; the UI shows Accept/Decline.
final pendingInvitesProvider =
    NotifierProvider<PendingInvitesController, List<PendingInvite>>(
        PendingInvitesController.new);

class PendingInvitesController extends Notifier<List<PendingInvite>> {
  // Sender+epoch we've already surfaced or dismissed, so a relay re-delivering
  // the same wrapped-key event doesn't re-prompt after Accept/Decline.
  final _settled = <String>{};

  @override
  List<PendingInvite> build() => const [];

  String _id(String sender, int epoch) => '$sender@$epoch';

  /// Surface a new join offer, ignoring ones already pending or settled.
  void offer(PendingInvite invite) {
    if (!_settled.add(_id(invite.senderPub, invite.epoch))) return;
    state = [...state, invite];
  }

  void _drop(PendingInvite invite) =>
      state = state.where((i) => i != invite).toList();

  /// Accept an offer: adopt its key and add the inviter to the roster.
  Future<void> accept(PendingInvite invite) async {
    await ref.read(groupProvider.notifier).adopt(invite.key, invite.epoch);
    await ref.read(membersProvider.notifier).add(invite.senderPub);
    _drop(invite);
    ref.read(logProvider.notifier).add(
        'accepted invite (epoch ${invite.epoch}) from ${_short(invite.senderPub)}');
  }

  /// Decline an offer: drop it (and remember it, so it won't re-prompt).
  void decline(PendingInvite invite) {
    _drop(invite);
    ref.read(logProvider.notifier).add(
        'declined invite from ${_short(invite.senderPub)}', level: LogLevel.warn);
  }
}

/// Watches for group keys wrapped *to me*. Re-keys from a member already in our
/// roster are adopted automatically (we're in the group already); a first-time
/// invite is routed to [pendingInvitesProvider] for explicit Accept/Decline.
/// The UI must watch this for it to run. Emits the running count handled.
final keyInboxProvider = StreamProvider<int>((ref) async* {
  final kp = await ref.read(identityProvider.future);
  final ndk = ref.read(ndkProvider);
  const subId = 'keys';
  final resp = ndk.requests.subscription(
    id: subId,
    filter: Filter(kinds: [kWrappedKeyKind], pTags: [kp.publicKey]),
  );
  ref.onDispose(() => ndk.requests.closeSubscription(subId));

  var adopted = 0;
  await for (final e in resp.stream) {
    try {
      final key = await GroupSession.openWrappedKey(kp, e.pubKey, e);
      final epoch = int.tryParse(GroupSession.tagValue(e, 'epoch') ?? '1') ?? 1;
      // Anyone can encrypt to our public key, so a successful decrypt above is
      // not by itself proof of trust — the sender still has to be vetted.
      final inGroup = ref.read(groupProvider).asData?.value != null;
      final known = ref.read(membersProvider).asData?.value ?? const [];
      if (inGroup && !known.contains(e.pubKey)) {
        // A stranger trying to push a key while we're in a group — never adopt.
        ref.read(logProvider.notifier).add(
            'ignored key from unknown ${_short(e.pubKey)}', level: LogLevel.warn);
        continue;
      }
      if (inGroup) {
        // A re-key from a roster member we already trust — adopt automatically
        // (epoch-guarded), no need to re-prompt; we're already in the group.
        await ref.read(groupProvider.notifier).adopt(key, epoch);
        await ref.read(membersProvider.notifier).add(e.pubKey);
        ref.read(logProvider.notifier)
            .add('adopted re-key (epoch $epoch) from ${_short(e.pubKey)}');
        yield ++adopted;
      } else {
        // A first-time invite — don't join silently. Surface it for the user to
        // Accept or Decline (closes the trust-on-first-use window).
        ref.read(pendingInvitesProvider.notifier)
            .offer(PendingInvite(e.pubKey, key, epoch));
        ref.read(logProvider.notifier)
            .add('invite received from ${_short(e.pubKey)} — awaiting accept');
      }
    } catch (_) {
      // Not wrapped to us / not decryptable — ignore.
    }
  }
});

/// Live map of pubkey → latest decrypted position for everyone in the group.
final positionsProvider = StreamProvider<Map<String, Position>>((ref) async* {
  final group = ref.watch(groupProvider).asData?.value;
  if (group == null) {
    yield const {};
    return;
  }
  final ndk = ref.read(ndkProvider);
  final subId = 'positions-${group.epoch}';
  final resp = ndk.requests.subscription(
    id: subId,
    filter: Filter(kinds: [kPositionKind], dTags: [group.groupId]),
  );
  ref.onDispose(() => ndk.requests.closeSubscription(subId));

  final latest = <String, Position>{};
  await for (final e in resp.stream) {
    try {
      final p = await group.decodePositionEvent(e);
      latest[e.pubKey] = p;
      await ref.read(membersProvider.notifier).add(e.pubKey);
      ref.read(logProvider.notifier)
          .add('position from ${p.name?.isNotEmpty == true ? p.name : _short(e.pubKey)}');
      yield Map<String, Position>.from(latest);
    } catch (_) {
      // Not decryptable with our key (other group / wrong epoch) — skip.
    }
  }
});

/// Publishes this device's position to the group.
final publisherProvider = Provider<Publisher>(Publisher.new);

class Publisher {
  final Ref ref;
  Publisher(this.ref);

  /// Publish a specific fix. False if there's no group or no relay accepted it.
  /// Stamps our self-chosen display name into the (encrypted) payload.
  Future<bool> publish(Position fix) async {
    final group = ref.read(groupProvider).asData?.value;
    if (group == null) return false;
    final kp = await ref.read(identityProvider.future);
    final ndk = ref.read(ndkProvider);
    final name = ref.read(myNameProvider).asData?.value ?? '';
    final stamped = Position(fix.lat, fix.lon, fix.t, name: name.isEmpty ? null : name);
    final acks = await _publish(ndk, await group.buildPositionEvent(kp, stamped));
    ref.read(logProvider.notifier).add(
          acks > 0 ? 'published position → $acks relay(s)' : 'publish failed: no relay accepted',
          level: acks > 0 ? LogLevel.info : LogLevel.error,
        );
    return acks > 0;
  }

  /// Publish the current one-shot fix. False if no group or no fix available.
  Future<bool> publishNow() async {
    final fix = await ref.read(locationSourceProvider).current();
    if (fix == null) return false;
    return publish(fix);
  }
}

/// Automatic live sharing: while on, publishes every fix the location source
/// emits plus a slow heartbeat so "last known" stays fresh when stationary.
final sharingProvider = NotifierProvider<SharingController, bool>(SharingController.new);

class SharingController extends Notifier<bool> {
  StreamSubscription<Position>? _sub;
  Timer? _heartbeat;
  Timer? _debounce;
  static const _heartbeatInterval = Duration(minutes: 2);
  // Collapse a burst of moves (dragging the pin) into one publish once it
  // settles — otherwise relays rate-limit us ("you are noting too much").
  static const _moveDebounce = Duration(seconds: 1);

  @override
  bool build() {
    ref.onDispose(_stop);
    return false;
  }

  void toggle() => state ? stop() : start();

  void start() {
    if (state) return;
    state = true;
    final publisher = ref.read(publisherProvider);
    final src = ref.read(locationSourceProvider);
    if (src is ManualLocationSource) {
      // Web/desktop: publish manual moves plus a heartbeat. No background isolate.
      // Debounce moves so a drag publishes once it settles, not per frame.
      _sub = src.positions().listen((fix) {
        _debounce?.cancel();
        _debounce = Timer(_moveDebounce, () => publisher.publish(fix));
      });
      _heartbeat = Timer.periodic(_heartbeatInterval, (_) => publisher.publishNow());
      publisher.publishNow();
    } else {
      // Mobile: publish once now for an immediate dot, then a single background
      // service publishes on movement — covering foreground, background, and the
      // app being killed (no second foreground stream, to avoid double-publishing).
      publisher.publishNow();
      startBackgroundPublishing();
    }
    ref.read(logProvider.notifier).add('live sharing on');
  }

  void stop() {
    _stop();
    stopBackgroundPublishing();
    state = false;
    ref.read(logProvider.notifier).add('live sharing off');
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _debounce?.cancel();
    _debounce = null;
  }
}
