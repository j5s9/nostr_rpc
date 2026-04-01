// NIP-44 v2 Encryption/Decryption
//
// Reference: https://github.com/nostr-protocol/nips/blob/master/44.md
// Algorithm: secp256k1 ECDH → HKDF-extract → HKDF-expand → ChaCha20 + HMAC-SHA256
//
// Version byte: 0x02
// Payload layout: base64(0x02 | nonce[32] | ciphertext[n] | mac[32])

import 'dart:convert';
import 'dart:math' show Random;
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

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Encrypts [plaintext] from sender to recipient.
///
/// Returns a base64-encoded NIP-44 v2 payload.
/// [customNonce] is for testing only — production uses a random 32-byte nonce.
Future<String> nip44Encrypt(
  String plaintext,
  String senderPrivkeyHex,
  String recipientPubkeyHex, {
  Uint8List? customNonce,
}) async {
  final convKey = computeConversationKey(senderPrivkeyHex, recipientPubkeyHex);
  final nonce = customNonce ?? _secureRandomBytes(32);
  return _encryptWithConversationKey(plaintext, convKey, nonce);
}

/// Decrypts a NIP-44 v2 payload.
///
/// Throws [FormatException] on MAC failure or malformed payload.
Future<String> nip44Decrypt(
  String ciphertext,
  String recipientPrivkeyHex,
  String senderPubkeyHex,
) async {
  final convKey = computeConversationKey(recipientPrivkeyHex, senderPubkeyHex);
  return _decryptWithConversationKey(ciphertext, convKey);
}

/// Computes the shared conversation key:
/// ECDH(privkey, pubkey) → shared_x → HKDF-extract(salt="nip44-v2", IKM=shared_x)
/// Returns 32 bytes.
Uint8List computeConversationKey(String privkeyHex, String pubkeyHex) {
  final sharedX = _computeSharedX(privkeyHex, pubkeyHex);
  return _hkdfExtract(sharedX, utf8.encode('nip44-v2'));
}

// ---------------------------------------------------------------------------
// Internal: encrypt/decrypt with pre-computed conversation key
// ---------------------------------------------------------------------------

/// Encrypt with a known conversation key (useful for testing).
String nip44EncryptWithKey(
  String plaintext,
  Uint8List conversationKey,
  Uint8List nonce,
) => _encryptWithConversationKey(plaintext, conversationKey, nonce);

/// Decrypt with a known conversation key (useful for testing).
String nip44DecryptWithKey(String payload, Uint8List conversationKey) =>
    _decryptWithConversationKey(payload, conversationKey);

String _encryptWithConversationKey(
  String plaintext,
  Uint8List conversationKey,
  Uint8List nonce,
) {
  if (nonce.length != 32) throw ArgumentError('nonce must be 32 bytes');

  final keys = _getMessageKeys(conversationKey, nonce);
  final chachaKey = keys[0];
  final chachaNonce = keys[1];
  final hmacKey = keys[2];

  final padded = _pad(plaintext);
  final ciphertext = _chacha20(chachaKey, chachaNonce, padded);
  final mac = _hmacSha256(hmacKey, _concat(nonce, ciphertext));

  // payload = base64(0x02 | nonce[32] | ciphertext | mac[32])
  final payload = Uint8List(1 + 32 + ciphertext.length + 32);
  payload[0] = 0x02;
  payload.setRange(1, 33, nonce);
  payload.setRange(33, 33 + ciphertext.length, ciphertext);
  payload.setRange(33 + ciphertext.length, payload.length, mac);

  return base64.encode(payload);
}

