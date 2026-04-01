// NIP-59 Gift Wrap implementation.
//
// Reference: https://github.com/nostr-protocol/nips/blob/master/59.md
//
// Provides three-layer encrypted event wrapping:
//   1. Rumor (kind=14)   — unsigned event with plaintext content
//   2. Seal  (kind=13)   — NIP-44 encrypted rumor, signed by sender
//   3. GiftWrap (kind=1059) — NIP-44 encrypted seal, signed by ephemeral key

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'event.dart';
import 'keys.dart';
import 'nip44.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const int _sealKind = 13;
const int _giftWrapKind = 1059;

// ---------------------------------------------------------------------------
// RumorEvent — unsigned NIP-59 inner event (kind 14, no sig)
// ---------------------------------------------------------------------------

/// An unsigned Nostr event (the "rumor") per NIP-59.
///
/// Rumors are NOT signed — the absence of a `sig` field is intentional.
/// The rumor is encrypted inside a [SealEvent] to preserve sender privacy.
final class RumorEvent {
  RumorEvent._({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required List<List<String>> tags,
    required this.content,
  }) : tags = _freezeTags(tags);

  /// Creates a new [RumorEvent] for [senderPubkeyHex].
  ///
  /// Computes the canonical NIP-01 ID but does NOT sign.
  factory RumorEvent.create({
    required int kind,
    required String content,
    required String senderPubkeyHex,
    List<List<String>> tags = const <List<String>>[],
    int? createdAt,
  }) {
    final normalizedPubkey = senderPubkeyHex.toLowerCase();
    final ts = createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final computedId = NostrEvent.computeId(
      pubkey: normalizedPubkey,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
    );

    return RumorEvent._(
      id: computedId,
      pubkey: normalizedPubkey,
      createdAt: ts,
      kind: kind,
      tags: tags,
      content: content,
    );
  }

  /// Deserializes a [RumorEvent] from a JSON map.
  ///
  /// Throws [FormatException] if a `sig` field is present (rumors must be
  /// unsigned) or if the `id` does not match the canonical computed value.
  factory RumorEvent.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('sig')) {
      throw const FormatException('Rumor events must be unsigned (no sig).');
    }

    final id = _requireString(json, 'id');
    final pubkey = _requireString(json, 'pubkey').toLowerCase();
    final createdAt = _requireInt(json, 'created_at');
    final kind = _requireInt(json, 'kind');
    final tags = _readTags(json);
    final content = _requireString(json, 'content');

    final expectedId = NostrEvent.computeId(
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
    if (id != expectedId) {
      throw const FormatException(
        'Rumor id does not match canonical event data.',
      );
    }

    return RumorEvent._(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: kind,
      tags: tags,
      content: content,
    );
  }

  final String id;
  final String pubkey;

  /// Unix timestamp in seconds.
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;

  /// Serializes to the Nostr wire format (without `sig`).
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
  };

  String toJsonString() => jsonEncode(toJson());
}

// ---------------------------------------------------------------------------
// SealEvent — kind=13, signed, NIP-44 encrypted rumor
// ---------------------------------------------------------------------------

/// A signed NIP-59 Seal (kind 13).
///
/// The content is the NIP-44 ciphertext of the serialized [RumorEvent].
/// Tags MUST be empty (NIP-59 requirement).
final class SealEvent {
  SealEvent._({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required List<List<String>> tags,
    required this.content,
    required this.sig,
  }) : tags = _freezeTags(tags);

  /// Deserializes a [SealEvent] from a JSON map and validates it.
  factory SealEvent.fromJson(Map<String, dynamic> json) {
    final parsedKind = _requireInt(json, 'kind');
    if (parsedKind != _sealKind) {
      throw FormatException(
        'Seal events must use kind $_sealKind, got $parsedKind.',
      );
    }

    final id = _requireString(json, 'id');
    final pubkey = _requireString(json, 'pubkey').toLowerCase();
    final createdAt = _requireInt(json, 'created_at');
    final tags = _readTags(json);
    final content = _requireString(json, 'content');
    final sig = _requireString(json, 'sig');

    final seal = SealEvent._(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      tags: tags,
      content: content,
      sig: sig,
    );
    seal.validate();
    return seal;
  }

