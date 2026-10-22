import 'abilities.dart';
import 'actions.dart';
import 'cards.dart';
import 'game.dart';
import 'state.dart';

/// The computer opponent: simple, fast heuristics. Also answers choices the engine makes on a
/// player's behalf (an opponent discarding, a bot's surveil).
class Bot {
  /// The next action for the bot, or null when it has nothing left to do this phase.
  static GameAction? nextAction(Game game, PlayerID p) {
    final s = game.state;
    if (s.isOver) return null;
    final pending = s.pending;
    if (pending != null) {
      if (pending.player != p) return null;
      return RespondAction(decide(game, pending.decision, p));
    }
    if (s.priority != null) {
      if (s.priority != p) return null;
      return bestResponse(game, p) ?? const PassPriorityAction();
    }
    if (s.activePlayer != p) return null;
    switch (s.phase) {
      case Phase.main1:
      case Phase.main2:
        final land = bestLand(game, p);
        if (land != null) return PlayLandAction(land);
        final station = bestStation(game, p);
        if (station != null) return station;
        final cast = bestCast(game, p);
        if (cast != null) return cast;
        final equip = bestEquip(game, p);
        if (equip != null) return equip;
        final act = bestActivation(game, p);
        if (act != null) return act;
        final cyc = bestCycle(game, p);
        if (cyc != null) return cyc;
        if (s.phase == Phase.main1) return DeclareAttackersAction(chooseAttackers(game, p));
        return const EndTurnAction();
      case Phase.declareAttackers:
      case Phase.beginCombat:
        return DeclareAttackersAction(chooseAttackers(game, p));
      default:
        return const PassPhaseAction();
    }
  }

  static DecisionResponse decide(Game game, Decision decision, PlayerID p) {
    switch (decision) {
      case MulliganDecision _:
        final hand = game.state.players[p].hand;
        final lands = hand.where((id) => game.card(id)?.isLand == true).length;
        final bad = (lands <= 1 || lands >= 6) && game.state.players[p].mulligans < 2;
        return bad ? const MulliganResponse() : const KeepResponse();
      case DeclareBlockersDecision d:
        return BlockersResponse(chooseBlockers(game, p, d.attackers));
      case ChooseTargetsDecision d:
        return TargetsResponse(chooseTargets(game, d.filter, d.count, d.optional, d.candidates, p, null));
      case ChooseModeDecision d:
        return ModeResponse(d.modes.isEmpty ? 0 : (d.modes.length > 1 ? 1 : 0));
      case ChooseOptionalDecision _:
        return const YesResponse();
      case DiscardToHandSizeDecision d:
        return CardsResponse(discardChoice(game, p, d.count));
      case ChooseBottomDecision d:
        return CardsResponse(bottomChoice(game, p, d.count));
      case PayOrCounterDecision _:
        return const YesResponse();
      case ChooseCardsDecision d:
        final sorted = List.of(d.cards)..sort((a, b) => cardValue(b, game) - cardValue(a, game));
        return CardsResponse(sorted.take(d.max).toList());
      case ChooseModesDecision d:
        return CardsResponse([for (var i = 0; i < d.modes.length && i < d.max; i++) i]);
      case ChooseSacrificeDecision d:
        return SacrificeResponse(sacrificeChoice(game, d.candidates));
      case SurveilDecision d:
        return CardsResponse(surveil(game, d.cards, p));
      case ScryDecision d:
        return CardsResponse(scry(game, d.cards, p));
      case ExploreDecision d:
        return ExploreResponse(exploreToGraveyard(game, d.card, p));
      case DiscoverDecision _:
        return const DiscoverResponse(true);
    }
  }

  /// Rough worth of a permanent: used to pick targets and trades.
  static int value(ObjectID id, Game game) {
    if (EffectContext.playerFromObject(id) != null) return 0;
    final c = game.characteristics(id);
    var v = 0;
    if (c.isCreature) v += c.power * 2 + c.toughness + c.keywords.length * 2;
    if (c.isLand) v += 2;
    if (c.isArtifact || c.isEnchantment) v += 3;
    final card = game.card(id);
    if (card != null) v += card.manaValue;
    return v;
  }

