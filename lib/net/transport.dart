import 'dart:async';

/// How a peer-to-peer link is made: over the local network, over Bluetooth, or through public
/// Nostr relays for players who aren't nearby.
enum LinkKind { lan, bluetooth, relay }

/// A player that can be joined.
class PeerInfo {
  PeerInfo({required this.id, required this.name, required this.kind, this.address, this.port, this.extra});
  final String id;
  final String name;
  final LinkKind kind;
  final String? address;
  final int? port;
  final Object? extra;

  @override
  String toString() => '$name ($kind ${address ?? ''}${port != null ? ':$port' : ''})';
}

enum LinkState { connecting, connected, closed, failed }

/// A bidirectional message channel to one peer. Messages are strings (JSON); ordering and
/// delivery guarantees come from LockstepMatch on top, so a transport may drop or reorder.
abstract class Transport {
  LinkKind get kind;
  Stream<String> get messages;
  Stream<LinkState> get stateChanges;
  LinkState get state;
  Future<void> send(String message);
  Future<void> close();
}

/// Advertises this device and accepts one connection (the host side).
abstract class HostLink {
  Stream<Transport> get connections;
  Future<void> start({required String name, required String id});
  Future<void> stop();
}

/// Finds hosts and connects to one (the guest side).
abstract class GuestLink {
  Stream<List<PeerInfo>> get peers;
  Future<void> startScan();
  Future<void> stopScan();
  Future<Transport> connect(PeerInfo peer);
}

/// A Transport over a pair of in-memory streams, for tests and for pass-and-play plumbing.
class LoopbackTransport implements Transport {
  LoopbackTransport._(this._in, this._out);

  static (LoopbackTransport, LoopbackTransport) pair() {
    final a = StreamController<String>.broadcast();
    final b = StreamController<String>.broadcast();
    return (LoopbackTransport._(a, b), LoopbackTransport._(b, a));
  }

  final StreamController<String> _in;
  final StreamController<String> _out;
  final _state = StreamController<LinkState>.broadcast();
  LinkState _current = LinkState.connected;

  @override
  LinkKind get kind => LinkKind.lan;
  @override
  Stream<String> get messages => _in.stream;
  @override
  Stream<LinkState> get stateChanges => _state.stream;
  @override
  LinkState get state => _current;
  @override
  Future<void> send(String message) async {
    if (_current != LinkState.connected) return;
    _out.add(message);
  }

  @override
  Future<void> close() async {
    _current = LinkState.closed;
    _state.add(_current);
  }
}
