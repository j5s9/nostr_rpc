// Tests for NIP-19 Bech32 npub/nsec encode/decode.
//
// Known vectors sourced from:
//   - NIP-19 spec examples: https://github.com/nostr-protocol/nips/blob/master/19.md
//   - Real Nostr clients (damus, snort, monstr) — cross-verified
//
// All known-vector pairs are from the official NIP-19 spec or confirmed by
// multiple independent implementations.

import 'package:test/test.dart';
import 'package:nostr_rpc/src/crypto/bech32.dart';

void main() {
  // -------------------------------------------------------------------------
  // Known test vectors (all from NIP-19 spec / verified cross-client)
  // -------------------------------------------------------------------------

  // Vector A (npub) — from NIP-19 README:
  //   https://github.com/nostr-protocol/nips/blob/master/19.md
  const hexA =
      '7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e';
  const npubA =
      'npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg';

  // Vector B (npub) — fiatjaf's pubkey, also from NIP-19 README:
  const hexB =
      '3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d';
  const npubB =
      'npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6';

  // Vector C (nsec) — from NIP-19 README:
  const hexC =
      '67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa';
  const nsecC =
      'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

  // Edge cases (round-trip only, no hardcoded expected value):
  const hexG =
      '79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798';
  const hexZero =
      '0000000000000000000000000000000000000000000000000000000000000000';
  const hexFf =
      'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

  // -------------------------------------------------------------------------
  // group: encodeNpub / decodeNpub
  // -------------------------------------------------------------------------
  group('Bech32 npub', () {
    test('encodeNpub known vector A', () {
      expect(encodeNpub(hexA), equals(npubA));
    });

    test('decodeNpub known vector A', () {
      expect(decodeNpub(npubA), equals(hexA));
    });

    test('encodeNpub known vector B (fiatjaf)', () {
      expect(encodeNpub(hexB), equals(npubB));
    });

    test('decodeNpub known vector B (fiatjaf)', () {
      expect(decodeNpub(npubB), equals(hexB));
    });

    test('encodeNpub round-trip: G.x key', () {
      final npub = encodeNpub(hexG);
      expect(npub, startsWith('npub1'));
      expect(decodeNpub(npub), equals(hexG));
    });

    test('round-trip: all-zero key', () {
      final npub = encodeNpub(hexZero);
      expect(npub, startsWith('npub1'));
      expect(decodeNpub(npub), equals(hexZero));
    });

    test('round-trip: all-0xff key', () {
      final npub = encodeNpub(hexFf);
      expect(decodeNpub(npub), equals(hexFf));
    });

    test('encodeNpub is lowercase', () {
      final npub = encodeNpub(hexA);
      expect(npub, equals(npub.toLowerCase()));
    });

    test('decodeNpub rejects wrong prefix (nsec)', () {
      final nsec = encodeNsec(hexA);
      expect(() => decodeNpub(nsec), throwsFormatException);
    });

    test('decodeNpub rejects garbage', () {
      expect(() => decodeNpub('npub1invalid!!!!'), throwsFormatException);
    });

    test('encodeNpub rejects non-hex input', () {
      expect(() => encodeNpub('zzzz'), throwsFormatException);
    });

    test('encodeNpub rejects too-short hex', () {
      expect(() => encodeNpub('79be667e'), throwsFormatException);
    });
  });

  // -------------------------------------------------------------------------
  // group: encodeNsec / decodeNsec
  // -------------------------------------------------------------------------
  group('Bech32 nsec', () {
    test('encodeNsec known vector C', () {
      expect(encodeNsec(hexC), equals(nsecC));
    });

    test('decodeNsec known vector C', () {
      expect(decodeNsec(nsecC), equals(hexC));
    });

    test('encodeNsec round-trip: G.x', () {
      final nsec = encodeNsec(hexG);
      expect(nsec, startsWith('nsec1'));
      expect(decodeNsec(nsec), equals(hexG));
    });

    test('round-trip: all-zero key as nsec', () {
      final nsec = encodeNsec(hexZero);
      expect(nsec, startsWith('nsec1'));
      expect(decodeNsec(nsec), equals(hexZero));
    });

    test('nsec and npub produce different strings for same hex', () {
      expect(encodeNpub(hexA), isNot(equals(encodeNsec(hexA))));
    });

    test('decodeNsec rejects npub', () {
      final npub = encodeNpub(hexA);
      expect(() => decodeNsec(npub), throwsFormatException);
    });

    test('encodeNsec rejects non-hex input', () {
      expect(() => encodeNsec('not-hex'), throwsFormatException);
    });
  });

  // -------------------------------------------------------------------------
  // group: isHexKey
  // -------------------------------------------------------------------------
  group('isHexKey', () {
    test('accepts 64-char lowercase hex', () {
      expect(isHexKey(hexA), isTrue);
      expect(isHexKey(hexZero), isTrue);
      expect(isHexKey(hexFf), isTrue);
      expect(isHexKey(hexG), isTrue);
    });

    test('accepts hex with leading/trailing whitespace', () {
      expect(isHexKey('  $hexA  '), isTrue);
    });

    test('rejects uppercase hex', () {
      expect(isHexKey(hexA.toUpperCase()), isFalse);
    });

    test('rejects too-short hex', () {
      expect(isHexKey('79be667e'), isFalse);
    });

    test('rejects npub string', () {
      expect(isHexKey(npubA), isFalse);
    });

    test('rejects empty string', () {
      expect(isHexKey(''), isFalse);
    });

    test('rejects non-hex characters', () {
      expect(
        isHexKey(
          'gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg',
        ),
        isFalse,
      );
    });
  });

  // -------------------------------------------------------------------------
  // group: normalizeToHex
  // -------------------------------------------------------------------------
  group('normalizeToHex', () {
    test('accepts 64-char lowercase hex unchanged', () {
      expect(normalizeToHex(hexA), equals(hexA));
    });

    test('accepts another lowercase hex unchanged', () {
      expect(normalizeToHex(hexC), equals(hexC));
    });

    test('accepts npub and returns hex (vector A)', () {
      expect(normalizeToHex(npubA), equals(hexA));
    });

    test('accepts npub and returns hex (vector B)', () {
      expect(normalizeToHex(npubB), equals(hexB));
    });

    test('accepts nsec and returns hex (vector C)', () {
      expect(normalizeToHex(nsecC), equals(hexC));
    });

    test('accepts npub with surrounding whitespace', () {
      expect(normalizeToHex('  $npubA  '), equals(hexA));
    });

    test('rejects invalid input', () {
      expect(() => normalizeToHex('notvalid'), throwsFormatException);
    });

    test('rejects empty string', () {
      expect(() => normalizeToHex(''), throwsFormatException);
    });

    test('rejects partial npub with bad checksum', () {
      expect(() => normalizeToHex('npub1invalid!!!!'), throwsFormatException);
    });
  });

  // -------------------------------------------------------------------------
  // group: checksum integrity
  // -------------------------------------------------------------------------
  group('Checksum / corruption detection', () {
    test('detects single char flip in npub', () {
      final npub = encodeNpub(hexA);
      // Flip one data character (not the separator or prefix)
      final corrupted = '${npub.substring(0, 10)}x${npub.substring(11)}';
      expect(() => decodeNpub(corrupted), throwsFormatException);
    });

    test('correct checksum passes round-trip verification', () {
      expect(() => decodeNpub(npubA), returnsNormally);
    });

    test('correct nsec checksum passes', () {
      expect(() => decodeNsec(nsecC), returnsNormally);
    });
  });
}
