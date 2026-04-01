// Tests for WebSocketRelayClient: Nostr NIP-01 wire protocol over WebSocket.
//
// All tests use a mock WebSocketChannel — no real relay connections.

import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:nostr_rpc/src/crypto/event.dart';
import 'package:nostr_rpc/src/transport/websocket_relay_client.dart';

// ---------------------------------------------------------------------------
// Mock infrastructure
// ---------------------------------------------------------------------------

/// A minimal [WebSocketSink] that records all added messages.
class _MockSink implements WebSocketSink {
  final List<String> messages = [];
  final Completer<void> _closeCompleter = Completer<void>();

  @override
  void add(dynamic data) {
    messages.add(data as String);
  }

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

/// A minimal [WebSocketChannel] backed by a [StreamController] for simulating
/// incoming relay messages and a [_MockSink] for capturing outgoing messages.
///
/// Extends [StreamChannelMixin] to provide the default implementations of
/// the abstract mixin methods (pipe, transform, cast, etc.).
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

/// A complete, valid Nostr event JSON map for use in tests.
/// Fields are plausible hex values that pass NostrEvent.fromJson().
Map<String, dynamic> _sampleEventJson() => {
  'id': 'a' * 64,
  'pubkey': 'b' * 64,
  'created_at': 1700000000,
  'kind': 1,
  'tags': <List<String>>[],
  'content': 'hello nostr',
  'sig': 'c' * 128,
};

// ---------------------------------------------------------------------------
// Test setup helper
// ---------------------------------------------------------------------------

typedef _TestSetup =
    ({
      WebSocketRelayClient client,
      StreamController<dynamic> incoming,
      _MockSink sink,
    });

_TestSetup _createMockSetup() {
  final incomingController = StreamController<dynamic>();
  final mockSink = _MockSink();
  final mockChannel = _MockWebSocketChannel(
    incomingController: incomingController,
    sink: mockSink,
  );

  final client = WebSocketRelayClient(
    'ws://mock',
    channelFactory: (_) => mockChannel,
  );

  return (client: client, incoming: incomingController, sink: mockSink);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('WebSocketRelayClient — outgoing messages', () {
    test('subscribe() sends ["REQ", subId, filter] as JSON', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      client.subscribe('sub1', [
        {
          'kinds': [1],
        },
      ]);

      expect(sink.messages, hasLength(1));
      final decoded = jsonDecode(sink.messages.first) as List<dynamic>;
      expect(decoded[0], equals('REQ'));
      expect(decoded[1], equals('sub1'));
      expect(
        decoded[2],
        equals({
          'kinds': [1],
        }),
      );

      await client.disconnect();
      await incoming.close();
    });

    test('subscribe() with multiple filters sends all filters', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      client.subscribe('sub2', [
        {
          'kinds': [1],
        },
        {
          'kinds': [3],
          'authors': ['abc'],
        },
      ]);

      expect(sink.messages, hasLength(1));
      final decoded = jsonDecode(sink.messages.first) as List<dynamic>;
      expect(decoded[0], equals('REQ'));
      expect(decoded[1], equals('sub2'));
      expect(
        decoded[2],
        equals({
          'kinds': [1],
        }),
      );
      expect(
        decoded[3],
        equals({
          'kinds': [3],
          'authors': ['abc'],
        }),
      );

      await client.disconnect();
      await incoming.close();
    });

    test('unsubscribe() sends ["CLOSE", subId] as JSON', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      client.unsubscribe('sub1');

      expect(sink.messages, hasLength(1));
      final decoded = jsonDecode(sink.messages.first) as List<dynamic>;
      expect(decoded[0], equals('CLOSE'));
      expect(decoded[1], equals('sub1'));

      await client.disconnect();
      await incoming.close();
    });

