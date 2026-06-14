import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:position_core/position_core.dart';

import 'location_source.dart';

const _storage = FlutterSecureStorage();
const _groupId = 'friends';
const _relayUrl = 'wss://relay.damus.io';

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
    bootstrapRelays: const [_relayUrl],
  ));
});

final locationSourceProvider = Provider<LocationSource>((ref) => createLocationSource());

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
  }

  /// Adopt a group key unwrapped from a member's wrapped-key event. Epoch-guarded
  /// so a stale or already-known key can't roll a re-key back.
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
    ndk.broadcast.broadcast(nostrEvent: await s.buildWrappedKeyEvent(kp, friendPubHex));
    await ref.read(membersProvider.notifier).add(friendPubHex);
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
      ndk.broadcast.broadcast(nostrEvent: await next.buildWrappedKeyEvent(kp, m));
    }
    await _persist(next);
    await ref.read(membersProvider.notifier).remove(pubHex);
    state = AsyncData(next);
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
}

/// Watches for group keys wrapped *to me* and adopts them (epoch-guarded).
/// The UI must watch this for it to run. Emits the running count adopted.
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
      await ref.read(groupProvider.notifier).adopt(key, epoch);
      await ref.read(membersProvider.notifier).add(e.pubKey);
      yield ++adopted;
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
      latest[e.pubKey] = await group.decodePositionEvent(e);
      await ref.read(membersProvider.notifier).add(e.pubKey);
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

  /// Publish a specific fix. No-op (false) if there's no group.
  Future<bool> publish(Position fix) async {
    final group = ref.read(groupProvider).asData?.value;
    if (group == null) return false;
    final kp = await ref.read(identityProvider.future);
    final ndk = ref.read(ndkProvider);
    ndk.broadcast.broadcast(nostrEvent: await group.buildPositionEvent(kp, fix));
    return true;
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
  static const _heartbeatInterval = Duration(minutes: 2);

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
    _sub = ref.read(locationSourceProvider).positions().listen(publisher.publish);
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) => publisher.publishNow());
    publisher.publishNow();
  }

  void stop() {
    _stop();
    state = false;
  }

  void _stop() {
    _sub?.cancel();
    _sub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
  }
}