String _decryptWithConversationKey(String payload, Uint8List conversationKey) {
  // Validate and decode payload
  if (payload.isEmpty) throw FormatException('empty payload');
  if (payload[0] == '#') throw FormatException('unknown version');
  if (payload.length < 132 || payload.length > 87472) {
    throw FormatException('invalid payload size: ${payload.length}');
  }

  final data = base64.decode(payload);
  final dlen = data.length;

  if (dlen < 99 || dlen > 65603) {
    throw FormatException('invalid data size: $dlen');
  }
  if (data[0] != 0x02) {
    throw FormatException('unknown version: ${data[0]}');
  }

  final nonce = data.sublist(1, 33);
  final ciphertext = data.sublist(33, dlen - 32);
  final mac = data.sublist(dlen - 32);

  final keys = _getMessageKeys(conversationKey, nonce);
  final chachaKey = keys[0];
  final chachaNonce = keys[1];
  final hmacKey = keys[2];

  // Verify MAC (constant-time comparison)
  final expectedMac = _hmacSha256(hmacKey, _concat(nonce, ciphertext));
  if (!_constantTimeEquals(expectedMac, mac)) {
    throw FormatException('invalid MAC');
  }

  final padded = _chacha20(chachaKey, chachaNonce, ciphertext);
  return _unpad(padded);
}

// ---------------------------------------------------------------------------
// ECDH
// ---------------------------------------------------------------------------

/// Multiply the lift_x(pubkeyHex) point by privkeyHex scalar.
/// Returns the x-coordinate of the shared point (32 bytes, unhashed).
Uint8List _computeSharedX(String privkeyHex, String pubkeyHex) {
  final privKey = BigInt.parse(privkeyHex, radix: 16);
  if (privKey < BigInt.one || privKey >= _curve.n) {
    throw ArgumentError('private key out of range');
  }

  final pubX = BigInt.parse(pubkeyHex, radix: 16);
  final pubPoint = _liftX(pubX);
  if (pubPoint == null) {
    throw ArgumentError('invalid public key (lift_x failed): $pubkeyHex');
  }

  final shared = pubPoint * privKey;
  if (shared == null || shared.isInfinity) {
    throw StateError('ECDH result is infinity');
  }

  return _bigIntToBytes32(shared.x!.toBigInteger()!);
}

/// lift_x(x): the unique secp256k1 point with this x-coordinate and even y.
ECPoint? _liftX(BigInt x) {
  if (x >= _p) return null;

  final ySq = (x.modPow(BigInt.from(3), _p) + BigInt.from(7)) % _p;
  final y = ySq.modPow((_p + BigInt.one) >> 2, _p);

  if (y.modPow(BigInt.two, _p) != ySq) return null;

  final yFinal = (y & BigInt.one) == BigInt.zero ? y : _p - y;
  return _curve.curve.createPoint(x, yFinal);
}

// ---------------------------------------------------------------------------
// HKDF (RFC 5869, SHA-256)
// ---------------------------------------------------------------------------

/// HKDF-Extract: PRK = HMAC-SHA256(key=salt, data=ikm)
Uint8List _hkdfExtract(Uint8List ikm, List<int> salt) {
  final saltBytes = Uint8List.fromList(salt);
  return _hmacSha256(saltBytes, ikm);
}

/// HKDF-Expand: generate `length` bytes from PRK + info.
/// Uses standard RFC 5869 T(1) || T(2) || T(3) construction.
Uint8List _hkdfExpand(Uint8List prk, Uint8List info, int length) {
  final hashLen = 32; // SHA-256
  final n = (length + hashLen - 1) ~/ hashLen;
  final okm = Uint8List(n * hashLen);

  Uint8List previous = Uint8List(0);
  for (var i = 1; i <= n; i++) {
    // T(i) = HMAC-SHA256(prk, T(i-1) || info || i)
    final data = Uint8List(previous.length + info.length + 1);
    data.setRange(0, previous.length, previous);
    data.setRange(previous.length, previous.length + info.length, info);
    data[previous.length + info.length] = i;
    previous = _hmacSha256(prk, data);
    okm.setRange((i - 1) * hashLen, i * hashLen, previous);
  }

  return okm.sublist(0, length);
}

/// Get per-message keys: [chacha_key(32), chacha_nonce(12), hmac_key(32)]
List<Uint8List> _getMessageKeys(Uint8List conversationKey, Uint8List nonce) {
  if (conversationKey.length != 32) {
    throw ArgumentError('conversation key must be 32 bytes');
  }
  if (nonce.length != 32) {
    throw ArgumentError('nonce must be 32 bytes');
  }

  final expanded = _hkdfExpand(conversationKey, nonce, 76);
  return [
    expanded.sublist(0, 32), // chacha_key
    expanded.sublist(32, 44), // chacha_nonce (12 bytes)
    expanded.sublist(44, 76), // hmac_key
  ];
}

