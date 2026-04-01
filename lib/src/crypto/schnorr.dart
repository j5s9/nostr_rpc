// BIP-340 Schnorr Sign and Verify for secp256k1.
//
// Reference: https://github.com/bitcoin/bips/blob/master/bip-0340/bip-0340.mediawiki
// Reference Python: https://github.com/bitcoin/bips/blob/master/bip-0340/reference.py
//
// Implemented from scratch — pointycastle has no native BIP-340 Schnorr.

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ---------------------------------------------------------------------------
// secp256k1 constants
// ---------------------------------------------------------------------------

final ECDomainParameters _curve = ECDomainParameters('secp256k1');

// Field prime p = 2^256 - 2^32 - 977
final BigInt _p = BigInt.parse(
  'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F',
  radix: 16,
);

// Curve order n
final BigInt _n = _curve.n;

// Generator point G
final ECPoint _generator = _curve.G;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Signs [messageHash] with [privateKey] using BIP-340 Schnorr.
///
/// [privateKey] must be 32 bytes (a valid secp256k1 private key).
/// [messageHash] may be any length (Nostr always uses 32 bytes).
/// [auxRand] must be 32 bytes of auxiliary randomness (defaults to zero bytes
/// when null — deterministic but less secure; use random bytes in production).
///
/// Returns a 64-byte signature (R.x || s).
Uint8List schnorrSign(
  Uint8List privateKey,
  Uint8List messageHash, {
  Uint8List? auxRand,
}) {
  if (privateKey.length != 32) {
    throw ArgumentError('privateKey must be 32 bytes');
  }

  final aux = auxRand ?? Uint8List(32);
  if (aux.length != 32) {
    throw ArgumentError('auxRand must be 32 bytes');
  }

  final d0 = _bigIntFromBytes(privateKey);
  if (d0 < BigInt.one || d0 >= _n) {
    throw ArgumentError('Private key is out of valid range [1, n-1]');
  }

  // P = G * d0
  final pointP = _generator * d0;
  if (pointP == null || pointP.isInfinity) {
    throw StateError('Point multiplication returned infinity');
  }

  // Negate d if P has odd y (BIP-340 requirement)
  final d = _hasEvenY(pointP) ? d0 : _n - d0;

  // t = d XOR tagged_hash("BIP0340/aux", aux_rand)
  final tBytes = _xorBytes(
    _bigIntToBytes32(d),
    _taggedHash('BIP0340/aux', aux),
  );

  // k0 = int(tagged_hash("BIP0340/nonce", t || bytes(P) || msg)) mod n
  final px = _bigIntToBytes32(pointP.x!.toBigInteger()!);
  final nonceInput = Uint8List(32 + 32 + messageHash.length);
  nonceInput.setRange(0, 32, tBytes);
  nonceInput.setRange(32, 64, px);
  nonceInput.setRange(64, 64 + messageHash.length, messageHash);
  final k0 = _bigIntFromBytes(_taggedHash('BIP0340/nonce', nonceInput)) % _n;

  if (k0 == BigInt.zero) {
    throw StateError('k0 == 0: negligible probability, retry with new auxRand');
  }

  // R = G * k0
  final pointR = _generator * k0;
  if (pointR == null || pointR.isInfinity) {
    throw StateError('R is infinity: negligible probability');
  }

  // Negate k if R has odd y
  final k = _hasEvenY(pointR) ? k0 : _n - k0;

  // e = int(tagged_hash("BIP0340/challenge", bytes(R) || bytes(P) || msg)) mod n
  final rx = _bigIntToBytes32(pointR.x!.toBigInteger()!);
  final challengeInput = Uint8List(32 + 32 + messageHash.length);
  challengeInput.setRange(0, 32, rx);
  challengeInput.setRange(32, 64, px);
  challengeInput.setRange(64, 64 + messageHash.length, messageHash);
  final e =
      _bigIntFromBytes(_taggedHash('BIP0340/challenge', challengeInput)) % _n;

  // s = (k + e * d) mod n
  final s = (k + e * d) % _n;

  // sig = bytes(R.x) || bytes32(s)
  final sig = Uint8List(64);
  sig.setRange(0, 32, rx);
  sig.setRange(32, 64, _bigIntToBytes32(s));
  return sig;
}

