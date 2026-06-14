import 'dart:typed_data';

import 'package:position_core/position_core.dart';
import 'package:test/test.dart';

void main() {
  test('signEvent produces an event that verifies', () async {
    final alice = generateKeyPair();
    final signed = await signEvent(
      alice,
      Nip01Event(pubKey: alice.publicKey, kind: 1, tags: const [], content: 'hello'),
    );
    expect(signed.pubKey, alice.publicKey);
    expect(await Bip340EventVerifier().verify(signed), isTrue);
  });

  test('keyPairFromPrivateHex round-trips an identity', () {
    final a = generateKeyPair();
    final b = keyPairFromPrivateHex(a.privateKey!);
    expect(b.publicKey, a.publicKey);
  });

  group('group encryption', () {
    test('position event encrypts and decrypts under the group key', () async {
      final alice = generateKeyPair();
      final session = GroupSession.create('friends');
      final event = await session.buildPositionEvent(alice, const Position(48.8566, 2.3522, 100));
      final decoded = await session.decodePositionEvent(event);
      expect(decoded.lat, closeTo(48.8566, 1e-9));
      expect(decoded.t, 100);
      expect(GroupSession.tagValue(event, 'd'), 'friends');
    });

    test('a different group key cannot decrypt the position', () async {
      final alice = generateKeyPair();
      final session = GroupSession.create('friends');
      final event = await session.buildPositionEvent(alice, const Position(1, 1, 1));
      final other = GroupSession.create('friends'); // different random key
      expect(() => other.decodePositionEvent(event), throwsA(anything));
    });
  });

  test('wrap the group key to a pubkey: only the recipient can unwrap', () async {
    final alice = generateKeyPair();
    final bob = generateKeyPair();
    final carol = generateKeyPair();
    final session = GroupSession.create('friends');

    final wrapped = await session.buildWrappedKeyEvent(alice, bob.publicKey);

    final byBob = await GroupSession.openWrappedKey(bob, alice.publicKey, wrapped);
    expect(byBob, session.groupKey);

    expect(
      () => GroupSession.openWrappedKey(carol, alice.publicKey, wrapped),
      throwsA(anything),
    );
  });

  test('re-key removes a member: old key loses the new epoch', () async {
    final alice = generateKeyPair();
    final bob = generateKeyPair();

    final e1 = GroupSession.create('friends');
    final carolE1 = GroupSession(groupId: 'friends', epoch: 1, groupKey: e1.groupKey);
    final pos1 = await e1.buildPositionEvent(alice, const Position(1, 1, 100));
    expect((await carolE1.decodePositionEvent(pos1)).lat, 1);

    // Alice re-keys, wrapping the new key only to Bob.
    final e2 = e1.rekey();
    expect(e2.epoch, 2);
    final wrapToBob = await e2.buildWrappedKeyEvent(alice, bob.publicKey);
    final bobKey = await GroupSession.openWrappedKey(bob, alice.publicKey, wrapToBob);
    final bobE2 = GroupSession(groupId: 'friends', epoch: 2, groupKey: Uint8List.fromList(bobKey));

    final pos2 = await e2.buildPositionEvent(alice, const Position(2, 2, 200));
    expect((await bobE2.decodePositionEvent(pos2)).lat, 2);
    expect(() => carolE1.decodePositionEvent(pos2), throwsA(anything));
  });

  test('full join: Alice wraps the group key to Bob, Bob decodes her position', () async {
    final alice = generateKeyPair();
    final bob = generateKeyPair();

    final aliceSession = GroupSession.create('friends');
    final posEvent = await aliceSession.buildPositionEvent(alice, const Position(48.85, 2.35, 100));
    final wrappedKeyEvent = await aliceSession.buildWrappedKeyEvent(alice, bob.publicKey);

    final bobKey = await GroupSession.openWrappedKey(bob, alice.publicKey, wrappedKeyEvent);
    final bobSession = GroupSession(groupId: 'friends', epoch: 1, groupKey: Uint8List.fromList(bobKey));

    final decoded = await bobSession.decodePositionEvent(posEvent);
    expect(decoded.lat, closeTo(48.85, 1e-9));
    expect(decoded.t, 100);
  });
}
