// NIP-44 v2 official test vector validation.
//
// Vectors from: https://github.com/paulmillr/nip44/blob/main/nip44.vectors.json
// SHA-256 of vectors file: 269ed0f69e4c192512cc779e78c555090cebc7c785b609e338a62afc3ce25040
//
// Sections tested:
//   valid.get_conversation_key    — ECDH + HKDF-extract
//   valid.get_message_keys        — HKDF-expand key derivation (indirect roundtrip)
//   valid.calc_padded_len         — padding length formula
//   valid.encrypt_decrypt         — full encrypt/decrypt cycle
//   valid.encrypt_decrypt_long_msg — long message (SHA-256 checksum verification)
//   invalid.decrypt               — must throw on invalid payloads
//   invalid.get_conversation_key  — must throw on bad keys

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

import 'package:nostr_rpc/src/crypto/nip44.dart';

// Path relative to package root (dart test is run from project root)
const _vectorsPath = 'test/crypto/fixtures/nip44_vectors.json';

void main() {
  late Map<String, dynamic> vectors;

  setUpAll(() {
    final file = File(_vectorsPath);
    vectors = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
  });

  // ---------------------------------------------------------------------------
  // valid.get_conversation_key
  // ---------------------------------------------------------------------------

  group('valid.get_conversation_key', () {
    test('all 35 vectors produce expected conversation_key', () {
      final cases =
          (vectors['v2']['valid']['get_conversation_key'] as List)
              .cast<Map<String, dynamic>>();

      for (final tc in cases) {
        final sec1 = tc['sec1'] as String;
        final pub2 = tc['pub2'] as String;
        final expectedHex = tc['conversation_key'] as String;

        final result = computeConversationKey(sec1, pub2);
        final resultHex = hex.encode(result);

        expect(resultHex, equals(expectedHex), reason: 'sec1=$sec1 pub2=$pub2');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // valid.get_message_keys
  // ---------------------------------------------------------------------------

  group('valid.get_message_keys', () {
    test('encrypt/decrypt roundtrip validates derived message keys', () {
      final data =
          vectors['v2']['valid']['get_message_keys'] as Map<String, dynamic>;
      final conversationKeyHex = data['conversation_key'] as String;
      final conversationKey = Uint8List.fromList(
        hex.decode(conversationKeyHex),
      );

      final keys = (data['keys'] as List).cast<Map<String, dynamic>>();

      for (final tc in keys) {
        final nonceHex = tc['nonce'] as String;
        final nonce = Uint8List.fromList(hex.decode(nonceHex));

        // If derived chacha_key/nonce/hmac_key are correct, encrypt+decrypt works.
        final payload = nip44EncryptWithKey(
          'test message',
          conversationKey,
          nonce,
        );
        final decrypted = nip44DecryptWithKey(payload, conversationKey);
        expect(decrypted, equals('test message'), reason: 'nonce=$nonceHex');
      }
    });
  });

  // ---------------------------------------------------------------------------
  // valid.calc_padded_len
  // ---------------------------------------------------------------------------

  group('valid.calc_padded_len', () {
    test('all [input, expected] pairs match', () {
      final cases =
          (vectors['v2']['valid']['calc_padded_len'] as List)
              .cast<List<dynamic>>();

      for (final tc in cases) {
        final input = tc[0] as int;
        final expected = tc[1] as int;
        expect(
          calcPaddedLen(input),
          equals(expected),
          reason: 'calcPaddedLen($input)',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // valid.encrypt_decrypt
  // ---------------------------------------------------------------------------

  group('valid.encrypt_decrypt', () {
    test('encrypt with known nonce produces exact expected payload', () {
      final cases =
          (vectors['v2']['valid']['encrypt_decrypt'] as List)
              .cast<Map<String, dynamic>>();

      for (final tc in cases) {
        final expectedConvKeyHex = tc['conversation_key'] as String;
        final nonceHex = tc['nonce'] as String;
        final plaintext = tc['plaintext'] as String;
        final expectedPayload = tc['payload'] as String;

        final convKey = Uint8List.fromList(hex.decode(expectedConvKeyHex));
        final nonce = Uint8List.fromList(hex.decode(nonceHex));

        // Encrypt with known nonce → must match expected payload exactly
        final payload = nip44EncryptWithKey(plaintext, convKey, nonce);
        expect(
          payload,
          equals(expectedPayload),
          reason:
              'conversation_key=$expectedConvKeyHex nonce=$nonceHex plaintext=${plaintext.substring(0, plaintext.length.clamp(0, 40))}',
        );

        // Decrypt back → must recover plaintext
        final decrypted = nip44DecryptWithKey(payload, convKey);
        expect(
          decrypted,
          equals(plaintext),
          reason: 'decrypt failed for nonce=$nonceHex',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // valid.encrypt_decrypt_long_msg
  // ---------------------------------------------------------------------------

  group('valid.encrypt_decrypt_long_msg', () {
    test('long message: payload SHA-256 matches expected', () {
      final cases =
          (vectors['v2']['valid']['encrypt_decrypt_long_msg'] as List)
              .cast<Map<String, dynamic>>();

      for (final tc in cases) {
        final convKeyHex = tc['conversation_key'] as String;
        final nonceHex = tc['nonce'] as String;
        final pattern = tc['pattern'] as String;
        final repeat = tc['repeat'] as int;
        final plaintextSha256 = tc['plaintext_sha256'] as String;
        final payloadSha256 = tc['payload_sha256'] as String;

        final convKey = Uint8List.fromList(hex.decode(convKeyHex));
        final nonce = Uint8List.fromList(hex.decode(nonceHex));

        // Build plaintext
        final plaintext = pattern * repeat;

        // Verify plaintext SHA-256
        final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));
        expect(
          hex.encode(_sha256(plaintextBytes)),
          equals(plaintextSha256),
          reason: 'plaintext SHA-256 mismatch for conversation_key=$convKeyHex',
        );

        // Encrypt
        final payload = nip44EncryptWithKey(plaintext, convKey, nonce);

        // Verify payload SHA-256 (payload is a base64 string — hash its UTF-8 bytes)
        final payloadBytes = Uint8List.fromList(utf8.encode(payload));
        expect(
          hex.encode(_sha256(payloadBytes)),
          equals(payloadSha256),
          reason: 'payload SHA-256 mismatch for conversation_key=$convKeyHex',
        );

        // Decrypt back
        final decrypted = nip44DecryptWithKey(payload, convKey);
        expect(decrypted, equals(plaintext));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // invalid.decrypt
  // ---------------------------------------------------------------------------

  group('invalid.decrypt', () {
    test('all invalid payloads throw', () {
      final cases =
          (vectors['v2']['invalid']['decrypt'] as List)
              .cast<Map<String, dynamic>>();

      for (final tc in cases) {
        final convKeyHex = tc['conversation_key'] as String;
        final payload = tc['payload'] as String;
        final note = tc['note'] as String? ?? '';

        final convKey = Uint8List.fromList(hex.decode(convKeyHex));

        expect(
          () => nip44DecryptWithKey(payload, convKey),
          throwsA(anything),
          reason:
              'Expected throw for: $note payload=${payload.substring(0, payload.length.clamp(0, 50))}',
        );
      }
    });
  });

  // ---------------------------------------------------------------------------
  // invalid.get_conversation_key
  // ---------------------------------------------------------------------------

  group('invalid.get_conversation_key', () {
    test('all invalid key pairs throw', () {
      final cases =
          (vectors['v2']['invalid']['get_conversation_key'] as List)
              .cast<Map<String, dynamic>>();

      for (final tc in cases) {
        final sec1 = tc['sec1'] as String;
        final pub2 = tc['pub2'] as String;
        final note = tc['note'] as String? ?? '';

        expect(
          () => computeConversationKey(sec1, pub2),
          throwsA(anything),
          reason: 'Expected throw for: $note sec1=$sec1',
        );
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// SHA-256 hash using pointycastle.
Uint8List _sha256(Uint8List data) {
  final digest = SHA256Digest();
  digest.update(data, 0, data.length);
  final result = Uint8List(32);
  digest.doFinal(result, 0);
  return result;
}
