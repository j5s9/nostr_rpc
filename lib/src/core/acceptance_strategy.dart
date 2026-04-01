/// Strategy interface for deciding whether to accept an incoming connection
/// from a peer identified by their hex public key.
abstract class AcceptanceStrategy {
  /// Returns true if the peer with [peerPubkeyHex] should be accepted.
  Future<bool> shouldAccept(String peerPubkeyHex);

  /// Release any resources held by this strategy (e.g., clear caches).
  void dispose() {}
}

/// Always accepts any peer without asking.
class AlwaysAcceptStrategy extends AcceptanceStrategy {
  /// Creates an instance of [AlwaysAcceptStrategy].
  AlwaysAcceptStrategy();

  @override
  Future<bool> shouldAccept(String peerPubkeyHex) async => true;
}

/// Always invokes the [onNewPeer] callback for every peer, every time.
class AlwaysAskStrategy extends AcceptanceStrategy {
  /// Creates an instance of [AlwaysAskStrategy] with the given [onNewPeer] callback.
  AlwaysAskStrategy({required Future<bool> Function(String pubkey) onNewPeer})
    : _onNewPeer = onNewPeer;

  final Future<bool> Function(String pubkey) _onNewPeer;

  @override
  Future<bool> shouldAccept(String peerPubkeyHex) => _onNewPeer(peerPubkeyHex);
}

/// Invokes the [onNewPeer] callback the first time a peer is seen,
/// then caches the result for subsequent calls.
/// Also handles concurrent requests for the same peer — callback called only ONCE.
class CachedApprovalStrategy extends AcceptanceStrategy {
  /// Creates an instance of [CachedApprovalStrategy] with the given [onNewPeer] callback.
  CachedApprovalStrategy({
    required Future<bool> Function(String pubkey) onNewPeer,
  }) : _onNewPeer = onNewPeer;

  final Future<bool> Function(String pubkey) _onNewPeer;
  final Map<String, bool> _cache = {};
  final Map<String, Future<bool>> _pending = {}; // concurrent request dedup

  @override
  Future<bool> shouldAccept(String peerPubkeyHex) {
    if (_cache.containsKey(peerPubkeyHex)) {
      return Future.value(_cache[peerPubkeyHex]);
    }
    // If there's already a pending call, reuse it
    if (_pending.containsKey(peerPubkeyHex)) {
      return _pending[peerPubkeyHex]!;
    }
    final future = _onNewPeer(peerPubkeyHex).then((result) {
      _cache[peerPubkeyHex] = result;
      _pending.remove(peerPubkeyHex);
      return result;
    });
    _pending[peerPubkeyHex] = future;
    return future;
  }

  @override
  void dispose() {
    _cache.clear();
    _pending.clear();
  }
}
