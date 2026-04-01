// Tests for NIP-59 Gift Wrap (wrap/unwrap round-trips, ephemeral keys,
// signature validation, and JSON serialization).

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:test/test.dart';

import 'package:nostr_rpc/src/crypto/keys.dart';
import 'package:nostr_rpc/src/crypto/nip59.dart';

void main() {
  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Generates a fresh keypair and returns (privBytes, pubHex).
  (Uint8List, String) makeKeypair() {
    final priv = generatePrivateKey();
    final pub = hex.encode(derivePublicKey(priv));
    return (priv, pub);
  }

  // -------------------------------------------------------------------------
  // Test fixtures — two parties: Alice (sender) and Bob (recipient).
  // -------------------------------------------------------------------------

  late Uint8List alicePriv;
  late String alicePub;
  late Uint8List bobPriv;
  late String bobPub;

  setUp(() {
    (alicePriv, alicePub) = makeKeypair();
    (bobPriv, bobPub) = makeKeypair();
  });

  // =========================================================================
  // 1. wrap / unwrap round-trip
  // =========================================================================

  group('wrap/unwrap round-trip', () {
    test('content is preserved after wrapping and unwrapping', () async {
      const message = 'Hello, Bob! This is a secret message.';

      final giftWrap = await Nip59.wrap(
        content: message,
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.content, equals(message));
    });

    test('unicode content is preserved', () async {
      const message = '🔐 Encrypted: こんにちは, Héllo Wörld! 中文';

      final giftWrap = await Nip59.wrap(
        content: message,
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.content, equals(message));
    });

    test('long content (1000 chars) is preserved', () async {
      final message = 'A' * 1000;

      final giftWrap = await Nip59.wrap(
        content: message,
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.content, equals(message));
    });
  });

  // =========================================================================
  // 2. Ephemeral key check
  // =========================================================================

  group('ephemeral key privacy', () {
    test('giftWrap.pubkey differs from sender pubkey', () async {
      final giftWrap = await Nip59.wrap(
        content: 'test',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(
        giftWrap.pubkey,
        isNot(equals(alicePub)),
        reason: 'Gift wrap pubkey must be ephemeral, not the sender pubkey',
      );
    });

    test('giftWrap.pubkey differs from recipient pubkey', () async {
      final giftWrap = await Nip59.wrap(
        content: 'test',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(
        giftWrap.pubkey,
        isNot(equals(bobPub)),
        reason: 'Gift wrap pubkey must not leak recipient identity either',
      );
    });

    test(
      'two wraps of same message produce different ephemeral keys',
      () async {
        const message = 'same message';

        final wrap1 = await Nip59.wrap(
          content: message,
          senderPrivkeyBytes: alicePriv,
          senderPubkeyHex: alicePub,
          recipientPubkeyHex: bobPub,
        );

        final wrap2 = await Nip59.wrap(
          content: message,
          senderPrivkeyBytes: alicePriv,
          senderPubkeyHex: alicePub,
          recipientPubkeyHex: bobPub,
        );

        expect(
          wrap1.pubkey,
          isNot(equals(wrap2.pubkey)),
          reason: 'Each wrap must use a fresh ephemeral key',
        );
      },
    );
  });

  // =========================================================================
  // 3. Wrong key failure
  // =========================================================================

  group('wrong key fails', () {
    test('unwrap with wrong recipient key throws', () async {
      final (wrongPriv, _) = makeKeypair();

      final giftWrap = await Nip59.wrap(
        content: 'secret',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(
        () =>
            Nip59.unwrap(giftWrap: giftWrap, recipientPrivkeyBytes: wrongPriv),
        throwsA(isA<FormatException>()),
        reason: 'Decrypting with the wrong key must fail',
      );
    });
  });

  // =========================================================================
  // 4. Sender identity preservation
  // =========================================================================

  group('sender identity', () {
    test('unwrapped.senderPubkey equals original sender pubkey', () async {
      final giftWrap = await Nip59.wrap(
        content: 'from Alice',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.senderPubkey, equals(alicePub));
    });
  });

  // =========================================================================
  // 5. p-tag set correctly
  // =========================================================================

  group('p-tag', () {
    test('giftWrap.tags contains [p, recipientPubkey]', () async {
      final giftWrap = await Nip59.wrap(
        content: 'tagged',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(
        giftWrap.tags,
        contains(containsAllInOrder(['p', bobPub])),
        reason: 'GiftWrap must have a p-tag pointing to the recipient',
      );
    });

    test('giftWrap.recipientPubkey returns recipient pubkey', () async {
      final giftWrap = await Nip59.wrap(
        content: 'tagged',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(giftWrap.recipientPubkey, equals(bobPub));
    });
  });

  // =========================================================================
  // 6. Seal validity
  // =========================================================================

  group('seal validity', () {
    test('seal.validate() does not throw after successful wrap', () async {
      final giftWrap = await Nip59.wrap(
        content: 'verified seal',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      // validate() should not throw (called inside fromJsonString, but we
      // call it explicitly to confirm the object is self-consistent).
      expect(() => unwrapped.seal.validate(), returnsNormally);
    });

    test('seal has kind 13', () async {
      final giftWrap = await Nip59.wrap(
        content: 'kind check',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.seal.kind, equals(13));
    });

    test('seal has empty tags', () async {
      final giftWrap = await Nip59.wrap(
        content: 'empty tags',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.seal.tags, isEmpty);
    });
  });

  // =========================================================================
  // 7. Rumor is unsigned
  // =========================================================================

  group('rumor unsigned', () {
    test('rumor JSON does not contain a sig field', () async {
      final giftWrap = await Nip59.wrap(
        content: 'no signature',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      final rumorJson = unwrapped.rumor.toJson();
      expect(
        rumorJson.containsKey('sig'),
        isFalse,
        reason: 'Rumors must not have a sig field',
      );
    });

    test('RumorEvent.fromJson rejects events with sig', () {
      final jsonWithSig = <String, dynamic>{
        'id': 'a' * 64,
        'pubkey': 'b' * 64,
        'created_at': 1000000,
        'kind': 14,
        'tags': <List<String>>[],
        'content': 'hello',
        'sig': 'c' * 128,
      };

      expect(
        () => RumorEvent.fromJson(jsonWithSig),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // =========================================================================
  // 8. fromJson round-trip
  // =========================================================================

  group('fromJson round-trip', () {
    test(
      'GiftWrapEvent.fromJson(giftWrap.toJson()) produces equal event',
      () async {
        final original = await Nip59.wrap(
          content: 'round-trip test',
          senderPrivkeyBytes: alicePriv,
          senderPubkeyHex: alicePub,
          recipientPubkeyHex: bobPub,
        );

        final restored = GiftWrapEvent.fromJson(original.toJson());

        expect(restored.id, equals(original.id));
        expect(restored.pubkey, equals(original.pubkey));
        expect(restored.createdAt, equals(original.createdAt));
        expect(restored.kind, equals(original.kind));
        expect(restored.tags, equals(original.tags));
        expect(restored.content, equals(original.content));
        expect(restored.sig, equals(original.sig));
      },
    );

    test('GiftWrapEvent.fromJsonString round-trip', () async {
      final original = await Nip59.wrap(
        content: 'json string round-trip',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final jsonStr = original.toJsonString();
      final restored = GiftWrapEvent.fromJsonString(jsonStr);

      expect(restored.id, equals(original.id));
      expect(restored.sig, equals(original.sig));
    });

    test('can unwrap a gift wrap that went through JSON round-trip', () async {
      const message = 'JSON round-trip then unwrap';

      final original = await Nip59.wrap(
        content: message,
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      // Simulate relay transmission via JSON.
      final transmitted = GiftWrapEvent.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: transmitted,
        recipientPrivkeyBytes: bobPriv,
      );

      expect(unwrapped.content, equals(message));
      expect(unwrapped.senderPubkey, equals(alicePub));
    });

    test('SealEvent.fromJson round-trip preserves all fields', () async {
      final giftWrap = await Nip59.wrap(
        content: 'seal round-trip',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      final seal = unwrapped.seal;
      final restoredSeal = SealEvent.fromJson(seal.toJson());

      expect(restoredSeal.id, equals(seal.id));
      expect(restoredSeal.pubkey, equals(seal.pubkey));
      expect(restoredSeal.createdAt, equals(seal.createdAt));
      expect(restoredSeal.sig, equals(seal.sig));
      expect(restoredSeal.kind, equals(13));
    });

    test('RumorEvent.fromJson round-trip preserves all fields', () async {
      final giftWrap = await Nip59.wrap(
        content: 'rumor round-trip',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      final rumor = unwrapped.rumor;
      final restoredRumor = RumorEvent.fromJson(rumor.toJson());

      expect(restoredRumor.id, equals(rumor.id));
      expect(restoredRumor.pubkey, equals(rumor.pubkey));
      expect(restoredRumor.createdAt, equals(rumor.createdAt));
      expect(restoredRumor.content, equals(rumor.content));
    });
  });

  // =========================================================================
  // 9. Additional structural checks
  // =========================================================================

  group('structural checks', () {
    test('giftWrap has kind 1059', () async {
      final giftWrap = await Nip59.wrap(
        content: 'kind',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(giftWrap.kind, equals(1059));
    });

    test('giftWrap.validate() does not throw on valid wrap', () async {
      final giftWrap = await Nip59.wrap(
        content: 'valid',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      expect(() => giftWrap.validate(), returnsNormally);
    });

    test('unwrapped.timestamp is a recent unix seconds value', () async {
      final before = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final giftWrap = await Nip59.wrap(
        content: 'timestamp',
        senderPrivkeyBytes: alicePriv,
        senderPubkeyHex: alicePub,
        recipientPubkeyHex: bobPub,
      );

      final after = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      final unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: bobPriv,
      );

      // The seal timestamp uses randomTimestamp() which subtracts up to 2 days.
      const twoDaysSeconds = 2 * 24 * 60 * 60;
      expect(
        unwrapped.timestamp,
        greaterThanOrEqualTo(before - twoDaysSeconds),
      );
      expect(unwrapped.timestamp, lessThanOrEqualTo(after));
    });

    test('Nip59.randomTimestamp returns value within past 2 days', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      const twoDays = 2 * 24 * 60 * 60;

      // Run multiple times to reduce flakiness.
      for (var i = 0; i < 10; i++) {
        final ts = Nip59.randomTimestamp();
        expect(ts, greaterThanOrEqualTo(now - twoDays - 1));
        expect(ts, lessThanOrEqualTo(now));
      }
    });

    test('constants are correct', () {
      expect(Nip59.sealKind, equals(13));
      expect(Nip59.giftWrapKind, equals(1059));
    });
  });
}
