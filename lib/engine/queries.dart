part of 'game.dart';

/// What a permanent is right now, with counters, pumps, attachments and statics applied.
class Characteristics {
  Characteristics({required this.name, required this.power, required this.toughness, required this.keywords, required this.isCreature, required this.isArtifact, required this.isEnchantment, required this.isLand, required this.isSpacecraft, required this.subtypes});
  String name;
  int power, toughness;
  Set<Keyword> keywords;
  bool isCreature, isArtifact, isEnchantment, isLand, isSpacecraft;
  Set<String> subtypes;
  bool cantAttackOrBlock = false;

  bool has(KeywordKind kind) => keywords.any((k) => k.kind == kind);
  int get wardCost => keywords.where((k) => k.kind == KeywordKind.ward).map((k) => k.value).firstOrNull ?? 0;

  static Characteristics empty() => Characteristics(name: '?', power: 0, toughness: 0, keywords: {}, isCreature: false, isArtifact: false, isEnchantment: false, isLand: false, isSpacecraft: false, subtypes: {});
}

class TargetRequirement {
  TargetRequirement(this.filter, this.count, this.optional);
  final Filter filter;
  final int count;
  final bool optional;
}

extension GameQueries on Game {
  Card? cardOf(GameObject o) => o.cardID.isEmpty ? null : db[o.cardID];
  Card? card(ObjectID id) {
    final o = state.objects[id];
    return o == null ? null : cardOf(o);
  }

  ParsedCard? parsedOf(GameObject o) {
    final c = cardOf(o);
    return c == null ? null : db.parsed(c);
  }

  String name(ObjectID id) {
    final p = EffectContext.playerFromObject(id);
    if (p != null) return state.players[p].name;
    final o = state.objects[id];
    if (o == null) return '?';
    return o.token?.name ?? cardOf(o)?.name ?? 'Token';
  }

  /// Full characteristics for anything on the battlefield.
  Characteristics characteristics(ObjectID id) {
    final o = state.objects[id];
    if (o == null) return Characteristics.empty();
    final card = cardOf(o);
    final parsedCard = card == null ? null : db.parsed(card);
    Characteristics c;
    final t = o.token;
    if (t != null && card == null) {
      c = Characteristics(name: t.name, power: t.power, toughness: t.toughness, keywords: Set.of(t.keywords), isCreature: t.isCreature, isArtifact: t.isArtifact, isEnchantment: false, isLand: false, isSpacecraft: false, subtypes: Set.of(t.subtypes));
    } else if (card != null && parsedCard != null) {
      c = Characteristics(name: card.name, power: card.basePower, toughness: card.baseToughness, keywords: Set.of(parsedCard.keywords), isCreature: card.isCreature, isArtifact: card.isArtifact, isEnchantment: card.isEnchantment, isLand: card.isLand, isSpacecraft: card.isSpacecraft, subtypes: Set.of(card.subtypes));
      if (t != null) c.keywords.addAll(t.keywords);
      if (card.isSpacecraft) {
        final threshold = parsedCard.stationThreshold ?? card.stationThreshold;
        if (threshold != null && o.chargeCounters >= threshold) {
          c.isCreature = true;
          c.keywords.addAll(parsedCard.stationKeywords);
        }
      }
      for (final s in parsedCard.statics) {
        switch (s) {
          case PowerEquals pe:
            final n = amount(pe.amount, o.controller, id, EffectContext());
            c.power = n;
            if (pe.andToughness) c.toughness = n;
          case SelfPumpPerCount sp:
            final n = amount(sp.amount, o.controller, id, EffectContext());
            c.power += sp.power * n;
            c.toughness += sp.toughness * n;
          case KeywordDuringYourTurn k:
            if (state.activePlayer == o.controller) c.keywords.add(k.keyword);
          case SimpleStatic ss:
            if (ss.kind == SimpleStaticKind.hexproofWhileNotCreature && !c.isCreature) c.keywords.add(Keyword.hexproof);
          default:
            break;
        }
      }
    } else {
      c = Characteristics.empty();
    }
    if (o.assimilated) {
      c.isCreature = true;
      c.isArtifact = true;
      c.subtypes = {'Borg'};
    }
    final counterDelta = o.plusOneCounters - (o.counters[CounterKind.minusOne] ?? 0);
    c.power += counterDelta;
    c.toughness += counterDelta;
    for (final e in o.untilEndOfTurn) {
      switch (e) {
        case PumpEffect p:
          c.power += p.power;
          c.toughness += p.toughness;
        case KeywordEffect k:
          c.keywords.add(k.keyword);
        case CantBlockEffect _:
          c.keywords.add(Keyword.cantBlock);
      }
    }
    for (final other in state.allPermanents) {
      if (other.attachedTo != id) continue;
      final p = parsedOf(other);
      if (p == null) continue;
      for (final s in p.statics) {
        switch (s) {
          case AttachedGets g:
            c.power += g.power;
            c.toughness += g.toughness;
          case AttachedHas h:
            c.keywords.add(h.keyword);
          case SimpleStatic ss:
            if (ss.kind == SimpleStaticKind.attachedCantAttackOrBlock) c.cantAttackOrBlock = true;
          default:
            break;
        }
      }
    }
    for (final other in state.allPermanents) {
      final p = parsedOf(other);
      if (p == null) continue;
      for (final s in p.statics) {
        switch (s) {
          case Anthem a:
            if (matches(a.filter, id, other.controller, other.id, base: c)) {
              c.power += a.power;
              c.toughness += a.toughness;
            }
          case GrantKeywordStatic g:
            if ((!g.duringYourTurn || state.activePlayer == other.controller) && matches(g.filter, id, other.controller, other.id, base: c)) c.keywords.add(g.keyword);
          default:
            break;
        }
      }
    }
    return c;
  }

