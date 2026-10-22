part of 'game.dart';

/// What a permanent is right now, with counters, pumps, attachments and statics applied.
class Characteristics {
  Characteristics({
    required this.name,
    required this.power,
    required this.toughness,
    required this.keywords,
    required this.isCreature,
    required this.isArtifact,
    required this.isEnchantment,
    required this.isLand,
    required this.isSpacecraft,
    required this.subtypes,
  });
  String name;
  int power, toughness;
  Set<Keyword> keywords;
  bool isCreature, isArtifact, isEnchantment, isLand, isSpacecraft;
  Set<String> subtypes;
  bool cantAttackOrBlock = false;

  bool has(KeywordKind kind) => keywords.any((k) => k.kind == kind);
  int get wardCost => keywords.where((k) => k.kind == KeywordKind.ward).map((k) => k.value).firstOrNull ?? 0;

  static Characteristics empty() =>
      Characteristics(name: '?', power: 0, toughness: 0, keywords: {}, isCreature: false, isArtifact: false, isEnchantment: false, isLand: false, isSpacecraft: false, subtypes: {});
}

class TargetRequirement {
  TargetRequirement(this.filter, this.count, this.optional);
  final Filter filter;
  final int count;
  final bool optional;
}

extension GameQueries on Game {
  Card? cardOf(GameObject o) {
    final id = o.copiedCardID ?? o.cardID;
    return id.isEmpty ? null : db[id];
  }

  Card? card(ObjectID id) {
    final o = state.objects[id];
    return o == null ? null : cardOf(o);
  }

