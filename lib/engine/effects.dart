part of 'game.dart';

extension GameEffects on Game {
  /// The abilities a permanent has right now: its own, plus any station lines it is charged past.
  List<Ability> activeAbilities(GameObject o) {
    final p = parsedOf(o);
    if (p == null) return const [];
    final lines = p.stationLines;
    if (lines.isEmpty) return p.abilities;
    final charge = o.chargeCounters;
    return [
      ...p.abilities,
      for (final line in lines)
        if (charge >= line.threshold) ...line.extra,
    ];
  }

  /// The static abilities a permanent has right now.
  List<StaticAbility> staticsOf(GameObject o) => activeAbilities(o).whereType<StaticAbilityEntry>().map((s) => s.ability).toList();

  /// Whether any permanent `p` controls has the static.
  bool controlsStatic(PlayerID p, SimpleStaticKind kind) => state.permanentsOf(p).any((o) => staticsOf(o).any((s) => s is SimpleStatic && s.kind == kind));

  /// A permanent's own triggered abilities plus the ones statics on the battlefield grant it. Each
  /// comes with a key unique to the ability, for "triggers only once each turn".
  List<(Triggered, String)> triggersOf(ObjectID id) {
    final o = state.objects[id];
    if (o == null) return const [];
    final out = <(Triggered, String)>[];
    final own = activeAbilities(o);
    for (var i = 0; i < own.length; i++) {
      final a = own[i];
      if (a is Triggered) out.add((a, '$id:$i'));
    }
    for (final other in state.allPermanents) {
      final statics = staticsOf(other);
      for (var i = 0; i < statics.length; i++) {
        final s = statics[i];
        if (s is GrantTrigger && matches(s.filter, id, other.controller, other.id)) out.add((Triggered(s.event, s.effects), '$id:g${other.id}:$i'));
      }
    }
    // Equipment and Auras: "Whenever equipped creature attacks" belongs to the attachment.
    return out;
  }

  /// Compatibility: (event, effects) of every trigger of a permanent.
  List<(TriggerEvent, List<Effect>)> grantedAndOwnTriggers(ObjectID id) => [for (final (t, _) in triggersOf(id)) (t.event, t.effects)];

  /// Fires the permanent's triggers for `event`. `amount` is carried into the effects (combat
  /// damage dealt, for "draw that many cards").
  void fireTriggers(TriggerEvent event, ObjectID id, {ObjectID? touched, int amount = 0}) {
    if (state.objects[id]?.zone != Zone.battlefield) return;
    for (final (t, key) in triggersOf(id)) {
      if (t.event == event) fireTrigger(t, key, source: id, touched: touched, amount: amount);
    }
  }

  /// Fires one triggered ability if its condition holds and it hasn't used its once-per-turn.
  bool fireTrigger(Triggered t, String key, {required ObjectID source, ObjectID? touched, int amount = 0, bool leftBattlefield = false}) {
    final o = state.objects[source];
    if (o == null) return false;
    final c = t.condition;
    if (c != null && !triggerConditionHolds(c, source, o.controller)) return false;
    if (t.oncePerTurn) {
      if (state.firedThisTurn.contains(key)) return false;
      state.firedThisTurn.add(key);
    }
    final n = (state.resolvedCounts[key] ?? 0) + 1;
    state.resolvedCounts[key] = n;
    runTrigger(t.effects, source: source, touched: touched, leftBattlefield: leftBattlefield, amount: amount, resolution: n);
    return true;
  }

  bool triggerConditionHolds(TriggerCondition c, ObjectID source, PlayerID controller) {
    switch (c.kind) {
      case TriggerConditionKind.totalPowerAtLeast:
        final total = state.permanentsOf(controller).where((o) => characteristics(o.id).isCreature).fold<int>(0, (a, o) => a + characteristics(o.id).power.clamp(0, 1 << 20));
        return total >= c.n;
      case TriggerConditionKind.castNoncreatureThisTurn:
        return state.players[controller].noncreatureSpellsThisTurn > 0;
      case TriggerConditionKind.wasCast:
        return state.objects[source]?.wasCast == true;
      case TriggerConditionKind.selfCountersAtLeast:
        return (state.objects[source]?.counters[c.counter] ?? 0) >= c.n;
      case TriggerConditionKind.firstSpellThisGame:
        return state.players[controller].spellsCastThisGame <= 1;
      case TriggerConditionKind.permanentReturnedToHandThisTurn:
        return state.players[controller].permanentsReturnedToHandThisTurn > 0;
    }
  }

  void runTrigger(List<Effect> effects, {required ObjectID source, ObjectID? touched, bool leftBattlefield = false, int amount = 0, int resolution = 1}) {
    final o = state.objects[source];
    if (o == null) return;
    if (!leftBattlefield && o.zone != Zone.battlefield) return;
    log(GameEvent('triggered', object: source, text: name(source)));
    final context = EffectContext()
      ..lastTouched = touched ?? source
      ..triggeringObject = touched
      ..eventAmount = amount
      ..resolution = resolution;
    if (state.pending != null) {
      // Someone is mid-decision: this trigger waits its turn.
      state.queuedTriggers.add(QueuedTrigger(source: source, controller: o.controller, effects: effects, context: context));
      return;
    }
    resolve(effects, source: source, controller: o.controller, context: context);
  }

  /// Resolves effects in order. Pauses (storing the rest in `state.pending`) when a player must choose.
  void resolve(List<Effect> effects, {required ObjectID? source, required PlayerID controller, required EffectContext context}) {
    final ctx = context;
    var queue = List.of(effects);
    if (ctx.kicked) {
      final i = queue.indexWhere((e) => e is KickedInstead);
      if (i >= 0) queue = [...(queue[i] as KickedInstead).effects, ...queue.sublist(i + 1)];
    }
    while (queue.isNotEmpty && !state.isOver) {
      final pending = state.pending;
      if (pending != null) {
        pending.resume.effects = [...queue, ...pending.resume.effects];
        return;
      }
      final e = queue.removeAt(0);
      final happened = _applyEffect(e, source, controller, ctx, queue);
      final after = state.pending;
      if (after != null) {
        after.resume.effects = List.of(queue);
        after.resume.context = ctx;
        return;
      }
      ctx.previousHappened = happened;
    }
  }

  /// The chosen target(s) of a Target in the current context, as object ids (players as player objects).
  List<ObjectID> resolveTarget(Target t, ObjectID? source, PlayerID controller, EffectContext context) {
    switch (t) {
      case ThisTarget _:
        return source == null ? [] : [source];
      case YouTarget _:
        return [EffectContext.playerObject(controller)];
      case LastTarget _:
        final last = context.lastTouched;
        if (last != null) return [last];
        if (context.targets.isNotEmpty) return [context.targets.removeAt(0)];
        return source == null ? [] : [source];
      case ControllerOfLastTarget _:
        final last = context.lastTouched;
        if (last == null) return [];
        if (EffectContext.playerFromObject(last) != null) return [last];
        final o = state.objects[last];
        return o == null ? [] : [EffectContext.playerObject(o.controller)];
      case AttachedCreatureTarget _:
        final host = source == null ? null : state.objects[source]?.attachedTo;
        return host == null ? [] : [host];
      case TriggeringTarget _:
        final t = context.triggeringObject;
        return t == null ? [] : [t];
      case EachTarget e:
        final f = e.filter;
        if (f.isPlayerFilter) {
          return state.players.where((p) => !p.lost && (f.kind == FilterKind.player || p.id != controller)).map((p) => EffectContext.playerObject(p.id)).toList();
        }
        return state.allPermanents.where((o) => matches(f, o.id, controller, source)).map((o) => o.id).toList();
      case ChosenTarget c:
        final taken = <ObjectID>[];
        while (taken.length < c.count && context.targets.isNotEmpty) {
          final id = context.targets[0];
          final isPlayer = EffectContext.playerFromObject(id) != null;
          if (legalTargets(c.filter, controller, source).contains(id) || (isPlayer && (c.filter.isPlayerFilter || c.filter.kind == FilterKind.creatureOrPlayer))) {
            taken.add(id);
            context.targets.removeAt(0);
          } else {
            break;
          }
        }
        return taken;
    }
  }

