import 'dart:async';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/core/acceptance_strategy.dart';

void main() {
  group('AlwaysAcceptStrategy', () {
    test('always returns true', () async {
      final strategy = AlwaysAcceptStrategy();

      expect(await strategy.shouldAccept('any'), isTrue);
      expect(await strategy.shouldAccept('any'), isTrue);
    });
  });

  group('AlwaysAskStrategy', () {
    test('calls callback every time and returns its value', () async {
      var callCount = 0;
      final strategy = AlwaysAskStrategy(
        onNewPeer: (pubkey) async {
          callCount++;
          return pubkey == 'allow';
        },
      );

      expect(await strategy.shouldAccept('allow'), isTrue);
      expect(await strategy.shouldAccept('allow'), isTrue);
      expect(callCount, equals(2));
    });

    test('returns false when callback rejects', () async {
      final strategy = AlwaysAskStrategy(onNewPeer: (_) async => false);

      expect(await strategy.shouldAccept('deny'), isFalse);
    });
  });

  group('CachedApprovalStrategy', () {
    test('calls callback for first invocation and caches the result', () async {
      var callCount = 0;
      final strategy = CachedApprovalStrategy(
        onNewPeer: (_) async {
          callCount++;
          return true;
        },
      );

      expect(await strategy.shouldAccept('peer1'), isTrue);
      expect(await strategy.shouldAccept('peer1'), isTrue);
      expect(callCount, equals(1));
    });

    test('caches rejections too', () async {
      var callCount = 0;
      final strategy = CachedApprovalStrategy(
        onNewPeer: (_) async {
          callCount++;
          return false;
        },
      );

      expect(await strategy.shouldAccept('peer2'), isFalse);
      expect(await strategy.shouldAccept('peer2'), isFalse);
      expect(callCount, equals(1));
    });

    test('deduplicates concurrent requests for the same peer', () async {
      var callCount = 0;
      final completer = Completer<bool>();
      final strategy = CachedApprovalStrategy(
        onNewPeer: (_) {
          callCount++;
          return completer.future;
        },
      );

      final first = strategy.shouldAccept('peer3');
      final second = strategy.shouldAccept('peer3');

      expect(callCount, equals(1));
      completer.complete(true);

      expect(await first, isTrue);
      expect(await second, isTrue);
    });

    test('dispose clears cache so callback is invoked again', () async {
      var callCount = 0;
      final strategy = CachedApprovalStrategy(
        onNewPeer: (_) async {
          callCount++;
          return true;
        },
      );

      expect(await strategy.shouldAccept('peer4'), isTrue);
      expect(callCount, equals(1));

      strategy.dispose();

      expect(await strategy.shouldAccept('peer4'), isTrue);
      expect(callCount, equals(2));
    });
  });
}