// ---------------------------------------------------------------------------
// HMAC-SHA256
// ---------------------------------------------------------------------------

Uint8List _hmacSha256(Uint8List key, Uint8List data) {
  final mac = HMac(SHA256Digest(), 64);
  mac.init(KeyParameter(key));
  mac.update(data, 0, data.length);
  final result = Uint8List(32);
  mac.doFinal(result, 0);
  return result;
}

// ---------------------------------------------------------------------------
// ChaCha20 (RFC 8439, 12-byte nonce, counter starts at 0)
// ---------------------------------------------------------------------------

Uint8List _chacha20(Uint8List key, Uint8List nonce12, Uint8List data) {
  final engine = ChaCha7539Engine();
  engine.init(true, ParametersWithIV(KeyParameter(key), nonce12));
  final output = Uint8List(data.length);
  engine.processBytes(data, 0, data.length, output, 0);
  return output;
}

// ---------------------------------------------------------------------------
// Padding (NIP-44 specific)
// ---------------------------------------------------------------------------

/// Pads plaintext according to NIP-44 spec.
/// Format: u16BE(len) || plaintext_utf8 || zero_bytes
Uint8List _pad(String plaintext) {
  final plaintextBytes = utf8.encode(plaintext);
  final unpaddedLen = plaintextBytes.length;

  if (unpaddedLen < 1 || unpaddedLen > 65535) {
    throw ArgumentError('invalid plaintext length: $unpaddedLen');
  }

  final paddedLen = _calcPaddedLen(unpaddedLen);
  final padded = Uint8List(2 + paddedLen);

  // First 2 bytes: plaintext length as big-endian uint16
  padded[0] = (unpaddedLen >> 8) & 0xFF;
  padded[1] = unpaddedLen & 0xFF;

  // Then plaintext bytes
  padded.setRange(2, 2 + unpaddedLen, plaintextBytes);

  // Remaining bytes are 0 (Uint8List default)
  return padded;
}

/// Unpads a padded plaintext blob.
String _unpad(Uint8List padded) {
  if (padded.length < 2) throw FormatException('padded data too short');

  final unpaddedLen = (padded[0] << 8) | padded[1];
  if (unpaddedLen == 0) throw FormatException('invalid padding: zero length');
  if (unpaddedLen > padded.length - 2) {
    throw FormatException('invalid padding: length overflow');
  }

  final plaintextBytes = padded.sublist(2, 2 + unpaddedLen);

  // Verify padding length matches spec
  final expectedPaddedLen = _calcPaddedLen(unpaddedLen);
  if (padded.length != 2 + expectedPaddedLen) {
    throw FormatException(
      'invalid padding: expected ${2 + expectedPaddedLen} bytes, got ${padded.length}',
    );
  }

  return utf8.decode(plaintextBytes);
}

/// NIP-44 padding length calculation.
/// Reference: https://github.com/nostr-protocol/nips/blob/master/44.md
int calcPaddedLen(int unpaddedLen) => _calcPaddedLen(unpaddedLen);

int _calcPaddedLen(int unpaddedLen) {
  if (unpaddedLen <= 0) throw ArgumentError('unpaddedLen must be > 0');
  if (unpaddedLen <= 32) return 32;

  // next_power = 1 << (floor(log2(unpaddedLen - 1)) + 1)
  // i.e. the next power of 2 >= unpaddedLen
  var nextPower = 1;
  while (nextPower < unpaddedLen) {
    nextPower <<= 1;
  }

  final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
  return chunk * ((unpaddedLen - 1) ~/ chunk + 1);
}

// ---------------------------------------------------------------------------
// Constant-time equality
// ---------------------------------------------------------------------------

bool _constantTimeEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Uint8List _concat(Uint8List a, Uint8List b) {
  final result = Uint8List(a.length + b.length);
  result.setRange(0, a.length, a);
  result.setRange(a.length, result.length, b);
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

Uint8List _secureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}
