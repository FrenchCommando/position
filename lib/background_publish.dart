import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:position_core/position_core.dart';

// Kept in sync with providers.dart (the background isolate can't see those
// providers — it reads the same secure-storage keys and relay list directly).
const _storage = FlutterSecureStorage();
const _groupId = 'friends';
const _relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://offchain.pub',
];

/// Publish one fix from a headless background isolate: load identity + group key
/// from secure storage, encrypt the position, broadcast to the relays, tear the
/// connection down. Best-effort — swallows everything and returns whether any
/// relay accepted it. No-op (false) if we have no group key yet.
Future<bool> publishFixInBackground(double lat, double lon) async {
  WidgetsFlutterBinding.ensureInitialized();
  Ndk? ndk;
  try {
    final priv = await _storage.read(key: 'priv');
    final keyHex = await _storage.read(key: 'groupkey');
    if (priv == null || keyHex == null) return false;
    final epoch = int.tryParse(await _storage.read(key: 'groupepoch') ?? '1') ?? 1;
    final name = await _storage.read(key: 'name');
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final kp = keyPairFromPrivateHex(priv);
    final session = GroupSession(
      groupId: _groupId,
      epoch: epoch,
      groupKey: Uint8List.fromList(hex.decode(keyHex)),
    );
    final event = await session.buildPositionEvent(
      kp,
      Position(lat, lon, now, name: (name == null || name.isEmpty) ? null : name),
    );

    ndk = Ndk(NdkConfig(
      eventVerifier: Bip340EventVerifier(),
      cache: MemCacheManager(),
      bootstrapRelays: _relays,
    ));
    final resp = ndk.broadcast.broadcast(nostrEvent: event);
    final acks = await resp.broadcastDoneFuture;
    return acks.any((r) => r.broadcastSuccessful);
  } catch (_) {
    return false;
  } finally {
    await ndk?.destroy();
  }
}