  static int cardValue(ObjectID id, Game game) {
    final card = game.card(id);
    if (card == null) return 0;
    return card.manaValue * 2 + (card.isCreature ? card.basePower + card.baseToughness : 2) + (card.isLand ? 1 : 0);
  }

  static List<ObjectID> chooseTargets(Game game, Filter f, int count, bool optional, List<ObjectID> candidates, PlayerID p, Effect? effect) {
    if (candidates.isEmpty) return [];
    var harmful = true;
    if (effect != null) {
      switch (effect) {
        case Pump x:
          harmful = x.power < 0 || x.toughness < 0;
        case AddCounters x:
          harmful = x.kind == CounterKind.minusOne || x.kind == CounterKind.stun;
        case GrantKeyword _:
        case Untap _:
        case Explore _:
        case Draw _:
        case GainLife _:
        case CreateTokens _:
        case SearchBasicLand _:
          harmful = false;
        default:
          harmful = true;
      }
    }
    final opponents = candidates.where((id) {
      final pl = EffectContext.playerFromObject(id);
      if (pl != null) return pl != p;
      return game.state.objects[id]?.controller != p;
    }).toList();
    final mine = candidates.where((id) => !opponents.contains(id)).toList();
    var pool = harmful ? opponents : mine;
    if (pool.isEmpty) {
      if (optional) return [];
      pool = candidates;
    }
    if (effect is Damage && effect.amount.kind == AmountKind.fixed) {
      final n = effect.amount.n;
      final opp = game.state.opponentOf(p);
      final oppObj = EffectContext.playerObject(opp);
      if (pool.contains(oppObj) && game.state.players[opp].life <= n) return [oppObj];
      final killable = pool.where((id) => EffectContext.playerFromObject(id) == null && game.characteristics(id).toughness - (game.state.objects[id]?.damage ?? 0) <= n).toList();
      if (killable.isNotEmpty) {
        killable.sort((a, b) => value(b, game) - value(a, game));
        return [killable.first];
      }
      if (pool.contains(oppObj)) return [oppObj];
    }
    final sorted = List.of(pool)..sort((a, b) => value(b, game) - value(a, game));
    return sorted.take(count).toList();
  }

  /// London mulligan: keep three or four lands if possible, bottoming extra lands first and
  /// then the most expensive spells.
  static List<ObjectID> bottomChoice(Game game, PlayerID p, int count) {
    final hand = List.of(game.state.players[p].hand);
    final lands = hand.where((id) => game.card(id)?.isLand == true).toList();
    final spells = hand.where((id) => game.card(id)?.isLand != true).toList()..sort((a, b) => (game.card(b)?.manaValue ?? 0).compareTo(game.card(a)?.manaValue ?? 0));
    final out = <ObjectID>[];
    while (out.length < count && lands.length > 3) {
      out.add(lands.removeLast());
    }
    while (out.length < count && spells.isNotEmpty) {
      out.add(spells.removeAt(0));
    }
    while (out.length < count && lands.isNotEmpty) {
      out.add(lands.removeLast());
    }
    return out;
  }

  static List<ObjectID> discardChoice(Game game, PlayerID p, int count) {
    final hand = List.of(game.state.players[p].hand);
    final lands = game.state.permanentsOf(p).where((o) => game.characteristics(o.id).isLand).length;
    hand.sort((a, b) {
      final ca = game.card(a), cb = game.card(b);
      final la = ca?.isLand == true, lb = cb?.isLand == true;
      if (la != lb) return (lands >= 6 ? la : lb) ? -1 : 1;
      return (cb?.manaValue ?? 0) - (ca?.manaValue ?? 0);
    });
    return hand.take(count).toList();
  }

  static ObjectID sacrificeChoice(Game game, List<ObjectID> candidates) {
    final sorted = List.of(candidates)..sort((a, b) => value(a, game) - value(b, game));
    return sorted.first;
  }

  static ObjectID? bestCard(Game game, List<ObjectID> among) {
    if (among.isEmpty) return null;
    final sorted = List.of(among)..sort((a, b) => cardValue(b, game) - cardValue(a, game));
    return sorted.first;
  }

