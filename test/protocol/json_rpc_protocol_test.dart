import 'dart:async';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:test/test.dart';

import 'package:nostr_rpc/src/protocol/rpc_protocol.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_protocol.dart';
import 'package:nostr_rpc/src/protocol/json_rpc_with_sequence_cache_protocol.dart';

/// Creates a pair of connected RawChannels backed by in-memory stream
/// controllers. Data written to A.outgoing appears on B.incoming and vice versa.
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

void main() {
  group('JsonRpcProtocol.createConnection()', () {
    test('returns a JsonRpcConnection', () async {
      final protocol = JsonRpcProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final conn = protocol.createConnection('aabbcc', channelA);

      expect(conn, isA<JsonRpcConnection>());
      expect(conn.peerPubkeyHex, equals('aabbcc'));

      await conn.close();
      await close();
    });

    test('stores peerPubkeyHex correctly', () async {
      final protocol = JsonRpcProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      // 64-char hex string
      const pubkey =
          'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef';

      final conn = protocol.createConnection(pubkey, channelA);

      expect(conn.peerPubkeyHex, equals(pubkey));

      await conn.close();
      await close();
    });

    test('exposes rpcPeer of type rpc.Peer', () async {
      final protocol = JsonRpcProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final conn = protocol.createConnection('aabbcc', channelA);

      expect(conn.rpcPeer, isA<rpc.Peer>());

      await conn.close();
      await close();
    });
  });

  group('JsonRpcProtocol — JSON-RPC round-trip', () {
    test('echo method returns correct response', () async {
      final protocol = JsonRpcProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      // Side A: the server that registers the "echo" method.
      final serverConn = protocol.createConnection('server_pubkey', channelA);
      serverConn.registerMethod('echo', (rpc.Parameters params) {
        return params['msg'].value;
      });

      // Side B: the client that calls "echo".
      final clientConn = protocol.createConnection('client_pubkey', channelB);

      final response = await clientConn
          .sendRequest('echo', {'msg': 'hello'})
          .timeout(const Duration(seconds: 5));

      expect(response, equals('hello'));

      await serverConn.close();
      await clientConn.close();
      await close();
    });

    test('multiple method calls work correctly', () async {
      final protocol = JsonRpcProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final serverConn = protocol.createConnection('server', channelA);
      serverConn.registerMethod('add', (rpc.Parameters params) {
        return (params['a'].value as num) + (params['b'].value as num);
      });

      final clientConn = protocol.createConnection('client', channelB);

      final r1 = await clientConn
          .sendRequest('add', {'a': 1, 'b': 2})
          .timeout(const Duration(seconds: 5));
      final r2 = await clientConn
          .sendRequest('add', {'a': 10, 'b': 20})
          .timeout(const Duration(seconds: 5));

      expect(r1, equals(3));
      expect(r2, equals(30));

      await serverConn.close();
      await clientConn.close();
      await close();
    });

    test('notification does not return a response', () async {
      final protocol = JsonRpcProtocol();
      final (:channelA, :channelB, :close) = _makePairedChannels();

      final received = <String>[];
      final serverConn = protocol.createConnection('server', channelA);
      serverConn.registerMethod('ping', (rpc.Parameters params) {
        received.add(params['data'].value as String);
      });

      final clientConn = protocol.createConnection('client', channelB);
      clientConn.sendNotification('ping', {'data': 'pong'});

      // Allow async processing.
      await Future.delayed(const Duration(milliseconds: 30));

      expect(received, equals(['pong']));

      await serverConn.close();
      await clientConn.close();
      await close();
    });

    test(
      'sequence-cache protocol preserves arbitrary JSON params types',
      () async {
        final protocol = JsonRpcWithSequenceCacheProtocol();
        final (:channelA, :channelB, :close) = _makePairedChannels();

        final serverConn = protocol.createConnection('server', channelA);
        serverConn.registerMethod('reflect', (rpc.Parameters params) {
          return {
            'map': params['map'].asMap,
            'list': params['list'].asList,
            'string': params['string'].asString,
            'number': params['number'].asInt,
            'bool': params['bool'].asBool,
            'nullable': params['nullable'].value,
          };
        });

        final clientConn = protocol.createConnection('client', channelB);

        final response = await clientConn
            .sendRequest('reflect', {
              'map': {
                'nested': [1, true, null],
              },
              'list': [
                'a',
                {'b': 2},
                false,
              ],
              'string': 'hello',
              'number': 42,
              'bool': true,
              'nullable': null,
            })
            .timeout(const Duration(seconds: 5));

        expect(
          response,
          equals({
            'map': {
              'nested': [1, true, null],
            },
            'list': [
              'a',
              {'b': 2},
              false,
            ],
            'string': 'hello',
            'number': 42,
            'bool': true,
            'nullable': null,
          }),
        );

        await serverConn.close();
        await clientConn.close();
        await close();
      },
    );
  });

  group('JsonRpcProtocol — dispose', () {
    test('dispose() does not throw', () {
      final protocol = JsonRpcProtocol();
      expect(() => protocol.dispose(), returnsNormally);
    });
  });
}
