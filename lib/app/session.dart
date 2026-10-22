import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../engine/actions.dart';
import '../engine/bot.dart';
import '../engine/cards.dart';
import '../engine/game.dart';
import '../engine/rules.dart';
import '../engine/state.dart';
import '../net/protocol.dart';
import 'notifications.dart';
import 'sound.dart';

enum SessionMode { solo, hotseat, linked }

/// One game being played on this device: drives the engine, runs the computer player, keeps the
/// action log for saving, or defers to a LockstepMatch when the opponent is on another device.
class GameSession extends ChangeNotifier {
  GameSession.local({required this.mode, required List<String> playerNames, required this.seed, required this.decks, required this.db, this.rules = Rules.standard})
      : playerNames = List.of(playerNames),
        match = null,
        game = Game(playerNames: playerNames, bots: mode == SessionMode.solo ? const [false, true] : const [false, false], seed: seed, db: db) {
    localSeat = 0;
  }

  /// Linked (LAN, Bluetooth or relay): the LockstepMatch owns the game.
  GameSession.linked({required LockstepMatch match, required this.db})
      : mode = SessionMode.linked,
        seed = 0,
        rules = Rules.standard,
        match = match,
        playerNames = [match.game!.state.players[0].name, match.game!.state.players[1].name],
        decks = const [],
        game = match.game! {
    localSeat = match.localSeat;
    _lastLogCount = game.state.log.length;
    _matchSub = match.events.listen((e) {
      if (e == 'action') _afterChange(remote: true);
      if (e == 'rewind' || e == 'start') _followMatch();
      if (e == 'desync' || e == 'error') {
        lastError = match.error;
        notifyListeners();
      }
    });
  }

  final SessionMode mode;
  final int seed;

  /// The rules a local game starts under (a linked game's are in its start action).
  final Rules rules;
  final List<String> playerNames;
  final List<List<String>> decks;
  final CardDatabase db;
  final LockstepMatch? match;
  Game game;
  final List<GameAction> actions = [];
  String? lastError;

  /// Something the table should say once, such as the game going back a few moves.
  String? notice;

  /// Counts the times the game was replaced under the table (a rewind), so it can drop a half-made move.
  int resets = 0;
  List<GameEvent> recentEvents = [];
  bool thinking = false;
  late PlayerID localSeat;
  int _lastLogCount = 0;
  Timer? _botTimer;
  bool _botRunning = false;
  StreamSubscription? _matchSub;
  /// Called when a game is saved (solo/hotseat) so the store can refresh.
  void Function(Map<String, dynamic> saved)? onSave;
  void Function()? onFinished;
  bool appInForeground = true;

  GameState get state => game.state;
  bool get isLocalTurn => state.playerToAct == localSeat;
  PlayerID get opponentSeat => state.opponentOf(localSeat);
  bool get isLinked => mode == SessionMode.linked;

  void start() => perform(StartAction(decks, rules: rules));

  /// Resumes a saved local game by replaying its actions.
  void replay(List<GameAction> saved) {
    for (final a in saved) {
      try {
        game.apply(a);
        actions.add(a);
      } catch (_) {
        break;
      }
    }
    _lastLogCount = state.log.length;
    if (mode == SessionMode.hotseat) localSeat = state.playerToAct ?? 0;
    _runBotIfNeeded();
    notifyListeners();
  }

  /// Applies an action for the local player, then lets the bot (or the link) respond.
  void perform(GameAction action) {
    try {
      final m = match;
      if (m != null) {
        m.perform(action);
      } else if (action is StartAction) {
        game.apply(action);
        actions.add(action);
      } else {
        game.applyAs(action, localSeat);
        actions.add(action);
      }
      lastError = null;
      notice = null;
      _afterChange();
    } catch (e) {
      lastError = '$e';
      Console.shared.play(Fx.deny);
      notifyListeners();
    }
  }

