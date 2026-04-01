// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nostr_rpc/nostr_rpc.dart';

import 'chat_ui.dart';

// ─── Domain model ─────────────────────────────────────────────────────────────
class ChatMessage {
  ChatMessage({
    required this.from,
    required this.text,
    required this.timestamp,
  });

  final String from;
  final String text;
  final DateTime timestamp;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      from: json['from'] as String? ?? 'unknown',
      text: json['text'] as String? ?? '',
      timestamp:
          json.containsKey('ts')
              ? DateTime.fromMillisecondsSinceEpoch(json['ts'] as int)
              : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'from': from,
    'text': text,
    'ts': timestamp.millisecondsSinceEpoch,
  };
}

// ─── Typed connection ─────────────────────────────────────────────────────────
class ChatConnection extends RpcConnection {
  ChatConnection({required String peerPubkeyHex, required RawChannel channel})
    : _peerPubkeyHex = peerPubkeyHex,
      _channel = channel {
    _incomingController = StreamController<ChatMessage>.broadcast();
    _subscription = channel.incoming.listen(
      _handleRaw,
      onDone: () => _incomingController.close(),
      onError: (_) => _incomingController.close(),
    );
  }

  final String _peerPubkeyHex;
  final RawChannel _channel;
  late final StreamController<ChatMessage> _incomingController;
  late final StreamSubscription<String> _subscription;
  bool _closed = false;

  @override
  String get peerPubkeyHex => _peerPubkeyHex;

  Stream<ChatMessage> get onMessage => _incomingController.stream;

  Future<void> sendMessage(String text, String senderName) async {
    if (_closed) return;
    final msg = ChatMessage(
      from: senderName,
      text: text,
      timestamp: DateTime.now(),
    );
    _channel.outgoing.add(jsonEncode(msg.toJson()));
  }

  void _handleRaw(String raw) {
    if (_closed) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final msg = ChatMessage.fromJson(json);
      if (!_incomingController.isClosed) _incomingController.add(msg);
    } catch (_) {
      // Malformed message — ignore silently
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    if (!_incomingController.isClosed) await _incomingController.close();
    await _channel.outgoing.close();
  }
}

// ─── Typed protocol ───────────────────────────────────────────────────────────
class ChatProtocol extends RpcProtocol<ChatConnection> {
  @override
  ChatConnection createConnection(String peerPubkeyHex, RawChannel channel) {
    return ChatConnection(peerPubkeyHex: peerPubkeyHex, channel: channel);
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────
final ui = ChatUi();
String? peerPubKey;

Future<void> main() async {
  const String relayUrl = 'wss://nostr.001.j5s9.dev';
  final identity = NostrIdentity.generate();
  final name = ui.setup(relayUrl, identity);

  final nostrRpc = NostrRpc<ChatConnection>(
    relays: [relayUrl],
    identity: identity,
    protocol: ChatProtocol(),
    acceptanceStrategy: AlwaysAcceptStrategy(),
  );

  nostrRpc.onPeerConnected.listen(registerChatHandler);

  ui.printInfo('Connecting to relay: $relayUrl …');
  await nostrRpc.start();
  ui.printInfo('Connected.\n');

  ProcessSignal.sigint.watch().listen((_) async {
    ui.printInfo('\nShutting down…');
    await nostrRpc.dispose();
    exit(0);
  });

  await ui.runLoop(
    onPeerSelected: (rawInput) async {
      String hexPubkey;
      if (rawInput.toLowerCase().startsWith('npub1')) {
        try {
          hexPubkey = decodeNpub(rawInput);
        } catch (_) {
          ui.printError('Invalid npub. Please try again.');
          return false;
        }
      } else {
        hexPubkey = rawInput;
      }
      final connection = nostrRpc.getOrCreateConnection(hexPubkey);
      registerChatHandler(connection);
      peerPubKey = hexPubkey;
      return true;
    },
    onMessage: (String input) async {
      final connection = nostrRpc.getOrCreateConnection(peerPubKey!);
      try {
        await connection.sendMessage(input, name);
        ui.printOwnBubble(input, name, ChatUi.shortPubkey(identity.pubkeyHex));
      } catch (e) {
        ui.printError('Failed to send message: $e');
      }
    },
    onQuit: () async {
      ui.printInfo('Goodbye!');
      await nostrRpc.dispose();
      exit(0);
    },
  );
}

void registerChatHandler(ChatConnection connection) {
  if (peerPubKey != null) return;
  connection.onMessage.listen((msg) {
    ui.printPeerBubble(
      msg.text,
      msg.from,
      ChatUi.shortPubkey(connection.peerPubkeyHex),
    );
  });
  peerPubKey = connection.peerPubkeyHex;
  ui.notifyPeerConnected(connection.peerPubkeyHex);
}
