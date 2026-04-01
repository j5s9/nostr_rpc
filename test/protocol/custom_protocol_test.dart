import 'dart:async';

import 'package:test/test.dart';

import 'package:nostr_rpc/src/protocol/rpc_protocol.dart';

// ---------------------------------------------------------------------------
// Mock custom connection and protocol — inline in this file.
// ---------------------------------------------------------------------------

/// A simple custom connection that records all messages received.
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

  /// Messages received from the peer (via incoming channel).
  final List<String> received = [];

  bool _closed = false;

  bool get isClosed => _closed;

  /// Send a raw string to the peer.
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

/// Custom protocol that creates [MockConnection] instances.
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
// Helper: create a pair of linked RawChannels.
// ---------------------------------------------------------------------------

({RawChannel channelA, RawChannel channelB, Future<void> Function() close})
_makePairedChannels() {
  final aToB = StreamController<String>.broadcast();
  final bToA = StreamController<String>.broadcast();

  final channelA = RawChannel(bToA.stream, aToB.sink);
  final channelB = RawChannel(aToB.stream, bToA.sink);

  Future<void> close() async {
    await aToB.close();
    await bToA.close();
  }

  return (channelA: channelA, channelB: channelB, close: close);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MockProtocol — createConnection()', () {
    test('returns a MockConnection with correct peerPubkeyHex', () async {
      final protocol = MockProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final conn = protocol.createConnection('aabbcc', channelA);

      expect(conn, isA<MockConnection>());
      expect(conn.peerPubkeyHex, equals('aabbcc'));

      await conn.close();
      await close();
    });

    test('tracks all created connections in .created list', () async {
      final protocol = MockProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final conn1 = protocol.createConnection('peer1', channelA);
      expect(protocol.created, hasLength(1));
      expect(protocol.created.first, same(conn1));

      await conn1.close();
      await close();
    });

    test('multiple connections are tracked independently', () async {
      final protocol = MockProtocol();

      final ctrl1in = StreamController<String>.broadcast();
      final ctrl1out = StreamController<String>.broadcast();
      final ctrl2in = StreamController<String>.broadcast();
      final ctrl2out = StreamController<String>.broadcast();

      final ch1 = RawChannel(ctrl1in.stream, ctrl1out.sink);
      final ch2 = RawChannel(ctrl2in.stream, ctrl2out.sink);

      final conn1 = protocol.createConnection('peer1', ch1);
      final conn2 = protocol.createConnection('peer2', ch2);

      expect(protocol.created, hasLength(2));
      expect(protocol.created[0].peerPubkeyHex, equals('peer1'));
      expect(protocol.created[1].peerPubkeyHex, equals('peer2'));
      expect(conn1, isNot(same(conn2)));

      await conn1.close();
      await conn2.close();
      await ctrl1in.close();
      await ctrl1out.close();
      await ctrl2in.close();
      await ctrl2out.close();
    });

    test('dispose() does not throw', () {
      final protocol = MockProtocol();
      expect(() => protocol.dispose(), returnsNormally);
    });
  });

  group('MockConnection — messaging', () {
    test('messages sent via send() appear in peer received list', () async {
      final protocol = MockProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final connA = protocol.createConnection('peerB', channelA);
      final connB = protocol.createConnection('peerA', channelB);

      connA.send('hello from A');
      connB.send('hello from B');

      await Future.delayed(const Duration(milliseconds: 30));

      expect(connB.received, contains('hello from A'));
      expect(connA.received, contains('hello from B'));

      await connA.close();
      await connB.close();
      await close();
    });

    test('multiple messages arrive in order', () async {
      final protocol = MockProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final connA = protocol.createConnection('peerB', channelA);
      final connB = protocol.createConnection('peerA', channelB);

      connA.send('msg1');
      connA.send('msg2');
      connA.send('msg3');

      await Future.delayed(const Duration(milliseconds: 30));

      expect(connB.received, equals(['msg1', 'msg2', 'msg3']));

      await connA.close();
      await connB.close();
      await close();
    });

    test('after close(), send() is a no-op', () async {
      final protocol = MockProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final connA = protocol.createConnection('peerB', channelA);
      final connB = protocol.createConnection('peerA', channelB);

      await connA.close();
      expect(connA.isClosed, isTrue);

      // This should not throw or deliver.
      connA.send('after close');

      await Future.delayed(const Duration(milliseconds: 30));

      expect(connB.received, isEmpty);

      await connB.close();
      await close();
    });

    test('close() is idempotent — calling twice does not throw', () async {
      final protocol = MockProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final connA = protocol.createConnection('peer', channelA);

      await connA.close();
      expect(() async => connA.close(), returnsNormally);

      await close();
    });
  });

  group('RpcProtocol<T> generic type flow', () {
    test('MockProtocol generic parameter T is MockConnection', () {
      // Verify the generic type resolves correctly at compile-time via type check.
      final protocol = MockProtocol();
      expect(protocol, isA<RpcProtocol<MockConnection>>());
    });

    test(
      'createConnection returns T (MockConnection), not RpcConnection base',
      () async {
        final protocol = MockProtocol();
        final ctrl = StreamController<String>.broadcast();
        final ctrlOut = StreamController<String>.broadcast();
        final ch = RawChannel(ctrl.stream, ctrlOut.sink);

        final conn = protocol.createConnection('abc', ch);

        // conn is statically typed as MockConnection — methods like .send() accessible.
        expect(conn, isA<MockConnection>());
        conn.send('type check'); // static dispatch on MockConnection

        await conn.close();
        await ctrl.close();
        await ctrlOut.close();
      },
    );
  });
}