  static List<ObjectID> surveil(Game game, List<ObjectID> cards, PlayerID p) {
    final lands = game.state.permanentsOf(p).where((o) => game.characteristics(o.id).isLand).length;
    return cards.where((id) {
      final c = game.card(id);
      if (c == null) return false;
      if (c.isLand) return lands >= 5;
      return c.manaValue > lands + 3;
    }).toList();
  }

  static List<ObjectID> scry(Game game, List<ObjectID> cards, PlayerID p) => surveil(game, cards, p);
  static bool exploreToGraveyard(Game game, ObjectID card, PlayerID p) => surveil(game, [card], p).isNotEmpty;

  static int chooseMode(Game game, List<List<Effect>> modes, PlayerID p, ObjectID? source) {
    for (var i = 0; i < modes.length; i++) {
      final reqs = game.targetRequirementsIn(modes[i]);
      if (reqs.every((r) => game.legalTargets(r.filter, p, source).isNotEmpty)) return i;
    }
    return 0;
  }

  static bool wantsOptional(Game game, List<Effect> effects, PlayerID p, ObjectID? source) {
    for (final e in effects) {
      switch (e) {
        case Sacrifice x:
          if (x.target == Target.you) return false;
        case PayLife x:
          return game.state.players[p].life > x.n + 5;
        case Discard x:
          if (x.target == Target.you) return false;
        case LoseLife x:
          if (x.target == Target.you) return false;
        default:
          break;
      }
    }
    return true;
  }

  /// The basic land type a player would most like to find.
  static String? preferredBasicLand(Game game, PlayerID p) {
    final need = <ManaColor, int>{};
    for (final id in game.state.players[p].hand) {
      game.card(id)?.cost.colored.forEach((c, n) => need[c] = (need[c] ?? 0) + n);
    }
    final have = <ManaColor, int>{};
    for (final o in game.state.permanentsOf(p)) {
      for (final c in game.parsedOf(o)?.manaColors ?? const <ManaColor>[]) {
        have[c] = (have[c] ?? 0) + 1;
      }
    }
    ManaColor? best;
    var bestScore = -1 << 30;
    for (final c in ManaColor.values) {
      if (need[c] == null) continue;
      final score = need[c]! - (have[c] ?? 0);
      if (score > bestScore) {
        bestScore = score;
        best = c;
      }
    }
    return best?.basicLandType;
  }

  static ObjectID? bestLand(Game game, PlayerID p) {
    final lands = [...game.state.players[p].hand, ...game.extraPlayables(p)].where((id) => game.canPlayLand(id, p)).toList();
    if (lands.isEmpty) return null;
    final have = <ManaColor>{};
    for (final o in game.state.permanentsOf(p)) {
      have.addAll(game.parsedOf(o)?.manaColors ?? const []);
    }
    final need = <ManaColor>{};
    for (final id in game.state.players[p].hand) {
      need.addAll(game.card(id)?.cost.colored.keys ?? const <ManaColor>[]);
    }
    int score(ObjectID id) {
      final card = game.card(id);
      if (card == null) return 0;
      final parsed = game.db.parsed(card);
      final colors = parsed.manaColors.toSet();
      var s = colors.intersection(need).difference(have).length * 10 + colors.length;
      if (parsed.statics.contains(SimpleStatic.entersTapped)) s -= 3;
      return s;
    }

    lands.sort((a, b) => score(b) - score(a));
    return lands.first;
  }

