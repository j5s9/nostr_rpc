import 'dart:async';

import '../crypto/nip59.dart';
import '../crypto/event.dart';
import '../transport/relay_manager.dart';
import 'acceptance_strategy.dart';
import '../protocol/rpc_protocol.dart';
import '../protocol/json_rpc_protocol.dart';
import '../protocol/json_rpc_with_sequence_cache_protocol.dart';
import '../identity.dart';

/// Generic, protocol-agnostic Nostr RPC engine.
///
/// [T] is the connection type produced by the [RpcProtocol].
///
/// When no [protocol] is provided, [T] must be [JsonRpcConnection] and the
/// default [JsonRpcWithSequenceCacheProtocol] is used.
class NostrRpc<T extends RpcConnection> {
  /// [relays]: list of relay WebSocket URLs
  /// [identity]: local Nostr identity
  /// [protocol]: protocol to use (default: JsonRpcWithSequenceCacheProtocol)
  /// [acceptanceStrategy]: strategy for incoming peers (default: AlwaysAcceptStrategy)
  /// [relayManager]: injected relay manager (for testing)
  NostrRpc({
    required List<String> relays,
    required NostrIdentity identity,
    RpcProtocol<T>? protocol,
    AcceptanceStrategy? acceptanceStrategy,
    RelayManager? relayManager,
  }) : _identity = identity,
       // When no protocol is given, default to JsonRpcWithSequenceCacheProtocol.
       // The cast is safe when T == JsonRpcConnection (the typical default).
       _protocol =
           protocol ?? (JsonRpcWithSequenceCacheProtocol() as RpcProtocol<T>),
       _acceptanceStrategy = acceptanceStrategy ?? AlwaysAcceptStrategy(),
       _relayManager = relayManager ?? RelayManager(relays);

  final NostrIdentity _identity;
  final RpcProtocol<T> _protocol;
  final AcceptanceStrategy _acceptanceStrategy;
  final RelayManager _relayManager;

  /// Active connections, keyed by peer pubkey hex.
  final Map<String, T> _connections = {};

  /// Incoming RawChannel controllers, keyed by peer pubkey hex.
  final Map<String, StreamController<String>> _incomingControllers = {};

  /// Outgoing RawChannel subscriptions (reads from json_rpc_2, writes to relay).
  final Map<String, StreamSubscription<String>> _outgoingSubscriptions = {};

  StreamSubscription<NostrEvent>? _eventsSubscription;

  final StreamController<T> _onPeerConnectedController =
      StreamController<T>.broadcast();

  /// Stream that emits a new [T] connection when an inbound peer is accepted.
  Stream<T> get onPeerConnected => _onPeerConnectedController.stream;

  /// All currently active connections.
  List<T> get connections => List.unmodifiable(_connections.values);

  /// Own identity.
  NostrIdentity get identity => _identity;

  /// Start the relay connections and begin listening for inbound events.
  Future<void> start() async {
    await _relayManager.connectAll();
    _relayManager.subscribe('nostr_rpc', [
      {
        'kinds': [1059], // NIP-59 gift wrap kind
        '#p': [_identity.pubkeyHex],
      },
    ]);
    _eventsSubscription = _relayManager.events.listen(_handleIncomingEvent);
  }

  /// Stop all connections and disconnect relays.
  Future<void> dispose() async {
    await _eventsSubscription?.cancel();
    _eventsSubscription = null;

    for (final sub in _outgoingSubscriptions.values) {
      await sub.cancel();
    }
    _outgoingSubscriptions.clear();

    for (final ctrl in _incomingControllers.values) {
      await ctrl.close();
    }
    _incomingControllers.clear();

    for (final conn in _connections.values) {
      await conn.close();
    }
    _connections.clear();

    _relayManager.unsubscribe('nostr_rpc');
    await _relayManager.disconnectAll();

    if (!_onPeerConnectedController.isClosed) {
      await _onPeerConnectedController.close();
    }

    _acceptanceStrategy.dispose();
    _protocol.dispose();
  }

