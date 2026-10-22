import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:permission_handler/permission_handler.dart';

import 'transport.dart';

/// Bluetooth Low Energy play with no network at all. The host advertises a GATT service; the
/// guest scans for it and connects. One characteristic carries both directions: the guest writes
/// to it, the host notifies on it. Messages are chunked to the link's MTU with a one-byte header.
final bleServiceUuid = UUID.fromString('6d616769-6374-7265-6b00-000000000001');
final bleDataUuid = UUID.fromString('6d616769-6374-7265-6b00-000000000002');
const _namePrefix = 'MT:';

/// Chunk header: bit 0 = last chunk of a message, bits 1-7 = message counter.
class _Framer {
  int _counter = 0;

  List<Uint8List> split(String message, int chunkSize) {
    final bytes = utf8.encode(message);
    final size = chunkSize < 4 ? 4 : chunkSize;
    final out = <Uint8List>[];
    final counter = (_counter++ & 0x7F) << 1;
    for (var i = 0; i < bytes.length; i += size - 1) {
      final end = (i + size - 1) < bytes.length ? i + size - 1 : bytes.length;
      final last = end == bytes.length;
      out.add(Uint8List.fromList([counter | (last ? 1 : 0), ...bytes.sublist(i, end)]));
    }
    if (out.isEmpty) out.add(Uint8List.fromList([counter | 1]));
    return out;
  }
}

class _Reassembler {
  final List<int> _buffer = [];
  int? _counter;

  /// Returns the complete message when the last chunk arrives.
  String? add(Uint8List chunk) {
    if (chunk.isEmpty) return null;
    final header = chunk[0];
    final counter = header >> 1;
    if (_counter != counter) {
      _buffer.clear();
      _counter = counter;
    }
    _buffer.addAll(chunk.sublist(1));
    if (header & 1 == 1) {
      final s = utf8.decode(_buffer, allowMalformed: true);
      _buffer.clear();
      _counter = null;
      return s;
    }
    return null;
  }
}

/// Asks Android for what Bluetooth needs on the running version, or throws a [StateError]
/// naming what was refused. Android 12 (API 31) introduced its own runtime permissions
/// for scanning, connecting and advertising; before that, scanning needed location. The
/// manifest declares location only up to Android 11, so asking for it later could only
/// come back denied.
Future<bool> requestBluetoothPermissions() async {
  if (!Platform.isAndroid) return true;
  var sdk = 31;
  try {
    sdk = await const MethodChannel('magictrek/updater').invokeMethod<int>('sdkInt') ?? sdk;
  } catch (_) {}
  final wanted = sdk >= 31
      ? [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.bluetoothAdvertise]
      : [Permission.locationWhenInUse];
  final results = await wanted.request();
  final refused = results.entries.where((e) => !(e.value.isGranted || e.value.isLimited)).toList();
  if (refused.isEmpty) return true;
  final names = refused.map((e) => switch (e.key) {
        Permission.bluetoothScan => 'scan',
        Permission.bluetoothConnect => 'connect',
        Permission.bluetoothAdvertise => 'advertise',
        _ => 'location',
      }).join(', ');
  final settings = refused.any((e) => e.value.isPermanentlyDenied) ? ' Allow "Nearby devices" for MagicTrek in Android Settings → Apps.' : '';
  throw StateError('Bluetooth permission refused ($names).$settings');
}

Future<void> _waitPoweredOn(Stream<BluetoothLowEnergyStateChangedEventArgs> changes, BluetoothLowEnergyState Function() current) async {
  if (current() == BluetoothLowEnergyState.poweredOn) return;
  await changes.firstWhere((e) => e.state == BluetoothLowEnergyState.poweredOn).timeout(const Duration(seconds: 8), onTimeout: () => throw StateError('Bluetooth is ${current().name}'));
}

