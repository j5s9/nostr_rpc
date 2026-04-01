// WebSocket relay client for the Nostr JSON wire protocol (NIP-01).
//
// This client handles a single relay connection and exposes streams for
// incoming events, notices, OK results, and EOSE signals.
//
// Wire protocol (NIP-01):
//   Client → Relay: ["REQ", subId, filter...], ["CLOSE", subId], ["EVENT", eventJson]
//   Relay → Client: ["EVENT", subId, eventJson], ["OK", eventId, bool, msg],
//                   ["EOSE", subId], ["NOTICE", msg]

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/event.dart';

/// Result of a relay OK message in response to a published event.
class OkResult {
  final String eventId;
  final bool accepted;
  final String message;

  const OkResult({
    required this.eventId,
    required this.accepted,
    required this.message,
  });
}

/// A single-relay WebSocket client that speaks the Nostr NIP-01 wire protocol.
///
/// Usage:
/// ```dart
/// final client = WebSocketRelayClient('wss://relay.example.com');
/// await client.connect();
///
/// client.subscribe('sub1', [{'kinds': [1]}]);
/// client.events.listen((event) => print('Got event: ${event.id}'));
///
/// await client.disconnect();
/// ```
class WebSocketRelayClient {
  WebSocketRelayClient(
    String url, {
    WebSocketChannel Function(Uri)? channelFactory,
  }) : _url = url,
       _channelFactory = channelFactory ?? WebSocketChannel.connect;

  final String _url;
  final WebSocketChannel Function(Uri) _channelFactory;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _isConnected = false;

  final StreamController<NostrEvent> _eventsController =
      StreamController<NostrEvent>.broadcast();
  final StreamController<String> _noticesController =
      StreamController<String>.broadcast();
  final StreamController<OkResult> _okResultsController =
      StreamController<OkResult>.broadcast();
  final StreamController<String> _eoseController =
      StreamController<String>.broadcast();

  /// Whether the client is currently connected to the relay.
  bool get isConnected => _isConnected;

  /// Stream of parsed [NostrEvent]s received from the relay via EVENT messages.
  Stream<NostrEvent> get events => _eventsController.stream;

  /// Stream of NOTICE messages from the relay.
  Stream<String> get notices => _noticesController.stream;

  /// Stream of OK results from the relay (responses to published events).
  Stream<OkResult> get okResults => _okResultsController.stream;

  /// Stream of EOSE signals (subscription IDs) from the relay.
  Stream<String> get eoseSignals => _eoseController.stream;

  /// Connects to the relay and begins listening for messages.
  Future<void> connect() async {
    final uri = Uri.parse(_url);
    _channel = _channelFactory(uri);
    _isConnected = true;

    _subscription = _channel!.stream.listen(
      _handleMessage,
      onError: (Object error, StackTrace stackTrace) {
        // Errors are silently absorbed; consumers close via disconnect().
      },
      onDone: () {
        _isConnected = false;
      },
      cancelOnError: false,
    );
  }

  /// Disconnects from the relay and closes all output streams.
  Future<void> disconnect() async {
    _isConnected = false;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;

    if (!_eventsController.isClosed) await _eventsController.close();
    if (!_noticesController.isClosed) await _noticesController.close();
    if (!_okResultsController.isClosed) await _okResultsController.close();
    if (!_eoseController.isClosed) await _eoseController.close();
  }

  /// Sends a REQ message: `["REQ", subscriptionId, ...filters]`.
  void subscribe(String subscriptionId, List<Map<String, dynamic>> filters) {
    final msg = jsonEncode(['REQ', subscriptionId, ...filters]);
    _channel?.sink.add(msg);
  }

  /// Sends a CLOSE message: `["CLOSE", subscriptionId]`.
  void unsubscribe(String subscriptionId) {
    final msg = jsonEncode(['CLOSE', subscriptionId]);
    _channel?.sink.add(msg);
  }

  /// Sends an EVENT message: `["EVENT", event.toJson()]`.
  Future<void> publish(NostrEvent event) async {
    final msg = jsonEncode(['EVENT', event.toJson()]);
    _channel?.sink.add(msg);
  }

  // ---------------------------------------------------------------------------
  // Incoming frame dispatch
  // ---------------------------------------------------------------------------

  void _handleMessage(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as List<dynamic>;
      if (data.isEmpty) return;

      final type = data[0];
      switch (type) {
        case 'EVENT':
          _handleEvent(data);
        case 'OK':
          _handleOk(data);
        case 'NOTICE':
          _handleNotice(data);
        case 'EOSE':
          _handleEose(data);
        default:
          // Unknown message type — silently ignore per NIP-01.
          break;
      }
    } catch (_) {
      // Malformed JSON or unexpected structure — silently ignore.
    }
  }

  void _handleEvent(List<dynamic> data) {
    // ["EVENT", subscriptionId, eventJson]
    if (data.length < 3) return;
    final eventJson = data[2];
    if (eventJson is! Map<String, dynamic>) return;

    try {
      final event = NostrEvent.fromJson(eventJson);
      if (!_eventsController.isClosed) {
        _eventsController.add(event);
      }
    } catch (_) {
      // Malformed event — silently ignore.
    }
  }

  void _handleOk(List<dynamic> data) {
    // ["OK", eventId, accepted, message]
    if (data.length < 3) return;
    final eventId = data[1];
    if (eventId is! String) return;

    final accepted = data[2] == true;
    final message = data.length > 3 ? (data[3]?.toString() ?? '') : '';

    if (!_okResultsController.isClosed) {
      _okResultsController.add(
        OkResult(eventId: eventId, accepted: accepted, message: message),
      );
    }
  }

  void _handleNotice(List<dynamic> data) {
    // ["NOTICE", message]
    if (data.length < 2) return;
    final notice = data[1]?.toString();
    if (notice == null) return;

    if (!_noticesController.isClosed) {
      _noticesController.add(notice);
    }
  }

  void _handleEose(List<dynamic> data) {
    // ["EOSE", subscriptionId]
    if (data.length < 2) return;
    final subId = data[1]?.toString();
    if (subId == null) return;

    if (!_eoseController.isClosed) {
      _eoseController.add(subId);
    }
  }
}
