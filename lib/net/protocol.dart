import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../engine/actions.dart';
import '../engine/cards.dart';
import '../engine/game.dart';
import '../engine/rules.dart';
import 'transport.dart';

/// Wire format version; peers with different versions refuse to play (lockstep needs identical rules).
const protocolVersion = 1;

/// Lockstep over any Transport. Both sides keep the full ordered action list; every action carries
/// its sequence number and the state digest after applying it, so a divergence is caught at once.
///
/// Messages (JSON): hello, start, action, need (ask for actions from a seq), state (digest check).
class LockstepMatch {
  LockstepMatch({
    required this.transport,
    required this.db,
    required this.localName,
    required this.localId,
    required this.localDeck,
    required this.isHost,
    int? seed,
    this.engineVersion = 1,
    this.rules = Rules.standard,
  }) : _seed = seed ?? DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFFFFFF {
    _sub = transport.messages.listen(_onMessage, onError: (_) {});
    _stateSub = transport.stateChanges.listen((s) {
      if (s == LinkState.connected) _sendHello();
      _status.add(status);
    });
  }

  final Transport transport;
  final CardDatabase db;
  final String localName, localId;
  final List<String> localDeck;
  final bool isHost;
  final int engineVersion;
  final int _seed;

  /// The host's rules; a guest takes them from the start message.
  Rules rules;

  String? remoteName, remoteId;
  List<String>? remoteDeck;
  Game? game;
  final List<GameAction> actions = [];
  final List<String> digests = [];
  int get localSeat => isHost ? 0 : 1;
  int get remoteSeat => isHost ? 1 : 0;
  String? error;
  bool desynced = false;

  final _events = StreamController<String>.broadcast(); // 'hello', 'start', 'action', 'desync', 'error'
  final _status = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;
  Stream<String> get statusChanges => _status.stream;
  late final StreamSubscription<String> _sub;
  late final StreamSubscription<LinkState> _stateSub;
  final Map<int, Map<String, dynamic>> _buffered = {};
  Timer? _retry;
  final Set<String> _seen = {};

  String get status {
    if (error != null) return 'Error: $error';
    if (desynced) return 'Out of sync';
    if (game == null) return remoteName == null ? 'Waiting for the other player…' : 'Linked with $remoteName';
    return 'In game with $remoteName';
  }

  /// Say hello; the host answers with the start message once both sides are known.
  void begin() => _sendHello();

  void _sendHello() {
    _send({'t': 'hello', 'v': protocolVersion, 'ev': engineVersion, 'name': localName, 'id': localId, 'deck': localDeck, 'host': isHost, 'seq': actions.length});
  }

  void _send(Map<String, dynamic> m) {
    transport.send(jsonEncode(m));
  }

  void _onMessage(String raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    // Relays replay history: drop duplicates by message id.
    final mid = m['mid'] as String?;
    if (mid != null) {
      if (_seen.contains(mid)) return;
      _seen.add(mid);
    }
    switch (m['t']) {
      case 'hello':
        if (m['v'] != protocolVersion || m['ev'] != engineVersion) {
          error = 'The other player runs a different game version (${m['v']}/${m['ev']} vs $protocolVersion/$engineVersion)';
          _events.add('error');
          _status.add(status);
          return;
        }
        if ((m['host'] as bool) == isHost) {
          error = isHost ? 'Both players are hosting; one should join instead' : 'Both players are joining; one should host';
          _events.add('error');
          _status.add(status);
          return;
        }
        final newPeer = remoteId != m['id'];
        remoteName = m['name'] as String;
        remoteId = m['id'] as String;
        remoteDeck = (m['deck'] as List).cast<String>();
        _events.add('hello');
        _status.add(status);
        if (isHost) {
          _sendStart();
        } else if (newPeer) {
          _sendHello();
        }
        // Either side may be behind after a reconnect: ask for what we lack.
        final theirSeq = m['seq'] as int? ?? 0;
        if (theirSeq > actions.length) _send({'t': 'need', 'from': actions.length});
      case 'start':
        if (isHost) return;
        if (game != null) return;
        final seed = m['seed'] as int;
        final names = (m['names'] as List).cast<String>();
        final decks = (m['decks'] as List).map((d) => (d as List).cast<String>()).toList();
        rules = Rules.fromJson(m['rules'] as Map<String, dynamic>?);
        _startGame(seed, names, decks);
        _send({'t': 'need', 'from': actions.length});
      case 'action':
        _onAction(m);
      case 'need':
        final from = m['from'] as int;
        for (var i = from; i < actions.length; i++) {
          _send(_actionMessage(i));
        }
        if (isHost && game != null) _sendStart();
      case 'state':
        final seq = m['seq'] as int;
        final digest = m['d'] as String;
        if (seq < digests.length && digests[seq] != digest) _desync(seq);
    }
  }

