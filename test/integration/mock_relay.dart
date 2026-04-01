// In-process mock Nostr relay using dart:io HttpServer + WebSocket upgrade.
//
// Implements a minimal NIP-01 relay:
//   Client → Relay: ["EVENT", eventJson], ["REQ", subId, filter], ["CLOSE", subId]
//   Relay → Client (EVENT): ["OK", eventId, true, ""] + broadcast ["EVENT", subId, eventJson] to all
//   Relay → Client (REQ):   ["EOSE", subId]
//   Relay → Client (CLOSE): (ignored silently)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An in-process WebSocket relay that broadcasts events to all connected clients.
class MockRelay {
  HttpServer? _server;
  final List<WebSocket> _clients = [];
  int _port = 0;

  /// Start the relay on a random available port.
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;

    _server!.listen((HttpRequest request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final ws = await WebSocketTransformer.upgrade(request);
        _handleClient(ws);
      } else {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..close();
      }
    });
  }

  /// Stop the relay and close all connected clients.
  Future<void> stop() async {
    // Close all client connections.
    final clients = List<WebSocket>.of(_clients);
    for (final ws in clients) {
      await ws.close();
    }
    _clients.clear();

    await _server?.close(force: true);
    _server = null;
  }

  /// The WebSocket URL for this relay (e.g. ws://127.0.0.1:PORT).
  String get wsUrl => 'ws://127.0.0.1:$_port';

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _handleClient(WebSocket ws) {
    _clients.add(ws);

    ws.listen(
      (dynamic raw) {
        if (raw is String) {
          _handleMessage(ws, raw);
        }
      },
      onDone: () {
        _clients.remove(ws);
      },
      onError: (Object _) {
        _clients.remove(ws);
      },
      cancelOnError: false,
    );
  }

  void _handleMessage(WebSocket sender, String raw) {
    try {
      final msg = jsonDecode(raw) as List<dynamic>;
      if (msg.isEmpty) return;

      final type = msg[0] as String;
      switch (type) {
        case 'EVENT':
          _handleEvent(sender, msg);
        case 'REQ':
          _handleReq(sender, msg);
        case 'CLOSE':
          // Silently ignore.
          break;
        default:
          // Unknown message — ignore per NIP-01.
          break;
      }
    } catch (_) {
      // Malformed JSON — ignore.
    }
  }

  void _handleEvent(WebSocket sender, List<dynamic> msg) {
    // ["EVENT", eventJson]
    if (msg.length < 2) return;
    final eventJson = msg[1];
    if (eventJson is! Map<String, dynamic>) return;

    final eventId = eventJson['id'] as String?;
    if (eventId == null) return;

    // Send OK to sender.
    final okMsg = jsonEncode(['OK', eventId, true, '']);
    try {
      sender.add(okMsg);
    } catch (_) {}

    // Broadcast ["EVENT", subId, eventJson] to ALL connected clients.
    // We use a fixed subscription ID "nostr_rpc" to match what NostrRpc subscribes with.
    final broadcastMsg = jsonEncode(['EVENT', 'nostr_rpc', eventJson]);
    for (final client in List<WebSocket>.of(_clients)) {
      try {
        client.add(broadcastMsg);
      } catch (_) {}
    }
  }

  void _handleReq(WebSocket sender, List<dynamic> msg) {
    // ["REQ", subId, filter...]
    if (msg.length < 2) return;
    final subId = msg[1] as String?;
    if (subId == null) return;

    // Immediately reply with EOSE — no historical events.
    final eoseMsg = jsonEncode(['EOSE', subId]);
    try {
      sender.add(eoseMsg);
    } catch (_) {}
  }
}