  static GameAction? bestCast(Game game, PlayerID p) {
    final hand = [...game.state.players[p].hand, ...game.extraPlayables(p)].where((id) => game.canCast(id, p)).toList();
    final opp = game.state.opponentOf(p);
    GameAction? best;
    var bestScore = -1 << 30;
    for (final id in hand) {
      final card = game.card(id);
      if (card == null) continue;
      final parsed = game.db.parsed(card);
      if ((card.isInstant || card.isSorcery) && parsed.spellEffects.isEmpty) continue;
      int? mode;
      final modal = parsed.spellEffects.whereType<Modal>().firstOrNull;
      if (modal != null) mode = chooseMode(game, modal.modes, p, id);
      var kicked = false;
      final k = parsed.kicker;
      if (k != null) {
        final cost = card.cost..add(k);
        kicked = game.canPay(cost, p) && game.targetRequirementsForCard(card, mode, kicked: true).every((r) => r.optional || game.legalTargets(r.filter, p, id).isNotEmpty);
      }
      final targets = <ObjectID>[];
      var ok = true;
      var targetValue = 0;
      for (final r in game.targetRequirementsForCard(card, mode, kicked: kicked)) {
        final legal = game.legalTargets(r.filter, p, id);
        final effect = parsed.spellEffects.where((e) {
          final t = targetOf(e);
          return t is ChosenTarget && t.filter == r.filter;
        }).firstOrNull;
        final chosen = chooseTargets(game, r.filter, r.count, r.optional, legal, p, effect);
        if (chosen.isEmpty && !r.optional) {
          ok = false;
          break;
        }
        if (chosen.isNotEmpty && EffectContext.playerFromObject(chosen.first) == null && game.state.objects[chosen.first]?.controller == p && isHarmful(effect)) {
          ok = false;
          break;
        }
        targetValue += chosen.fold<int>(0, (a, b) => a + value(b, game));
        targets.addAll(chosen);
      }
      if (!ok) continue;
      var score = card.manaValue * 3 + (card.isCreature ? card.basePower + card.baseToughness : 0) + targetValue;
      if ((card.isInstant || card.isSorcery) && targetValue == 0 && parsed.spellEffects.any((e) => e is Damage)) score -= 5;
      if (card.isLegendary && game.state.permanentsOf(p).any((o) => game.cardOf(o)?.name == card.name)) continue;
      if (game.state.players[opp].life <= 0) continue;
      if (score > bestScore) {
        bestScore = score;
        best = CastAction(id, targets: targets, kicked: kicked, mode: mode);
      }
    }
    return best;
  }

  /// What to do with priority: counter a threatening spell, protect a creature a spell targets,
  /// kill an attacker, or flash something in at the end of the opponent's turn.
  static GameAction? bestResponse(Game game, PlayerID p) {
    final s = game.state;
    final hand = [...s.players[p].hand, ...game.extraPlayables(p)].where((id) => game.canCast(id, p)).toList();
    if (hand.isEmpty) return null;
    final top = s.stack.isEmpty ? null : s.stack.last;
    if (top != null) {
      if (top.controller == p) return null;
      final topCard = game.card(top.id);
      final mine = EffectContext.playerObject(p);
      final targetsMine = top.context.targets.any((t) => t == mine || (s.objects[t]?.controller == p && s.objects[t]?.zone == Zone.battlefield));
      final threatening = topCard != null && (topCard.manaValue >= 3 || targetsMine || (topCard.isCreature && topCard.basePower >= 3));
      for (final id in hand) {
        final card = game.card(id)!;
        final fx = game.db.parsed(card).spellEffects;
        final counters = fx.any((e) => e is CounterSpell || (e is Modal && e.modes.any((m) => m.any((x) => x is CounterSpell))));
        if (!counters || !threatening) continue;
        int? mode;
        final modal = fx.whereType<Modal>().firstOrNull;
        if (modal != null) mode = modal.modes.indexWhere((m) => m.any((x) => x is CounterSpell));
        for (final kicked in [false, if (game.db.parsed(card).kicker != null) true]) {
          if (kicked && !game.canPay(card.cost..add(game.db.parsed(card).kicker!), p)) continue;
          final reqs = game.targetRequirementsForCard(card, mode, kicked: kicked);
          if (reqs.isEmpty || reqs.first.filter.kind != FilterKind.spell) continue;
          if (!game.legalTargets(reqs.first.filter, p, id).contains(top.id)) continue;
          return CastAction(id, targets: [top.id], mode: mode, kicked: kicked);
        }
        continue;
      }
      // Protect a creature of ours that the spell targets.
      final threatened = top.context.targets.where((t) => s.objects[t]?.controller == p && s.objects[t]?.zone == Zone.battlefield).toList();
      if (threatened.isNotEmpty) {
        for (final id in hand) {
          final card = game.card(id)!;
          final fx = game.db.parsed(card).spellEffects;
          final protects = fx.any((e) => e is GrantKeyword && (e.keyword.kind == KeywordKind.hexproof || e.keyword.kind == KeywordKind.indestructible));
          if (!protects) continue;
          final reqs = game.targetRequirementsForCard(card, null);
          if (reqs.isEmpty) continue;
          final legal = game.legalTargets(reqs.first.filter, p, id);
          final t = threatened.where(legal.contains).firstOrNull;
          if (t != null) return CastAction(id, targets: [t]);
        }
      }
      return null;
    }
    if (s.activePlayer == p) return null;
    final cast = bestCast(game, p);
    if (cast is! CastAction) return null;
    final card = game.card(cast.id);
    if (card == null) return null;
    final fx = game.db.parsed(card).spellEffects;
    if (fx.any((e) => e is CounterSpell)) return null;
    if (s.phase == Phase.end) return cast;
    final harmful = fx.any((e) => e is Destroy || e is Exile || e is Damage || e is Bounce || (e is Pump && (e.power < 0 || e.toughness < 0)));
    if (s.phase == Phase.declareAttackers && harmful && cast.targets.any((t) => s.combat.attackers.contains(t))) return cast;
    if (card.isCreature && s.phase == Phase.declareAttackers) return cast; // flash in a blocker
    return null;
  }

