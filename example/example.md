# Examples

## Quick Start: Basic JSON-RPC

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

## Quick Start: Custom typed Protocol

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