  /// The linked game went back to the last move both devices share (or switched to the other
  /// device's copy): pick up its new state.
  void _followMatch() {
    final m = match!;
    game = m.game!;
    localSeat = m.localSeat;
    playerNames
      ..clear()
      ..addAll([for (final p in game.state.players) p.name]);
    _lastLogCount = state.log.length;
    recentEvents = [];
    notice = m.notice;
    lastError = null;
    resets++;
    notifyListeners();
  }

  void _afterChange({bool remote = false}) {
    final newEvents = state.log.skip(_lastLogCount).toList();
    _lastLogCount = state.log.length;
    recentEvents = newEvents;
    for (final e in newEvents) {
      _sound(e);
    }
    if (mode == SessionMode.hotseat) {
      final p = state.playerToAct;
      if (p != null) localSeat = p;
    }
    if (mode != SessionMode.linked) _save();
    if (remote && !appInForeground && isLocalTurn) {
      Notifications.shared.yourMove(title: 'Your move, ${playerNames[localSeat]}', body: 'Turn ${state.turn} against ${playerNames[opponentSeat]}.');
    }
    if (state.isOver) onFinished?.call();
    notifyListeners();
    _runBotIfNeeded();
  }

  void _sound(GameEvent e) {
    switch (e.kind) {
      case 'drew':
        if (e.player == localSeat) Console.shared.play(Fx.draw);
      case 'attackersDeclared':
        Console.shared.play(Fx.attack);
      case 'damage':
        if (e.object != null && EffectContext.playerFromObject(e.object!) != null) Console.shared.play(Fx.damage);
      case 'gameOver':
        Console.shared.play(e.player == localSeat ? Fx.victory : Fx.defeat);
      case 'cast':
        Console.shared.play(Fx.chirp);
    }
  }

  void _runBotIfNeeded() {
    if (mode != SessionMode.solo || state.isOver || _botRunning) return;
    final p = state.playerToAct;
    if (p == null || !state.players[p].isBot) return;
    _botRunning = true;
    thinking = true;
    notifyListeners();
    _botTimer = Timer(const Duration(milliseconds: 550), _botStep);
  }

  void _botStep() {
    if (state.isOver) {
      _finishBot();
      return;
    }
    final p = state.playerToAct;
    if (p == null || !state.players[p].isBot) {
      _finishBot();
      return;
    }
    final action = Bot.nextAction(game, p);
    if (action == null) {
      _finishBot();
      return;
    }
    try {
      game.applyAs(action, p);
      actions.add(action);
    } catch (e) {
      debugPrint('Bot action failed: $e');
      _finishBot();
      return;
    }
    final newEvents = state.log.skip(_lastLogCount).toList();
    _lastLogCount = state.log.length;
    recentEvents = newEvents;
    for (final e in newEvents) {
      _sound(e);
    }
    notifyListeners();
    final pause = switch (action) {
      CastAction _ || DeclareAttackersAction _ || PlayLandAction _ => 650,
      RespondAction _ => 400,
      _ => 250,
    };
    _botTimer = Timer(Duration(milliseconds: pause), _botStep);
  }

  void _finishBot() {
    _botRunning = false;
    thinking = false;
    _save();
    if (state.isOver) onFinished?.call();
    if (!appInForeground && !state.isOver) {
      Notifications.shared.yourMove(title: 'Your move, ${playerNames[localSeat]}', body: 'Turn ${state.turn}: the computer has finished its turn.');
    }
    notifyListeners();
  }

  void _save() {
    if (mode == SessionMode.linked || state.isOver) return;
    onSave?.call({
      'mode': mode.name,
      'seed': seed,
      'names': playerNames,
      'decks': decks,
      'actions': actions.map((a) => a.toJson()).toList(),
      'date': DateTime.now().toIso8601String(),
    });
  }

  String get saveJson => jsonEncode({'mode': mode.name, 'seed': seed, 'names': playerNames, 'decks': decks, 'actions': actions.map((a) => a.toJson()).toList()});

  void concede() => perform(ConcedeAction(localSeat));

  @override
  void dispose() {
    _botTimer?.cancel();
    _matchSub?.cancel();
    super.dispose();
  }
}
