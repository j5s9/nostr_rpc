// Real-relay integration tests for NostrRpc.
//
// These tests exercise the full nostr_rpc communication flow over a REAL
// external Nostr relay at wss://nostr.001.j5s9.dev. All NIP-59 gift-wrap
// encryption is exercised end-to-end over the live network.
//
// Run with:
//   dart test --tags real_relay
// or:
//   dart test test/integration/real_relay_test.dart
//
// These tests are excluded from default `dart test` runs via the @Tags annotation
// combined with the dart_test.yaml configuration.

@Tags(['real_relay'])
library;

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';

import 'package:nostr_rpc/nostr_rpc.dart';

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const _relayUrl = 'wss://nostr.001.j5s9.dev';

// ---------------------------------------------------------------------------
// Helper: wait with timeout (30s for real network latency + NIP-59 overhead)
// ---------------------------------------------------------------------------

Future<T> _withTimeout<T>(Future<T> future, {int seconds = 30}) {
  return Future.any([
    future,
    Future.delayed(
      Duration(seconds: seconds),
      () => throw TimeoutException('Timed out after $seconds seconds'),
    ),
  ]);
}

void main() {
  group('NostrRpc — real relay integration', () {
    // -----------------------------------------------------------------------
    // Test 1: Alice → Bob ping/pong
    // -----------------------------------------------------------------------

    test('Test 1: Alice → Bob RPC call returns pong', () async {
      final aliceIdentity = NostrIdentity.generate();
      final bobIdentity = NostrIdentity.generate();

      final alice = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: aliceIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      final bob = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: bobIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );

      await alice.start();
      await bob.start();

      // Let relay subscriptions take effect before sending messages.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      try {
        // Bob listens for inbound connections and registers 'ping'.
        final bobPeerConnected = Completer<JsonRpcConnection>();
        bob.onPeerConnected.listen((conn) {
          if (!bobPeerConnected.isCompleted) {
            conn.registerMethod('ping', (_) => 'pong');
            bobPeerConnected.complete(conn);
          }
        });

        // Alice opens outbound connection to Bob and sends a request.
        final aliceConnToBob = alice.getOrCreateConnection(
          bobIdentity.pubkeyHex,
        );

        final response = await _withTimeout(
          aliceConnToBob.sendRequest('ping', []),
        );

        expect(response, equals('pong'));

        // Ensure Bob's onPeerConnected fired with Alice's pubkey.
        final bobConn = await _withTimeout(bobPeerConnected.future);
        expect(bobConn.peerPubkeyHex, equals(aliceIdentity.pubkeyHex));
      } finally {
        try {
          await alice.dispose();
        } catch (_) {}
        try {
          await bob.dispose();
        } catch (_) {}
      }
    });

    // -----------------------------------------------------------------------
    // Test 2: Bidirectional RPC
    // -----------------------------------------------------------------------

    test('Test 2: Bidirectional RPC (Alice↔Bob)', () async {
      final aliceIdentity = NostrIdentity.generate();
      final bobIdentity = NostrIdentity.generate();

      final alice = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: aliceIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      final bob = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: bobIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );

      await alice.start();
      await bob.start();

      await Future<void>.delayed(const Duration(milliseconds: 500));

      try {
        // Bob listens for inbound and registers 'ping'.
        final bobPeerConnected = Completer<JsonRpcConnection>();
        bob.onPeerConnected.listen((conn) {
          if (!bobPeerConnected.isCompleted) {
            conn.registerMethod('ping', (_) => 'pong from bob');
            bobPeerConnected.complete(conn);
          }
        });

        // Alice opens outbound to Bob; also registers a method for Bob to call back.
        final aliceConnToBob = alice.getOrCreateConnection(
          bobIdentity.pubkeyHex,
        );
        aliceConnToBob.registerMethod('hello', (_) => 'hello from alice');

        // Alice → Bob ping.
        final aliceToBobResponse = await _withTimeout(
          aliceConnToBob.sendRequest('ping', []),
        );
        expect(aliceToBobResponse, equals('pong from bob'));

        // Wait until Bob has Alice's inbound connection.
        final bobConnToAlice = await _withTimeout(bobPeerConnected.future);
        expect(bobConnToAlice.peerPubkeyHex, equals(aliceIdentity.pubkeyHex));

        // Bob → Alice hello.
        final bobToAliceResponse = await _withTimeout(
          bobConnToAlice.sendRequest('hello', []),
        );
        expect(bobToAliceResponse, equals('hello from alice'));
      } finally {
        try {
          await alice.dispose();
        } catch (_) {}
        try {
          await bob.dispose();
        } catch (_) {}
      }
    });

    // -----------------------------------------------------------------------
    // Test 3: Notification (fire-and-forget)
    // -----------------------------------------------------------------------

    test('Test 3: Notification — Bob handler fires without response', () async {
      final aliceIdentity = NostrIdentity.generate();
      final bobIdentity = NostrIdentity.generate();

      final alice = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: aliceIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      final bob = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: bobIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );

      await alice.start();
      await bob.start();

      await Future<void>.delayed(const Duration(milliseconds: 500));

      try {
        final notificationReceived = Completer<String>();

        // Bob listens for inbound and registers a notification handler.
        bob.onPeerConnected.listen((conn) {
          conn.registerMethod('alert', (rpc.Parameters params) {
            if (!notificationReceived.isCompleted) {
              notificationReceived.complete(params['message'].value as String);
            }
          });
        });

        // Alice opens connection to Bob and sends notification (fire-and-forget).
        final aliceConnToBob = alice.getOrCreateConnection(
          bobIdentity.pubkeyHex,
        );
        aliceConnToBob.sendNotification('alert', {
          'message': 'hello from alice',
        });

        final received = await _withTimeout(notificationReceived.future);
        expect(received, equals('hello from alice'));
      } finally {
        try {
          await alice.dispose();
        } catch (_) {}
        try {
          await bob.dispose();
        } catch (_) {}
      }
    });

    // -----------------------------------------------------------------------
    // Test 4: Multi-peer (Alice talks to Bob and Charlie)
    // -----------------------------------------------------------------------

    test('Test 4: Alice talks to two separate peers', () async {
      final aliceIdentity = NostrIdentity.generate();
      final bobIdentity = NostrIdentity.generate();
      final charlieIdentity = NostrIdentity.generate();

      final alice = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: aliceIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      final bob = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: bobIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      final charlie = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: charlieIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );

      await alice.start();
      await bob.start();
      await charlie.start();

      await Future<void>.delayed(const Duration(milliseconds: 500));

      try {
        // Bob and Charlie register 'whoami' on inbound connections.
        bob.onPeerConnected.listen((conn) {
          conn.registerMethod('whoami', (_) => 'i am bob');
        });
        charlie.onPeerConnected.listen((conn) {
          conn.registerMethod('whoami', (_) => 'i am charlie');
        });

        final aliceConnToBob = alice.getOrCreateConnection(
          bobIdentity.pubkeyHex,
        );
        final aliceConnToCharlie = alice.getOrCreateConnection(
          charlieIdentity.pubkeyHex,
        );

        final bobResponse = await _withTimeout(
          aliceConnToBob.sendRequest('whoami', []),
        );
        final charlieResponse = await _withTimeout(
          aliceConnToCharlie.sendRequest('whoami', []),
        );

        expect(bobResponse, equals('i am bob'));
        expect(charlieResponse, equals('i am charlie'));
        expect(alice.connections, hasLength(2));
      } finally {
        try {
          await alice.dispose();
        } catch (_) {}
        try {
          await bob.dispose();
        } catch (_) {}
        try {
          await charlie.dispose();
        } catch (_) {}
      }
    });

    // -----------------------------------------------------------------------
    // Test 5: Error propagation
    // -----------------------------------------------------------------------

    test('Test 5: Bob throws RpcException — Alice receives error', () async {
      final aliceIdentity = NostrIdentity.generate();
      final bobIdentity = NostrIdentity.generate();

      final alice = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: aliceIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      final bob = NostrRpc<JsonRpcConnection>(
        relays: [_relayUrl],
        identity: bobIdentity,
        protocol: JsonRpcProtocol(),
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );

      await alice.start();
      await bob.start();

      await Future<void>.delayed(const Duration(milliseconds: 500));

      try {
        // Bob registers a method that always throws.
        bob.onPeerConnected.listen((conn) {
          conn.registerMethod('fail', (_) {
            throw rpc.RpcException(42, 'deliberate failure');
          });
        });

        final aliceConnToBob = alice.getOrCreateConnection(
          bobIdentity.pubkeyHex,
        );

        Object? caughtError;
        try {
          await _withTimeout(aliceConnToBob.sendRequest('fail', []));
        } catch (e) {
          caughtError = e;
        }

        expect(caughtError, isA<rpc.RpcException>());
        final rpcError = caughtError as rpc.RpcException;
        expect(rpcError.code, equals(42));
        expect(rpcError.message, equals('deliberate failure'));
      } finally {
        try {
          await alice.dispose();
        } catch (_) {}
        try {
          await bob.dispose();
        } catch (_) {}
      }
    });
  });
}
