# Nostr RPC

[![Pub Version](https://img.shields.io/pub/v/nostr_rpc)](https://pub.dev/packages/nostr_rpc)
[![Dart CI](https://github.com/j5s9/nostr_rpc/actions/workflows/ci-cd.yml/badge.svg)](https://github.com/j5s9/nostr_rpc/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**End-to-end encrypted JSON-RPC 2.0 over Nostr** – secure peer-to-peer communication for Dart and Flutter without servers, VPNs or port forwarding.

Nostr RPC wraps the familiar JSON-RPC 2.0 protocol in Nostr's NIP-59 Gift Wrap (with NIP-44 encryption), giving you decentralized, private and resilient RPC calls across relays.

## What It Is

Nostr RPC is a Dart library that enables **secure peer-to-peer communication** using the Nostr protocol. It specializes in **end-to-end encrypted JSON-RPC 2.0** calls wrapped in Nostr's NIP-59 Gift Wrap, ensuring your data stays private and tamper-proof.

Key highlights:
- **Decentralized**: No central authority controls your communication
- **Encrypted**: Messages are encrypted using NIP-44 and wrapped with NIP-59
- **Reliable**: Multi-relay support with automatic deduplication
- **Flexible**: Pluggable protocols for custom communication patterns

## What It Is Not

This library is **not** a general-purpose Nostr client. It's specifically designed for RPC-style communication between peers. If you need:
- General Nostr event publishing/subscribing → Use [`dart_nostr`](https://pub.dev/packages/dart_nostr) instead
- Wallet functionality → Look for Nostr wallet libraries
- Social media features → Check other Nostr packages

Nostr RPC focuses solely on secure, structured RPC communication.

## Features

### 🔒 Strong End-to-End Encryption
Messages are protected with **NIP-44** (AES-GCM) encryption and wrapped using **NIP-59 Gift Wrap**. Even if a relay or observer intercepts the message, they cannot read the content or reliably determine who is communicating with whom.

### 🚀 JSON-RPC 2.0 Support
Communicate using the industry-standard JSON-RPC 2.0 protocol. This familiar format makes it easy to integrate with existing systems and tools that already support RPC calls.

### 🌐 Multi-Relay Resilience
Connect through multiple Nostr relays simultaneously. If one relay goes down, your communication continues seamlessly through others. Automatic deduplication ensures you don't receive duplicate messages.

### 🎛️ Flexible Connection Control
Choose how you want to handle incoming connections:
- **Always Accept**: Trust everyone (great for open services)
- **Always Ask**: Manual approval for each connection
- **Cached Approval**: Remember trusted peers automatically

### 📦 Pluggable Protocols
Need something beyond JSON-RPC? Easily create custom protocols for your specific use case – chat, file transfer, or any structured communication pattern.

### 🔄 Smart Ordering
Handle out-of-order messages gracefully with sequence caching and automatic reordering, ensuring your RPC calls and responses arrive in the correct sequence.

## How It Works
To achieve maximum privacy on Nostr, messages are wrapped in **multiple encryption layers.** Each layer solves a different privacy problem:

To achieve maximum privacy on Nostr, messages are wrapped in **multiple encryption layers.** Each layer solves a different privacy problem:

1. **Innermost Layer – The Rumor (unsigned event)**
   Your actual message content (e.g. a text message, RPC request, or response) exists as an **unsigned** Nostr event called the "Rumor". It is not signed with your private key.
2. **NIP-44 Encryption – Content Protection**
   The Rumor is encrypted using **NIP-44** (AES-GCM with modern cryptography).
   Only you and the intended recipient share the symmetric key (the conversation key).
   → No one else can read the actual message content.
3. **Seal (Kind 13) – Sender Protection**
   The encrypted Rumor is placed inside a "Seal" event.
   This Seal is encrypted again with **NIP-44**, but this time using a **random, one-time (ephemeral) keypair**.
   This completely hides the real sender’s public key.
4. **Gift Wrap (Kind 1059) – Anonymous Envelope**
   The Seal is encrypted one final time with **NIP-44** (again using a fresh ephemeral key) and wrapped into a Gift Wrap event.
   This outer envelope:
   - is signed by a **completely random, temporary key** (not your real account),
   - only contains the recipient’s public key as a tag ("p"),
   - looks like a generic, harmless Nostr event to everyone else.

### What Does Each Party See?

| Party | Can See Sender? | Can See Content? | Can See Who Is Talking to Whom? |
|-------|-----------------|------------------|--------------------------------|
| Relays / Observers | ❌ (random key) | ❌ | receivers pubkey got blob from random public key.
| Intermediaries | ❌ | ❌ | ❌ |
| Recipient | ✅ (after decryption) | ✅ | ✅ |

### Key Benefits:
- **Content** is strongly encrypted (NIP-44).
- **Metadata** (who is talking to whom, when, from which account) is heavily obfuscated.
- Forward secrecy thanks to ephemeral keys.
- Plausible deniability (the inner event is unsigned).


## Dependencies

We carefully selected dependencies to ensure security, reliability, and minimal footprint:

- **json_rpc_2** (4M+ downloads) - Official Dart team package for JSON-RPC
- **web_socket_channel** (6M+ downloads) - Dart team's WebSocket implementation
- **stream_channel** (5M+ downloads) - Dart team's streaming utilities
- **convert** (5M+ downloads) - Dart team's encoding/decoding utilities
- **pointycastle** (2M+ downloads) - Bouncy Castle's cryptographic library

All dependencies are from trusted sources (Dart team or Bouncy Castle) with millions of downloads and active maintenance.

## Installation

```bash
dart pub add nostr_rpc
```

## Examples

### Quick Start: Basic JSON-RPC

```dart
import 'package:nostr_rpc/nostr_rpc.dart';

final rpc = NostrRpc<JsonRpcConnection>(
  relays: ['wss://relay.example.com'],
  identity: NostrIdentity.generate(),
  acceptanceStrategy: AlwaysAcceptStrategy(),
);

await rpc.start();

rpc.onPeerConnected.listen((connection) {
  connection.registerMethod('echo', (params) => print(params['text']));
});

// connect with peer and send a message
final connection = rpc.getOrCreateConnection('peer_pubkey_hex');
final response = await connection.sendRequest('echo', {'text': 'Hello, from nostr_rpc!'});
print(response)
```

See [example/chat_simple.dart](https://github.com/j5s9/nostr_rpc/tree/main/example/chat_simple.dart) for a complete example.

### Quick Start: Custom typed Protocol

```dart
import 'package:nostr_rpc/nostr_rpc.dart';

class ChatConnection extends RpcConnection {
  ChatConnection({required super.peerPubkeyHex, required super.channel});
}

class ChatProtocol extends RpcProtocol<ChatConnection> {
  @override
  ChatConnection createConnection(String peerPubkeyHex, RawChannel channel) {
    return ChatConnection(peerPubkeyHex: peerPubkeyHex, channel: channel);
  }
}

final rpc = NostrRpc<ChatConnection>(
  relays: ['wss://relay.example.com'],
  identity: NostrIdentity.generate(),
  protocol: ChatProtocol(),
  acceptanceStrategy: AlwaysAcceptStrategy(),
);
```

See [example/chat_typed.dart](https://github.com/j5s9/nostr_rpc/tree/main/example/chat_typed.dart) for the full implementation.

## API Overview

For detailed API documentation, see [pub.dev](https://pub.dev/documentation/nostr_rpc/latest/).

- [`NostrRpc<T>`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/core/nostr_rpc.dart) — The core RPC engine that manages connections and relays
- [`NostrIdentity`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/identity.dart) — Handles key generation and cryptographic operations
- [`RpcProtocol<T>`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/protocol/rpc_protocol.dart) — Abstract base for custom communication protocols
- [`JsonRpcProtocol`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/protocol/json_rpc_protocol.dart) — Default JSON-RPC 2.0 implementation
- [`JsonRpcWithSequenceCacheProtocol`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/protocol/json_rpc_with_sequence_cache_protocol.dart) — Ordered JSON-RPC with sequence handling
- [`OrderingStrategy`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/ordering/ordering_strategy.dart) — Interfaces for message ordering ([`NoCacheOrdering`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/ordering/no_cache_ordering.dart), [`SequenceCacheOrdering`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/ordering/sequence_cache_ordering.dart))
- [`AcceptanceStrategy`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/core/acceptance_strategy.dart) — Connection approval logic ([`AlwaysAcceptStrategy`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/core/acceptance_strategy.dart), [`AlwaysAskStrategy`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/core/acceptance_strategy.dart), [`CachedApprovalStrategy`](https://github.com/j5s9/nostr_rpc/blob/main/lib/src/core/acceptance_strategy.dart))


## Contributing

We welcome contributions! See [CONTRIBUTION.md](CONTRIBUTION.md) for guidelines.

## Acknowledgments

This library builds on the foundational work of the Nostr community, including the [Nostr Protocol specification](https://github.com/nostr-protocol/nostr) and [dart_nostr](https://pub.dev/packages/dart_nostr).

## License

This project is licensed under the MIT License - see the LICENSE file for details.