/// The host side of a Bluetooth link to one central.
class _BleHostTransport implements Transport {
  _BleHostTransport(this._manager, this._central, this._characteristic, this._chunkSize);
  final PeripheralManager _manager;
  final Central _central;
  final GATTCharacteristic _characteristic;
  final int _chunkSize;
  final _messages = StreamController<String>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  final _framer = _Framer();
  final _reassembler = _Reassembler();
  LinkState _current = LinkState.connected;
  Future<void> _sending = Future.value();

  void receive(Uint8List chunk) {
    final m = _reassembler.add(chunk);
    if (m != null) _messages.add(m);
  }

  void setState(LinkState s) {
    if (_current == LinkState.closed) return;
    _current = s;
    _state.add(s);
  }

  @override
  LinkKind get kind => LinkKind.bluetooth;
  @override
  Stream<String> get messages => _messages.stream;
  @override
  Stream<LinkState> get stateChanges => _state.stream;
  @override
  LinkState get state => _current;

  @override
  Future<void> send(String message) {
    if (_current != LinkState.connected) return Future.value();
    _sending = _sending.then((_) async {
      for (final chunk in _framer.split(message, _chunkSize)) {
        await _manager.notifyCharacteristic(_central, _characteristic, value: chunk);
      }
    }).catchError((_) => setState(LinkState.failed));
    return _sending;
  }

  @override
  Future<void> close() async {
    setState(LinkState.closed);
    try {
      await _manager.disconnect(_central);
    } catch (_) {}
  }
}

class BleHost implements HostLink {
  final _manager = PeripheralManager();
  final _connections = StreamController<Transport>.broadcast();
  final Map<String, _BleHostTransport> _transports = {};
  final List<StreamSubscription> _subs = [];

  @override
  Stream<Transport> get connections => _connections.stream;

  @override
  Future<void> start({required String name, required String id}) async {
    if (!await requestBluetoothPermissions()) throw StateError('Bluetooth permission denied');
    await _waitPoweredOn(_manager.stateChanged, () => _manager.state);
    await _manager.removeAllServices();
    final characteristic = GATTCharacteristic.mutable(
      uuid: bleDataUuid,
      properties: [GATTCharacteristicProperty.write, GATTCharacteristicProperty.writeWithoutResponse, GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read, GATTCharacteristicPermission.write],
      descriptors: [],
    );
    await _manager.addService(GATTService(uuid: bleServiceUuid, isPrimary: true, includedServices: [], characteristics: [characteristic]));
    _subs.add(_manager.characteristicWriteRequested.listen((e) async {
      try {
        await _manager.respondWriteRequest(e.request);
      } catch (_) {}
      final t = _transports[e.central.uuid.toString()];
      if (t != null) t.receive(e.request.value);
    }));
    _subs.add(_manager.characteristicNotifyStateChanged.listen((e) async {
      final key = e.central.uuid.toString();
      if (e.state) {
        var chunk = 20;
        try {
          chunk = await _manager.getMaximumNotifyLength(e.central);
        } catch (_) {}
        final t = _BleHostTransport(_manager, e.central, characteristic, chunk);
        _transports[key] = t;
        _connections.add(t);
      } else {
        _transports.remove(key)?.setState(LinkState.closed);
      }
    }));
    // Android reports a central dropping off; Core Bluetooth has no such event for a
    // peripheral (the getter throws), and a disconnect shows up above as the central's
    // notifications being switched off, which closes the link just the same.
    try {
      _subs.add(_manager.connectionStateChanged.listen((e) {
        if (e.state == ConnectionState.disconnected) _transports.remove(e.central.uuid.toString())?.setState(LinkState.closed);
      }));
    } on UnsupportedError {
      // iOS and macOS.
    }
    await _manager.startAdvertising(Advertisement(name: '$_namePrefix$name', serviceUUIDs: [bleServiceUuid]));
  }

  @override
  Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _manager.stopAdvertising();
      await _manager.removeAllServices();
    } catch (_) {}
  }
}

