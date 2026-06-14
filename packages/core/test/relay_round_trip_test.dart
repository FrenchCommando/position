@Tags(['network'])
library;

import 'package:position_core/position_core.dart';
import 'package:test/test.dart';

/// End-to-end against a real public relay via NDK: publish an encrypted position
/// and read it back, then decrypt. Networked and best-effort — `dart test -t network`.
void main() {
  test('publish encrypted position to a relay and read it back', () async {
    final ndk = Ndk(NdkConfig(
      eventVerifier: Bip340EventVerifier(),
      cache: MemCacheManager(),
      bootstrapRelays: const ['wss://relay.damus.io'],
    ));

    final alice = generateKeyPair();
    final session = GroupSession.create('position-e2e');
    final event = await session.buildPositionEvent(alice, const Position(48.8566, 2.3522, 1700000000));

    final sub = ndk.requests.subscription(
      id: 'e2e',
      filter: Filter(
        authors: [alice.publicKey],
        kinds: [kPositionKind],
        dTags: [session.groupId],
      ),
    );
    ndk.broadcast.broadcast(nostrEvent: event);

    final received =
        await sub.stream.firstWhere((e) => e.id == event.id).timeout(const Duration(seconds: 20));
    final decoded = await session.decodePositionEvent(received);
    expect(decoded.lat, closeTo(48.8566, 1e-9));
    expect(decoded.t, 1700000000);

    await ndk.requests.closeSubscription('e2e');
  }, timeout: const Timeout(Duration(seconds: 40)));
}
