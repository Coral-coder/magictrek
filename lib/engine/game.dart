import 'abilities.dart';
import 'actions.dart';
import 'bot.dart';
import 'cards.dart';
import 'rules.dart';
import 'state.dart';

part 'queries.dart';
part 'effects.dart';
part 'combat.dart';

/// The game: a state plus the rules that move it. Apply actions in order; the same actions on the
/// same seed always give the same state, which is what keeps two phones in lockstep.
class Game {
  Game({required List<String> playerNames, List<bool>? bots, required int seed, required this.db}) : state = GameState(playerNames: playerNames, bots: bots, seed: seed);

  final GameState state;
  final CardDatabase db;

  Rules get rules => state.rules;

  // MARK: - Applying actions

  void apply(GameAction action) {
    if (state.isOver) throw GameError('The game is over');
    switch (action) {
      case StartAction a:
        state.rules = a.rules;
        _start(a.decks);
      case RespondAction a:
        _respond(a.response);
      case ConcedeAction a:
        final who = a.player ?? state.activePlayer;
        _lose(who, '${state.players[who].name} conceded');
      case TimeOutAction a:
        _lose(a.player, '${state.players[a.player].name} ran out of time');
      default:
        if (!state.started) throw GameError("The game hasn't started");
        if (state.pending != null) throw GameError('Waiting for a decision');
        final responding = state.priority != null;
        switch (action) {
          case PassPriorityAction _:
            if (!responding) throw GameError('Nothing to respond to');
            _passPriority();
          case CastAction a:
            _cast(a.id, targets: a.targets, kicked: a.kicked, mode: a.mode, beamUpBounce: a.beamUpBounce, x: a.x);
          case ActivateAbilityAction a:
            _activate(a.id, a.ability, targets: a.targets, sacrifice: a.sacrifice, discard: a.discard);
          case CycleAction a:
            _cycle(a.id);
          default:
            if (responding) throw GameError('Respond or pass first');
            _applyTurnAction(action);
        }
    }
    state.actionCount++;
    _checkStateBasedActions();
  }

  /// The player taking actions right now: whoever holds priority, else the active player.
  PlayerID get actor => state.priority ?? state.activePlayer;

  void _applyTurnAction(GameAction action) {
    switch (action) {
      case PlayLandAction a:
        _playLand(a.id);
      case StationAction a:
        _station(a.spacecraft, a.creature);
      case EquipAction a:
        _equip(a.equipment, a.to);
      case DeclareAttackersAction a:
        _declareAttackers(a.ids);
        _runContinuations();
      case PassPhaseAction _:
        _passPhase();
      case EndTurnAction _:
        _endTurn();
      default:
        break;
    }
  }

  /// Applies an action for a specific player, checking it is theirs to take.
  void applyAs(GameAction action, PlayerID player) {
    switch (action) {
      case StartAction _:
      case TimeOutAction _:
        break;
      case ConcedeAction a:
        // Recorded with the player, so every device that replays it agrees on who gave up.
        apply(ConcedeAction(a.player ?? player));
        return;
      default:
        if (state.playerToAct != player) throw GameError('Not your move');
    }
    apply(action);
  }

  // MARK: - Setup

  void _start(List<List<String>> decks) {
    if (state.started || decks.length != state.players.length) throw GameError('Bad setup');
    for (var p = 0; p < decks.length; p++) {
      for (final cardID in decks[p]) {
        if (db[cardID] == null) throw GameError('Unknown card $cardID');
        final id = newObject(cardID: cardID, owner: p, zone: Zone.library);
        state.players[p].library.add(id);
      }
      state.rng.shuffle(state.players[p].library);
      state.players[p].life = rules.startingLife;
    }
    state.started = true;
    state.startingPlayer = state.rng.nextInt(state.players.length);
    state.activePlayer = state.startingPlayer;
    log(GameEvent('gameStarted', player: state.startingPlayer));
    for (final p in state.players) {
      _draw(p.id, rules.handSize);
    }
    state.turn = 0;
    _askMulligan(state.startingPlayer);
  }

  void _askMulligan(PlayerID p) {
    state.pending = PendingDecision(
      player: p,
      decision: const MulliganDecision(),
      resume: Resume(source: null, controller: p, effects: [], context: EffectContext(), kind: ResumeKind.mulligan),
    );
  }

  void _beginFirstTurn() {
    state.pending = null;
    _beginTurn(state.startingPlayer, first: true);
  }

  ObjectID newObject({required String cardID, required PlayerID owner, required Zone zone, TokenSpec? token}) {
    final id = state.nextObjectID++;
    state.objects[id] = GameObject(id: id, cardID: cardID, owner: owner, zone: zone, token: token);
    return id;
  }

  void log(GameEvent e) => state.log.add(e);

  // MARK: - Zones

  void _removeFromZone(ObjectID id) {
    final o = state.objects[id];
    if (o == null) return;
    final owner = state.players[o.owner];
    switch (o.zone) {
      case Zone.library:
        owner.library.remove(id);
      case Zone.hand:
        owner.hand.remove(id);
      case Zone.graveyard:
        owner.graveyard.remove(id);
      case Zone.exile:
        owner.exile.remove(id);
      case Zone.battlefield:
        state.players[o.controller].battlefield.remove(id);
      case Zone.stack:
        break; // the StackItem is removed by whoever takes it off the stack
    }
  }

  /// Moves an object to a zone of its owner (or controller, for the battlefield) and resets battlefield state.
  void move(ObjectID id, Zone zone, {PlayerID? controller, bool tapped = false, bool toBottom = false}) {
    final o = state.objects[id];
    if (o == null) return;
    final wasOnBattlefield = o.zone == Zone.battlefield;
    final wasInGraveyard = o.zone == Zone.graveyard;
    _removeFromZone(id);
    if (wasOnBattlefield) {
      for (final other in state.allPermanents) {
        if (other.attachedTo == id) {
          other.attachedTo = null;
          if (parsedOf(other)?.isAura == true) move(other.id, Zone.graveyard);
        }
      }
    }
    final returning = wasOnBattlefield ? List.of(o.exiledUntilLeaves) : const <ObjectID>[];
    if (o.isToken && zone != Zone.battlefield && zone != Zone.stack) {
      state.objects.remove(id);
      return;
    }
    o.zone = zone;
    o.tapped = tapped;
    o.damage = 0;
    o.counters = {};
    o.attachedTo = null;
    o.untilEndOfTurn = [];
    o.frozen = false;
    o.sacrificeAtEnd = false;
    o.activatedThisTurn = {};
    o.attacking = null;
    o.blocking = null;
    o.assimilated = false;
    o.exiledWithThis = [];
    o.wasCast = false;
    o.chosenNumber = null;
    o.copiedCardID = null;
    o.nonLegendary = false;
    o.lasting = [];
    o.controlRevertsTo = null;
    o.phasedOut = false;
    o.exileIfDiesThisTurn = false;
    o.chargedThisTurn = false;
    o.basePowerOverride = null;
    o.baseToughnessOverride = null;
    o.playableBy = null;
    o.playableUntilTurn = 0;
    o.extraCost = 0;
    o.qCopyable = false;
    o.usedModes = {};
    o.exiledUntilLeaves = [];
    o.addedTypes = [];
    o.controller = (zone == Zone.battlefield || zone == Zone.stack) ? (controller ?? o.owner) : o.owner;
    if (wasOnBattlefield && zone == Zone.hand) state.players[o.owner].permanentsReturnedToHandThisTurn++;
    if (zone == Zone.battlefield) o.enteredTurn = state.turn;
    final owner = state.players[o.owner];
    switch (zone) {
      case Zone.library:
        if (toBottom) {
          owner.library.add(id);
        } else {
          owner.library.insert(0, id);
        }
      case Zone.hand:
        owner.hand.add(id);
      case Zone.graveyard:
        owner.graveyard.add(id);
      case Zone.exile:
        owner.exile.add(id);
      case Zone.battlefield:
        state.players[o.controller].battlefield.add(id);
      case Zone.stack:
        break;
    }
    for (final r in returning) {
      if (state.objects[r]?.zone != Zone.exile) continue;
      move(r, Zone.battlefield, controller: state.objects[r]!.owner);
      log(GameEvent('returned', object: r));
      enteredBattlefield(r, untapped: true);
    }
    if (wasInGraveyard && zone != Zone.graveyard) {
      for (final other in state.permanentsOf(o.owner)) {
        fireTriggers(SimpleTrigger.cardLeavesYourGraveyard, other.id, touched: id);
      }
    }
  }