/// Verifies a BIP-340 Schnorr signature.
///
/// [publicKey] is the x-only pubkey (32 bytes).
/// [messageHash] is the message hash (any length supported by BIP-340).
/// [signature] is the 64-byte signature (R.x || s).
///
/// Returns true if valid, false otherwise.
bool schnorrVerify(
  Uint8List publicKey,
  Uint8List messageHash,
  Uint8List signature,
) {
  if (publicKey.length != 32) return false;
  if (signature.length != 64) return false;

  // P = lift_x(pubkey)
  final P = _liftX(_bigIntFromBytes(publicKey));
  if (P == null) return false;

  final r = _bigIntFromBytes(signature.sublist(0, 32));
  final s = _bigIntFromBytes(signature.sublist(32, 64));

  // r must be < p; s must be < n
  if (r >= _p) return false;
  if (s >= _n) return false;

  // e = int(tagged_hash("BIP0340/challenge", bytes32(r) || pubkey || msg)) mod n
  final challengeInput = Uint8List(32 + 32 + messageHash.length);
  challengeInput.setRange(0, 32, signature.sublist(0, 32));
  challengeInput.setRange(32, 64, publicKey);
  challengeInput.setRange(64, 64 + messageHash.length, messageHash);
  final e =
      _bigIntFromBytes(_taggedHash('BIP0340/challenge', challengeInput)) % _n;

  // R = s*G + (n-e)*P  (equivalent to s*G - e*P)
  final sG = _generator * s;
  final eNeg = (_n - e) % _n;
  final eP = P * eNeg;

  final ECPoint? R;
  if (sG == null || sG.isInfinity) {
    R = (eP == null || eP.isInfinity) ? null : eP;
  } else if (eP == null || eP.isInfinity) {
    R = sG;
  } else {
    R = sG + eP;
  }

  if (R == null || R.isInfinity) return false;
  if (!_hasEvenY(R)) return false;
  if (R.x!.toBigInteger() != r) return false;

  return true;
}

// ---------------------------------------------------------------------------
// BIP-340 Tagged Hash
// ---------------------------------------------------------------------------

/// tagged_hash(tag, msg) = SHA256(SHA256(tag) || SHA256(tag) || msg)
Uint8List _taggedHash(String tag, Uint8List msg) {
  final digest = SHA256Digest();
  final tagBytes = Uint8List.fromList(tag.codeUnits);

  // SHA256(tag)
  digest.reset();
  digest.update(tagBytes, 0, tagBytes.length);
  final tagHash = Uint8List(32);
  digest.doFinal(tagHash, 0);

  // SHA256(tagHash || tagHash || msg)
  digest.reset();
  digest.update(tagHash, 0, 32);
  digest.update(tagHash, 0, 32);
  digest.update(msg, 0, msg.length);
  final result = Uint8List(32);
  digest.doFinal(result, 0);
  return result;
}

// ---------------------------------------------------------------------------
// Curve helpers
// ---------------------------------------------------------------------------

/// lift_x(x): returns the unique point P on the curve with P.x == x and even y.
/// Returns null if no such point exists.
ECPoint? _liftX(BigInt x) {
  if (x >= _p) return null;

  // y_sq = (x^3 + 7) mod p
  final ySq = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;

  // y = y_sq^((p+1)/4) mod p  — works because p ≡ 3 mod 4
  final y = ySq.modPow((_p + BigInt.one) >> 2, _p);

  if (y.modPow(BigInt.two, _p) != ySq) return null;

  // Use even y
  final yFinal = (y & BigInt.one) == BigInt.zero ? y : _p - y;

  final fp = _curve.curve.createPoint(x, yFinal);
  return fp;
}

/// Returns true if the point P has an even y-coordinate.
bool _hasEvenY(ECPoint P) {
  return (P.y!.toBigInteger()! & BigInt.one) == BigInt.zero;
}

// ---------------------------------------------------------------------------
// Byte / BigInt helpers
// ---------------------------------------------------------------------------

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

Uint8List _xorBytes(Uint8List a, Uint8List b) {
  assert(a.length == b.length);
  final result = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    result[i] = a[i] ^ b[i];
  }
  return result;
}
