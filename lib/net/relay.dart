import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:nostr/nostr.dart' as nostr;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'transport.dart';

/// Remote play with nobody running a server: moves travel as encrypted events through public
/// Nostr relays. Both players derive a room tag and an encryption key from a shared match code,
/// publish their messages to several relays and subscribe to the room on each. Relays keep the
/// events, so a game can continue days later and a reinstalled app can catch up from history.
const relayEventKind = 4042;

const defaultRelays = ['wss://relay.damus.io', 'wss://nos.lol', 'wss://relay.primal.net', 'wss://relay.nostr.band'];

String roomTag(String code) => sha256.convert(utf8.encode('magictrek:room:${code.toUpperCase()}')).toString().substring(0, 32);

/// A keystream cipher with an HMAC tag, both from the shared code. Keeps game traffic private
/// from relay operators; the engine, not secrecy, is what makes the game fair.
class RoomCipher {
  RoomCipher(String code) : _key = sha256.convert(utf8.encode('magictrek:key:${code.toUpperCase()}')).bytes, _mac = sha256.convert(utf8.encode('magictrek:mac:${code.toUpperCase()}')).bytes;
  final List<int> _key, _mac;
  final _rand = Random.secure();

  String encrypt(String plaintext) {
    final data = utf8.encode(plaintext);
    final nonce = List<int>.generate(12, (_) => _rand.nextInt(256));
    final out = Uint8List(data.length);
    for (var i = 0; i < data.length; i += 32) {
      final block = Hmac(sha256, _key).convert([...nonce, i ~/ 32 & 0xFF, (i ~/ 32 >> 8) & 0xFF]).bytes;
      for (var j = 0; j < 32 && i + j < data.length; j++) {
        out[i + j] = data[i + j] ^ block[j];
      }
    }
    final tag = Hmac(sha256, _mac).convert([...nonce, ...out]).bytes.sublist(0, 16);
    return base64Encode([...nonce, ...out, ...tag]);
  }

  String? decrypt(String encoded) {
    List<int> all;
    try {
      all = base64Decode(encoded);
    } catch (_) {
      return null;
    }
    if (all.length < 28) return null;
    final nonce = all.sublist(0, 12);
    final body = all.sublist(12, all.length - 16);
    final tag = all.sublist(all.length - 16);
    final expected = Hmac(sha256, _mac).convert([...nonce, ...body]).bytes.sublist(0, 16);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= tag[i] ^ expected[i];
    }
    if (diff != 0) return null;
    final out = Uint8List(body.length);
    for (var i = 0; i < body.length; i += 32) {
      final block = Hmac(sha256, _key).convert([...nonce, i ~/ 32 & 0xFF, (i ~/ 32 >> 8) & 0xFF]).bytes;
      for (var j = 0; j < 32 && i + j < body.length; j++) {
        out[i + j] = body[i + j] ^ block[j];
      }
    }
    return utf8.decode(out, allowMalformed: true);
  }
}

class RelayTransport implements Transport {
  RelayTransport({required this.code, required this.secretKey, List<String>? relays}) : relays = relays ?? defaultRelays, _cipher = RoomCipher(code) {
    _pubkey = nostr.Keys(secretKey).public;
    _room = roomTag(code);
    for (final url in this.relays) {
      _connect(url);
    }
  }

  final String code;
  final String secretKey;
  final List<String> relays;
  final RoomCipher _cipher;
  late final String _pubkey;
  late final String _room;
  final Map<String, WebSocketChannel> _channels = {};
  final Set<String> _ready = {};
  final Set<String> _seenEvents = {};
  final List<String> _outbox = [];
  final _messages = StreamController<String>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  final _relayStatus = StreamController<Map<String, bool>>.broadcast();
  LinkState _current = LinkState.connecting;
  bool _closed = false;
  final String _subId = 'mt${Random().nextInt(1 << 30)}';

  Stream<Map<String, bool>> get relayStatus => _relayStatus.stream;
  int get connectedRelays => _ready.length;

  void _connect(String url) {
    if (_closed) return;
    try {
      final ch = WebSocketChannel.connect(Uri.parse(url));
      _channels[url] = ch;
      ch.ready
          .then((_) {
            if (_closed) return;
            _ready.add(url);
            _relayStatus.add({for (final r in relays) r: _ready.contains(r)});
            _set(LinkState.connected);
            final req = nostr.Request(
              subscriptionId: _subId,
              filters: [
                nostr.Filter(
                  kinds: const [relayEventKind],
                  tagFilters: {
                    't': [_room],
                  },
                  limit: 1000,
                ),
              ],
            );
            ch.sink.add(req.serialize());
            for (final m in _outbox) {
              ch.sink.add(m);
            }
          })
          .catchError((_) => _retry(url));
      ch.stream.listen(_onRelayMessage, onError: (_) => _retry(url), onDone: () => _retry(url), cancelOnError: true);
    } catch (_) {
      _retry(url);
    }
  }

  void _retry(String url) {
    if (_closed) return;
    _ready.remove(url);
    _channels.remove(url);
    _relayStatus.add({for (final r in relays) r: _ready.contains(r)});
    if (_ready.isEmpty) _set(LinkState.connecting);
    Timer(const Duration(seconds: 5), () => _connect(url));
  }

  void _set(LinkState s) {
    if (_closed) return;
    if (_current == s) return;
    _current = s;
    _state.add(s);
  }

  void _onRelayMessage(dynamic raw) {
    if (raw is! String) return;
    List<dynamic> frame;
    try {
      frame = jsonDecode(raw) as List<dynamic>;
    } catch (_) {
      return;
    }
    if (frame.isEmpty || frame[0] != 'EVENT' || frame.length < 3) return;
    final e = frame[2] as Map<String, dynamic>;
    final id = e['id'] as String?;
    if (id == null || _seenEvents.contains(id)) return;
    _seenEvents.add(id);
    if (e['pubkey'] == _pubkey) return; // our own messages come back from every relay
    final plain = _cipher.decrypt((e['content'] as String?) ?? '');
    if (plain == null) return;
    // Give the lockstep layer a message id so replays from several relays are deduplicated.
    try {
      final m = jsonDecode(plain) as Map<String, dynamic>;
      m['mid'] = id;
      _messages.add(jsonEncode(m));
    } catch (_) {
      _messages.add(plain);
    }
  }

  @override
  LinkKind get kind => LinkKind.relay;
  @override
  Stream<String> get messages => _messages.stream;
  @override
  Stream<LinkState> get stateChanges => _state.stream;
  @override
  LinkState get state => _current;

  @override
  Future<void> send(String message) async {
    if (_closed) return;
    final event = nostr.Event.from(
      kind: relayEventKind,
      content: _cipher.encrypt(message),
      secretKey: secretKey,
      tags: [
        ['t', _room],
      ],
    );
    final frame = jsonEncode(['EVENT', jsonDecode(event.serialize())[1]]);
    _outbox.add(frame);
    if (_outbox.length > 400) _outbox.removeAt(0);
    for (final url in _ready) {
      try {
        _channels[url]?.sink.add(frame);
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _current = LinkState.closed;
    _state.add(_current);
    for (final ch in _channels.values) {
      try {
        ch.sink.add(nostr.Close(_subId).serialize());
        // Don't wait: a relay that never answered would hold this open.
        unawaited(ch.sink.close().timeout(const Duration(seconds: 2), onTimeout: () {}).catchError((_) {}));
      } catch (_) {}
    }
    _channels.clear();
  }
}

/// A fresh Nostr identity for this device (hex secret key).
String newRelayIdentity() => nostr.Keys.generate().secret;