  ParsedCard? parsedOf(GameObject o) {
    final c = cardOf(o);
    if (c != null) return db.parsed(c);
    final t = o.token;
    return t == null ? null : db.parsedToken(t);
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
      c = Characteristics(
        name: t.name,
        power: t.power,
        toughness: t.toughness,
        keywords: {...t.keywords, ...db.parsedToken(t).keywords},
        isCreature: t.isCreature,
        isArtifact: t.isArtifact,
        isEnchantment: false,
        isLand: t.isLand,
        isSpacecraft: false,
        subtypes: Set.of(t.subtypes),
      );
    } else if (card != null && parsedCard != null) {
      c = Characteristics(
        name: card.name,
        power: card.basePower,
        toughness: card.baseToughness,
        keywords: Set.of(parsedCard.keywords),
        isCreature: card.isCreature,
        isArtifact: card.isArtifact,
        isEnchantment: card.isEnchantment,
        isLand: card.isLand,
        isSpacecraft: card.isSpacecraft,
        subtypes: Set.of(card.subtypes),
      );
      if (t != null) c.keywords.addAll(t.keywords);
      if (o.basePowerOverride != null) c.power = o.basePowerOverride!;
      if (o.baseToughnessOverride != null) c.toughness = o.baseToughnessOverride!;
      if (card.isSpacecraft) {
        // It becomes an artifact creature at its last station line, if it has power and toughness.
        final threshold = card.power == null ? null : (parsedCard.stationThreshold ?? card.stationThreshold);
        if (threshold != null && o.chargeCounters >= threshold) c.isCreature = true;
        for (final line in parsedCard.stationLines) {
          if (o.chargeCounters >= line.threshold) c.keywords.addAll(line.keywords);
        }
      }
      for (final s in staticsOf(o)) {
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
    for (final e in [...o.untilEndOfTurn, for (final l in o.lasting) l.effect]) {
      switch (e) {
        case PumpEffect p:
          c.power += p.power;
          c.toughness += p.toughness;
        case KeywordEffect k:
          c.keywords.add(k.keyword);
        case CantBlockEffect _:
          c.keywords.add(Keyword.cantBlock);
        case TypeEffect t:
          if (t.replace) c.subtypes = {t.subtype};
          c.subtypes.add(t.subtype);
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
      for (final s in staticsOf(other)) {
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
      case FilterKind.creatureToken:
        if (!o.isToken || !c.isCreature) return false;
      case FilterKind.creatureCardInGraveyard:
      case FilterKind.cardInGraveyard:
      case FilterKind.permanentCardInGraveyard:
      case FilterKind.basicLandCardInLibrary:
      case FilterKind.spell:
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
    if (f.minManaValue != null && (cardOf(o)?.manaValue ?? 0) < f.minManaValue!) return false;
    if (f.legendary && !isLegendary(o)) return false;
    if (f.nonBorg && c.subtypes.contains('Borg')) return false;
    if (f.enteredThisTurn && o.enteredTurn != state.turn) return false;
    if (f.historic && !(c.isArtifact || isLegendary(o) || (cardOf(o)?.isSaga ?? false))) return false;
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
    if (f.kind == FilterKind.spell) {
      for (final item in state.stack) {
        if (item.id == source) continue;
        final c = card(item.id);
        if (c == null) continue;
        if (f.maxManaValue != null && c.manaValue + item.x > f.maxManaValue!) continue;
        if (f.controller == Controller.you && item.controller != controller) continue;
        if (f.controller == Controller.opponent && item.controller == controller) continue;
        out.add(item.id);
      }
      return out;
    }
    if (f.kind == FilterKind.creatureCardInGraveyard || f.kind == FilterKind.cardInGraveyard || f.kind == FilterKind.permanentCardInGraveyard) {
      for (final p in state.players) {
        if (f.controller == Controller.you && p.id != controller) continue;
        if (f.controller == Controller.opponent && p.id == controller) continue;
        for (final id in p.graveyard) {
          final o = state.objects[id];
          final c = o == null ? null : cardOf(o);
          if (c == null) continue;
          if (f.kind == FilterKind.creatureCardInGraveyard && !c.isCreature) continue;
          if (f.kind == FilterKind.permanentCardInGraveyard && (c.isInstant || c.isSorcery)) continue;
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
  bool shallowIsLand(GameObject o) => cardOf(o)?.isLand ?? o.token?.isLand ?? false;

  /// Creature types from the card alone (assimilated creatures are Borg).
  Set<String> shallowSubtypes(GameObject o) {
    if (o.assimilated) return {'Borg'};
    final c = cardOf(o);
    return {...?c?.subtypes, ...?o.token?.subtypes}..remove('Spacecraft');
  }

  /// Legendary right now: printed legendary (or a legendary token), unless it is a copy "except
  /// it isn't legendary".
  bool isLegendary(GameObject o) => !o.nonLegendary && (cardOf(o)?.isLegendary ?? o.token?.isLegendary ?? false);

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
      case AmountKind.artifactCreaturesYouControl:
        return state.permanentsOf(controller).where((o) => shallowIsCreature(o) && shallowIsArtifact(o)).length;
      case AmountKind.creatureTypesNonBorg:
        final types = <String>{};
        for (final o in state.permanentsOf(controller)) {
          if (!shallowIsCreature(o)) continue;
          final sub = shallowSubtypes(o);
          if (sub.contains('Borg')) continue;
          types.addAll(sub);
        }
        return types.length;
      case AmountKind.x:
        return context.x;
      case AmountKind.twiceX:
        return context.x * 2;
      case AmountKind.eventAmount:
        return context.eventAmount;
      case AmountKind.artifactOrCreatureCardsInGraveyard:
        return state.players[controller].graveyard.where((id) {
          final c = card(id);
          return c != null && (c.isArtifact || c.isCreature);
        }).length;
      case AmountKind.dilemmasThisTurn:
        return state.players[controller].dilemmasThisTurn;
      case AmountKind.opponentsAttacked:
        return state.players[controller].opponentsAttackedThisTurn;
      case AmountKind.subtypeYouControl:
        return state.permanentsOf(controller).where((o) => shallowSubtypes(o).contains(a.subtype)).length;
      case AmountKind.countedThisWay:
        return context.counted;
      case AmountKind.otherCreaturesWithCommunicator:
        final hosts = <ObjectID>{};
        for (final o in state.permanentsOf(controller)) {
          final host = o.attachedTo;
          if (host != null && host != source && (cardOf(o)?.subtypes.contains('Communicator') ?? false)) hosts.add(host);
        }
        final equipped = source == null ? null : state.objects[source]?.attachedTo;
        hosts.remove(equipped);
        return hosts.length;
    }
  }

  bool isCreature(ObjectID id) => characteristics(id).isCreature;

  bool hasSummoningSickness(GameObject o) => o.enteredTurn == state.turn && !characteristics(o.id).has(KeywordKind.haste);

  bool canAttack(ObjectID id) {
    final o = state.objects[id];
    if (o == null || o.zone != Zone.battlefield || o.tapped) return false;
    final c = characteristics(id);
    if (state.players[o.controller].cantAttackThisTurn) return false;
    return c.isCreature && !c.has(KeywordKind.defender) && !c.cantAttackOrBlock && !hasSummoningSickness(o);
  }

  /// Whether `p` may play this card from where it is: their hand; exile when an effect let them
  /// (or the card can be cast from exile); the top of their library (Captain Pike, Benjamin
  /// Sisko); their graveyard once a turn (The Holodeck).
  bool playableFromZone(GameObject o, PlayerID p) {
    final c = cardOf(o);
    if (c == null) return false;
    switch (o.zone) {
      case Zone.hand:
        return o.owner == p;
      case Zone.exile:
        if (o.playableBy == p && state.turn <= o.playableUntilTurn) return true;
        if (o.owner == p && o.qCopyable && state.activePlayer == p && state.players[p].hand.isNotEmpty) return true;
        return o.owner == p && db.parsed(c).statics.contains(const SimpleStatic(SimpleStaticKind.castSelfFromExile));
      case Zone.library:
        if (o.owner != p || state.players[p].library.firstOrNull != o.id) return false;
        if (c.isLand && (controlsStatic(p, SimpleStaticKind.playLandsFromTop) || controlsStatic(p, SimpleStaticKind.playLandsAndCreaturesFromTop))) return true;
        return c.isCreature && controlsStatic(p, SimpleStaticKind.playLandsAndCreaturesFromTop);
      case Zone.graveyard:
        return o.owner == p && c.isPermanent && state.activePlayer == p && !state.players[p].usedGraveyardPlayThisTurn && controlsStatic(p, SimpleStaticKind.playPermanentFromGraveyardOncePerTurn);
      default:
        return false;
    }
  }

  /// Cards outside the hand that `p` may play right now (shown on the table so they can be tapped).
  List<ObjectID> extraPlayables(PlayerID p) {
    final out = <ObjectID>[];
    final top = state.players[p].library.firstOrNull;
    for (final id in [...state.players[p].exile, ...state.players[p].graveyard, ...state.players[state.opponentOf(p)].exile, ?top]) {
      final o = state.objects[id];
      if (o != null && playableFromZone(o, p) && (canCast(id, p) || canPlayLand(id, p))) out.add(id);
    }
    return out;
  }

  bool canBlock(ObjectID blocker, ObjectID attacker) {
    final b = state.objects[blocker];
    if (b == null || b.zone != Zone.battlefield || b.tapped) return false;
    final bc = characteristics(blocker), ac = characteristics(attacker);
    if (!bc.isCreature || bc.has(KeywordKind.cantBlock) || bc.cantAttackOrBlock) return false;
    if (ac.has(KeywordKind.unblockable)) return false;
    if (ac.has(KeywordKind.flying) && !bc.has(KeywordKind.flying) && !bc.has(KeywordKind.reach)) return false;
    for (final k in ac.keywords) {
      if (k.kind == KeywordKind.evadesSmall && bc.power <= k.value) return false;
    }
    return true;
  }

  /// Untapped sources of mana: (object, colors it can make; empty = colorless, usesSacrifice).
  /// Mana in a player's pool, as pseudo sources: object id `poolID(p, i)`.
  static ObjectID poolID(PlayerID p, int i) => -1000 - p * 100 - i;

  List<(ObjectID, List<ManaColor>, bool)> manaSources(PlayerID p, {Card? forSpell}) {
    final out = <(ObjectID, List<ManaColor>, bool)>[];
    var i = 0;
    final pool = state.players[p].manaPool;
    for (final key in (pool.keys.toList()..sort())) {
      for (var n = 0; n < pool[key]!; n++) {
        final c = ManaColor.fromSymbol(key);
        out.add((GameQueries.poolID(p, i++), c == null ? <ManaColor>[] : [c], false));
      }
    }
    final noTreasureSacrifice = controlsStatic(p, SimpleStaticKind.cantSacrificeTreasures);
    for (final o in state.permanentsOf(p)) {
      if (o.tapped) continue;
      final parsed = parsedOf(o);
      if (parsed == null) continue;
      final manaAbilities = parsed.abilities.whereType<ManaAbility>().where((m) => m.amount > 0 && (!m.artifactSpellsOnly || (forSpell?.isArtifact ?? false))).toList();
      if (manaAbilities.isNotEmpty) {
        if (characteristics(o.id).isCreature && hasSummoningSickness(o)) continue;
        final best = manaAbilities.reduce((a, b) => b.amount > a.amount ? b : a);
        if (best.amount > 1) {
          // One tap, several mana (Gumato, Command Chair): one entry per mana.
          for (var n = 0; n < best.amount; n++) {
            out.add((o.id, List.of(best.colors), false));
          }
        } else {
          out.add((o.id, manaAbilities.expand((m) => m.colors).toSet().toList(), false));
        }
        continue;
      }
      for (final a in parsed.abilities) {
        if (a is Activated && a.cost.tap && a.effects.length == 1 && a.effects[0] is AddMana && a.cost.mana.isFree && a.cost.payLife == 0) {
          if (a.cost.sacrificeSelf && noTreasureSacrifice && (o.token?.subtypes.contains('Treasure') ?? false)) continue;
          out.add((o.id, (a.effects[0] as AddMana).colors, a.cost.sacrificeSelf));
        }
      }
    }
    return out;
  }

  /// Which sources to tap to pay a cost, or null if it can't be paid. Colored needs first, from
  /// the pickiest sources; Treasures last.
  List<ObjectID>? manaPlan(ManaCost cost, PlayerID player, {Card? forSpell}) {
    final sources = manaSources(player, forSpell: forSpell);
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
    // A source making several mana makes them all one color: once one is spent on a color, the
    // rest of that source can only be that color.
    void commit(int i, ManaColor color) {
      final id = sources[i].$1;
      used.add(id);
      sources.removeAt(i);
      if (id <= -1000) return;
      for (var j = 0; j < sources.length; j++) {
        if (sources[j].$1 == id) sources[j] = (id, [color], sources[j].$3);
      }
    }

    for (final color in needs) {
      final i = sources.indexWhere((s) => s.$2.contains(color));
      if (i < 0) return null;
      commit(i, color);
    }
    for (final pair in cost.hybrid) {
      final i = sources.indexWhere((s) => s.$2.any(pair.contains));
      if (i < 0) return null;
      commit(i, sources[i].$2.firstWhere(pair.contains));
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

  /// The abilities a card has where it is now: a permanent's active abilities, or a card's own
  /// abilities in a hand or graveyard (only those activated from there can be used).
  List<Ability> abilitiesIn(GameObject o) {
    if (o.zone == Zone.battlefield) return activeAbilities(o);
    return parsedOf(o)?.abilities ?? const [];
  }

  /// The permanents a "tap N untapped …" cost would tap: tokens first, then the weakest. The
  /// source counts when it fits (Picard is an Officer); summoning sickness doesn't matter, since
  /// the cost isn't {T}.
  List<ObjectID>? tapOthersChoice(ActivationCost cost, PlayerID p, ObjectID source) {
    final f = cost.tapOthersFilter;
    if (cost.tapOthers == 0 || f == null) return const [];
    final ready = state.permanentsOf(p).where((o) => !o.tapped && matches(f, o.id, p, source)).toList()
      ..sort((a, b) {
        if (a.isToken != b.isToken) return a.isToken ? -1 : 1;
        final pa = characteristics(a.id).power, pb = characteristics(b.id).power;
        return pa != pb ? pa - pb : a.id - b.id;
      });
    if (ready.length < cost.tapOthers) return null;
    return ready.take(cost.tapOthers).map((o) => o.id).toList();
  }

  /// The counters "remove N counters from among creatures you control" would take: any kind but
  /// +1/+1 first, from the creatures holding the most.
  List<(ObjectID, CounterKind)>? removeCountersChoice(ActivationCost cost, PlayerID p) {
    if (cost.removeCounters == 0) return const [];
    final pool = <(ObjectID, CounterKind)>[];
    final holders = state.permanentsOf(p).where((o) => characteristics(o.id).isCreature).toList()..sort((a, b) => a.id - b.id);
    for (final pass in [false, true]) {
      for (final o in holders) {
        for (final e in o.counters.entries.toList()..sort((a, b) => a.key.index - b.key.index)) {
          if ((e.key == CounterKind.plusOne) != pass) continue;
          for (var i = 0; i < e.value; i++) {
            pool.add((o.id, e.key));
          }
        }
      }
    }
    if (pool.length < cost.removeCounters) return null;
    return pool.take(cost.removeCounters).toList();
  }

  /// Why the ability can't be activated now, or null if it can (targets and choices aside).
  String? activationProblem(ObjectID id, int index, PlayerID p) {
    final o = state.objects[id];
    if (o == null) return 'No such ability';
    final all = abilitiesIn(o);
    if (index >= all.length) return 'No such ability';
    final ability = all[index];
    if (ability is! Activated) return 'No such ability';
    final cost = ability.cost;
    switch (cost.zone) {
      case AbilityZone.battlefield:
        if (o.zone != Zone.battlefield || o.controller != p) return 'Not yours to use';
      case AbilityZone.hand:
        if (o.zone != Zone.hand || o.owner != p) return 'Only from your hand';
      case AbilityZone.graveyard:
        if (o.zone != Zone.graveyard || o.owner != p) return 'Only from your graveyard';
    }
    if (ability.sorcerySpeed && (!state.phase.isMain || state.priority != null || state.stack.isNotEmpty || state.activePlayer != p)) return 'Only as a sorcery';
    if (cost.oncePerTurn && o.activatedThisTurn.contains(index)) return 'Already used this turn';
    if (cost.tap) {
      if (o.tapped) return 'Already tapped';
      if (characteristics(id).isCreature && hasSummoningSickness(o)) return 'Summoning sick';
    }
    if (cost.payLife > 0 && state.players[p].life <= cost.payLife) return 'Not enough life';
    if (cost.minDifferentLands > 0 && amount(const Amount.counted(AmountKind.differentlyNamedLands), p, id, EffectContext()) < cost.minDifferentLands) {
      return 'Needs ${cost.minDifferentLands} differently named lands';
    }
    if (tapOthersChoice(cost, p, id) == null) return 'Not enough untapped permanents to tap';
    if (removeCountersChoice(cost, p) == null) return 'Not enough counters';
    if (cost.discard > 0 && state.players[p].hand.where((h) => h != id).length < cost.discard) return 'No card to discard';
    final f = cost.sacrifice;
    if (f != null && !state.permanentsOf(p).any((x) => matches(f, x.id, p, id))) return 'Nothing to sacrifice';
    if (!canPay(cost.mana, p)) return 'Not enough mana';
    return null;
  }

  int availableMana(PlayerID p) => manaSources(p).length;

  /// Whether a card in hand can be cast now (timing + mana), ignoring targets.
  bool canCast(ObjectID id, PlayerID p) {
    if (state.pending != null || state.winner != null) return false;
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null || card.isLand || !playableFromZone(o, p)) return false;
    if (!_timingAllows(card, p)) return false;
    final cost = card.cost..generic += o.extraCost;
    reduceCost(cost, card, p, const []);
    if (manaPlan(cost, p, forSpell: card) == null) return false;
    if (db.parsed(card).isAura && legalTargets(auraFilter(card), p, id).isEmpty) return false;
    return true;
  }

  /// Extra mana for targeting permanents an opponent controls that have ward.
  int wardTax(List<ObjectID> targets, PlayerID p) {
    var tax = 0;
    for (final t in targets) {
      if (EffectContext.playerFromObject(t) != null) continue;
      final o = state.objects[t];
      if (o != null && o.zone == Zone.battlefield && o.controller != p) tax += characteristics(t).wardCost;
    }
    return tax;
  }

  /// Whether `p` can pay everything casting this card with these choices costs: mana cost, X,
  /// kicker, ward on the targets, minus reductions.
  bool canAffordCast(ObjectID id, PlayerID p, {List<ObjectID> targets = const [], bool kicked = false, int x = 0}) {
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null) return false;
    final cost = card.cost..generic += o.extraCost + (card.cost.hasX ? x : 0) + wardTax(targets, p);
    final k = db.parsed(card).kicker;
    if (kicked && k != null) cost.add(k);
    reduceCost(cost, card, p, targets);
    return manaPlan(cost, p, forSpell: card) != null;
  }

  /// The largest X `p` can pay for when casting this card (0 when it has no X).
  int maxX(ObjectID id, PlayerID p) {
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null || !card.cost.hasX) return 0;
    var x = 0;
    while (x < 20) {
      final cost = card.cost..generic += o.extraCost + x + 1;
      reduceCost(cost, card, p, const []);
      if (manaPlan(cost, p, forSpell: card) == null) break;
      x++;
    }
    return x;
  }

  /// Whether the card's sacrifice kicker ("Kicker—Sacrifice an artifact or creature") can be paid.
  bool canSacrificeKick(ObjectID id, PlayerID p) {
    final card = this.card(id);
    final sk = card == null ? null : db.parsed(card).abilities.whereType<SacrificeKicker>().firstOrNull;
    if (sk == null) return false;
    final f = sk.filter.copy()..controller = Controller.you;
    return state.permanentsOf(p).any((c) => matches(f, c.id, p, id));
  }

  /// Whether `p` holds an instant or flash card they could cast in response right now, with a
  /// target for it. Windows to respond only open when this is true, so nobody is asked to pass
  /// when they have nothing.
  bool hasResponses(PlayerID p) {
    if (state.players[p].lost) return false;
    for (final id in state.players[p].hand) {
      final card = this.card(id);
      if (card == null || card.isLand) continue;
      final parsed = db.parsed(card);
      if (!card.isInstant && !parsed.has(KeywordKind.flash)) continue;
      if (!canPay(card.cost, p)) continue;
      if (card.isInstant && parsed.spellEffects.isEmpty) continue;
      if (_hasTargetsFor(card, p, id)) return true;
    }
    return false;
  }

  /// Whether every required target of the card (in at least one mode) has a legal choice.
  bool _hasTargetsFor(Card card, PlayerID p, ObjectID id) {
    final parsed = db.parsed(card);
    if (parsed.isAura) return legalTargets(auraFilter(card), p, id).isNotEmpty;
    final modal = parsed.spellEffects.whereType<Modal>().firstOrNull;
    final modes = modal == null ? <int?>[null] : List<int?>.generate(modal.modes.length, (i) => i);
    for (final m in modes) {
      for (final kicked in [false, if (parsed.kicker != null) true]) {
        final reqs = targetRequirementsForCard(card, m, kicked: kicked);
        if (reqs.every((r) => r.optional || legalTargets(r.filter, p, id).isNotEmpty)) return true;
      }
    }
    return false;
  }

  bool canPlayLand(ObjectID id, PlayerID p) {
    if (state.pending != null || state.winner != null || state.priority != null || state.stack.isNotEmpty || state.activePlayer != p || !state.phase.isMain) return false;
    final o = state.objects[id];
    final card = o == null ? null : cardOf(o);
    if (o == null || card == null || !card.isLand || !playableFromZone(o, p)) return false;
    return state.players[p].landsPlayedThisTurn < landsAllowed(p);
  }

  int landsAllowed(PlayerID p) => 1 + state.permanentsOf(p).where((o) => parsedOf(o)?.statics.contains(SimpleStatic.extraLandEachTurn) == true).length;

  /// What an Aura can enchant: "Enchant creature", "Enchant artifact or creature", "Enchant
  /// creature an opponent controls".
  Filter auraFilter(Card card) {
    final statics = db.parsed(card).statics;
    if (statics.contains(SimpleStatic.enchantArtifactOrCreature)) return Filter(FilterKind.artifactOrCreature);
    if (statics.contains(SimpleStatic.enchantCreatureOpponentControls)) return Filter(FilterKind.creature, controller: Controller.opponent);
    return Filter.creature;
  }

  /// Whether a permanent can still carry this Aura (an artifact Aura host must stay an artifact
  /// or creature, a creature Aura host a creature).
  bool auraFits(GameObject aura, ObjectID host) {
    final card = cardOf(aura);
    final c = characteristics(host);
    if (card == null) return c.isCreature;
    return auraFilter(card).kind == FilterKind.artifactOrCreature ? (c.isCreature || c.isArtifact) : c.isCreature;
  }

  /// The spell's targets the caster must pick, in order: each `ChosenTarget` in its effects.
  /// Kicked, a spell whose "instead" text names its own target (Highly Illogical) asks for that
  /// one; one that reuses "that creature" (Burst Lightning) keeps the unkicked target.
  List<TargetRequirement> targetRequirementsForCard(Card card, int? mode, {bool kicked = false}) {
    final parsed = db.parsed(card);
    var effects = parsed.spellEffects;
    if (parsed.isAura) return [TargetRequirement(auraFilter(card), 1, false)];
    if (mode != null) {
      final modal = effects.whereType<Modal>().firstOrNull;
      if (modal != null && mode < modal.modes.length) effects = modal.modes[mode];
    }
    final i = effects.indexWhere((e) => e is KickedInstead);
    if (i < 0) return targetRequirementsIn(effects);
    final unkicked = [...effects.sublist(0, i), ...effects.sublist(i + 1)];
    if (kicked) {
      final instead = [...(effects[i] as KickedInstead).effects, ...effects.sublist(i + 1)];
      final own = targetRequirementsIn(instead);
      if (targetRequirementsIn((effects[i] as KickedInstead).effects).isNotEmpty) return own;
    }
    return targetRequirementsIn(unkicked);
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
        case CounterSpell x:
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
        case Conditional x:
          out.addAll(targetRequirementsIn(x.effects));
        default:
          break;
      }
    }
    return out;
  }
}