  /// Does `id` match the filter, as seen by `controller` (the filter's "you")?
  bool matches(Filter f, ObjectID id, PlayerID controller, ObjectID? source, {Characteristics? base}) {
    final p = EffectContext.playerFromObject(id);
    if (p != null) {
      switch (f.kind) {
        case FilterKind.player:
        case FilterKind.creatureOrPlayer:
          return true;
        case FilterKind.opponent:
          return p != controller;
        default:
          return false;
      }
    }
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield) return false;
    if (f.other && id == source) return false;
    switch (f.controller) {
      case Controller.any:
        break;
      case Controller.you:
        if (o.controller != controller) return false;
      case Controller.opponent:
        if (o.controller == controller) return false;
    }
    final c = base ?? characteristics(id);
    switch (f.kind) {
      case FilterKind.creature:
      case FilterKind.creatureOrPlayer:
        if (!c.isCreature) return false;
      case FilterKind.player:
      case FilterKind.opponent:
        return false;
      case FilterKind.permanent:
        break;
      case FilterKind.nonlandPermanent:
        if (c.isLand) return false;
      case FilterKind.artifact:
        if (!c.isArtifact) return false;
      case FilterKind.enchantment:
        if (!c.isEnchantment) return false;
      case FilterKind.artifactOrEnchantment:
        if (!c.isArtifact && !c.isEnchantment) return false;
      case FilterKind.artifactOrCreature:
        if (!c.isArtifact && !c.isCreature) return false;
      case FilterKind.land:
        if (!c.isLand) return false;
      case FilterKind.spacecraft:
        if (!c.isSpacecraft) return false;
      case FilterKind.creatureOrSpacecraft:
        if (!c.isCreature && !c.isSpacecraft) return false;
      case FilterKind.artifactCreature:
        if (!c.isArtifact || !c.isCreature) return false;
      case FilterKind.token:
        if (!o.isToken) return false;
      case FilterKind.creatureCardInGraveyard:
      case FilterKind.basicLandCardInLibrary:
        return false;
    }
    if (f.attacking && o.attacking == null && !f.blocking) return false;
    if (f.blocking && o.blocking == null && !f.attacking) return false;
    if (f.attacking && f.blocking && o.attacking == null && o.blocking == null) return false;
    if (f.tapped && !o.tapped) return false;
    if (f.untapped && o.tapped) return false;
    if (f.nontoken && o.isToken) return false;
    if (f.nonartifact && c.isArtifact) return false;
    if (f.withCounters && o.counters.values.fold<int>(0, (a, b) => a + b) == 0) return false;
    final st = f.subtype;
    if (st != null && !c.subtypes.contains(st)) return false;
    if (f.maxPower != null && c.power > f.maxPower!) return false;
    if (f.minPower != null && c.power < f.minPower!) return false;
    if (f.maxManaValue != null && (cardOf(o)?.manaValue ?? 0) > f.maxManaValue!) return false;
    return true;
  }

  /// Legal targets for a filter chosen by `controller`: hexproof is checked here.
  List<ObjectID> legalTargets(Filter f, PlayerID controller, ObjectID? source) {
    final out = <ObjectID>[];
    if (f.isPlayerFilter || f.kind == FilterKind.creatureOrPlayer) {
      for (final p in state.players) {
        if (p.lost) continue;
        if (f.kind == FilterKind.opponent && p.id == controller) continue;
        out.add(EffectContext.playerObject(p.id));
      }
      if (f.isPlayerFilter) return out;
    }
    if (f.kind == FilterKind.creatureCardInGraveyard) {
      for (final p in state.players) {
        if (f.controller == Controller.you && p.id != controller) continue;
        if (f.controller == Controller.opponent && p.id == controller) continue;
        for (final id in p.graveyard) {
          final o = state.objects[id];
          final c = o == null ? null : cardOf(o);
          if (c == null || !c.isCreature) continue;
          if (f.maxManaValue != null && c.manaValue > f.maxManaValue!) continue;
          out.add(id);
        }
      }
      return out;
    }
    for (final o in state.allPermanents) {
      if (!matches(f, o.id, controller, source)) continue;
      if (o.controller != controller && characteristics(o.id).has(KeywordKind.hexproof)) continue;
      out.add(o.id);
    }
    return out;
  }

  /// Type checks from the card alone (plus Station and assimilation), so counting "artifacts you
  /// control" inside `characteristics` can't recurse through other permanents' statics.
  bool shallowIsCreature(GameObject o) {
    if (o.assimilated) return true;
    final t = o.token;
    final c = cardOf(o);
    if (c == null) return t?.isCreature ?? false;
    if (c.isCreature) return true;
    if (c.isSpacecraft) {
      final threshold = db.parsed(c).stationThreshold ?? c.stationThreshold;
      return threshold != null && o.chargeCounters >= threshold;
    }
    return false;
  }

  bool shallowIsArtifact(GameObject o) => o.assimilated || (cardOf(o)?.isArtifact ?? o.token?.isArtifact ?? false);
  bool shallowIsLand(GameObject o) => cardOf(o)?.isLand ?? false;

  int amount(Amount a, PlayerID controller, ObjectID? source, EffectContext context) {
    switch (a.kind) {
      case AmountKind.fixed:
        return a.n;
      case AmountKind.creaturesYouControl:
        return state.permanentsOf(controller).where(shallowIsCreature).length;
      case AmountKind.artifactsYouControl:
        return state.permanentsOf(controller).where(shallowIsArtifact).length;
      case AmountKind.landsYouControl:
        return state.permanentsOf(controller).where(shallowIsLand).length;
      case AmountKind.cardsInHand:
        return state.players[controller].hand.length;
      case AmountKind.differentlyNamedLands:
        return state.permanentsOf(controller).where(shallowIsLand).map((o) => name(o.id)).toSet().length;
      case AmountKind.thisPower:
        return source == null ? 0 : characteristics(source).power;
    }
  }

  bool isCreature(ObjectID id) => characteristics(id).isCreature;

  bool hasSummoningSickness(GameObject o) => o.enteredTurn == state.turn && !characteristics(o.id).has(KeywordKind.haste);

  bool canAttack(ObjectID id) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield || o.tapped) return false;
    final c = characteristics(id);
    return c.isCreature && !c.has(KeywordKind.defender) && !c.cantAttackOrBlock && !hasSummoningSickness(o);
  }

  bool canBlock(ObjectID blocker, ObjectID attacker) {
    final b = state.objects[blocker];
    if (b == null || b.zone != Zone.battlefield || b.tapped) return false;
    final bc = characteristics(blocker), ac = characteristics(attacker);
    if (!bc.isCreature || bc.has(KeywordKind.cantBlock) || bc.cantAttackOrBlock) return false;
    if (ac.has(KeywordKind.unblockable)) return false;
    if (ac.has(KeywordKind.flying) && !bc.has(KeywordKind.flying) && !bc.has(KeywordKind.reach)) return false;
    return true;
  }

  /// Untapped sources of mana: (object, colors it can make; empty = colorless, usesSacrifice).
  List<(ObjectID, List<ManaColor>, bool)> manaSources(PlayerID p) {
    final out = <(ObjectID, List<ManaColor>, bool)>[];
    for (final o in state.permanentsOf(p)) {
      if (o.tapped) continue;
      final parsed = parsedOf(o);
      if (parsed == null) continue;
      if (parsed.hasManaAbility) {
        if (characteristics(o.id).isCreature && hasSummoningSickness(o)) continue;
        out.add((o.id, parsed.manaColors, false));
        continue;
      }
      for (final a in parsed.abilities) {
        if (a is Activated && a.cost.tap && a.effects.length == 1 && a.effects[0] is AddMana && a.cost.mana.isFree && a.cost.payLife == 0) {
          out.add((o.id, (a.effects[0] as AddMana).colors, a.cost.sacrificeSelf));
        }
      }
    }
    return out;
  }

  /// Which sources to tap to pay a cost, or null if it can't be paid. Colored needs first, from
  /// the pickiest sources; Treasures last.
  List<ObjectID>? manaPlan(ManaCost cost, PlayerID player) {
    final sources = manaSources(player);
    sources.sort((a, b) {
      if (a.$3 != b.$3) return a.$3 ? 1 : -1;
      return a.$2.length - b.$2.length;
    });
    final used = <ObjectID>[];
    final needs = <ManaColor>[];
    final colorKeys = cost.colored.keys.toList()..sort((a, b) => a.index - b.index);
    for (final c in colorKeys) {
      for (var i = 0; i < cost.colored[c]!; i++) {
        needs.add(c);
      }
    }
    for (final color in needs) {
      final i = sources.indexWhere((s) => s.$2.contains(color));
      if (i < 0) return null;
      used.add(sources[i].$1);
      sources.removeAt(i);
    }
    for (final pair in cost.hybrid) {
      final i = sources.indexWhere((s) => s.$2.any(pair.contains));
      if (i < 0) return null;
      used.add(sources[i].$1);
      sources.removeAt(i);
    }
    var generic = cost.generic;
    sources.sort((a, b) {
      final ae = a.$2.isEmpty, be = b.$2.isEmpty;
      if (ae == be) return 0;
      return ae ? -1 : 1;
    });
    while (generic > 0) {
      if (sources.isEmpty) return null;
      used.add(sources.removeAt(0).$1);
      generic--;
    }
    return used;
  }

  bool canPay(ManaCost cost, PlayerID player) => manaPlan(cost, player) != null;
  int availableMana(PlayerID p) => manaSources(p).length;

  /// Whether a card in hand can be cast now (timing + mana), ignoring targets.
  bool canCast(ObjectID id, PlayerID p) {
    if (state.pending != null || state.winner != null || state.activePlayer != p) return false;
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || o.zone != Zone.hand || card == null || card.isLand) return false;
    final parsed = db.parsed(card);
    final instantSpeed = card.isInstant || parsed.has(KeywordKind.flash);
    if (!state.phase.isMain && !instantSpeed) return false;
    const combatPhases = {Phase.beginCombat, Phase.declareAttackers, Phase.declareBlockers, Phase.combatDamage, Phase.endCombat, Phase.end};
    if (!state.phase.isMain && !combatPhases.contains(state.phase)) return false;
    if (!canPay(card.cost, p)) return false;
    if (parsed.isAura && legalTargets(Filter.creature, p, id).isEmpty) return false;
    return true;
  }

  bool canPlayLand(ObjectID id, PlayerID p) {
    if (state.pending != null || state.winner != null || state.activePlayer != p || !state.phase.isMain) return false;
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || o.zone != Zone.hand || card == null || !card.isLand) return false;
    return state.players[p].landsPlayedThisTurn < landsAllowed(p);
  }

  int landsAllowed(PlayerID p) => 1 + state.permanentsOf(p).where((o) => parsedOf(o)?.statics.contains(SimpleStatic.extraLandEachTurn) == true).length;

  /// The spell's targets the caster must pick, in order: each `ChosenTarget` in its effects.
  List<TargetRequirement> targetRequirementsForCard(Card card, int? mode) {
    final parsed = db.parsed(card);
    var effects = parsed.spellEffects;
    if (parsed.isAura) return [TargetRequirement(Filter.creature, 1, false)];
    if (mode != null) {
      final modal = effects.whereType<Modal>().firstOrNull;
      if (modal != null && mode < modal.modes.length) effects = modal.modes[mode];
    }
    return targetRequirementsIn(effects);
  }

  List<TargetRequirement> targetRequirementsIn(List<Effect> effects) {
    final out = <TargetRequirement>[];
    void add(Target t) {
      if (t is ChosenTarget) out.add(TargetRequirement(t.filter, t.count, t.optional));
    }
    for (final e in effects) {
      switch (e) {
        case Damage x:
          add(x.target);
        case Draw x:
          add(x.target);
        case GainLife x:
          add(x.target);
        case LoseLife x:
          add(x.target);
        case Destroy x:
          add(x.target);
        case Exile x:
          add(x.target);
        case Bounce x:
          add(x.target);
        case Tap x:
          add(x.target);
        case Untap x:
          add(x.target);
        case Pump x:
          add(x.target);
        case AddCounters x:
          add(x.target);
        case Mill x:
          add(x.target);
        case Discard x:
          add(x.target);
        case Sacrifice x:
          add(x.target);
        case GrantKeyword x:
          add(x.target);
        case Fight x:
          add(x.target);
        case Bite x:
          add(x.target);
        case Explore x:
          add(x.target);
        case CantBlock x:
          add(x.target);
        case GainControl x:
          add(x.target);
        case SacrificeAtEndOfTurn x:
          add(x.target);
        case AssimilateFromLibrary x:
          add(x.target);
        case AssimilateExiledOrExile x:
          add(x.target);
        case CopyToken x:
          add(x.target);
        case CreateTokens x:
          add(x.target);
        case SearchBasicLand x:
          add(x.target);
        case FightBetween x:
          add(x.a);
          add(x.b);
        case ReturnFromGraveyard x:
          out.add(TargetRequirement(x.filter, 1, false));
        case Assimilate x:
          out.add(TargetRequirement(x.filter, 1, false));
        case Optional x:
          out.addAll(targetRequirementsIn(x.effects));
        case IfDidPrevious x:
          out.addAll(targetRequirementsIn(x.effects));
        case KickedInstead x:
          out.addAll(targetRequirementsIn(x.effects));
        case Conditional x:
          out.addAll(targetRequirementsIn(x.effects));
        default:
          break;
      }
    }
    return out;
  }
}
