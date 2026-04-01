import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';

import 'package:nostr_rpc/src/core/acceptance_strategy.dart';
import 'package:nostr_rpc/src/core/nostr_rpc.dart';
import 'package:nostr_rpc/src/identity.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_protocol.dart';

import 'mock_relay.dart';

Future<T> _withTimeout<T>(Future<T> future, {int seconds = 10}) {
  return Future.any([
    future,
    Future.delayed(
      Duration(seconds: seconds),
      () => throw TimeoutException('Timed out after $seconds seconds'),
    ),
  ]);
}

void main() {
  group('simple chat flow regression', () {
    late MockRelay relay;

    setUp(() async {
      relay = MockRelay();
      await relay.start();
    });

    tearDown(() async {
      await relay.stop();
    });

    test(
      'outbound chat handler plus immediate notification delivers both directions',
      () async {
        final alice = NostrRpc<JsonRpcConnection>(
          relays: [relay.wsUrl],
          identity: NostrIdentity.generate(),
          acceptanceStrategy: AlwaysAcceptStrategy(),
        );
        final bob = NostrRpc<JsonRpcConnection>(
          relays: [relay.wsUrl],
          identity: NostrIdentity.generate(),
          acceptanceStrategy: AlwaysAcceptStrategy(),
        );

        final aliceReceived = Completer<Map<String, String>>();
        final bobReceived = Completer<Map<String, String>>();
        final bobPeerConnected = Completer<JsonRpcConnection>();

        try {
          bob.onPeerConnected.listen((connection) {
            if (!bobPeerConnected.isCompleted) {
              bobPeerConnected.complete(connection);
            }

            connection.registerMethod('chat', (rpc.Parameters params) {
              if (!bobReceived.isCompleted) {
                bobReceived.complete({
                  'text': params['text'].value as String? ?? '',
                  'from': params['from'].value as String? ?? '',
                });
              }
            });
          });

          await alice.start();
          await bob.start();

          final aliceConn = alice.getOrCreateConnection(bob.identity.pubkeyHex);
          aliceConn.registerMethod('chat', (rpc.Parameters params) {
            if (!aliceReceived.isCompleted) {
              aliceReceived.complete({
                'text': params['text'].value as String? ?? '',
                'from': params['from'].value as String? ?? '',
              });
            }
          });

          aliceConn.sendNotification('chat', {
            'text': 'hello from alice',
            'from': 'Alice',
          });

          expect(
            await _withTimeout(bobReceived.future),
            equals({'text': 'hello from alice', 'from': 'Alice'}),
          );

          final bobConn = await _withTimeout(bobPeerConnected.future);
          bobConn.sendNotification('chat', {
            'text': 'hello from bob',
            'from': 'Bob',
          });

          expect(
            await _withTimeout(aliceReceived.future),
            equals({'text': 'hello from bob', 'from': 'Bob'}),
          );
        } finally {
          try {
            await alice.dispose();
          } catch (_) {}
          try {
            await bob.dispose();
          } catch (_) {}
        }
      },
    );
  });
}
