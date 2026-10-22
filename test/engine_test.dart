import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:magictrek/engine/abilities.dart';
import 'package:magictrek/engine/actions.dart';
import 'package:magictrek/engine/bot.dart';
import 'package:magictrek/engine/cards.dart';
import 'package:magictrek/engine/decks.dart';
import 'package:magictrek/engine/game.dart';
import 'package:magictrek/engine/rng.dart';
import 'package:magictrek/engine/rules.dart';
import 'package:magictrek/engine/state.dart';

late CardDatabase db;

/// Plays a whole game between two bots and returns the actions taken.
(Game, List<GameAction>) playBotGame(int seed, List<Deck> decks, {int maxActions = 3000}) {
  final game = Game(playerNames: const ['Kirk', 'Picard'], bots: const [true, true], seed: seed, db: db);
  final actions = <GameAction>[StartAction(decks.map((d) => d.cardList).toList())];
  game.apply(actions[0]);
  var steps = 0;
  while (!game.state.isOver && steps < maxActions) {
    final p = game.state.playerToAct;
    final action = p == null ? null : Bot.nextAction(game, p);
    if (p == null || action == null) {
      fail('Seed $seed: nobody can act in ${game.state.phase} turn ${game.state.turn}, pending ${game.state.pending?.decision}');
    }
    try {
      game.applyAs(action, p);
    } catch (e) {
      fail('Seed $seed turn ${game.state.turn} ${game.state.phase}: $action failed: $e');
    }
    actions.add(action);
    steps++;
  }
  return (game, actions);
}

