import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'transport.dart';

/// Local network play: the host announces itself with UDP broadcasts; guests listen, show the
/// hosts they hear, and connect over TCP. Newline-delimited JSON on the socket.
const lanDiscoveryPort = 47474;
const _magic = 'MAGICTREK1';

class TcpTransport implements Transport {
  TcpTransport(this._socket) {
    _socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen(
      (line) {
        if (line.isNotEmpty) _messages.add(line);
      },
      onDone: () => _set(LinkState.closed),
      onError: (_) => _set(LinkState.failed),
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final _messages = StreamController<String>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  LinkState _current = LinkState.connected;

  void _set(LinkState s) {
    if (_current == LinkState.closed) return;
    _current = s;
    _state.add(s);
  }

  @override
  LinkKind get kind => LinkKind.lan;
  @override
  Stream<String> get messages => _messages.stream;
  @override
  Stream<LinkState> get stateChanges => _state.stream;
  @override
  LinkState get state => _current;

  @override
  Future<void> send(String message) async {
    if (_current != LinkState.connected) return;
    try {
      // No explicit flush: Dart sockets drain their own buffer, and overlapping flush() calls throw.
      _socket.add(utf8.encode('$message\n'));
    } catch (_) {
      _set(LinkState.failed);
    }
  }

  @override
  Future<void> close() async {
    _set(LinkState.closed);
    try {
      await _socket.close();
    } catch (_) {}
  }
}

/// The port a host listens on when it's free, so "type the host's address" usually needs no port.
const lanGamePort = 47000;

/// This device's IPv4 addresses on the local network, for telling a guest where to connect.
Future<List<String>> localAddresses() async {
  try {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    return [for (final i in interfaces) for (final a in i.addresses) a.address];
  } catch (_) {
    return const [];
  }
}

class LanHost implements HostLink {
  ServerSocket? _server;
  RawDatagramSocket? _beacon;
  Timer? _timer;
  final _connections = StreamController<Transport>.broadcast();
  int get port => _server?.port ?? 0;

  @override
  Stream<Transport> get connections => _connections.stream;

  @override
  Future<void> start({required String name, required String id}) async {
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, lanGamePort);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0); // the usual port is taken
    }
    _server!.listen((socket) {
      socket.setOption(SocketOption.tcpNoDelay, true);
      _connections.add(TcpTransport(socket));
    });
    _beacon = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _beacon!.broadcastEnabled = true;
    final payload = utf8.encode(jsonEncode({'m': _magic, 'name': name, 'id': id, 'port': _server!.port}));
    void announce() {
      try {
        _beacon?.send(payload, InternetAddress('255.255.255.255'), lanDiscoveryPort);
      } catch (_) {}
    }
    announce();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => announce());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _beacon?.close();
    await _server?.close();
    _server = null;
  }
}

class LanGuest implements GuestLink {
  RawDatagramSocket? _socket;
  final Map<String, PeerInfo> _found = {};
  final Map<String, DateTime> _lastSeen = {};
  final _peers = StreamController<List<PeerInfo>>.broadcast();
  Timer? _prune;

  @override
  Stream<List<PeerInfo>> get peers => _peers.stream;

  @override
  Future<void> startScan() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, lanDiscoveryPort, reuseAddress: true, reusePort: true);
    _socket!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = _socket!.receive();
      if (d == null) return;
      try {
        final m = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
        if (m['m'] != _magic) return;
        final id = m['id'] as String;
        _found[id] = PeerInfo(id: id, name: m['name'] as String, kind: LinkKind.lan, address: d.address.address, port: m['port'] as int);
        _lastSeen[id] = DateTime.now();
        _peers.add(_found.values.toList());
      } catch (_) {}
    });
    _prune = Timer.periodic(const Duration(seconds: 2), (_) {
      final now = DateTime.now();
      final stale = _lastSeen.entries.where((e) => now.difference(e.value).inSeconds > 5).map((e) => e.key).toList();
      if (stale.isEmpty) return;
      for (final id in stale) {
        _found.remove(id);
        _lastSeen.remove(id);
      }
      _peers.add(_found.values.toList());
    });
  }

  @override
  Future<void> stopScan() async {
    _prune?.cancel();
    _socket?.close();
    _socket = null;
  }

  @override
  Future<Transport> connect(PeerInfo peer) async {
    final socket = await Socket.connect(peer.address!, peer.port!, timeout: const Duration(seconds: 5));
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport(socket);
  }

  /// Connect by address when broadcasts don't cross the network (some Wi‑Fi isolates clients).
  Future<Transport> connectTo(String address, int port) async {
    final socket = await Socket.connect(address, port, timeout: const Duration(seconds: 5));
    socket.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport(socket);
  }
}
