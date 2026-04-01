import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';

import 'package:nostr_rpc/src/core/nostr_rpc.dart';
import 'package:nostr_rpc/src/core/acceptance_strategy.dart';
import 'package:nostr_rpc/src/protocol/rpc_protocol.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_protocol.dart';
import 'package:nostr_rpc/src/transport/relay_manager.dart';
import 'package:nostr_rpc/src/crypto/event.dart';
import 'package:nostr_rpc/src/crypto/nip59.dart';
import 'package:nostr_rpc/src/identity.dart';

// ---------------------------------------------------------------------------
// Mock RelayManager (same pattern as nostr_rpc_test.dart, inline copy)
// ---------------------------------------------------------------------------

class _MockRelayManager extends RelayManager {
  _MockRelayManager() : super([]);

  final StreamController<NostrEvent> _eventsController =
      StreamController<NostrEvent>.broadcast();
  final List<NostrEvent> published = [];
  bool connectAllCalled = false;
  bool disconnectAllCalled = false;
  final List<String> subscriptions = [];
  final List<String> unsubscriptions = [];

  @override
  Stream<NostrEvent> get events => _eventsController.stream;

  @override
  Future<void> connectAll() async {
    connectAllCalled = true;
  }

  @override
  Future<void> disconnectAll() async {
    disconnectAllCalled = true;
    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  @override
  void subscribe(String subscriptionId, List<Map<String, dynamic>> filters) {
    subscriptions.add(subscriptionId);
  }

  @override
  void unsubscribe(String subscriptionId) {
    unsubscriptions.add(subscriptionId);
  }

  @override
  Future<void> publish(NostrEvent event) async {
    published.add(event);
  }

  void injectEvent(NostrEvent event) {
    _eventsController.add(event);
  }

  Future<void> closeEvents() => _eventsController.close();
}

// ---------------------------------------------------------------------------
// Inline MockConnection + MockProtocol for custom protocol generic tests
// ---------------------------------------------------------------------------

class MockConnection extends RpcConnection {
  MockConnection({
    required this.peerPubkeyHex,
    required Stream<String> incoming,
    required StreamSink<String> outgoing,
  }) : _outgoing = outgoing {
    _subscription = incoming.listen((msg) => received.add(msg));
  }

  @override
  final String peerPubkeyHex;

  final StreamSink<String> _outgoing;
  late final StreamSubscription<String> _subscription;

  final List<String> received = [];
  bool _closed = false;

  bool get isClosed => _closed;

  void send(String message) {
    if (!_closed) _outgoing.add(message);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
  }
}

class MockProtocol extends RpcProtocol<MockConnection> {
  final List<MockConnection> created = [];