  factory SealEvent.fromJsonString(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid seal JSON: expected an object.');
    }
    return SealEvent.fromJson(decoded);
  }

  final String id;
  final String pubkey;

  /// Unix timestamp in seconds.
  final int createdAt;
  final List<List<String>> tags;
  final String content;
  final String sig;

  int get kind => _sealKind;

  /// Validates ID integrity and signature.
  ///
  /// Throws [FormatException] on any validation failure.
  void validate() {
    if (tags.isNotEmpty) {
      throw const FormatException('Seal events must not contain tags.');
    }

    final nostrEvent = _toNostrEvent();
    if (!nostrEvent.verify()) {
      throw const FormatException('Seal id or signature is invalid.');
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  String toJsonString() => jsonEncode(toJson());

  NostrEvent _toNostrEvent() => NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: content,
    sig: sig,
  );
}

// ---------------------------------------------------------------------------
// GiftWrapEvent — kind=1059, ephemeral key, NIP-44 encrypted seal
// ---------------------------------------------------------------------------

/// A NIP-59 Gift Wrap event (kind 1059).
///
/// Signed by an ephemeral keypair to decouple the sender's identity from the
/// transport layer. The content is the NIP-44 ciphertext of the serialized
/// [SealEvent]. MUST contain a `["p", recipientPubkey]` tag.
final class GiftWrapEvent {
  GiftWrapEvent._({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required List<List<String>> tags,
    required this.content,
    required this.sig,
  }) : tags = _freezeTags(tags);

  /// Deserializes a [GiftWrapEvent] from a JSON map and validates it.
  factory GiftWrapEvent.fromJson(Map<String, dynamic> json) {
    final parsedKind = _requireInt(json, 'kind');
    if (parsedKind != _giftWrapKind) {
      throw FormatException(
        'Gift wrap events must use kind $_giftWrapKind, got $parsedKind.',
      );
    }

    final id = _requireString(json, 'id');
    final pubkey = _requireString(json, 'pubkey').toLowerCase();
    final createdAt = _requireInt(json, 'created_at');
    final tags = _readTags(json);
    final content = _requireString(json, 'content');
    final sig = _requireString(json, 'sig');

    final giftWrap = GiftWrapEvent._(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      tags: tags,
      content: content,
      sig: sig,
    );
    giftWrap.validate();
    return giftWrap;
  }

