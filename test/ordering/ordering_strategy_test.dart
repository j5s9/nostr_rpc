import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/ordering/sequence_wrapper.dart';
import 'package:nostr_rpc/src/ordering/ordering_strategy.dart';
import 'package:nostr_rpc/src/ordering/no_cache_ordering.dart';
import 'package:nostr_rpc/src/ordering/sequence_cache_ordering.dart';

Map<String, dynamic> _rpcMessage({
  required int id,
  String method = 'echo',
  Object? params,
}) {
  return {
    'jsonrpc': '2.0',
    'method': method,
    'params': params ?? {'value': id},
    'id': id,
  };
}

void main() {
  group('SequenceWrapper', () {
    test('wrap produces valid JSON object with seq and data fields', () {
      final payload = _rpcMessage(id: 1, params: {'text': 'hello'});
      final result = SequenceWrapper.wrap(0, payload);
      final decoded = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
      expect(decoded['seq'], equals(0));
      expect(decoded['data'], equals(payload));
    });

    test('wrap uses the provided seq number', () {
      final payload = _rpcMessage(id: 5, params: ['world']);
      final result = SequenceWrapper.wrap(5, payload);
      final decoded = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
      expect(decoded['seq'], equals(5));
      expect(decoded['data'], equals(payload));
    });

    test('unwrap round-trips nested JSON payload without escaping', () {
      final payload = _rpcMessage(
        id: 5,
        params: {
          'list': [
            1,
            true,
            null,
            {'nested': 'value'},
          ],
          'text': 'world',
        },
      );
      final wrapped = SequenceWrapper.wrap(5, payload);
      final encoded = jsonEncode(wrapped);
      final (seq, data) = SequenceWrapper.unwrap<Map<String, dynamic>>(wrapped);

      expect(seq, equals(5));
      expect(data, equals(payload));
      expect(encoded, contains('"data":{"jsonrpc":"2.0"'));
      expect(encoded, isNot(contains(r'\"jsonrpc\"')));
    });

    test('unwrap accepts null payload when type allows it', () {
      final wrapped = SequenceWrapper.wrap<Object?>(3, null);
      final (seq, data) = SequenceWrapper.unwrap<Object?>(wrapped);

      expect(seq, equals(3));
      expect(data, isNull);
    });

    test('unwrap throws FormatException when seq field missing', () {
      expect(
        () => SequenceWrapper.unwrap<Map<String, dynamic>>({'data': 'hello'}),
        throwsA(isA<FormatException>()),
      );
    });

    test('unwrap throws FormatException when data field missing', () {
      expect(
        () => SequenceWrapper.unwrap<Map<String, dynamic>>({'seq': 0}),
        throwsA(isA<FormatException>()),
      );
    });

    test('unwrap throws FormatException when seq is not an int', () {
      expect(
        () => SequenceWrapper.unwrap<Map<String, dynamic>>({
          'seq': '0',
          'data': _rpcMessage(id: 1),
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('unwrap throws FormatException when data has wrong type', () {
      expect(
        () => SequenceWrapper.unwrap<Map<String, dynamic>>({
          'seq': 0,
          'data': 'not a map',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('NoCacheOrdering', () {
    late NoCacheOrdering ordering;

    setUp(() {
      ordering = NoCacheOrdering();
    });

    tearDown(() {
      ordering.dispose();
    });

    test('wrapOutgoing encodes the JSON-RPC object without seq wrapping', () {
      final payload = _rpcMessage(id: 1, params: 'hello');
      expect(ordering.wrapOutgoing(payload), equals(jsonEncode(payload)));
      expect(
        ordering.wrapOutgoing(_rpcMessage(id: 2, method: 'foo', params: [1])),
        equals(jsonEncode(_rpcMessage(id: 2, method: 'foo', params: [1]))),
      );
    });

    test('handleIncoming delivers decoded JSON object immediately', () {
      final delivered = <Map<String, dynamic>>[];
      final message = _rpcMessage(id: 0, params: 'msg0');
      ordering.handleIncoming(message, delivered.add);
      expect(delivered, equals([message]));
    });

    test('handleIncoming delivers messages in order of arrival', () {
      final delivered = <Map<String, dynamic>>[];
      final msgB = _rpcMessage(id: 2, params: 'msgB');
      final msgA = _rpcMessage(id: 1, params: 'msgA');
      ordering.handleIncoming(msgB, delivered.add);
      ordering.handleIncoming(msgA, delivered.add);
      expect(delivered, equals([msgB, msgA]));
    });

    test('handleIncoming preserves arbitrary nested JSON params', () {
      final delivered = <Map<String, dynamic>>[];
      final message = _rpcMessage(
        id: 1,
        method: 'ping',
        params: [
          {'nested': true},
          'text',
          42,
          false,
          null,
        ],
      );
      ordering.handleIncoming(message, delivered.add);
      expect(delivered, equals([message]));
    });
  });

  group('SequenceCacheOrdering', () {
    test('in-order messages are delivered immediately', () {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 100),
      );
      final delivered = <Map<String, dynamic>>[];

      final zero = _rpcMessage(id: 0, params: 'zero');
      final one = _rpcMessage(id: 1, params: 'one');
      final two = _rpcMessage(id: 2, params: 'two');

      ordering.handleIncoming(SequenceWrapper.wrap(0, zero), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(1, one), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(2, two), delivered.add);

      expect(delivered, equals([zero, one, two]));
      ordering.dispose();
    });

    test('out-of-order: seq=1 before seq=0 buffers then flushes in order', () {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 100),
      );
      final delivered = <Map<String, dynamic>>[];
      final zero = _rpcMessage(id: 0, params: 'zero');
      final one = _rpcMessage(id: 1, params: 'one');

      // Receive seq=1 first — should be buffered, nothing delivered yet
      ordering.handleIncoming(SequenceWrapper.wrap(1, one), delivered.add);
      expect(delivered, isEmpty);

      // Receive seq=0 — should deliver 0 then drain 1
      ordering.handleIncoming(SequenceWrapper.wrap(0, zero), delivered.add);
      expect(delivered, equals([zero, one]));

      ordering.dispose();
    });

    test('duplicate/old seq numbers are ignored', () {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 100),
      );
      final delivered = <Map<String, dynamic>>[];
      final zero = _rpcMessage(id: 0, params: 'zero');
      final one = _rpcMessage(id: 1, params: 'one');

      ordering.handleIncoming(SequenceWrapper.wrap(0, zero), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(1, one), delivered.add);

      // Duplicate of seq=0 and seq=1 should be ignored
      ordering.handleIncoming(
        SequenceWrapper.wrap(0, _rpcMessage(id: 10, params: 'dup0')),
        delivered.add,
      );
      ordering.handleIncoming(
        SequenceWrapper.wrap(1, _rpcMessage(id: 11, params: 'dup1')),
        delivered.add,
      );

      expect(delivered, equals([zero, one]));
      ordering.dispose();
    });

    test(
      'gap timeout → flushOutOfOrder delivers all buffered in order',
      () async {
        final ordering = SequenceCacheOrdering(
          timeout: const Duration(milliseconds: 5),
          fallback: TimeoutFallback.flushOutOfOrder,
        );
        final delivered = <Map<String, dynamic>>[];
        final one = _rpcMessage(
          id: 1,
          params: {
            'payload': [1],
          },
        );
        final two = _rpcMessage(
          id: 2,
          params: {
            'payload': [2],
          },
        );

        // Buffer seq=1 and seq=2, creating a gap at seq=0
        ordering.handleIncoming(SequenceWrapper.wrap(1, one), delivered.add);
        ordering.handleIncoming(SequenceWrapper.wrap(2, two), delivered.add);
        expect(delivered, isEmpty);

        // Wait for the timeout to fire
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Both buffered messages should be delivered in seq order
        expect(delivered, equals([one, two]));
        ordering.dispose();
      },
    );

    test(
      'gap timeout → dropMissing skips gap and delivers next available',
      () async {
        final ordering = SequenceCacheOrdering(
          timeout: const Duration(milliseconds: 5),
          fallback: TimeoutFallback.dropMissing,
        );
        final delivered = <Map<String, dynamic>>[];
        final two = _rpcMessage(id: 2, params: ['two']);

        // Buffer seq=2 (gap at 0,1)
        ordering.handleIncoming(SequenceWrapper.wrap(2, two), delivered.add);
        expect(delivered, isEmpty);

        // Wait for timeout
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // seq=2 should be delivered (skipping 0 and 1)
        expect(delivered, equals([two]));
        ordering.dispose();
      },
    );

    test('gap timeout → throwOnMissing throws SequenceGapException', () async {
      Object? caughtError;
      final completer = Completer<void>();

      // Create the ordering inside runZonedGuarded so Timer inherits the zone
      runZonedGuarded(
        () {
          final ordering = SequenceCacheOrdering(
            timeout: const Duration(milliseconds: 5),
            fallback: TimeoutFallback.throwOnMissing,
          );
          final delivered = <Map<String, dynamic>>[];

          // Buffer seq=1, creating gap at seq=0
          ordering.handleIncoming(
            SequenceWrapper.wrap(1, _rpcMessage(id: 1, params: 'one')),
            delivered.add,
          );
          expect(delivered, isEmpty);

          // Schedule a cleanup after timeout fires
          Future<void>.delayed(const Duration(milliseconds: 30)).then((_) {
            ordering.dispose();
            if (!completer.isCompleted) completer.complete();
          });
        },
        (e, st) {
          caughtError = e;
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future;

      // throwOnMissing throws a SequenceGapException
      expect(caughtError, isA<SequenceGapException>());
    });

    test('dispose cancels timer and clears buffer', () async {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 5),
        fallback: TimeoutFallback.flushOutOfOrder,
      );
      final delivered = <Map<String, dynamic>>[];

      // Buffer a message to start the timer
      ordering.handleIncoming(
        SequenceWrapper.wrap(1, _rpcMessage(id: 1, params: 'one')),
        delivered.add,
      );
      expect(delivered, isEmpty);

      // Dispose before timer fires
      ordering.dispose();

      // Wait beyond timeout — nothing should be delivered
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(delivered, isEmpty);
    });

    test(
      'consecutive gaps: multiple out-of-order messages buffer correctly',
      () {
        final ordering = SequenceCacheOrdering(
          timeout: const Duration(milliseconds: 100),
        );
        final delivered = <Map<String, dynamic>>[];
        final zero = _rpcMessage(id: 0, params: 'zero');
        final one = _rpcMessage(id: 1, params: 'one');
        final two = _rpcMessage(id: 2, params: 'two');
        final three = _rpcMessage(id: 3, params: 'three');
        final four = _rpcMessage(id: 4, params: 'four');

        // Receive 4, 3, 2, 1 — all buffered
        ordering.handleIncoming(SequenceWrapper.wrap(4, four), delivered.add);
        ordering.handleIncoming(SequenceWrapper.wrap(3, three), delivered.add);
        ordering.handleIncoming(SequenceWrapper.wrap(2, two), delivered.add);
        ordering.handleIncoming(SequenceWrapper.wrap(1, one), delivered.add);
        expect(delivered, isEmpty);

        // Now receive seq=0 — should drain entire buffer
        ordering.handleIncoming(SequenceWrapper.wrap(0, zero), delivered.add);
        expect(delivered, equals([zero, one, two, three, four]));

        ordering.dispose();
      },
    );

    test('wrapOutgoing increments seq starting at 0', () {
      final ordering = SequenceCacheOrdering();
      final w0 = SequenceWrapper.unwrap<Map<String, dynamic>>(
        jsonDecode(ordering.wrapOutgoing(_rpcMessage(id: 0, params: 'a')))
            as Map<String, dynamic>,
      );
      final w1 = SequenceWrapper.unwrap<Map<String, dynamic>>(
        jsonDecode(ordering.wrapOutgoing(_rpcMessage(id: 1, params: 'b')))
            as Map<String, dynamic>,
      );
      expect(w0.$1, equals(0));
      expect(w1.$1, equals(1));
      expect(w0.$2['params'], equals('a'));
      expect(w1.$2['params'], equals('b'));
      ordering.dispose();
    });
  });
}
