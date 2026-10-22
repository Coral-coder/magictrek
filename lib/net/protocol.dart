import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../engine/actions.dart';
import '../engine/cards.dart';
import '../engine/game.dart';
import '../engine/rules.dart';
import 'transport.dart';

/// Wire format version; peers with different versions refuse to play (lockstep needs identical rules).
const protocolVersion = 2;

/// Keeps each linked game's move log on this device, so a crash or a closed app picks the game up
/// where it was. Keys are `relay:<code>` for a match code and `peer:<id>+<id>` for nearby play.
abstract class MatchArchive {
  Map<String, dynamic>? load(String key);
  void save(String key, Map<String, dynamic> log);
}

/// Lockstep over any Transport. Both sides keep the full ordered move list, each move with a
/// fingerprint (digest) of the game after it, and save it on the device as it grows.
///
/// When the devices (re)connect they swap their lists of fingerprints and find the last move they
/// agree on. A device that is merely behind fetches the moves it lacks. If the histories split,
/// the first seat's moves stand (the host's, in a new game) and the other device goes back to the
/// last shared move and takes them, so a crash or a lost message never strands a game.
///
/// Messages (JSON):
/// - hello: who I am, my deck, and my log (game id, fingerprints); answered once with `r`.
/// - start: the deal (seed, names, decks, seat ids, rules), sent to a device without the game.
/// - action: move `seq`, its fingerprint `d` and the fingerprint `p` of the position it was made
///   from, so a move from a different history is never applied on top of this one.
/// - need: send me your moves from `from` on.
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
    this.matchKey,
    this.archive,
  }) : _seed = seed ?? Random.secure().nextInt(1 << 31) {
    _sub = transport.messages.listen(_onMessage, onError: (_) {});
    _stateSub = transport.stateChanges.listen((s) {
      if (s == LinkState.connected) _sendHello();
      _status.add(status);
    });
    _restore(keepFinished: true);
  }

  final Transport transport;
  final CardDatabase db;
  final String localName, localId;
  final List<String> localDeck;
  final bool isHost;
  final int engineVersion;
  final int _seed;

  /// Where the log is saved: given up front for a match code, worked out from both device ids
  /// for nearby play once the other side says hello.
  String? matchKey;
  final MatchArchive? archive;

  /// The host's rules; a guest takes them from the deal.
  Rules rules;

  String? remoteName, remoteId;
  List<String>? remoteDeck;
  Game? game;
  final List<GameAction> actions = [];
  final List<String> digests = [];

  /// Which seat made each move (-1 for the deal).
  final List<int> by = [];

  /// Device ids in seat order, from the deal.
  List<String> seatIds = const [];
  Map<String, dynamic>? _setup;

  int get localSeat => seatIds.isEmpty ? (isHost ? 0 : 1) : max(0, seatIds.indexOf(localId));
  int get remoteSeat => 1 - localSeat;

  /// The first move's fingerprint names the game: same seed, decks and rules, same id.
  String? get gameId => digests.isEmpty ? null : digests.first;

  String? error;
  bool desynced = false;

  /// What the last rewind did, in words for the table.
  String? notice;

  final _events = StreamController<String>.broadcast(); // 'hello', 'start', 'action', 'rewind', 'desync', 'error'
  final _status = StreamController<String>.broadcast();
  Stream<String> get events => _events.stream;
  Stream<String> get statusChanges => _status.stream;
  late final StreamSubscription<String> _sub;
  late final StreamSubscription<LinkState> _stateSub;
  final Map<int, Map<String, dynamic>> _buffered = {};
  Timer? _retry, _replyTimer;
  DateTime? _lastCompare;
  final Set<String> _seen = {};

  String get status {
    if (error != null) return 'Error: $error';
    if (desynced) return 'Out of sync';
    if (game == null) return remoteName == null ? 'Waiting for the other player…' : 'Linked with $remoteName';
    return remoteName == null ? 'Waiting for the other player…' : 'In game with $remoteName';
  }

  /// Whether this device's moves stand when the two histories split.
  bool get _leads => localSeat == 0;

  /// Say hello; whoever has the game sends the deal, and the logs are compared.
  void begin() => _sendHello();

  void _sendHello({bool reply = false}) {
    _send({
      't': 'hello',
      'v': protocolVersion,
      'ev': engineVersion,
      'name': localName,
      'id': localId,
      'deck': localDeck,
      'host': isHost,
      'gid': gameId,
      'log': [for (final d in digests) d.substring(0, 8)],
      if (reply) 'r': true,
    });
  }

  /// Answers a hello with ours (and the deal, if they lack it) once for a burst: a relay replays
  /// every old hello when it reconnects.
  void _replySoon({bool hello = false, bool deal = false}) {
    _replyHello |= hello;
    _replyDeal |= deal;
    _replyTimer?.cancel();
    _replyTimer = Timer(const Duration(milliseconds: 300), () {
      if (_replyDeal) _sendStart();
      if (_replyHello) _sendHello(reply: true);
      _replyHello = _replyDeal = false;
    });
  }

  bool _replyHello = false, _replyDeal = false;

  /// Asks the other side for its log when a move doesn't fit ours; at most every two seconds.
  void _compareLogs() {
    final now = DateTime.now();
    if (_lastCompare != null && now.difference(_lastCompare!) < const Duration(seconds: 2)) return;
    _lastCompare = now;
    _sendHello();
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
        _onHello(m);
      case 'start':
        _onStart(m);
      case 'action':
        _onAction(m);
      case 'need':
        if (game == null) return;
        final from = m['from'] as int;
        if (from <= 0) _sendStart();
        for (var i = max(1, from); i < actions.length; i++) {
          _send(_actionMessage(i));
        }
    }
  }

  void _onHello(Map<String, dynamic> m) {
    final id = m['id'] as String;
    if (id == localId) return;
    if (m['v'] != protocolVersion || m['ev'] != engineVersion) {
      // An old hello replayed from a relay's history doesn't spoil a game already going.
      if (game == null) _fail('The other player runs a different game version (${m['v']}/${m['ev']} vs $protocolVersion/$engineVersion)');
      return;
    }
    if (game != null && !seatIds.contains(id)) return; // someone else using the same code
    if ((m['host'] as bool) == isHost && game == null) {
      _fail(isHost ? 'Both players are hosting; one should join instead' : 'Both players are joining; one should host');
      return;
    }
    if (!desynced) error = null;
    remoteName = m['name'] as String;
    remoteId = id;
    remoteDeck = (m['deck'] as List).cast<String>();
    if (matchKey == null && archive != null) {
      final ids = [localId, id]..sort();
      matchKey = 'peer:${ids.join('+')}';
      _restore(keepFinished: false);
    }
    _events.add('hello');
    _status.add(status);

    final theirGame = m['gid'] as String?;
    final theirLog = ((m['log'] as List?) ?? const []).cast<String>();
    if (game == null) {
      // Nobody has a game yet: the host deals. If they have one, their answer brings the deal.
      if (theirGame == null && isHost) _deal();
    } else if (theirGame == null) {
      _replySoon(deal: true);
    } else if (theirGame != gameId) {
      // Two different games under one match: the one further along stays.
      if (!_theirsWins(theirLog.length)) _replySoon(deal: true);
    } else {
      _reconcile(theirLog);
    }
    if (m['r'] != true) _replySoon(hello: true);
  }

  /// Whether the other device's game replaces ours when the two are different games.
  bool _theirsWins(int theirMoves) => theirMoves != actions.length ? theirMoves > actions.length : !isHost;

  /// Same game: find the last move both logs share and catch up or go back to it.
  void _reconcile(List<String> theirs) {
    var k = 0;
    while (k < actions.length && k < theirs.length && digests[k].startsWith(theirs[k])) {
      k++;
    }
    if (k == actions.length && k == theirs.length) return;
    if (k < actions.length && k < theirs.length) {
      if (_leads) return; // ours stand; they go back when they see our log
      _rewindTo(k, 'The two devices had different moves after move ${k - 1}. Went back to it and took ${remoteName ?? 'the other player'}’s moves.');
      _send({'t': 'need', 'from': actions.length});
    } else if (k == actions.length) {
      _send({'t': 'need', 'from': actions.length});
    }
    // Otherwise they are behind and ask us.
  }

  void _onStart(Map<String, dynamic> m) {
    final setup = (m['setup'] as Map).cast<String, dynamic>();
    if (!(setup['ids'] as List).contains(localId)) return;
    final theirGame = m['gid'] as String?;
    final replacing = game != null;
    if (replacing) {
      if (theirGame == gameId) return;
      if (!_theirsWins(m['n'] as int? ?? 1)) {
        _sendStart();
        return;
      }
    }
    final decks = [for (final d in setup['decks'] as List) (d as List).cast<String>()];
    _load(setup, [StartAction(decks, rules: Rules.fromJson(setup['rules'] as Map<String, dynamic>?))], const [-1]);
    if (theirGame != null && theirGame != gameId) {
      _desync('The two devices dealt the same game differently. Make sure both run the latest version.');
      return;
    }
    _save();
    notice = replacing ? 'Switched to the game on ${remoteName ?? 'the other device'}, which was further along.' : null;
    _events.add(replacing ? 'rewind' : 'start');
    _status.add(status);
    _send({'t': 'need', 'from': actions.length});
  }

  /// The host deals a new game for the two of them.
  void _deal() {
    final deck = remoteDeck, name = remoteName, id = remoteId;
    if (deck == null || name == null || id == null) return;
    final setup = <String, dynamic>{
      'seed': _seed,
      'names': [localName, name],
      'decks': [localDeck, deck],
      'ids': [localId, id],
      'rules': rules.toJson(),
    };
    _load(setup, [StartAction([localDeck, deck], rules: rules)], const [-1]);
    _save();
    _sendStart();
    _events.add('start');
    _status.add(status);
  }

  void _sendStart() {
    final setup = _setup;
    if (setup == null) return;
    _send({'t': 'start', 'setup': setup, 'gid': gameId, 'n': actions.length});
  }

  /// Deals the game [setup] describes and replays [moves] (the first is the deal itself).
  void _load(Map<String, dynamic> setup, List<GameAction> moves, List<int> movers) {
    final g = Game(playerNames: (setup['names'] as List).cast<String>(), seed: setup['seed'] as int, db: db);
    actions.clear();
    digests.clear();
    by.clear();
    _buffered.clear();
    for (var i = 0; i < moves.length; i++) {
      try {
        g.apply(moves[i]);
      } catch (_) {
        break;
      }
      actions.add(moves[i]);
      by.add(i < movers.length ? movers[i] : -1);
      digests.add(_digest(g));
    }
    _setup = setup;
    seatIds = (setup['ids'] as List).cast<String>();
    rules = Rules.fromJson(setup['rules'] as Map<String, dynamic>?);
    game = g;
  }

  /// Picks the game up from this device's saved log. A finished nearby game isn't resumed: the
  /// next game with the same person is a new one.
  void _restore({required bool keepFinished}) {
    final key = matchKey, a = archive;
    if (key == null || a == null || game != null) return;
    final log = a.load(key);
    if (log == null) return;
    try {
      final setup = (log['setup'] as Map).cast<String, dynamic>();
      if (!(setup['ids'] as List).contains(localId)) return;
      final moves = [for (final j in log['moves'] as List) GameAction.fromJson((j as Map).cast<String, dynamic>())];
      _load(setup, moves, (log['by'] as List).cast<int>());
      if (!keepFinished && game!.state.isOver) _clear();
    } catch (_) {
      _clear();
    }
  }

  void _clear() {
    game = null;
    _setup = null;
    seatIds = const [];
    actions.clear();
    digests.clear();
    by.clear();
  }

  void _save() {
    final key = matchKey, a = archive, setup = _setup;
    if (key == null || a == null || setup == null) return;
    a.save(key, {
      'setup': setup,
      'moves': [for (final x in actions) x.toJson()],
      'by': by,
      'opponent': remoteName,
      'date': DateTime.now().toIso8601String(),
    });
  }

  /// Goes back to just after move [length] - 1, dropping the moves after it.
  void _rewindTo(int length, String why) {
    final setup = _setup;
    if (setup == null) return;
    _load(setup, actions.sublist(0, length), by.sublist(0, length));
    _save();
    notice = why;
    _events.add('rewind');
    _status.add(status);
  }

  static String _digest(Game g) => sha256.convert(utf8.encode(g.state.digest())).toString().substring(0, 24);

  Map<String, dynamic> _actionMessage(int i) => {'t': 'action', 'seq': i, 'a': actions[i].toJson(), 'd': digests[i], 'p': digests[i - 1], 'by': by[i]};

  /// A move by the local player: applied and saved here, then sent.
  void perform(GameAction action) {
    final g = game;
    if (g == null) throw StateError('No game yet');
    // A concession is logged with who gave up: it can happen on the other player's move.
    if (action is ConcedeAction && action.player == null) action = ConcedeAction(localSeat);
    g.applyAs(action, localSeat);
    actions.add(action);
    by.add(localSeat);
    digests.add(_digest(g));
    _save();
    notice = null;
    _events.add('action');
    _send(_actionMessage(actions.length - 1));
  }

  void _onAction(Map<String, dynamic> m) {
    final seq = m['seq'] as int;
    if (seq <= 0) return; // the deal travels in 'start'
    if (game != null && seq < actions.length) {
      if (m['d'] == digests[seq]) return; // already have it
      if (m['p'] != digests[seq - 1]) {
        _compareLogs();
        return;
      }
      // Both moved from the same position at once: the first seat's move stands.
      if (_leads) return;
      _rewindTo(seq, '${remoteName ?? 'The other player'} moved at the same moment, and that move stands. Make yours again if it still applies.');
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
    var applied = false;
    while (_buffered.containsKey(actions.length)) {
      final m = _buffered.remove(actions.length)!;
      if (m['p'] != digests.last) {
        // Made from a position this device doesn't have: compare logs to find where they split.
        _buffered.clear();
        _compareLogs();
        break;
      }
      final action = GameAction.fromJson(m['a'] as Map<String, dynamic>);
      try {
        g.apply(action);
      } catch (e) {
        _fail('Illegal move from the other player: $e');
        return;
      }
      actions.add(action);
      by.add(m['by'] as int? ?? remoteSeat);
      final d = _digest(g);
      digests.add(d);
      applied = true;
      if (m['d'] != d) {
        _save();
        _desync('The two devices worked out move ${actions.length - 1} differently. Make sure both run the latest version.');
        return;
      }
      _events.add('action');
    }
    if (applied) _save();
  }

  void _fail(String message) {
    error = message;
    _events.add('error');
    _status.add(status);
  }

  /// The same move from the same position gave different games: the engines differ, and going
  /// back can't fix that.
  void _desync(String message) {
    desynced = true;
    error = message;
    _events.add('desync');
    _status.add(status);
  }

  Future<void> dispose() async {
    _retry?.cancel();
    _replyTimer?.cancel();
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
  final random = Random.secure();
  return String.fromCharCodes([for (var i = 0; i < length; i++) letters.codeUnitAt(random.nextInt(letters.length))]);
}