  @override
  MockConnection createConnection(String peerPubkeyHex, RawChannel channel) {
    final conn = MockConnection(
      peerPubkeyHex: peerPubkeyHex,
      incoming: channel.incoming,
      outgoing: channel.outgoing,
    );
    created.add(conn);
    return conn;
  }
}

// ---------------------------------------------------------------------------
// Helper: build a NIP-59 gift-wrapped NostrEvent
// ---------------------------------------------------------------------------

Future<NostrEvent> _buildGiftWrap({
  required NostrIdentity sender,
  required NostrIdentity recipient,
  required String content,
}) async {
  final giftWrap = await Nip59.wrap(
    content: content,
    senderPrivkeyBytes: sender.privkeyBytes,
    senderPubkeyHex: sender.pubkeyHex,
    recipientPubkeyHex: recipient.pubkeyHex,
  );
  return NostrEvent.fromJson(giftWrap.toJson());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Multi-peer tests
  // -------------------------------------------------------------------------

  group('NostrRpc — multi-peer inbound', () {
    test(
      'two senders → two separate connections in connections list',
      () async {
        final identity = NostrIdentity.generate();
        final peerA = NostrIdentity.generate();
        final peerB = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        // Inject events from two different senders.
        final eventA = await _buildGiftWrap(
          sender: peerA,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
        );
        final eventB = await _buildGiftWrap(
          sender: peerB,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
        );

        mockRelay.injectEvent(eventA);
        mockRelay.injectEvent(eventB);

        await Future.delayed(const Duration(milliseconds: 100));

        expect(nostrRpc.connections, hasLength(2));

        final pubkeys =
            nostrRpc.connections.map((c) => c.peerPubkeyHex).toSet();
        expect(pubkeys, containsAll([peerA.pubkeyHex, peerB.pubkeyHex]));

        await nostrRpc.dispose();
      },
    );

    test('two senders → two distinct onPeerConnected emissions', () async {
      final identity = NostrIdentity.generate();
      final peerA = NostrIdentity.generate();
      final peerB = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      final connectedPubkeys = <String>[];
      nostrRpc.onPeerConnected.listen((conn) {
        connectedPubkeys.add(conn.peerPubkeyHex);
      });

      final eventA = await _buildGiftWrap(
        sender: peerA,
        recipient: identity,
        content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
      );
      final eventB = await _buildGiftWrap(
        sender: peerB,
        recipient: identity,
        content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":2}',
      );

      mockRelay.injectEvent(eventA);
      mockRelay.injectEvent(eventB);

      await Future.delayed(const Duration(milliseconds: 100));

      expect(connectedPubkeys, hasLength(2));
      expect(connectedPubkeys, containsAll([peerA.pubkeyHex, peerB.pubkeyHex]));

      await nostrRpc.dispose();
    });

    test('getOrCreateConnection for multiple peers — all tracked', () async {
      final identity = NostrIdentity.generate();
      final peerA = NostrIdentity.generate();
      final peerB = NostrIdentity.generate();
      final peerC = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      nostrRpc.getOrCreateConnection(peerA.pubkeyHex);
      nostrRpc.getOrCreateConnection(peerB.pubkeyHex);
      nostrRpc.getOrCreateConnection(peerC.pubkeyHex);

      expect(nostrRpc.connections, hasLength(3));

      final pubkeys = nostrRpc.connections.map((c) => c.peerPubkeyHex).toSet();
      expect(
        pubkeys,
        containsAll([peerA.pubkeyHex, peerB.pubkeyHex, peerC.pubkeyHex]),
      );

      await nostrRpc.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Custom protocol / generics
  // -------------------------------------------------------------------------

  group('NostrRpc — custom protocol (MockProtocol)', () {
    test(
      'NostrRpc<MockConnection> with MockProtocol — emits MockConnection on onPeerConnected',
      () async {
        final identity = NostrIdentity.generate();
        final peerIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();
        final mockProtocol = MockProtocol();

        final nostrRpc = NostrRpc<MockConnection>(
          relays: [],
          identity: identity,
          protocol: mockProtocol,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final connectedPeers = <MockConnection>[];
        nostrRpc.onPeerConnected.listen((conn) => connectedPeers.add(conn));

        final event = await _buildGiftWrap(
          sender: peerIdentity,
          recipient: identity,
          content: 'hello custom protocol',
        );
        mockRelay.injectEvent(event);

        await Future.delayed(const Duration(milliseconds: 50));

        expect(connectedPeers, hasLength(1));
        expect(connectedPeers.first, isA<MockConnection>());
        expect(
          connectedPeers.first.peerPubkeyHex,
          equals(peerIdentity.pubkeyHex),
        );

        await nostrRpc.dispose();
      },
    );

    test(
      'MockProtocol.createConnection is called once per unique peer',
      () async {
        final identity = NostrIdentity.generate();
        final peerA = NostrIdentity.generate();
        final peerB = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();
        final mockProtocol = MockProtocol();

        final nostrRpc = NostrRpc<MockConnection>(
          relays: [],
          identity: identity,
          protocol: mockProtocol,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final event1 = await _buildGiftWrap(
          sender: peerA,
          recipient: identity,
          content: 'msg1',
        );
        final event2 = await _buildGiftWrap(
          sender: peerA,
          recipient: identity,
          content: 'msg2',
        );
        final event3 = await _buildGiftWrap(
          sender: peerB,
          recipient: identity,
          content: 'msg3',
        );

        mockRelay.injectEvent(event1);
        mockRelay.injectEvent(event2);
        mockRelay.injectEvent(event3);

        await Future.delayed(const Duration(milliseconds: 100));

        // createConnection called once per unique peer
        expect(mockProtocol.created, hasLength(2));

        await nostrRpc.dispose();
      },
    );

    test('inbound content delivered to MockConnection.received', () async {
      final identity = NostrIdentity.generate();
      final peerIdentity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();
      final mockProtocol = MockProtocol();

      final nostrRpc = NostrRpc<MockConnection>(
        relays: [],
        identity: identity,
        protocol: mockProtocol,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      final event = await _buildGiftWrap(
        sender: peerIdentity,
        recipient: identity,
        content: 'raw message content',
      );
      mockRelay.injectEvent(event);

      await Future.delayed(const Duration(milliseconds: 100));

      expect(mockProtocol.created, hasLength(1));
      expect(
        mockProtocol.created.first.received,
        contains('raw message content'),
      );

      await nostrRpc.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Bidirectional JSON-RPC
  // -------------------------------------------------------------------------

  group('NostrRpc — bidirectional JSON-RPC', () {
    test('both sides can call methods on each other', () async {
      final identityA = NostrIdentity.generate();
      final identityB = NostrIdentity.generate();
      final relayA = _MockRelayManager();
      final relayB = _MockRelayManager();

      // Wire relayA.publish → relayB.injectEvent and vice versa.
      relayA.published.clear();
      relayB.published.clear();

      final nostrRpcA = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identityA,
        relayManager: relayA,
      );
      final nostrRpcB = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identityB,
        relayManager: relayB,
      );

      await nostrRpcA.start();
      await nostrRpcB.start();

      // A gets outbound connection to B (not used directly — test uses paired channels below).
      nostrRpcA.getOrCreateConnection(identityB.pubkeyHex);

      // B registers a method.
      final connBfromA = nostrRpcB.getOrCreateConnection(identityA.pubkeyHex);
      connBfromA.registerMethod('greet', (rpc.Parameters params) {
        return 'Hello, ${params['name'].value}!';
      });

      // To simulate A→B: we need A's outgoing message (gift-wrapped to B)
      // delivered to B's event stream. Since relay publish is captured in
      // relayA.published, we need to unwrap + re-inject to relayB.
      // For a simpler integration test, we use paired in-memory channels
      // that bypass NIP-59 encryption — directly wire connections together.

      // Use JsonRpcProtocol with paired channels to test bidirectional RPC
      // without NIP-59 overhead.
      final protocol = JsonRpcProtocol();

      final ctrlAtoB = StreamController<String>.broadcast();
      final ctrlBtoA = StreamController<String>.broadcast();

      final channelA = RawChannel(ctrlBtoA.stream, ctrlAtoB.sink);
      final channelB = RawChannel(ctrlAtoB.stream, ctrlBtoA.sink);

      final directConnA = protocol.createConnection(
        identityB.pubkeyHex,
        channelA,
      );
      final directConnB = protocol.createConnection(
        identityA.pubkeyHex,
        channelB,
      );

      // B side registers methods.
      directConnB.registerMethod('greet', (rpc.Parameters params) {
        return 'Hello, ${params["name"].value}!';
      });

      // A side registers methods.
      directConnA.registerMethod('farewell', (rpc.Parameters params) {
        return 'Goodbye, ${params["name"].value}!';
      });

      // A calls B.
      final responseFromB = await directConnA
          .sendRequest('greet', {'name': 'Alice'})
          .timeout(const Duration(seconds: 5));

      expect(responseFromB, equals('Hello, Alice!'));

      // B calls A.
      final responseFromA = await directConnB
          .sendRequest('farewell', {'name': 'Bob'})
          .timeout(const Duration(seconds: 5));

      expect(responseFromA, equals('Goodbye, Bob!'));

      await directConnA.close();
      await directConnB.close();
      await ctrlAtoB.close();
      await ctrlBtoA.close();
      await nostrRpcA.dispose();
      await nostrRpcB.dispose();
    });
  });

  // -------------------------------------------------------------------------
  // Notification test
  // -------------------------------------------------------------------------

  group('NostrRpc — notifications', () {
    test(
      'sendNotification arrives on the other side without response',
      () async {
        final protocol = JsonRpcProtocol();

        final ctrlAtoB = StreamController<String>.broadcast();
        final ctrlBtoA = StreamController<String>.broadcast();

        final channelA = RawChannel(ctrlBtoA.stream, ctrlAtoB.sink);
        final channelB = RawChannel(ctrlAtoB.stream, ctrlBtoA.sink);

        final connA = protocol.createConnection('peerB', channelA);
        final connB = protocol.createConnection('peerA', channelB);

        final notificationsReceived = <Map<String, dynamic>>[];

        connB.registerMethod('event', (rpc.Parameters params) {
          notificationsReceived.add({
            'type': params['type'].value,
            'data': params['data'].value,
          });
        });

        connA.sendNotification('event', {
          'type': 'update',
          'data': 'payload-xyz',
        });

        await Future.delayed(const Duration(milliseconds: 50));

        expect(notificationsReceived, hasLength(1));
        expect(notificationsReceived.first['type'], equals('update'));
        expect(notificationsReceived.first['data'], equals('payload-xyz'));

        await connA.close();
        await connB.close();
        await ctrlAtoB.close();
        await ctrlBtoA.close();
      },
    );

    test('multiple notifications all arrive in order', () async {
      final protocol = JsonRpcProtocol();

      final ctrlAtoB = StreamController<String>.broadcast();
      final ctrlBtoA = StreamController<String>.broadcast();

      final channelA = RawChannel(ctrlBtoA.stream, ctrlAtoB.sink);
      final channelB = RawChannel(ctrlAtoB.stream, ctrlBtoA.sink);

      final connA = protocol.createConnection('peerB', channelA);
      final connB = protocol.createConnection('peerA', channelB);

      final received = <int>[];
      connB.registerMethod('tick', (rpc.Parameters params) {
        received.add(params['n'].value as int);
      });

      for (var i = 1; i <= 5; i++) {
        connA.sendNotification('tick', {'n': i});
      }

      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, equals([1, 2, 3, 4, 5]));

      await connA.close();
      await connB.close();
      await ctrlAtoB.close();
      await ctrlBtoA.close();
    });
  });

  // -------------------------------------------------------------------------
  // CachedApprovalStrategy integration
  // -------------------------------------------------------------------------

  group('NostrRpc — CachedApprovalStrategy integration', () {
    test(
      'callback called only once for same peer (second event uses cache)',
      () async {
        final identity = NostrIdentity.generate();
        final peerIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        int callbackCount = 0;
        final strategy = CachedApprovalStrategy(
          onNewPeer: (pubkey) async {
            callbackCount++;
            return true;
          },
        );

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          acceptanceStrategy: strategy,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final event1 = await _buildGiftWrap(
          sender: peerIdentity,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
        );
        final event2 = await _buildGiftWrap(
          sender: peerIdentity,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"pong","params":[],"id":2}',
        );

        mockRelay.injectEvent(event1);
        await Future.delayed(const Duration(milliseconds: 50));

        mockRelay.injectEvent(event2);
        await Future.delayed(const Duration(milliseconds: 50));

        // Callback should have been called exactly once (cached on second event).
        expect(callbackCount, equals(1));
        // One connection established.
        expect(nostrRpc.connections, hasLength(1));

        await nostrRpc.dispose();
      },
    );

    test(
      'CachedApprovalStrategy — rejection is cached and peer stays rejected',
      () async {
        final identity = NostrIdentity.generate();
        final peerIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        int callbackCount = 0;
        final strategy = CachedApprovalStrategy(
          onNewPeer: (pubkey) async {
            callbackCount++;
            return false; // reject
          },
        );

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          acceptanceStrategy: strategy,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final connectedPeers = <JsonRpcConnection>[];
        nostrRpc.onPeerConnected.listen((conn) => connectedPeers.add(conn));

        for (var i = 1; i <= 3; i++) {
          final event = await _buildGiftWrap(
            sender: peerIdentity,
            recipient: identity,
            content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":$i}',
          );
          mockRelay.injectEvent(event);
          await Future.delayed(const Duration(milliseconds: 30));
        }

        // Callback called once, result cached as rejected.
        expect(callbackCount, equals(1));
        // No connection established.
        expect(connectedPeers, isEmpty);
        expect(nostrRpc.connections, isEmpty);

        await nostrRpc.dispose();
      },
    );
  });

  // -------------------------------------------------------------------------
  // Connection lifecycle
  // -------------------------------------------------------------------------

  group('NostrRpc — connection lifecycle', () {
    test(
      'after connection.close(), connection remains in connections map',
      () async {
        final identity = NostrIdentity.generate();
        final peerIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final conn = nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);
        expect(nostrRpc.connections, hasLength(1));

        // Close the connection.
        await conn.close();

        // NostrRpc does NOT auto-remove closed connections.
        expect(nostrRpc.connections, hasLength(1));
        expect(nostrRpc.getConnection(peerIdentity.pubkeyHex), same(conn));

        await nostrRpc.dispose();
      },
    );

    test(
      'getOrCreateConnection returns same instance before and after close()',
      () async {
        final identity = NostrIdentity.generate();
        final peerIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final conn1 = nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);
        await conn1.close();

        // After closing, getOrCreateConnection returns the SAME instance (cached).
        final conn2 = nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);
        expect(identical(conn1, conn2), isTrue);

        await nostrRpc.dispose();
      },
    );

    test('dispose() after connection.close() does not throw', () async {
      final identity = NostrIdentity.generate();
      final peerIdentity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      final conn = nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);
      await conn.close();

      // dispose() after individual connection close should not throw.
      Object? thrown;
      try {
        await nostrRpc.dispose();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // identity accessor
  // -------------------------------------------------------------------------

  group('NostrRpc — identity', () {
    test('identity getter returns the provided identity', () async {
      final identity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      expect(nostrRpc.identity.pubkeyHex, equals(identity.pubkeyHex));

      await nostrRpc.dispose();
    });
  });
}
