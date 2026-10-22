part of 'game.dart';

extension GameEffects on Game {
  /// A permanent's own triggers plus the ones statics on the battlefield grant it.
  List<(TriggerEvent, List<Effect>)> grantedAndOwnTriggers(ObjectID id) {
    final o = state.objects[id];
    if (o == null) return const [];
    final out = <(TriggerEvent, List<Effect>)>[];
    final parsed = parsedOf(o);
    if (parsed != null) {
      for (final a in parsed.abilities) {
        if (a is Triggered) out.add((a.event, a.effects));
      }
    }
    for (final other in state.allPermanents) {
      final p = parsedOf(other);
      if (p == null) continue;
      for (final s in p.statics) {
        if (s is GrantTrigger && matches(s.filter, id, other.controller, other.id)) out.add((s.event, s.effects));
      }
    }
    return out;
  }

  void fireTriggers(TriggerEvent event, ObjectID id, {ObjectID? touched}) {
    if (state.objects[id]?.zone != Zone.battlefield) return;
    for (final (e, fx) in grantedAndOwnTriggers(id)) {
      if (e == event) runTrigger(fx, source: id, touched: touched);
    }
  }

  void runTrigger(List<Effect> effects, {required ObjectID source, ObjectID? touched, bool leftBattlefield = false}) {
    final o = state.objects[source];
    if (o == null) return;
    if (!leftBattlefield && o.zone != Zone.battlefield) return;
    log(GameEvent('triggered', object: source, text: name(source)));
    final context = EffectContext()
      ..lastTouched = touched ?? source
      ..triggeringObject = touched;
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
        for (final id in ids) {
          destroy(id);
        }
        return ids.isNotEmpty;
      case Exile x:
        final ids = targets(x.target, '$srcName: choose what to exile');
        if (ids == null) return false;
        for (final id in ids) {
          if (state.objects[id]?.zone != Zone.battlefield) continue;
          move(id, Zone.exile);
          log(GameEvent('exiled', object: id));
          if (source != null) state.objects[source]?.exiledWithThis.add(id);
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
        for (final id in ids) {
          addCounters(x.kind, n, id);
        }
        return ids.isNotEmpty;
      case CreateTokens x:
        final ids = targets(x.target, '$srcName: who gets the tokens');
        if (ids == null) return false;
        final n = amount(x.amount, controller, source, ctx);
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          for (var i = 0; i < n; i++) {
            createToken(x.spec, p);
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
        state.pending = PendingDecision(player: controller, decision: SurveilDecision(top), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.surveil));
        remaining.clear();
        return true;
      case Scry x:
        final top = state.players[controller].library.take(x.n).toList();
        if (top.isEmpty) return false;
        if (state.players[controller].isBot) {
          finishScry(controller, Bot.scry(this, top, controller), top);
          return true;
        }
        state.pending = PendingDecision(player: controller, decision: ScryDecision(top), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.scry));
        remaining.clear();
        return true;
      case Mill x:
        final ids = targets(x.target, '$srcName: who mills');
        if (ids == null) return false;
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          for (var i = 0; i < x.n; i++) {
            final lib = state.players[p].library;
            if (lib.isEmpty) break;
            final top = lib.first;
            move(top, Zone.graveyard);
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
            state.pending = PendingDecision(player: p, decision: DiscardToHandSizeDecision(count), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.none));
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
            switch (x.destination) {
              case LibraryDestination.hand:
                move(found, Zone.hand);
              case LibraryDestination.battlefield:
                move(found, Zone.battlefield, controller: p);
                enteredBattlefield(found, untapped: true);
              case LibraryDestination.battlefieldTapped:
                move(found, Zone.battlefield, controller: p, tapped: true);
                enteredBattlefield(found, untapped: false);
            }
            log(GameEvent('searched', player: p, object: found));
            if (x.destination != LibraryDestination.hand) {
              for (final o in state.permanentsOf(p)) {
                if (o.id != found) fireTriggers(SimpleTrigger.landfall, o.id, touched: found);
              }
            }
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
            move(source, Zone.graveyard);
            log(GameEvent('died', object: source));
            fireDies(source);
            return true;
          }
        }
        var any = false;
        for (final id in ids) {
          final p = EffectContext.playerFromObject(id);
          if (p == null) continue;
          final candidates = state.permanentsOf(p).where((o) => matches(x.filter, o.id, p, null)).map((o) => o.id).toList();
          if (candidates.isEmpty) continue;
          if (!state.players[p].isBot && candidates.length > 1) {
            state.pending = PendingDecision(player: p, decision: ChooseSacrificeDecision('$srcName: choose what to sacrifice', candidates), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.sacrifice, sacrificeFilter: x.filter));
            remaining.clear();
            return true;
          }
          final chosen = candidates.length == 1 ? candidates[0] : Bot.sacrificeChoice(this, candidates);
          move(chosen, Zone.graveyard);
          log(GameEvent('died', object: chosen));
          fireDies(chosen);
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
        final filter = x.filter.copy()..controller = x.filter.controller == Controller.any ? Controller.you : x.filter.controller;
        final candidates = legalTargets(filter, controller, source);
        if (candidates.isEmpty) return false;
        ObjectID? chosen = ctx.targets.where(candidates.contains).firstOrNull;
        if (chosen != null) ctx.targets.remove(chosen);
        if (chosen == null) {
          if (state.players[controller].isBot || candidates.length == 1) {
            chosen = Bot.bestCard(this, candidates);
          } else {
            state.pending = PendingDecision(player: controller, decision: ChooseTargetsDecision(prompt: '$srcName: choose a card in your graveyard', filter: filter, count: 1, optional: false, candidates: candidates), resume: Resume(source: source, controller: controller, effects: [e, ...remaining], context: ctx, kind: ResumeKind.targets));
            remaining.clear();
            return true;
          }
        }
        if (chosen == null) return false;
        switch (x.destination) {
          case LibraryDestination.hand:
            move(chosen, Zone.hand);
          case LibraryDestination.battlefield:
            move(chosen, Zone.battlefield, controller: controller);
            enteredBattlefield(chosen, untapped: true);
          case LibraryDestination.battlefieldTapped:
            move(chosen, Zone.battlefield, controller: controller, tapped: true);
            enteredBattlefield(chosen, untapped: false);
        }
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
              state.pending = PendingDecision(player: controller, decision: ExploreDecision(top, id), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.explore));
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
        if (state.players[controller].isBot) {
          final i = Bot.chooseMode(this, x.modes, controller, source);
          remaining.insertAll(0, x.modes[i]);
          return true;
        }
        if (x.modes.length == 1) {
          remaining.insertAll(0, x.modes[0]);
          return true;
        }
        state.pending = PendingDecision(player: controller, decision: ChooseModeDecision('$srcName: choose one', x.modes.map(describeEffects).toList()), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.mode, modes: x.modes));
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
        state.pending = PendingDecision(player: controller, decision: ChooseOptionalDecision('$srcName: ${describeEffects(x.effects)}?'), resume: Resume(source: source, controller: controller, effects: List.of(remaining), context: ctx, kind: ResumeKind.optional, optionalEffects: x.effects));
        remaining.clear();
        return true;
      case IfDidPrevious x:
        if (ctx.previousHappened) remaining.insertAll(0, x.effects);
        return ctx.previousHappened;
      case KickedInstead _:
        return false;
      case Conditional x:
        if (source == null) return false;
        final isCreature = characteristics(source).isCreature;
        if ((x.condition == Condition.thisIsCreature) == isCreature) {
          remaining.insertAll(0, x.effects);
          return true;
        }
        return false;
      case GainControl x:
        final ids = targets(x.target, '$srcName: choose what to take');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield || o.controller == controller) continue;
          _removeFromZone(id);
          o.controller = controller;
          state.players[controller].battlefield.add(id);
          o.enteredTurn = state.turn;
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
            state.pending = PendingDecision(player: controller, decision: ChooseTargetsDecision(prompt: '$srcName: choose a creature card to assimilate', filter: x.filter, count: 1, optional: false, candidates: candidates), resume: Resume(source: source, controller: controller, effects: [e, ...remaining], context: ctx, kind: ResumeKind.targets));
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
      case CopyToken x:
        final ids = targets(x.target, '$srcName: choose what to copy');
        if (ids == null) return false;
        for (final id in ids) {
          final o = state.objects[id];
          if (o == null || o.zone != Zone.battlefield) continue;
          final spec = (o.token ?? TokenSpec(name: name(id))).copyWith();
          spec.keywords.addAll(x.extra);
          final copy = newObject(cardID: o.cardID, owner: controller, zone: Zone.battlefield, token: spec);
          state.objects[copy]!.controller = controller;
          state.objects[copy]!.enteredTurn = state.turn;
          state.players[controller].battlefield.add(copy);
          log(GameEvent('tokenCreated', player: controller, object: copy));
          enteredBattlefield(copy, untapped: true);
        }
        return ids.isNotEmpty;
    }
  }

  void createToken(TokenSpec spec, PlayerID p) {
    final id = newObject(cardID: '', owner: p, zone: Zone.battlefield, token: spec.copyWith());
    state.objects[id]!.controller = p;
    state.objects[id]!.enteredTurn = state.turn;
    state.players[p].battlefield.add(id);
    log(GameEvent('tokenCreated', player: p, object: id));
    enteredBattlefield(id, untapped: true);
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

  /// Puts a permanent onto the battlefield, or resolves a spell with bot-chosen targets, for free.
  void playFree(ObjectID id, PlayerID p) {
    final c = card(id);
    if (c == null) return;
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
      enteredBattlefield(id, untapped: true);
    } else {
      final parsed = db.parsed(c);
      final ctx = EffectContext();
      for (final r in targetRequirementsForCard(c, null)) {
        final legal = legalTargets(r.filter, p, id);
        ctx.targets.addAll(Bot.chooseTargets(this, r.filter, r.count, true, legal, p, null));
      }
      log(GameEvent('cast', player: p, object: id, amount: 0));
      resolve(parsed.spellEffects, source: id, controller: p, context: ctx);
      if (state.objects[id]?.zone == Zone.exile) move(id, Zone.graveyard);
    }
  }

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
      move(id, Zone.graveyard);
      log(GameEvent('died', object: id));
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
      case Conditional x:
        return describeEffects(x.effects);
    }
  }
}
