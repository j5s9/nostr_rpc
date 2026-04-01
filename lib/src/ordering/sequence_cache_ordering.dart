import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'ordering_strategy.dart';
import 'sequence_wrapper.dart';

/// In-order delivery with out-of-order buffering and timeout fallback.
///
/// Uses a [SplayTreeMap] to buffer out-of-order messages by sequence number.
/// When seq==expected, delivers immediately and drains buffer.
/// When seq>expected, buffers and starts a [Timer].
/// When timer fires, applies [TimeoutFallback] strategy.
class SequenceCacheOrdering extends OrderingStrategy {
  SequenceCacheOrdering({
    this.timeout = const Duration(milliseconds: 500),
    this.fallback = TimeoutFallback.flushOutOfOrder,
    int startSeq = 0,
  }) : _expectedSeq = startSeq;

  final Duration timeout;
  final TimeoutFallback fallback;

  int _outgoingSeq = 0;
  int _expectedSeq;
  final SplayTreeMap<int, String> _buffer = SplayTreeMap<int, String>();
  Timer? _timer;
  // ignore: unused_field
  void Function(String payload)? _currentDeliver;

  @override
  String wrapOutgoing(String payload) {
    final wrapped = SequenceWrapper.wrap(_outgoingSeq, payload);
    _outgoingSeq++;
    return wrapped;
  }

  @override
  void handleIncoming(String raw, void Function(String payload) deliver) {
    final wrapped = _tryUnwrap(raw);
    if (wrapped == null) {
      deliver(raw);
      return;
    }

    final (seq, data) = wrapped;
    _currentDeliver = deliver;

    if (seq == _expectedSeq) {
      // In-order: deliver immediately, drain buffer
      _deliverAndDrain(seq, data, deliver);
    } else if (seq > _expectedSeq) {
      // Out-of-order: buffer and start timer if not already running
      _buffer[seq] = data;
      _startTimerIfNeeded(deliver);
    }
    // seq < _expectedSeq → ignore (duplicate or old)
  }

  (int, String)? _tryUnwrap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return null;
    final seq = decoded['seq'];
    final data = decoded['data'];
    if (seq is! int || data is! String) return null;
    return (seq, data);
  }

  void _deliverAndDrain(int seq, String data, void Function(String) deliver) {
    _cancelTimer();
    deliver(data);
    _expectedSeq = seq + 1;

    // Drain any buffered messages that are now in-order
    while (_buffer.containsKey(_expectedSeq)) {
      final next = _buffer.remove(_expectedSeq)!;
      deliver(next);
      _expectedSeq++;
    }

    // If there are still buffered items (gap remains), restart timer
    if (_buffer.isNotEmpty) {
      _startTimerIfNeeded(deliver);
    }
  }

  void _startTimerIfNeeded(void Function(String) deliver) {
    if (_timer != null) return; // already running
    _timer = Timer(timeout, () => _onTimeout(deliver));
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTimeout(void Function(String) deliver) {
    _timer = null;
    switch (fallback) {
      case TimeoutFallback.flushOutOfOrder:
        // Deliver all buffered messages in order, skipping gaps
        while (_buffer.isNotEmpty) {
          final seq = _buffer.firstKey()!;
          final data = _buffer.remove(seq)!;
          deliver(data);
          _expectedSeq = seq + 1;
        }
      case TimeoutFallback.dropMissing:
        // Skip to the next buffered seq, discard the gap
        if (_buffer.isNotEmpty) {
          final seq = _buffer.firstKey()!;
          _expectedSeq = seq; // pretend we got everything up to here
          _deliverAndDrain(seq, _buffer.remove(seq)!, deliver);
        }
      case TimeoutFallback.throwOnMissing:
        _buffer.clear();
        throw SequenceGapException(
          'Missing sequence number $_expectedSeq after timeout.',
        );
    }
  }

  @override
  void dispose() {
    _cancelTimer();
    _buffer.clear();
    _currentDeliver = null;
  }
}
