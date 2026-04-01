// Tests for RelayManager: multi-relay management with event deduplication.
//
// All tests use mock WebSocketChannels — no real relay connections.

import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:nostr_rpc/src/crypto/event.dart';
import 'package:nostr_rpc/src/transport/relay_manager.dart';

// ---------------------------------------------------------------------------
// Mock infrastructure (mirrors websocket_relay_client_test.dart pattern)
// ---------------------------------------------------------------------------

class _MockSink implements WebSocketSink {
  final List<String> messages = [];
  final Completer<void> _closeCompleter = Completer<void>();

  @override
  void add(dynamic data) => messages.add(data as String);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> get done => _closeCompleter.future;
}

class _MockWebSocketChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _MockWebSocketChannel({required this.incomingController, required this.sink});

  final StreamController<dynamic> incomingController;

  @override
  final _MockSink sink;

  @override
  Stream<dynamic> get stream => incomingController.stream;

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _eventJson({String? id, String? content}) => {
  'id': id ?? 'a' * 64,
  'pubkey': 'b' * 64,
  'created_at': 1700000000,
  'kind': 1,
  'tags': <List<String>>[],
  'content': content ?? 'hello nostr',
  'sig': 'c' * 128,
};

/// Encodes a relay → client EVENT frame: ["EVENT", subId, eventJson]
String _relayEventFrame(
  Map<String, dynamic> eventJson, [
  String subId = 'sub1',
]) => jsonEncode(['EVENT', subId, eventJson]);

// ---------------------------------------------------------------------------
// Multi-relay mock factory
// ---------------------------------------------------------------------------

/// Holds the mock infrastructure for a single relay endpoint.
class _RelayMock {
  _RelayMock()
    : incomingController = StreamController<dynamic>(),
      sink = _MockSink() {
    channel = _MockWebSocketChannel(
      incomingController: incomingController,
      sink: sink,
    );
  }

  final StreamController<dynamic> incomingController;
  final _MockSink sink;
  late final _MockWebSocketChannel channel;

  /// Simulates an incoming EVENT message from this relay.
  void sendEvent(Map<String, dynamic> eventJson, [String subId = 'sub1']) {
    incomingController.add(_relayEventFrame(eventJson, subId));
  }

  /// Closes the relay stream (simulates unexpected disconnect).
  Future<void> closeStream() => incomingController.close();
}