  /// Nyota Uhura: the mana value the opponent's deck plays most.
  static int chooseNumber(Game game, PlayerID p, int min, int max) {
    final counts = <int, int>{};
    final opp = game.state.opponentOf(p);
    for (final id in [...game.state.players[opp].graveyard, ...game.state.permanentsOf(opp).map((o) => o.id)]) {
      final c = game.card(id);
      if (c == null || c.isLand) continue;
      counts[c.manaValue] = (counts[c.manaValue] ?? 0) + 1;
    }
    var best = 2, bestN = -1;
    for (final e in counts.entries) {
      if (e.key >= min && e.key <= max && (e.value > bestN || (e.value == bestN && e.key < best))) {
        best = e.key;
        bestN = e.value;
      }
    }
    return best.clamp(min, max);
  }

  /// The color of mana the hand needs most.
  static ManaColor preferredColor(Game game, PlayerID p) {
    final land = preferredBasicLand(game, p);
    return ManaColor.values.firstWhere((c) => c.basicLandType == land, orElse: () => ManaColor.white);
  }

  /// Peace in Our Time: take the card when there's no worthwhile attack anyway.
  static bool acceptsPeace(Game game, PlayerID p) => chooseAttackers(game, p).isEmpty;

  static Target? targetOf(Effect e) {
    switch (e) {
      case Damage x:
        return x.target;
      case Destroy x:
        return x.target;
      case Exile x:
        return x.target;
      case Bounce x:
        return x.target;
      case Tap x:
        return x.target;
      case Pump x:
        return x.target;
      case AddCounters x:
        return x.target;
      case GrantKeyword x:
        return x.target;
      case Fight x:
        return x.target;
      case Bite x:
        return x.target;
      case CantBlock x:
        return x.target;
      case GainControl x:
        return x.target;
      case CounterSpell x:
        return x.target;
      case Untap x:
        return x.target;
      case Explore x:
        return x.target;
      default:
        return null;
    }
  }

  static bool isHarmful(Effect? e) {
    if (e == null) return false;
    switch (e) {
      case Pump x:
        return x.power < 0 || x.toughness < 0;
      case AddCounters x:
        return x.kind == CounterKind.minusOne || x.kind == CounterKind.stun;
      case GrantKeyword _:
      case Untap _:
      case Explore _:
        return false;
      default:
        return true;
    }
  }

  static GameAction? bestStation(Game game, PlayerID p) {
    if (!game.state.phase.isMain) return null;
    final ships = game.state
        .permanentsOf(p)
        .where((o) => game.characteristics(o.id).isSpacecraft && !game.characteristics(o.id).isCreature && game.parsedOf(o)?.has(KeywordKind.station) == true)
        .toList();
    if (ships.isEmpty) return null;
    final ship = ships.first;
    final opp = game.state.opponentOf(p);
    final oppCreatures = game.state.permanentsOf(opp).where((o) => game.characteristics(o.id).isCreature).toList();
    final candidates = game.state
        .permanentsOf(p)
        .where((o) => o.id != ship.id && !o.tapped && game.characteristics(o.id).isCreature && !game.hasSummoningSickness(o) && game.characteristics(o.id).power > 0)
        .toList();
    final threshold = game.parsedOf(ship)?.stationThreshold;
    if (threshold == null || candidates.isEmpty) return null;
    final need = threshold - ship.chargeCounters;
    candidates.sort((a, b) => game.characteristics(b.id).power - game.characteristics(a.id).power);
    final c = candidates.first;
    final power = game.characteristics(c.id).power;
    if (game.state.phase == Phase.main2 || power >= need || oppCreatures.length > candidates.length) return StationAction(ship.id, c.id);
    return null;
  }

