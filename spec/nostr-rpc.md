# nostr_rpc Package Specification

## Overview

The `nostr_rpc` package is a Dart library that enables end-to-end encrypted JSON-RPC 2.0 communication between devices over the Nostr network using NIP-59 Gift Wrap. It provides a secure, protocol-agnostic transport layer for remote procedure calls, allowing developers to build peer-to-peer applications with strong encryption and reliable message ordering.

**Core Concept**: Connect two or more devices securely via Nostr's decentralized network, enabling RPC-style communication without requiring direct IP connections or centralized servers. All communication is encrypted using NIP-44 and wrapped in NIP-59 Gift Wrap events.

## Scope and Limitations

### What This Package Is
- A specialized transport layer for JSON-RPC communication over Nostr
- Focused exclusively on NIP-59 Gift Wrap for secure, encrypted RPC calls
- Protocol-agnostic design allowing custom RPC protocols beyond JSON-RPC
- Includes built-in crypto implementations (NIP-44, secp256k1, Bech32, etc.)
- Provides connection management, message ordering, and peer acceptance strategies

### What This Package Is NOT
- A general-purpose Nostr client library
- A replacement for packages like `dart_nostr` for other Nostr operations
- A full Nostr protocol implementation (events, relays, subscriptions beyond RPC transport)

**Important**: For general Nostr functionality (posting events, subscribing to feeds, managing keys, etc.), use dedicated packages like `dart_nostr`. This package is specifically designed for RPC communication and does not provide broader Nostr features.

### Design Constraints
- No dependencies on external Nostr packages.
- All crypto code implemented internally for security and reliability
- WebSocket-based relay communication only
- Identity management limited to in-memory operations; persisted identity management is outside the scope of this package

## Features

### Core Features
- **E2E Encryption**: Full NIP-44 encryption with NIP-59 Gift Wrap
- **JSON-RPC 2.0 Support**: Built-in protocol with `json_rpc_2` integration
- **Protocol Abstraction**: Pluggable `RpcProtocol<T>` for custom protocols
- **Multi-Relay Support**: Send to multiple relays, receive from all with deduplication
- **Message Ordering**: Configurable strategies (NoCache, SequenceCache with reordering)
- **Peer Management**: Connection objects per peer with acceptance strategies
- **Sequence Caching**: Handles out-of-order messages with configurable fallback behaviors

### Security Features
- Built-in secp256k1, Schnorr signatures, Bech32 encoding
- Official test vector validation for crypto components
- Ephemeral key generation for each communication session

### Developer Experience
- Generic `NostrRpc<T>` class for type-safe connections
- Three acceptance strategies: AlwaysAccept, AlwaysAsk, CachedApproval
- Example CLI chat applications (simple JSON-RPC and typed protocol)
- Comprehensive unit tests with mock transport layer

## Architecture

### Core Components

```
NostrRpc<T> (Generic RPC Engine)
├── Identity Management (NostrIdentity)
├── Transport Layer (WebSocket Relay Client + Multi-Relay Manager)
├── Protocol Layer (RpcProtocol<T> abstraction)
│   ├── JsonRpcProtocol (default)
│   └── JsonRpcWithSequenceCacheProtocol
├── Ordering Strategies
│   ├── NoCacheOrdering
│   └── SequenceCacheOrdering
└── Acceptance Strategies
    ├── AlwaysAcceptStrategy
    ├── AlwaysAskStrategy
    └── CachedApprovalStrategy
```

### Data Flow
1. **Connection Establishment**: Subscribe to relay with filter `#p=[myPubkey], kinds=[1059]`
2. **Peer Discovery**: Receive NIP-59 Gift Wrap events from potential peers
3. **Acceptance Check**: Use AcceptanceStrategy to approve/reject connections
4. **Decryption**: Unwrap NIP-59, decrypt NIP-44 payload
5. **Protocol Processing**: Parse JSON-RPC messages via configured protocol
6. **Ordering**: Apply ordering strategy (sequence numbers, caching)
7. **RPC Execution**: Route to registered method handlers

### Key Abstractions
- `RpcProtocol<T>`: Defines how to create connections and handle messages
- `RpcConnection`: Represents a connection to a specific peer
- `OrderingStrategy`: Controls message sequencing and reordering
- `AcceptanceStrategy`: Determines which peers can connect

## API Overview

### Basic Usage

```dart
import 'package:nostr_rpc/nostr_rpc.dart';

final rpc = NostrRpc<JsonRpcConnection>(
  relays: ['wss://relay.example.com'],
  identity: NostrIdentity.generate(),
  acceptanceStrategy: AlwaysAcceptStrategy(),
);

await rpc.start();

rpc.onPeerConnected.listen((connection) {
  connection.registerMethod('echo', (params) => params['text']?.value);
});

final peerConnection = rpc.getOrCreateConnection('peer_pubkey_hex');
final response = await peerConnection.sendRequest('echo', {'text': 'hello'});
```

### Custom Protocol Example

