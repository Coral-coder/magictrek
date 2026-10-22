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

/// Declines every response window that is open.
void passWindows(Game game) {
  while (game.state.priority != null && game.state.pending == null) {
    game.apply(const PassPriorityAction());
  }
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
    // Nearly every card's text is understood; the few left are at least partly.
    expect(full, greaterThanOrEqualTo(225), reason: '$full fully supported');
    expect(full + partial, greaterThanOrEqualTo(232), reason: '${full + partial} at least partly supported');
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
      [ManaColor.blue, ManaColor.black],
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
        passWindows(game);
        game.apply(const EndTurnAction());
        // Player 0 holds an instant, so they may respond at the end of the opponent's turn.
        passWindows(game);
      }
      final spell = game.state.players[0].hand.firstWhere((id) => game.card(id)?.name == 'Burst Lightning');
      expect(game.canCast(spell, 0), isTrue);
      final life = game.state.players[1].life;
      game.apply(CastAction(spell, targets: [EffectContext.playerObject(1)], kicked: true));
      expect(game.state.players[1].life, life - 4);
      expect(game.state.objects[spell]!.zone, Zone.graveyard);
      expect(game.state.permanentsOf(0).where((o) => o.tapped).length, 5);
    });

    /// Puts `n` untapped basic lands named `land` onto player `p`'s battlefield.
    void giveLands(Game game, PlayerID p, String land, int n) {
      for (var i = 0; i < n; i++) {
        final id = game.newObject(cardID: db.byName(land)!.id, owner: p, zone: Zone.hand);
        game.move(id, Zone.battlefield, controller: p);
        game.state.objects[id]!.enteredTurn = -5;
      }
    }

    test('a spell goes on the stack and the opponent can counter it', () {
      final bear = db.distinctCards.firstWhere((c) => c.isCreature && c.manaCost == '{1}{W}' && db.parsed(c).fullySupported).id;
      final refute = db.byName('Refute')!.id;
      final game = makeGame([bear], [refute]);
      giveLands(game, 0, 'Plains', 2);
      giveLands(game, 1, 'Island', 3);
      final spell = game.state.players[0].hand.firstWhere((id) => game.state.objects[id]!.cardID == bear);
      game.apply(CastAction(spell));
      expect(game.state.objects[spell]!.zone, Zone.stack);
      expect(game.state.priority, 1, reason: 'the opponent holds a counterspell');
      expect(game.state.playerToAct, 1);
      final counter = game.state.players[1].hand.firstWhere((id) => game.state.objects[id]!.cardID == refute);
      expect(game.canCast(counter, 1), isTrue);
      expect(() => game.apply(const EndTurnAction()), throwsA(isA<GameError>()));
      game.applyAs(CastAction(counter, targets: [spell]), 1);
      passWindows(game);
      // Refute: draw, then discard (player 1 chooses).
      final pending = game.state.pending;
      if (pending != null && pending.decision is DiscardToHandSizeDecision) {
        game.apply(RespondAction(CardsResponse([game.state.players[1].hand.first])));
      }
      expect(game.state.objects[spell]!.zone, Zone.graveyard);
      expect(game.state.objects[counter]!.zone, Zone.graveyard);
      expect(game.state.stack, isEmpty);
      expect(game.state.permanentsOf(0).where((o) => game.state.objects[o.id]!.cardID == bear), isEmpty);
    });

    test('counter unless its controller pays', () {
      final bear = db.distinctCards.firstWhere((c) => c.isCreature && c.manaCost == '{1}{W}' && db.parsed(c).fullySupported).id;
      final prime = db.byName('Consider the Prime Directive')!.id;
      final game = makeGame([bear], [prime]);
      giveLands(game, 0, 'Plains', 5);
      giveLands(game, 1, 'Island', 3);
      final spell = game.state.players[0].hand.firstWhere((id) => game.state.objects[id]!.cardID == bear);
      game.apply(CastAction(spell));
      final counter = game.state.players[1].hand.first;
      game.applyAs(CastAction(counter, targets: [spell], mode: 0), 1);
      passWindows(game);
      expect(game.state.pending?.decision, isA<PayOrCounterDecision>());
      game.apply(const RespondAction(YesResponse()));
      passWindows(game);
      expect(game.state.objects[spell]!.zone, Zone.battlefield, reason: 'paid {3}, so it resolved');
      expect(game.state.permanentsOf(0).where((o) => o.tapped).length, 5);
    });

    test('no window opens for a player with nothing to cast', () {
      final bear = db.distinctCards.firstWhere((c) => c.isCreature && c.manaCost == '{1}{W}' && db.parsed(c).fullySupported).id;
      final game = makeGame([bear]);
      giveLands(game, 0, 'Plains', 2);
      final spell = game.state.players[0].hand.first;
      game.apply(CastAction(spell));
      expect(game.state.priority, isNull);
      expect(game.state.objects[spell]!.zone, Zone.battlefield);
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
    /// Puts a card straight onto player `p`'s battlefield, past summoning sickness.
    ObjectID putOnTable(Game game, PlayerID p, String name) {
      final id = game.newObject(cardID: db.byName(name)!.id, owner: p, zone: Zone.hand);
      game.move(id, Zone.battlefield, controller: p);
      game.state.objects[id]!.enteredTurn = -5;
      return id;
    }

    int abilityIndex(Game game, ObjectID id) {
      final all = game.abilitiesIn(game.state.objects[id]!);
      return all.indexWhere((a) => a is Activated);
    }

    test('Captain Picard taps seven Officers to fetch a Spacecraft with seven charge counters', () {
      final game = makeGame([]);
      final picard = putOnTable(game, 0, 'Captain Jean-Luc Picard');
      final ship = game.newObject(cardID: db.byName('Suurok-Class Science Vessel')!.id, owner: 0, zone: Zone.library);
      game.state.players[0].library.add(ship);
      final officer = TokenSpec(name: 'Officer', power: 1, toughness: 1, colors: [ManaColor.red], subtypes: ['Officer']);
      for (var i = 0; i < 6; i++) {
        game.createToken(officer, 0);
      }
      final index = abilityIndex(game, picard);
      // Picard is an Officer too: six tokens plus Picard make seven.
      expect(game.activationProblem(picard, index, 0), isNull);
      game.state.objects[picard]!.tapped = true;
      expect(game.activationProblem(picard, index, 0), isNotNull, reason: 'only six untapped Officers');
      game.state.objects[picard]!.tapped = false;
      game.createToken(officer, 0);
      game.apply(ActivateAbilityAction(picard, index));
      expect(game.state.objects[ship]!.zone, Zone.battlefield);
      expect(game.state.objects[ship]!.chargeCounters, 7);
      expect(game.state.permanentsOf(0).where((o) => o.isToken && o.tapped).length, 7);
      expect(game.state.objects[picard]!.tapped, isFalse, reason: 'the least valuable Officers are tapped first');
    });

    test('Lieutenant Commander Data removes three counters from among creatures to draw', () {
      final game = makeGame([]);
      giveLands(game, 0, 'Island', 1);
      final data = putOnTable(game, 0, 'Lieutenant Commander Data');
      final index = abilityIndex(game, data);
      game.state.objects[data]!.counters[CounterKind.plusOne] = 2;
      expect(game.activationProblem(data, index, 0), isNotNull, reason: 'only two counters');
      game.state.objects[data]!.counters[CounterKind.plusOne] = 4;
      final hand = game.state.players[0].hand.length;
      game.apply(ActivateAbilityAction(data, index));
      expect(game.state.objects[data]!.counters[CounterKind.plusOne], 1);
      expect(game.state.players[0].hand.length, hand + 1);
    });

    test('Relentless Drednok exiles itself from the graveyard to draw', () {
      final game = makeGame([]);
      giveLands(game, 0, 'Swamp', 3);
      final id = game.newObject(cardID: db.byName('Relentless Drednok')!.id, owner: 0, zone: Zone.graveyard);
      game.state.players[0].graveyard.add(id);
      final index = abilityIndex(game, id);
      expect(game.activationProblem(id, index, 0), isNull);
      final hand = game.state.players[0].hand.length, life = game.state.players[0].life;
      game.apply(ActivateAbilityAction(id, index));
      expect(game.state.objects[id]!.zone, Zone.exile);
      expect(game.state.players[0].hand.length, hand + 1);
      expect(game.state.players[0].life, life - 1);
    });

    test('Locutus is discarded from hand to deal 2 damage', () {
      final game = makeGame([db.byName('Locutus, the One Who Speaks')!.id]);
      giveLands(game, 0, 'Plains', 1);
      giveLands(game, 0, 'Swamp', 1);
      final enemy = putOnTable(game, 1, 'Relentless Drednok');
      final locutus = game.state.players[0].hand.first;
      final index = abilityIndex(game, locutus);
      final life = game.state.players[0].life;
      game.apply(ActivateAbilityAction(locutus, index, targets: [enemy]));
      expect(game.state.objects[locutus]!.zone, Zone.graveyard);
      expect(game.state.objects[enemy]!.zone, Zone.graveyard);
      expect(game.state.players[0].life, life + 2);
      expect(game.activationProblem(locutus, index, 0), isNotNull, reason: 'only from the hand');
    });

    test('Commander Spock casts the top card free when the lands allow it', () {
      final game = makeGame([]);
      giveLands(game, 0, 'Plains', 1);
      giveLands(game, 0, 'Island', 1);
      final drednok = game.newObject(cardID: db.byName('Relentless Drednok')!.id, owner: 0, zone: Zone.library);
      game.state.players[0].library.insert(0, drednok);
      final spock = game.newObject(cardID: db.byName('Commander Spock')!.id, owner: 0, zone: Zone.hand);
      game.move(spock, Zone.battlefield, controller: 0);
      game.fireTriggers(SimpleTrigger.enters, spock);
      // A human player is asked; the card waits on top of the library meanwhile.
      expect(game.state.pending?.decision, isA<FreeCastDecision>());
      final hand = game.state.players[0].hand.length;
      game.apply(const RespondAction(FreeCastResponse(cast: true)));
      passWindows(game);
      expect(game.state.objects[drednok]!.zone, Zone.battlefield, reason: 'mana value 1 <= 2 differently named lands');
      expect(game.state.players[0].hand.length, hand, reason: 'it left the top, so no draw');
    });

    test('Commander Spock: declining the free cast draws the card instead', () {
      final game = makeGame([]);
      giveLands(game, 0, 'Plains', 1);
      giveLands(game, 0, 'Island', 1);
      final drednok = game.newObject(cardID: db.byName('Relentless Drednok')!.id, owner: 0, zone: Zone.library);
      game.state.players[0].library.insert(0, drednok);
      final spock = game.newObject(cardID: db.byName('Commander Spock')!.id, owner: 0, zone: Zone.hand);
      game.move(spock, Zone.battlefield, controller: 0);
      game.fireTriggers(SimpleTrigger.enters, spock);
      game.apply(const RespondAction(FreeCastResponse(cast: false)));
      expect(game.state.objects[drednok]!.zone, Zone.hand, reason: 'still on top, so it is drawn');
    });

    test('Peace in Our Time: drawing stops the attack and wins only at twelve counters', () {
      final game = makeGame([]);
      final peace = putOnTable(game, 1, 'Peace in Our Time');
      game.state.players[0].isBot = true; // the bot decides whether to accept
      game.apply(const EndTurnAction());
      passWindows(game);
      expect(game.state.isOver, isFalse, reason: 'no win without twelve peace counters');
      game.state.objects[peace]!.counters[CounterKind.peace] = 12;
      game.apply(const EndTurnAction());
      passWindows(game);
      if (game.state.pending != null && game.state.pending!.decision is DiscardToHandSizeDecision) {
        game.apply(RespondAction(CardsResponse(game.state.players[1].hand.take(1).toList())));
      }
      game.apply(const EndTurnAction());
      passWindows(game);
      expect(game.state.winner, 1);
    });
    test('Khaaaaaaaaaaaannn! deals twice X and exiles the creature', () {
      final game = makeGame([db.byName('Khaaaaaaaaaaaannn!')!.id]);
      giveLands(game, 0, 'Mountain', 4);
      final enemy = putOnTable(game, 1, 'Lieutenant Commander Data');
      final spell = game.state.players[0].hand.first;
      expect(game.maxX(spell, 0), 3);
      game.apply(CastAction(spell, targets: [enemy], x: 2));
      passWindows(game);
      expect(game.state.objects[enemy]!.zone, Zone.exile, reason: '4 damage kills a 2/2 (+counters), and it is exiled instead');
    });

    test('Eject the Warp Core: the sacrifice kicker makes it -6/-6', () {
      final game = makeGame([db.byName('Eject the Warp Core')!.id]);
      giveLands(game, 0, 'Swamp', 2);
      game.createToken(TokenSpec(name: 'Crew', power: 1, toughness: 1), 0);
      final crew = tokenOf(game, 0);
      final enemy = putOnTable(game, 1, 'Lieutenant Commander Data');
      game.state.objects[enemy]!.counters[CounterKind.plusOne] = 3;
      final spell = game.state.players[0].hand.first;
      expect(game.canSacrificeKick(spell, 0), isTrue);
      game.apply(CastAction(spell, targets: [enemy], kicked: true));
      passWindows(game);
      expect(game.state.objects[crew], isNull, reason: 'the token was sacrificed');
      expect(game.state.objects[enemy]!.zone, Zone.graveyard, reason: '5/6 with -6/-6 dies');
    });
    test('Gumato taps for three green mana; leftovers stay in the pool', () {
      final game = makeGame([db.byName('Battle-Scarred Survivalist')!.id]);
      final gumato = putOnTable(game, 0, 'Gumato');
      expect(game.canPay(ManaCost.parse('{G}{G}{G}'), 0), isTrue);
      expect(game.canPay(ManaCost.parse('{G}{G}{G}{G}'), 0), isFalse);
      // A {1}{B} spell can't be paid by green mana alone.
      final spell = game.state.players[0].hand.first;
      expect(game.canCast(spell, 0), isFalse);
      giveLands(game, 0, 'Swamp', 1);
      game.apply(CastAction(spell));
      passWindows(game);
      expect(game.state.objects[gumato]!.tapped, isTrue);
      expect(game.state.players[0].manaPool['G'], 2, reason: 'one green paid the generic, two float');
    });

    test('Shields Up! and Run Amok ask for one target', () {
      for (final name in ['Shields Up!', 'Run Amok', 'Dathon and Picard at El-Adrel']) {
        final card = db.byName(name)!;
        final game = makeGame([]);
        expect(game.targetRequirementsForCard(card, name.startsWith('Dathon') ? 0 : null).length, 1, reason: name);
      }
    });

    test('Pure Energy splits its counters between two creatures', () {
      final game = makeGame([db.byName('Pure Energy')!.id]);
      giveLands(game, 0, 'Plains', 2);
      final a = putOnTable(game, 0, 'Head of Security');
      final b = putOnTable(game, 0, 'Sickbay Orderly');
      game.apply(CastAction(game.state.players[0].hand.first, targets: [a, b]));
      passWindows(game);
      expect(game.state.objects[a]!.counters[CounterKind.plusOne], 1);
      expect(game.state.objects[b]!.counters[CounterKind.plusOne], 1);
    });

    test('Romulan Bird-of-Prey charges itself when a noncreature spell is cast', () {
      final game = makeGame([db.byName('Gin\'tak Charge')!.id]);
      giveLands(game, 0, 'Mountain', 1);
      final ship = putOnTable(game, 0, 'Romulan Bird-of-Prey');
      game.apply(CastAction(game.state.players[0].hand.first, targets: [EffectContext.playerObject(1)]));
      passWindows(game);
      expect(game.state.objects[ship]!.chargeCounters, 2);
    });

    test('Marooned can enchant an artifact', () {
      final game = makeGame([db.byName('Marooned')!.id]);
      giveLands(game, 0, 'Island', 1);
      final relic = putOnTable(game, 1, 'Replicator');
      final aura = game.state.players[0].hand.first;
      expect(game.canCast(aura, 0), isTrue);
      game.apply(CastAction(aura, targets: [relic]));
      passWindows(game);
      if (game.state.pending?.decision is ChooseOptionalDecision) game.apply(const RespondAction(NoResponse()));
      expect(game.state.objects[aura]!.attachedTo, relic);
    });
    test('effects after a player\'s choice still happen (First Contact gains 2 life)', () {
      final game = makeGame([db.byName('First Contact')!.id]);
      giveLands(game, 0, 'Forest', 2);
      // Mill four permanent cards so there is a choice to make.
      for (var i = 0; i < 4; i++) {
        final id = game.newObject(cardID: db.byName('Mugato')!.id, owner: 0, zone: Zone.library);
        game.state.players[0].library.insert(0, id);
      }
      final life = game.state.players[0].life;
      game.apply(CastAction(game.state.players[0].hand.first));
      passWindows(game);
      final pending = game.state.pending;
      expect(pending?.decision, isA<ChooseCardsDecision>());
      final pick = (pending!.decision as ChooseCardsDecision).cards.first;
      game.apply(RespondAction(CardsResponse([pick])));
      expect(game.state.objects[pick]!.zone, Zone.hand);
      expect(game.state.players[0].life, life + 2, reason: 'first spell of the game');
    });
  });
}
