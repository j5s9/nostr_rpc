/// Wraps/unwraps payloads with a sequence number.
/// Wire format: `{"seq": <int>, "data": <payload json>}`
class SequenceWrapper {
  /// Wrap [payload] with sequence number [seq].
  /// Returns a JSON-ready map: {"seq": seq, "data": payload}
  static Map<String, dynamic> wrap<T>(int seq, T payload) {
    return {'seq': seq, 'data': payload};
  }

  /// Unwrap a wrapped JSON object.
  /// Returns (seq, data) as a record.
  /// Throws [FormatException] if the format is invalid.
  static (int seq, T data) unwrap<T>(Map<String, dynamic> wrapped) {
    final hasSeq = wrapped.containsKey('seq');
    final hasData = wrapped.containsKey('data');
    final seqVal = wrapped['seq'];
    final dataVal = wrapped['data'];

    if (!hasSeq) {
      throw FormatException('Missing "seq" field in wrapped message', wrapped);
    }
    if (!hasData) {
      throw FormatException('Missing "data" field in wrapped message', wrapped);
    }
    if (seqVal is! int) {
      throw FormatException(
        '"seq" field must be an integer, got ${seqVal.runtimeType}',
        wrapped,
      );
    }
    if (dataVal is! T) {
      throw FormatException(
        '"data" field must be of type ${T.toString()}, got ${dataVal.runtimeType}',
        wrapped,
      );
    }

    return (seqVal, dataVal);
  }
}