```dart
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

## Dependencies
- `json_rpc_2`: JSON-RPC 2.0 protocol implementation
- `stream_channel`: Bidirectional stream communication
- `web_socket_channel`: WebSocket client
- `pointycastle`: Cryptographic primitives
- `convert`: Data conversion utilities

## Examples

The package includes two example CLI applications:

### Simple Chat (Default JSON-RPC)
- Uses built-in `JsonRpcProtocol`
- Demonstrates basic request/response communication
- Located in `example/chat_simple.dart`

### Typed Chat (Custom Protocol)
- Implements custom `ChatProtocol` with strongly typed interface
- Shows how to extend the protocol abstraction
- Located in `example/chat_typed.dart`

Both examples include ASCII art wizards and bidirectional chat functionality.

## Testing

- **Crypto Tests**: Validation against official NIP-44 and BIP-340 test vectors
- **Transport Tests**: Mock WebSocket testing for relay communication
- **Integration Tests**: Full round-trip testing with real relays
- **Unit Tests**: Coverage for all core components and strategies

## Security Considerations

- All cryptographic operations use well-vetted algorithms (secp256k1, ChaCha20, etc.)
- Ephemeral keys generated per session prevent long-term key compromise
- No sensitive data persisted to disk
- Relay communication is over WebSocket (WSS recommended)
- Acceptance strategies prevent unauthorized connections

## Future Considerations

This package is designed specifically for RPC communication over Nostr. For broader Nostr ecosystem integration:
- Use `dart_nostr` for general event posting and subscription
- Combine with other Nostr packages for hybrid applications
- Consider relay selection strategies for production deployments

## Conclusion

`nostr_rpc` provides a secure, focused solution for encrypted RPC communication over Nostr's decentralized network. By limiting scope to NIP-59 Gift Wrap and RPC protocols, it offers a reliable foundation for peer-to-peer applications while avoiding the complexity of full Nostr client implementations.
- Relay Reconnection: NOT in v1 → Guardrail
- StreamChannel Lifecycle: Explicit lifecycle management per connection → In NostrRpc task
- Multi-Peer Subscription: One filter `#p=[myPubkey], kinds=[1059]` receives from ALL senders → Validated
- NIP-59 Timestamp Jitter: `since` filter must look back 2+ days → In transport task

---

## Work Objectives

### Core Objective
Create a general-purpose, dependency-light Dart package that enables E2E-encrypted JSON-RPC 2.0 communication between any number of peers over Nostr NIP-59 Gift Wrap, with injectable strategies for peer acceptance and message ordering.

### Concrete Deliverables
- `lib/nostr_rpc.dart` — Package export
- `lib/src/crypto/` — Built-in NIP-44, NIP-59, secp256k1, bech32 implementations
- `lib/src/transport/` — WebSocket relay client, multi-relay management, dedup
- `lib/src/core/` — NostrRpc<T>, RpcConnection, AcceptanceStrategy
- `lib/src/protocol/` — RpcProtocol<T>, JsonRpcProtocol, JsonRpcConnection, JsonRpcWithSequenceCacheProtocol
- `lib/src/ordering/` — OrderingStrategy, NoCacheOrdering, SequenceCacheOrdering, SequenceWrapper
- `lib/src/identity.dart` — NostrIdentity (in-memory key generation)
- `example/chat_simple.dart` — CLI chat with default JsonRpc protocol
- `example/chat_typed.dart` — CLI chat with custom ChatProtocol (strongly typed)
- `test/` — Unit tests with official test vectors

### Definition of Done
- [ ] `dart pub get` successful
- [ ] `dart analyze` reports 0 errors, 0 warnings
- [ ] `dart test` — all tests green
- [ ] `ast_grep_search` finds no `import 'package:dart_nostr'`, `import 'package:nip44'`, `import 'package:nostr'`, `import 'package:bip340'` in package
- [ ] Example CLI app starts and shows wizard
- [ ] Two example CLI instances can exchange at least one JSON-RPC message (manual test against real relay)

### Must Have
- NIP-59 Gift Wrap (Rumor → Seal → Wrap) with NIP-44 encryption
- **Protocol Abstraction**: `RpcProtocol<T>` abstract class, interchangeable
- **JsonRpcProtocol**: Default implementation with json_rpc_2.Peer per connection
- **JsonRpcWithSequenceCacheProtocol**: JsonRpcProtocol + SequenceCacheOrdering (DEFAULT if user specifies nothing)
- **SequenceCacheOrdering**: Fully implemented — cache, reorder by seq, timeout + 3 fallback strategies (FlushOutOfOrder, DropMissing, ThrowOnMissing)
- Generic NostrRpc: `NostrRpc<T extends RpcConnection>` — protocol determines connection type
- Multi-peer support (one filter receives from all senders)
- Multi-relay support (send to all, receive from all, dedup)
- AcceptanceStrategy interface + AlwaysAccept, AlwaysAsk, CachedApproval
- In-memory identity (no persistence)
- WebSocket-based relay client (Nostr JSON protocol)
- Official NIP-44 test vectors + BIP-340 test vectors
- Two example CLI chat apps: `chat_simple.dart` (default) + `chat_typed.dart` (custom ChatProtocol)

### Must NOT Have (Guardrails)
- **No dart_nostr, nip44, nostr, bip340 package dependencies** — implementations are self-contained
- **No persistence** — no files, databases, SharedPreferences
- **No relay reconnection in v1** — Connect/Subscribe/Publish/Disconnect. Consumer handles retry.
- **No handshake protocol** — NostrRpc is transport channel, not protocol
- **No ACP-specific code** — Do not copy anything from `acp_over_nostr/acpon/lib/acp/`
- **No auto-reconnection, exponential backoff, cursor-based replay**
- **No over-engineered error handling** — Exceptions up, consumer handles retry
- **No dart_nostr or nip44 as transitive dependency**
- **NostrRpc MUST NOT directly depend on json_rpc_2** — json_rpc_2 lives only in JsonRpcProtocol

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: NO (new project)
- **Automated tests**: Tests after implementation (but validate crypto code with test vectors FIRST)
- **Framework**: `dart test` (built-in)
- **Crypto Gate**: NIP-44 and BIP-340 test vectors MUST be passed BEFORE building transport/NostrRpc layer

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Crypto/Transport/NostrRpc**: Use Bash (`dart test`, `dart analyze`) — Run tests, assert exit code 0
- **CLI Example**: Use interactive_bash (tmux) — Start app, send input, validate output
- **Integration**: Use Bash (two processes via tmux) — Start two instances, verify message exchange