  factory GiftWrapEvent.fromJsonString(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Invalid gift wrap JSON: expected an object.',
      );
    }
    return GiftWrapEvent.fromJson(decoded);
  }

  final String id;
  final String pubkey;

  /// Unix timestamp in seconds (randomized, ±2 days jitter).
  final int createdAt;
  final List<List<String>> tags;
  final String content;
  final String sig;

  int get kind => _giftWrapKind;

  /// Returns the recipient pubkey from the `p` tag, or `null` if absent.
  String? get recipientPubkey {
    for (final tag in tags) {
      if (tag.length >= 2 && tag[0] == 'p') return tag[1];
    }
    return null;
  }

  /// Validates ID integrity, p-tag presence, and signature.
  ///
  /// Throws [FormatException] on any validation failure.
  void validate() {
    if (recipientPubkey == null) {
      throw const FormatException(
        'Gift wrap events must contain a p-tag recipient.',
      );
    }

    final nostrEvent = _toNostrEvent();
    if (!nostrEvent.verify()) {
      throw const FormatException('Gift wrap id or signature is invalid.');
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  String toJsonString() => jsonEncode(toJson());

  NostrEvent _toNostrEvent() => NostrEvent(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: content,
    sig: sig,
  );
}

// ---------------------------------------------------------------------------
// UnwrappedGift — result of unwrapping a GiftWrapEvent
// ---------------------------------------------------------------------------

/// The result of successfully unwrapping a [GiftWrapEvent].
final class UnwrappedGift {
  const UnwrappedGift({
    required this.giftWrap,
    required this.seal,
    required this.rumor,
    required this.recipientPubkey,
  });

  final GiftWrapEvent giftWrap;
  final SealEvent seal;
  final RumorEvent rumor;
  final String recipientPubkey;

  /// The pubkey of the original sender (from the seal).
  String get senderPubkey => seal.pubkey;

  /// The plaintext content from the rumor.
  String get content => rumor.content;

  /// Unix timestamp from the seal (seconds).
  int get timestamp => seal.createdAt;
}

// ---------------------------------------------------------------------------
// Nip59 — main entry point
// ---------------------------------------------------------------------------

/// NIP-59 Gift Wrap protocol implementation.
///
/// Provides [wrap] and [unwrap] operations for E2E encrypted Nostr messages
/// with metadata protection via ephemeral keypairs and timestamp jitter.
final class Nip59 {
  Nip59._();

  static const int sealKind = _sealKind;
  static const int giftWrapKind = _giftWrapKind;

  // -------------------------------------------------------------------------
  // Wrap
  // -------------------------------------------------------------------------

  /// Creates a [GiftWrapEvent] wrapping [content] from sender to recipient.
  ///
  /// [senderPrivkeyBytes] — sender's secp256k1 private key (32 bytes).
  /// [senderPubkeyHex]   — sender's x-only public key (64 hex chars).
  /// [recipientPubkeyHex] — recipient's x-only public key (64 hex chars).
  /// [kind]               — NIP content kind for the rumor (default 14).
  /// [tags]               — optional rumor tags.
  /// [rumorCreatedAt]     — optional fixed rumor timestamp (unix seconds).
  ///
  /// Returns a fully signed, ready-to-publish [GiftWrapEvent].
  static Future<GiftWrapEvent> wrap({
    required String content,
    required Uint8List senderPrivkeyBytes,
    required String senderPubkeyHex,
    required String recipientPubkeyHex,
    int kind = 14,
    List<List<String>> tags = const <List<String>>[],
    int? rumorCreatedAt,
    // Test-only overrides:
    Uint8List? sealNonce,
    Uint8List? giftWrapNonce,
    Uint8List? ephemeralPrivkeyBytes,
    int? sealCreatedAt,
    int? giftWrapCreatedAt,
  }) async {
    final normalizedRecipient = recipientPubkeyHex.toLowerCase();
    final normalizedSender = senderPubkeyHex.toLowerCase();

    // 1. Build rumor (unsigned).
    final rumor = RumorEvent.create(
      kind: kind,
      content: content,
      senderPubkeyHex: normalizedSender,
      tags: tags,
      createdAt: rumorCreatedAt,
    );

    // 2. Build seal: encrypt rumor JSON with sender→recipient NIP-44.
    final rumorJson = rumor.toJsonString();
    final sealCiphertext = await nip44Encrypt(
      rumorJson,
      hex.encode(senderPrivkeyBytes),
      normalizedRecipient,
      customNonce: sealNonce,
    );

    final sealEvent = NostrEvent.sign(
      pubkeyHex: normalizedSender,
      privateKey: senderPrivkeyBytes,
      kind: _sealKind,
      tags: const <List<String>>[],
      content: sealCiphertext,
      createdAt: sealCreatedAt ?? randomTimestamp(),
    );

    final seal = SealEvent._(
      id: sealEvent.id,
      pubkey: sealEvent.pubkey,
      createdAt: sealEvent.createdAt,
      tags: const <List<String>>[],
      content: sealCiphertext,
      sig: sealEvent.sig,
    );

    // 3. Build gift wrap: generate ephemeral key, encrypt seal JSON.
    final ephPrivBytes = ephemeralPrivkeyBytes ?? generatePrivateKey();
    final ephPubBytes = derivePublicKey(ephPrivBytes);
    final ephPubHex = hex.encode(ephPubBytes);
    final ephPrivHex = hex.encode(ephPrivBytes);

    final sealJson = seal.toJsonString();
    final wrapCiphertext = await nip44Encrypt(
      sealJson,
      ephPrivHex,
      normalizedRecipient,
      customNonce: giftWrapNonce,
    );

    final wrapTags = <List<String>>[
      <String>['p', normalizedRecipient],
    ];

    final wrapEvent = NostrEvent.sign(
      pubkeyHex: ephPubHex,
      privateKey: ephPrivBytes,
      kind: _giftWrapKind,
      tags: wrapTags,
      content: wrapCiphertext,
      createdAt: giftWrapCreatedAt ?? randomTimestamp(),
    );

    return GiftWrapEvent._(
      id: wrapEvent.id,
      pubkey: wrapEvent.pubkey,
      createdAt: wrapEvent.createdAt,
      tags: wrapTags,
      content: wrapCiphertext,
      sig: wrapEvent.sig,
    );
  }

  // -------------------------------------------------------------------------
  // Unwrap
  // -------------------------------------------------------------------------

  /// Unwraps a [GiftWrapEvent] using the recipient's private key.
  ///
  /// [giftWrap]              — the gift wrap to unwrap.
  /// [recipientPrivkeyBytes] — recipient's private key (32 bytes).
  ///
  /// Throws [FormatException] if any layer is invalid or the sender identity
  /// check fails.
  static Future<UnwrappedGift> unwrap({
    required GiftWrapEvent giftWrap,
    required Uint8List recipientPrivkeyBytes,
  }) async {
    giftWrap.validate();

    final recipientPrivHex = hex.encode(recipientPrivkeyBytes);
    final recipientPubHex = hex.encode(derivePublicKey(recipientPrivkeyBytes));

    // Decrypt gift wrap → seal JSON.
    final sealJson = await nip44Decrypt(
      giftWrap.content,
      recipientPrivHex,
      giftWrap.pubkey, // ephemeral pubkey
    );

    final seal = SealEvent.fromJsonString(sealJson);

    // Decrypt seal → rumor JSON.
    final rumorJson = await nip44Decrypt(
      seal.content,
      recipientPrivHex,
      seal.pubkey, // sender pubkey
    );

    final rumor = RumorEvent.fromJson(_decodeJsonMap(rumorJson));

    // Anti-impersonation check: rumor author must match seal signer.
    if (rumor.pubkey != seal.pubkey) {
      throw const FormatException(
        'Rumor pubkey must match the author who signed the seal.',
      );
    }

    return UnwrappedGift(
      giftWrap: giftWrap,
      seal: seal,
      rumor: rumor,
      recipientPubkey: recipientPubHex,
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Returns a random unix timestamp within the past ±2 days.
  ///
  /// Used to obscure when a message was actually created.
  static int randomTimestamp() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final jitterSeconds = 2 * 24 * 60 * 60; // 2 days in seconds
    final offset = Random.secure().nextInt(jitterSeconds + 1);
    return now - offset;
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

List<List<String>> _freezeTags(List<List<String>> tags) =>
    List<List<String>>.unmodifiable(
      tags.map((tag) => List<String>.unmodifiable(tag)),
    );

List<List<String>> _readTags(Map<String, dynamic> json) {
  final value = json['tags'];
  if (value is! List) {
    throw const FormatException('Missing or invalid `tags`: expected list.');
  }
  return value
      .map<List<String>>((tag) {
        if (tag is! List) {
          throw const FormatException('Invalid tag: expected nested list.');
        }
        return List<String>.unmodifiable(tag.map((e) => e.toString()));
      })
      .toList(growable: false);
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

Map<String, dynamic> _decodeJsonMap(String jsonStr) {
  final decoded = jsonDecode(jsonStr);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object.');
  }
  return decoded;
}
