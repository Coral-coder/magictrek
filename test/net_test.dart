import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:magictrek/engine/actions.dart';
import 'package:magictrek/engine/bot.dart';
import 'package:magictrek/engine/cards.dart';
import 'package:magictrek/engine/decks.dart';
import 'package:magictrek/net/lan.dart';
import 'package:magictrek/net/protocol.dart';
import 'package:magictrek/net/transport.dart';

late CardDatabase db;

/// Two LockstepMatch instances play a full bot game against each other across a transport.
Future<void> playAcross(Transport a, Transport b) async {
  final decks = StarterDecks.all(db);
  final host = LockstepMatch(transport: a, db: db, localName: 'Host', localId: 'h', localDeck: decks[0].cardList, isHost: true, seed: 42);
  final guest = LockstepMatch(transport: b, db: db, localName: 'Guest', localId: 'g', localDeck: decks[1].cardList, isHost: false);
  host.begin();
  guest.begin();
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while ((host.game == null || guest.game == null) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(host.game, isNotNull);
  expect(guest.game, isNotNull);
  // Each side moves only when it is their turn; bots pick the moves.
  var steps = 0;
  while (!host.game!.state.isOver && steps < 1500 && host.error == null && guest.error == null) {
    final hp = host.game!.state.playerToAct;
    if (hp == host.localSeat) {
      final action = Bot.nextAction(host.game!, hp!);
      host.perform(action!);
    } else {
      // Wait for the guest to see the same state, then let them move.
      while (guest.actions.length < host.actions.length && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final gp = guest.game!.state.playerToAct;
      expect(gp, guest.localSeat, reason: 'guest should be to act at seq ${guest.actions.length}');
      guest.perform(Bot.nextAction(guest.game!, gp!)!);
    }
    while (guest.actions.length != host.actions.length && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    steps++;
  }
  expect(host.error, isNull);
  expect(guest.error, isNull);
  expect(host.desynced, isFalse);
  expect(host.game!.state.isOver, isTrue, reason: 'game should finish within $steps moves');
  expect(guest.game!.state.digest(), host.game!.state.digest());
  await host.dispose();
  await guest.dispose();
}

/// A relay in miniature: every message goes to everyone else in the room, and a device that joins
/// gets the room's history first, old hellos and all. A device never hears its own messages back.
class Hub {
  final List<HubWire> ends = [];
  final List<(String, String)> history = [];
  bool up = true;

  HubWire join(String id) {
    final w = HubWire(this, id);
    ends.add(w);
    for (final (from, m) in List.of(history)) {
      if (from != id) scheduleMicrotask(() => w._in.add(m));
    }
    return w;
  }

  /// The connection drops: nothing gets through, and nothing is kept.
  void cut() => up = false;

  /// It comes back: every device is told, as a relay reconnecting would.
  void restore() {
    up = true;
    for (final e in ends) {
      e._state.add(LinkState.connected);
    }
  }
}

class HubWire implements Transport {
  HubWire(this.hub, this.id);
  final Hub hub;
  final String id;
  final _in = StreamController<String>.broadcast();
  final _state = StreamController<LinkState>.broadcast();
  bool closed = false;

  @override
  LinkKind get kind => LinkKind.relay;
  @override
  Stream<String> get messages => _in.stream;
  @override
  Stream<LinkState> get stateChanges => _state.stream;
  @override
  LinkState get state => closed ? LinkState.closed : LinkState.connected;
  @override
  Future<void> send(String message) async {
    if (closed || !hub.up) return;
    hub.history.add((id, message));
    for (final e in List.of(hub.ends)) {
      if (e != this && !e.closed) e._in.add(message);
    }
  }

  @override
  Future<void> close() async {
    closed = true;
    hub.ends.remove(this);
  }
}

/// A device's saved logs, kept as JSON text the way the app keeps them.
class MemoryArchive implements MatchArchive {
  final Map<String, String> logs = {};
  @override
  Map<String, dynamic>? load(String key) => logs[key] == null ? null : jsonDecode(logs[key]!) as Map<String, dynamic>;
  @override
  void save(String key, Map<String, dynamic> log) => logs[key] = jsonEncode(log);
}

LockstepMatch hostOn(Transport t, MatchArchive a, {int seed = 42}) =>
    LockstepMatch(transport: t, db: db, localName: 'Host', localId: 'h', localDeck: StarterDecks.all(db)[0].cardList, isHost: true, seed: seed, matchKey: 'relay:TEST', archive: a);

LockstepMatch guestOn(Transport t, MatchArchive a) =>
    LockstepMatch(transport: t, db: db, localName: 'Guest', localId: 'g', localDeck: StarterDecks.all(db)[1].cardList, isHost: false, matchKey: 'relay:TEST', archive: a);

Future<void> until(bool Function() done, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out${reason == null ? '' : ': $reason'}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

bool inStep(LockstepMatch a, LockstepMatch b) =>
    a.game != null && b.game != null && a.actions.length == b.actions.length && a.digests.last == b.digests.last && a.error == null && b.error == null;

/// The player to act moves (a bot picks), and both devices see it before the next move.
Future<void> playMoves(LockstepMatch host, LockstepMatch guest, int n) async {
  for (var i = 0; i < n && !host.game!.state.isOver; i++) {
    final p = host.game!.state.playerToAct!;
    final mover = p == host.localSeat ? host : guest;
    mover.perform(Bot.nextAction(mover.game!, p)!);
    await until(() => inStep(host, guest), reason: 'move ${host.actions.length}');
  }
}

/// Both devices start a match on [hub] and play [moves] moves.
Future<(LockstepMatch, LockstepMatch)> startMatch(Hub hub, MatchArchive ha, MatchArchive ga, {int moves = 20}) async {
  final host = hostOn(hub.join('h'), ha)..begin();
  final guest = guestOn(hub.join('g'), ga)..begin();
  await until(() => inStep(host, guest), reason: 'deal');
  await playMoves(host, guest, moves);
  return (host, guest);
}

void main() {
  setUpAll(() {
    db = CardDatabase.fromJsonString(File('assets/cards.json').readAsStringSync());
  });

  test('lockstep over loopback plays a whole game in sync', () async {
    final (a, b) = LoopbackTransport.pair();
    await playAcross(a, b);
  });

  test('lockstep catches a divergence', () async {
    final (a, b) = LoopbackTransport.pair();
    final decks = StarterDecks.all(db);
    final host = LockstepMatch(transport: a, db: db, localName: 'Host', localId: 'h', localDeck: decks[0].cardList, isHost: true, seed: 7);
    final guest = LockstepMatch(transport: b, db: db, localName: 'Guest', localId: 'g', localDeck: decks[1].cardList, isHost: false);
    host.begin();
    guest.begin();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    // Tamper with the guest's state, then let the host move: digests must disagree.
    guest.game!.state.players[0].life = 99;
    final p = host.game!.state.playerToAct!;
    if (p == host.localSeat) {
      host.perform(Bot.nextAction(host.game!, p)!);
    } else {
      guest.perform(Bot.nextAction(guest.game!, p)!);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(host.desynced || guest.desynced, isTrue);
    await host.dispose();
    await guest.dispose();
  });

  test('a device that crashed picks the game up from its saved log', () async {
    final hub = Hub();
    final ha = MemoryArchive(), ga = MemoryArchive();
    var (host, guest) = await startMatch(hub, ha, ga);
    final moves = host.actions.length;
    final where = host.digests.last;
    // The host's app dies; all that is left of it is what it saved.
    await host.dispose();
    host = hostOn(hub.join('h'), ha, seed: 999);
    expect(host.actions.length, moves, reason: 'the saved log is loaded at once');
    expect(host.digests.last, where);
    host.begin();
    await until(() => inStep(host, guest));
    await playMoves(host, guest, 20);
    expect(inStep(host, guest), isTrue);
    expect(host.desynced || guest.desynced, isFalse);
    // Now the guest's app dies too, and comes back.
    await guest.dispose();
    guest = guestOn(hub.join('g'), ga)..begin();
    await until(() => inStep(host, guest));
    await playMoves(host, guest, 10);
    await host.dispose();
    await guest.dispose();
  });

  test('a host that lost its saved game takes the one the guest has', () async {
    final hub = Hub();
    final ga = MemoryArchive();
    var (host, guest) = await startMatch(hub, MemoryArchive(), ga);
    final moves = guest.actions.length;
    await host.dispose();
    // A reinstall: nothing saved, and a new seed that would deal a different game.
    host = hostOn(hub.join('h'), MemoryArchive(), seed: 12345)..begin();
    await until(() => inStep(host, guest));
    expect(host.gameId, guest.gameId);
    expect(host.actions.length, moves);
    await playMoves(host, guest, 10);
    await host.dispose();
    await guest.dispose();
  });

  test('a move that never arrived is fetched when the link comes back', () async {
    final hub = Hub();
    final (host, guest) = await startMatch(hub, MemoryArchive(), MemoryArchive());
    hub.cut();
    final p = host.game!.state.playerToAct!;
    final mover = p == host.localSeat ? host : guest;
    mover.perform(Bot.nextAction(mover.game!, p)!);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(host.actions.length == guest.actions.length, isFalse);
    hub.restore();
    await until(() => inStep(host, guest));
    await playMoves(host, guest, 10);
    await host.dispose();
    await guest.dispose();
  });

  test('when the histories split, both go back to the last shared move and the host’s moves stand', () async {
    final hub = Hub();
    final (host, guest) = await startMatch(hub, MemoryArchive(), MemoryArchive());
    final shared = host.actions.length;
    hub.cut();
    // Cut off from each other, each device records something different after the same move.
    final p = host.game!.state.playerToAct!;
    final mover = p == host.localSeat ? host : guest;
    final other = p == host.localSeat ? guest : host;
    mover.perform(Bot.nextAction(mover.game!, p)!);
    other.perform(const ConcedeAction());
    mover.perform(Bot.nextAction(mover.game!, mover.game!.state.playerToAct!) ?? const PassPhaseAction());
    final hostLine = List.of(host.digests);
    hub.restore();
    await until(() => inStep(host, guest));
    expect(host.digests, hostLine, reason: 'the host keeps its moves');
    expect(guest.digests, hostLine);
    expect(guest.digests[shared - 1], host.digests[shared - 1]);
    expect(guest.notice, isNotNull, reason: 'the guest is told it went back');
    if (!host.game!.state.isOver) await playMoves(host, guest, 10);
    await host.dispose();
    await guest.dispose();
  });

  test('two moves at the same moment: the host’s stands and nobody falls out of step', () async {
    final hub = Hub();
    final (host, guest) = await startMatch(hub, MemoryArchive(), MemoryArchive());
    final p = host.game!.state.playerToAct!;
    final mover = p == host.localSeat ? host : guest;
    final other = p == host.localSeat ? guest : host;
    // Both send before either hears the other.
    mover.perform(Bot.nextAction(mover.game!, p)!);
    other.perform(const ConcedeAction());
    await until(() => inStep(host, guest));
    expect(host.desynced || guest.desynced, isFalse);
    await host.dispose();
    await guest.dispose();
  });

  test('conceding on the other player’s move ends the game the same way on both devices', () async {
    final hub = Hub();
    final (host, guest) = await startMatch(hub, MemoryArchive(), MemoryArchive());
    final p = host.game!.state.playerToAct!;
    final waiting = p == host.localSeat ? guest : host;
    waiting.perform(const ConcedeAction());
    await until(() => inStep(host, guest));
    expect(host.game!.state.winner, 1 - waiting.localSeat);
    expect(guest.game!.state.winner, 1 - waiting.localSeat);
    await host.dispose();
    await guest.dispose();
  });

  test('LAN discovery and TCP transport on loopback', () async {
    final hostLink = LanHost();
    await hostLink.start(name: 'Enterprise', id: 'h1');
    final guestLink = LanGuest();
    await guestLink.startScan();
    List<PeerInfo> seen = [];
    final sub = guestLink.peers.listen((p) => seen = p);
    final deadline = DateTime.now().add(const Duration(seconds: 6));
    while (seen.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await sub.cancel();
    // Broadcast may be blocked in a sandbox; fall back to a direct connection on the known port.
    final pending = hostLink.connections.first;
    final guestTransport = seen.isNotEmpty ? await guestLink.connect(seen.first) : await guestLink.connectTo('127.0.0.1', hostLink.port);
    final hostTransport = await pending.timeout(const Duration(seconds: 5));
    await guestLink.stopScan();
    await playAcross(hostTransport, guestTransport);
    await hostLink.stop();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
