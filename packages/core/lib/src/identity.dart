import 'package:ndk/ndk.dart';
import 'package:ndk/shared/nips/nip01/bip340.dart';
import 'package:ndk/shared/nips/nip01/key_pair.dart';

/// Helpers over NDK's [KeyPair] — a device's secp256k1 identity. The private key
/// is a 64-hex string; [KeyPair.publicKey] is the x-only pubkey friends know.
KeyPair generateKeyPair() => Bip340.generatePrivateKey();

KeyPair keyPairFromPrivateHex(String privateHex) =>
    KeyPair(privateHex, Bip340.getPublicKey(privateHex), null, null);

/// Sign an event with this keypair (NDK's BIP-340 signer).
Future<Nip01Event> signEvent(KeyPair keyPair, Nip01Event event) {
  final signer = Bip340EventSigner(
    privateKey: keyPair.privateKey,
    publicKey: keyPair.publicKey,
  );
  return signer.sign(event);
}
