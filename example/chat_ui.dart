import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:nostr_rpc/nostr_rpc.dart';

// ─── Chat UI ──────────────────────────────────────────────────────────────────
class ChatUi {
  static const String reset = '\x1B[0m';
  static const String cyan = '\x1B[36m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String bold = '\x1B[1m';

  bool _hasPeer = false;

  String setup(String relayUrl, NostrIdentity identity) {
    printBanner(relayUrl);
    final myName = prompt('Your display name');

    printInfo('Generating fresh Nostr identity…');

    printInfo(
      'Your pubkey (npub): ${ChatUi.bold}${identity.npub}${ChatUi.reset}',
    );
    printInfo('Your pubkey (hex):  ${identity.pubkeyHex}');
    print('');
    printInfo('Share your npub with your chat partner.');
    print('');
    return myName;
  }

  void printBanner(String relayUrl) {
    print(yellow);
    print('╔═════════════════════════════════════════════════════╗');
    print('║     nostr_rpc  ·  by https://j5s9.dev               ║');
    print('║     NIP-59 - Gift Wrapped JSON-RPC 2.0              ║');
    print('╚═════════════════════════════════════════════════════╝$reset');
    print('');
    print('$yellow[info]$reset Relay: $relayUrl');
    print('');
  }

  void printInfo(String msg) => print('$yellow[info]$reset $msg');
  void printError(String msg) => print('\x1B[31m[error]$reset $msg');

  void printOwnBubble(String text, String name, String pubkeyShort) =>
      _printPeerBubble(text, name, pubkeyShort, false);

  void printPeerBubble(String text, String fromName, String pubkeyShort) =>
      _printPeerBubble(text, fromName, pubkeyShort, true);

  void _printPeerBubble(
    String text,
    String fromName,
    String pubkeyShort,
    bool peerMessage,
  ) {
    final color = peerMessage ? green : cyan;
    final ident = peerMessage ? '  ' : '';

    print('');
    print(
      '$ident$color╔═════════════════════════════════════════════════════╗$reset',
    );
    print('$ident$color║$reset $bold$fromName$reset ($pubkeyShort…)');
    print('$ident$color║$reset $text');
    print(
      '$ident$color╚═════════════════════════════════════════════════════╝$reset',
    );
  }

  static String shortPubkey(String hex) =>
      hex.length > 10 ? hex.substring(0, 10) : hex;

  String prompt(String question, {String? defaultValue}) {
    if (defaultValue != null) {
      stdout.write('$question [$defaultValue]: ');
    } else {
      stdout.write('$question: ');
    }
    final line = stdin.readLineSync()?.trim();
    if (line == null || line.isEmpty) return defaultValue ?? '';
    return line;
  }

  /// Called by logic when an inbound peer connects while waiting in Phase 1.
  void notifyPeerConnected(String pubkeyHex) {
    _hasPeer = true;
    print('');
    printInfo('Peer connected: $pubkeyHex');
    printInfo('Type messages and press Enter.');
    stdout.write('> ');
  }

  Future<void> runLoop({
    required Future<bool> Function(String rawInput) onPeerSelected,
    required Future<void> Function(String input) onMessage,
    required Future<void> Function() onQuit,
  }) async {
    printInfo('Enter peer pubkey (hex or npub) to connect,');
    printInfo('or wait for a peer to connect to you. Type "quit" to exit.');
    print('');
    stdout.write('Peer pubkey: ');

    await for (final line in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      final input = line.trim();

      if (input == 'quit' || input == 'exit') {
        await onQuit();
        return;
      }

      if (!_hasPeer) {
        // Phase 1: waiting for peer
        if (input.isEmpty) {
          stdout.write('Peer pubkey: ');
          continue;
        }
        final accepted = await onPeerSelected(input);
        if (accepted) {
          _hasPeer = true;
          printInfo('Peer set. Type messages and press Enter.');
        }
        stdout.write('> ');
        continue;
      }

      // Phase 2: chatting
      if (input.isEmpty) {
        stdout.write('> ');
        continue;
      }

      await onMessage(input);
      stdout.write('> ');
    }
  }
}