  void _sendStart() {
    final deck = remoteDeck;
    if (deck == null) return;
    game ??= _buildGame(_seed, [localName, remoteName!], [localDeck, deck]);
    _send({
      't': 'start',
      'seed': _seed,
      'names': [localName, remoteName],
      'decks': [localDeck, deck],
      'rules': rules.toJson(),
    });
  }

  Game _buildGame(int seed, List<String> names, List<List<String>> decks) {
    final g = Game(playerNames: names, seed: seed, db: db);
    if (actions.isEmpty) {
      final start = StartAction(decks, rules: rules);
      g.apply(start);
      actions.add(start);
      digests.add(_digest(g));
    } else {
      for (final a in actions) {
        g.apply(a);
      }
    }
    return g;
  }

  void _startGame(int seed, List<String> names, List<List<String>> decks) {
    game = _buildGame(seed, names, decks);
    _events.add('start');
    _status.add(status);
    _flushBuffered();
  }

  static String _digest(Game g) => sha256.convert(utf8.encode(g.state.digest())).toString().substring(0, 24);

  Map<String, dynamic> _actionMessage(int i) => {'t': 'action', 'seq': i, 'a': actions[i].toJson(), 'd': digests[i], 'by': i == 0 ? -1 : (_by.length > i ? _by[i] : -1)};
  final List<int> _by = [-1];

  /// A move by the local player: applied here, then sent.
  void perform(GameAction action) {
    final g = game;
    if (g == null) throw StateError('No game yet');
    g.applyAs(action, localSeat);
    actions.add(action);
    _by.add(localSeat);
    digests.add(_digest(g));
    _events.add('action');
    _send(_actionMessage(actions.length - 1));
  }

  void _onAction(Map<String, dynamic> m) {
    final seq = m['seq'] as int;
    if (seq < actions.length) {
      // Already have it: compare digests to be sure both sides agree.
      if (m['d'] != digests[seq]) _desync(seq);
      return;
    }
    _buffered[seq] = m;
    _flushBuffered();
    if (_buffered.isNotEmpty) {
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 2), () => _send({'t': 'need', 'from': actions.length}));
    }
  }

  void _flushBuffered() {
    final g = game;
    if (g == null) return;
    while (_buffered.containsKey(actions.length)) {
      final m = _buffered.remove(actions.length)!;
      final action = GameAction.fromJson(m['a'] as Map<String, dynamic>);
      try {
        g.apply(action);
      } catch (e) {
        error = 'Illegal move from the other player: $e';
        _events.add('error');
        _status.add(status);
        return;
      }
      actions.add(action);
      _by.add(m['by'] as int? ?? remoteSeat);
      final d = _digest(g);
      digests.add(d);
      if (m['d'] != d) {
        _desync(actions.length - 1);
        return;
      }
      _events.add('action');
    }
  }

  void _desync(int seq) {
    desynced = true;
    error = 'The two devices disagree about the game after move $seq';
    _events.add('desync');
    _status.add(status);
  }

  Future<void> dispose() async {
    _retry?.cancel();
    await _sub.cancel();
    await _stateSub.cancel();
    await transport.close();
    await _events.close();
    await _status.close();
  }
}

/// Six characters of letters and digits that are easy to read aloud.
String newMatchCode([int length = 6]) {
  const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  final seed = DateTime.now().microsecondsSinceEpoch;
  var x = seed;
  final out = StringBuffer();
  for (var i = 0; i < length; i++) {
    x = (x * 6364136223846793005 + 1442695040888963407) & 0x7FFFFFFFFFFFFFFF;
    out.write(letters[(x >> 33) % letters.length]);
  }
  return out.toString();
}
