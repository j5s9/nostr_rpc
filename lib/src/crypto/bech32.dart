// NIP-19 Bech32 encoding/decoding for npub and nsec.
// Implements standard Bech32 (BIP-173) from scratch — no external bech32 package.
// NIP-19 uses original Bech32 (polymod constant 1), NOT Bech32m.
//
// Spec references:
//   https://github.com/nostr-protocol/nips/blob/master/19.md
//   https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki

import 'dart:typed_data';
import 'package:convert/convert.dart';

// ---------------------------------------------------------------------------
// Internal Bech32 constants & helpers
// ---------------------------------------------------------------------------

const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

// Reverse lookup: char → 5-bit value (-1 = invalid)
final _charsetRev =
    (() {
      final map = List<int>.filled(128, -1);
      for (var i = 0; i < _charset.length; i++) {
        map[_charset.codeUnitAt(i)] = i;
      }
      return map;
    })();

/// BIP-173 polymod — returns the Bech32 checksum value.
int _polymod(List<int> values) {
  const generator = [
    0x3b6a57b2,
    0x26508e6d,
    0x1ea119fa,
    0x3d4233dd,
    0x2a1462b3,
  ];
  var chk = 1;
  for (final v in values) {
    final top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (var i = 0; i < 5; i++) {
      if ((top >> i) & 1 == 1) chk ^= generator[i];
    }
  }
  return chk;
}

/// Expand HRP for checksum computation.
List<int> _hrpExpand(String hrp) {
  final result = <int>[];
  for (final c in hrp.codeUnits) {
    result.add(c >> 5);
  }
  result.add(0);
  for (final c in hrp.codeUnits) {
    result.add(c & 31);
  }
  return result;
}

/// Verify Bech32 checksum (original Bech32, polymod constant = 1).
bool _verifyChecksum(String hrp, List<int> data) {
  return _polymod([..._hrpExpand(hrp), ...data]) == 1;
}

