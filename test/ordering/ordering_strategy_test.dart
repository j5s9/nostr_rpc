import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/ordering/sequence_wrapper.dart';
import 'package:nostr_rpc/src/ordering/ordering_strategy.dart';
import 'package:nostr_rpc/src/ordering/no_cache_ordering.dart';
import 'package:nostr_rpc/src/ordering/sequence_cache_ordering.dart';

void main() {
  group('SequenceWrapper', () {
    test('wrap produces valid JSON with seq and data fields', () {
      final result = SequenceWrapper.wrap(0, 'hello');
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['seq'], equals(0));
      expect(decoded['data'], equals('hello'));
    });

    test('wrap uses the provided seq number', () {
      final result = SequenceWrapper.wrap(5, 'world');
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['seq'], equals(5));
      expect(decoded['data'], equals('world'));
    });

    test('unwrap round-trips wrap correctly', () {
      final wrapped = SequenceWrapper.wrap(5, 'world');
      final (seq, data) = SequenceWrapper.unwrap(wrapped);
      expect(seq, equals(5));
      expect(data, equals('world'));
    });

    test('unwrap throws FormatException on invalid JSON', () {
      expect(
        () => SequenceWrapper.unwrap('not json at all'),
        throwsA(isA<FormatException>()),
      );
    });

    test('unwrap throws FormatException when seq field missing', () {
      final json = jsonEncode({'data': 'hello'});
      expect(
        () => SequenceWrapper.unwrap(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('unwrap throws FormatException when data field missing', () {
      final json = jsonEncode({'seq': 0});
      expect(
        () => SequenceWrapper.unwrap(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('unwrap throws FormatException when input is not a JSON object', () {
      expect(
        () => SequenceWrapper.unwrap('"just a string"'),
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

    test('wrapOutgoing returns payload unchanged (no seq wrapping)', () {
      expect(ordering.wrapOutgoing('hello'), equals('hello'));
      expect(
        ordering.wrapOutgoing('{"method":"foo"}'),
        equals('{"method":"foo"}'),
      );
    });

    test('handleIncoming delivers raw message immediately', () {
      final delivered = <String>[];
      ordering.handleIncoming('msg0', delivered.add);
      expect(delivered, equals(['msg0']));
    });

    test('handleIncoming delivers messages in order of arrival', () {
      final delivered = <String>[];
      ordering.handleIncoming('msgB', delivered.add);
      ordering.handleIncoming('msgA', delivered.add);
      expect(delivered, equals(['msgB', 'msgA']));
    });

    test('handleIncoming passes arbitrary strings through unchanged', () {
      final delivered = <String>[];
      ordering.handleIncoming(
        '{"jsonrpc":"2.0","method":"ping","params":[],"id":1}',
        delivered.add,
      );
      expect(
        delivered,
        equals(['{"jsonrpc":"2.0","method":"ping","params":[],"id":1}']),
      );
    });
  });

  group('SequenceCacheOrdering', () {
    test('in-order messages are delivered immediately', () {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 100),
      );
      final delivered = <String>[];

      ordering.handleIncoming(SequenceWrapper.wrap(0, 'zero'), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(1, 'one'), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(2, 'two'), delivered.add);

      expect(delivered, equals(['zero', 'one', 'two']));
      ordering.dispose();
    });

    test('out-of-order: seq=1 before seq=0 buffers then flushes in order', () {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 100),
      );
      final delivered = <String>[];

      // Receive seq=1 first — should be buffered, nothing delivered yet
      ordering.handleIncoming(SequenceWrapper.wrap(1, 'one'), delivered.add);
      expect(delivered, isEmpty);

      // Receive seq=0 — should deliver 0 then drain 1
      ordering.handleIncoming(SequenceWrapper.wrap(0, 'zero'), delivered.add);
      expect(delivered, equals(['zero', 'one']));

      ordering.dispose();
    });

    test('duplicate/old seq numbers are ignored', () {
      final ordering = SequenceCacheOrdering(
        timeout: const Duration(milliseconds: 100),
      );
      final delivered = <String>[];

      ordering.handleIncoming(SequenceWrapper.wrap(0, 'zero'), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(1, 'one'), delivered.add);

      // Duplicate of seq=0 and seq=1 should be ignored
      ordering.handleIncoming(SequenceWrapper.wrap(0, 'dup0'), delivered.add);
      ordering.handleIncoming(SequenceWrapper.wrap(1, 'dup1'), delivered.add);

      expect(delivered, equals(['zero', 'one']));
      ordering.dispose();
    });

    test(
      'gap timeout → flushOutOfOrder delivers all buffered in order',
      () async {
        final ordering = SequenceCacheOrdering(
          timeout: const Duration(milliseconds: 5),
          fallback: TimeoutFallback.flushOutOfOrder,
        );
        final delivered = <String>[];

        // Buffer seq=1 and seq=2, creating a gap at seq=0
        ordering.handleIncoming(SequenceWrapper.wrap(1, 'one'), delivered.add);
        ordering.handleIncoming(SequenceWrapper.wrap(2, 'two'), delivered.add);
        expect(delivered, isEmpty);

        // Wait for the timeout to fire
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // Both buffered messages should be delivered in seq order
        expect(delivered, equals(['one', 'two']));
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
        final delivered = <String>[];

        // Buffer seq=2 (gap at 0,1)
        ordering.handleIncoming(SequenceWrapper.wrap(2, 'two'), delivered.add);
        expect(delivered, isEmpty);

        // Wait for timeout
        await Future<void>.delayed(const Duration(milliseconds: 30));

        // seq=2 should be delivered (skipping 0 and 1)
        expect(delivered, equals(['two']));
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
          final delivered = <String>[];

          // Buffer seq=1, creating gap at seq=0
          ordering.handleIncoming(
            SequenceWrapper.wrap(1, 'one'),
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
      final delivered = <String>[];

      // Buffer a message to start the timer
      ordering.handleIncoming(SequenceWrapper.wrap(1, 'one'), delivered.add);
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
        final delivered = <String>[];

        // Receive 4, 3, 2, 1 — all buffered
        ordering.handleIncoming(SequenceWrapper.wrap(4, 'four'), delivered.add);
        ordering.handleIncoming(
          SequenceWrapper.wrap(3, 'three'),
          delivered.add,
        );
        ordering.handleIncoming(SequenceWrapper.wrap(2, 'two'), delivered.add);
        ordering.handleIncoming(SequenceWrapper.wrap(1, 'one'), delivered.add);
        expect(delivered, isEmpty);

        // Now receive seq=0 — should drain entire buffer
        ordering.handleIncoming(SequenceWrapper.wrap(0, 'zero'), delivered.add);
        expect(delivered, equals(['zero', 'one', 'two', 'three', 'four']));

        ordering.dispose();
      },
    );

    test('wrapOutgoing increments seq starting at 0', () {
      final ordering = SequenceCacheOrdering();
      final w0 = SequenceWrapper.unwrap(ordering.wrapOutgoing('a'));
      final w1 = SequenceWrapper.unwrap(ordering.wrapOutgoing('b'));
      expect(w0.$1, equals(0));
      expect(w1.$1, equals(1));
      ordering.dispose();
    });
  });
}
