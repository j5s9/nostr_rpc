import 'ordering_strategy.dart';

/// Passthrough ordering strategy — no buffering, no reordering, no wrapping.
/// Delivers incoming messages immediately as-is.
/// Outgoing messages are sent as-is (no sequence numbers).
class NoCacheOrdering extends OrderingStrategy {
  @override
  String wrapOutgoing(String payload) => payload;

  @override
  void handleIncoming(String raw, void Function(String payload) deliver) {
    // Deliver immediately without any unwrapping
    deliver(raw);
  }

  @override
  void dispose() {}
}
