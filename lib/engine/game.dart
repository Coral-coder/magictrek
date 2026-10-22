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
      case ConcedeAction _:
        _lose(state.activePlayer, '${state.players[state.activePlayer].name} conceded');
      case TimeOutAction a:
        _lose(a.player, '${state.players[a.player].name} ran out of time');
      default:
        if (!state.started) throw GameError("The game hasn't started");
        if (state.pending != null) throw GameError('Waiting for a decision');
        switch (action) {
          case PlayLandAction a:
            _playLand(a.id);
          case CastAction a:
            _cast(a.id, targets: a.targets, kicked: a.kicked, mode: a.mode, beamUpBounce: a.beamUpBounce);
          case ActivateAbilityAction a:
            _activate(a.id, a.ability, targets: a.targets, sacrifice: a.sacrifice, discard: a.discard);
          case StationAction a:
            _station(a.spacecraft, a.creature);
          case EquipAction a:
            _equip(a.equipment, a.to);
          case CycleAction a:
            _cycle(a.id);
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
    state.actionCount++;
    _checkStateBasedActions();
  }

  /// Applies an action for a specific player, checking it is theirs to take.
  void applyAs(GameAction action, PlayerID player) {
    switch (action) {
      case StartAction _:
      case TimeOutAction _:
        break;
      case ConcedeAction _:
        _lose(player, '${state.players[player].name} conceded');
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
    state.pending = PendingDecision(player: p, decision: const MulliganDecision(), resume: Resume(source: null, controller: p, effects: [], context: EffectContext(), kind: ResumeKind.mulligan));
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
    }
  }

  /// Moves an object to a zone of its owner (or controller, for the battlefield) and resets battlefield state.
  void move(ObjectID id, Zone zone, {PlayerID? controller, bool tapped = false, bool toBottom = false}) {
    final o = state.objects[id];
    if (o == null) return;
    final wasOnBattlefield = o.zone == Zone.battlefield;
    _removeFromZone(id);
    if (wasOnBattlefield) {
      for (final other in state.allPermanents) {
        if (other.attachedTo == id) {
          other.attachedTo = null;
          if (parsedOf(other)?.isAura == true) move(other.id, Zone.graveyard);
        }
      }
    }
    if (o.isToken && zone != Zone.battlefield) {
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
    o.controller = zone == Zone.battlefield ? (controller ?? o.owner) : o.owner;
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
    }
  }

  void _draw(PlayerID p, int n) {
    var drawn = 0;
    for (var i = 0; i < n; i++) {
      final lib = state.players[p].library;
      if (lib.isEmpty) {
        _lose(p, '${state.players[p].name} drew from an empty library');
        break;
      }
      move(lib.first, Zone.hand);
      drawn++;
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
    log(GameEvent('turnBegan', amount: state.turn, player: p));
    for (final o in state.permanentsOf(p)) {
      o.activatedThisTurn = {};
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
    state.phase = Phase.main1;
    log(GameEvent('phase', phase: Phase.main1));
  }

  void _runContinuations() {
    while (state.pending == null && state.turnContinuation.isNotEmpty && !state.isOver) {
      final step = state.turnContinuation.removeAt(0);
      switch (step) {
        case TurnStep.drawStep:
          _drawStep(state.turn == 1);
        case TurnStep.main1:
          state.phase = Phase.main1;
          log(GameEvent('phase', phase: Phase.main1));
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
        for (final o in state.permanentsOf(state.activePlayer)) {
          fireTriggers(SimpleTrigger.beginCombat, o.id);
        }
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
    state.phase = Phase.end;
    log(GameEvent('phase', phase: Phase.end));
    final p = state.activePlayer;
    for (final o in state.permanentsOf(p)) {
      fireTriggers(SimpleTrigger.endStep, o.id);
    }
    for (final o in state.allPermanents) {
      if (o.sacrificeAtEnd) {
        move(o.id, Zone.graveyard);
        log(GameEvent('died', object: o.id));
      }
    }
    state.turnContinuation.add(TurnStep.cleanup);
  }

  void _cleanup() {
    state.phase = Phase.cleanup;
    final p = state.activePlayer;
    final ps = state.players[p];
    final noMax = ps.noMaxHandSizeUntilNextTurn || state.permanentsOf(p).any((o) => parsedOf(o)?.statics.contains(SimpleStatic.noMaxHandSize) == true);
    if (!noMax && rules.maxHandSize && ps.hand.length > rules.handSize) {
      state.pending = PendingDecision(player: p, decision: DiscardToHandSizeDecision(ps.hand.length - rules.handSize), resume: Resume(source: null, controller: p, effects: [], context: EffectContext(), kind: ResumeKind.cleanup));
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
    }
    _checkStateBasedActions();
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
    move(id, Zone.battlefield, controller: p, tapped: tapped);
    log(GameEvent('playedLand', player: p, object: id));
    enteredBattlefield(id, untapped: !tapped);
    for (final o in state.permanentsOf(p)) {
      if (o.id != id) fireTriggers(SimpleTrigger.landfall, o.id, touched: id);
    }
    _runContinuations();
  }

  void _cast(ObjectID id, {required List<ObjectID> targets, required bool kicked, int? mode, ObjectID? beamUpBounce}) {
    final p = state.activePlayer;
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null) throw GameError('No such card');
    final parsed = db.parsed(card);
    var cost = card.cost;
    var fromGraveyard = false;
    if (o.zone == Zone.graveyard) {
      final beam = parsed.beamMeUp;
      final b = beamUpBounce == null ? null : state.objects[beamUpBounce];
      if (beam == null || b == null || b.zone != Zone.battlefield || b.controller != p || !characteristics(beamUpBounce!).isCreature) throw GameError("Can't beam that up");
      cost = beam.copy();
      fromGraveyard = true;
    } else {
      if (!canCast(id, p)) throw GameError("Can't cast that now");
    }
    if (kicked) {
      final k = parsed.kicker;
      if (k == null) throw GameError('No kicker');
      cost.add(k);
    }
    final reqs = targetRequirementsForCard(card, mode);
    _validateTargets(targets, reqs, p, id);
    for (final t in targets) {
      if (EffectContext.playerFromObject(t) == null) {
        final tgt = state.objects[t];
        if (tgt != null && tgt.controller != p) cost.generic += characteristics(t).wardCost;
      }
    }
    final plan = manaPlan(cost, p);
    if (plan == null) throw GameError('Not enough mana');
    _payMana(plan);
    if (fromGraveyard && beamUpBounce != null) {
      move(beamUpBounce, Zone.hand);
      log(GameEvent('bounced', object: beamUpBounce));
    }
    state.players[p].spellsCastThisTurn++;
    log(GameEvent('cast', player: p, object: id, amount: kicked ? 1 : 0));
    final context = EffectContext()
      ..targets = List.of(targets)
      ..kicked = kicked;
    if (card.isPermanent) {
      move(id, Zone.battlefield, controller: p);
      if (parsed.isAura && targets.isNotEmpty) state.objects[id]!.attachedTo = targets.first;
      enteredBattlefield(id, untapped: true);
    } else {
      var effects = List.of(parsed.spellEffects);
      final mi = effects.indexWhere((e) => e is Modal);
      if (mode != null && mi >= 0) {
        final modes = (effects[mi] as Modal).modes;
        if (mode < modes.length) effects = [...effects.sublist(0, mi), ...modes[mode], ...effects.sublist(mi + 1)];
      }
      resolve(effects, source: id, controller: p, context: context);
      if (state.objects[id]?.zone != Zone.battlefield) move(id, fromGraveyard ? Zone.exile : Zone.graveyard);
    }
    final kind = card.isCreature ? SpellKind.creature : SpellKind.noncreature;
    for (final other in state.allPermanents) {
      if (other.controller != p) continue;
      for (final (event, fx) in grantedAndOwnTriggers(other.id)) {
        if (event is CastSpellTrigger) {
          final k = event.kind;
          if (k == SpellKind.any || k == kind || (k == SpellKind.artifact && card.isArtifact) || (k == SpellKind.instantOrSorcery && (card.isInstant || card.isSorcery))) {
            runTrigger(fx, source: other.id, touched: id);
          }
        }
      }
    }
    _runContinuations();
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
    for (final id in plan) {
      final o = state.objects[id];
      if (o == null) continue;
      final parsed = parsedOf(o);
      if (parsed != null && parsed.abilities.any((a) => a is Activated && a.cost.sacrificeSelf && a.cost.tap)) {
        move(id, Zone.graveyard); // Treasure
      } else {
        o.tapped = true;
        log(GameEvent('tapped', object: id));
        fireTriggers(SimpleTrigger.becomesTapped, id);
      }
    }
  }

  void enteredBattlefield(ObjectID id, {required bool untapped}) {
    final o = state.objects[id];
    if (o == null) return;
    log(GameEvent('entered', object: id));
    if (cardOf(o)?.isSaga == true) _advanceSaga(id);
    fireTriggers(SimpleTrigger.enters, id);
    if (untapped) fireTriggers(SimpleTrigger.entersUntapped, id);
    final c = characteristics(id);
    for (final other in state.allPermanents) {
      if (other.id == id) continue;
      for (final (event, fx) in grantedAndOwnTriggers(other.id)) {
        if (event is PermanentEntersTrigger && matches(event.filter, id, other.controller, other.id, base: c)) {
          runTrigger(fx, source: other.id, touched: id);
        }
      }
    }
  }

  void _activate(ObjectID id, int index, {required List<ObjectID> targets, ObjectID? sacrifice, ObjectID? discard}) {
    final p = state.activePlayer;
    final o = state.objects[id];
    final parsed = o == null ? null : parsedOf(o);
    if (o == null || o.controller != p || o.zone != Zone.battlefield || parsed == null || index >= parsed.abilities.length) throw GameError('No such ability');
    final ability = parsed.abilities[index];
    if (ability is! Activated) throw GameError('No such ability');
    final cost = ability.cost;
    if (ability.sorcerySpeed && !state.phase.isMain) throw GameError('Only as a sorcery');
    if (cost.oncePerTurn && o.activatedThisTurn.contains(index)) throw GameError('Already used this turn');
    if (cost.tap) {
      if (o.tapped) throw GameError('Already tapped');
      if (characteristics(id).isCreature && hasSummoningSickness(o)) throw GameError('Summoning sick');
    }
    if (cost.payLife > 0 && state.players[p].life <= cost.payLife) throw GameError('Not enough life');
    ObjectID? sacID;
    final f = cost.sacrifice;
    if (f != null) {
      if (sacrifice == null || !matches(f, sacrifice, p, id) || state.objects[sacrifice]?.controller != p) throw GameError('Choose something to sacrifice');
      sacID = sacrifice;
    }
    if (cost.discard > 0) {
      final d = discard == null ? null : state.objects[discard];
      if (d == null || d.zone != Zone.hand || d.owner != p) throw GameError('Choose a card to discard');
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
    if (cost.payLife > 0) changeLife(p, -cost.payLife);
    if (discard != null && cost.discard > 0) {
      move(discard, Zone.graveyard);
      log(GameEvent('discarded', player: p, object: discard));
    }
    if (sacID != null) {
      move(sacID, Zone.graveyard);
      log(GameEvent('died', object: sacID));
      fireDies(sacID);
    }
    if (cost.sacrificeSelf) {
      move(id, Zone.graveyard);
      log(GameEvent('died', object: id));
    }
    o.activatedThisTurn.add(index);
    log(GameEvent('activated', object: id, text: name(id)));
    final context = EffectContext()..targets = List.of(targets);
    resolve(ability.effects, source: id, controller: p, context: context);
    _runContinuations();
  }

  void _station(ObjectID spacecraft, ObjectID creature) {
    final p = state.activePlayer;
    final s = state.objects[spacecraft];
    final c = state.objects[creature];
    if (!state.phase.isMain || s == null || s.controller != p || c == null || c.controller != p || c.tapped || spacecraft == creature || !characteristics(spacecraft).isSpacecraft || parsedOf(s)?.has(KeywordKind.station) != true) {
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
    final p = state.activePlayer;
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
      for (final o in state.permanentsOf(p)) {
        fireTriggers(SimpleTrigger.gainLife, o.id);
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
    if (n == 0 || o == null || o.zone != Zone.battlefield) return;
    o.counters[kind] = (o.counters[kind] ?? 0) + n;
    log(GameEvent('counters', object: id, counter: kind, amount: n));
  }

  void destroy(ObjectID id) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield) return;
    if (characteristics(id).has(KeywordKind.indestructible)) return;
    move(id, Zone.graveyard);
    log(GameEvent('destroyed', object: id));
    fireDies(id);
  }

  void fireDies(ObjectID id) {
    final o = state.objects[id];
    if (o == null) return;
    final card = cardOf(o);
    if (card != null) {
      final parsed = db.parsed(card);
      for (final fx in parsed.triggers(SimpleTrigger.dies)) {
        runTrigger(fx, source: id, touched: id, leftBattlefield: true);
      }
      for (final fx in parsed.triggers(SimpleTrigger.leaves)) {
        runTrigger(fx, source: id, touched: id, leftBattlefield: true);
      }
    }
    for (final other in state.allPermanents) {
      for (final (event, fx) in grantedAndOwnTriggers(other.id)) {
        if (event is PermanentDiesTrigger && _matchesDead(event.filter, id, other.controller, other.id)) runTrigger(fx, source: other.id, touched: id);
      }
    }
  }

  bool _matchesDead(Filter f, ObjectID id, PlayerID controller, ObjectID? source) {
    final o = state.objects[id];
    final c = o == null ? null : cardOf(o);
    if (o == null || c == null) return false;
    if (f.other && id == source) return false;
    if (f.controller == Controller.you && o.owner != controller) return false;
    if (f.controller == Controller.opponent && o.owner == controller) return false;
    switch (f.kind) {
      case FilterKind.creature:
        return c.isCreature;
      case FilterKind.artifact:
        return c.isArtifact;
      case FilterKind.permanent:
        return true;
      default:
        return c.isCreature;
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
            move(o.id, Zone.graveyard);
            log(GameEvent('died', object: o.id));
            fireDies(o.id);
            changed = true;
            continue;
          }
          if (o.damage >= c.toughness && !c.has(KeywordKind.indestructible)) {
            move(o.id, Zone.graveyard);
            log(GameEvent('died', object: o.id));
            fireDies(o.id);
            changed = true;
            continue;
          }
        }
        final host = o.attachedTo;
        if (host != null) {
          if (state.objects[host]?.zone != Zone.battlefield || (parsedOf(o)?.isAura == true && !characteristics(host).isCreature)) {
            o.attachedTo = null;
            if (parsedOf(o)?.isAura == true) {
              move(o.id, Zone.graveyard);
              log(GameEvent('died', object: o.id));
              changed = true;
            }
          }
        }
        final legend = cardOf(o);
        if (legend != null && legend.isLegendary) {
          final same = state.permanentsOf(o.controller).where((x) => cardOf(x)?.name == legend.name).toList();
          if (same.length > 1) {
            final oldest = same.reduce((a, b) => a.id < b.id ? a : b);
            if (oldest.id == o.id) {
              move(o.id, Zone.graveyard);
              log(GameEvent('died', object: o.id));
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
              state.pending = PendingDecision(player: p, decision: ChooseBottomDecision(cost), resume: Resume(source: null, controller: p, effects: [], context: EffectContext(), kind: ResumeKind.mulligan));
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
        final modes = resume.modes;
        if (r is! ModeResponse || modes == null || r.index >= modes.length || r.index >= d.modes.length) {
          state.pending = pending;
          throw GameError('Bad mode');
        }
        resolve([...modes[r.index], ...resume.effects], source: resume.source, controller: resume.controller, context: resume.context);
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
        move(r.id, Zone.graveyard);
        log(GameEvent('died', object: r.id));
        fireDies(r.id);
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
