// BIP-340 test vectors from:
// https://raw.githubusercontent.com/bitcoin/bips/master/bip-0340/test-vectors.csv
//
// Format: index, secret key, public key, aux_rand, message, signature,
//         verification result, comment
//
// Vectors 0-4 have secret keys → test signing + verification.
// Vectors 5-14 are verify-only.

import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/crypto/schnorr.dart';
import 'package:nostr_rpc/src/crypto/keys.dart';

void main() {
  // ---------------------------------------------------------------------------
  // BIP-340 Signing vectors (vectors 0-4 from official CSV)
  // ---------------------------------------------------------------------------
  group('BIP-340 Schnorr signing test vectors', () {
    // index 0
    test('vector 0: sign and verify', () {
      final seckey = _h(
        '0000000000000000000000000000000000000000000000000000000000000003',
      );
      final expectedPubkey = _h(
        'F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9',
      );
      final auxRand = _h(
        '0000000000000000000000000000000000000000000000000000000000000000',
      );
      final msg = _h(
        '0000000000000000000000000000000000000000000000000000000000000000',
      );
      final expectedSig = _h(
        'E907831F80848D1069A5371B402410364BDF1C5F8307B0084C55F1CE2DCA8215'
        '25F66A4A85EA8B71E482A74F382D2CE5EBEEE8FDB2172F477DF4900D310536C0',
      );

      final pubkey = derivePublicKey(seckey);
      expect(_hexEncode(pubkey), equals(_hexEncode(expectedPubkey)));

      final sig = schnorrSign(seckey, msg, auxRand: auxRand);
      expect(_hexEncode(sig), equals(_hexEncode(expectedSig)));

      expect(schnorrVerify(pubkey, msg, sig), isTrue);
    });

    // index 1
    test('vector 1: sign and verify', () {
      final seckey = _h(
        'B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF',
      );
      final expectedPubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final auxRand = _h(
        '0000000000000000000000000000000000000000000000000000000000000001',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final expectedSig = _h(
        '6896BD60EEAE296DB48A229FF71DFE071BDE413E6D43F917DC8DCF8C78DE334'
        '18906D11AC976ABCCB20B091292BFF4EA897EFCB639EA871CFA95F6DE339E4B0A',
      );

      final pubkey = derivePublicKey(seckey);
      expect(_hexEncode(pubkey), equals(_hexEncode(expectedPubkey)));

      final sig = schnorrSign(seckey, msg, auxRand: auxRand);
      expect(_hexEncode(sig), equals(_hexEncode(expectedSig)));

      expect(schnorrVerify(pubkey, msg, sig), isTrue);
    });

    // index 2
    test('vector 2: sign and verify', () {
      final seckey = _h(
        'C90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B14E5C9',
      );
      final expectedPubkey = _h(
        'DD308AFEC5777E13121FA72B9CC1B7CC0139715309B086C960E18FD969774EB8',
      );
      final auxRand = _h(
        'C87AA53824B4D7AE2EB035A2B5BBBCCC080E76CDC6D1692C4B0B62D798E6D906',
      );
      final msg = _h(
        '7E2D58D8B3BCDF1ABADEC7829054F90DDA9805AAB56C77333024B9D0A508B75C',
      );
      final expectedSig = _h(
        '5831AAEED7B44BB74E5EAB94BA9D4294C49BCF2A60728D8B4C200F50DD313C1'
        'BAB745879A5AD954A72C45A91C3A51D3C7ADEA98D82F8481E0E1E03674A6F3FB7',
      );

      final pubkey = derivePublicKey(seckey);
      expect(_hexEncode(pubkey), equals(_hexEncode(expectedPubkey)));

      final sig = schnorrSign(seckey, msg, auxRand: auxRand);
      expect(_hexEncode(sig), equals(_hexEncode(expectedSig)));

      expect(schnorrVerify(pubkey, msg, sig), isTrue);
    });

    // index 3
    test('vector 3: sign and verify (all-FF aux and msg)', () {
      final seckey = _h(
        '0B432B2677937381AEF05BB02A66ECD012773062CF3FA2549E44F58ED2401710',
      );
      final expectedPubkey = _h(
        '25D1DFF95105F5253C4022F628A996AD3A0D95FBF21D468A1B33F8C160D8F517',
      );
      final auxRand = _h(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
      );
      final msg = _h(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
      );
      final expectedSig = _h(
        '7EB0509757E246F19449885651611CB965ECC1A187DD51B64FDA1EDC9637D5EC'
        '97582B9CB13DB3933705B32BA982AF5AF25FD78881EBB32771FC5922EFC66EA3',
      );

      final pubkey = derivePublicKey(seckey);
      expect(_hexEncode(pubkey), equals(_hexEncode(expectedPubkey)));

      final sig = schnorrSign(seckey, msg, auxRand: auxRand);
      expect(_hexEncode(sig), equals(_hexEncode(expectedSig)));

      expect(schnorrVerify(pubkey, msg, sig), isTrue);
    });

    // index 4 — no secret key, verify only
    test('vector 4: verify only (TRUE)', () {
      final pubkey = _h(
        'D69C3509BB99E412E68B0FE8544E72837DFA30746D8BE2AA65975F29D22DC7B9',
      );
      final msg = _h(
        '4DF3C3F68FCC83B27E9D42C90431A72499F17875C81A599B566C9889B9696703',
      );
      final sig = _h(
        '00000000000000000000003B78CE563F89A0ED9414F5AA28AD0D96D6795F9C63'
        '76AFB1548AF603B3EB45C9F8207DEE1060CB71C04E80F593060B07D28308D7F4',
      );
      expect(schnorrVerify(pubkey, msg, sig), isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // BIP-340 Verify-only vectors (vectors 5-14 from official CSV)
  // ---------------------------------------------------------------------------
  group('BIP-340 Schnorr verification test vectors', () {
    // index 5 — FALSE: public key not on the curve
    test('vector 5: FALSE — public key not on the curve', () {
      final pubkey = _h(
        'EEFDEA4CDB677750A420FEE807EACF21EB9898AE79B9768766E4FAA04A2D4A34',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '6CFF5C3BA86C69EA4B7376F31A9BCB4F74C1976089B2D9963DA2E5543E177769'
        '69E89B4C5564D00349106B8497785DD7D1D713A8AE82B32FA79D5F7FC407D39B',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 6 — FALSE: has_even_y(R) is false
    test('vector 6: FALSE — has_even_y(R) is false', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        'FFF97BD5755EEEA420453A14355235D382F6472F8568A18B2F057A1460297556'
        '3CC27944640AC607CD107AE10923D9EF7A73C643E166BE5EBEAFA34B1AC553E2',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 7 — FALSE: negated message
    test('vector 7: FALSE — negated message', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '1FA62E331EDBC21C394792D2AB1100A7B432B013DF3F6FF4F99FCB33E0E1515F'
        '28890B3EDB6E7189B630448B515CE4F8622A954CFE545735AAEA5134FCCDB2BD',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 8 — FALSE: negated s value
    test('vector 8: FALSE — negated s value', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '6CFF5C3BA86C69EA4B7376F31A9BCB4F74C1976089B2D9963DA2E5543E177769'
        '61764B3AA9B2FFCB6EF947B6887A226E8D7C93E00C5ED0C1834FF0D0C2E6DA6',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 9 — FALSE: sG - eP is infinite
    test('vector 9: FALSE — sG - eP is infinite', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '0000000000000000000000000000000000000000000000000000000000000000'
        '123DDA8328AF9C23A94C1FEECFD123BA4FB73476F0D594DCB65C6425BD186051',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 10 — FALSE: sG - eP is infinite (x=1)
    test('vector 10: FALSE — sG - eP is infinite (x=1)', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '0000000000000000000000000000000000000000000000000000000000000001'
        '7615FBAF5AE28864013C099742DEADB4DBA87F11AC6754F93780D5A1837CF197',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 11 — FALSE: sig[0:32] is not an X coordinate on the curve
    test('vector 11: FALSE — sig[0:32] is not on the curve', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '4A298DACAE57395A15D0795DDBFD1DCB564DA82B0F269BC70A74F8220429BA1D'
        '69E89B4C5564D00349106B8497785DD7D1D713A8AE82B32FA79D5F7FC407D39B',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 12 — FALSE: sig[0:32] is equal to field size
    test('vector 12: FALSE — sig[0:32] equals field size', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F'
        '69E89B4C5564D00349106B8497785DD7D1D713A8AE82B32FA79D5F7FC407D39B',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 13 — FALSE: sig[32:64] is equal to curve order
    test('vector 13: FALSE — sig[32:64] equals curve order', () {
      final pubkey = _h(
        'DFF1D77F2A671C5F36183726DB2341BE58FEAE1DA2DECED843240F7B502BA659',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '6CFF5C3BA86C69EA4B7376F31A9BCB4F74C1976089B2D9963DA2E5543E177769'
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });

    // index 14 — FALSE: public key exceeds field size
    test('vector 14: FALSE — public key exceeds field size', () {
      final pubkey = _h(
        'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC30',
      );
      final msg = _h(
        '243F6A8885A308D313198A2E03707344A4093822299F31D0082EFA98EC4E6C89',
      );
      final sig = _h(
        '6CFF5C3BA86C69EA4B7376F31A9BCB4F74C1976089B2D9963DA2E5543E177769'
        '69E89B4C5564D00349106B8497785DD7D1D713A8AE82B32FA79D5F7FC407D39B',
      );
      expect(schnorrVerify(pubkey, msg, sig), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // Round-trip tests using key generation
  // ---------------------------------------------------------------------------
  group('Schnorr round-trip with generated keys', () {
    test('sign then verify succeeds', () {
      final privkey = generatePrivateKey();
      final pubkey = derivePublicKey(privkey);
      final msg = Uint8List(32)..fillRange(0, 32, 0xAB);
      final sig = schnorrSign(privkey, msg);
      expect(schnorrVerify(pubkey, msg, sig), isTrue);
    });

    test('verify fails with wrong message', () {
      final privkey = generatePrivateKey();
      final pubkey = derivePublicKey(privkey);
      final msg = Uint8List(32)..fillRange(0, 32, 0xAB);
      final wrongMsg = Uint8List(32)..fillRange(0, 32, 0xCD);
      final sig = schnorrSign(privkey, msg);
      expect(schnorrVerify(pubkey, wrongMsg, sig), isFalse);
    });

    test('verify fails with wrong public key', () {
      final privkey = generatePrivateKey();
      final pubkey = derivePublicKey(privkey);
      final wrongPrivkey = generatePrivateKey();
      final wrongPubkey = derivePublicKey(wrongPrivkey);
      final msg = Uint8List(32)..fillRange(0, 32, 0x7F);
      final sig = schnorrSign(privkey, msg);
      // Correct pubkey passes
      expect(schnorrVerify(pubkey, msg, sig), isTrue);
      // Wrong pubkey fails
      expect(schnorrVerify(wrongPubkey, msg, sig), isFalse);
    });

    test('schnorrSign is deterministic given same auxRand', () {
      final privkey = generatePrivateKey();
      final msg = Uint8List(32);
      final auxRand = Uint8List(32)..fillRange(0, 32, 0x42);
      final sig1 = schnorrSign(privkey, msg, auxRand: auxRand);
      final sig2 = schnorrSign(privkey, msg, auxRand: auxRand);
      expect(sig1, equals(sig2));
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Decode a hex string (case-insensitive, optional spaces) to Uint8List.
Uint8List _h(String hex) {
  final h = hex.toLowerCase().replaceAll(' ', '');
  final result = Uint8List(h.length ~/ 2);
  for (var i = 0; i < result.length; i++) {
    result[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return result;
}

String _hexEncode(Uint8List bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    buf.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}
