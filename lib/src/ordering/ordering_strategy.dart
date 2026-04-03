/// Enum for what SequenceCacheOrdering does when a gap timeout fires.
enum TimeoutFallback {
  /// Deliver all buffered messages in sequence order, skipping gaps.
  flushOutOfOrder,

  /// Skip missing seq numbers, deliver next expected.
  dropMissing,

  /// Throw a StateError when a gap is detected after timeout.
  throwOnMissing,
}

/// Exception thrown when a sequence gap is detected after timeout.
class SequenceGapException implements Exception {
  SequenceGapException(this.message);

  final String message;

  @override
  String toString() => 'SequenceGapException: $message';
}

/// Abstract strategy for wrapping outgoing payloads with ordering info
/// and reordering incoming payloads before delivery.
abstract class OrderingStrategy<T> {
  /// Wrap an outgoing payload (e.g., add sequence number).
  String wrapOutgoing(T payload);

  /// Handle an incoming raw message (wrapped with seq).
  /// Calls [deliver] with the unwrapped payload when ready to deliver.
  void handleIncoming(
    Map<String, dynamic> raw,
    void Function(T payload) deliver,
  );

  /// Release resources (cancel timers, clear buffers).
  void dispose();
}