/// The guest side: scans for hosts and connects to one.
class _BleGuestTransport implements Transport {
  _BleGuestTransport(this._manager, this._peripheral, this._characteristic, this._chunkSize) {
    _subs.add(_manager.characteristicNotified.listen((e) {
      if (e.peripheral.uuid != _peripheral.uuid || e.characteristic.uuid != bleDataUuid) return;
      final m = _reassembler.add(e.value);
      if (m != null) _messages.add(m);
    }));
    _subs.add(_manager.connectionStateChanged.listen((e) {
      if (e.peripheral.uuid == _peripheral.uuid && e.state == ConnectionState.disconnected) _set(LinkState.closed);
    }));
  }
  final CentralManager _manager;
  final Peripheral _peripheral;
  final GATTCharacteristic _characteristic;
  final int _chunkSize;
  final _messages = StreamController<String>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  final _framer = _Framer();
  final _reassembler = _Reassembler();
  final List<StreamSubscription> _subs = [];
  LinkState _current = LinkState.connected;
  Future<void> _sending = Future.value();

  void _set(LinkState s) {
    if (_current == LinkState.closed) return;
    _current = s;
    _state.add(s);
  }

  @override
  LinkKind get kind => LinkKind.bluetooth;
  @override
  Stream<String> get messages => _messages.stream;
  @override
  Stream<LinkState> get stateChanges => _state.stream;
  @override
  LinkState get state => _current;

  @override
  Future<void> send(String message) {
    if (_current != LinkState.connected) return Future.value();
    _sending = _sending.then((_) async {
      for (final chunk in _framer.split(message, _chunkSize)) {
        await _manager.writeCharacteristic(_peripheral, _characteristic, value: chunk, type: GATTCharacteristicWriteType.withResponse);
      }
    }).catchError((_) => _set(LinkState.failed));
    return _sending;
  }

  @override
  Future<void> close() async {
    _set(LinkState.closed);
    for (final s in _subs) {
      await s.cancel();
    }
    try {
      await _manager.disconnect(_peripheral);
    } catch (_) {}
  }
}

class BleGuest implements GuestLink {
  final _manager = CentralManager();
  final Map<String, PeerInfo> _found = {};
  final _peers = StreamController<List<PeerInfo>>.broadcast();
  StreamSubscription? _sub;

  @override
  Stream<List<PeerInfo>> get peers => _peers.stream;

  @override
  Future<void> startScan() async {
    if (!await requestBluetoothPermissions()) throw StateError('Bluetooth permission denied');
    await _waitPoweredOn(_manager.stateChanged, () => _manager.state);
    _sub = _manager.discovered.listen((e) {
      final name = e.advertisement.name;
      if (name == null || !name.startsWith(_namePrefix)) return;
      final id = e.peripheral.uuid.toString();
      _found[id] = PeerInfo(id: id, name: name.substring(_namePrefix.length), kind: LinkKind.bluetooth, extra: e.peripheral);
      _peers.add(_found.values.toList());
    });
    await _manager.startDiscovery(serviceUUIDs: [bleServiceUuid]);
  }

  @override
  Future<void> stopScan() async {
    await _sub?.cancel();
    try {
      await _manager.stopDiscovery();
    } catch (_) {}
  }

  @override
  Future<Transport> connect(PeerInfo peer) async {
    final peripheral = peer.extra as Peripheral;
    await _manager.connect(peripheral);
    var chunk = 20;
    try {
      await _manager.requestMTU(peripheral, mtu: 512);
    } catch (_) {}
    try {
      chunk = await _manager.getMaximumWriteLength(peripheral, type: GATTCharacteristicWriteType.withResponse);
    } catch (_) {}
    final services = await _manager.discoverGATT(peripheral);
    GATTCharacteristic? characteristic;
    for (final s in services) {
      if (s.uuid != bleServiceUuid) continue;
      for (final c in s.characteristics) {
        if (c.uuid == bleDataUuid) characteristic = c;
      }
    }
    if (characteristic == null) {
      await _manager.disconnect(peripheral);
      throw StateError('That device is not hosting a MagicTrek game');
    }
    final transport = _BleGuestTransport(_manager, peripheral, characteristic, chunk);
    await _manager.setCharacteristicNotifyState(peripheral, characteristic, state: true);
    return transport;
  }
}
