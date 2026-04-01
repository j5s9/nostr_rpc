import 'dart:async';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:stream_channel/stream_channel.dart';

import '../ordering/ordering_strategy.dart';
import '../ordering/no_cache_ordering.dart';
import 'rpc_protocol.dart';

class JsonRpcConnection extends RpcConnection {
  JsonRpcConnection({
    required this.peerPubkeyHex,
    required rpc.Peer peer,
    required StreamChannelController<String> channelController,
    required OrderingStrategy ordering,
  }) : _peer = peer,
       _channelController = channelController,
       _ordering = ordering;

  @override
  final String peerPubkeyHex;

  final rpc.Peer _peer;
  final StreamChannelController<String> _channelController;
  final OrderingStrategy _ordering;

  /// The underlying json_rpc_2 Peer for advanced use.
  rpc.Peer get rpcPeer => _peer;

  void registerMethod(String name, Function callback) =>
      _peer.registerMethod(name, callback);

  void registerFallback(void Function(rpc.Parameters) callback) =>
      _peer.registerFallback(callback);

  Future<dynamic> sendRequest(String method, [dynamic parameters]) =>
      _peer.sendRequest(method, parameters);

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
  JsonRpcProtocol({OrderingStrategy Function()? orderingFactory})
    : _orderingFactory = orderingFactory ?? NoCacheOrdering.new;

  final OrderingStrategy Function() _orderingFactory;

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
        ordering.handleIncoming(raw, (payload) {
          try {
            controller.local.sink.add(payload);
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
        final wrapped = ordering.wrapOutgoing(payload);
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
}
