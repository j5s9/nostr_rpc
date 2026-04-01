import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/crypto/nip44.dart';
import 'package:nostr_rpc/src/crypto/keys.dart';

void main() {
  // Known test keys: sec1=1 (G generator point), sec2=2
  const sec1 =
      '0000000000000000000000000000000000000000000000000000000000000001';
  const sec2 =
      '0000000000000000000000000000000000000000000000000000000000000002';
  // pub1 = G*1 x-coordinate
  const pub1 =
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
  // pub2 = G*2 x-coordinate
  const pub2 =
      'c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5';

  group('computeConversationKey', () {
    test('is symmetric: conv(sec1, pub2) == conv(sec2, pub1)', () {
      final ck1 = computeConversationKey(sec1, pub2);
      final ck2 = computeConversationKey(sec2, pub1);
      expect(ck1, equals(ck2));
    });

    test('returns 32 bytes', () {
      final ck = computeConversationKey(sec1, pub2);
      expect(ck.length, equals(32));
    });
  });

  group('round-trip encrypt/decrypt', () {
    test('encrypts and decrypts simple string', () async {
      const plaintext = 'hello world';
      final encrypted = await nip44Encrypt(plaintext, sec1, pub2);
      final decrypted = await nip44Decrypt(encrypted, sec2, pub1);
      expect(decrypted, equals(plaintext));
    });

    test('encrypts and decrypts single byte', () async {
      const plaintext = 'a';
      final encrypted = await nip44Encrypt(plaintext, sec1, pub2);
      final decrypted = await nip44Decrypt(encrypted, sec2, pub1);
      expect(decrypted, equals(plaintext));
    });

    test('encrypts and decrypts unicode', () async {
      const plaintext = 'こんにちは世界 🌍';
      final encrypted = await nip44Encrypt(plaintext, sec1, pub2);
      final decrypted = await nip44Decrypt(encrypted, sec2, pub1);
      expect(decrypted, equals(plaintext));
    });

    test('two encryptions produce different payloads (random nonce)', () async {
      const plaintext = 'same message';
      final enc1 = await nip44Encrypt(plaintext, sec1, pub2);
      final enc2 = await nip44Encrypt(plaintext, sec1, pub2);
      expect(enc1, isNot(equals(enc2)));
    });

    test('custom nonce produces deterministic output', () async {
      const plaintext = 'deterministic';
      final nonce = Uint8List(32); // all zeros
      final enc1 = await nip44Encrypt(
        plaintext,
        sec1,
        pub2,
        customNonce: nonce,
      );
      final enc2 = await nip44Encrypt(
        plaintext,
        sec1,
        pub2,
        customNonce: nonce,
      );
      expect(enc1, equals(enc2));
    });

    test('round-trip with random generated keys', () async {
      final privA = generatePrivateKey();
      final privB = generatePrivateKey();
      final pubA = derivePublicKey(privA);
      final pubB = derivePublicKey(privB);

      String bytesToHex(Uint8List b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

      final privAHex = bytesToHex(privA);
      final privBHex = bytesToHex(privB);
      final pubAHex = bytesToHex(pubA);
      final pubBHex = bytesToHex(pubB);

      const plaintext = 'random key test';
      final encrypted = await nip44Encrypt(plaintext, privAHex, pubBHex);
      final decrypted = await nip44Decrypt(encrypted, privBHex, pubAHex);
      expect(decrypted, equals(plaintext));
    });
  });

  group('payload format', () {
    test('payload is valid base64 with version byte 0x02', () async {
      const plaintext = 'test';
      final nonce = Uint8List(32);
      final encrypted = await nip44Encrypt(
        plaintext,
        sec1,
        pub2,
        customNonce: nonce,
      );
      expect(encrypted, isNotEmpty);
      expect(encrypted[0], isNot(equals('#')));
      final bytes = base64.decode(encrypted);
      expect(bytes[0], equals(0x02));
      expect(bytes.length, greaterThanOrEqualTo(99));
    });

    test('nonce in payload matches custom nonce', () async {
      const plaintext = 'x';
      final nonce = Uint8List(32); // all zeros
      final encrypted = await nip44Encrypt(
        plaintext,
        sec1,
        pub2,
        customNonce: nonce,
      );
      final bytes = base64.decode(encrypted);
      final extractedNonce = bytes.sublist(1, 33);
      expect(extractedNonce, equals(nonce));
    });
  });

  group('MAC tamper detection', () {
    test('throws FormatException on tampered ciphertext byte', () async {
      const plaintext = 'tamper test';
      final nonce = Uint8List(32);
      final encrypted = await nip44Encrypt(
        plaintext,
        sec1,
        pub2,
        customNonce: nonce,
      );

      final bytes = base64.decode(encrypted);
      final tampered = Uint8List.fromList(bytes);
      tampered[34] ^= 0xFF; // flip ciphertext byte
      final tamperedB64 = base64.encode(tampered);

      expect(
        () async => nip44Decrypt(tamperedB64, sec2, pub1),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException on tampered MAC byte', () async {
      const plaintext = 'mac tamper test';
      final nonce = Uint8List(32);
      final encrypted = await nip44Encrypt(
        plaintext,
        sec1,
        pub2,
        customNonce: nonce,
      );

      final bytes = base64.decode(encrypted);
      final tampered = Uint8List.fromList(bytes);
      tampered[tampered.length - 1] ^= 0x01; // flip last MAC byte
      final tamperedB64 = base64.encode(tampered);

      expect(
        () async => nip44Decrypt(tamperedB64, sec2, pub1),
        throwsA(isA<FormatException>()),
      );
    });

    test('throws FormatException with wrong recipient private key', () async {
      const plaintext = 'wrong key test';
      final encrypted = await nip44Encrypt(plaintext, sec1, pub2);

      // Try decrypting with sec1 instead of sec2
      expect(
        () async => nip44Decrypt(encrypted, sec1, pub1),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('calcPaddedLen', () {
    test('len=1 → 32', () => expect(calcPaddedLen(1), equals(32)));
    test('len=32 → 32', () => expect(calcPaddedLen(32), equals(32)));
    test('len=33 → 64', () => expect(calcPaddedLen(33), equals(64)));
    test('len=64 → 64', () => expect(calcPaddedLen(64), equals(64)));
    test('len=65 → 96', () => expect(calcPaddedLen(65), equals(96)));
    test('len=100 → 128', () => expect(calcPaddedLen(100), equals(128)));
    test('len=256 → 256', () => expect(calcPaddedLen(256), equals(256)));
    test('len=257 → 320', () => expect(calcPaddedLen(257), equals(320)));
    test(
      'len=65535 → 65536',
      () => expect(calcPaddedLen(65535), equals(65536)),
    );
  });
}
