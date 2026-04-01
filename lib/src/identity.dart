import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'crypto/keys.dart';
import 'crypto/bech32.dart';

/// A Nostr identity backed by a secp256k1 keypair.
class NostrIdentity {
  const NostrIdentity._({
    required Uint8List privkeyBytes,
    required String pubkeyHex,
  }) : _privkeyBytes = privkeyBytes,
       _pubkeyHex = pubkeyHex;

  final Uint8List _privkeyBytes;
  final String _pubkeyHex;

  /// Generate a fresh random keypair.
  factory NostrIdentity.generate() {
    final privkeyBytes = generatePrivateKey();
    final pubkeyBytes = derivePublicKey(privkeyBytes);
    final pubkeyHex = hex.encode(pubkeyBytes);
    return NostrIdentity._(privkeyBytes: privkeyBytes, pubkeyHex: pubkeyHex);
  }

  /// Reconstruct from an nsec1... bech32 private key.
  factory NostrIdentity.fromNsec(String nsec) {
    final privkeyHex = decodeNsec(nsec);
    return NostrIdentity.fromPrivateKey(privkeyHex);
  }

  /// Reconstruct from an existing 64-char hex private key.
  factory NostrIdentity.fromPrivateKey(String privkeyHex) {
    final privkeyBytes = Uint8List.fromList(hex.decode(privkeyHex));
    final pubkeyBytes = derivePublicKey(privkeyBytes);
    final pubkeyHex = hex.encode(pubkeyBytes);
    return NostrIdentity._(privkeyBytes: privkeyBytes, pubkeyHex: pubkeyHex);
  }

  /// The private key as raw bytes (32 bytes).
  Uint8List get privkeyBytes => _privkeyBytes;

  /// The private key as 64-char lowercase hex.
  String get privkeyHex => hex.encode(_privkeyBytes);

  /// The x-only public key as 64-char lowercase hex.
  String get pubkeyHex => _pubkeyHex;

  /// The public key in npub bech32 format.
  String get npub => encodeNpub(_pubkeyHex);

  /// The private key in nsec bech32 format.
  String get nsec => encodeNsec(privkeyHex);
}
