import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// secp256k1 curve parameters
final ECDomainParameters _secp256k1 = ECDomainParameters('secp256k1');
final BigInt _n = _secp256k1.n;

/// Generates a new random secp256k1 private key (32 bytes).
Uint8List generatePrivateKey() {
  final secureRandom = _buildSecureRandom();
  while (true) {
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = secureRandom.nextUint8();
    }
    if (isValidPrivateKey(bytes)) return bytes;
  }
}

/// Derives the x-only public key from a private key (BIP-340 style, 32 bytes).
///
/// Returns the x-coordinate of G*k, with k adjusted so that the resulting
/// point has an even y-coordinate (BIP-340 "lift_x" convention).
Uint8List derivePublicKey(Uint8List privateKey) {
  final d0 = _bigIntFromBytes(privateKey);
  if (d0 < BigInt.one || d0 >= _n) {
    throw ArgumentError('Private key is out of range [1, n-1]');
  }

  final G = _secp256k1.G;
  final P = G * d0;
  if (P == null || P.isInfinity) {
    throw StateError('Point multiplication returned infinity');
  }

  return _bigIntToBytes32(P.x!.toBigInteger()!);
}

/// Returns true if the private key is valid (1 ≤ k < n).
bool isValidPrivateKey(Uint8List privateKey) {
  if (privateKey.length != 32) return false;
  final k = _bigIntFromBytes(privateKey);
  return k >= BigInt.one && k < _n;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

FortunaRandom _buildSecureRandom() {
  final secureRandom = FortunaRandom();
  final seedSource = Random.secure();
  final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
  secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
  return secureRandom;
}

BigInt _bigIntFromBytes(Uint8List bytes) {
  BigInt result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

Uint8List _bigIntToBytes32(BigInt value) {
  final result = Uint8List(32);
  var v = value;
  for (var i = 31; i >= 0; i--) {
    result[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return result;
}
