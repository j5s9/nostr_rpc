// Multi-relay manager for the Nostr protocol.
//
// Manages a pool of [WebSocketRelayClient] instances, merging their event
// streams into a single deduplicated broadcast stream.

import 'dart:async';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/event.dart';
import 'websocket_relay_client.dart';

// ---------------------------------------------------------------------------
// Internal channel wrapper that fires a callback when the stream closes.
// ---------------------------------------------------------------------------

/// Wraps a [WebSocketChannel] and fires [onStreamDone] when the incoming
/// stream ends. Used by [RelayManager] to detect unexpected relay disconnects.
class _ClosureNotifyChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _ClosureNotifyChannel(this._inner, this._onStreamDone);

  final WebSocketChannel _inner;
  final void Function() _onStreamDone;

  late final Stream<dynamic> _wrappedStream = _inner.stream.transform(
    StreamTransformer<dynamic, dynamic>.fromHandlers(
      handleData: (data, sink) => sink.add(data),
      handleError: (error, stack, sink) => sink.addError(error, stack),
      handleDone: (sink) {
        _onStreamDone();
        sink.close();
      },
    ),
  );

  @override
  Stream<dynamic> get stream => _wrappedStream;

  @override
  WebSocketSink get sink => _inner.sink;

  @override
  Future<void> get ready => _inner.ready;

  @override
  String? get protocol => _inner.protocol;

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;
}

/// Manages connections to multiple Nostr relays and provides a unified,
/// deduplicated stream of events across all connected relays.
///
/// Usage:
/// ```dart
/// final manager = RelayManager([
///   'wss://relay1.example.com',
///   'wss://relay2.example.com',
/// ]);
/// await manager.connectAll();
///
/// manager.subscribe('sub1', [{'kinds': [1]}]);
/// manager.events.listen((event) => print('Got event: ${event.id}'));
///
/// await manager.disconnectAll();
/// ```
class RelayManager {
  /// Constructs a [RelayManager] with a list of relay WebSocket URLs.
  ///
  /// The optional [channelFactory] is injected into each [WebSocketRelayClient]
  /// for testing — the same DI pattern as [WebSocketRelayClient] itself.
  RelayManager(
    List<String> relayUrls, {
    WebSocketChannel Function(Uri)? channelFactory,
  }) : _relayUrls = List.unmodifiable(relayUrls),
       _channelFactory = channelFactory;

  final List<String> _relayUrls;
  final WebSocketChannel Function(Uri)? _channelFactory;

  /// Active relay clients, keyed by their URL.
  final Map<String, WebSocketRelayClient> _connectedClients = {};

  /// Subscriptions that forward each relay's event stream to [_eventsController].
  final Map<String, StreamSubscription<NostrEvent>> _eventSubscriptions = {};

  /// Deduplicated broadcast stream controller.
  final StreamController<NostrEvent> _eventsController =
      StreamController<NostrEvent>.broadcast();

  /// Event IDs already forwarded — prevents duplicates from multiple relays.
  final Set<String> _seenIds = {};

  /// Currently connected relay URLs.
  List<String> get connectedRelays => List.unmodifiable(_connectedClients.keys);

  /// Merged, deduplicated stream of [NostrEvent]s from all connected relays.
  Stream<NostrEvent> get events => _eventsController.stream;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Connects to all relays in parallel.
  ///
  /// Partial failure is tolerated: if a relay throws during [connect()], it is
  /// excluded from [connectedRelays] but no exception is thrown by this method.
  Future<void> connectAll() async {
    final futures = _relayUrls.map((url) => _connectOne(url));
    await Future.wait(futures, eagerError: false);
  }

  Future<void> _connectOne(String url) async {
    // Wrap the channel factory so we get notified when the channel stream ends.
    WebSocketChannel Function(Uri) wrappedFactory;
    if (_channelFactory != null) {
      wrappedFactory =
          (uri) => _ClosureNotifyChannel(
            _channelFactory(uri),
            () => _onRelayStreamDone(url),
          );
    } else {
      wrappedFactory =
          (uri) => _ClosureNotifyChannel(
            WebSocketChannel.connect(uri),
            () => _onRelayStreamDone(url),
          );
    }

    final client = WebSocketRelayClient(url, channelFactory: wrappedFactory);

    try {
      await client.connect();
    } catch (_) {
      // Failed to connect — exclude this relay.
      return;
    }

    _connectedClients[url] = client;

    // Forward events from this relay into the merged stream, with dedup.
    final sub = client.events.listen((event) {
      if (!_seenIds.contains(event.id)) {
        _seenIds.add(event.id);
        if (!_eventsController.isClosed) {
          _eventsController.add(event);
        }
      }
    }, cancelOnError: false);

    _eventSubscriptions[url] = sub;
  }

  /// Called when a relay's underlying WebSocket stream closes unexpectedly.
  void _onRelayStreamDone(String url) {
    _connectedClients.remove(url);
    final sub = _eventSubscriptions.remove(url);
    sub?.cancel();
  }

  /// Disconnects all relays and closes the merged events stream.
  Future<void> disconnectAll() async {
    // Cancel all forwarding subscriptions first.
    for (final sub in _eventSubscriptions.values) {
      await sub.cancel();
    }
    _eventSubscriptions.clear();

    // Disconnect each relay client.
    final clients = Map<String, WebSocketRelayClient>.of(_connectedClients);
    _connectedClients.clear();
    for (final client in clients.values) {
      await client.disconnect();
    }

    if (!_eventsController.isClosed) {
      await _eventsController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Protocol operations (broadcast to all connected relays)
  // ---------------------------------------------------------------------------

  /// Sends a REQ message to all connected relays.
  void subscribe(String subscriptionId, List<Map<String, dynamic>> filters) {
    for (final client in _connectedClients.values) {
      client.subscribe(subscriptionId, filters);
    }
  }

  /// Sends a CLOSE message to all connected relays.
  void unsubscribe(String subscriptionId) {
    for (final client in _connectedClients.values) {
      client.unsubscribe(subscriptionId);
    }
  }

  /// Publishes an event to all connected relays.
  ///
  /// Best-effort: if one relay fails the others still receive the event.
  Future<void> publish(NostrEvent event) async {
    final futures = _connectedClients.values.map((c) => c.publish(event));
    await Future.wait(futures, eagerError: false);
  }
}