  static GameAction? bestEquip(Game game, PlayerID p) {
    if (!game.state.phase.isMain) return null;
    for (final e in game.state.permanentsOf(p)) {
      final cost = game.parsedOf(e)?.equipCost;
      if (cost == null || e.attachedTo != null || !game.canPay(cost, p)) continue;
      final creatures = game.state.permanentsOf(p).where((o) => game.characteristics(o.id).isCreature && !game.hasSummoningSickness(o)).toList();
      if (creatures.isEmpty) continue;
      creatures.sort((a, b) => game.characteristics(b.id).power - game.characteristics(a.id).power);
      return EquipAction(e.id, creatures.first.id);
    }
    return null;
  }

  static GameAction? bestActivation(Game game, PlayerID p) {
    final me = game.state.players[p];
    final sources = [
      ...game.state.permanentsOf(p),
      for (final id in [...me.hand, ...me.graveyard]) ?game.state.objects[id],
    ];
    for (final o in sources) {
      final all = game.abilitiesIn(o);
      for (var i = 0; i < all.length; i++) {
        final a = all[i];
        if (a is! Activated) continue;
        final cost = a.cost;
        final fx = a.effects;
        if (game.activationProblem(o.id, i, p) != null) continue;
        if (cost.sacrificeSelf && fx.length == 1 && fx[0] is AddMana) continue; // Treasure: used by manaPlan
        if (cost.sacrificeSelf && cost.tap && fx.length == 1 && fx[0] is Draw && me.hand.length > 3) continue; // Clue: keep for later
        if (cost.discard > 0 || cost.sacrifice != null || cost.payLife > 0) continue;
        // A card in hand is usually worth more cast than discarded for its ability.
        if (cost.zone == AbilityZone.hand && (game.canCast(o.id, p) || game.state.phase != Phase.main2)) continue;
        // Tapping creatures to pay costs only after combat.
        if (cost.tapOthers > 0 && game.state.phase != Phase.main2 && game.state.activePlayer == p) continue;
        if (cost.tap && game.characteristics(o.id).isCreature && game.state.phase == Phase.main1) continue;
        if (fx.any((e) => e is AddMana)) continue;
        final targets = <ObjectID>[];
        var ok = true;
        for (final r in game.targetRequirementsIn(fx)) {
          final legal = game.legalTargets(r.filter, p, o.id);
          final chosen = chooseTargets(game, r.filter, r.count, r.optional, legal, p, fx.first);
          if (chosen.isEmpty && !r.optional) {
            ok = false;
            break;
          }
          if (chosen.isNotEmpty && EffectContext.playerFromObject(chosen.first) == null && game.state.objects[chosen.first]?.controller == p && isHarmful(fx.first)) {
            ok = false;
            break;
          }
          targets.addAll(chosen);
        }
        if (!ok) continue;
        if (game.state.phase == Phase.main1 && !cost.mana.isFree && bestCast(game, p) != null) continue;
        return ActivateAbilityAction(o.id, i, targets: targets);
      }
    }
    return null;
  }

  static GameAction? bestCycle(Game game, PlayerID p) {
    final lands = game.state.permanentsOf(p).where((o) => game.characteristics(o.id).isLand).length;
    for (final id in game.state.players[p].hand) {
      final card = game.card(id);
      if (card == null) continue;
      final cyc = game.db.parsed(card).cycling;
      if (cyc == null || !game.canPay(cyc.cost, p)) continue;
      if (card.manaValue > lands + 2 && game.state.phase == Phase.main2) return CycleAction(id);
    }
    return null;
  }