    test('publish() sends ["EVENT", eventJson] as JSON', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eventJson = _sampleEventJson();
      final event = NostrEvent.fromJson(eventJson);
      await client.publish(event);

      expect(sink.messages, hasLength(1));
      final decoded = jsonDecode(sink.messages.first) as List<dynamic>;
      expect(decoded[0], equals('EVENT'));
      expect((decoded[1] as Map<String, dynamic>)['id'], equals('a' * 64));
      expect(
        (decoded[1] as Map<String, dynamic>)['content'],
        equals('hello nostr'),
      );

      await client.disconnect();
      await incoming.close();
    });
  });

  group('WebSocketRelayClient — incoming EVENT messages', () {
    test('["EVENT", subId, eventJson] is emitted on events stream', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eventFuture = client.events.first;

      incoming.add(jsonEncode(['EVENT', 'sub1', _sampleEventJson()]));

      final event = await eventFuture;
      expect(event.id, equals('a' * 64));
      expect(event.content, equals('hello nostr'));

      await client.disconnect();
      await incoming.close();
    });

    test('multiple EVENT messages are all emitted in order', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final events = <NostrEvent>[];
      final completer = Completer<void>();
      client.events.listen((e) {
        events.add(e);
        if (events.length == 2) completer.complete();
      });

      final event1 = {..._sampleEventJson(), 'id': 'a' * 64, 'content': 'msg1'};
      final event2 = {..._sampleEventJson(), 'id': 'b' * 64, 'content': 'msg2'};

      incoming.add(jsonEncode(['EVENT', 'sub1', event1]));
      incoming.add(jsonEncode(['EVENT', 'sub1', event2]));

      await completer.future.timeout(const Duration(seconds: 2));
      expect(events[0].content, equals('msg1'));
      expect(events[1].content, equals('msg2'));

      await client.disconnect();
      await incoming.close();
    });
  });

  group('WebSocketRelayClient — incoming OK messages', () {
    test('["OK", eventId, true, ""] is emitted on okResults stream', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final okFuture = client.okResults.first;

      incoming.add(jsonEncode(['OK', 'a' * 64, true, '']));

      final result = await okFuture;
      expect(result.eventId, equals('a' * 64));
      expect(result.accepted, isTrue);
      expect(result.message, equals(''));

      await client.disconnect();
      await incoming.close();
    });

    test(
      '["OK", eventId, false, "blocked: spam"] is emitted correctly',
      () async {
        final (:client, :incoming, :sink) = _createMockSetup();
        await client.connect();

        final okFuture = client.okResults.first;

        incoming.add(jsonEncode(['OK', 'b' * 64, false, 'blocked: spam']));

        final result = await okFuture;
        expect(result.eventId, equals('b' * 64));
        expect(result.accepted, isFalse);
        expect(result.message, equals('blocked: spam'));

        await client.disconnect();
        await incoming.close();
      },
    );
  });

  group('WebSocketRelayClient — incoming NOTICE messages', () {
    test('["NOTICE", "hello"] is emitted on notices stream', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final noticeFuture = client.notices.first;

      incoming.add(jsonEncode(['NOTICE', 'hello from relay']));

      final notice = await noticeFuture;
      expect(notice, equals('hello from relay'));

      await client.disconnect();
      await incoming.close();
    });
  });

  group('WebSocketRelayClient — incoming EOSE messages', () {
    test('["EOSE", subId] is emitted on eoseSignals stream', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eoseFuture = client.eoseSignals.first;

      incoming.add(jsonEncode(['EOSE', 'my-subscription']));

      final subId = await eoseFuture;
      expect(subId, equals('my-subscription'));

      await client.disconnect();
      await incoming.close();
    });
  });

  group('WebSocketRelayClient — error resilience', () {
    test('malformed JSON is silently ignored, client does not crash', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      // A valid event future to confirm the client is still working after
      // receiving malformed JSON.
      final eventFuture = client.events.first;

      // Send garbage first.
      incoming.add('not valid json {{{');
      incoming.add('also bad: [unclosed');
      // Then send a valid event.
      incoming.add(jsonEncode(['EVENT', 'sub1', _sampleEventJson()]));

      final event = await eventFuture.timeout(const Duration(seconds: 2));
      expect(event.id, equals('a' * 64));

      await client.disconnect();
      await incoming.close();
    });

    test('unknown message type is silently ignored', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eventFuture = client.events.first;

      // Send unknown types first.
      incoming.add(jsonEncode(['AUTH', 'some-challenge']));
      incoming.add(jsonEncode(['UNKNOWN_FUTURE_TYPE', 'data']));
      // Then valid event.
      incoming.add(jsonEncode(['EVENT', 'sub1', _sampleEventJson()]));

      final event = await eventFuture.timeout(const Duration(seconds: 2));
      expect(event.id, equals('a' * 64));

      await client.disconnect();
      await incoming.close();
    });

    test('empty JSON array is silently ignored', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eventFuture = client.events.first;

      incoming.add(jsonEncode([]));
      incoming.add(jsonEncode(['EVENT', 'sub1', _sampleEventJson()]));

      final event = await eventFuture.timeout(const Duration(seconds: 2));
      expect(event.id, equals('a' * 64));

      await client.disconnect();
      await incoming.close();
    });

    test('EVENT with malformed event JSON is silently ignored', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eventFuture = client.events.first;

      // Bad event: missing required fields.
      incoming.add(
        jsonEncode([
          'EVENT',
          'sub1',
          {'bad': 'data'},
        ]),
      );
      // Valid event comes through.
      incoming.add(jsonEncode(['EVENT', 'sub1', _sampleEventJson()]));

      final event = await eventFuture.timeout(const Duration(seconds: 2));
      expect(event.id, equals('a' * 64));

      await client.disconnect();
      await incoming.close();
    });
  });

  group('WebSocketRelayClient — connection lifecycle', () {
    test(
      'isConnected is true after connect(), false after disconnect()',
      () async {
        final (:client, :incoming, :sink) = _createMockSetup();

        expect(client.isConnected, isFalse);

        await client.connect();
        expect(client.isConnected, isTrue);

        await client.disconnect();
        await incoming.close();

        expect(client.isConnected, isFalse);
      },
    );

    test('streams close gracefully after disconnect()', () async {
      final (:client, :incoming, :sink) = _createMockSetup();
      await client.connect();

      final eventsDone = client.events.toList();
      final noticesDone = client.notices.toList();
      final okDone = client.okResults.toList();
      final eoseDone = client.eoseSignals.toList();

      await client.disconnect();
      await incoming.close();

      // All streams should complete (no exception) after disconnect.
      await expectLater(eventsDone, completes);
      await expectLater(noticesDone, completes);
      await expectLater(okDone, completes);
      await expectLater(eoseDone, completes);
    });
  });
}
