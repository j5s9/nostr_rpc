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
class SequenceCacheOrdering extends OrderingStrategy<Map<String, dynamic>> {
  SequenceCacheOrdering({
    this.timeout = const Duration(milliseconds: 500),
    this.fallback = TimeoutFallback.flushOutOfOrder,
    int startSeq = 0,
  }) : _expectedSeq = startSeq;

  final Duration timeout;
  final TimeoutFallback fallback;

  int _outgoingSeq = 0;
  int _expectedSeq;
  final SplayTreeMap<int, Map<String, dynamic>> _buffer =
      SplayTreeMap<int, Map<String, dynamic>>();
  Timer? _timer;

  @override
  String wrapOutgoing(Map<String, dynamic> payload) {
    final wrapped = SequenceWrapper.wrap(_outgoingSeq, payload);
    _outgoingSeq++;
    return jsonEncode(wrapped);
  }

  @override
  void handleIncoming(
    Map<String, dynamic> raw,
    void Function(Map<String, dynamic> payload) deliver,
  ) {
    final wrapped = _tryUnwrap(raw);
    if (wrapped == null) {
      deliver(raw);
      return;
    }

    final (seq, data) = wrapped;
    // deliver is passed to timer closures directly; no field needed

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

  (int, Map<String, dynamic>)? _tryUnwrap(Map<String, dynamic> raw) {
    final seq = raw['seq'];
    final data = raw['data'];
    if (seq is! int || data is! Map) return null;

    return (seq, Map<String, dynamic>.from(data));
  }

  void _deliverAndDrain(
    int seq,
    Map<String, dynamic> data,
    void Function(Map<String, dynamic>) deliver,
  ) {
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

  void _startTimerIfNeeded(void Function(Map<String, dynamic>) deliver) {
    if (_timer != null) return; // already running
    _timer = Timer(timeout, () => _onTimeout(deliver));
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTimeout(void Function(Map<String, dynamic>) deliver) {
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
  }
}