  static List<ObjectID> chooseAttackers(Game game, PlayerID p) {
    final opp = game.state.opponentOf(p);
    final blockers = game.state.permanentsOf(opp).where((o) => !o.tapped && game.characteristics(o.id).isCreature && !game.characteristics(o.id).has(KeywordKind.cantBlock)).toList();
    final mine = game.state.permanentsOf(p).where((o) => game.canAttack(o.id)).toList();
    final oppLife = game.state.players[opp].life;
    final totalPower = mine.fold<int>(0, (a, o) => a + (game.characteristics(o.id).power.clamp(0, 1 << 30)));
    final blockerToughness = blockers.fold<int>(0, (a, o) => a + game.characteristics(o.id).toughness);
    final attackers = <ObjectID>[];
    for (final o in mine) {
      final c = game.characteristics(o.id);
      if (c.has(KeywordKind.mustAttack)) {
        attackers.add(o.id);
        continue;
      }
      if (c.power <= 0) continue;
      if (totalPower >= oppLife + blockerToughness) {
        attackers.add(o.id);
        continue;
      }
      final canBeBlockedBy = blockers.where((b) => game.canBlock(b.id, o.id)).toList();
      if (canBeBlockedBy.isEmpty) {
        attackers.add(o.id);
        continue;
      }
      final dies = canBeBlockedBy.any((b) {
        final bc = game.characteristics(b.id);
        final kills = bc.power >= c.toughness || bc.has(KeywordKind.deathtouch);
        final survives = c.power < bc.toughness && !c.has(KeywordKind.deathtouch);
        return kills && (survives || bc.power + bc.toughness < c.power + c.toughness);
      });
      if (!dies) {
        attackers.add(o.id);
      } else if (oppLife <= 6 && c.power >= 2) {
        attackers.add(o.id);
      }
    }
    return attackers;
  }

  static Map<ObjectID, ObjectID> chooseBlockers(Game game, PlayerID p, List<ObjectID> attackers) {
    final blocks = <ObjectID, ObjectID>{};
    final free = game.state.permanentsOf(p).where((o) => game.characteristics(o.id).isCreature && !o.tapped).toList();
    final life = game.state.players[p].life;
    final incoming = attackers.fold<int>(0, (a, id) => a + game.characteristics(id).power.clamp(0, 1 << 30));
    final desperate = incoming >= life;
    final sortedAttackers = List.of(attackers)..sort((a, b) => game.characteristics(b).power - game.characteristics(a).power);
    for (final a in sortedAttackers) {
      final ac = game.characteristics(a);
      final menace = ac.has(KeywordKind.menace);
      final options = free.where((b) => game.canBlock(b.id, a)).toList();
      bool kills(GameObject b) {
        final bc = game.characteristics(b.id);
        return bc.power >= ac.toughness || bc.has(KeywordKind.deathtouch);
      }

      final good = options.where((b) {
        final bc = game.characteristics(b.id);
        final survives = (ac.power < bc.toughness && !ac.has(KeywordKind.deathtouch)) || (!ac.has(KeywordKind.firstStrike) && bc.has(KeywordKind.firstStrike) && kills(b));
        return kills(b) && survives;
      }).toList();
      final trade = options.where((b) => kills(b) && value(b.id, game) <= value(a, game)).toList();
      GameObject? least(List<GameObject> list) {
        if (list.isEmpty) return null;
        final sorted = List.of(list)..sort((x, y) => value(x.id, game) - value(y.id, game));
        return sorted.first;
      }

      var chosen = <ObjectID>[];
      final g = least(good);
      final t = least(trade);
      final c = least(options);
      if (g != null) {
        chosen = [g.id];
      } else if (t != null) {
        chosen = [t.id];
      } else if (desperate && c != null) {
        chosen = [c.id];
      }
      if (menace) {
        if (chosen.length == 1) {
          final second = options.where((b) => b.id != chosen[0]).firstOrNull;
          if (second != null) {
            chosen.add(second.id);
          } else {
            chosen = [];
          }
        } else {
          chosen = [];
        }
      }
      for (final b in chosen) {
        blocks[b] = a;
        free.removeWhere((o) => o.id == b);
      }
    }
    return blocks;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