  /// Asks the player for targets if the effect needs some that weren't chosen up front (triggers).
  bool _needTargets(Target t, ObjectID? source, PlayerID controller, EffectContext context, String prompt, List<Effect> remaining, Effect current) {
    if (t is! ChosenTarget || context.targets.isNotEmpty) return false;
    final candidates = legalTargets(t.filter, controller, source);
    if (candidates.isEmpty) return false;
    if (candidates.length == 1 && !t.optional) {
      context.targets = List.of(candidates);
      return false;
    }
    if (state.players[controller].isBot) {
      context.targets = Bot.chooseTargets(this, t.filter, t.count, t.optional, candidates, controller, current);
      return false;
    }
    state.pending = PendingDecision(
      player: controller,
      decision: ChooseTargetsDecision(prompt: prompt, filter: t.filter, count: t.count, optional: t.optional, candidates: candidates),
      resume: Resume(source: source, controller: controller, effects: [current, ...remaining], context: context, kind: ResumeKind.targets),
    );
    return true;
  }

  /// Applies one effect. Returns whether it did anything (for "If you do").
  bool _applyEffect(Effect e, ObjectID? source, PlayerID controller, EffectContext ctx, List<Effect> remaining) {
    List<ObjectID>? targets(Target t, String prompt) {
      if (_needTargets(t, source, controller, ctx, prompt, remaining, e)) {
        remaining.clear();
        return null;
      }
      final ids = resolveTarget(t, source, controller, ctx);
      if (ids.isNotEmpty) ctx.lastTouched = ids.last;
      return ids;
    }

    final srcName = source == null ? 'Effect' : name(source);
    switch (e) {
      case Damage x:
        final ids = targets(x.target, '$srcName: choose what to damage');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        var any = false;
        for (final id in ids) {
          any = dealDamage(n, id, source) > 0 || any;
        }
        return any;
      case Draw x:
        final ids = targets(x.target, '$srcName: who draws');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p != null) _draw(p, n);
        }
        return true;
      case GainLife x:
        final ids = targets(x.target, '$srcName: who gains life');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p != null) changeLife(p, n);
        }
        return true;
      case LoseLife x:
        final ids = targets(x.target, '$srcName: who loses life');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p != null) changeLife(p, -n);
        }
        return true;
      case Destroy x:
        final ids = targets(x.target, '$srcName: choose what to destroy');
        if (ids == null) return false;
        var nonartifactCreatures = 0;
        for (final id in ids) {
          final c = characteristics(id);
          final counts = c.isCreature && !c.isArtifact;
          final before = state.objects[id]?.zone;
          destroy(id);
          if (counts && before == Zone.battlefield && state.objects[id]?.zone != Zone.battlefield) nonartifactCreatures++;
        }
        ctx.counted = nonartifactCreatures;
        return ids.isNotEmpty;
      case Exile x:
        final ids = targets(x.target, '$srcName: choose what to exile');
        if (ids == null) return false;
        for (final id in ids) {
          final z = state.objects[id]?.zone;
          if (z != Zone.battlefield && z != Zone.graveyard) continue;
          move(id, Zone.exile);
          log(GameEvent('exiled', object: id));
          if (source != null && z == Zone.battlefield) state.objects[source]?.exiledWithThis.add(id);
        }
        return ids.isNotEmpty;
      case Bounce x:
        final ids = targets(x.target, '$srcName: choose what to return');
        if (ids == null) return false;
        for (final id in ids) {
          if (state.objects[id]?.zone != Zone.battlefield) continue;
          move(id, Zone.hand);
          log(GameEvent('bounced', object: id));
        }
        return ids.isNotEmpty;
      case Tap x:
        final ids = targets(x.target, '$srcName: choose what to tap');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield) continue;
          o.tapped = true;
          log(GameEvent('tapped', object: id));
          fireTriggers(SimpleTrigger.becomesTapped, id);
        }
        return ids.isNotEmpty;
      case Untap x:
        final ids = targets(x.target, '$srcName: choose what to untap');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield) continue;
          o.tapped = false;
          log(GameEvent('untapped', object: id));
        }
        return ids.isNotEmpty;
      case Pump x:
        final ids = targets(x.target, '$srcName: choose a creature');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o != null && o.zone == Zone.battlefield) o.untilEndOfTurn.add(PumpEffect(x.power, x.toughness));
        }
        return ids.isNotEmpty;
      case AddCounters x:
        final ids = targets(x.target, '$srcName: choose where the counters go');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        var given = 0;
        final live = ids.where((id) => state.objects[id]?.zone == Zone.battlefield).toList();
        for (var i = 0; i < ids.length; i++) {
          final id = ids[i];
          // Distributed: split as evenly as possible, earlier targets taking the remainder.
          var each = n;
          if (x.distribute && live.isNotEmpty) {
            final at = live.indexOf(id);
            each = at < 0 ? 0 : n ~/ live.length + (at < n % live.length ? 1 : 0);
          }
          if (each > 0 && state.objects[id]?.zone == Zone.battlefield) given++;
          addCounters(x.kind, each, id);
        }
        ctx.counted = given;
        return ids.isNotEmpty;
      case CreateTokens x:
        final ids = targets(x.target, '$srcName: who gets the tokens');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          for (var i = 0; i < n; i++) {
            final t = createToken(x.spec, p, tapped: x.tapped);
            if (x.sacrificeAtEnd) state.objects[t]?.sacrificeAtEnd = true;
            ctx.lastTouched = t;
          }
        }
        return true;
      case Surveil x:
        final top = state.players[controller].library.take(x.n).toList();
        if (top.isEmpty) return false;
        if (state.players[controller].isBot) {
          finishSurveil(controller, Bot.surveil(this, top, controller), top);
          return true;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: SurveilDecision(top),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.surveil),
        );
        remaining.clear();
        return true;
      case Scry x:
        final top = state.players[controller].library.take(x.n).toList();
        if (top.isEmpty) return false;
        if (state.players[controller].isBot) {
          finishScry(controller, Bot.scry(this, top, controller), top);
          return true;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ScryDecision(top),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.scry),
        );
        remaining.clear();
        return true;
      case Mill x:
        final ids = targets(x.target, '$srcName: who mills');
        if (ids == null) return false;
        ctx.affected = [];
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          for (var i = 0; i < x.n; i++) {
            final lib = state.players[p].library;
            if (lib.isEmpty) break;
            final top = lib.first;
            move(top, Zone.graveyard);
            ctx.affected.add(top);
            log(GameEvent('milled', player: p, object: top));
          }
        }
        return true;
      case Discard x:
        final ids = targets(x.target, '$srcName: who discards');
        if (ids == null) return false;
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          final hand = state.players[p].hand;
          if (hand.isEmpty) continue;
          final count = x.n < hand.length ? x.n : hand.length;
          if (p == controller && !state.players[p].isBot) {
            state.pending = PendingDecision(
              player: p,
              decision: DiscardToHandSizeDecision(count),
              resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.none),
            );
            remaining.clear();
            return true;
          }
          for (final c in Bot.discardChoice(this, p, count)) {
            move(c, Zone.graveyard);
            log(GameEvent('discarded', player: p, object: c));
          }
        }
        return true;
      case SearchBasicLand x:
        final ids = targets(x.target, '$srcName: whose library');
        if (ids == null) return false;
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          final want = Bot.preferredBasicLand(this, p);
          final lib = state.players[p].library;
          ObjectID? found;
          for (final l in lib) {
            final c = card(l);
            if (c != null && c.isBasicLand && (want == null || c.name == want)) {
              found = l;
              break;
            }
          }
          found ??= lib.where((l) => card(l)?.isBasicLand == true).firstOrNull;
          if (found != null) {
            log(GameEvent('searched', player: p, object: found));
            putCard(found, x.destination, p);
          } else {
            log(GameEvent('searched', player: p));
          }
          state.rng.shuffle(state.players[p].library);
        }
        return true;
      case Sacrifice x:
        final ids = targets(x.target, '$srcName: who sacrifices');
        if (ids == null) return false;
        if (x.filter.kind == FilterKind.token && x.target == Target.you && source != null) {
          final s = state.objects[source];
          if (s != null && s.cardID.isNotEmpty && !s.isToken && x.filter == Filter(FilterKind.token)) {
            dies(source);
            return true;
          }
        }
        var any = false;
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          final candidates = state.permanentsOf(p).where((o) => matches(x.filter, o.id, p, source)).map((o) => o.id).toList();
          if (candidates.isEmpty) continue;
          if (!state.players[p].isBot && candidates.length > 1) {
            state.pending = PendingDecision(
              player: p,
              decision: ChooseSacrificeDecision('$srcName: choose what to sacrifice', candidates),
              resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.sacrifice, sacrificeFilter: x.filter),
            );
            remaining.clear();
            return true;
          }
          final chosen = candidates.length == 1 ? candidates[0] : Bot.sacrificeChoice(this, candidates);
          ctx.sacrificedSubtypes.addAll(characteristics(chosen).subtypes);
          dies(chosen);
          any = true;
        }
        return any;
      case GrantKeyword x:
        final ids = targets(x.target, '$srcName: choose a creature');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o != null && o.zone == Zone.battlefield) o.untilEndOfTurn.add(KeywordEffect(x.keyword));
        }
        return ids.isNotEmpty;
      case CantBlock x:
        final ids = targets(x.target, '$srcName: choose a creature');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o != null && o.zone == Zone.battlefield) o.untilEndOfTurn.add(const CantBlockEffect());
        }
        return ids.isNotEmpty;
      case ReturnFromGraveyard x:
        final filter = x.filter.copy();
        final candidates = legalTargets(filter, controller, source);
        if (candidates.isEmpty) return false;
        ObjectID? chosen = ctx.targets.where(candidates.contains).firstOrNull;
        if (chosen != null) ctx.targets.remove(chosen);
        if (chosen == null) {
          if (state.players[controller].isBot || candidates.length == 1) {
            chosen = Bot.bestCard(this, candidates);
          } else {
            state.pending = PendingDecision(
              player: controller,
              decision: ChooseTargetsDecision(prompt: '$srcName: choose a card in your graveyard', filter: filter, count: 1, optional: false, candidates: candidates),
              resume: Resume(source: source, controller: controller, effects: [e, ...remaining], context: ctx, kind: ResumeKind.targets),
            );
            remaining.clear();
            return true;
          }
        }
        if (chosen == null) return false;
        final newController = x.underOwnersControl ? state.objects[chosen]!.owner : controller;
        putCard(chosen, x.destination, newController, counter: x.counter);
        ctx.lastTouched = chosen;
        return true;
      case Fight x:
        if (source == null) return false;
        final ids = targets(x.target, '$srcName: choose what to fight');
        if (ids == null || ids.isEmpty) return false;
        fight(source, ids.first);
        return true;
      case FightBetween x:
        final first = targets(x.a, '$srcName: choose your creature');
        if (first == null || first.isEmpty) return false;
        final second = targets(x.b, '$srcName: choose the creature it fights');
        if (second == null || second.isEmpty) return false;
        fight(first.first, second.first);
        return true;
      case Bite x:
        if (source == null) return false;
        final ids = targets(x.target, '$srcName: choose what to bite');
        if (ids == null || ids.isEmpty) return false;
        dealDamage(characteristics(source).power, ids.first, source);
        return true;
      case Explore x:
        final ids = targets(x.target, '$srcName: choose a creature to explore');
        if (ids == null) return false;
        for (final id in ids) {
          if (state.objects[id]?.zone != Zone.battlefield) continue;
          final lib = state.players[controller].library;
          if (lib.isEmpty) continue;
          final top = lib.first;
          if (card(top)?.isLand == true) {
            move(top, Zone.hand);
            log(GameEvent('explored', object: id, amount: 1));
          } else {
            addCounters(CounterKind.plusOne, 1, id);
            log(GameEvent('explored', object: id, amount: 0));
            if (state.players[controller].isBot) {
              if (Bot.exploreToGraveyard(this, top, controller)) move(top, Zone.graveyard);
            } else {
              state.pending = PendingDecision(
                player: controller,
                decision: ExploreDecision(top, id),
                resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.explore),
              );
              remaining.clear();
              return true;
            }
          }
        }
        return true;
      case AddMana _:
        return false;
      case DoubleLife _:
        changeLife(controller, state.players[controller].life);
        return true;
      case NoMaxHandSize _:
        state.players[controller].noMaxHandSizeUntilNextTurn = true;
        return true;
      case PutLandFromHand x:
        final land = state.players[controller].hand.where((id) => card(id)?.isLand == true).firstOrNull;
        if (land == null) return false;
        move(land, Zone.battlefield, controller: controller, tapped: x.tapped);
        enteredBattlefield(land, untapped: !x.tapped);
        for (final o in state.permanentsOf(controller)) {
          if (o.id != land) fireTriggers(SimpleTrigger.landfall, o.id, touched: land);
        }
        return true;
      case Modal x:
        final src = source == null ? null : state.objects[source];
        final allowed = [
          for (var i = 0; i < x.modes.length; i++)
            if (!x.unchosenOnly || !(src?.usedModes.contains(i) ?? false)) i,
        ];
        if (allowed.isEmpty) return false;
        faceDilemma(controller);
        final many = x.oneOrMoreIfHandEmpty && state.players[controller].hand.isEmpty;
        String label(int i) => '${i < x.labels.length ? '${x.labels[i]}: ' : ''}${describeEffects(x.modes[i])}';
        if (state.players[controller].isBot) {
          final picks = many
              ? allowed
              : [
                  Bot.chooseMode(this, [for (final i in allowed) x.modes[i]], controller, source),
                ].map((j) => allowed[j]).toList();
          for (final i in picks.reversed) {
            remaining.insertAll(0, x.modes[i]);
          }
          if (x.unchosenOnly) src?.usedModes.addAll(picks);
          return true;
        }
        if (allowed.length == 1 && !many) {
          remaining.insertAll(0, x.modes[allowed[0]]);
          if (x.unchosenOnly) src?.usedModes.add(allowed[0]);
          return true;
        }
        if (many) {
          state.pending = PendingDecision(
            player: controller,
            decision: ChooseModesDecision('$srcName: choose one or more', [for (final i in allowed) label(i)], min: 1, max: allowed.length),
            resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseModes, modes: [for (final i in allowed) x.modes[i]]),
          );
        } else {
          state.pending = PendingDecision(
            player: controller,
            decision: ChooseModeDecision('$srcName: choose one', [for (final i in allowed) label(i)]),
            resume: Resume(
              source: source,
              controller: controller,
              effects: List.of(remaining),
              context: ctx,
              kind: ResumeKind.mode,
              modes: [for (final i in allowed) x.modes[i]],
              cards: x.unchosenOnly ? allowed : const [],
            ),
          );
        }
        remaining.clear();
        return true;
      case Optional x:
        if (state.players[controller].isBot) {
          if (Bot.wantsOptional(this, x.effects, controller, source)) {
            remaining.insertAll(0, x.effects);
            return true;
          }
          return false;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseOptionalDecision('$srcName: ${describeEffects(x.effects)}?'),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.optional, optionalEffects: x.effects),
        );
        remaining.clear();
        return true;
      case IfDidPrevious x:
        if (ctx.previousHappened) remaining.insertAll(0, x.effects);
        return ctx.previousHappened;
      case KickedInstead _:
        return false;
      case Conditional x:
        var holds = conditionHolds(x, source, controller, ctx);
        if (x.negate) holds = !holds;
        if (holds) {
          remaining.insertAll(0, x.effects);
        } else if (x.otherwise.isNotEmpty) {
          remaining.insertAll(0, x.otherwise);
        }
        return holds;
      case GainControl x:
        final ids = targets(x.target, '$srcName: choose what to take');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield || o.controller == controller) continue;
          final previous = o.controller;
          changeControl(id, controller);
          if (x.untilEndOfTurn) o.controlRevertsTo = previous;
        }
        return ids.isNotEmpty;
      case SacrificeAtEndOfTurn x:
        final ids = targets(x.target, '');
        if (ids == null) return false;
        for (final id in ids) {
          state.objects[id]?.sacrificeAtEnd = true;
        }
        return true;
      case Assimilate x:
        final candidates = legalTargets(x.filter, controller, source);
        if (candidates.isEmpty) return false;
        ObjectID? chosen = ctx.targets.where(candidates.contains).firstOrNull;
        if (chosen != null) ctx.targets.remove(chosen);
        if (chosen == null) {
          if (state.players[controller].isBot || candidates.length == 1) {
            chosen = Bot.bestCard(this, candidates);
          } else {
            state.pending = PendingDecision(
              player: controller,
              decision: ChooseTargetsDecision(prompt: '$srcName: choose a creature card to assimilate', filter: x.filter, count: 1, optional: false, candidates: candidates),
              resume: Resume(source: source, controller: controller, effects: [e, ...remaining], context: ctx, kind: ResumeKind.targets),
            );
            remaining.clear();
            return true;
          }
        }
        if (chosen == null) return false;
        assimilate(chosen, controller);
        return true;
      case AssimilateFromLibrary x:
        final ids = targets(x.target, '$srcName: choose an opponent');
        if (ids == null || ids.isEmpty) return false;
        final p = EffectContext.playerFromObject(ids.first);
        if (p == null) return false;
        final exiled = <ObjectID>[];
        ObjectID? found;
        while (state.players[p].library.isNotEmpty) {
          final top = state.players[p].library.first;
          move(top, Zone.exile);
          if (card(top)?.isCreature == true) {
            found = top;
            break;
          }
          exiled.add(top);
        }
        if (found != null) assimilate(found, controller);
        state.rng.shuffle(exiled);
        for (final id in exiled) {
          move(id, Zone.library, toBottom: true);
        }
        return found != null;
      case AssimilateExiledOrExile x:
        if (source == null) return false;
        final s = state.objects[source];
        final exiledCreatures = (s?.exiledWithThis ?? const []).where((id) => state.objects[id]?.zone == Zone.exile && card(id)?.isCreature == true).toList();
        if (exiledCreatures.isNotEmpty) {
          final pick = exiledCreatures.first;
          s!.exiledWithThis.remove(pick);
          assimilate(pick, controller);
          return true;
        }
        final ids = targets(x.target, '$srcName: choose a creature to exile');
        if (ids == null) return false;
        for (final id in ids) {
          if (state.objects[id]?.zone != Zone.battlefield) continue;
          move(id, Zone.exile);
          log(GameEvent('exiled', object: id));
          state.objects[source]?.exiledWithThis.add(id);
        }
        return ids.isNotEmpty;
      case Discover x:
        final exiled = <ObjectID>[];
        ObjectID? found;
        while (state.players[controller].library.isNotEmpty) {
          final top = state.players[controller].library.first;
          move(top, Zone.exile);
          final c = card(top);
          if (c != null && !c.isLand && c.manaValue <= x.n) {
            found = top;
            break;
          }
          exiled.add(top);
        }
        state.rng.shuffle(exiled);
        for (final id in exiled) {
          move(id, Zone.library, toBottom: true);
        }
        if (found == null) return false;
        playFree(found, controller);
        return true;
      case PayLife x:
        if (state.players[controller].life > x.n) {
          changeLife(controller, -x.n);
          return true;
        }
        return false;
      case PayMana x:
        final plan = manaPlan(x.cost, controller);
        if (plan == null) return false;
        _payMana(plan);
        return true;
      case CounterSpell x:
        final ids = targets(x.target, '$srcName: choose a spell to counter');
        if (ids == null) return false;
        var any = false;
        for (final id in ids) {
          final item = state.stack.where((s) => s.id == id).firstOrNull;
          if (item == null) continue;
          final cost = x.unlessPays;
          if (cost != null && canPay(cost, item.controller)) {
            if (state.players[item.controller].isBot) {
              _payMana(manaPlan(cost, item.controller)!);
              log(GameEvent('paid', player: item.controller, text: '$cost'));
              continue;
            }
            state.pending = PendingDecision(
              player: item.controller,
              decision: PayOrCounterDecision('$srcName: pay $cost or ${name(id)} is countered', cost, id),
              resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.payOrCounter, subject: id),
            );
            remaining.clear();
            return true;
          }
          any = counterSpell(id) || any;
        }
        return any;
      case CopyToken x:
        final ids = targets(x.target, '$srcName: choose what to copy');
        if (ids == null) return false;
        final originals = <ObjectID>[];
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (x.eachCreatureOfTarget && p != null) {
            originals.addAll(state.permanentsOf(p).where((o) => characteristics(o.id).isCreature).map((o) => o.id));
          } else {
            originals.add(id);
          }
        }
        for (final id in originals) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield) continue;
          final copy = copyAsToken(id, controller, extra: x.extra, nonLegendary: x.nonLegendary, tapped: x.tapped);
          final c = state.objects[copy];
          if (c == null) continue;
          if (x.hasteUntilEndOfTurn) c.untilEndOfTurn.add(const KeywordEffect(Keyword.haste));
          if (x.sacrificeAtEnd) c.sacrificeAtEnd = true;
          ctx.lastTouched = copy;
        }
        return originals.isNotEmpty;
      case LookAtTop x:
        final n = amount(x.n, controller, source, ctx);
        final looked = x.fromAffected ? ctx.affected.where((id) => state.objects[id]?.zone == Zone.graveyard).toList() : state.players[controller].library.take(n).toList();
        if (looked.isEmpty) return false;
        final candidates = looked.where((id) => cardMatches(x.pick, id)).toList();
        final max = x.pickCount < candidates.length ? x.pickCount : candidates.length;
        if (candidates.isEmpty || state.players[controller].isBot) {
          final picks = (List.of(candidates)..sort((a, b) => Bot.cardValue(b, this) - Bot.cardValue(a, this))).take(max).toList();
          finishLookAtTop(x, picks, looked, controller);
          return picks.isNotEmpty;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseCardsDecision('$srcName: choose ${x.pickCount == 1 ? 'a card' : 'up to ${x.pickCount} cards'}', candidates, min: x.optional ? 0 : max, max: max),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseCards, effect: x, cards: looked),
        );
        remaining.clear();
        return true;
      case ExileTopPlayable x:
        final n = amount(x.n, controller, source, ctx);
        final until = x.untilNextTurn ? (state.activePlayer == controller ? state.turn + 2 : state.turn + 1) : state.turn;
        final exiled = <ObjectID>[];
        for (var i = 0; i < n; i++) {
          final top = state.players[controller].library.firstOrNull;
          if (top == null) break;
          move(top, Zone.exile);
          final o = state.objects[top]!;
          o.playableBy = controller;
          o.playableUntilTurn = until;
          exiled.add(top);
          log(GameEvent('exiledPlayable', player: controller, object: top));
        }
        ctx.affected = exiled;
        return exiled.isNotEmpty;
      case ExileTopPutPermanents x:
        final exiled = <ObjectID>[];
        for (var i = 0; i < x.n; i++) {
          final top = state.players[controller].library.firstOrNull;
          if (top == null) break;
          move(top, Zone.exile);
          exiled.add(top);
        }
        for (final id in exiled) {
          if (card(id)?.isPermanent == true) putCard(id, LibraryDestination.battlefield, controller);
        }
        return exiled.isNotEmpty;
      case RevealTopCastFree x:
        final top = state.players[controller].library.firstOrNull;
        if (top == null) return false;
        final c = card(top);
        log(GameEvent('revealed', player: controller, object: top));
        if (c != null) {
          if (c.isLand) {
            putCard(top, LibraryDestination.battlefieldTapped, controller);
          } else if (c.manaValue <= amount(x.max, controller, source, ctx)) {
            castFree(top, controller);
          }
        }
        if (state.players[controller].library.firstOrNull == top) _draw(controller, 1);
        return true;
      case SearchCard x:
        final pool = <ObjectID>[...state.players[controller].library, if (x.alsoGraveyard) ...state.players[controller].graveyard];
        final candidates = pool.where((id) => cardMatches(x.pick, id)).toList();
        if (candidates.isEmpty) {
          state.rng.shuffle(state.players[controller].library);
          return false;
        }
        final names = candidates.map((id) => card(id)?.name).toSet();
        if (state.players[controller].isBot || names.length == 1) {
          finishSearch(x, [Bot.bestCard(this, candidates)!], controller);
          return true;
        }
        final shown = <ObjectID>[];
        final seen = <String?>{};
        for (final id in candidates) {
          if (seen.add('${card(id)?.name}|${state.objects[id]?.zone}')) shown.add(id);
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseCardsDecision('$srcName: choose a card', shown, min: 1, max: 1),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseCards, effect: x),
        );
        remaining.clear();
        return true;
      case HandChoice x:
        final ids = targets(x.target, '$srcName: choose an opponent');
        if (ids == null || ids.isEmpty) return false;
        final p = EffectContext.playerFromObject(ids.first);
        if (p == null) return false;
        final hand = List.of(state.players[p].hand);
        log(GameEvent('lookedAtHand', player: controller, other: ids.first, ids: hand));
        if (x.lookOnly) return true;
        final candidates = hand.where((id) => cardMatches(x.pick, id)).toList();
        if (candidates.isEmpty) return false;
        if (state.players[controller].isBot) {
          finishHandChoice(x, [Bot.bestCard(this, candidates)!], p);
          return true;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseCardsDecision("$srcName: choose a card from ${state.players[p].name}'s hand", candidates, min: 0, max: 1),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseCards, effect: x, subject: ids.first),
        );
        remaining.clear();
        return true;
      case PumpAmount x:
        final ids = targets(x.target, '$srcName: choose a creature');
        if (ids == null) return false;
        final pw = amount(x.power, controller, source, ctx), th = amount(x.toughness, controller, source, ctx);
        for (final id in ids) {
          final o = state.objects[id];
          if (o != null && o.zone == Zone.battlefield) o.untilEndOfTurn.add(PumpEffect(pw, th));
        }
        return ids.isNotEmpty;
      case PumpUntilYourNextTurn x:
        final ids = targets(x.target, '$srcName: choose a creature');
        if (ids == null) return false;
        for (final id in ids) {
          state.objects[id]?.lasting.add(LastingEffect(PumpEffect(x.power, x.toughness), controller));
        }
        return ids.isNotEmpty;
      case BecomeCopy x:
        if (source == null) return false;
        final ids = targets(x.target, '$srcName: choose what to copy');
        if (ids == null || ids.isEmpty) return false;
        final target = state.objects[ids.first];
        final me = state.objects[source];
        if (target == null || me == null || target.cardID.isEmpty) return false;
        me.copiedCardID = target.copiedCardID ?? target.cardID;
        me.nonLegendary = x.nonLegendary;
        if (x.copyCounters) {
          for (final e in target.counters.entries) {
            addCounters(e.key, e.value, source);
          }
        }
        log(GameEvent('becameCopy', object: source, other: ids.first));
        return true;
      case ChooseNumber x:
        if (source == null) return false;
        if (state.players[controller].isBot) {
          state.objects[source]?.chosenNumber = Bot.chooseNumber(this, controller, x.min, x.max);
          log(GameEvent('chose', object: source, amount: state.objects[source]?.chosenNumber));
          return true;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseModeDecision('$srcName: choose a number', [for (var i = x.min; i <= x.max; i++) '$i']),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseNumber, subject: x.min),
        );
        remaining.clear();
        return true;
      case EnterTriggers x:
        if (source != null) enterTriggers(source, untapped: x.untapped);
        return true;
      case TopOrBottom x:
        final ids = targets(x.target, '$srcName: choose a creature or Spacecraft');
        if (ids == null || ids.isEmpty) return false;
        final o = state.objects[ids.first];
        if (o == null || o.zone != Zone.battlefield) return false;
        if (state.players[o.owner].isBot) {
          move(ids.first, Zone.library, toBottom: !(o.owner == controller));
          log(GameEvent('toLibrary', object: ids.first, amount: o.owner == controller ? 0 : 1));
          return true;
        }
        state.pending = PendingDecision(
          player: o.owner,
          decision: ChooseModeDecision('Put ${name(ids.first)} on top or bottom of your library?', const ['Top', 'Bottom']),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.topOrBottom, subject: ids.first),
        );
        remaining.clear();
        return true;
      case WinGame _:
        for (final p in state.players) {
          if (p.id != controller) _lose(p.id, '${state.players[controller].name} wins with $srcName');
        }
        return true;
      case LoseGame _:
        _lose(controller, '${state.players[controller].name} loses to $srcName');
        return true;
      case Delayed x:
        final object = ctx.lastTouched;
        if (object == null) return false;
        state.delayed.add(
          DelayedTrigger(
            event: x.event == DelayedEventKind.lastTouchedDies ? DelayedEvent.dies : DelayedEvent.nextCombat,
            object: object,
            controller: controller,
            source: source ?? object,
            effects: x.effects,
            turn: state.turn,
          ),
        );
        return true;
      case BecomeType x:
        final ids = targets(x.target, '$srcName: choose a creature');
        if (ids == null) return false;
        for (final id in ids) {
          state.objects[id]?.untilEndOfTurn.add(TypeEffect(x.subtype, replace: x.replace));
        }
        return ids.isNotEmpty;
      case PhaseOut x:
        final ids = targets(x.target, '');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield) continue;
          o.phasedOut = true;
          for (final a in state.allPermanents) {
            if (a.attachedTo == id) a.phasedOut = true;
          }
          log(GameEvent('phasedOut', object: id));
        }
        return ids.isNotEmpty;
      case CopyThisSpell _:
        if (source == null) return false;
        final c = card(source);
        if (c == null) return false;
        final copy = newObject(
          cardID: c.id,
          owner: controller,
          zone: Zone.battlefield,
          token: TokenSpec(name: c.name, isArtifact: c.isArtifact, isCreature: c.isCreature, isLegendary: c.isLegendary),
        );
        state.objects[copy]!.controller = controller;
        state.objects[copy]!.enteredTurn = state.turn;
        state.players[controller].battlefield.add(copy);
        log(GameEvent('tokenCreated', player: controller, object: copy));
        enteredBattlefield(copy, untapped: true);
        return true;
      case DoubleCounters x:
        final ids = targets(x.target, '');
        if (ids == null) return false;
        for (final id in ids) {
          final n = state.objects[id]?.plusOneCounters ?? 0;
          if (n > 0) addCounters(CounterKind.plusOne, n, id);
        }
        return ids.isNotEmpty;
      case EachBites x:
        final biters = targets(x.biters, '$srcName: choose your creatures');
        if (biters == null || biters.isEmpty) return false;
        final victims = targets(x.target, '$srcName: choose the creature they damage');
        if (victims == null || victims.isEmpty) return false;
        for (final b in biters) {
          if (state.objects[b]?.zone == Zone.battlefield) dealDamage(characteristics(b).power, victims.first, b);
        }
        return true;
      case SetBasePT x:
        final me = source == null ? null : state.objects[source];
        if (me == null) return false;
        me.basePowerOverride = x.power;
        me.baseToughnessOverride = x.toughness;
        return true;
      case AddManaOfChosenColor x:
        final n = amount(x.amount, controller, source, ctx);
        if (n <= 0) return false;
        if (state.players[controller].isBot) {
          final color = Bot.preferredColor(this, controller);
          final pool = state.players[controller].manaPool;
          pool[color.symbol] = (pool[color.symbol] ?? 0) + n;
          return true;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseModeDecision('$srcName: choose a color for $n mana', [for (final c in ManaColor.values) c.label]),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseColor, subject: n),
        );
        remaining.clear();
        return true;
      case PeaceOffer _:
        final active = state.activePlayer;
        if (state.players[active].isBot) {
          if (Bot.acceptsPeace(this, active)) remaining.insert(0, PeaceAccepted(active));
          return true;
        }
        state.pending = PendingDecision(
          player: active,
          decision: ChooseOptionalDecision("$srcName: draw a card? If you do, you can't attack this turn."),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.optional, optionalEffects: [PeaceAccepted(active)]),
        );
        remaining.clear();
        return true;
      case PeaceAccepted x:
        _draw(x.player, 1);
        state.players[x.player].cantAttackThisTurn = true;
        if (source != null) addCounters(CounterKind.peace, 1, source);
        return true;
      case RemoveCounters x:
        final ids = targets(x.target, '');
        if (ids == null) return false;
        for (final id in ids) {
          state.objects[id]?.counters.remove(x.kind);
        }
        return ids.isNotEmpty;
      case DestroyNonlandWithManaValue x:
        final n = amount(x.amount, controller, source, ctx);
        for (final o in state.allPermanents) {
          if (characteristics(o.id).isLand) continue;
          if ((cardOf(o)?.manaValue ?? 0) == n) destroy(o.id);
        }
        return true;
      case QStackTheDeck _:
        final lib = state.players[controller].library;
        state.rng.shuffle(lib);
        while (lib.isNotEmpty) {
          final top = lib.first;
          move(top, Zone.exile);
          if (card(top)?.isLand != true) {
            state.objects[top]!.qCopyable = true;
            log(GameEvent('exiledPlayable', player: controller, object: top));
            break;
          }
        }
        return true;
      case ExileTopCastFree x:
        final max = amount(x.maxManaValue, controller, source, ctx);
        final exiled = <ObjectID>[];
        for (var i = 0; i < x.n; i++) {
          final top = state.players[controller].library.firstOrNull;
          if (top == null) break;
          move(top, Zone.exile);
          exiled.add(top);
        }
        for (final id in exiled) {
          final c = card(id);
          if (c != null && !c.isLand && c.manaValue <= max) castFree(id, controller);
        }
        return exiled.isNotEmpty;
      case ExtraCountersThisTurn _:
        state.players[controller].extraCounterThisTurn = true;
        return true;
      case ExileUntilLeaves x:
        final ids = targets(x.target, '$srcName: choose what to exile');
        if (ids == null) return false;
        for (final id in ids) {
          if (state.objects[id]?.zone != Zone.battlefield) continue;
          move(id, Zone.exile);
          log(GameEvent('exiled', object: id));
          if (source != null && state.objects[source]?.zone == Zone.battlefield) state.objects[source]!.exiledUntilLeaves.add(id);
        }
        return ids.isNotEmpty;
      case PutLandsFromHand x:
        final n = amount(x.amount, controller, source, ctx);
        final lands = state.players[controller].hand.where((id) => card(id)?.isLand == true).take(n).toList();
        for (final land in lands) {
          putCard(land, x.tapped ? LibraryDestination.battlefieldTapped : LibraryDestination.battlefield, controller);
        }
        return lands.isNotEmpty;
      case ExileFromHand _:
        final hand = state.players[controller].hand;
        if (hand.isEmpty) return false;
        if (state.players[controller].isBot) {
          final pick = Bot.discardChoice(this, controller, 1).first;
          move(pick, Zone.exile);
          log(GameEvent('exiled', object: pick));
          return true;
        }
        state.pending = PendingDecision(
          player: controller,
          decision: ChooseCardsDecision('$srcName: exile a card from your hand?', List.of(hand), min: 0, max: 1),
          resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.chooseCards, effect: e),
        );
        remaining.clear();
        return true;
      case ExileIfDiesThisTurn x:
        final ids = targets(x.target, '');
        if (ids == null) return false;
        for (final id in ids) {
          state.objects[id]?.exileIfDiesThisTurn = true;
        }
        return ids.isNotEmpty;
    }
  }

  /// Puts a card from wherever it is into a zone, with what entering involves.
  void putCard(ObjectID id, LibraryDestination dest, PlayerID controller, {CounterKind? counter}) {
    final c = card(id);
    switch (dest) {
      case LibraryDestination.hand:
        move(id, Zone.hand);
      case LibraryDestination.battlefield:
      case LibraryDestination.battlefieldTapped:
        final tapped = dest == LibraryDestination.battlefieldTapped;
        move(id, Zone.battlefield, controller: controller, tapped: tapped);
        if (counter != null) addCounters(counter, 1, id);
        if (c != null && db.parsed(c).isAura) {
          final host = legalTargets(Filter.creature, controller, id).firstOrNull;
          if (host == null) {
            move(id, Zone.graveyard);
            return;
          }
          state.objects[id]!.attachedTo = host;
        }
        enteredBattlefield(id, untapped: !tapped);
        if (c?.isLand == true) {
          for (final o in state.permanentsOf(controller)) {
            if (o.id != id) fireTriggers(SimpleTrigger.landfall, o.id, touched: id);
          }
        }
      case LibraryDestination.libraryTop:
        move(id, Zone.library);
      case LibraryDestination.libraryBottom:
        move(id, Zone.library, toBottom: true);
      case LibraryDestination.graveyard:
        move(id, Zone.graveyard);
    }
  }

  /// Whether a card (in any zone) is the kind a search or look may pick.
  bool cardMatches(CardPred pred, ObjectID id) {
    final c = card(id);
    if (c == null) return false;
    bool test(CardPred p) {
      if (p.names.isNotEmpty && !p.names.contains(c.name)) return false;
      if (p.basicLand && !c.isBasicLand) return false;
      for (final t in p.types) {
        if (!c.types.contains(t) && !c.subtypes.contains(t)) return false;
      }
      for (final t in p.notTypes) {
        if (c.types.contains(t)) return false;
      }
      if (p.subtypes.isNotEmpty && !p.subtypes.any(c.subtypes.contains)) return false;
      if (p.maxManaValue != null && c.manaValue > p.maxManaValue!) return false;
      if (p.permanent && !c.isPermanent) return false;
      if (p.nonland && c.isLand) return false;
      return true;
    }

    if (test(pred)) return true;
    final alt = pred.or;
    return alt != null && test(alt);
  }

  void finishLookAtTop(LookAtTop x, List<ObjectID> picks, List<ObjectID> looked, PlayerID controller) {
    for (final id in picks) {
      log(GameEvent('revealed', player: controller, object: id));
      putCard(id, x.destination, controller);
    }
    if (x.fromAffected) return;
    final rest = looked.where((id) => !picks.contains(id) && state.objects[id]?.zone == Zone.library).toList();
    switch (x.rest) {
      case RestDestination.bottomRandom:
        state.rng.shuffle(rest);
        for (final id in rest) {
          move(id, Zone.library, toBottom: true);
        }
      case RestDestination.bottom:
        for (final id in rest) {
          move(id, Zone.library, toBottom: true);
        }
      case RestDestination.graveyard:
        for (final id in rest) {
          move(id, Zone.graveyard);
        }
      case RestDestination.top:
        break;
    }
  }

  void finishSearch(SearchCard x, List<ObjectID> picks, PlayerID controller) {
    for (final id in picks) {
      log(GameEvent('searched', player: controller, object: id));
      putCard(id, x.destination, controller, counter: null);
      if (x.counter != null && x.counterAmount > 0) addCounters(x.counter!, x.counterAmount, id);
    }
    state.rng.shuffle(state.players[controller].library);
  }

  void finishHandChoice(HandChoice x, List<ObjectID> picks, PlayerID owner) {
    for (final id in picks) {
      move(id, Zone.exile);
      log(GameEvent('exiled', object: id));
      if (x.ownerMayPlayForMore > 0) {
        final o = state.objects[id]!;
        o.playableBy = owner;
        o.playableUntilTurn = 1 << 30;
        o.extraCost = x.ownerMayPlayForMore;
      }
    }
    if (x.drawAfter && picks.isNotEmpty) _draw(owner, 1);
  }

  /// You chose modes for a spell or ability: Seven of Nine's "face a dilemma".
  void faceDilemma(PlayerID p) {
    state.players[p].dilemmasThisTurn++;
    for (final o in state.permanentsOf(p)) {
      fireTriggers(SimpleTrigger.faceDilemma, o.id);
    }
  }

  bool conditionHolds(Conditional x, ObjectID? source, PlayerID controller, EffectContext ctx) {
    switch (x.condition) {
      case Condition.thisIsCreature:
        return source != null && characteristics(source).isCreature;
      case Condition.thisIsNotCreature:
        return source != null && !characteristics(source).isCreature;
      case Condition.lastIsCreature:
        final last = ctx.lastTouched;
        return last != null && state.objects[last]?.zone == Zone.battlefield && characteristics(last).isCreature;
      case Condition.controlPermanentWithCounter:
        return state.permanentsOf(controller).any((o) => o.counters.values.any((n) => n > 0));
      case Condition.selfCountersAtLeast:
        return source != null && (state.objects[source]?.counters[x.counter] ?? 0) >= x.n;
      case Condition.resolvedTimes:
        return ctx.resolution == x.n;
      case Condition.countedAtLeast:
        return ctx.counted >= x.n;
      case Condition.totalPowerAtLeast:
        return state.permanentsOf(controller).where((o) => characteristics(o.id).isCreature).fold<int>(0, (a, o) => a + characteristics(o.id).power.clamp(0, 1 << 20)) >= x.n;
      case Condition.firstSpellThisGame:
        return state.players[controller].spellsCastThisGame <= 1;
      case Condition.differentLandsAtLeast:
        return amount(const Amount.counted(AmountKind.differentlyNamedLands), controller, source, ctx) >= x.n;
      case Condition.lastHasSubtype:
        return ctx.sacrificedSubtypes.contains(x.subtype);
      case Condition.handEmpty:
        return state.players[controller].hand.isEmpty;
    }
  }

  /// A token that copies a permanent.
  ObjectID copyAsToken(ObjectID id, PlayerID controller, {List<Keyword> extra = const [], bool nonLegendary = false, bool tapped = false}) {
    final o = state.objects[id]!;
    final spec = (o.token ?? TokenSpec(name: name(id), isLegendary: isLegendary(o))).copyWith();
    spec.keywords.addAll(extra);
    final copy = newObject(cardID: o.copiedCardID ?? o.cardID, owner: controller, zone: Zone.battlefield, token: spec);
    final c = state.objects[copy]!;
    c.controller = controller;
    c.enteredTurn = state.turn;
    c.tapped = tapped;
    c.nonLegendary = nonLegendary;
    c.assimilated = o.assimilated;
    state.players[controller].battlefield.add(copy);
    log(GameEvent('tokenCreated', player: controller, object: copy));
    enteredBattlefield(copy, untapped: !tapped);
    return copy;
  }

  /// Casts a card without paying its mana cost, right away (targets chosen as the computer
  /// would for that player when they aren't asked).
  void castFree(ObjectID id, PlayerID p) {
    final c = card(id);
    if (c == null) return;
    final ps = state.players[p];
    ps.spellsCastThisTurn++;
    ps.spellsCastThisGame++;
    if (!c.isCreature) ps.noncreatureSpellsThisTurn++;
    log(GameEvent('cast', player: p, object: id, amount: 0));
    final fromExile = state.objects[id]?.zone == Zone.exile;
    _castTriggers(c, id, p, 0);
    if (c.isPermanent) {
      move(id, Zone.battlefield, controller: p);
      if (db.parsed(c).isAura) {
        final host = legalTargets(Filter.creature, p, id).firstOrNull;
        if (host == null) {
          move(id, Zone.graveyard);
          return;
        }
        state.objects[id]!.attachedTo = host;
      }
      enteredBattlefield(id, untapped: true, castBy: p);
    } else {
      final parsed = db.parsed(c);
      final ctx = EffectContext();
      var effects = parsed.spellEffects;
      final modal = effects.whereType<Modal>().firstOrNull;
      int? mode;
      if (modal != null) {
        mode = Bot.chooseMode(this, modal.modes, p, id);
        final mi = effects.indexOf(modal);
        effects = [...effects.sublist(0, mi), ...modal.modes[mode], ...effects.sublist(mi + 1)];
      }
      for (final r in targetRequirementsForCard(c, mode)) {
        final legal = legalTargets(r.filter, p, id);
        ctx.targets.addAll(Bot.chooseTargets(this, r.filter, r.count, true, legal, p, null));
      }
      move(id, Zone.stack, controller: p);
      resolve(effects, source: id, controller: p, context: ctx);
      if (state.objects[id]?.zone == Zone.stack) move(id, Zone.graveyard);
    }
    if (fromExile) {
      for (final other in state.permanentsOf(p)) {
        fireTriggers(SimpleTrigger.playFromExile, other.id, touched: id);
      }
    }
  }

  ObjectID createToken(TokenSpec spec, PlayerID p, {bool tapped = false}) {
    final id = newObject(cardID: '', owner: p, zone: Zone.battlefield, token: spec.copyWith());
    state.objects[id]!.controller = p;
    state.objects[id]!.enteredTurn = state.turn;
    state.objects[id]!.tapped = tapped;
    state.players[p].battlefield.add(id);
    log(GameEvent('tokenCreated', player: p, object: id));
    enteredBattlefield(id, untapped: !tapped);
    return id;
  }

  void fight(ObjectID a, ObjectID b) {
    if (state.objects[a]?.zone != Zone.battlefield || state.objects[b]?.zone != Zone.battlefield) return;
    final pa = characteristics(a).power, pb = characteristics(b).power;
    dealDamage(pa, b, a);
    dealDamage(pb, a, b);
    log(GameEvent('fought', object: a, other: b));
  }

  void assimilate(ObjectID id, PlayerID p) {
    move(id, Zone.battlefield, controller: p);
    state.objects[id]!.assimilated = true;
    addCounters(CounterKind.plusOne, 1, id);
    log(GameEvent('assimilated', object: id, player: p));
    enteredBattlefield(id, untapped: true);
  }

  /// Discover and similar: cast the card without paying its mana cost.
  void playFree(ObjectID id, PlayerID p) => castFree(id, p);

  void _advanceSaga(ObjectID id) {
    final o = state.objects[id];
    final parsed = o == null ? null : parsedOf(o);
    if (o == null || o.zone != Zone.battlefield || parsed == null) return;
    final chapters = parsed.sagaChapters ?? const <List<Effect>>[];
    addCounters(CounterKind.lore, 1, id);
    final n = state.objects[id]?.counters[CounterKind.lore] ?? 1;
    log(GameEvent('sagaChapter', object: id, amount: n));
    if (n - 1 < chapters.length) {
      final ctx = EffectContext()..lastTouched = id;
      resolve(chapters[n - 1], source: id, controller: o.controller, context: ctx);
    }
    final last = chapters.length > 3 ? chapters.length : 3;
    if (n >= last && state.pending == null) {
      dies(id);
    }
  }

  void finishSurveil(PlayerID p, List<ObjectID> toGraveyard, List<ObjectID> cards) {
    for (final id in cards) {
      if (toGraveyard.contains(id)) move(id, Zone.graveyard);
    }
    log(GameEvent('surveilled', player: p, amount: toGraveyard.length, other: cards.length - toGraveyard.length));
  }

  void finishScry(PlayerID p, List<ObjectID> toBottom, List<ObjectID> cards) {
    for (final id in cards) {
      if (toBottom.contains(id)) move(id, Zone.library, toBottom: true);
    }
  }

  /// A short description of effects, for prompts.
  String describeEffects(List<Effect> effects) => effects.map(describeEffect).join('; ');

  String describeEffect(Effect e) {
    String amt(Amount a) => a.kind == AmountKind.fixed ? '${a.n}' : 'X';
    switch (e) {
      case Damage x:
        return 'deal ${amt(x.amount)} damage';
      case Draw x:
        return 'draw ${amt(x.amount)}';
      case GainLife x:
        return 'gain ${amt(x.amount)} life';
      case LoseLife x:
        return 'lose ${amt(x.amount)} life';
      case Destroy _:
        return 'destroy';
      case Exile _:
        return 'exile';
      case Bounce _:
        return 'return to hand';
      case Tap _:
        return 'tap';
      case Untap _:
        return 'untap';
      case Pump x:
        return '${x.power >= 0 ? '+' : ''}${x.power}/${x.toughness >= 0 ? '+' : ''}${x.toughness} until end of turn';
      case AddCounters x:
        return 'put ${amt(x.amount)} ${x.kind.text} counter(s)';
      case CreateTokens x:
        return 'create ${amt(x.amount)} ${x.spec.name.isEmpty ? 'token' : x.spec.name}';
      case Surveil x:
        return 'surveil ${x.n}';
      case Scry x:
        return 'scry ${x.n}';
      case Mill x:
        return 'mill ${x.n}';
      case Discard x:
        return 'discard ${x.n}';
      case SearchBasicLand _:
        return 'search for a basic land';
      case Sacrifice _:
        return 'sacrifice';
      case GrantKeyword x:
        return 'gain ${x.keyword}';
      case ReturnFromGraveyard _:
        return 'return from graveyard';
      case Fight _:
      case FightBetween _:
        return 'fight';
      case Bite _:
        return 'deal damage equal to power';
      case Explore _:
        return 'explore';
      case AddMana _:
        return 'add mana';
      case DoubleLife _:
        return 'double your life';
      case NoMaxHandSize _:
        return 'no maximum hand size';
      case PutLandFromHand _:
        return 'put a land onto the battlefield';
      case Modal x:
        return x.modes.map(describeEffects).join(' / ');
      case Optional x:
        return 'you may ${describeEffects(x.effects)}';
      case CantBlock _:
        return "can't block";
      case GainControl _:
        return 'gain control';
      case SacrificeAtEndOfTurn _:
        return 'sacrifice at end of turn';
      case KickedInstead x:
        return 'if kicked, ${describeEffects(x.effects)}';
      case IfDidPrevious x:
        return 'if you do, ${describeEffects(x.effects)}';
      case Assimilate _:
      case AssimilateFromLibrary _:
      case AssimilateExiledOrExile _:
        return 'assimilate';
      case Discover x:
        return 'discover ${x.n}';
      case PayLife x:
        return 'pay ${x.n} life';
      case PayMana x:
        return 'pay ${x.cost}';
      case CopyToken _:
        return 'create a copy';
      case CounterSpell x:
        return x.unlessPays == null ? 'counter a spell' : 'counter a spell unless ${x.unlessPays} is paid';
      case LookAtTop x:
        return x.fromAffected ? 'put a card from among them into your hand' : 'look at the top ${amt(x.n)} and take ${x.pickCount == 1 ? 'one' : 'up to ${x.pickCount}'}';
      case ExileTopPlayable x:
        return 'exile the top ${amt(x.n)}, you may play ${x.n == Amount.one ? 'it' : 'them'}';
      case ExileTopPutPermanents x:
        return 'exile the top ${x.n}, put permanents onto the battlefield';
      case RevealTopCastFree _:
        return 'reveal the top card and cast it free';
      case SearchCard _:
        return 'search for a card';
      case HandChoice x:
        return x.lookOnly ? "look at an opponent's hand" : "take a card from an opponent's hand";
      case PumpAmount x:
        return '+${amt(x.power)}/+${amt(x.toughness)} until end of turn';
      case PumpUntilYourNextTurn x:
        return '${x.power}/${x.toughness} until your next turn';
      case BecomeCopy _:
        return 'become a copy';
      case ChooseNumber _:
        return 'choose a number';
      case EnterTriggers _:
        return 'enters';
      case TopOrBottom _:
        return 'put on top or bottom of its library';
      case WinGame _:
        return 'win the game';
      case LoseGame _:
        return 'lose the game';
      case Delayed x:
        return describeEffects(x.effects);
      case BecomeType x:
        return 'becomes a ${x.subtype}';
      case PhaseOut _:
        return 'phase out';
      case CopyThisSpell _:
        return 'copy this spell';
      case DoubleCounters _:
        return 'double +1/+1 counters';
      case EachBites _:
        return 'deal damage equal to power';
      case SetBasePT x:
        return 'become ${x.power}/${x.toughness}';
      case AddManaOfChosenColor _:
        return 'add mana';
      case PeaceOffer _:
        return 'offer peace';
      case PeaceAccepted _:
        return "draw a card and don't attack";
      case RemoveCounters x:
        return 'remove ${x.kind.text} counters';
      case DestroyNonlandWithManaValue _:
        return 'destroy each nonland permanent with that mana value';
      case QStackTheDeck _:
        return 'exile a card to copy';
      case ExileTopCastFree _:
        return 'exile the top cards and cast spells free';
      case ExtraCountersThisTurn _:
        return 'extra counters this turn';
      case ExileUntilLeaves _:
        return 'exile until this leaves';
      case PutLandsFromHand x:
        return 'put up to ${amt(x.amount)} lands onto the battlefield';
      case ExileFromHand _:
        return 'exile a card from your hand';
      case ExileIfDiesThisTurn _:
        return 'exile it if it would die';
      case Conditional x:
        return describeEffects(x.effects);
    }
  }
}
