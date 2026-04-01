import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/crypto/keys.dart';

void main() {
  group('Key generation', () {
    test('generatePrivateKey returns 32 bytes', () {
      final key = generatePrivateKey();
      expect(key.length, equals(32));
    });

    test('generatePrivateKey returns different keys each time', () {
      final k1 = generatePrivateKey();
      final k2 = generatePrivateKey();
      // Overwhelmingly likely to differ (probability of collision is 1/2^256)
      expect(k1, isNot(equals(k2)));
    });

    test('generatePrivateKey is always valid', () {
      for (var i = 0; i < 20; i++) {
        final key = generatePrivateKey();
        expect(isValidPrivateKey(key), isTrue);
      }
    });

    test('derivePublicKey returns 32 bytes', () {
      final priv = generatePrivateKey();
      final pub = derivePublicKey(priv);
      expect(pub.length, equals(32));
    });

    test('derivePublicKey is deterministic', () {
      final priv = generatePrivateKey();
      final pub1 = derivePublicKey(priv);
      final pub2 = derivePublicKey(priv);
      expect(pub1, equals(pub2));
    });

    test('derivePublicKey with known private key matches BIP-340 vector 0', () {
      // BIP-340 vector 0: seckey = 0x03
      final priv = Uint8List(32);
      priv[31] = 3;
      final pub = derivePublicKey(priv);
      final expectedHex =
          'f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9';
      expect(_hexEncode(pub), equals(expectedHex));
    });

    test('derivePublicKey with known private key matches BIP-340 vector 1', () {
      // BIP-340 vector 1
      final priv = _hexDecode(
        'b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef',
      );
      final pub = derivePublicKey(priv);
      expect(
        _hexEncode(pub),
        equals(
          'dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659',
        ),
      );
    });

    test('isValidPrivateKey rejects all-zero key', () {
      expect(isValidPrivateKey(Uint8List(32)), isFalse);
    });

    test('isValidPrivateKey rejects key > n', () {
      // n = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
      final aboveN = _hexDecode(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364142',
      );
      expect(isValidPrivateKey(aboveN), isFalse);
    });

    test('isValidPrivateKey rejects wrong length', () {
      expect(isValidPrivateKey(Uint8List(31)), isFalse);
      expect(isValidPrivateKey(Uint8List(33)), isFalse);
    });

    test('isValidPrivateKey accepts key = 1', () {
      final key = Uint8List(32);
      key[31] = 1;
      expect(isValidPrivateKey(key), isTrue);
    });

    test('isValidPrivateKey accepts key = n-1', () {
      // n-1 = FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140
      final nMinus1 = _hexDecode(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140',
      );
      expect(isValidPrivateKey(nMinus1), isTrue);
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _hexEncode(Uint8List bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

Uint8List _hexDecode(String hex) {
  final h = hex.toLowerCase().replaceAll(' ', '');
  final result = Uint8List(h.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}
