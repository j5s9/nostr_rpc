import 'dart:convert';

/// Wraps/unwraps payloads with a sequence number.
/// Wire format: `{"seq": <int>, "data": "<payload string>"}`
class SequenceWrapper {
  /// Wrap [payload] with sequence number [seq].
  /// Returns JSON string: {"seq": seq, "data": payload}
  static String wrap(int seq, String payload) {
    return jsonEncode({'seq': seq, 'data': payload});
  }

  /// Unwrap a wrapped JSON string.
  /// Returns (seq, data) as a record.
  /// Throws [FormatException] if the format is invalid.
  static (int seq, String data) unwrap(String wrapped) {
    final Object? decoded;
    try {
      decoded = jsonDecode(wrapped);
    } catch (e) {
      throw FormatException('Invalid JSON in wrapped message: $e', wrapped);
    }

    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Expected a JSON object, got ${decoded.runtimeType}',
        wrapped,
      );
    }

    final seqVal = decoded['seq'];
    final dataVal = decoded['data'];

    if (seqVal == null) {
      throw FormatException('Missing "seq" field in wrapped message', wrapped);
    }
    if (dataVal == null) {
      throw FormatException('Missing "data" field in wrapped message', wrapped);
    }
    if (seqVal is! int) {
      throw FormatException(
        '"seq" field must be an integer, got ${seqVal.runtimeType}',
        wrapped,
      );
    }
    if (dataVal is! String) {
      throw FormatException(
        '"data" field must be a string, got ${dataVal.runtimeType}',
        wrapped,
      );
    }

    return (seqVal, dataVal);
  }
}
