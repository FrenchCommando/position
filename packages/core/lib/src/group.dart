// NDK marks its NIP-44 API @experimental; it's the maintained implementation we
// want and is covered by the standard's test vectors upstream.
// ignore_for_file: experimental_member_use
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:cryptography/cryptography.dart' hide KeyPair;
import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/key_pair.dart';
import 'package:ndk/shared/nips/nip44/nip44.dart';

import 'identity.dart';

/// App-specific addressable event kinds (NIP-33 parameterized-replaceable range).
const int kPositionKind = 30078;
const int kWrappedKeyKind = 30079;

/// A position fix. Carries the publisher's chosen display [name] so each peer
/// labels its own dot — names travel inside the encrypted payload, never in
/// public metadata.
class Position {
  final double lat;
  final double lon;

  /// Unix seconds.
  final int t;

  /// Publisher's self-chosen display name, if set.
  final String? name;

  const Position(this.lat, this.lon, this.t, {this.name});

  Map<String, dynamic> toJson() => {
        'lat': lat,
        'lon': lon,
        't': t,
        if (name != null && name!.isNotEmpty) 'name': name,
      };

  factory Position.fromJson(Map<String, dynamic> j) => Position(
        (j['lat'] as num).toDouble(),
        (j['lon'] as num).toDouble(),
        j['t'] as int,
        name: j['name'] as String?,
      );
}

/// One group at one key epoch: the shared symmetric group key plus the group id.
///
/// Position payloads are encrypted with the symmetric [groupKey] (one event,
/// many readers); the key itself is distributed to each member by NIP-44-wrapping
/// it to their pubkey.
class GroupSession {
  final String groupId;
  final int epoch;
  final Uint8List groupKey;

  const GroupSession({
    required this.groupId,
    required this.epoch,
    required this.groupKey,
  });

  factory GroupSession.create(String groupId) =>
      GroupSession(groupId: groupId, epoch: 1, groupKey: _randomBytes(32));

  /// New key at the next epoch — for removing a member (wrap it to everyone but them).
  GroupSession rekey() =>
      GroupSession(groupId: groupId, epoch: epoch + 1, groupKey: _randomBytes(32));

  /// Build this author's encrypted, signed, replaceable position event.
  Future<Nip01Event> buildPositionEvent(KeyPair author, Position p) async {
    final content = await _sealSym(
      groupKey,
      Uint8List.fromList(utf8.encode(jsonEncode(p.toJson()))),
    );
    return signEvent(
      author,
      Nip01Event(
        pubKey: author.publicKey,
        kind: kPositionKind,
        tags: [
          ['d', groupId],
          ['epoch', '$epoch'],
        ],
        content: content,
      ),
    );
  }

  Future<Position> decodePositionEvent(Nip01Event e) async {
    final clear = await _openSym(groupKey, e.content);
    return Position.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
  }

  /// Wrap [groupKey] to [recipientPubHex] (NIP-44) as a signed addressable event.
  Future<Nip01Event> buildWrappedKeyEvent(KeyPair sender, String recipientPubHex) async {
    final content = await Nip44.encryptMessage(
      hex.encode(groupKey),
      sender.privateKey!,
      recipientPubHex,
    );
    return signEvent(
      sender,
      Nip01Event(
        pubKey: sender.publicKey,
        kind: kWrappedKeyKind,
        tags: [
          ['d', '$recipientPubHex:$epoch'],
          ['p', recipientPubHex],
          ['epoch', '$epoch'],
          ['group', groupId],
        ],
        content: content,
      ),
    );
  }

  /// Recipient side: NIP-44-unwrap a wrapped-key event from [senderPubHex].
  static Future<Uint8List> openWrappedKey(
    KeyPair recipient,
    String senderPubHex,
    Nip01Event e,
  ) async {
    final keyHex = await Nip44.decryptMessage(e.content, recipient.privateKey!, senderPubHex);
    return Uint8List.fromList(hex.decode(keyHex));
  }

  /// First value of the named tag on an event, or null.
  static String? tagValue(Nip01Event e, String name) {
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == name) return t[1];
    }
    return null;
  }
}

// --- symmetric AEAD for the shared group key (ChaCha20-Poly1305, vetted primitive) ---

final _aead = Chacha20.poly1305Aead();
const _nonceLen = 12;
const _macLen = 16;

Future<String> _sealSym(Uint8List key, Uint8List plaintext) async {
  final box = await _aead.encrypt(plaintext,
      secretKey: SecretKey(key), nonce: _randomBytes(_nonceLen));
  return base64.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> _openSym(Uint8List key, String packed) async {
  final raw = base64.decode(packed);
  final clear = await _aead.decrypt(
    SecretBox(
      raw.sublist(_nonceLen, raw.length - _macLen),
      nonce: raw.sublist(0, _nonceLen),
      mac: Mac(raw.sublist(raw.length - _macLen)),
    ),
    secretKey: SecretKey(key),
  );
  return Uint8List.fromList(clear);
}

Uint8List _randomBytes(int n) {
  final rnd = Random.secure();
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = rnd.nextInt(256);
  }
  return b;
}
