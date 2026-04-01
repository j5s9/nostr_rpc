import 'dart:async';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/core/nostr_rpc.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_protocol.dart';
import 'package:nostr_rpc/src/transport/relay_manager.dart';
import 'package:nostr_rpc/src/crypto/event.dart';
import 'package:nostr_rpc/src/crypto/nip59.dart';
import 'package:nostr_rpc/src/identity.dart';
import 'package:nostr_rpc/src/core/acceptance_strategy.dart';
// ---------------------------------------------------------------------------
// Mock RelayManager
// ---------------------------------------------------------------------------

/// A mock RelayManager that doesn't open any real WebSocket connections.
/// It exposes methods to manually inject events and inspect published events.
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

  /// Inject a fake NostrEvent into the events stream.
  void injectEvent(NostrEvent event) {
    _eventsController.add(event);
  }

  /// Close the mock event stream.
  Future<void> closeEvents() => _eventsController.close();
}

// ---------------------------------------------------------------------------
// Helper: build a fake gift-wrap NostrEvent for a given sender→recipient pair
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
  // Convert GiftWrapEvent → NostrEvent
  return NostrEvent.fromJson(giftWrap.toJson());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('NostrRpc — start()', () {
    test('start() calls connectAll() and subscribes', () async {
      final identity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      expect(mockRelay.connectAllCalled, isTrue);
      expect(mockRelay.subscriptions, contains('nostr_rpc'));

      await nostrRpc.dispose();
    });
  });

  group('NostrRpc — inbound connections', () {
    test('incoming event from new peer → onPeerConnected emits', () async {
      final identity = NostrIdentity.generate();
      final senderIdentity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      final connectedPeers = <JsonRpcConnection>[];
      nostrRpc.onPeerConnected.listen((conn) => connectedPeers.add(conn));

      // Inject a valid gift-wrapped event from senderIdentity to identity.
      final event = await _buildGiftWrap(
        sender: senderIdentity,
        recipient: identity,
        content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
      );
      mockRelay.injectEvent(event);

      // Allow async processing.
      await Future.delayed(const Duration(milliseconds: 50));

      expect(connectedPeers, hasLength(1));
      expect(
        connectedPeers.first.peerPubkeyHex,
        equals(senderIdentity.pubkeyHex),
      );

      await nostrRpc.dispose();
    });

    test(
      'second event from same peer → onPeerConnected does NOT emit again',
      () async {
        final identity = NostrIdentity.generate();
        final senderIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final connectedPeers = <JsonRpcConnection>[];
        nostrRpc.onPeerConnected.listen((conn) => connectedPeers.add(conn));

        // First event.
        final event1 = await _buildGiftWrap(
          sender: senderIdentity,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
        );
        mockRelay.injectEvent(event1);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(connectedPeers, hasLength(1));

        // Second event from the same sender.
        final event2 = await _buildGiftWrap(
          sender: senderIdentity,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"pong","params":[],"id":2}',
        );
        mockRelay.injectEvent(event2);
        await Future.delayed(const Duration(milliseconds: 50));

        // onPeerConnected should still only have been fired once.
        expect(connectedPeers, hasLength(1));
        // But only 1 connection entry.
        expect(nostrRpc.connections, hasLength(1));

        await nostrRpc.dispose();
      },
    );

    test(
      'acceptance strategy rejects peer → onPeerConnected does NOT emit',
      () async {
        final identity = NostrIdentity.generate();
        final senderIdentity = NostrIdentity.generate();
        final mockRelay = _MockRelayManager();

        // Rejection strategy.
        final rejectStrategy = AlwaysAskStrategy(onNewPeer: (_) async => false);

        final nostrRpc = NostrRpc<JsonRpcConnection>(
          relays: [],
          identity: identity,
          acceptanceStrategy: rejectStrategy,
          relayManager: mockRelay,
        );

        await nostrRpc.start();

        final connectedPeers = <JsonRpcConnection>[];
        nostrRpc.onPeerConnected.listen((conn) => connectedPeers.add(conn));

        final event = await _buildGiftWrap(
          sender: senderIdentity,
          recipient: identity,
          content: '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
        );
        mockRelay.injectEvent(event);
        await Future.delayed(const Duration(milliseconds: 50));

        expect(connectedPeers, isEmpty);
        expect(nostrRpc.connections, isEmpty);

        await nostrRpc.dispose();
      },
    );
  });

  group('NostrRpc — getOrCreateConnection()', () {
    test(
      'creates outbound connection without emitting onPeerConnected',
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

        final connectedPeers = <JsonRpcConnection>[];
        nostrRpc.onPeerConnected.listen((conn) => connectedPeers.add(conn));

        final conn = nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);

        expect(conn, isA<JsonRpcConnection>());
        expect(conn.peerPubkeyHex, equals(peerIdentity.pubkeyHex));

        // Wait to make sure no async event fires.
        await Future.delayed(const Duration(milliseconds: 30));

        // onPeerConnected should NOT have been called.
        expect(connectedPeers, isEmpty);
        // But the connection is tracked.
        expect(nostrRpc.connections, hasLength(1));

        await nostrRpc.dispose();
      },
    );

    test(
      'calling getOrCreateConnection twice returns same connection',
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
        final conn2 = nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);

        expect(identical(conn1, conn2), isTrue);
        expect(nostrRpc.connections, hasLength(1));

        await nostrRpc.dispose();
      },
    );
  });

  group('NostrRpc — getConnection()', () {
    test('returns null when no connection exists', () async {
      final identity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      expect(nostrRpc.getConnection('nonexistent_pubkey'), isNull);

      await nostrRpc.dispose();
    });

    test('returns connection after getOrCreateConnection', () async {
      final identity = NostrIdentity.generate();
      final peerIdentity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();

      nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);
      final conn = nostrRpc.getConnection(peerIdentity.pubkeyHex);

      expect(conn, isNotNull);
      expect(conn!.peerPubkeyHex, equals(peerIdentity.pubkeyHex));

      await nostrRpc.dispose();
    });
  });

  group('NostrRpc — dispose()', () {
    test('dispose() calls disconnectAll() on relay manager', () async {
      final identity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();
      await nostrRpc.dispose();

      expect(mockRelay.disconnectAllCalled, isTrue);
    });

    test('dispose() clears connections', () async {
      final identity = NostrIdentity.generate();
      final peerIdentity = NostrIdentity.generate();
      final mockRelay = _MockRelayManager();

      final nostrRpc = NostrRpc<JsonRpcConnection>(
        relays: [],
        identity: identity,
        relayManager: mockRelay,
      );

      await nostrRpc.start();
      nostrRpc.getOrCreateConnection(peerIdentity.pubkeyHex);
      expect(nostrRpc.connections, hasLength(1));

      await nostrRpc.dispose();

      expect(nostrRpc.connections, isEmpty);
    });
  });
}
