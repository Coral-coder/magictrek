part of 'game.dart';

extension GameCombat on Game {
  void _declareAttackers(List<ObjectID> ids) {
    final p = state.activePlayer;
    if (!(state.phase == Phase.main1 || state.phase == Phase.declareAttackers || state.phase == Phase.beginCombat)) throw GameError('Not the time to attack');
    if (state.phase == Phase.main1) {
      state.phase = Phase.beginCombat;
      log(GameEvent('phase', phase: Phase.beginCombat));
      _beginCombatTriggers();
      // A beginning-of-combat trigger asked a question (Peace in Our Time): attackers are
      // declared again once it's answered, since the answer can change who may attack.
      if (state.pending != null) return;
    }
    final attackers = <ObjectID>[];
    for (final id in ids) {
      if (!attackers.contains(id)) attackers.add(id);
    }
    for (final id in attackers) {
      if (!canAttack(id) || state.objects[id]?.controller != p) throw GameError("${name(id)} can't attack");
    }
    for (final o in state.permanentsOf(p)) {
      if (canAttack(o.id) && characteristics(o.id).has(KeywordKind.mustAttack) && !attackers.contains(o.id)) attackers.add(o.id);
    }
    state.phase = Phase.declareAttackers;
    final defender = state.opponentOf(p);
    state.combat = CombatState()
      ..attackers = attackers
      ..defender = defender;
    if (attackers.isEmpty) {
      state.phase = Phase.main2;
      log(GameEvent('phase', phase: Phase.main2));
      return;
    }
    for (final id in attackers) {
      state.objects[id]!.attacking = defender;
      if (!characteristics(id).has(KeywordKind.vigilance)) {
        state.objects[id]!.tapped = true;
        log(GameEvent('tapped', object: id));
      }
    }
    log(GameEvent('attackersDeclared', player: p, ids: List.of(attackers)));
    state.players[p].opponentsAttackedThisTurn = 1;
    for (final o in state.permanentsOf(p)) {
      fireTriggers(SimpleTrigger.youAttack, o.id);
    }
    for (final id in attackers) {
      fireTriggers(SimpleTrigger.attacks, id);
      for (final e in state.permanentsOf(p).where((e) => e.attachedTo == id).toList()) {
        fireTriggers(SimpleTrigger.equippedAttacks, e.id, touched: id);
      }
    }
    state.turnContinuation.add(TurnStep.attackWindow);
    state.turnContinuation.add(TurnStep.blockers);
  }

  void _askBlockers() {
    final defender = state.combat.defender;
    final attackers = state.combat.attackers.where((a) => state.objects[a]?.zone == Zone.battlefield).toList();
    state.combat.attackers = attackers;
    state.phase = Phase.declareBlockers;
    log(GameEvent('phase', phase: Phase.declareBlockers));
    final possible = state.permanentsOf(defender).any((b) => attackers.any((a) => canBlock(b.id, a)));
    if (attackers.isEmpty || !possible) {
      state.turnContinuation.addAll(const [TurnStep.blockWindowActive, TurnStep.blockWindowDefender, TurnStep.combatDamage]);
      return;
    }
    state.pending = PendingDecision(
      player: defender,
      decision: DeclareBlockersDecision(attackers),
      resume: Resume(source: null, controller: defender, effects: [], context: EffectContext(), kind: ResumeKind.blockers),
    );
    state.turnContinuation.addAll(const [TurnStep.blockWindowActive, TurnStep.blockWindowDefender, TurnStep.combatDamage]);
  }

  void _acceptBlockers(Map<ObjectID, ObjectID> blocks) {
    final defender = state.combat.defender;
    final counts = <ObjectID, int>{};
    final sortedBlocks = blocks.entries.toList()..sort((a, b) => a.key - b.key);
    for (final e in sortedBlocks) {
      if (state.objects[e.key]?.controller != defender || !state.combat.attackers.contains(e.value) || !canBlock(e.key, e.value)) {
        throw GameError("${name(e.key)} can't block ${name(e.value)}");
      }
      counts[e.value] = (counts[e.value] ?? 0) + 1;
    }
    for (final e in counts.entries) {
      if (characteristics(e.key).has(KeywordKind.menace) && e.value < 2) throw GameError('${name(e.key)} needs two blockers');
      if (characteristics(e.key).has(KeywordKind.oneBlocker) && e.value > 1) throw GameError("${name(e.key)} can't be blocked by more than one creature");
    }
    state.combat.blockers = Map.of(blocks);
    for (final e in sortedBlocks) {
      state.objects[e.key]!.blocking = e.value;
    }
    log(GameEvent('blockersDeclared', player: defender, map: Map.of(blocks)));
    for (final e in sortedBlocks) {
      fireTriggers(SimpleTrigger.blocks, e.key);
      fireTriggers(SimpleTrigger.blocked, e.value);
    }
  }