/// Builds a [RelayManager] with [count] mock relays.
///
/// Returns the manager and a list of [_RelayMock]s in the same order as their
/// URL indices (relay0, relay1, ...).
({RelayManager manager, List<_RelayMock> mocks}) _buildManager(int count) {
  final mocks = List.generate(count, (_) => _RelayMock());
  int callIndex = 0;

  final manager = RelayManager(
    List.generate(count, (i) => 'ws://relay$i'),
    channelFactory: (uri) {
      final idx = callIndex++;
      return mocks[idx].channel;
    },
  );

  return (manager: manager, mocks: mocks);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RelayManager — connectAll()', () {
    test(
      'connects to all relays → connectedRelays has expected count',
      () async {
        final (:manager, :mocks) = _buildManager(3);
        await manager.connectAll();

        expect(manager.connectedRelays, hasLength(3));
        expect(
          manager.connectedRelays,
          containsAll(['ws://relay0', 'ws://relay1', 'ws://relay2']),
        );

        await manager.disconnectAll();
        for (final m in mocks) {
          await m.closeStream();
        }
      },
    );

    test('single relay connects successfully', () async {
      final (:manager, :mocks) = _buildManager(1);
      await manager.connectAll();

      expect(manager.connectedRelays, hasLength(1));
      expect(manager.connectedRelays.first, equals('ws://relay0'));

      await manager.disconnectAll();
      await mocks[0].closeStream();
    });
  });

  group('RelayManager — publish()', () {
    test('publishes event to all connected relays', () async {
      final (:manager, :mocks) = _buildManager(2);
      await manager.connectAll();

      final event = NostrEvent.fromJson(_eventJson());
      await manager.publish(event);

      for (final mock in mocks) {
        expect(mock.sink.messages, hasLength(1));
        final decoded = jsonDecode(mock.sink.messages.first) as List<dynamic>;
        expect(decoded[0], equals('EVENT'));
        expect((decoded[1] as Map<String, dynamic>)['id'], equals('a' * 64));
      }

      await manager.disconnectAll();
      for (final m in mocks) {
        await m.closeStream();
      }
    });
  });

  group('RelayManager — subscribe()', () {
    test('sends REQ to all connected relays', () async {
      final (:manager, :mocks) = _buildManager(3);
      await manager.connectAll();

      manager.subscribe('sub1', [
        {
          'kinds': [1],
        },
      ]);

      for (final mock in mocks) {
        expect(mock.sink.messages, hasLength(1));
        final decoded = jsonDecode(mock.sink.messages.first) as List<dynamic>;
        expect(decoded[0], equals('REQ'));
        expect(decoded[1], equals('sub1'));
        expect(
          decoded[2],
          equals({
            'kinds': [1],
          }),
        );
      }

      await manager.disconnectAll();
      for (final m in mocks) {
        await m.closeStream();
      }
    });

    test('unsubscribe() sends CLOSE to all connected relays', () async {
      final (:manager, :mocks) = _buildManager(2);
      await manager.connectAll();

      manager.unsubscribe('sub1');

      for (final mock in mocks) {
        expect(mock.sink.messages, hasLength(1));
        final decoded = jsonDecode(mock.sink.messages.first) as List<dynamic>;
        expect(decoded[0], equals('CLOSE'));
        expect(decoded[1], equals('sub1'));
      }

      await manager.disconnectAll();
      for (final m in mocks) {
        await m.closeStream();
      }
    });
  });

  group('RelayManager — deduplication', () {
    test('same event ID from two relays is emitted only once', () async {
      final (:manager, :mocks) = _buildManager(2);
      await manager.connectAll();

      final received = <NostrEvent>[];
      final completer = Completer<void>();

      manager.events.listen((event) {
        received.add(event);
        // Schedule a check after a short delay; if we only see 1 event, good.
        if (!completer.isCompleted) {
          Future.delayed(const Duration(milliseconds: 100), () {
            if (!completer.isCompleted) completer.complete();
          });
        }
      });

      final eventJson = _eventJson(id: 'd' * 64, content: 'dup');

      // Both relays send the same event.
      mocks[0].sendEvent(eventJson);
      mocks[1].sendEvent(eventJson);

      await completer.future.timeout(const Duration(seconds: 2));

      // Allow any extra events that might be buffered.
      await Future.delayed(const Duration(milliseconds: 50));

      expect(received, hasLength(1));
      expect(received.first.id, equals('d' * 64));

      await manager.disconnectAll();
      for (final m in mocks) {
        await m.closeStream();
      }
    });

    test('different events from different relays are both emitted', () async {
      final (:manager, :mocks) = _buildManager(2);
      await manager.connectAll();

      final received = <NostrEvent>[];
      final completer = Completer<void>();

      manager.events.listen((event) {
        received.add(event);
        if (received.length == 2) completer.complete();
      });

      mocks[0].sendEvent(_eventJson(id: 'e' * 64, content: 'from relay 0'));
      mocks[1].sendEvent(_eventJson(id: 'f' * 64, content: 'from relay 1'));

      await completer.future.timeout(const Duration(seconds: 2));

      expect(received, hasLength(2));
      final ids = received.map((e) => e.id).toSet();
      expect(ids, containsAll(['e' * 64, 'f' * 64]));

      await manager.disconnectAll();
      for (final m in mocks) {
        await m.closeStream();
      }
    });
  });

  group('RelayManager — partial failure / relay disconnect', () {
    test('one relay stream closes unexpectedly → connectedRelays decrements, '
        'remaining relay still works', () async {
      final (:manager, :mocks) = _buildManager(2);
      await manager.connectAll();

      expect(manager.connectedRelays, hasLength(2));

      // Set up listener for events from the surviving relay.
      final received = <NostrEvent>[];
      final completer = Completer<void>();

      manager.events.listen((event) {
        received.add(event);
        if (!completer.isCompleted) completer.complete();
      });

      // Close relay0's stream — simulates unexpected disconnect.
      await mocks[0].closeStream();

      // Allow the onDone callback to fire.
      await Future.delayed(const Duration(milliseconds: 50));

      expect(manager.connectedRelays, hasLength(1));
      expect(manager.connectedRelays.first, equals('ws://relay1'));

      // Relay1 still delivers events.
      mocks[1].sendEvent(_eventJson(id: 'g' * 64, content: 'surviving'));

      await completer.future.timeout(const Duration(seconds: 2));
      expect(received, hasLength(1));
      expect(received.first.id, equals('g' * 64));

      await manager.disconnectAll();
      await mocks[1].closeStream();
    });
  });

  group('RelayManager — disconnectAll()', () {
    test('disconnectAll() cleans up and closes events stream', () async {
      final (:manager, :mocks) = _buildManager(2);
      await manager.connectAll();

      // Collect the events stream future to check it completes.
      final eventsDone = manager.events.toList();

      await manager.disconnectAll();
      for (final m in mocks) {
        await m.closeStream();
      }

      expect(manager.connectedRelays, isEmpty);

      // The events stream should complete after disconnectAll().
      await expectLater(eventsDone, completes);
    });

    test('disconnectAll() after zero connects is a no-op', () async {
      final manager = RelayManager(['ws://relay0', 'ws://relay1']);
      // Never called connectAll() — should not throw.
      await manager.disconnectAll();
      expect(manager.connectedRelays, isEmpty);
    });
  });
}
