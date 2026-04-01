import 'dart:async';

/// A raw string channel between two peers.
/// [incoming] carries decrypted, unwrapped strings arriving from the peer.
/// [outgoing] is where the protocol writes strings to be encrypted and sent.
class RawChannel {
  RawChannel(this.incoming, this.outgoing);
  final Stream<String> incoming;
  final StreamSink<String> outgoing;
}

/// Base class for protocol-specific connections.
abstract class RpcConnection {
  /// The hex-encoded public key of the connected peer.
  String get peerPubkeyHex;

  /// Close this connection and release its resources.
  Future<void> close();
}

/// Pluggable protocol abstraction.
/// [T] is the concrete connection type created by this protocol.
abstract class RpcProtocol<T extends RpcConnection> {
  /// Create a protocol-specific connection for [peerPubkeyHex] using [channel].
  T createConnection(String peerPubkeyHex, RawChannel channel);

  /// Release resources held by this protocol instance.
  void dispose() {}
}