  void _draw(PlayerID p, int n) {
    // Mr. Spock: each draw becomes two.
    final perDraw = controlsStatic(p, SimpleStaticKind.drawTwoInstead) ? 2 : 1;
    var drawn = 0;
    for (var i = 0; i < n * perDraw; i++) {
      final lib = state.players[p].library;
      if (lib.isEmpty) {
        _lose(p, '${state.players[p].name} drew from an empty library');
        break;
      }
      move(lib.first, Zone.hand);
      drawn++;
      final ps = state.players[p];
      ps.cardsDrawnThisTurn++;
      for (final o in state.permanentsOf(p)) {
        fireTriggers(SimpleTrigger.youDraw, o.id);
        if (ps.cardsDrawnThisTurn == 2) fireTriggers(SimpleTrigger.secondCardDrawn, o.id);
      }
      for (final o in state.permanentsOf(state.opponentOf(p))) {
        fireTriggers(SimpleTrigger.opponentDraws, o.id, touched: EffectContext.playerObject(p));
      }
    }
    if (drawn > 0) log(GameEvent('drew', player: p, amount: drawn));
  }

  void _lose(PlayerID p, String reason) {
    if (state.winner != null) return;
    state.players[p].lost = true;
    final remaining = state.players.where((x) => !x.lost).toList();
    if (remaining.length == 1) {
      state.winner = remaining[0].id;
      state.pending = null;
      log(GameEvent('gameOver', player: remaining[0].id, text: reason));
    }
  }

  // MARK: - Turn structure

  void _beginTurn(PlayerID p, {bool first = false}) {
    state.turn++;
    state.activePlayer = p;
    state.phase = Phase.untap;
    state.combat = CombatState();
    final ps = state.players[p];
    ps.landsPlayedThisTurn = 0;
    ps.spellsCastThisTurn = 0;
    ps.lifeGainedThisTurn = 0;
    ps.noMaxHandSizeUntilNextTurn = false;
    for (final q in state.players) {
      q.noncreatureSpellsThisTurn = 0;
      q.permanentsReturnedToHandThisTurn = 0;
      q.cardsDrawnThisTurn = 0;
      q.dilemmasThisTurn = 0;
      q.opponentsAttackedThisTurn = 0;
      q.usedGraveyardPlayThisTurn = false;
      q.extraCounterThisTurn = false;
      q.cantAttackThisTurn = false;
    }
    state.firedThisTurn.clear();
    state.resolvedCounts.clear();
    state.delayed.clear();
    log(GameEvent('turnBegan', amount: state.turn, player: p));
    for (final q in state.players) {
      for (final o in state.allOnBattlefieldOf(q.id)) {
        o.chargedThisTurn = false;
        o.lasting.removeWhere((l) => l.untilTurnOf == p);
      }
    }
    // Phasing: your phased-out permanents phase back in, unless something says they can't.
    final cantPhaseIn = state.allPermanents.any((o) => staticsOf(o).any((s) => s is SimpleStatic && s.kind == SimpleStaticKind.permanentsCantPhaseIn));
    if (!cantPhaseIn) {
      for (final o in state.allOnBattlefieldOf(p)) {
        if (o.phasedOut) {
          o.phasedOut = false;
          log(GameEvent('phasedIn', object: o.id));
        }
      }
    }
    for (final o in state.permanentsOf(p)) {
      o.activatedThisTurn = {};
      final held = state.allPermanents.any((a) => a.attachedTo == o.id && staticsOf(a).any((s) => s is SimpleStatic && s.kind == SimpleStaticKind.attachedDoesntUntap));
      if (o.tapped && held) continue;
      if (o.tapped) {
        if (o.frozen) {
          o.frozen = false;
        } else if ((o.counters[CounterKind.stun] ?? 0) > 0) {
          o.counters[CounterKind.stun] = o.counters[CounterKind.stun]! - 1;
          if (o.counters[CounterKind.stun] == 0) o.counters.remove(CounterKind.stun);
          log(GameEvent('counters', object: o.id, counter: CounterKind.stun, amount: -1));
        } else {
          o.tapped = false;
          log(GameEvent('untapped', object: o.id));
        }
      }
    }
    state.phase = Phase.upkeep;
    log(GameEvent('phase', phase: Phase.upkeep));
    for (final o in state.permanentsOf(p)) {
      fireTriggers(SimpleTrigger.upkeep, o.id);
    }
    for (final o in state.allPermanents) {
      fireTriggers(SimpleTrigger.eachUpkeep, o.id);
    }
    if (state.pending != null) {
      state.turnContinuation.add(TurnStep.drawStep);
      return;
    }
    _drawStep(first);
  }

  void _drawStep(bool first) {
    state.phase = Phase.draw;
    log(GameEvent('phase', phase: Phase.draw));
    if (!(first && state.players.length == 2 && !rules.firstPlayerDraws)) _draw(state.activePlayer, 1);
    for (final o in state.permanentsOf(state.activePlayer)) {
      if (cardOf(o)?.isSaga == true) _advanceSaga(o.id);
    }
    if (state.pending != null) {
      state.turnContinuation.add(TurnStep.main1);
      return;
    }
    _beginMain1();
  }

  void _beginMain1() {
    state.phase = Phase.main1;
    log(GameEvent('phase', phase: Phase.main1));
    for (final o in state.permanentsOf(state.activePlayer)) {
      fireTriggers(SimpleTrigger.firstMain, o.id);
    }
  }

  void _runContinuations() {
    while (state.pending == null && state.priority == null && !state.isOver) {
      if (state.queuedTriggers.isNotEmpty) {
        final q = state.queuedTriggers.removeAt(0);
        resolve(q.effects, source: q.source, controller: q.controller, context: q.context);
        continue;
      }
      if (state.stack.isNotEmpty) {
        _resolveStack();
        continue;
      }
      if (state.turnContinuation.isEmpty) break;
      final step = state.turnContinuation.removeAt(0);
      switch (step) {
        case TurnStep.attackWindow:
          _offerPriority(state.combat.defender);
        case TurnStep.blockWindowActive:
          if (state.combat.attackers.isNotEmpty) _offerPriority(state.activePlayer);
        case TurnStep.blockWindowDefender:
          if (state.combat.attackers.isNotEmpty) _offerPriority(state.combat.defender);
        case TurnStep.endWindow:
          _offerPriority(state.opponentOf(state.activePlayer));
        case TurnStep.drawStep:
          _drawStep(state.turn == 1);
        case TurnStep.main1:
          _beginMain1();
        case TurnStep.blockers:
          _askBlockers();
        case TurnStep.combatDamage:
          _combatDamage();
        case TurnStep.main2:
          state.phase = Phase.main2;
          log(GameEvent('phase', phase: Phase.main2));
        case TurnStep.endStep:
          _endStep();
        case TurnStep.cleanup:
          _cleanup();
        case TurnStep.nextTurn:
          _beginTurn(state.opponentOf(state.activePlayer));
      }
    }
  }

