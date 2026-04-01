import '../ordering/sequence_cache_ordering.dart';
import '../ordering/ordering_strategy.dart';
import 'json_rpc_protocol.dart';

/// JSON-RPC protocol with SequenceCacheOrdering — the DEFAULT protocol.
class JsonRpcWithSequenceCacheProtocol extends JsonRpcProtocol {
  JsonRpcWithSequenceCacheProtocol({
    Duration timeout = const Duration(milliseconds: 500),
    TimeoutFallback fallback = TimeoutFallback.flushOutOfOrder,
  }) : super(
         orderingFactory:
             () => SequenceCacheOrdering(timeout: timeout, fallback: fallback),
       );
}
