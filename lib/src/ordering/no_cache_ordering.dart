import 'dart:convert';

import 'ordering_strategy.dart';

/// Passthrough ordering strategy — no buffering, no reordering, no wrapping.
/// Delivers incoming messages immediately as-is.
/// Outgoing messages are sent as-is (no sequence numbers).
class NoCacheOrdering extends OrderingStrategy<Map<String, dynamic>> {
  @override
  String wrapOutgoing(Map<String, dynamic> payload) => jsonEncode(payload);

  @override
  void handleIncoming(
    Map<String, dynamic> raw,
    void Function(Map<String, dynamic> payload) deliver,
  ) {
    // Deliver immediately without any unwrapping
    deliver(raw);
  }

  @override
  void dispose() {}
}