  void _passPhase() {
    switch (state.phase) {
      case Phase.main1:
        state.phase = Phase.beginCombat;
        log(GameEvent('phase', phase: Phase.beginCombat));
        _beginCombatTriggers();
        state.phase = Phase.declareAttackers;
        log(GameEvent('phase', phase: Phase.declareAttackers));
      case Phase.beginCombat:
        state.phase = Phase.declareAttackers;
      case Phase.declareAttackers:
        _declareAttackers([]);
      case Phase.main2:
        _endTurn();
        return;
      default:
        throw GameError('Nothing to pass in ${state.phase.label}');
    }
    _runContinuations();
  }

  void _endTurn() {
    if (!(state.phase.isMain || state.phase == Phase.declareAttackers || state.phase == Phase.endCombat)) throw GameError("Can't end the turn now");
    if (state.phase == Phase.main1 || state.phase == Phase.declareAttackers) state.phase = Phase.main2;
    state.turnContinuation.add(TurnStep.endStep);
    _runContinuations();
  }

  void _endStep() {
    _emptyManaPools();
    state.phase = Phase.end;
    log(GameEvent('phase', phase: Phase.end));
    final p = state.activePlayer;
    for (final o in state.permanentsOf(p)) {
      fireTriggers(SimpleTrigger.endStep, o.id);
    }
    for (final o in state.allPermanents) {
      fireTriggers(SimpleTrigger.eachEndStep, o.id, touched: EffectContext.playerObject(p));
    }
    for (final o in state.allPermanents) {
      if (o.sacrificeAtEnd) dies(o.id);
    }
    state.turnContinuation.add(TurnStep.endWindow);
    state.turnContinuation.add(TurnStep.cleanup);
  }

  void _cleanup() {
    _emptyManaPools();
    state.phase = Phase.cleanup;
    final p = state.activePlayer;
    final ps = state.players[p];
    final noMax = ps.noMaxHandSizeUntilNextTurn || controlsStatic(p, SimpleStaticKind.noMaxHandSize);
    if (!noMax && rules.maxHandSize && ps.hand.length > rules.handSize) {
      state.pending = PendingDecision(
        player: p,
        decision: DiscardToHandSizeDecision(ps.hand.length - rules.handSize),
        resume: Resume(source: null, controller: p, effects: [], context: EffectContext(), kind: ResumeKind.cleanup),
      );
      state.turnContinuation.add(TurnStep.nextTurn);
      return;
    }
    _finishCleanup();
    state.turnContinuation.add(TurnStep.nextTurn);
  }

  void _finishCleanup() {
    for (final o in state.allPermanents) {
      o.damage = 0;
      o.untilEndOfTurn = [];
      o.attacking = null;
      o.blocking = null;
      o.exileIfDiesThisTurn = false;
      final back = o.controlRevertsTo;
      if (back != null) {
        o.controlRevertsTo = null;
        if (o.controller != back) changeControl(o.id, back);
      }
    }
    _checkStateBasedActions();
  }