void main() {
  setUpAll(() {
    db = CardDatabase.fromJsonString(File('assets/cards.json').readAsStringSync());
  });

  test('database loads and parses like the reference', () {
    expect(db.cards.length, greaterThan(300));
    expect(db.byName('Captain Jean-Luc Picard'), isNotNull);
    expect(db.byName('Swamp')!.isBasicLand, isTrue);
    expect(db.parsed(db.byName('Swamp')!).manaColors, [ManaColor.black]);
    final full = db.distinctCards.where((c) => db.parsed(c).fullySupported).length;
    final partial = db.distinctCards.where((c) => !db.parsed(c).fullySupported && db.parsed(c).anySupported).length;
    // The Swift parser reached 117 fully / 60 partially; the Dart port must not regress.
    expect(full, greaterThanOrEqualTo(117), reason: '$full fully supported');
    expect(partial, greaterThanOrEqualTo(55), reason: '$partial partially supported');
    final burst = db.parsed(db.byName('Burst Lightning')!);
    expect(burst.kicker, isNotNull);
    expect(burst.spellEffects.whereType<KickedInstead>(), isNotEmpty);
  });

  test('mana cost parsing', () {
    final c = ManaCost.parse('{2}{W}{W}');
    expect(c.generic, 2);
    expect(c.colored[ManaColor.white], 2);
    expect(c.manaValue, 4);
    final h = ManaCost.parse('{X}{U/B}{C}');
    expect(h.hasX, isTrue);
    expect(h.hybrid, [
      [ManaColor.blue, ManaColor.black]
    ]);
    expect(h.generic, 1);
  });

  test('starter decks are legal', () {
    for (final faction in StarterDecks.factions) {
      final deck = StarterDecks.deck(faction, db);
      expect(deck.count, 60, reason: faction.name);
      expect(deck.isLegal(db), isTrue, reason: '${faction.name}: ${deck.problems(db)}');
      final lands = deck.cards.entries.where((e) => db[e.key]?.isLand == true).fold<int>(0, (a, e) => a + e.value);
      expect(lands, inInclusiveRange(20, 27), reason: '${faction.name} has $lands lands');
    }
  });

  test('bot games finish and replay deterministically', () {
    final decks = StarterDecks.all(db);
    var finished = 0;
    var totalTurns = 0;
    for (var seed = 1; seed <= 24; seed++) {
      final d1 = decks[seed % decks.length], d2 = decks[(seed + 1) % decks.length];
      final (game, actions) = playBotGame(seed, [d1, d2]);
      if (game.state.isOver) finished++;
      totalTurns += game.state.turn;
      final replay = Game(playerNames: const ['Kirk', 'Picard'], bots: const [true, true], seed: seed, db: db);
      for (final a in actions) {
        replay.apply(a);
      }
      expect(replay.state.digest(), game.state.digest(), reason: 'seed $seed replay diverged');
      // Actions survive JSON (what the network and the save file carry).
      final replay2 = Game(playerNames: const ['Kirk', 'Picard'], bots: const [true, true], seed: seed, db: db);
      for (final a in actions) {
        final round = GameAction.fromJson(a.toJson());
        expect(round, a);
        replay2.apply(round);
      }
      expect(replay2.state.digest(), game.state.digest());
    }
    expect(finished, greaterThanOrEqualTo(22), reason: 'only $finished/24 games finished');
    // ignore: avoid_print
    print('average turns per game: ${totalTurns ~/ 24}');
  });

  test('every card can be in a game without crashing', () {
    final all = db.distinctCards.where((c) => !c.isBasicLand && c.set != 'sds').toList();
    final basics = ['Plains', 'Island', 'Swamp', 'Mountain', 'Forest'].map((n) => db.byName(n)!).toList();
    for (var seed = 1; seed <= 8; seed++) {
      final rng = SeededRng(seed * 7919);
      final pick = List.of(all);
      rng.shuffle(pick);
      Deck deck(Iterable<Card> slice) {
        final cards = <String, int>{};
        for (final c in slice.take(36)) {
          cards[c.id] = 1;
        }
        for (var i = 0; i < basics.length; i++) {
          cards[basics[i].id] = i < 4 ? 5 : 4;
        }
        return Deck(name: 'Chaos', cards: cards);
      }
      playBotGame(seed, [deck(pick), deck(pick.skip(40))], maxActions: 1500);
    }
  });

  group('rule options', () {
    Game start(Rules rules) {
      final game = Game(playerNames: const ['A', 'B'], bots: const [false, false], seed: 7, db: db);
      final plains = db.byName('Plains')!.id;
      final shock = db.byName('Burst Lightning')?.id ?? plains;
      final deck = [for (var i = 0; i < 40; i++) i.isEven ? plains : shock];
      game.apply(StartAction([deck, deck], rules: rules));
      return game;
    }

    test('London mulligan redraws a full hand and bottoms one card per mulligan', () {
      final game = start(const Rules());
      final p = game.state.startingPlayer;
      expect(game.state.pending?.decision, isA<MulliganDecision>());
      game.apply(const RespondAction(MulliganResponse()));
      expect(game.state.players[p].hand.length, 7);
      expect(game.state.pending?.decision, isA<ChooseBottomDecision>());
      final bottom = game.state.players[p].hand.first;
      game.apply(RespondAction(CardsResponse([bottom])));
      expect(game.state.players[p].hand.length, 6);
      expect(game.state.players[p].library.last, bottom);
      expect(game.state.pending?.decision, isA<MulliganDecision>());
      game.apply(const RespondAction(MulliganResponse()));
      expect((game.state.pending!.decision as ChooseBottomDecision).count, 2);
    });

    test('classic mulligan draws one card fewer; the free mulligan costs nothing', () {
      final classic = start(const Rules(londonMulligan: false));
      classic.apply(const RespondAction(MulliganResponse()));
      expect(classic.state.players[classic.state.startingPlayer].hand.length, 6);
      expect(classic.state.pending?.decision, isA<MulliganDecision>());

      final free = start(const Rules(freeMulligan: true));
      free.apply(const RespondAction(MulliganResponse()));
      expect(free.state.players[free.state.startingPlayer].hand.length, 7);
      expect(free.state.pending?.decision, isA<MulliganDecision>());
      free.apply(const RespondAction(MulliganResponse()));
      expect(free.state.pending?.decision, isA<ChooseBottomDecision>());
    });

    test('starting life, hand size and the first draw follow the rules', () {
      final game = start(const Rules(startingLife: 30, handSize: 5, firstPlayerDraws: true));
      final p = game.state.startingPlayer;
      expect(game.state.players.every((ps) => ps.life == 30), isTrue);
      expect(game.state.players[p].hand.length, 5);
      game.apply(const RespondAction(KeepResponse()));
      game.apply(const RespondAction(KeepResponse()));
      expect(game.state.players[p].hand.length, 6, reason: 'the first player drew on turn one');

      final normal = start(const Rules());
      final q = normal.state.startingPlayer;
      normal.apply(const RespondAction(KeepResponse()));
      normal.apply(const RespondAction(KeepResponse()));
      expect(normal.state.players[q].hand.length, 7, reason: 'no draw on the first turn');
    });

    test('rules travel in the start action and the digest', () {
      const rules = Rules(startingLife: 40, londonMulligan: false, maxHandSize: false);
      final action = StartAction(const [[], []], rules: rules);
      final back = GameAction.fromJson(action.toJson()) as StartAction;
      expect(back.rules, rules);
      expect(GameAction.fromJson(const StartAction([[], []]).toJson()), const StartAction([[], []]));
      expect(start(rules).state.digest(), isNot(start(const Rules()).state.digest()));
    });
  });

  group('rules', () {
    Game makeGame(List<String> hand1, [List<String> hand2 = const []]) {
      final game = Game(playerNames: const ['A', 'B'], bots: const [false, false], seed: 1, db: db);
      final filler = List.filled(40, db.byName('Plains')!.id);
      game.apply(StartAction([filler, filler]));
      for (var p = 0; p < 2; p++) {
        for (final id in List.of(game.state.players[p].hand)) {
          game.move(id, Zone.library, toBottom: true);
        }
        for (final cardID in p == 0 ? hand1 : hand2) {
          final id = game.newObject(cardID: cardID, owner: p, zone: Zone.hand);
          game.state.players[p].hand.add(id);
        }
      }
      game.apply(const RespondAction(KeepResponse()));
      game.apply(const RespondAction(KeepResponse()));
      if (game.state.activePlayer != 0) {
        game.apply(const EndTurnAction());
        final pending = game.state.pending;
        if (pending != null && pending.decision is DiscardToHandSizeDecision) {
          game.apply(RespondAction(CardsResponse(game.state.players[1].hand.take(1).toList())));
        }
      }
      expect(game.state.activePlayer, 0);
      expect(game.state.phase, Phase.main1);
      return game;
    }

    ObjectID tokenOf(Game game, PlayerID p) => game.state.permanentsOf(p).firstWhere((o) => o.isToken).id;

    test('cast creature, attack and block', () {
      final mountain = db.byName('Mountain')!.id;
      final game = makeGame([mountain, mountain]);
      final lands = game.state.players[0].hand.where((id) => game.card(id)?.isLand == true).toList();
      game.apply(PlayLandAction(lands[0]));
      expect(() => game.apply(PlayLandAction(lands[1])), throwsA(isA<GameError>()), reason: 'one land per turn');
      expect(game.state.permanentsOf(0).length, 1);
      game.apply(const EndTurnAction());
      expect(game.state.activePlayer, 1);
      game.apply(const EndTurnAction());
      expect(game.state.activePlayer, 0);
      game.apply(PlayLandAction(lands[1]));
      game.createToken(TokenSpec(name: 'Officer', power: 2, toughness: 2, colors: [ManaColor.red], subtypes: ['Officer']), 0);
      final token = tokenOf(game, 0);
      expect(game.canAttack(token), isFalse, reason: 'summoning sick');
      game.apply(const EndTurnAction());
      game.apply(const EndTurnAction());
      expect(game.canAttack(token), isTrue);
      final lifeBefore = game.state.players[1].life;
      game.apply(DeclareAttackersAction([token]));
      expect(game.state.players[1].life, lifeBefore - 2);
      expect(game.state.phase, Phase.main2);
      game.apply(const EndTurnAction());
      game.createToken(TokenSpec(name: 'Guard', power: 1, toughness: 3), 1);
      final guard = tokenOf(game, 1);
      game.apply(const EndTurnAction());
      game.apply(DeclareAttackersAction([token]));
      expect(game.state.pending, isNotNull);
      expect(game.state.playerToAct, 1);
      game.applyAs(RespondAction(BlockersResponse({guard: token})), 1);
      expect(game.state.players[1].life, lifeBefore - 2, reason: 'blocked');
      expect(game.state.objects[guard]!.damage, 2);
      expect(game.state.objects[guard]!.zone, Zone.battlefield);
      expect(game.state.objects[token]!.damage, 1);
      expect(game.state.phase, Phase.main2);
    });

    test('Burst Lightning kicked', () {
      final burst = db.byName('Burst Lightning')!.id;
      final mountain = db.byName('Mountain')!.id;
      final game = makeGame([burst, mountain, mountain, mountain, mountain, mountain]);
      for (var i = 0; i < 5; i++) {
        final land = game.state.players[0].hand.firstWhere((id) => game.card(id)?.isLand == true);
        game.apply(PlayLandAction(land));
        game.apply(const EndTurnAction());
        game.apply(const EndTurnAction());
      }
      final spell = game.state.players[0].hand.firstWhere((id) => game.card(id)?.name == 'Burst Lightning');
      expect(game.canCast(spell, 0), isTrue);
      final life = game.state.players[1].life;
      game.apply(CastAction(spell, targets: [EffectContext.playerObject(1)], kicked: true));
      expect(game.state.players[1].life, life - 4);
      expect(game.state.objects[spell]!.zone, Zone.graveyard);
      expect(game.state.permanentsOf(0).where((o) => o.tapped).length, 5);
    });

    test('Station makes a Spacecraft a creature', () {
      final ship = db.byName('Suurok-Class Science Vessel')!;
      final game = makeGame([]);
      final id = game.newObject(cardID: ship.id, owner: 0, zone: Zone.hand);
      game.move(id, Zone.battlefield, controller: 0);
      game.createToken(TokenSpec(name: 'Crew', power: 3, toughness: 3), 0);
      final crew = tokenOf(game, 0);
      game.apply(const EndTurnAction());
      game.apply(const EndTurnAction());
      expect(game.characteristics(id).isCreature, isFalse);
      game.apply(StationAction(id, crew));
      expect(game.state.objects[id]!.chargeCounters, 3);
      expect(game.characteristics(id).isCreature, isFalse);
      expect(game.state.objects[crew]!.tapped, isTrue);
      game.apply(const EndTurnAction());
      game.apply(const EndTurnAction());
      game.apply(StationAction(id, crew));
      expect(game.characteristics(id).isCreature, isTrue, reason: '5+ charge counters');
      expect(game.characteristics(id).has(KeywordKind.flying), isTrue);
      expect(game.characteristics(id).power, 3);
    });
  });
}