  /// Get an existing connection, or null if none.
  T? getConnection(String peerPubkeyHex) => _connections[peerPubkeyHex];

  /// Get existing connection, OR create a new outbound connection to the peer.
  ///
  /// This bypasses AcceptanceStrategy (user explicitly chose the peer).
  /// Does NOT emit on [onPeerConnected] (that is only for inbound).
  T getOrCreateConnection(String peerPubkeyHex) {
    return _connections.putIfAbsent(peerPubkeyHex, () {
      return _createConnection(peerPubkeyHex);
    });
  }

  // ---------------------------------------------------------------------------
  // Internal event processing
  // ---------------------------------------------------------------------------

  void _handleIncomingEvent(NostrEvent event) {
    // Run async processing but don't block the stream listener.
    _processEvent(event).catchError((Object _) {
      // Silently ignore unwrap errors (not our message, wrong key, etc.)
    });
  }

  Future<void> _processEvent(NostrEvent event) async {
    // Only process kind 1059 (gift wrap) events.
    if (event.kind != 1059) return;

    // Reconstruct GiftWrapEvent from the NostrEvent JSON.
    final GiftWrapEvent giftWrap;
    try {
      giftWrap = GiftWrapEvent.fromJson(event.toJson());
    } catch (_) {
      return; // Malformed gift wrap
    }

    // Unwrap the gift wrap using our private key.
    final UnwrappedGift unwrapped;
    try {
      unwrapped = await Nip59.unwrap(
        giftWrap: giftWrap,
        recipientPrivkeyBytes: _identity.privkeyBytes,
      );
    } catch (_) {
      return; // Not intended for us or malformed
    }

    final senderPubkey = unwrapped.senderPubkey;
    final content = unwrapped.content;

    // Look up or create connection.
    if (!_connections.containsKey(senderPubkey)) {
      // New peer — check acceptance.
      final accepted = await _acceptanceStrategy.shouldAccept(senderPubkey);
      if (!accepted) return;

      final connection = _createConnection(senderPubkey);
      // Emit on onPeerConnected for inbound peers.
      if (!_onPeerConnectedController.isClosed) {
        _onPeerConnectedController.add(connection);
      }
    }

    // Forward content to the incoming channel for this peer.
    final incomingCtrl = _incomingControllers[senderPubkey];
    if (incomingCtrl != null && !incomingCtrl.isClosed) {
      incomingCtrl.add(content);
    }
  }

  T _createConnection(String peerPubkeyHex) {
    // Create an incoming stream controller for messages from this peer.
    final incomingCtrl = StreamController<String>.broadcast();
    _incomingControllers[peerPubkeyHex] = incomingCtrl;

    // Create an outgoing sink that wraps to NIP-59 and publishes.
    final outgoingCtrl = StreamController<String>();
    final outgoingSub = outgoingCtrl.stream.listen((payload) {
      _sendToRelay(peerPubkeyHex, payload);
    });
    _outgoingSubscriptions[peerPubkeyHex] = outgoingSub;

    final channel = RawChannel(incomingCtrl.stream, outgoingCtrl.sink);
    final connection = _protocol.createConnection(peerPubkeyHex, channel);
    _connections[peerPubkeyHex] = connection;
    return connection;
  }

  void _sendToRelay(String peerPubkeyHex, String plaintext) {
    // Async — don't await, publish is fire-and-forget.
    _wrapAndPublish(peerPubkeyHex, plaintext).catchError((Object _) {});
  }

  Future<void> _wrapAndPublish(String peerPubkeyHex, String plaintext) async {
    final giftWrap = await Nip59.wrap(
      content: plaintext,
      senderPrivkeyBytes: _identity.privkeyBytes,
      senderPubkeyHex: _identity.pubkeyHex,
      recipientPubkeyHex: peerPubkeyHex,
      kind: 14, // NIP-17 DM kind
    );

    // Convert GiftWrapEvent → NostrEvent for publishing.
    final nostrEvent = NostrEvent.fromJson(giftWrap.toJson());
    await _relayManager.publish(nostrEvent);
  }
}