  void _combatDamage() {
    state.phase = Phase.combatDamage;
    log(GameEvent('phase', phase: Phase.combatDamage));
    final attackers = state.combat.attackers.where((a) => state.objects[a]?.zone == Zone.battlefield).toList();
    bool fs(ObjectID id) {
      final c = characteristics(id);
      return c.has(KeywordKind.firstStrike) || c.has(KeywordKind.doubleStrike);
    }

    final anyFirstStrike = attackers.any(fs) || state.combat.blockers.keys.any(fs);
    if (anyFirstStrike) {
      _dealCombatDamage(firstStrikeStep: true);
      _checkStateBasedActions();
    }
    _dealCombatDamage(firstStrikeStep: false);
    _checkStateBasedActions();
    state.phase = Phase.endCombat;
    for (final id in state.combat.attackers) {
      state.objects[id]?.attacking = null;
    }
    for (final id in state.combat.blockers.keys) {
      state.objects[id]?.blocking = null;
    }
    state.combat = CombatState();
    state.phase = Phase.main2;
    log(GameEvent('phase', phase: Phase.main2));
  }

  void _dealCombatDamage({required bool firstStrikeStep}) {
    final defender = state.combat.defender;
    final attackers = state.combat.attackers.where((a) => state.objects[a]?.zone == Zone.battlefield).toList();
    bool strikesNow(ObjectID id) {
      final c = characteristics(id);
      if (firstStrikeStep) return c.has(KeywordKind.firstStrike) || c.has(KeywordKind.doubleStrike);
      return c.has(KeywordKind.doubleStrike) || !c.has(KeywordKind.firstStrike);
    }

    final pending = <(int, ObjectID, ObjectID?)>[];
    for (final a in attackers) {
      if (!strikesNow(a)) continue;
      final ac = characteristics(a);
      final power = ac.power < 0 ? 0 : ac.power;
      final blockers = state.combat.blockers.entries.where((e) => e.value == a).map((e) => e.key).where((b) => state.objects[b]?.zone == Zone.battlefield).toList()..sort();
      if (blockers.isEmpty) {
        if (state.combat.blockers.values.contains(a)) {
          if (ac.has(KeywordKind.trample)) pending.add((power, EffectContext.playerObject(defender), a));
        } else {
          pending.add((power, EffectContext.playerObject(defender), a));
        }
        continue;
      }
      var remaining = power;
      final ordered = List.of(blockers)
        ..sort((x, y) {
          final tx = characteristics(x).toughness, ty = characteristics(y).toughness;
          return tx != ty ? tx - ty : x - y;
        });
      for (var i = 0; i < ordered.length; i++) {
        final b = ordered[i];
        final bc = characteristics(b);
        final lethal = ac.has(KeywordKind.deathtouch) ? 1 : (bc.toughness - (state.objects[b]?.damage ?? 0)).clamp(0, 1 << 30);
        final isLast = i == ordered.length - 1;
        final give = (ac.has(KeywordKind.trample) || !isLast) ? (remaining < lethal ? remaining : lethal) : remaining;
        pending.add((give, b, a));
        remaining -= give;
      }
      if (remaining > 0 && ac.has(KeywordKind.trample)) pending.add((remaining, EffectContext.playerObject(defender), a));
    }
    final sortedBlocks = state.combat.blockers.entries.toList()..sort((a, b) => a.key - b.key);
    for (final e in sortedBlocks) {
      if (strikesNow(e.key) && state.objects[e.key]?.zone == Zone.battlefield && state.objects[e.value]?.zone == Zone.battlefield) {
        final pw = characteristics(e.key).power;
        pending.add((pw < 0 ? 0 : pw, e.value, e.key));
      }
    }
    final damagedPlayerBy = <ObjectID, int>{};
    for (final (amount, target, source) in pending) {
      final dealt = dealDamage(amount, target, source);
      if (dealt > 0 && EffectContext.playerFromObject(target) != null && source != null) damagedPlayerBy[source] = (damagedPlayerBy[source] ?? 0) + dealt;
    }
    for (final e in damagedPlayerBy.entries) {
      fireTriggers(SimpleTrigger.combatDamageToPlayer, e.key, amount: e.value);
      final hitter = state.objects[e.key];
      if (hitter != null && hitter.counters.values.any((n) => n > 0)) {
        for (final o in state.permanentsOf(hitter.controller)) {
          fireTriggers(SimpleTrigger.counteredCreatureHitsPlayer, o.id, touched: e.key, amount: e.value);
        }
      }
    }
  }
}
