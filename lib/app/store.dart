import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/actions.dart';
import '../engine/cards.dart';
import '../engine/decks.dart';
import '../net/protocol.dart';
import '../net/relay.dart';
import '../engine/rules.dart';
import 'notifications.dart';
import 'session.dart';
import 'sound.dart';
import 'updater.dart';

/// App-wide state: settings, decks, the saved local game, the current session.
class AppStore extends ChangeNotifier implements MatchArchive {
  AppStore._();
  static final AppStore shared = AppStore._();

  late CardDatabase db;
  late SharedPreferences _prefs;
  List<Deck> decks = [];
  Map<String, dynamic>? savedGame;
  GameSession? session;
  String playerName = 'Captain';
  bool soundOn = true, hapticsOn = true, autoUpdate = true;
  /// Tapping a card on the table opens it large with its actions, instead of acting at once.
  bool tapToInspect = true;
  /// A line on the table saying what you can do right now, for new players.
  bool coachOn = true;

  /// Every card in play shown as a card, lands included (one card per land). Off: lands are
  /// labels grouped by name, to leave more room.
  bool showAllCards = false;
  /// Whether the guided tour of the table has been shown (or skipped).
  bool tourSeen = false;
  Rules rules = Rules.standard;
  String deviceId = '';
  String relayIdentity = '';
  List<String> relays = List.of(defaultRelays);
  /// Remote matches this device has hosted or joined: code -> {name, host, opponent, date}.
  List<Map<String, dynamic>> remoteMatches = [];
  bool ready = false;

