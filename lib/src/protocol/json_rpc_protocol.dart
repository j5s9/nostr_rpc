import 'dart:async';
import 'dart:convert';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';

import '../ordering/ordering_strategy.dart';
import '../ordering/no_cache_ordering.dart';
import 'rpc_protocol.dart';

/// A JSON-RPC 2.0 connection implementation for Nostr RPC protocol.
class JsonRpcConnection extends RpcConnection {
  /// Creates a [JsonRpcConnection] with the specified peer and communication channel.
  JsonRpcConnection({
    required this.peerPubkeyHex,
    required rpc.Peer peer,
    required StreamChannelController<String> channelController,
    required OrderingStrategy<Map<String, dynamic>> ordering,
  }) : _peer = peer,
       _channelController = channelController,
       _ordering = ordering;

  @override
  final String peerPubkeyHex;

  final rpc.Peer _peer;
  final StreamChannelController<String> _channelController;
  final OrderingStrategy<Map<String, dynamic>> _ordering;

  /// The underlying json_rpc_2 Peer for advanced use.
  rpc.Peer get rpcPeer => _peer;
    /// Register a JSON-RPC method handler for incoming requests from the peer.
    ///
    /// [name] is the method name and [callback] is invoked with the request
    /// parameters when a matching request arrives.
    void registerMethod(String name, Function callback) =>
      _peer.registerMethod(name, callback);

    /// Register a fallback handler that receives requests which don't match any
    /// registered method. Useful for forwarding or logging unexpected calls.
    void registerFallback(void Function(rpc.Parameters) callback) =>
      _peer.registerFallback(callback);

    /// Send a JSON-RPC request to the remote peer and return its result.
    ///
    /// [method] is the RPC method name and [parameters] are optional parameters
    /// to pass. The returned `Future` completes with the response value.
    Future<dynamic> sendRequest(String method, [dynamic parameters]) =>
      _peer.sendRequest(method, parameters);

    /// Send a JSON-RPC notification (no response expected) to the remote peer.
    void sendNotification(String method, [dynamic parameters]) =>
      _peer.sendNotification(method, parameters);

  @override
  Future<void> close() async {
    _ordering.dispose();
    await _peer.close();
    await _channelController.local.sink.close();
  }
}

/// JSON-RPC 2.0 protocol with optional ordering.
///
/// Each call to [createConnection] creates one ordering instance per connection.
class JsonRpcProtocol extends RpcProtocol<JsonRpcConnection> {
  /// [orderingFactory] creates a fresh [OrderingStrategy] per connection.
  /// Defaults to [NoCacheOrdering].
  JsonRpcProtocol({
    OrderingStrategy<Map<String, dynamic>> Function()? orderingFactory,
  }) : _orderingFactory = orderingFactory ?? NoCacheOrdering.new;

  final OrderingStrategy<Map<String, dynamic>> Function() _orderingFactory;

  @override
  JsonRpcConnection createConnection(String peerPubkeyHex, RawChannel channel) {
    final ordering = _orderingFactory();

    // StreamChannelController bridges the RawChannel to json_rpc_2.
    //
    // Convention (from stream_channel package):
    //   local.sink   → data written here appears on foreign.stream
    //   local.stream ← data appears here when foreign.sink is written
    //
    // json_rpc_2 uses the "foreign" side.
    // We feed incoming network data into local.sink → appears on foreign.stream → json_rpc_2 reads.
    // json_rpc_2 writes responses to foreign.sink → appears on local.stream → we forward to relay.
    final controller = StreamChannelController<String>(sync: true);

    // Incoming: RawChannel.incoming → unwrap ordering → local.sink → json_rpc_2 foreign.stream
    channel.incoming.listen(
      (raw) {
        final decoded = _tryDecodeJsonObject(raw);
        if (decoded == null) {
          return;
        }

        ordering.handleIncoming(decoded, (payload) {
          try {
            controller.local.sink.add(jsonEncode(payload));
          } catch (_) {
            // Sink may be closed if peer disconnected
          }
        });
      },
      onDone: () {
        controller.local.sink.close();
      },
      onError: (Object err, StackTrace st) {
        controller.local.sink.close();
      },
    );

    // Outgoing: json_rpc_2 foreign.sink → local.stream → wrap ordering → RawChannel.outgoing
    controller.local.stream.listen(
      (payload) {
        final decoded = _tryDecodeJsonObject(payload);
        if (decoded == null) {
          channel.outgoing.add(payload);
          return;
        }

        final wrapped = ordering.wrapOutgoing(decoded);
        channel.outgoing.add(wrapped);
      },
      onDone: () {
        channel.outgoing.close();
      },
    );

    final peer = rpc.Peer(controller.foreign);
    // Start listening immediately so incoming events are processed.
    peer.listen();

    return JsonRpcConnection(
      peerPubkeyHex: peerPubkeyHex,
      peer: peer,
      channelController: controller,
      ordering: ordering,
    );
  }

  Map<String, dynamic>? _tryDecodeJsonObject(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }

    if (decoded is! Map) {
      return null;
    }

    return Map<String, dynamic>.from(decoded);
  }
}