/// Create Bech32 checksum (6 5-bit values).
List<int> _createChecksum(String hrp, List<int> data) {
  final values = [..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
  final polymod = _polymod(values) ^ 1;
  return List<int>.generate(6, (i) => (polymod >> (5 * (5 - i))) & 31);
}

/// Convert between bit groups.
/// [from] bits per input value, [to] bits per output value.
/// [pad] true for encoding (8→5), false for decoding (5→8).
List<int>? _convertBits(List<int> data, int from, int to, {bool pad = true}) {
  var acc = 0;
  var bits = 0;
  final result = <int>[];
  final maxv = (1 << to) - 1;
  for (final value in data) {
    if (value < 0 || value >> from != 0) return null;
    acc = (acc << from) | value;
    bits += from;
    while (bits >= to) {
      bits -= to;
      result.add((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits > 0) {
      result.add((acc << (to - bits)) & maxv);
    }
  } else {
    if (bits >= from || ((acc << (to - bits)) & maxv) != 0) return null;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Low-level encode/decode
// ---------------------------------------------------------------------------

/// Encode bytes to Bech32 string with given HRP.
String _bech32Encode(String hrp, List<int> data) {
  final data5 = _convertBits(data, 8, 5, pad: true);
  if (data5 == null) {
    throw const FormatException('Bech32 encode: bit conversion failed');
  }
  final checksum = _createChecksum(hrp, data5);
  final combined = [...data5, ...checksum];
  final sb = StringBuffer('$hrp${String.fromCharCode(0x31)}'); // '1' separator
  for (final d in combined) {
    sb.writeCharCode(_charset.codeUnitAt(d));
  }
  return sb.toString();
}

/// Decode Bech32 string, returns (hrp, data-bytes).
(String hrp, Uint8List data) _bech32Decode(String bech) {
  final lower = bech.toLowerCase();

  // Must be all lowercase after normalisation
  if (bech != lower && bech != bech.toUpperCase()) {
    throw const FormatException('Bech32 decode: mixed case');
  }

  final pos = lower.lastIndexOf('1');
  if (pos < 1) {
    throw const FormatException('Bech32 decode: missing separator');
  }
  if (lower.length - pos - 1 < 6) {
    throw const FormatException('Bech32 decode: checksum too short');
  }

  final hrp = lower.substring(0, pos);
  final data5 = <int>[];
  for (var i = pos + 1; i < lower.length; i++) {
    final c = lower.codeUnitAt(i);
    if (c >= 128) throw const FormatException('Bech32 decode: non-ASCII char');
    final d = _charsetRev[c];
    if (d == -1) {
      throw const FormatException('Bech32 decode: invalid character');
    }
    data5.add(d);
  }

  if (!_verifyChecksum(hrp, data5)) {
    throw const FormatException('Bech32 decode: invalid checksum');
  }

  // Strip 6-char checksum, convert 5→8 bits
  final payloadBits = data5.sublist(0, data5.length - 6);
  final bytes = _convertBits(payloadBits, 5, 8, pad: false);
  if (bytes == null) {
    throw const FormatException('Bech32 decode: bit conversion failed');
  }

  return (hrp, Uint8List.fromList(bytes));
}

// ---------------------------------------------------------------------------
// NIP-19 public API
// ---------------------------------------------------------------------------

/// Returns true if [input] looks like a 64-char lowercase hex key.
bool isHexKey(String input) {
  final s = input.trim();
  return s.length == 64 && RegExp(r'^[0-9a-f]+$').hasMatch(s);
}

/// Encode a 32-byte hex public key to npub1... format.
String encodeNpub(String hexPubkey) {
  final bytes = _hexToBytes(hexPubkey, 'npub');
  return _bech32Encode('npub', bytes);
}

/// Decode an npub1... string to 32-byte hex.
String decodeNpub(String npub) {
  final s = npub.trim().toLowerCase();
  if (!s.startsWith('npub1')) {
    throw const FormatException('Expected npub1... prefix');
  }
  final (hrp, data) = _bech32Decode(s);
  if (hrp != 'npub') {
    throw FormatException('Expected HRP "npub", got "$hrp"');
  }
  if (data.length != 32) {
    throw FormatException('Expected 32 bytes, got ${data.length}');
  }
  return hex.encode(data);
}

/// Encode a 32-byte hex private key to nsec1... format.
String encodeNsec(String hexPrivkey) {
  final bytes = _hexToBytes(hexPrivkey, 'nsec');
  return _bech32Encode('nsec', bytes);
}

/// Decode an nsec1... string to 32-byte hex.
String decodeNsec(String nsec) {
  final s = nsec.trim().toLowerCase();
  if (!s.startsWith('nsec1')) {
    throw const FormatException('Expected nsec1... prefix');
  }
  final (hrp, data) = _bech32Decode(s);
  if (hrp != 'nsec') {
    throw FormatException('Expected HRP "nsec", got "$hrp"');
  }
  if (data.length != 32) {
    throw FormatException('Expected 32 bytes, got ${data.length}');
  }
  return hex.encode(data);
}

/// Accepts either a 64-char hex OR an npub/nsec string, returns 64-char hex.
/// Throws [FormatException] if neither.
String normalizeToHex(String input) {
  final s = input.trim();
  if (isHexKey(s)) return s.toLowerCase();
  final lower = s.toLowerCase();
  if (lower.startsWith('npub1')) return decodeNpub(s);
  if (lower.startsWith('nsec1')) return decodeNsec(s);
  throw FormatException(
    'normalizeToHex: expected 64-char hex, npub1..., or nsec1..., got: $input',
  );
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

List<int> _hexToBytes(String hexStr, String context) {
  final s = hexStr.trim().toLowerCase();
  if (!isHexKey(s)) {
    throw FormatException(
      'Invalid $context hex key: expected 64 hex chars, got "${hexStr.length}" chars',
    );
  }
  return hex.decode(s);
}