  Future<void> init() async {
    db = CardDatabase.fromJsonString(await rootBundle.loadString('assets/cards.json'));
    _prefs = await SharedPreferences.getInstance();
    playerName = _prefs.getString('playerName') ?? 'Captain';
    soundOn = _prefs.getBool('soundOn') ?? true;
    hapticsOn = _prefs.getBool('hapticsOn') ?? true;
    autoUpdate = _prefs.getBool('autoUpdate') ?? true;
    tapToInspect = _prefs.getBool('tapToInspect') ?? true;
    coachOn = _prefs.getBool('coachOn') ?? true;
    showAllCards = _prefs.getBool('showAllCards') ?? false;
    tourSeen = _prefs.getBool('tourSeen') ?? false;
    final rulesJson = _prefs.getString('rules');
    if (rulesJson != null) {
      try {
        rules = Rules.fromJson(jsonDecode(rulesJson) as Map<String, dynamic>);
      } catch (_) {}
    }
    Updater.shared.autoDownload = autoUpdate;
    deviceId = _prefs.getString('deviceId') ?? '';
    if (deviceId.isEmpty) {
      deviceId = newMatchCode(10);
      await _prefs.setString('deviceId', deviceId);
    }
    relayIdentity = _prefs.getString('relayIdentity') ?? '';
    if (relayIdentity.isEmpty) {
      relayIdentity = newRelayIdentity();
      await _prefs.setString('relayIdentity', relayIdentity);
    }
    relays = _prefs.getStringList('relays') ?? List.of(defaultRelays);
    final deckJson = _prefs.getString('decks');
    if (deckJson != null) {
      try {
        decks = (jsonDecode(deckJson) as List).map((e) => Deck.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {}
    }
    if (decks.isEmpty) {
      decks = StarterDecks.all(db);
      await _persistDecks();
    }
    final saved = _prefs.getString('savedGame');
    if (saved != null) {
      try {
        savedGame = jsonDecode(saved) as Map<String, dynamic>;
      } catch (_) {}
    }
    final rm = _prefs.getString('remoteMatches');
    if (rm != null) {
      try {
        remoteMatches = (jsonDecode(rm) as List).cast<Map<String, dynamic>>();
      } catch (_) {}
    }
    Console.shared.soundOn = soundOn;
    Console.shared.hapticsOn = hapticsOn;
    await Console.shared.init();
    await Notifications.shared.init();
    ready = true;
    notifyListeners();
  }

  // MARK: Settings

  Future<void> setPlayerName(String n) async {
    playerName = n.trim().isEmpty ? 'Captain' : n.trim();
    await _prefs.setString('playerName', playerName);
    notifyListeners();
  }

  Future<void> setSound(bool v) async {
    soundOn = v;
    Console.shared.soundOn = v;
    await _prefs.setBool('soundOn', v);
    notifyListeners();
  }

  Future<void> setRules(Rules r) async {
    rules = r;
    await _prefs.setString('rules', jsonEncode(r.toJson()));
    notifyListeners();
  }

  Future<void> setAutoUpdate(bool v) async {
    autoUpdate = v;
    Updater.shared.autoDownload = v;
    await _prefs.setBool('autoUpdate', v);
    notifyListeners();
  }

  Future<void> setTapToInspect(bool v) async {
    tapToInspect = v;
    await _prefs.setBool('tapToInspect', v);
    notifyListeners();
  }

  Future<void> setShowAllCards(bool v) async {
    showAllCards = v;
    await _prefs.setBool('showAllCards', v);
    notifyListeners();
  }

  Future<void> setCoach(bool v) async {
    coachOn = v;
    await _prefs.setBool('coachOn', v);
    notifyListeners();
  }

  Future<void> setTourSeen(bool v) async {
    tourSeen = v;
    await _prefs.setBool('tourSeen', v);
    notifyListeners();
  }

  Future<void> setHaptics(bool v) async {
    hapticsOn = v;
    Console.shared.hapticsOn = v;
    await _prefs.setBool('hapticsOn', v);
    notifyListeners();
  }

  Future<void> setRelays(List<String> list) async {
    relays = list.where((s) => s.trim().isNotEmpty).map((s) => s.trim()).toList();
    if (relays.isEmpty) relays = List.of(defaultRelays);
    await _prefs.setStringList('relays', relays);
    notifyListeners();
  }

  // MARK: Decks

  List<Deck> get starterDecks => decks.where((d) => d.isStarter).toList();
  List<Deck> get customDecks => decks.where((d) => !d.isStarter).toList();
  List<Deck> get legalDecks => decks.where((d) => d.isLegal(db)).toList();
  Deck? deck(String id) => decks.where((d) => d.id == id).firstOrNull;

  Future<void> saveDeck(Deck deck) async {
    final i = decks.indexWhere((d) => d.id == deck.id);
    if (i >= 0) {
      decks[i] = deck;
    } else {
      decks.add(deck);
    }
    await _persistDecks();
    notifyListeners();
  }

  Future<void> deleteDeck(Deck deck) async {
    decks.removeWhere((d) => d.id == deck.id);
    await _persistDecks();
    notifyListeners();
  }

  Future<Deck> duplicateDeck(Deck deck) async {
    final copy = deck.copy(name: '${deck.name} copy', isStarter: false);
    await saveDeck(copy);
    return copy;
  }

  Future<void> restoreStarterDecks() async {
    for (final d in StarterDecks.all(db)) {
      if (!decks.any((x) => x.isStarter && x.name == d.name)) decks.add(d);
    }
    await _persistDecks();
    notifyListeners();
  }

  Future<void> _persistDecks() => _prefs.setString('decks', jsonEncode(decks.map((d) => d.toJson()).toList()));

  // MARK: Games

  GameSession startLocalGame({required Deck deck, required Deck opponentDeck, required bool hotseat}) {
    final seed = DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFFFFFF;
    final names = hotseat ? ['Player 1', 'Player 2'] : [playerName, 'Computer'];
    final s = GameSession.local(mode: hotseat ? SessionMode.hotseat : SessionMode.solo, playerNames: names, seed: seed, decks: [deck.cardList, opponentDeck.cardList], db: db, rules: rules);
    _attach(s);
    s.start();
    return s;
  }

  GameSession? resumeLocalGame() {
    final saved = savedGame;
    if (saved == null) return null;
    try {
      final mode = SessionMode.values.byName(saved['mode'] as String);
      final s = GameSession.local(mode: mode, playerNames: (saved['names'] as List).cast<String>(), seed: saved['seed'] as int, decks: (saved['decks'] as List).map((d) => (d as List).cast<String>()).toList(), db: db);
      _attach(s);
      s.replay((saved['actions'] as List).map((a) => GameAction.fromJson(a as Map<String, dynamic>)).toList());
      return s;
    } catch (_) {
      clearSavedGame();
      return null;
    }
  }

  GameSession startLinkedGame(LockstepMatch match) {
    final s = GameSession.linked(match: match, db: db);
    _attach(s);
    return s;
  }

  void _attach(GameSession s) {
    session?.dispose();
    session = s;
    s.onSave = (map) {
      savedGame = map;
      _prefs.setString('savedGame', jsonEncode(map));
      notifyListeners();
    };
    s.onFinished = () {
      if (s.mode != SessionMode.linked) clearSavedGame();
    };
    notifyListeners();
  }

  void clearSavedGame() {
    savedGame = null;
    _prefs.remove('savedGame');
    notifyListeners();
  }

  int savedGameTurn() {
    final saved = savedGame;
    if (saved == null) return 0;
    return (saved['actions'] as List).length;
  }

  Future<void> rememberRemoteMatch({required String code, required bool host, String? opponent}) async {
    remoteMatches.removeWhere((m) => m['code'] == code);
    remoteMatches.insert(0, {'code': code, 'host': host, 'opponent': opponent, 'date': DateTime.now().toIso8601String()});
    if (remoteMatches.length > 20) remoteMatches = remoteMatches.sublist(0, 20);
    await _prefs.setString('remoteMatches', jsonEncode(remoteMatches));
    notifyListeners();
  }

  Future<void> forgetRemoteMatch(String code) async {
    // If that match is the game in progress here, close it: its link would otherwise stay open.
    final s = session, link = s?.match;
    if (s != null && link != null && link.transport is RelayTransport && (link.transport as RelayTransport).code == code) {
      session = null;
      s.dispose();
      unawaited(link.dispose());
    }
    remoteMatches.removeWhere((m) => m['code'] == code);
    await _prefs.setString('remoteMatches', jsonEncode(remoteMatches));
    await _prefs.remove('match:relay:$code');
    notifyListeners();
  }

  // Linked games' move logs, saved after every move (see LockstepMatch).

  @override
  Map<String, dynamic>? load(String key) {
    final raw = _prefs.getString('match:$key');
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  @override
  void save(String key, Map<String, dynamic> log) {
    _prefs.setString('match:$key', jsonEncode(log));
    // Keep the logs of the 30 most recent games.
    final keys = (_prefs.getStringList('matchLogs') ?? [])
      ..remove(key)
      ..insert(0, key);
    for (final old in keys.skip(30)) {
      _prefs.remove('match:$old');
    }
    _prefs.setStringList('matchLogs', keys.take(30).toList());
  }
}
