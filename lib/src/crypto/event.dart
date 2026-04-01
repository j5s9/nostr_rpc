// NIP-01 Nostr Event model with canonical ID computation and BIP-340 signing.
//
// Reference: https://github.com/nostr-protocol/nips/blob/master/01.md
// Reference: https://github.com/bitcoin/bips/blob/master/bip-0340/bip-0340.mediawiki

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:pointycastle/export.dart';

import 'keys.dart';
import 'schnorr.dart';

/// A Nostr event per NIP-01.
///
/// The [id] is the SHA-256 hash of the canonical serialization of the event
/// fields (minus the signature). The [sig] is the BIP-340 Schnorr signature
/// over the id.
class NostrEvent {
  final String id; // hex, 64 chars (32 bytes)
  final String pubkey; // hex, 64 chars (32 bytes x-only pubkey)
  final int createdAt; // unix timestamp in seconds
  final int kind; // event kind number
  final List<List<String>> tags; // array of string arrays
  final String content; // arbitrary string
  final String sig; // hex, 128 chars (64-byte BIP-340 signature)

  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  /// Computes the canonical event ID per NIP-01.
  ///
  /// The ID is the SHA-256 hash of the UTF-8 encoded minimal JSON array:
  ///   [0, pubkey, created_at, kind, tags, content]
  static String computeId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    // Build the canonical array exactly as NIP-01 specifies.
    final canonical = json.encode([
      0,
      pubkey.toLowerCase(),
      createdAt,
      kind,
      tags,
      content,
    ]);

    // SHA-256 the UTF-8 bytes of the canonical JSON.
    final inputBytes = utf8.encode(canonical);
    final digest = SHA256Digest();
    digest.update(Uint8List.fromList(inputBytes), 0, inputBytes.length);
    final hashBytes = Uint8List(32);
    digest.doFinal(hashBytes, 0);

    return hex.encode(hashBytes);
  }

  /// Creates a new event and signs it with [privateKey].
  ///
  /// [pubkeyHex] must be the x-only public key (64 hex chars, 32 bytes) that
  /// corresponds to [privateKey].
  /// [createdAt] defaults to current Unix timestamp when not provided.
  static NostrEvent sign({
    required String pubkeyHex,
    required Uint8List privateKey,
    required int kind,
    required List<List<String>> tags,
    required String content,
    int? createdAt,
    Uint8List? auxRand,
  }) {
    if (!isValidPrivateKey(privateKey)) {
      throw ArgumentError('privateKey is not a valid secp256k1 private key');
    }

    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final normalizedPubkey = pubkeyHex.toLowerCase();

    final id = computeId(
      pubkey: normalizedPubkey,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
    );

    // Sign the event ID (32-byte hash) with BIP-340 Schnorr.
    final idBytes = Uint8List.fromList(hex.decode(id));
    final sigBytes = schnorrSign(privateKey, idBytes, auxRand: auxRand);

    return NostrEvent(
      id: id,
      pubkey: normalizedPubkey,
      createdAt: ts,
      kind: kind,
      tags: _freezeTags(tags),
      content: content,
      sig: hex.encode(sigBytes),
    );
  }

  /// Returns true if the event's BIP-340 Schnorr signature is valid.
  ///
  /// Verifies that:
  ///   1. The stored [id] matches the computed canonical ID.
  ///   2. The [sig] is a valid BIP-340 Schnorr signature over [id] by [pubkey].
  bool verify() {
    // Recompute the canonical ID and compare.
    final expectedId = computeId(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    if (id != expectedId) return false;

    // Verify the BIP-340 Schnorr signature.
    try {
      final pubkeyBytes = Uint8List.fromList(hex.decode(pubkey));
      final idBytes = Uint8List.fromList(hex.decode(id));
      final sigBytes = Uint8List.fromList(hex.decode(sig));
      return schnorrVerify(pubkeyBytes, idBytes, sigBytes);
    } catch (_) {
      return false;
    }
  }

  /// Serializes the event to the Nostr wire format JSON map.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'pubkey': pubkey,
      'created_at': createdAt,
      'kind': kind,
      'tags': tags,
      'content': content,
      'sig': sig,
    };
  }

  /// Deserializes an event from the Nostr wire format JSON map.
  factory NostrEvent.fromJson(Map<String, dynamic> json) {
    final rawTags = json['tags'];
    if (rawTags is! List) {
      throw const FormatException('Missing or invalid `tags`: expected list.');
    }
    final parsedTags = rawTags
        .map<List<String>>((tag) {
          if (tag is! List) {
            throw const FormatException('Invalid tag: expected nested list.');
          }
          return List<String>.unmodifiable(tag.map((e) => e.toString()));
        })
        .toList(growable: false);

    return NostrEvent(
      id: _requireString(json, 'id'),
      pubkey: _requireString(json, 'pubkey'),
      createdAt: _requireInt(json, 'created_at'),
      kind: _requireInt(json, 'kind'),
      tags: parsedTags,
      content: _requireString(json, 'content'),
      sig: _requireString(json, 'sig'),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<List<String>> _freezeTags(List<List<String>> tags) {
  return List<List<String>>.unmodifiable(
    tags.map((tag) => List<String>.unmodifiable(tag)),
  );
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) {
    throw FormatException('Missing or invalid `$key`: expected string.');
  }
  return value;
}

int _requireInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('Missing or invalid `$key`: expected integer.');
}
