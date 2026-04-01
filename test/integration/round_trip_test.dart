// Round-trip integration tests for NostrRpc.
//
// Alice and Bob each run a real NostrRpc instance connected to an in-process
// MockRelay via real WebSocket connections (dart:io). All NIP-59 gift-wrap
// encryption is exercised end-to-end.
//
// Test setup:
//   - MockRelay starts on a random port before each test.
//   - Alice and Bob each call nostrRpc.start() with relay.wsUrl.
//   - Teardown: both call dispose(), then relay.stop().

import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';

import 'package:nostr_rpc/src/core/nostr_rpc.dart';
import 'package:nostr_rpc/src/core/acceptance_strategy.dart';
import 'package:nostr_rpc/src/identity.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_protocol.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_with_sequence_cache_protocol.dart';

import 'mock_relay.dart';

// ---------------------------------------------------------------------------
// Helper: wait with timeout
// ---------------------------------------------------------------------------

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
  group('NostrRpc — round-trip integration', () {
    late MockRelay relay;
    late NostrIdentity aliceIdentity;
    late NostrIdentity bobIdentity;
    late NostrRpc<JsonRpcConnection> alice;
    late NostrRpc<JsonRpcConnection> bob;

    setUp(() async {
      relay = MockRelay();
      await relay.start();

      aliceIdentity = NostrIdentity.generate();
      bobIdentity = NostrIdentity.generate();

      alice = NostrRpc<JsonRpcConnection>(
        relays: [relay.wsUrl],
        identity: aliceIdentity,
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      bob = NostrRpc<JsonRpcConnection>(
        relays: [relay.wsUrl],
        identity: bobIdentity,
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );

      await alice.start();
      await bob.start();
    });

    tearDown(() async {
      try {
        await alice.dispose();
      } catch (_) {}
      try {
        await bob.dispose();
      } catch (_) {}
      await relay.stop();
    });

    // -----------------------------------------------------------------------
    // Test 1: Alice calls a method on Bob, receives pong.
    // -----------------------------------------------------------------------

    test('Test 1: Alice → Bob RPC call returns pong', () async {
      // Set up Bob to receive Alice's inbound connection and register 'ping'.
      final bobPeerConnected = Completer<JsonRpcConnection>();
      bob.onPeerConnected.listen((conn) {
        if (!bobPeerConnected.isCompleted) {
          conn.registerMethod('ping', (_) => 'pong');
          bobPeerConnected.complete(conn);
        }
      });

      // Alice opens outbound connection to Bob and sends a request.
      // The NIP-59 gift-wrapped event travels: Alice → relay → Bob.
      final aliceConnToBob = alice.getOrCreateConnection(bobIdentity.pubkeyHex);

      // Small delay to let Alice's first message reach Bob and trigger onPeerConnected.
      // Bob will then register 'ping' and process the request.

      // Send the ping request.
      final response = await _withTimeout(
        aliceConnToBob.sendRequest('ping', []),
      );

      expect(response, equals('pong'));

      // Ensure Bob's onPeerConnected fired with Alice's pubkey.
      final bobConn = await _withTimeout(bobPeerConnected.future);
      expect(bobConn.peerPubkeyHex, equals(aliceIdentity.pubkeyHex));
    });

    // -----------------------------------------------------------------------
    // Test 2: Bidirectional — Bob also calls a method on Alice.
    // -----------------------------------------------------------------------

    test('Test 2: Bidirectional RPC (Alice↔Bob)', () async {
      // Set up Bob to accept inbound and register 'ping'.
      final bobPeerConnected = Completer<JsonRpcConnection>();
      bob.onPeerConnected.listen((conn) {
        if (!bobPeerConnected.isCompleted) {
          conn.registerMethod('ping', (_) => 'pong from bob');
          bobPeerConnected.complete(conn);
        }
      });

      // Alice opens outbound to Bob; also registers a method for Bob to call back.
      final aliceConnToBob = alice.getOrCreateConnection(bobIdentity.pubkeyHex);
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
    });

    // -----------------------------------------------------------------------
    // Test 3: JsonRpcWithSequenceCacheProtocol — 5 rapid messages in order.
    // -----------------------------------------------------------------------

    test(
      'Test 3: SequenceCache protocol — 5 rapid requests all succeed',
      () async {
        // Create fresh instances using JsonRpcWithSequenceCacheProtocol.
        late NostrRpc<JsonRpcConnection> aliceSeq;
        late NostrRpc<JsonRpcConnection> bobSeq;

        aliceSeq = NostrRpc<JsonRpcConnection>(
          relays: [relay.wsUrl],
          identity: NostrIdentity.generate(),
          protocol: JsonRpcWithSequenceCacheProtocol(
            timeout: const Duration(seconds: 5),
          ),
          acceptanceStrategy: AlwaysAcceptStrategy(),
        );
        bobSeq = NostrRpc<JsonRpcConnection>(
          relays: [relay.wsUrl],
          identity: NostrIdentity.generate(),
          protocol: JsonRpcWithSequenceCacheProtocol(
            timeout: const Duration(seconds: 5),
          ),
          acceptanceStrategy: AlwaysAcceptStrategy(),
        );

        await aliceSeq.start();
        await bobSeq.start();

        try {
          // Bob registers an echo method.
          final bobConnected = Completer<JsonRpcConnection>();
          bobSeq.onPeerConnected.listen((conn) {
            if (!bobConnected.isCompleted) {
              conn.registerMethod('echo', (rpc.Parameters params) {
                return params[0].value;
              });
              bobConnected.complete(conn);
            }
          });

          final aliceConn = aliceSeq.getOrCreateConnection(
            bobSeq.identity.pubkeyHex,
          );

          // Fire 5 requests rapidly — sequence cache ordering ensures delivery order.
          final futures = List.generate(
            5,
            (i) => aliceConn.sendRequest('echo', [i]),
          );

          final results = await _withTimeout(Future.wait(futures));
          expect(results, equals([0, 1, 2, 3, 4]));
        } finally {
          try {
            await aliceSeq.dispose();
          } catch (_) {}
          try {
            await bobSeq.dispose();
          } catch (_) {}
        }
      },
    );

    // -----------------------------------------------------------------------
    // Test 4: Alice sends notification (no response) — Bob's handler fires.
    // -----------------------------------------------------------------------

    test('Test 4: Notification — Bob handler fires without response', () async {
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
      final aliceConnToBob = alice.getOrCreateConnection(bobIdentity.pubkeyHex);
      aliceConnToBob.sendNotification('alert', {'message': 'hello bob!'});

      final received = await _withTimeout(notificationReceived.future);
      expect(received, equals('hello bob!'));
    });

    // -----------------------------------------------------------------------
    // Test 5: Multiple peers — Alice calls both Bob and Charlie.
    // -----------------------------------------------------------------------

    test('Test 5: Alice talks to two separate peers', () async {
      final charlieIdentity = NostrIdentity.generate();
      final charlie = NostrRpc<JsonRpcConnection>(
        relays: [relay.wsUrl],
        identity: charlieIdentity,
        acceptanceStrategy: AlwaysAcceptStrategy(),
      );
      await charlie.start();

      try {
        // Set up Bob and Charlie to register methods on inbound.
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
          await charlie.dispose();
        } catch (_) {}
      }
    });

    // -----------------------------------------------------------------------
    // Test 6: Error response — Bob throws, Alice receives RPC error.
    // -----------------------------------------------------------------------

    test('Test 6: Bob throws RpcException — Alice receives error', () async {
      bob.onPeerConnected.listen((conn) {
        conn.registerMethod('fail', (_) {
          throw rpc.RpcException(42, 'deliberate failure');
        });
      });

      final aliceConnToBob = alice.getOrCreateConnection(bobIdentity.pubkeyHex);

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
    });
  });
}
