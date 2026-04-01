// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'chat_ui.dart';

import 'package:nostr_rpc/nostr_rpc.dart';

final ui = ChatUi();
String? peerPubKey;

Future<void> main() async {
  // ── Setup ──
  const String relayUrl = 'wss://nostr.001.j5s9.dev';
  final identity = NostrIdentity.generate();
  final name = ui.setup(relayUrl, identity);

  // ── Build NostrRpc ──
  final nostrRpc = NostrRpc<JsonRpcConnection>(
    relays: [relayUrl],
    identity: identity,
    acceptanceStrategy: AlwaysAcceptStrategy(),
  );

  // ── Register handler for inbound connections ──
  nostrRpc.onPeerConnected.listen(registerChatHandler);

  // ── Start relay connection ──
  ui.printInfo('Connecting to relay: $relayUrl …');
  await nostrRpc.start();
  ui.printInfo('Connected.\n');

  // ── Graceful shutdown ──
  ProcessSignal.sigint.watch().listen((_) async {
    ui.printInfo('\nShutting down…');
    await nostrRpc.dispose();
    exit(0);
  });

  // ── Peer selection + chat loop ──
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
      connection.sendNotification('chat', {'text': 'connected', 'from': name});

      return true;
    },
    onMessage: (String input) async {
      final connection = nostrRpc.getOrCreateConnection(peerPubKey!);
      try {
        connection.sendNotification('chat', {'text': input, 'from': name});
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

void registerChatHandler(JsonRpcConnection connection) {
  // Already connected to a peer — ignore new connections
  if (peerPubKey != null) return;
  connection.registerMethod('chat', (params) {
    final from = params['from']?.value as String? ?? 'unknown';
    final text = params['text']?.value as String? ?? '';
    ui.printPeerBubble(
      text,
      from,
      ChatUi.shortPubkey(connection.peerPubkeyHex),
    );
  });
  peerPubKey = connection.peerPubkeyHex;
  ui.notifyPeerConnected(connection.peerPubkeyHex);
}
