import 'package:test/test.dart';

import 'package:nostr_rpc/src/identity.dart';

void main() {
  group('NostrIdentity.generate()', () {
    test('produces a 64-char lowercase hex privkey', () {
      final identity = NostrIdentity.generate();
      expect(identity.privkeyHex, hasLength(64));
      expect(identity.privkeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('produces a 64-char lowercase hex pubkey', () {
      final identity = NostrIdentity.generate();
      expect(identity.pubkeyHex, hasLength(64));
      expect(identity.pubkeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('privkey and pubkey are different', () {
      final identity = NostrIdentity.generate();
      expect(identity.privkeyHex, isNot(equals(identity.pubkeyHex)));
    });

    test('npub starts with "npub1"', () {
      final identity = NostrIdentity.generate();
      expect(identity.npub, startsWith('npub1'));
    });

    test('nsec starts with "nsec1"', () {
      final identity = NostrIdentity.generate();
      expect(identity.nsec, startsWith('nsec1'));
    });

    test('two generated identities have different keys', () {
      final a = NostrIdentity.generate();
      final b = NostrIdentity.generate();
      expect(a.privkeyHex, isNot(equals(b.privkeyHex)));
      expect(a.pubkeyHex, isNot(equals(b.pubkeyHex)));
    });
  });

  group('NostrIdentity.fromPrivateKey()', () {
    test('derives the correct pubkey from a known private key', () {
      // Generate a fresh identity, then reconstruct from its privkey hex.
      final original = NostrIdentity.generate();
      final reconstructed = NostrIdentity.fromPrivateKey(original.privkeyHex);

      expect(reconstructed.privkeyHex, equals(original.privkeyHex));
      expect(reconstructed.pubkeyHex, equals(original.pubkeyHex));
      expect(reconstructed.npub, equals(original.npub));
      expect(reconstructed.nsec, equals(original.nsec));
    });

    test('npub round-trips through fromPrivateKey', () {
      final original = NostrIdentity.generate();
      final reconstructed = NostrIdentity.fromPrivateKey(original.privkeyHex);
      expect(reconstructed.npub, startsWith('npub1'));
      expect(reconstructed.npub, equals(original.npub));
    });

    test('nsec round-trips through fromPrivateKey', () {
      final original = NostrIdentity.generate();
      final reconstructed = NostrIdentity.fromPrivateKey(original.privkeyHex);
      expect(reconstructed.nsec, startsWith('nsec1'));
      expect(reconstructed.nsec, equals(original.nsec));
    });

    test('privkeyBytes has 32 bytes', () {
      final identity = NostrIdentity.generate();
      expect(identity.privkeyBytes, hasLength(32));
    });
  });
}