  /// Moves a permanent to another player's side of the battlefield.
  void changeControl(ObjectID id, PlayerID to) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield) return;
    state.players[o.controller].battlefield.remove(id);
    o.controller = to;
    state.players[to].battlefield.add(id);
    o.enteredTurn = state.turn;
    o.attacking = null;
    o.blocking = null;
    log(GameEvent('controlChanged', object: id, player: to));
  }

  /// "At the beginning of combat": the active player's triggers, each player's-turn triggers,
  /// and delayed "next combat" triggers.
  /// Unspent mana goes away as each step ends.
  void _emptyManaPools() {
    for (final p in state.players) {
      p.manaPool.clear();
    }
  }

  void _beginCombatTriggers() {
    _emptyManaPools();
    for (final o in state.permanentsOf(state.activePlayer)) {
      fireTriggers(SimpleTrigger.beginCombat, o.id);
    }
    for (final o in state.allPermanents) {
      fireTriggers(SimpleTrigger.eachBeginCombat, o.id, touched: EffectContext.playerObject(state.activePlayer));
    }
    final due = state.delayed.where((d) => d.event == DelayedEvent.nextCombat && d.turn == state.turn).toList();
    state.delayed.removeWhere(due.contains);
    for (final d in due) {
      if (state.objects[d.source] == null) continue;
      final ctx = EffectContext()
        ..lastTouched = d.object
        ..triggeringObject = d.object;
      log(GameEvent('triggered', object: d.source, text: name(d.source)));
      resolve(d.effects, source: d.source, controller: d.controller, context: ctx);
    }
  }

  // MARK: - Playing cards

  void _playLand(ObjectID id) {
    final p = state.activePlayer;
    if (!canPlayLand(id, p)) throw GameError("Can't play that land now");
    state.players[p].landsPlayedThisTurn++;
    var tapped = false;
    final parsed = parsedOf(state.objects[id]!);
    if (parsed != null) {
      for (final s in parsed.statics) {
        if (s == SimpleStatic.entersTapped) {
          tapped = true;
        } else if (s is EntersTappedUnless) {
          tapped = state.permanentsOf(p).where((o) => characteristics(o.id).isLand).length < s.landsAtLeast;
        } else if (s == SimpleStatic.shockLand) {
          if (state.players[p].life > 4) {
            changeLife(p, -2);
          } else {
            tapped = true;
          }
        }
      }
    }
    final landFrom = state.objects[id]!.zone;
    if (landFrom == Zone.graveyard) state.players[p].usedGraveyardPlayThisTurn = true;
    move(id, Zone.battlefield, controller: p, tapped: tapped);
    log(GameEvent('playedLand', player: p, object: id));
    if (landFrom == Zone.exile) {
      for (final other in state.permanentsOf(p)) {
        fireTriggers(SimpleTrigger.playFromExile, other.id, touched: id);
      }
    }
    enteredBattlefield(id, untapped: !tapped);
    for (final o in state.permanentsOf(p)) {
      if (o.id != id) fireTriggers(SimpleTrigger.landfall, o.id, touched: id);
    }
    _runContinuations();
  }

  void _cast(ObjectID id, {required List<ObjectID> targets, required bool kicked, int? mode, ObjectID? beamUpBounce, int x = 0}) {
    final p = actor;
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null) throw GameError('No such card');
    final parsed = db.parsed(card);
    var cost = card.cost;
    var fromGraveyard = false;
    if (o.zone == Zone.exile && o.qCopyable && o.owner == p) {
      // Q: exile a card from your hand to create a copy of this card, and cast the copy.
      final hand = state.players[p].hand;
      if (hand.isEmpty || state.activePlayer != p) throw GameError("Can't copy that now");
      final payment = Bot.discardChoice(this, p, 1).first;
      move(payment, Zone.exile);
      log(GameEvent('exiled', object: payment));
      final copy = newObject(
        cardID: o.cardID,
        owner: p,
        zone: Zone.hand,
        token: TokenSpec(
          name: card.name,
          power: card.basePower,
          toughness: card.baseToughness,
          isArtifact: card.isArtifact,
          isCreature: card.isCreature,
          isLand: card.isLand,
          isLegendary: card.isLegendary,
        ),
      );
      hand.add(copy);
      log(GameEvent('copied', object: id, other: copy, player: p));
      _cast(copy, targets: targets, kicked: kicked, mode: mode, x: x);
      return;
    }
    final fromZone = o.zone;
    if (o.zone == Zone.graveyard && beamUpBounce != null) {
      final beam = parsed.beamMeUp;
      final b = state.objects[beamUpBounce];
      if (beam == null || o.owner != p || b == null || b.zone != Zone.battlefield || b.controller != p || !characteristics(beamUpBounce).isCreature) throw GameError("Can't beam that up");
      if (state.allPermanents.any((a) => a.attachedTo == beamUpBounce && staticsOf(a).contains(const SimpleStatic(SimpleStaticKind.attachedCantBeBeamedUp)))) {
        throw GameError("${name(beamUpBounce)} can't be beamed up");
      }
      if (!_timingAllows(card, p)) throw GameError("Can't cast that now");
      cost = beam.copy();
      fromGraveyard = true;
    } else {
      if (!canCast(id, p)) throw GameError("Can't cast that now");
    }
    if (x < 0) throw GameError('X must be 0 or more');
    if (!card.cost.hasX) x = 0;
    cost.generic += x + o.extraCost;
    ObjectID? kickerSacrifice;
    if (kicked) {
      final k = parsed.kicker;
      final sk = parsed.abilities.whereType<SacrificeKicker>().firstOrNull;
      if (k != null) {
        cost.add(k);
      } else if (sk != null) {
        final f = sk.filter.copy()..controller = Controller.you;
        final options = state.permanentsOf(p).where((c) => matches(f, c.id, p, id)).map((c) => c.id).toList();
        if (options.isEmpty) throw GameError('Nothing to sacrifice for kicker');
        kickerSacrifice = Bot.sacrificeChoice(this, options);
      } else {
        throw GameError('No kicker');
      }
    }
    final reqs = targetRequirementsForCard(card, mode, kicked: kicked);
    _validateTargets(targets, reqs, p, id);
    for (final t in targets) {
      if (EffectContext.playerFromObject(t) == null) {
        final tgt = state.objects[t];
        if (tgt != null && tgt.zone == Zone.battlefield && tgt.controller != p) cost.generic += characteristics(t).wardCost;
      }
    }
    reduceCost(cost, card, p, targets);
    final plan = manaPlan(cost, p, forSpell: card);
    if (plan == null) throw GameError('Not enough mana');
    final sunburst = parsed.abilities.any((a) => a is Sunburst) ? sunburstColors(plan) : 0;
    _payMana(plan);
    if (kickerSacrifice != null) dies(kickerSacrifice, event: 'sacrificed');
    if (fromZone == Zone.graveyard && beamUpBounce == null) state.players[p].usedGraveyardPlayThisTurn = true;
    if (fromGraveyard && beamUpBounce != null) {
      move(beamUpBounce, Zone.hand);
      log(GameEvent('bounced', object: beamUpBounce));
    }
    state.players[p].spellsCastThisTurn++;
    state.players[p].spellsCastThisGame++;
    if (!card.isCreature) state.players[p].noncreatureSpellsThisTurn++;
    move(id, Zone.stack, controller: p);
    final context = EffectContext()
      ..targets = List.of(targets)
      ..kicked = kicked
      ..x = x;
    var effects = <Effect>[];
    if (!card.isPermanent) {
      effects = List.of(parsed.spellEffects);
      final mi = effects.indexWhere((e) => e is Modal);
      if (mode != null && mi >= 0) {
        final modes = (effects[mi] as Modal).modes;
        if (mode < modes.length) effects = [...effects.sublist(0, mi), ...modes[mode], ...effects.sublist(mi + 1)];
      }
    }
    state.stack.add(StackItem(id: id, controller: p, effects: effects, context: context, fromGraveyard: fromGraveyard, x: x, sunburst: sunburst));
    log(GameEvent('cast', player: p, object: id, amount: kicked ? 1 : 0));
    // "When you cast this spell" (Starfleet Communicator).
    for (final (i, a) in parsed.abilities.indexed) {
      if (a is Triggered && a.event == SimpleTrigger.castThis) fireTrigger(a, '$id:$i', source: id, touched: id, leftBattlefield: true);
    }
    _castTriggers(card, id, p, x);
    if (fromZone == Zone.exile) {
      for (final other in state.permanentsOf(p)) {
        fireTriggers(SimpleTrigger.playFromExile, other.id, touched: id);
      }
    }
    _runContinuations();
  }

  /// "Whenever you cast / a player casts / an opponent casts a ... spell".
  void _castTriggers(Card card, ObjectID id, PlayerID caster, int x) {
    for (final other in state.allPermanents) {
      for (final (t, key) in triggersOf(other.id)) {
        final event = t.event;
        if (event is! CastSpellTrigger) continue;
        final mine = other.controller == caster;
        if (event.who == Controller.you && !mine) continue;
        if (event.who == Controller.opponent && mine) continue;
        if (event.manaValueIsChosenNumber && other.chosenNumber != card.manaValue + x) continue;
        final ok = switch (event.kind) {
          SpellKind.any => true,
          SpellKind.creature => card.isCreature,
          SpellKind.noncreature => !card.isCreature,
          SpellKind.artifact => card.isArtifact,
          SpellKind.instantOrSorcery => card.isInstant || card.isSorcery,
          SpellKind.creatureOrSpacecraft => card.isCreature || card.isSpacecraft,
        };
        if (ok) fireTrigger(t, key, source: other.id, touched: id);
      }
    }
  }

  /// Cost reductions: affinity, "costs {1} less if it targets an attacking creature".
  void reduceCost(ManaCost cost, Card card, PlayerID p, List<ObjectID> targets) {
    var less = 0;
    for (final a in db.parsed(card).abilities) {
      if (a is Affinity) less += state.permanentsOf(p).where((o) => matches(a.filter, o.id, p, null)).length;
      if (a is CostReductionIfTargetsAttacker && targets.any((t) => state.objects[t]?.attacking != null)) less += a.amount;
    }
    cost.generic = (cost.generic - less).clamp(0, 1 << 30);
  }

  /// The most distinct colors the sources in a mana plan could have produced (sunburst).
  int sunburstColors(List<ObjectID> plan) {
    final options = <List<ManaColor>>[];
    // A source that made several mana made them all one color: it counts once.
    for (final id in plan.toSet()) {
      final o = state.objects[id];
      if (o == null) continue;
      final p = parsedOf(o);
      final colors = <ManaColor>{...?p?.manaColors};
      for (final a in p?.abilities ?? const <Ability>[]) {
        if (a is Activated && a.effects.length == 1 && a.effects[0] is AddMana) colors.addAll((a.effects[0] as AddMana).colors);
      }
      options.add(colors.toList());
    }
    var best = 0;
    void search(int i, Set<ManaColor> used) {
      if (used.length > best) best = used.length;
      if (i >= options.length || best == 5) return;
      for (final c in options[i]) {
        if (used.contains(c)) continue;
        search(i + 1, {...used, c});
      }
      search(i + 1, used);
    }

    search(0, {});
    return best;
  }

  /// Whether the card's type lets `p` cast it at this moment (ignoring cost and zone).
  bool _timingAllows(Card card, PlayerID p) {
    final instantSpeed = card.isInstant || db.parsed(card).has(KeywordKind.flash);
    if (state.priority != null) return state.priority == p && instantSpeed;
    if (state.activePlayer != p) return false;
    if (instantSpeed) return state.phase.isMain || const {Phase.beginCombat, Phase.declareAttackers, Phase.declareBlockers, Phase.combatDamage, Phase.endCombat, Phase.end}.contains(state.phase);
    return state.phase.isMain && state.stack.isEmpty;
  }

  /// Resolves spells from the top of the stack, first giving the other player a chance to respond
  /// to each one. Stops when someone must decide or respond.
  void _resolveStack() {
    while (state.stack.isNotEmpty && state.pending == null && state.priority == null && !state.isOver) {
      final top = state.stack.last;
      if (!top.windowOffered) {
        top.windowOffered = true;
        final other = state.opponentOf(top.controller);
        if (hasResponses(other)) {
          state.priority = other;
          log(GameEvent('priority', player: other, object: top.id));
          return;
        }
      }
      state.stack.removeLast();
      _resolveSpell(top);
      _checkStateBasedActions();
    }
  }

  void _resolveSpell(StackItem item) {
    final o = state.objects[item.id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null || o.zone != Zone.stack) return;
    final parsed = db.parsed(card);
    log(GameEvent('resolved', player: item.controller, object: item.id));
    if (card.isPermanent) {
      move(item.id, Zone.battlefield, controller: item.controller);
      if (parsed.isAura) {
        final host = item.context.targets.firstOrNull;
        if (host == null || state.objects[host]?.zone != Zone.battlefield || !auraFits(state.objects[item.id]!, host)) {
          move(item.id, Zone.graveyard);
          log(GameEvent('fizzled', object: item.id));
          return;
        }
        state.objects[item.id]!.attachedTo = host;
      }
      enteredBattlefield(item.id, untapped: true, castBy: item.controller, x: item.x, sunburst: item.sunburst);
    } else {
      resolve(item.effects, source: item.id, controller: item.controller, context: item.context);
      if (state.objects[item.id]?.zone == Zone.stack) move(item.id, item.fromGraveyard ? Zone.exile : Zone.graveyard);
    }
  }

  /// Takes a spell off the stack without resolving it.
  bool counterSpell(ObjectID id) {
    final i = state.stack.indexWhere((s) => s.id == id);
    if (i < 0) return false;
    final spell = card(id);
    if (spell != null && db.parsed(spell).statics.contains(SimpleStatic.cantBeCountered)) {
      log(GameEvent('note', text: "${name(id)} can't be countered"));
      return false;
    }
    final item = state.stack.removeAt(i);
    move(id, item.fromGraveyard ? Zone.exile : Zone.graveyard);
    log(GameEvent('countered', object: id, player: item.controller));
    return true;
  }

  void _passPriority() {
    final p = state.priority;
    state.priority = null;
    log(GameEvent('passed', player: p));
    _runContinuations();
  }

  /// Gives `p` a window to respond if they have anything to respond with.
  void _offerPriority(PlayerID p) {
    if (hasResponses(p)) {
      state.priority = p;
      log(GameEvent('priority', player: p));
    }
  }

  void _validateTargets(List<ObjectID> targets, List<TargetRequirement> reqs, PlayerID controller, ObjectID source) {
    var i = 0;
    for (final r in reqs) {
      final legal = legalTargets(r.filter, controller, source);
      var taken = 0;
      while (taken < r.count && i < targets.length && legal.contains(targets[i])) {
        taken++;
        i++;
      }
      if (taken == 0 && !r.optional && legal.isNotEmpty) throw GameError('Choose a target');
    }
  }

  void _payMana(List<ObjectID> plan) {
    // Pool mana first: work out which symbol each pseudo source stood for before spending any.
    final spend = <(PlayerID, String)>[];
    for (final id in plan) {
      if (id > -1000) continue;
      final p = (-1000 - id) ~/ 100;
      var i = (-1000 - id) % 100;
      final pool = state.players[p].manaPool;
      for (final k in (pool.keys.toList()..sort())) {
        if (i < pool[k]!) {
          spend.add((p, k));
          break;
        }
        i -= pool[k]!;
      }
    }
    for (final (p, k) in spend) {
      final pool = state.players[p].manaPool;
      pool[k] = (pool[k] ?? 1) - 1;
      if (pool[k]! <= 0) pool.remove(k);
    }
    final uses = <ObjectID, int>{};
    for (final id in plan) {
      if (id > -1000) uses[id] = (uses[id] ?? 0) + 1;
    }
    for (final id in uses.keys) {
      final o = state.objects[id];
      if (o == null) continue;
      final parsed = parsedOf(o);
      if (parsed != null && parsed.abilities.any((a) => a is Activated && a.cost.sacrificeSelf && a.cost.tap && a.effects.length == 1 && a.effects[0] is AddMana)) {
        dies(id, event: 'sacrificed'); // Treasure
      } else {
        o.tapped = true;
        log(GameEvent('tapped', object: id));
        fireTriggers(SimpleTrigger.becomesTapped, id);
        // A source that made more mana than the cost needed leaves the rest in the pool.
        final best = parsed?.abilities.whereType<ManaAbility>().fold<ManaAbility?>(null, (a, b) => a == null || b.amount > a.amount ? b : a);
        final extra = (best?.amount ?? 1) - uses[id]!;
        if (best != null && extra > 0) {
          final key = best.colors.isEmpty ? 'C' : best.colors.first.symbol;
          final pool = state.players[o.controller].manaPool;
          pool[key] = (pool[key] ?? 0) + extra;
        }
      }
    }
  }

  /// `castBy` is set when the permanent arrived by being cast (for "if you cast it"); `x` is the
  /// value of X it was cast with; `sunburst` the colors of mana spent on it.
  void enteredBattlefield(ObjectID id, {required bool untapped, PlayerID? castBy, int x = 0, int sunburst = 0}) {
    final o = state.objects[id];
    if (o == null) return;
    if (castBy != null) o.wasCast = true;
    log(GameEvent('entered', object: id));
    final parsed = parsedOf(o);
    final before = <Effect>[];
    if (parsed != null) {
      if (parsed.abilities.any((a) => a is Sunburst) && sunburst > 0) addCounters(CounterKind.charge, sunburst, id);
      for (final a in parsed.abilities) {
        if (a is EnterAsCopy) {
          final f = a.filter.copy()..other = true;
          if (legalTargets(f, o.controller, id).isNotEmpty) before.add(Optional([BecomeCopy(ChosenTarget(f), nonLegendary: a.nonLegendary, copyCounters: a.copyCounters)]));
        }
        if (a is ChooseNumberOnEnter) before.add(ChooseNumber(a.min, a.max));
      }
    }
    if (before.isNotEmpty) {
      // Choices made "as it enters" come before its enters triggers.
      resolve([...before, EnterTriggers(untapped)], source: id, controller: o.controller, context: EffectContext()..lastTouched = id);
      return;
    }
    enterTriggers(id, untapped: untapped);
  }

  /// The triggers of a permanent entering: its own, Sagas' first chapter, and other permanents'
  /// "whenever a ... enters".
  void enterTriggers(ObjectID id, {required bool untapped}) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield) return;
    if (cardOf(o)?.isSaga == true) _advanceSaga(id);
    fireTriggers(SimpleTrigger.enters, id);
    if (untapped) fireTriggers(SimpleTrigger.entersUntapped, id);
    final c = characteristics(id);
    for (final other in state.allPermanents) {
      if (other.id == id) continue;
      for (final (t, key) in triggersOf(other.id)) {
        final event = t.event;
        if (event is PermanentEntersTrigger && matches(event.filter, id, other.controller, other.id, base: c)) {
          fireTrigger(t, key, source: other.id, touched: id);
        }
      }
    }
  }

  void _activate(ObjectID id, int index, {required List<ObjectID> targets, ObjectID? sacrifice, ObjectID? discard}) {
    final p = actor;
    final problem = activationProblem(id, index, p);
    if (problem != null) throw GameError(problem);
    final o = state.objects[id]!;
    final ability = abilitiesIn(o)[index] as Activated;
    final cost = ability.cost;
    ObjectID? sacID;
    final f = cost.sacrifice;
    if (f != null) {
      if (sacrifice == null || !matches(f, sacrifice, p, id) || state.objects[sacrifice]?.controller != p) throw GameError('Choose something to sacrifice');
      sacID = sacrifice;
    }
    if (cost.discard > 0) {
      final d = discard == null ? null : state.objects[discard];
      if (d == null || d.zone != Zone.hand || d.owner != p || discard == id) throw GameError('Choose a card to discard');
    }
    _validateTargets(targets, targetRequirementsIn(ability.effects), p, id);
    final mana = cost.mana.copy();
    for (final t in targets) {
      if (EffectContext.playerFromObject(t) == null) {
        final tgt = state.objects[t];
        if (tgt != null && tgt.controller != p) mana.generic += characteristics(t).wardCost;
      }
    }
    final plan = manaPlan(mana, p);
    if (plan == null) throw GameError('Not enough mana');
    _payMana(plan);
    if (cost.tap) {
      o.tapped = true;
      log(GameEvent('tapped', object: id));
      fireTriggers(SimpleTrigger.becomesTapped, id);
    }
    for (final t in tapOthersChoice(cost, p, id)!) {
      state.objects[t]!.tapped = true;
      log(GameEvent('tapped', object: t));
      fireTriggers(SimpleTrigger.becomesTapped, t);
    }
    for (final (holder, kind) in removeCountersChoice(cost, p)!) {
      final h = state.objects[holder]!;
      h.counters[kind] = (h.counters[kind] ?? 1) - 1;
      if (h.counters[kind]! <= 0) h.counters.remove(kind);
    }
    if (cost.removeCounters > 0) log(GameEvent('countersRemoved', player: p, amount: cost.removeCounters));
    if (cost.payLife > 0) changeLife(p, -cost.payLife);
    if (discard != null && cost.discard > 0) {
      move(discard, Zone.graveyard);
      log(GameEvent('discarded', player: p, object: discard));
    }
    final context = EffectContext()..targets = List.of(targets);
    if (sacID != null) {
      context.sacrificedSubtypes = Set.of(characteristics(sacID).subtypes);
      dies(sacID);
    }
    if (cost.sacrificeSelf) {
      context.eventAmount = o.chargeCounters;
      dies(id);
    }
    switch (cost.zone) {
      case AbilityZone.battlefield:
        break;
      case AbilityZone.hand:
        move(id, Zone.graveyard);
        log(GameEvent('discarded', player: p, object: id));
      case AbilityZone.graveyard:
        if (cost.exileSelf) {
          move(id, Zone.exile);
          log(GameEvent('exiled', object: id));
        } else if (cost.bottomSelf) {
          move(id, Zone.library, toBottom: true);
        }
    }
    o.activatedThisTurn.add(index);
    log(GameEvent('activated', object: id, text: name(id)));
    resolve(ability.effects, source: id, controller: p, context: context);
    _runContinuations();
  }

  void _station(ObjectID spacecraft, ObjectID creature) {
    final p = state.activePlayer;
    final s = state.objects[spacecraft];
    final c = state.objects[creature];
    if (!state.phase.isMain ||
        s == null ||
        s.controller != p ||
        c == null ||
        c.controller != p ||
        c.tapped ||
        spacecraft == creature ||
        !characteristics(spacecraft).isSpacecraft ||
        parsedOf(s)?.has(KeywordKind.station) != true) {
      throw GameError("Can't station that");
    }
    final cc = characteristics(creature);
    if (!cc.isCreature || hasSummoningSickness(c)) throw GameError("That creature can't station yet");
    final wasCreature = characteristics(spacecraft).isCreature;
    c.tapped = true;
    log(GameEvent('tapped', object: creature));
    fireTriggers(SimpleTrigger.becomesTapped, creature);
    addCounters(CounterKind.charge, cc.power < 0 ? 0 : cc.power, spacecraft);
    log(GameEvent('stationed', object: spacecraft, other: creature, amount: cc.power));
    for (final o in state.permanentsOf(p)) {
      fireTriggers(SimpleTrigger.stationed, o.id, touched: spacecraft);
    }
    if (!wasCreature && characteristics(spacecraft).isCreature) log(GameEvent('becameCreature', object: spacecraft));
    _runContinuations();
  }

  void _equip(ObjectID equipment, ObjectID creature) {
    final p = state.activePlayer;
    final e = state.objects[equipment];
    final parsed = e == null ? null : parsedOf(e);
    final cost = parsed?.equipCost;
    final c = state.objects[creature];
    if (!state.phase.isMain || e == null || e.controller != p || cost == null || c == null || c.controller != p || !characteristics(creature).isCreature) throw GameError("Can't equip that");
    final plan = manaPlan(cost, p);
    if (plan == null) throw GameError('Not enough mana');
    _payMana(plan);
    e.attachedTo = creature;
    log(GameEvent('equipped', object: equipment, other: creature));
  }

  void _cycle(ObjectID id) {
    final p = actor;
    final o = state.objects[id];
    final parsed = o == null ? null : parsedOf(o);
    final cyc = parsed?.cycling;
    if (o == null || o.zone != Zone.hand || o.owner != p || cyc == null) throw GameError("Can't cycle that");
    final plan = manaPlan(cyc.cost, p);
    if (plan == null) throw GameError('Not enough mana');
    _payMana(plan);
    move(id, Zone.graveyard);
    log(GameEvent('discarded', player: p, object: id));
    final landType = cyc.landType;
    if (landType != null) {
      final lib = state.players[p].library;
      ObjectID? found;
      for (final l in lib) {
        final c = card(l);
        if (c == null) continue;
        if (landType == 'basic' ? c.isBasicLand : c.subtypes.contains(landType)) {
          found = l;
          break;
        }
      }
      if (found != null) {
        move(found, Zone.hand);
        log(GameEvent('searched', player: p, object: found));
      }
      state.rng.shuffle(state.players[p].library);
    } else {
      _draw(p, 1);
    }
    _runContinuations();
  }

  // MARK: - Life, damage, counters

  void changeLife(PlayerID p, int delta) {
    if (delta == 0) return;
    state.players[p].life += delta;
    log(GameEvent('lifeChanged', player: p, amount: delta));
    if (delta > 0) {
      state.players[p].lifeGainedThisTurn += delta;
      final times = controlsStatic(p, SimpleStaticKind.lifeGainTriggersTwice) ? 2 : 1;
      for (var i = 0; i < times; i++) {
        for (final o in state.permanentsOf(p)) {
          fireTriggers(SimpleTrigger.gainLife, o.id, amount: delta);
        }
      }
    }
  }

  /// Damage to a creature or player object. Returns the damage actually dealt.
  int dealDamage(int amount, ObjectID target, ObjectID? source) {
    if (amount <= 0) return 0;
    final p = EffectContext.playerFromObject(target);
    if (p != null) {
      changeLife(p, -amount);
      log(GameEvent('damage', object: target, amount: amount, other: source));
      if (source != null && characteristics(source).has(KeywordKind.lifelink)) changeLife(state.objects[source]?.controller ?? p, amount);
      return amount;
    }
    final o = state.objects[target];
    if (o == null || o.zone != Zone.battlefield || !characteristics(target).isCreature) return 0;
    o.damage += amount;
    if (source != null && characteristics(source).has(KeywordKind.deathtouch)) o.damage += 1000;
    log(GameEvent('damage', object: target, amount: amount, other: source));
    if (source != null && characteristics(source).has(KeywordKind.lifelink)) changeLife(state.objects[source]?.controller ?? o.controller, amount);
    return amount;
  }

  void addCounters(CounterKind kind, int n, ObjectID id) {
    final o = state.objects[id];
    if (n <= 0 || o == null || o.zone != Zone.battlefield) {
      if (n < 0 && o != null) {
        o.counters[kind] = ((o.counters[kind] ?? 0) + n).clamp(0, 1 << 30);
        if (o.counters[kind] == 0) o.counters.remove(kind);
      }
      return;
    }
    final p = o.controller;
    var count = n;
    // Brad Boimler: one more of each kind until end of turn.
    if (state.players[p].extraCounterThisTurn) count += 1;
    final c = characteristics(id);
    if (c.isCreature && controlsStatic(p, SimpleStaticKind.doubleCountersOnCreatures)) count *= 2;
    if (kind == CounterKind.charge && c.isArtifact && controlsStatic(p, SimpleStaticKind.doubleChargeCounters)) count *= 2;
    o.counters[kind] = (o.counters[kind] ?? 0) + count;
    log(GameEvent('counters', object: id, counter: kind, amount: count));
    if (kind == CounterKind.charge && !o.chargedThisTurn) {
      o.chargedThisTurn = true;
      fireTriggers(SimpleTrigger.chargedFirstTime, id);
    }
  }

  void destroy(ObjectID id) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield) return;
    if (characteristics(id).has(KeywordKind.indestructible)) return;
    dies(id, event: 'destroyed');
  }

  /// A permanent goes from the battlefield to its owner's graveyard (destroyed, sacrificed,
  /// lethal damage...), with its "dies" triggers and other permanents' "whenever ... dies".
  /// Returns false if something exiled it instead.
  bool dies(ObjectID id, {String event = 'died'}) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield) return false;
    if (o.exileIfDiesThisTurn || (o.counters[CounterKind.finality] ?? 0) > 0) {
      move(id, Zone.exile);
      log(GameEvent('exiled', object: id));
      return false;
    }
    final c = characteristics(id);
    final info = DeathInfo(
      id: id,
      controller: o.controller,
      owner: o.owner,
      isCreature: c.isCreature,
      isArtifact: c.isArtifact,
      isToken: o.isToken,
      subtypes: Set.of(c.subtypes),
      triggers: triggersOf(id),
      wasCreatureWithCounters: o.counters.isNotEmpty,
    );
    move(id, Zone.graveyard);
    log(GameEvent(event == 'sacrificed' ? 'died' : event, object: id));
    fireDies(id, info: info);
    return true;
  }

  void fireDies(ObjectID id, {DeathInfo? info}) {
    final o = state.objects[id];
    final d =
        info ??
        (o == null
            ? null
            : DeathInfo(
                id: id,
                controller: o.controller,
                owner: o.owner,
                isCreature: cardOf(o)?.isCreature ?? false,
                isArtifact: cardOf(o)?.isArtifact ?? false,
                isToken: o.isToken,
                subtypes: {...?cardOf(o)?.subtypes},
                triggers: const [],
                wasCreatureWithCounters: false,
              ));
    if (d == null) return;
    final own = d.triggers.isNotEmpty
        ? d.triggers
        : (o == null
              ? const <(Triggered, String)>[]
              : [
                  for (final (i, a) in (parsedOf(o)?.abilities ?? const <Ability>[]).indexed)
                    if (a is Triggered) (a, '$id:$i'),
                ]);
    for (final (t, key) in own) {
      if (t.event == SimpleTrigger.dies || t.event == SimpleTrigger.leaves) {
        if (state.objects[id] != null) fireTrigger(t, key, source: id, touched: id, leftBattlefield: true);
      }
    }
    for (final other in state.allPermanents) {
      for (final (t, key) in triggersOf(other.id)) {
        final event = t.event;
        if (event is PermanentDiesTrigger && _matchesDead(event.filter, d, other.controller, other.id)) fireTrigger(t, key, source: other.id, touched: id);
      }
    }
    final due = state.delayed.where((x) => x.event == DelayedEvent.dies && x.object == id).toList();
    state.delayed.removeWhere(due.contains);
    for (final x in due) {
      final ctx = EffectContext()..lastTouched = id;
      log(GameEvent('triggered', object: x.source, text: name(x.source)));
      resolve(x.effects, source: x.source, controller: x.controller, context: ctx);
    }
  }

  bool _matchesDead(Filter f, DeathInfo d, PlayerID controller, ObjectID? source) {
    if (f.other && d.id == source) return false;
    if (f.controller == Controller.you && d.controller != controller) return false;
    if (f.controller == Controller.opponent && d.controller == controller) return false;
    if (f.nontoken && d.isToken) return false;
    if (f.subtype != null && !d.subtypes.contains(f.subtype)) return false;
    switch (f.kind) {
      case FilterKind.creature:
        return d.isCreature;
      case FilterKind.artifact:
        return d.isArtifact;
      case FilterKind.artifactCreature:
        return d.isArtifact && d.isCreature;
      case FilterKind.artifactOrCreature:
        return d.isArtifact || d.isCreature;
      case FilterKind.permanent:
        return true;
      default:
        return d.isCreature;
    }
  }

  // MARK: - State-based actions

  void _checkStateBasedActions() {
    if (!state.started || state.isOver) return;
    var changed = true;
    var rounds = 0;
    while (changed && rounds < 10) {
      changed = false;
      rounds++;
      for (final p in state.players) {
        if (!p.lost && p.life <= 0) {
          _lose(p.id, '${p.name} is out of life');
          changed = true;
        }
      }
      if (state.isOver) return;
      for (final o in state.allPermanents) {
        final c = characteristics(o.id);
        if (c.isCreature) {
          if (c.toughness <= 0) {
            dies(o.id);
            changed = true;
            continue;
          }
          if (o.damage >= c.toughness && !c.has(KeywordKind.indestructible)) {
            dies(o.id);
            changed = true;
            continue;
          }
        }
        final host = o.attachedTo;
        if (host != null) {
          if (state.objects[host]?.zone != Zone.battlefield || (parsedOf(o)?.isAura == true && !auraFits(o, host))) {
            o.attachedTo = null;
            if (parsedOf(o)?.isAura == true) {
              dies(o.id);
              changed = true;
            }
          }
        }
        if (isLegendary(o)) {
          final legendName = name(o.id);
          final same = state.permanentsOf(o.controller).where((x) => isLegendary(x) && name(x.id) == legendName).toList();
          if (same.length > 1) {
            final oldest = same.reduce((a, b) => a.id < b.id ? a : b);
            if (oldest.id == o.id) {
              dies(o.id);
              changed = true;
            }
          }
        }
      }
    }
  }

  // MARK: - Decisions

  void _respond(DecisionResponse r) {
    final pending = state.pending;
    if (pending == null) throw GameError('Nothing to decide');
    final resume = pending.resume;
    final decision = pending.decision;
    state.pending = null;
    switch (decision) {
      case MulliganDecision _:
        if (r is KeepResponse) {
          state.players[pending.player].keptHand = true;
          final next = state.opponentOf(pending.player);
          if (!state.players[next].keptHand) {
            _askMulligan(next);
          } else {
            _beginFirstTurn();
          }
          _runContinuations();
          return;
        }
        if (r is MulliganResponse) {
          final p = pending.player;
          final ps = state.players[p];
          ps.mulligans++;
          for (final id in List.of(ps.hand)) {
            move(id, Zone.library);
          }
          state.rng.shuffle(ps.library);
          // The cost of the mulligans taken so far, in cards.
          final cost = (ps.mulligans - (rules.freeMulligan ? 1 : 0)).clamp(0, rules.handSize - 1);
          if (rules.londonMulligan) {
            // Draw a full hand, then choose which cards go to the bottom.
            _draw(p, rules.handSize);
            log(GameEvent('mulliganed', player: p, amount: rules.handSize - cost));
            if (cost > 0) {
              state.pending = PendingDecision(
                player: p,
                decision: ChooseBottomDecision(cost),
                resume: Resume(source: null, controller: p, effects: [], context: EffectContext(), kind: ResumeKind.mulligan),
              );
            } else {
              _askMulligan(p);
            }
          } else {
            final n = rules.handSize - cost;
            _draw(p, n);
            log(GameEvent('mulliganed', player: p, amount: n));
            _askMulligan(p);
          }
          return;
        }
      case ChooseBottomDecision d:
        if (r is CardsResponse) {
          final p = pending.player;
          final ps = state.players[p];
          final chosen = r.ids.where((id) => ps.hand.contains(id)).toSet().toList();
          if (chosen.length != d.count) throw GameError('Choose ${d.count} card${d.count == 1 ? '' : 's'} to put on the bottom');
          for (final id in chosen) {
            move(id, Zone.library, toBottom: true);
          }
          _askMulligan(p);
          return;
        }
      case DeclareBlockersDecision _:
        if (r is BlockersResponse) {
          try {
            _acceptBlockers(r.blocks);
          } catch (e) {
            state.pending = pending;
            rethrow;
          }
        } else if (r is NoResponse) {
          _acceptBlockers({});
        } else {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
      case ChooseTargetsDecision d:
        if (r is! TargetsResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        final chosen = r.ids.where(d.candidates.contains).take(d.count).toList();
        if (chosen.isEmpty && !d.optional && d.candidates.isNotEmpty) {
          state.pending = pending;
          throw GameError('Choose a target');
        }
        final ctx = resume.context.copy()..targets = chosen;
        if (chosen.isEmpty) {
          resolve(resume.effects.skip(1).toList(), source: resume.source, controller: resume.controller, context: ctx);
        } else {
          resolve(resume.effects, source: resume.source, controller: resume.controller, context: ctx);
        }
      case ChooseModeDecision d:
        if (r is! ModeResponse || r.index < 0 || r.index >= d.modes.length) {
          state.pending = pending;
          throw GameError('Bad choice');
        }
        switch (resume.kind) {
          case ResumeKind.chooseNumber:
            final src = resume.source == null ? null : state.objects[resume.source!];
            src?.chosenNumber = (resume.subject ?? 0) + r.index;
            log(GameEvent('chose', object: resume.source, amount: src?.chosenNumber));
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
          case ResumeKind.topOrBottom:
            final id = resume.subject!;
            if (state.objects[id]?.zone == Zone.battlefield) {
              move(id, Zone.library, toBottom: r.index == 1);
              log(GameEvent('toLibrary', object: id, amount: r.index));
            }
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
          case ResumeKind.chooseColor:
            final color = ManaColor.values[r.index];
            final pool = state.players[resume.controller].manaPool;
            pool[color.symbol] = (pool[color.symbol] ?? 0) + (resume.subject ?? 0);
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
          default:
            final modes = resume.modes;
            if (modes == null || r.index >= modes.length) {
              state.pending = pending;
              throw GameError('Bad mode');
            }
            if (resume.cards.isNotEmpty && resume.source != null) state.objects[resume.source!]?.usedModes.add(resume.cards[r.index]);
            resolve([...modes[r.index], ...resume.effects], source: resume.source, controller: resume.controller, context: resume.context);
        }
      case ChooseModesDecision d:
        final modes = resume.modes ?? const <List<Effect>>[];
        final picks = r is CardsResponse ? r.ids.where((i) => i >= 0 && i < modes.length).toSet().toList() : <int>[];
        if (picks.length < d.min || picks.length > d.max) {
          state.pending = pending;
          throw GameError('Choose ${d.min == d.max ? d.min : '${d.min} to ${d.max}'}');
        }
        picks.sort();
        resolve([for (final i in picks) ...modes[i], ...resume.effects], source: resume.source, controller: resume.controller, context: resume.context);
      case ChooseCardsDecision d:
        final picks = r is CardsResponse ? r.ids.where(d.cards.contains).toSet().toList() : <ObjectID>[];
        if (picks.length < d.min || picks.length > d.max) {
          state.pending = pending;
          throw GameError('Choose ${d.min == d.max ? d.min : 'up to ${d.max}'}');
        }
        final ctx = resume.context;
        switch (resume.effect) {
          case LookAtTop x:
            finishLookAtTop(x, picks, resume.cards, resume.controller);
            ctx.previousHappened = picks.isNotEmpty;
          case SearchCard x:
            finishSearch(x, picks, resume.controller);
          case HandChoice x:
            finishHandChoice(x, picks, EffectContext.playerFromObject(resume.subject ?? -1) ?? state.opponentOf(resume.controller));
            ctx.previousHappened = picks.isNotEmpty;
          case ExileFromHand _:
            for (final id in picks) {
              move(id, Zone.exile);
              log(GameEvent('exiled', object: id));
            }
            ctx.previousHappened = picks.isNotEmpty;
          default:
            break;
        }
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: ctx);
      case ChooseOptionalDecision _:
        if (r is YesResponse) {
          resolve([...?resume.optionalEffects, ...resume.effects], source: resume.source, controller: resume.controller, context: resume.context);
        } else if (r is NoResponse) {
          final ctx = resume.context.copy()..previousHappened = false;
          resolve(resume.effects, source: resume.source, controller: resume.controller, context: ctx);
        } else {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
      case DiscardToHandSizeDecision d:
        if (r is! CardsResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        final p = pending.player;
        final hand = state.players[p].hand;
        final valid = r.ids.where(hand.contains).toList();
        final need = d.count < hand.length ? d.count : hand.length;
        if (valid.length != need) {
          state.pending = pending;
          throw GameError('Discard ${d.count} cards');
        }
        for (final id in valid) {
          move(id, Zone.graveyard);
          log(GameEvent('discarded', player: p, object: id));
        }
        if (resume.kind == ResumeKind.cleanup) {
          _finishCleanup();
        } else {
          resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
        }
      case ChooseSacrificeDecision d:
        if (r is! SacrificeResponse || !d.candidates.contains(r.id)) {
          state.pending = pending;
          throw GameError('Choose one of the candidates');
        }
        resume.context.sacrificedSubtypes.addAll(characteristics(r.id).subtypes);
        dies(r.id);
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
      case SurveilDecision d:
        if (r is! CardsResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        finishSurveil(pending.player, r.ids.where(d.cards.contains).toList(), d.cards);
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
      case ScryDecision d:
        if (r is! CardsResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        finishScry(pending.player, r.ids.where(d.cards.contains).toList(), d.cards);
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
      case ExploreDecision d:
        if (r is! ExploreResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        if (r.toGraveyard && state.players[pending.player].library.firstOrNull == d.card) move(d.card, Zone.graveyard);
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
      case PayOrCounterDecision d:
        if (r is YesResponse) {
          final plan = manaPlan(d.cost, pending.player);
          if (plan == null) {
            counterSpell(d.spell);
          } else {
            _payMana(plan);
            log(GameEvent('paid', player: pending.player, text: '${d.cost}'));
          }
        } else if (r is NoResponse) {
          counterSpell(d.spell);
        } else {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
      case FreeCastDecision d:
        if (r is! FreeCastResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        final c = card(d.card);
        if (r.cast && c != null) {
          final modal = db.parsed(c).spellEffects.whereType<Modal>().firstOrNull;
          final m = r.mode;
          if (modal != null && (m == null || m < 0 || m >= modal.modes.length)) {
            state.pending = pending;
            throw GameError('Choose a mode');
          }
          try {
            _validateTargets(r.targets, targetRequirementsForCard(c, m), pending.player, d.card);
          } catch (_) {
            state.pending = pending;
            rethrow;
          }
          castFree(d.card, pending.player, mode: m, targets: r.targets);
        } else if (d.toHandIfDeclined) {
          move(d.card, Zone.hand);
          log(GameEvent('toHand', player: pending.player, object: d.card));
        }
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
      case DiscoverDecision d:
        if (r is! DiscoverResponse) {
          state.pending = pending;
          throw GameError("That answer doesn't fit the question");
        }
        if (r.play) {
          playFree(d.card, pending.player);
        } else {
          move(d.card, Zone.hand);
        }
        resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context);
    }
    _runContinuations();
  }
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// What a permanent was as it died, for "whenever another creature dies" (tokens cease to exist
/// as they leave the battlefield, so this is all that's left of them).
class DeathInfo {
  DeathInfo({
    required this.id,
    required this.controller,
    required this.owner,
    required this.isCreature,
    required this.isArtifact,
    required this.isToken,
    required this.subtypes,
    required this.triggers,
    required this.wasCreatureWithCounters,
  });
  final ObjectID id;
  final PlayerID controller, owner;
  final bool isCreature, isArtifact, isToken, wasCreatureWithCounters;
  final Set<String> subtypes;
  final List<(Triggered, String)> triggers;
}
