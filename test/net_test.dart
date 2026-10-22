import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
