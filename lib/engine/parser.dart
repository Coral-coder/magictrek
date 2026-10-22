import 'abilities.dart';
import 'cards.dart';

/// Turns a card's rules text into abilities. Pattern-based: it knows the phrasings this set
/// uses and leaves the rest as `Unsupported`, so every card is at least playable for its stats.
class AbilityParser {
  static ParsedCard parse(Card card) => _Parser(card).run();
}

/// Anchored, case-insensitive match; returns the groups ('' for unmatched optional groups) or null.
List<String>? rx(String text, String pattern, {bool dotAll = false}) {
  final re = RegExp('^(?:$pattern)\$', caseSensitive: false, dotAll: dotAll);
  final m = re.firstMatch(text);
  if (m == null) return null;
  return List.generate(m.groupCount + 1, (i) => m.group(i) ?? '');
}

String replacing(String text, String pattern, String replacement) => text.replaceAll(RegExp(pattern, caseSensitive: false), replacement);

int? numberWord(String word) {
  final w = word.toLowerCase().trim();
  final n = int.tryParse(w);
  if (n != null) return n;
  const words = {
    'a': 1,
    'an': 1,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'twenty': 20,
  };
  return words[w];
}

const _num = r'(a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve|\d+|x)';

class _Parser {
  _Parser(this.card);
  final Card card;
  final List<Ability> abilities = [];
  final List<String> unsupported = [];

  ParsedCard run() {
    final text = normalize(card.rulesText);
    var lines = text.split('\n').map((l) => l.trim()).toList();
    // "Choose one —" followed by bullet lines is one ability.
    final grouped = <String>[];
    var i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (i + 1 < lines.length && lines[i + 1].startsWith('•')) {
        var j = i + 1;
        while (j < lines.length && lines[j].startsWith('•')) {
          line += '\n${lines[j]}';
          j++;
        }
        i = j;
      } else {
        i++;
      }
      grouped.add(line);
    }
    lines = grouped;
    if (card.isSaga) {
      parseSaga(lines);
      return finish();
    }
    for (final line in lines) {
      parseLine(line);
    }
    return finish();
  }

  ParsedCard finish() {
    // Basic lands and dual lands keep their mana ability in reminder text, which is stripped.
    if (card.isLand && !abilities.any((a) => a is ManaAbility) && (card.producedMana.isNotEmpty || card.producesColorless)) {
      abilities.add(ManaAbility(List.of(card.producedMana)));
    }
    if (card.isSpacecraft && card.keywords.contains('Station') && !abilities.contains(const KeywordAbility(Keyword.station))) {
      abilities.add(const KeywordAbility(Keyword.station));
    }
    return ParsedCard(abilities, unsupported);
  }

  /// Self-references become "~", "U.S.S." stops looking like a sentence end, smart quotes go.
  String normalize(String text) {
    var t = text.replaceAll('U.S.S.', 'USS').replaceAll('’', "'").replaceAll('−', '-').replaceAll('–', '-');
    final fullName = card.name.replaceAll('U.S.S.', 'USS');
    final names = [fullName];
    final comma = fullName.indexOf(',');
    final head = comma >= 0 ? fullName.substring(0, comma) : fullName;
    if (comma >= 0) names.add(head);
    // Legends call themselves by a shorter name: "Dr. Crusher", "Captain Burnham", "Captain Kirk".
    final words = head.split(' ');
    if (card.isLegendary && words.length >= 3) names.add('${words.first} ${words.last}');
    names.sort((a, b) => b.length - a.length);
    for (final n in names) {
      if (n.isNotEmpty) t = t.replaceAll(n, '~');
    }
    t = replacing(t, r'\bthis (creature|Spacecraft|artifact|enchantment|land|permanent|token|card|Saga|Equipment|Aura|spell|vehicle)\b', '~');
    return t;
  }

  void parseLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;

    // Spacecraft: "6+ | Flying, lifelink"
    final station = rx(line, r'(\d+)\+\s*\|\s*(.*)');
    if (station != null) {
      final parts = station[2].split(',').map((s) => s.trim()).toList();
      final kws = parts.map(keyword).whereType<Keyword>().toList();
      if (kws.length == parts.length) {
        abilities.add(StationAbilities(int.parse(station[1]), kws));
      } else {
        // "3+ | At the beginning of combat ...", "12+ | Artifact creatures you control have flying."
        final sub = _Parser(card);
        sub.parseLine(station[2]);
        abilities.add(StationAbilities(int.parse(station[1]), const [], sub.abilities));
        unsupported.addAll(sub.unsupported);
      }
      return;
    }
    // Ability words ("Landfall — ", "Cloaking Device — ") are just labels.
    var body = line;
    final label = rx(line, r"([A-Z][A-Za-z' ]+) — (.+)");
    if (label != null && !label[1].toLowerCase().startsWith('choose')) body = label[2];
    final bl = body.toLowerCase();

    final special = specialLine(_trimDot(bl));
    if (special != null) {
      abilities.addAll(special);
      return;
    }
    final kws = keywordLine(body);
    if (kws != null) {
      abilities.addAll(kws);
      return;
    }
    final restricted = rx(body, r'\{T\}: Add (.+?)\. Spend this mana only to cast an artifact spell\.?');
    if (restricted != null) {
      final colors = manaColors(restricted[1]);
      if (colors != null) {
        abilities.add(ManaAbility(colors, artifactSpellsOnly: true));
        return;
      }
    }
    final mana = rx(body, r'\{T\}: Add (.+?)\.?');
    if (mana != null) {
      final text = mana[1].toLowerCase();
      // Commanders don't exist here, so "X mana, where X is … among commanders" is always 0.
      if (text.contains('commanders you control')) {
        abilities.add(const ManaAbility([], amount: 0));
        return;
      }
      final many = rx(text, r'(two|three|four|five) mana of any one color');
      if (many != null) {
        abilities.add(ManaAbility(List.of(ManaColor.values), amount: numberWord(many[1]) ?? 1));
        return;
      }
      final colors = manaColors(mana[1]);
      if (colors != null) {
        // {G}{G}{G} and {C}{C}: several of one color from one tap.
        final symbols = RegExp(r'\{[a-z]\}').allMatches(text).map((m) => m[0]).toList();
        final repeated = !text.contains(' or ') && symbols.length > 1 && symbols.toSet().length == 1;
        abilities.add(repeated ? ManaAbility(colors.isEmpty ? const [] : [colors.first], amount: symbols.length) : ManaAbility(colors));
        return;
      }
    }
    final s = staticAbility(bl, body);
    if (s != null) {
      abilities.add(StaticAbilityEntry(s));
      return;
    }
    if (bl.startsWith('when') || bl.startsWith('at the beginning of')) {
      parseTriggered(body);
      return;
    }
    final act = rx(body, r'([^:"]+): (.+)', dotAll: true);
    if (act != null) {
      final cost = activationCost(act[1]);
      if (cost != null) {
        var effectText = act[2];
        var sorcery = false;
        var m = rx(effectText, r'(.+?)\s*Activate only as a sorcery\.?');
        if (m != null) {
          effectText = m[1];
          sorcery = true;
        }
        m = rx(effectText, r'(.+?)\s*Activate only once each turn\.?');
        if (m != null) {
          effectText = m[1];
          cost.oncePerTurn = true;
        }
        m = rx(effectText, r'(.+?)\s*Activate only during your turn\.?');
        if (m != null) {
          effectText = m[1];
          sorcery = true;
        }
        m = rx(effectText, r'(.+?)\s*Activate only as a sorcery and only once each turn\.?');
        if (m != null) {
          effectText = m[1];
          sorcery = true;
          cost.oncePerTurn = true;
        }
        m = rx(effectText, r'(.+?)\s*Activate only if you control (\w+) or more differently named lands\.?');
        if (m != null) {
          effectText = m[1];
          cost.minDifferentLands = numberWord(m[2]) ?? 0;
        }
        final (fx, bad) = effects(effectText);
        if (bad.isEmpty && fx.isNotEmpty) {
          abilities.add(Activated(cost, fx, sorcerySpeed: sorcery, text: body.trim()));
        } else {
          unsupported.add(line);
        }
        return;
      }
    }
    if (card.isInstant || card.isSorcery) {
      final (fx, bad) = effects(body);
      if (bad.isEmpty && fx.isNotEmpty) {
        abilities.add(Spell(fx));
      } else {
        unsupported.addAll(bad.isEmpty ? [line] : bad);
      }
      return;
    }
    unsupported.add(line);
  }

  void parseSaga(List<String> lines) {
    final chapters = <List<Effect>>[];
    final bad = <String>[];
    for (final line in lines) {
      final m = rx(line, r'((?:I|II|III|IV|V)(?:, (?:I|II|III|IV|V))*) — (.+)');
      if (m == null) {
        if (line.isNotEmpty) bad.add(line);
        continue;
      }
      final (fx, b) = effects(m[2]);
      if (b.isNotEmpty || fx.isEmpty) {
        bad.add(line);
        continue;
      }
      for (final chapter in m[1].split(',').map((s) => s.trim())) {
        final n = const {'I': 1, 'II': 2, 'III': 3, 'IV': 4, 'V': 5}[chapter] ?? 1;
        while (chapters.length < n) {
          chapters.add([]);
        }
        chapters[n - 1] = fx;
      }
    }
    if (bad.isEmpty) {
      abilities.add(Saga(chapters));
    } else {
      unsupported.addAll(bad);
    }
  }

  // MARK: Keywords

  Keyword? keyword(String word) {
    var w = word.toLowerCase().trim();
    while (w.endsWith('.')) {
      w = w.substring(0, w.length - 1);
    }
    final ward = rx(w, r'ward \{(\d+)\}');
    if (ward != null) return Keyword(KeywordKind.ward, int.parse(ward[1]));
    if (w == 'ward') return const Keyword(KeywordKind.ward, 1);
    if (w == "can't be blocked" || w == "~ can't be blocked") return Keyword.unblockable;
    if (w == "can't block" || w == "~ can't block") return Keyword.cantBlock;
    final small = rx(w, r"(?:~ )?can't be blocked by creatures with power (\d+) or less");
    if (small != null) return Keyword(KeywordKind.evadesSmall, int.parse(small[1]));
    if (w == "~ can't be blocked by more than one creature" || w == "can't be blocked by more than one creature") return const Keyword(KeywordKind.oneBlocker);
    final kind = KeywordKind.fromText(w);
    return kind == null ? null : Keyword(kind);
  }

  List<Ability>? keywordLine(String line) {
    final out = <Ability>[];
    for (final part in line.split(',').map((s) => s.trim())) {
      var p = part.toLowerCase();
      while (p.endsWith('.')) {
        p = p.substring(0, p.length - 1);
      }
      final k = keyword(p);
      if (k != null) {
        out.add(KeywordAbility(k));
        continue;
      }
      List<String>? m;
      if ((m = rx(p, r'kicker (\{.+\})')) != null) {
        out.add(Kicker(ManaCost.parse(m![1].toUpperCase())));
        continue;
      }
      if ((m = rx(p, r'beam me up (\{.+\})')) != null) {
        out.add(BeamMeUp(ManaCost.parse(m![1].toUpperCase())));
        continue;
      }
      if ((m = rx(p, r'equip (\{.+\})')) != null) {
        out.add(Equip(ManaCost.parse(m![1].toUpperCase())));
        continue;
      }
      if ((m = rx(p, r'cycling (\{.+\})')) != null) {
        out.add(Cycling(ManaCost.parse(m![1].toUpperCase()), null));
        continue;
      }
      if ((m = rx(p, r'basic landcycling (\{.+\})')) != null) {
        out.add(Cycling(ManaCost.parse(m![1].toUpperCase()), 'basic'));
        continue;
      }
      if ((m = rx(p, r'(plains|island|swamp|mountain|forest)cycling (\{.+\})')) != null) {
        final t = m![1];
        out.add(Cycling(ManaCost.parse(m[2].toUpperCase()), t[0].toUpperCase() + t.substring(1)));
        continue;
      }
      if (p == 'enchant creature' || p == 'enchant artifact or creature') {
        out.add(StaticAbilityEntry(p == 'enchant creature' ? SimpleStatic.enchantCreature : SimpleStatic.enchantArtifactOrCreature));
        continue;
      }
      if (p == 'enchant creature an opponent controls') {
        out.add(const StaticAbilityEntry(SimpleStatic.enchantCreatureOpponentControls));
        continue;
      }
      if (p == 'affinity for artifact creatures') {
        out.add(Affinity(Filter(FilterKind.artifactCreature, controller: Controller.you)));
        continue;
      }
      if (p == 'affinity for artifacts') {
        out.add(Affinity(Filter(FilterKind.artifact, controller: Controller.you)));
        continue;
      }
      if (p == 'sunburst') {
        out.add(const Sunburst());
        continue;
      }
      if (p == 'kicker—sacrifice an artifact or creature') {
        out.add(SacrificeKicker(Filter(FilterKind.artifactOrCreature)));
        continue;
      }
      if (p == 'prowess') {
        out.add(const Triggered(CastSpellTrigger(SpellKind.noncreature), [Pump(1, 1, Target.thisObject, EffectDuration.endOfTurn)]));
        continue;
      }
      return null;
    }
    return out.isEmpty ? null : out;
  }

  List<ManaColor>? manaColors(String text) {
    final t = text.toLowerCase();
    if (t.contains('any color') || t.contains('any one color')) return List.of(ManaColor.values);
    if (t == '{c}' || t == '{c}{c}') return [];
    final colors = <ManaColor>[];
    var sym = '';
    var inSym = false;
    for (final ch in t.split('')) {
      if (ch == '{') {
        inSym = true;
        sym = '';
        continue;
      }
      if (ch == '}') {
        inSym = false;
        final c = ManaColor.fromSymbol(sym.toUpperCase());
        if (c != null) {
          colors.add(c);
        } else if (sym != 'c') {
          return null;
        }
        continue;
      }
      if (inSym) sym += ch;
    }
    final rest = replacing(t, r'\{[a-z]\}|or|,|\s|\.', '');
    return rest.isEmpty ? colors : null;
  }

  // MARK: Statics

  StaticAbility? staticAbility(String l, [String? original]) {
    final o = _trimDot(original ?? l);
    if (l == '~ enters tapped.' || l == '~ enters the battlefield tapped.') return SimpleStatic.entersTapped;
    List<String>? m;
    if ((m = rx(l, r'~ enters tapped unless you control (two|three) or more other lands\.')) != null) return EntersTappedUnless(numberWord(m![1]) ?? 2);
    if (l == "as ~ enters, you may pay 2 life. if you don't, it enters tapped.") return SimpleStatic.shockLand;
    if (l == 'you may play an additional land on each of your turns.') return SimpleStatic.extraLandEachTurn;
    if (l == 'you have no maximum hand size.') return SimpleStatic.noMaxHandSize;
    if (l == "~ can't be countered.") return SimpleStatic.cantBeCountered;
    if (l == "as long as ~ isn't a creature, it has hexproof.") return SimpleStatic.hexproofWhileNotCreature;
    if ((m = rx(l, r'during your turn, ~ has (.+?)\.')) != null) {
      final k = keyword(m![1]);
      if (k != null) return KeywordDuringYourTurn(k);
    }
    if ((m = rx(l, r'during your turn, (.+?) have (.+?)\.')) != null) {
      final f = filterFromPlural(m![1]);
      final k = keyword(m[2]);
      if (f != null && k != null) return GrantKeywordStatic(f, k, duringYourTurn: true);
    }
    if ((m = rx(l, r"~'s power( and toughness are each| is) equal to the number of (.+?)\.")) != null) {
      final a = countAmount(m![2]);
      if (a != null) return PowerEquals(a, andToughness: m[1].contains('toughness'));
    }
    if ((m = rx(l, r'(equipped|enchanted) creature gets ([+-]\d+)/([+-]\d+)(?: and has (.+?))?\.')) != null) {
      if (m![4].isEmpty) return AttachedGets(int.parse(m[2]), int.parse(m[3]));
      return null;
    }
    if ((m = rx(l, r'(equipped|enchanted) creature has (.+?)\.')) != null) {
      final k = keyword(m![2]);
      if (k != null) return AttachedHas(k);
    }
    if (l.startsWith("enchanted creature can't attack or block")) return SimpleStatic.attachedCantAttackOrBlock;
    if ((m = rx(l, r'~ gets \+(\d+)/\+(\d+) for each (artifact|creature|land) you control\.')) != null) {
      final kind = m![3] == 'artifact' ? AmountKind.artifactsYouControl : (m[3] == 'creature' ? AmountKind.creaturesYouControl : AmountKind.landsYouControl);
      return SelfPumpPerCount(Amount.counted(kind), int.parse(m[1]), int.parse(m[2]));
    }
    final simple = _simpleStatics[_trimDot(l)];
    if (simple != null) return SimpleStatic(simple);
    if ((m = rx(o, r'(.+?) have "(.+)"')) != null) {
      final f = filterFromPlural(m![1]);
      if (f != null) {
        final inner = m[2][0].toUpperCase() + m[2].substring(1);
        final parts = triggerParts(inner);
        if (parts != null && parts.length == 1) return GrantTrigger(f, parts[0].$1, parts[0].$2);
      }
      return null;
    }
    if ((m = rx(o, r'(.+?) (?:get|have) (.+?)')) != null) {
      final f = filterFromPlural(m![1]);
      if (f != null) {
        final n = rx(m[2], r'([+-]\d+)/([+-]\d+)');
        if (n != null) return Anthem(f, int.parse(n[1]), int.parse(n[2]));
        final k = keyword(m[2]);
        if (k != null) return GrantKeywordStatic(f, k);
      }
    }
    return null;
  }

  /// "creatures you control", "other Klingons you control", "artifact creatures you control".
  Filter? filterFromPlural(String s) {
    var text = s.toLowerCase();
    var withCounters = false;
    if (text.endsWith(' with counters on them')) {
      withCounters = true;
      text = text.substring(0, text.length - 22);
    }
    for (final suffix in [' with a counter on it', ' with a counter on them']) {
      if (text.endsWith(suffix)) {
        withCounters = true;
        text = text.substring(0, text.length - suffix.length);
      }
    }
    var entered = false;
    if (text.endsWith(' that entered this turn')) {
      entered = true;
      text = text.substring(0, text.length - 23);
    }
    var words = text.split(' ').where((w) => w.isNotEmpty).toList();
    if (words.length < 2) return null;
    var controller = Controller.any;
    if (_endsWith(words, ['you', 'control'])) {
      controller = Controller.you;
      words = words.sublist(0, words.length - 2);
    } else if (_endsWith(words, ['your', 'opponents', 'control']) || _endsWith(words, ['you', "don't", 'control'])) {
      controller = Controller.opponent;
      words = words.sublist(0, words.length - 3);
    }
    if (controller == Controller.any || words.isEmpty) return null;
    final f = Filter(FilterKind.permanent, controller: controller)
      ..withCounters = withCounters
      ..enteredThisTurn = entered;
    var noun = words.removeLast();
    if (noun.endsWith('s')) noun = noun.substring(0, noun.length - 1);
    final original = s.split(' ');
    switch (noun) {
      case 'creature':
        f.kind = FilterKind.creature;
      case 'artifact':
        f.kind = FilterKind.artifact;
      case 'spacecraft':
        f.kind = FilterKind.spacecraft;
      case 'permanent':
        f.kind = FilterKind.permanent;
      case 'land':
        f.kind = FilterKind.land;
      default:
        final idx = words.length;
        if (idx < original.length && _isUpper(original[idx])) {
          f.kind = FilterKind.creature;
          f.subtype = original[idx].endsWith('s') && original[idx] != 'Borg' ? original[idx].substring(0, original[idx].length - 1) : original[idx];
        } else {
          return null;
        }
    }
    for (final w in words) {
      switch (w) {
        case 'other':
          f.other = true;
        case 'artifact':
          f.kind = f.kind == FilterKind.creature ? FilterKind.artifactCreature : FilterKind.artifact;
        case 'nontoken':
          f.nontoken = true;
        case 'attacking':
          f.attacking = true;
        case 'tapped':
          f.tapped = true;
        case 'untapped':
          f.untapped = true;
        case 'legendary':
          f.legendary = true;
        case 'nonlegendary':
        case 'all':
          break;
        default:
          final o = original.where((x) => x.toLowerCase() == w).firstOrNull;
          if (o != null && _isUpper(o) && f.kind == FilterKind.creature) {
            f.subtype = o;
          } else {
            return null;
          }
      }
    }
    return f;
  }

  static String _trimDot(String s) {
    var t = s.trim();
    while (t.endsWith('.')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  static const _simpleStatics = <String, SimpleStaticKind>{
    "you can't sacrifice treasure tokens": SimpleStaticKind.cantSacrificeTreasures,
    'if you would draw a card, draw two cards instead': SimpleStaticKind.drawTwoInstead,
    'if you would put one or more charge counters on an artifact you control, put twice that many charge counters on that artifact instead': SimpleStaticKind.doubleChargeCounters,
    'if you would put one or more counters on a creature you control, put twice that many of each of those kinds of counters on that creature instead': SimpleStaticKind.doubleCountersOnCreatures,
    'if you gaining life causes a triggered ability of a permanent you control to trigger, that ability triggers an additional time': SimpleStaticKind.lifeGainTriggersTwice,
    "enchanted permanent doesn't untap during its controller's untap step and can't be beamed up": SimpleStaticKind.attachedDoesntUntap,
    'you may look at the top card of your library any time': SimpleStaticKind.lookAtTop,
    'play with the top card of your library revealed': SimpleStaticKind.lookAtTop,
    'you may play lands from the top of your library': SimpleStaticKind.playLandsFromTop,
    'you may play lands and cast creature spells from the top of your library': SimpleStaticKind.playLandsAndCreaturesFromTop,
    'you may cast ~ from exile': SimpleStaticKind.castSelfFromExile,
    'once during each of your turns, you may play a permanent card you own from outside the game or from your graveyard': SimpleStaticKind.playPermanentFromGraveyardOncePerTurn,
    "permanents can't phase in": SimpleStaticKind.permanentsCantPhaseIn,
  };

  bool _endsWith(List<String> words, List<String> suffix) {
    if (words.length < suffix.length) return false;
    for (var i = 0; i < suffix.length; i++) {
      if (words[words.length - suffix.length + i] != suffix[i]) return false;
    }
    return true;
  }

  bool _isUpper(String s) => s.isNotEmpty && s[0].toUpperCase() == s[0] && s[0].toLowerCase() != s[0];

  // MARK: Triggers

  /// A condition found at the start of a trigger's effects ("if you cast it, ...").
  TriggerCondition? _cond;

  void parseTriggered(String line) {
    var text = line;
    var once = false;
    final o = rx(text, r'(.+?)\s*This ability triggers only once each turn\.?', dotAll: true);
    if (o != null) {
      text = o[1];
      once = true;
    }
    _cond = null;
    List<(TriggerEvent, List<Effect>)>? parts;
    final w = rx(text, r'Whenever (you attack|~ attacks) while creatures you control have total power (\d+) or greater, (.+)', dotAll: true);
    if (w != null) {
      final fx = triggerEffects(w[3]);
      _cond = TriggerCondition(TriggerConditionKind.totalPowerAtLeast, n: int.parse(w[2]));
      if (fx != null) parts = [(w[1].toLowerCase() == 'you attack' ? SimpleTrigger.youAttack : SimpleTrigger.attacks, fx)];
    } else {
      parts = triggerParts(text);
    }
    if (parts != null) {
      for (final (e, fx) in parts) {
        abilities.add(Triggered(e, fx, oncePerTurn: once, condition: _cond));
      }
    } else {
      unsupported.add(line);
    }
    _cond = null;
  }

  List<(TriggerEvent, List<Effect>)>? triggerParts(String l) {
    var m = rx(
      l,
      r"At the beginning of (your upkeep|your end step|combat on your turn|combat on each player's turn|each combat|your precombat main phase|your first main phase|each upkeep|each end step|each opponent's upkeep), (.+)",
      dotAll: true,
    );
    if (m != null) {
      TriggerEvent? event;
      switch (m[1].toLowerCase()) {
        case 'your upkeep':
          event = SimpleTrigger.upkeep;
        case 'your end step':
          event = SimpleTrigger.endStep;
        case 'combat on your turn':
          event = SimpleTrigger.beginCombat;
        case "combat on each player's turn":
          event = SimpleTrigger.eachBeginCombat;
        case 'each upkeep':
          event = SimpleTrigger.eachUpkeep;
        case 'each end step':
          event = SimpleTrigger.eachEndStep;
        case 'your precombat main phase':
        case 'your first main phase':
          event = SimpleTrigger.firstMain;
      }
      final fx = triggerEffects(m[2]);
      if (event == null || fx == null) return null;
      return [(event, fx)];
    }
    m = rx(l, r'When ~ enters and at the beginning of your upkeep, (.+)', dotAll: true);
    if (m != null) {
      final fx = triggerEffects(m[1]);
      return fx == null ? null : [(SimpleTrigger.enters, fx), (SimpleTrigger.upkeep, fx)];
    }
    const simpleWhenevers = <String, SimpleTrigger>{
      'Whenever you attack': SimpleTrigger.youAttack,
      'Whenever you draw a card': SimpleTrigger.youDraw,
      'Whenever an opponent draws a card': SimpleTrigger.opponentDraws,
      'Whenever you draw your second card each turn': SimpleTrigger.secondCardDrawn,
      'Whenever you face a dilemma': SimpleTrigger.faceDilemma,
      'Whenever a card leaves your graveyard': SimpleTrigger.cardLeavesYourGraveyard,
      'Whenever you play a card from exile': SimpleTrigger.playFromExile,
      'Whenever one or more charge counters are put on ~ for the first time each turn': SimpleTrigger.chargedFirstTime,
      'When you cast ~': SimpleTrigger.castThis,
      'Whenever equipped creature attacks': SimpleTrigger.equippedAttacks,
      'Whenever a creature you control with a counter on it deals combat damage to a player': SimpleTrigger.counteredCreatureHitsPlayer,
    };
    for (final e in simpleWhenevers.entries) {
      final n = rx(l, '${RegExp.escape(e.key)}, (.+)', dotAll: true);
      if (n != null) {
        final fx = triggerEffects(n[1]);
        return fx == null ? null : [(e.value, fx)];
      }
    }
    m = rx(
      l,
      r'Whenever (you|a player|an opponent) casts? (?:a|an) (noncreature|creature|artifact|instant or sorcery|creature or Spacecraft)? ?spell( with mana value equal to the chosen number)?, (.+)',
      dotAll: true,
    );
    if (m != null) {
      final kind =
          const {
            'noncreature': SpellKind.noncreature,
            'creature': SpellKind.creature,
            'artifact': SpellKind.artifact,
            'instant or sorcery': SpellKind.instantOrSorcery,
            'creature or spacecraft': SpellKind.creatureOrSpacecraft,
          }[m[2].toLowerCase()] ??
          SpellKind.any;
      final who = switch (m[1].toLowerCase()) {
        'you' => Controller.you,
        'an opponent' => Controller.opponent,
        _ => Controller.any,
      };
      final fx = triggerEffects(m[4]);
      return fx == null ? null : [(CastSpellTrigger(kind, who: who, manaValueIsChosenNumber: m[3].isNotEmpty), fx)];
    }
    m = rx(
      l,
      r'(When|Whenever) (.+?) (enters or deals combat damage to a player|enters or attacks|attacks or blocks|enters untapped|enters|dies|die|attacks|blocks|becomes blocked|leaves the battlefield|deals combat damage to a player|deals combat damage to a player or planeswalker|deals combat damage to an opponent|becomes tapped|is put into a graveyard from the battlefield), (.+)',
      dotAll: true,
    );
    if (m == null) {
      var n = rx(l, r'Whenever you cast (a|an) (noncreature|creature|artifact|instant or sorcery)? ?spell, (.+)', dotAll: true);
      if (n != null) {
        final kind =
            const {'noncreature': SpellKind.noncreature, 'creature': SpellKind.creature, 'artifact': SpellKind.artifact, 'instant or sorcery': SpellKind.instantOrSorcery}[n[2].toLowerCase()] ??
            SpellKind.any;
        final fx = triggerEffects(n[3]);
        return fx == null ? null : [(CastSpellTrigger(kind), fx)];
      }
      if ((n = rx(l, r'Whenever you gain life, (.+)', dotAll: true)) != null) {
        final fx = triggerEffects(n![1]);
        return fx == null ? null : [(SimpleTrigger.gainLife, fx)];
      }
      if ((n = rx(l, r'Whenever you station, (.+)', dotAll: true)) != null) {
        final fx = triggerEffects(n![1]);
        return fx == null ? null : [(SimpleTrigger.stationed, fx)];
      }
      if ((n = rx(l, r'Whenever a land enters (?:the battlefield )?under your control, (.+)', dotAll: true)) != null) {
        final fx = triggerEffects(n![1]);
        return fx == null ? null : [(SimpleTrigger.landfall, fx)];
      }
      return null;
    }
    final subject = m[2];
    final verb = m[3].toLowerCase();
    final effectText = m[4];
    final subjectLower = subject.toLowerCase();
    var events = <TriggerEvent>[];
    final orAnother = rx(subject, r'(.+?) or (another .+)');
    if (verb == 'enters' && orAnother != null && isSelfSubject(orAnother[1])) {
      final f = filterFromSingular(orAnother[2]);
      if (f != null) events = [SimpleTrigger.enters, PermanentEntersTrigger(f)];
    } else if (subjectLower == '~' || isSelfSubject(subject)) {
      switch (verb) {
        case 'enters':
          events = [SimpleTrigger.enters];
        case 'enters untapped':
          events = [SimpleTrigger.entersUntapped];
        case 'enters or attacks':
          events = [SimpleTrigger.enters, SimpleTrigger.attacks];
        case 'enters or deals combat damage to a player':
          events = [SimpleTrigger.enters, SimpleTrigger.combatDamageToPlayer];
        case 'attacks or blocks':
          events = [SimpleTrigger.attacks, SimpleTrigger.blocks];
        case 'dies':
        case 'die':
        case 'is put into a graveyard from the battlefield':
          events = [SimpleTrigger.dies];
        case 'attacks':
          events = [SimpleTrigger.attacks];
        case 'blocks':
          events = [SimpleTrigger.blocks];
        case 'becomes blocked':
          events = [SimpleTrigger.blocked];
        case 'leaves the battlefield':
          events = [SimpleTrigger.leaves];
        case 'deals combat damage to a player':
        case 'deals combat damage to a player or planeswalker':
        case 'deals combat damage to an opponent':
          events = [SimpleTrigger.combatDamageToPlayer];
        case 'becomes tapped':
          events = [SimpleTrigger.becomesTapped];
      }
    } else if (verb == 'enters') {
      if (subjectLower == 'a land you control' || subjectLower == 'a land') {
        events = [SimpleTrigger.landfall];
      } else if (subjectLower.startsWith('~ or another ') || subjectLower.startsWith('~ or a ')) {
        final rest = subject.substring(subjectLower.startsWith('~ or another ') ? 13 : 7);
        final f = filterFromSingular(rest);
        if (f != null) {
          f.other = true;
          events = [SimpleTrigger.enters, PermanentEntersTrigger(f)];
        }
      } else {
        final f = filterFromSingular(subject);
        if (f != null) events = [PermanentEntersTrigger(f)];
      }
    } else if (verb == 'dies' || verb == 'is put into a graveyard from the battlefield') {
      final f = filterFromSingular(subject);
      if (f != null) events = [PermanentDiesTrigger(f)];
    }
    if (events.isEmpty) return null;
    final fx = triggerEffects(effectText);
    if (fx == null) return null;
    return events.map((e) => (e, fx)).toList();
  }

  List<Effect>? triggerEffects(String textIn) {
    var text = textIn;
    const conditions = <String, TriggerConditionKind>{
      'if you cast it, ': TriggerConditionKind.wasCast,
      "if you've cast a noncreature spell this turn, ": TriggerConditionKind.castNoncreatureThisTurn,
      'if a permanent was returned to your hand from the battlefield this turn, ': TriggerConditionKind.permanentReturnedToHandThisTurn,
    };
    for (final e in conditions.entries) {
      if (text.toLowerCase().startsWith(e.key)) {
        _cond = TriggerCondition(e.value);
        text = text.substring(e.key.length);
      }
    }
    final c = rx(text, r'if ~ has (\w+) or more (\w+) counters on it, (.+)', dotAll: true);
    if (c != null) {
      final kind = CounterKind.values.where((k) => k.text == c[2].toLowerCase()).firstOrNull;
      if (kind != null) {
        _cond = TriggerCondition(TriggerConditionKind.selfCountersAtLeast, n: numberWord(c[1]) ?? 0, counter: kind);
        text = c[3];
      }
    }
    final (fx, bad) = effects(text);
    return bad.isEmpty && fx.isNotEmpty ? fx : null;
  }

  /// Names of legendary permanents appear as the subject ("Captain Janeway", "USS Enterprise-A").
  bool isSelfSubject(String subject) {
    const generic = ['a ', 'an ', 'another ', 'one or more ', 'each ', 'you', 'target ', 'equipped', 'enchanted', 'that '];
    final l = subject.toLowerCase();
    if (generic.any(l.startsWith)) return false;
    return _isUpper(subject) || l == '~';
  }

  /// "another creature you control", "a creature you control", "another Klingon you control".
  Filter? filterFromSingular(String s) {
    var words = s.toLowerCase().split(' ').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return null;
    var other = false;
    final first = words.first;
    if (first == 'another') {
      other = true;
      words.removeAt(0);
    } else if (first == 'a' || first == 'an' || first == 'one') {
      words.removeAt(0);
    } else if (words.length >= 3 && words[0] == 'one' && words[1] == 'or' && words[2] == 'more') {
      words.removeRange(0, 3);
    } else {
      return null;
    }
    var controller = Controller.any;
    if (_endsWith(words, ['you', 'control'])) {
      controller = Controller.you;
      words = words.sublist(0, words.length - 2);
    } else if (_endsWith(words, ['an', 'opponent', 'controls']) || _endsWith(words, ['you', "don't", 'control'])) {
      controller = Controller.opponent;
      words = words.sublist(0, words.length - 3);
    }
    if (words.isEmpty) return null;
    final original = s.split(' ');
    final f = Filter(FilterKind.creature, controller: controller)..other = other;
    final noun = words.removeLast();
    switch (noun) {
      case 'creature':
        f.kind = FilterKind.creature;
      case 'artifact':
        f.kind = FilterKind.artifact;
      case 'permanent':
        f.kind = FilterKind.permanent;
      case 'land':
        f.kind = FilterKind.land;
      case 'spacecraft':
        f.kind = FilterKind.spacecraft;
      case 'token':
        f.kind = FilterKind.token;
      default:
        final o = original.where((x) => x.toLowerCase() == noun).firstOrNull;
        if (o != null && _isUpper(o)) {
          f.kind = FilterKind.creature;
          f.subtype = o;
        } else {
          return null;
        }
    }
    for (final w in words) {
      switch (w) {
        case 'artifact':
          f.kind = f.kind == FilterKind.creature ? FilterKind.artifactCreature : FilterKind.artifact;
        case 'nontoken':
          f.nontoken = true;
        case 'other':
          f.other = true;
        default:
          final o = original.where((x) => x.toLowerCase() == w).firstOrNull;
          if (o != null && _isUpper(o) && f.kind == FilterKind.creature) {
            f.subtype = o;
          } else {
            return null;
          }
      }
    }
    return f;
  }

  // MARK: Activation costs

  ActivationCost? activationCost(String text) {
    final cost = ActivationCost();
    for (final part in text.split(',').map((s) => s.trim())) {
      final p = part.toLowerCase();
      if (p == '{t}') {
        cost.tap = true;
        continue;
      }
      if (p.startsWith('{') && !p.contains('t}') && !p.contains('q}')) {
        final c = ManaCost.parse(p.toUpperCase());
        if (c.manaValue == 0 && !c.hasX && p != '{0}') return null;
        if (c.hasX) return null;
        cost.mana.add(c);
        continue;
      }
      if (p == 'sacrifice ~') {
        cost.sacrificeSelf = true;
        continue;
      }
      if (p == 'discard ~') {
        cost.zone = AbilityZone.hand;
        continue;
      }
      if (p == 'exile ~ from your graveyard') {
        cost.zone = AbilityZone.graveyard;
        cost.exileSelf = true;
        continue;
      }
      if (p == 'put ~ from your graveyard on the bottom of your library') {
        cost.zone = AbilityZone.graveyard;
        cost.bottomSelf = true;
        continue;
      }
      var m = rx(p, r'remove (\w+) counters from among creatures you control');
      if (m != null) {
        cost.removeCounters = numberWord(m[1]) ?? 1;
        continue;
      }
      m = rx(p, r'tap (\w+) untapped (officers|artifacts and/or creatures) you control');
      if (m != null) {
        cost.tapOthers = numberWord(m[1]) ?? 1;
        cost.tapOthersFilter = m[2] == 'officers' ? (Filter(FilterKind.creature, controller: Controller.you)..subtype = 'Officer') : Filter(FilterKind.artifactOrCreature, controller: Controller.you);
        continue;
      }
      m = rx(p, r'sacrifice a (food|treasure|clue)');
      if (m != null) {
        cost.sacrifice = Filter(FilterKind.artifact, controller: Controller.you)..subtype = m[1][0].toUpperCase() + m[1].substring(1);
        continue;
      }
      if (p == 'sacrifice a creature') {
        cost.sacrifice = Filter(FilterKind.creature, controller: Controller.you);
        continue;
      }
      m = rx(p, r'sacrifice (another|a|an) (creature or artifact|artifact or creature)');
      if (m != null) {
        cost.sacrifice = Filter(FilterKind.artifactOrCreature, controller: Controller.you)..other = m[1] == 'another';
        continue;
      }
      m = rx(p, r'sacrifice (a|an|another) (creature|artifact|land|permanent|token)');
      if (m != null) {
        final f = Filter(FilterKind.creature, controller: Controller.you);
        switch (m[2]) {
          case 'artifact':
            f.kind = FilterKind.artifact;
          case 'land':
            f.kind = FilterKind.land;
          case 'permanent':
            f.kind = FilterKind.permanent;
          case 'token':
            f.kind = FilterKind.token;
        }
        f.other = m[1] == 'another';
        cost.sacrifice = f;
        continue;
      }
      if ((m = rx(p, r'pay (\d+) life')) != null) {
        cost.payLife = int.parse(m![1]);
        continue;
      }
      if (p == 'discard a card') {
        cost.discard = 1;
        continue;
      }
      return null;
    }
    return cost;
  }

  // MARK: Effects

  (List<Effect>, List<String>) effects(String text) {
    final out = <Effect>[];
    final bad = <String>[];
    final t = text.trim();
    final modal = rx(t, r"choose one(?: that hasn't been chosen)?(?: —|\. If you have no cards in hand, choose one or more instead\.)\s*(.+)", dotAll: true);
    if (modal != null) {
      final modes = <List<Effect>>[];
      final labels = <String>[];
      for (final mode in modal[1].split('\n').map((s) => s.trim()).where((s) => s.startsWith('•'))) {
        var modeText = mode.substring(1).trim();
        final named = rx(modeText, r'([A-Z][^—]+) — (.+)', dotAll: true);
        if (named != null) {
          labels.add(named[1].trim());
          modeText = named[2];
        }
        final (fx, b) = effects(modeText);
        if (b.isNotEmpty || fx.isEmpty) return ([], [t]);
        modes.add(fx);
      }
      final lower = t.toLowerCase();
      return modes.isEmpty
          ? ([], [t])
          : (
              [Modal(modes, labels: labels.length == modes.length ? labels : const [], unchosenOnly: lower.contains("hasn't been chosen"), oneOrMoreIfHandEmpty: lower.contains('no cards in hand'))],
              [],
            );
    }
    final whole = wholeText(t);
    if (whole != null) return (whole, []);
    _LookBuilder? look;
    void flushLook() {
      final b = look;
      if (b != null) out.add(b.build());
      look = null;
    }

    for (final sentence in sentences(t)) {
      final l = sentence.toLowerCase();
      // "Look at the top N cards..." spans several sentences.
      final lookStart = rx(l, r'look at the top (\w+) cards of your library(?:, where x is (.+))?');
      if (lookStart != null) {
        flushLook();
        final n = lookStart[1] == 'x' ? amountPhrase(lookStart[2]) : amount(lookStart[1]);
        if (n == null) {
          bad.add(sentence);
          continue;
        }
        look = _LookBuilder(n);
        continue;
      }
      final lb = look;
      if (lb != null) {
        if (lb.absorb(l, this)) continue;
        flushLook();
      }
      if (l.startsWith('you may put a permanent card from among them into your hand') && out.isNotEmpty && out.last is Mill) {
        out.add(const LookAtTop(Amount.zero, CardPred(permanent: true), fromAffected: true));
        continue;
      }
      // "Exile the top N cards ... . Until the end of your next turn, you may play those cards."
      final play = rx(l, r'(?:until the end of your next turn, you may play (?:those cards|that card|them)|you may play (?:that card|those cards) this turn)');
      if (play != null && out.isNotEmpty && out.last is ExileTopPlayable) {
        final e = out.removeLast() as ExileTopPlayable;
        out.add(ExileTopPlayable(e.n, untilNextTurn: l.contains('next turn')));
        continue;
      }
      final doIt = rx(sentence, r'(?:if|when) you do, (.+)');
      if (doIt != null && out.isNotEmpty) {
        final fx = effect(doIt[1]);
        if (fx != null) {
          final last = out.last;
          if (last is Optional) {
            out[out.length - 1] = Optional([...last.effects, IfDidPrevious(fx)]);
          } else {
            out.add(IfDidPrevious(fx));
          }
          continue;
        }
      }
      final ifCant = rx(l, r"if you can't, exile (.+)");
      if (ifCant != null && out.isNotEmpty && out.last is AssimilateExiledOrExile) {
        final tg = target(ifCant[1]);
        if (tg != null) {
          out[out.length - 1] = AssimilateExiledOrExile(tg);
          continue;
        }
      }
      final kicked = rx(sentence, r'if ~ was kicked, (?:instead (.+)|(.+?) instead)');
      if (kicked != null) {
        final fx = effect(kicked[1].isEmpty ? kicked[2] : kicked[1]);
        if (fx != null) {
          out.add(KickedInstead(fx));
          continue;
        }
      }
      final fx = effect(sentence);
      if (fx != null) {
        out.addAll(fx);
      } else {
        bad.add(sentence);
      }
    }
    flushLook();
    return (out, bad);
  }

  List<String> sentences(String text) {
    final result = <String>[];
    var current = StringBuffer();
    final chars = text.split('');
    var i = 0;
    while (i < chars.length) {
      final ch = chars[i];
      current.write(ch);
      if (ch == '.' && i + 1 < chars.length && chars[i + 1] == ' ') {
        result.add(current.toString());
        current = StringBuffer();
        i += 2;
        continue;
      }
      i++;
    }
    if (current.toString().trim().isNotEmpty) result.add(current.toString());
    return result
        .map((s) {
          var x = s.trim();
          while (x.endsWith('.')) {
            x = x.substring(0, x.length - 1);
          }
          if (x.startsWith('Then ') || x.startsWith('then ')) x = x.substring(5);
          return x;
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Amount? amount(String w) {
    final n = numberWord(w);
    return n == null ? null : Amount.fixed(n);
  }

  Amount? countAmount(String text) {
    var t = text.toLowerCase().trim();
    while (t.endsWith('.') || t.endsWith(' ')) {
      t = t.substring(0, t.length - 1);
    }
    switch (t) {
      case 'creatures you control':
        return const Amount.counted(AmountKind.creaturesYouControl);
      case 'artifacts you control':
        return const Amount.counted(AmountKind.artifactsYouControl);
      case 'lands you control':
        return const Amount.counted(AmountKind.landsYouControl);
      case 'differently named lands you control':
        return const Amount.counted(AmountKind.differentlyNamedLands);
      case 'cards in your hand':
        return const Amount.counted(AmountKind.cardsInHand);
      case 'artifact creatures you control':
        return const Amount.counted(AmountKind.artifactCreaturesYouControl);
      case 'creature types among non-borg creatures you control':
        return const Amount.counted(AmountKind.creatureTypesNonBorg);
      case 'opponents you attacked this turn':
        return const Amount.counted(AmountKind.opponentsAttacked);
      case 'other creatures you control with a communicator attached to them':
        return const Amount.counted(AmountKind.otherCreaturesWithCommunicator);
      case 'officers you control':
        return const Amount.counted(AmountKind.subtypeYouControl, subtype: 'Officer');
    }
    return null;
  }

  /// "the number of X" or "~'s power".
  Amount? amountPhrase(String text) {
    final t = text.toLowerCase().trim();
    if (t == "~'s power" || t == 'its power') return const Amount.counted(AmountKind.thisPower);
    final m = rx(t, r'the number of (.+)');
    return m == null ? null : countAmount(m[1]);
  }

  /// One sentence to effects, or null.
  List<Effect>? effect(String sentenceIn) {
    var s = sentenceIn.trim();
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    final l = s.toLowerCase();
    List<String>? m;

    final extra = extraEffect(s, l);
    if (extra != null) return extra;
    if (l.startsWith('you may ')) {
      final inner = effect(s.substring(8));
      return inner == null ? null : [Optional(inner)];
    }
    if ((m = rx(s, r'(.+?), then (.+)')) != null) {
      final a = effect(m![1]), b = effect(m[2]);
      if (a != null && b != null) return [...a, ...b];
    }
    if ((m = rx(s, r"if ~ (isn't|is) a creature, (.+)")) != null) {
      final inner = effect(m![2].replaceAll(RegExp(r'\bon it\b'), 'on ~'));
      if (inner != null) return [Conditional(m[1].toLowerCase() == 'is' ? Condition.thisIsCreature : Condition.thisIsNotCreature, inner)];
    }
    if ((m = rx(l, r"create a token that's a copy of (.+?)(?:, except it has (.+))?")) != null) {
      final t = target(m![1]);
      if (t != null) {
        final extra = <Keyword>[];
        if (m[2].isNotEmpty) {
          final k = keyword(m[2]);
          if (k == null) return null;
          extra.add(k);
        }
        return [CopyToken(t, extra)];
      }
    }
    if ((m = rx(l, r'counter (target spell(?: with mana value \d+ or less)?)(?: unless its controller pays (\{.+\}))?')) != null) {
      final t = target(m![1]);
      if (t == null) return null;
      return [CounterSpell(t, unlessPays: m[2].isEmpty ? null : ManaCost.parse(m[2].toUpperCase()))];
    }
    if (l.contains(' if ') || l.startsWith('if ') || l.contains(' instead') || l.contains(' unless ')) return null;

    // Damage
    if ((m = rx(l, '(?:~|it|he|she|they) deals? $_num damage to (.+?)(?: and $_num damage to (.+))?')) != null) {
      final a = amount(m![1]);
      final t = target(m[2]);
      if (a == null || t == null) return null;
      final fx = <Effect>[Damage(a, t)];
      if (m[3].isNotEmpty) {
        final a2 = amount(m[3]);
        final t2 = target(m[4]);
        if (a2 == null || t2 == null) return null;
        fx.add(Damage(a2, t2));
      }
      return fx;
    }
    if ((m = rx(l, '(?:~|it) deals $_num damage')) != null) {
      final a = amount(m![1]);
      if (a != null) return [Damage(a, Target.lastTarget)];
    }
    if ((m = rx(l, r'pay (\d+) life')) != null) return [PayLife(int.parse(m![1]))];
    if ((m = rx(l, r'pay (\{.+\})')) != null) return [PayMana(ManaCost.parse(m![1].toUpperCase()))];
    if ((m = rx(l, r'discover (\d+)')) != null) return [Discover(int.parse(m![1]))];
    if (rx(l, r'target opponent exiles cards from the top of their library until they exile a creature card\. assimilate that card\. they put the rest on the bottom in a random order') != null) {
      return [AssimilateFromLibrary(ChosenTarget(Filter.opponent))];
    }
    if ((m = rx(l, r"assimilate a creature card exiled with it\. if you can't, exile (.+)")) != null) {
      final t = target(m![1]);
      if (t != null) return [AssimilateExiledOrExile(t)];
    }
    if ((m = rx(l, 'distribute $_num \\+1/\\+1 counters among one or two target creatures')) != null) {
      final a = amount(m![1]);
      if (a != null) return [AddCounters(CounterKind.plusOne, a, ChosenTarget(Filter.creature, count: 2), distribute: true)];
    }
    if ((m = rx(l, r'~ deals damage equal to its power to (.+)')) != null) {
      final t = target(m![1]);
      if (t != null) return [Bite(t)];
    }
    if ((m = rx(l, r'~ fights (.+)')) != null) {
      final t = target(m![1]);
      if (t != null) return [Fight(t)];
    }
    // Draw
    if ((m = rx(l, '(?:you )?draw $_num cards?')) != null) {
      final a = amount(m![1]);
      if (a != null) return [Draw(a, Target.you)];
    }
    if (l == 'draw a card') return const [Draw(Amount.one, Target.you)];
    if ((m = rx(l, r'you gain life equal to the number of (.+)')) != null) {
      final a = countAmount(m![1]);
      if (a != null) return [GainLife(a, Target.you)];
    }
    if ((m = rx(l, r'(?:you )?draw cards equal to the number of (.+)')) != null) {
      final a = countAmount(m![1]);
      if (a != null) return [Draw(a, Target.you)];
    }
    if (rx(l, r'draw x cards, where x is the number of differently named lands you control') != null) {
      return const [Draw(Amount.counted(AmountKind.differentlyNamedLands), Target.you)];
    }
    if ((m = rx(l, '(target player|target opponent|each player|each opponent|its controller|that player) draws? $_num cards?')) != null) {
      final t = target(m![1]);
      final a = amount(m[2]);
      if (t != null && a != null) return [Draw(a, t)];
    }
    // Life
    if ((m = rx(l, 'you gain $_num life(?: and (.+))?')) != null) {
      final a = amount(m![1]);
      if (a != null) {
        final fx = <Effect>[GainLife(a, Target.you)];
        if (m[2].isNotEmpty) {
          final more = effect(m[2]);
          if (more == null) return null;
          fx.addAll(more);
        }
        return fx;
      }
    }
    if ((m = rx(l, '(target player|target opponent|each opponent|each player|its controller|that player) gains? $_num life')) != null) {
      final t = target(m![1]);
      final a = amount(m[2]);
      if (t != null && a != null) return [GainLife(a, t)];
    }
    if ((m = rx(l, '(each opponent|target opponent|target player|each player|its controller|that player) loses? $_num life(?: and you gain $_num life)?')) != null) {
      final t = target(m![1]);
      final a = amount(m[2]);
      if (t != null && a != null) {
        final fx = <Effect>[LoseLife(a, t)];
        if (m[3].isNotEmpty) {
          final g = amount(m[3]);
          if (g != null) fx.add(GainLife(g, Target.you));
        }
        return fx;
      }
    }
    if ((m = rx(l, 'you lose $_num life')) != null) {
      final a = amount(m![1]);
      if (a != null) return [LoseLife(a, Target.you)];
    }
    if (l == 'double your life total') return const [DoubleLife()];
    if (l.startsWith('you have no maximum hand size')) return const [NoMaxHandSize()];
    // Removal
    if ((m = rx(l, r'destroy (.+)')) != null) {
      final t = target(m![1]);
      if (t != null) return [Destroy(t)];
    }
    final exileMatch = rx(l, r'exile (.+?)(?: until .+)?');
    if (exileMatch != null && !exileMatch[0].contains('until')) {
      final t = target(exileMatch[1]);
      if (t != null) return [Exile(t)];
    }
    if ((m = rx(l, r"return (.+?) to (?:its|their) owner'?s? hands?")) != null) {
      final t = target(m![1]);
      if (t != null) return [Bounce(t)];
    }
    if ((m = rx(l, r'return (.+?) from your graveyard to (your hand|the battlefield)( tapped)?')) != null) {
      final f = graveyardFilter(m![1]);
      if (f == null) return null;
      return [ReturnFromGraveyard(f, m[2] == 'your hand' ? LibraryDestination.hand : (m[3].isEmpty ? LibraryDestination.battlefield : LibraryDestination.battlefieldTapped))];
    }
    if ((m = rx(l, r'tap (.+?) and put a stun counter on it')) != null) {
      final t = target(m![1]);
      if (t != null) return [Tap(t), const AddCounters(CounterKind.stun, Amount.one, Target.lastTarget)];
    }
    if ((m = rx(l, r"tap (.+?)(?:\. it doesn't untap during its controller's next untap step)?")) != null) {
      final t = target(m![1]);
      if (t != null) return [Tap(t)];
    }
    if ((m = rx(l, r'untap (.+)')) != null) {
      final t = target(m![1]);
      if (t != null) return [Untap(t)];
    }
    // Pump and keywords
    if ((m = rx(l, r'(.+?) gets? ([+-]\d+)/([+-]\d+)(?: and (?:gains?|has) (.+?))? until end of turn')) != null) {
      final t = target(m![1]);
      if (t != null) {
        final fx = <Effect>[Pump(int.parse(m[2]), int.parse(m[3]), t, EffectDuration.endOfTurn)];
        // "Target creature gets +3/+3 and gains trample": one target, chosen once.
        final again = t is ChosenTarget ? Target.lastTarget : t;
        if (m[4].isNotEmpty) {
          for (final kw in m[4].split(' and ').map((s) => s.trim())) {
            final k = keyword(kw);
            if (k == null) return null;
            fx.add(GrantKeyword(k, again, EffectDuration.endOfTurn));
          }
        }
        return fx;
      }
    }
    if ((m = rx(l, r'(.+?) gains? (.+?) until end of turn')) != null) {
      final t = target(m![1]);
      if (t != null) {
        final fx = <Effect>[];
        for (final kw in m[2].split(' and ').map((s) => s.trim())) {
          final k = keyword(kw);
          if (k == null) return null;
          // "gains hexproof and indestructible": the same target for each keyword.
          fx.add(GrantKeyword(k, fx.isNotEmpty && t is ChosenTarget ? Target.lastTarget : t, EffectDuration.endOfTurn));
        }
        return fx;
      }
    }
    if ((m = rx(l, r"(.+?) can't be blocked this turn")) != null) {
      final t = target(m![1]);
      if (t != null) return [GrantKeyword(Keyword.unblockable, t, EffectDuration.endOfTurn)];
    }
    if ((m = rx(l, r"(.+?) can't block this turn")) != null) {
      final t = target(m![1]);
      if (t != null) return [CantBlock(t, EffectDuration.endOfTurn)];
    }
    // Counters
    if ((m = rx(l, 'put $_num (\\+1/\\+1|-1/-1|charge|stun) counters? on (.+)')) != null) {
      final a = amount(m![1]);
      final t = target(m[3]);
      if (a != null && t != null) {
        final kind = m[2] == 'charge' ? CounterKind.charge : (m[2] == '-1/-1' ? CounterKind.minusOne : (m[2] == 'stun' ? CounterKind.stun : CounterKind.plusOne));
        return [AddCounters(kind, a, t)];
      }
    }
    if ((m = rx(l, 'put $_num \\+1/\\+1 counters? on each of (.+)')) != null) {
      final a = amount(m![1]);
      final t = target(m[2]);
      if (a != null && t != null) return [AddCounters(CounterKind.plusOne, a, t)];
    }
    // Tokens
    if ((m = rx(l, '(?:(each player|each opponent|target player|target opponent) )?creates? $_num treasure tokens?')) != null) {
      final a = amount(m![2]);
      final who = m[1].isEmpty ? Target.you : target(m[1]);
      if (a != null && who != null) return [CreateTokens(TokenSpec.treasure, a, who)];
    }
    if ((m = rx(l, 'create $_num food tokens?')) != null) {
      final a = amount(m![1]);
      if (a != null) return [CreateTokens(TokenSpec.food, a, Target.you)];
    }
    if ((m = rx(l, 'create $_num clue tokens?')) != null) {
      final a = amount(m![1]);
      if (a != null) return [CreateTokens(TokenSpec.clue, a, Target.you)];
    }
    if (l == 'investigate') return [CreateTokens(TokenSpec.clue, Amount.one, Target.you)];
    if ((m = rx(l, '(?:(each player|each opponent|target player|target opponent) )?creates? (?:[^,]+, )?$_num (?:legendary )?(\\d+)/(\\d+) (.+?) creature tokens?(?: with (.+?))?(?: named .+)?')) !=
        null) {
      final a = amount(m![2]);
      final who = m[1].isEmpty ? Target.you : target(m[1]);
      if (a != null && who != null) {
        final spec = TokenSpec(name: '', power: int.parse(m[3]), toughness: int.parse(m[4]));
        final original = s.split(' ');
        for (final w in m[5].split(' ')) {
          switch (w) {
            case 'white':
              spec.colors.add(ManaColor.white);
            case 'blue':
              spec.colors.add(ManaColor.blue);
            case 'black':
              spec.colors.add(ManaColor.black);
            case 'red':
              spec.colors.add(ManaColor.red);
            case 'green':
              spec.colors.add(ManaColor.green);
            case 'colorless':
            case 'and':
              break;
            case 'artifact':
              return [CreateTokens(_artifactToken(spec, m, original), a, who)];
            default:
              final o = original.where((x) => x.toLowerCase() == w).firstOrNull;
              if (o == null) return null;
              spec.subtypes.add(o);
          }
        }
        if (m[6].isNotEmpty) {
          for (final kw in m[6].split(' and ').expand((s) => s.split(',')).map((s) => s.trim())) {
            final cleaned = kw.replaceAll('"', '').replaceAll('~ ', '').replaceAll('this token ', '');
            final k = keyword(cleaned);
            if (k == null) return null;
            spec.keywords.add(k);
          }
        }
        spec.name = spec.subtypes.join(' ');
        // "create Porthos, a legendary 1/1 green Dog creature token": a named, legendary token.
        final named = rx(l, r"(?:.* )?creates? ([\w' ]+), an? (?:legendary )?\d+/\d+.*");
        if (named != null) {
          // Keep the name's capitals from the card text.
          final at = card.oracleText.toLowerCase().indexOf(named[1]);
          spec.name = at < 0 ? named[1] : card.oracleText.substring(at, at + named[1].length);
        }
        if (l.contains(' legendary ')) spec.isLegendary = true;
        return [CreateTokens(spec, a, who)];
      }
    }
    // Library and graveyard
    if ((m = rx(l, r'surveil (\d+)')) != null) return [Surveil(int.parse(m![1]))];
    if ((m = rx(l, r'scry (\d+)')) != null) return [Scry(int.parse(m![1]))];
    if ((m = rx(l, '(?:you )?mill $_num cards?')) != null) {
      final a = numberWord(m![1]);
      if (a != null) return [Mill(a, Target.you)];
    }
    if ((m = rx(l, '(target player|target opponent|each opponent|each player) mills? $_num cards?')) != null) {
      final t = target(m![1]);
      final a = numberWord(m[2]);
      if (t != null && a != null) return [Mill(a, t)];
    }
    if ((m = rx(l, '(target player|target opponent|each opponent|each player) discards? $_num cards?')) != null) {
      final t = target(m![1]);
      final a = numberWord(m[2]);
      if (t != null && a != null) return [Discard(a, t)];
    }
    if ((m = rx(l, '(?:you )?discard $_num cards?')) != null) {
      final a = numberWord(m![1]);
      if (a != null) return [Discard(a, Target.you)];
    }
    if (l == 'search your library for a basic land card, put it onto the battlefield tapped, then shuffle' ||
        l == 'search your library for a basic land card, put that card onto the battlefield tapped, then shuffle') {
      return const [SearchBasicLand(LibraryDestination.battlefieldTapped, Target.you)];
    }
    if (l == 'search your library for a basic land card, put it onto the battlefield, then shuffle') return const [SearchBasicLand(LibraryDestination.battlefield, Target.you)];
    if (l == 'search your library for a basic land card, reveal it, put it into your hand, then shuffle') return const [SearchBasicLand(LibraryDestination.hand, Target.you)];
    if (l == 'its controller may search their library for a basic land card, reveal it, put it into their hand, then shuffle') {
      return const [
        Optional([SearchBasicLand(LibraryDestination.hand, Target.controllerOfLastTarget)]),
      ];
    }
    if (rx(l, r'sacrifice (it|that token|that creature) at the beginning of the next end step') != null) return const [SacrificeAtEndOfTurn(Target.lastTarget)];
    if ((m = rx(l, r'(.+?) fights (.+)')) != null) {
      final a = target(m![1]), b = target(m[2]);
      if (a != null && b != null && a != Target.thisObject) return [FightBetween(a, b)];
    }
    if ((m = rx(l, r"assimilate target creature card from (a|an opponent's|your) graveyard")) != null) {
      final f = Filter(FilterKind.creatureCardInGraveyard)..controller = m![1] == 'a' ? Controller.any : (m[1] == 'your' ? Controller.you : Controller.opponent);
      return [Assimilate(f)];
    }
    if ((m = rx(l, r'(?:you may )?put a land card from your hand onto the battlefield( tapped)?')) != null) return [PutLandFromHand(m![1].isNotEmpty)];
    // Sacrifice
    if ((m = rx(
          l,
          r'(each opponent|target opponent|target player|each player) sacrifices? (a|an) (nontoken )?(creature|artifact|land|permanent|enchantment|artifact or enchantment|artifact or creature)(?: of their choice)?',
        )) !=
        null) {
      final t = target(m![1]);
      if (t != null) {
        final f = Filter(FilterKind.creature);
        switch (m[4]) {
          case 'artifact':
            f.kind = FilterKind.artifact;
          case 'land':
            f.kind = FilterKind.land;
          case 'permanent':
            f.kind = FilterKind.permanent;
          case 'enchantment':
            f.kind = FilterKind.enchantment;
          case 'artifact or enchantment':
            f.kind = FilterKind.artifactOrEnchantment;
          case 'artifact or creature':
            f.kind = FilterKind.artifactOrCreature;
        }
        f.nontoken = m[3].isNotEmpty;
        return [Sacrifice(t, f)];
      }
    }
    if ((m = rx(l, r'sacrifice (a|an) (creature|artifact|land|creature token|artifact or creature)')) != null) {
      final f = Filter(FilterKind.creature);
      switch (m![2]) {
        case 'artifact':
          f.kind = FilterKind.artifact;
        case 'land':
          f.kind = FilterKind.land;
        case 'creature token':
          f.kind = FilterKind.creatureToken;
        case 'artifact or creature':
          f.kind = FilterKind.artifactOrCreature;
      }
      return [Sacrifice(Target.you, f)];
    }
    if (l == 'sacrifice ~') return [Sacrifice(Target.you, Filter(FilterKind.token))]; // the engine sacrifices the source
    // Explore
    if ((m = rx(l, r'(.+?) explores?')) != null) {
      final t = target(m![1]);
      if (t != null) return [Explore(t)];
    }
    if (l == 'it explores' || l == 'that creature explores') return const [Explore(Target.lastTarget)];
    // Mana
    if ((m = rx(l, r'add (.+)')) != null) {
      final colors = manaColors(m![1]);
      if (colors != null) return [AddMana(colors)];
    }
    if ((m = rx(l, r'gain control of (.+)')) != null) {
      final t = target(m![1]);
      if (t != null) return [GainControl(t)];
    }
    // "You draw two cards and each player loses 2 life."
    final andIndex = s.toLowerCase().indexOf(' and ');
    if (andIndex > 0) {
      final a = effect(s.substring(0, andIndex)), b = effect(s.substring(andIndex + 5));
      if (a != null && b != null) return [...a, ...b];
    }
    return null;
  }

  TokenSpec _artifactToken(TokenSpec spec, List<String> m, List<String> original) {
    final out = TokenSpec(name: '', power: spec.power, toughness: spec.toughness, colors: List.of(spec.colors), isArtifact: true);
    for (final w in m[5].split(' ')) {
      if (['white', 'blue', 'black', 'red', 'green', 'colorless', 'and', 'artifact'].contains(w)) continue;
      final o = original.where((x) => x.toLowerCase() == w).firstOrNull;
      if (o != null) out.subtypes.add(o);
    }
    out.name = out.subtypes.join(' ');
    return out;
  }

  Filter? graveyardFilter(String text) {
    final l = text.toLowerCase();
    if (l == 'target creature card') return Filter(FilterKind.creatureCardInGraveyard, controller: Controller.you);
    if (l == 'target permanent card') return Filter(FilterKind.permanentCardInGraveyard, controller: Controller.you);
    if (l == 'target card') return Filter(FilterKind.cardInGraveyard, controller: Controller.you);
    final m = rx(l, r'target (artifact )?creature card with mana value (\d+) or less');
    if (m != null) return Filter(FilterKind.creatureCardInGraveyard, controller: Controller.you)..maxManaValue = int.parse(m[2]);
    return null;
  }

  // MARK: Targets

  Target? target(String textIn) {
    final t = textIn.trim().toLowerCase();
    switch (t) {
      case 'they':
      case 'that opponent':
        return Target.lastTarget;
      case 'enchanted permanent':
        return Target.attachedCreature;
      case '~':
      case 'this':
        return Target.thisObject;
      case 'you':
        return Target.you;
      case 'it':
      case 'that creature':
      case 'that permanent':
      case 'that player':
      case 'them':
      case 'that spacecraft':
        return Target.lastTarget;
      case 'its controller':
      case "that creature's controller":
        return Target.controllerOfLastTarget;
      case 'any target':
        return ChosenTarget(Filter.anyTarget);
      case 'equipped creature':
      case 'enchanted creature':
        return Target.attachedCreature;
      case 'each opponent':
      case 'your opponents':
        return EachTarget(Filter.opponent);
      case 'each player':
        return EachTarget(Filter.player);
      case 'target player':
      case 'target player or planeswalker':
        return ChosenTarget(Filter.player);
      case 'target opponent':
      case 'target opponent or planeswalker':
        return ChosenTarget(Filter.opponent);
    }
    var m = rx(t, r'up to (one|two|three) (other )?target (.+)');
    if (m != null) {
      final n = numberWord(m[1]);
      final f = targetFilter(m[3]);
      if (n != null && f != null) return ChosenTarget(f..other = f.other || m[2].isNotEmpty, count: n, optional: true);
    }
    if (t == 'target card from a graveyard') return ChosenTarget(Filter(FilterKind.cardInGraveyard));
    m = rx(t, r'one or two target (.+)');
    if (m != null) {
      final f = targetFilter(m[1]);
      if (f != null) return ChosenTarget(f, count: 2);
    }
    if ((m = rx(t, r'(another )?target (.+)')) != null) {
      final f = targetFilter(m![2]);
      if (f != null) {
        if (m[1].isNotEmpty) f.other = true;
        return ChosenTarget(f);
      }
    }
    if ((m = rx(t, r'(?:each|all) (.+)')) != null) {
      final rest = m![1];
      if (rest == 'creature' || rest == 'creatures') return EachTarget(Filter.creature);
      if (rest == 'other creature' || rest == 'other creatures') return EachTarget(Filter.creature..other = true);
      if (rest == 'opponent') return EachTarget(Filter.opponent);
      if (rest == 'nonartifact creatures') return EachTarget(Filter.creature..nonartifact = true);
      if (rest == 'artifacts and creatures') return EachTarget(Filter(FilterKind.artifactOrCreature));
      if (rest == 'player') return EachTarget(Filter.player);
      final f = filterFromPlural(rest.endsWith('s') ? rest : '${rest}s') ?? filterFromPlural(rest);
      return f == null ? null : EachTarget(f);
    }
    final f = filterFromPlural(t);
    return f == null ? null : EachTarget(f);
  }

  /// The words after "target": "creature", "creature or Spacecraft", "nonland permanent an opponent controls".
  Filter? targetFilter(String textIn) {
    var t = textIn.toLowerCase().trim();
    final f = Filter(FilterKind.creature);
    List<String>? m;
    if ((m = rx(t, r'(.+?) with power (\d+) or less')) != null) {
      t = m![1];
      f.maxPower = int.parse(m[2]);
    }
    if ((m = rx(t, r'(.+?) with power (\d+) or greater')) != null) {
      t = m![1];
      f.minPower = int.parse(m[2]);
    }
    if ((m = rx(t, r'(.+?) with mana value (\d+) or less')) != null) {
      t = m![1];
      f.maxManaValue = int.parse(m[2]);
    }
    if ((m = rx(t, r'(.+?) you control')) != null) {
      t = m![1];
      f.controller = Controller.you;
    } else if ((m = rx(t, r"(.+?) (?:an opponent controls|you don't control|your opponents control)")) != null) {
      t = m![1];
      f.controller = Controller.opponent;
    }
    var words = t.split(' ').where((w) => w.isNotEmpty).toList();
    final joined = words.join(' ');
    const nouns = <(String, FilterKind)>[
      ('creature or spacecraft', FilterKind.creatureOrSpacecraft),
      ('creature or planeswalker', FilterKind.creature),
      ('artifact or enchantment', FilterKind.artifactOrEnchantment),
      ('nonland permanent', FilterKind.nonlandPermanent),
      ('artifact creature', FilterKind.artifactCreature),
      ('artifact or creature', FilterKind.artifactOrCreature),
      ('player or planeswalker', FilterKind.player),
      ('creature or player', FilterKind.creatureOrPlayer),
      ('creature or artifact', FilterKind.artifactOrCreature),
      ('creature', FilterKind.creature),
      ('spacecraft', FilterKind.spacecraft),
      ('artifact', FilterKind.artifact),
      ('enchantment', FilterKind.enchantment),
      ('permanent', FilterKind.permanent),
      ('land', FilterKind.land),
      ('opponent', FilterKind.opponent),
      ('player', FilterKind.player),
      ('token', FilterKind.token),
      ('spell', FilterKind.spell),
    ];
    var matched = false;
    for (final (noun, kind) in nouns) {
      final plural = '${noun}s';
      if (joined == noun || joined == plural) {
        f.kind = kind;
        words = [];
        matched = true;
        break;
      }
      if (joined.endsWith(' $plural')) {
        f.kind = kind;
        matched = true;
        words = joined.substring(0, joined.length - plural.length - 1).split(' ');
        break;
      }
      if (joined.endsWith(' $noun')) {
        f.kind = kind;
        matched = true;
        words = joined.substring(0, joined.length - noun.length - 1).split(' ');
        break;
      }
    }
    final original = textIn.split(' ');
    if (!matched) {
      if (words.length != 1) return null;
      final o = original.where((x) => x.toLowerCase() == words[0]).firstOrNull;
      if (o == null || !_isUpper(o)) return null;
      f.kind = FilterKind.creature;
      f.subtype = o;
      return f;
    }
    for (final w in words) {
      switch (w) {
        case 'attacking':
          f.attacking = true;
        case 'blocking':
          f.blocking = true;
        case 'tapped':
          f.tapped = true;
        case 'untapped':
          f.untapped = true;
        case 'nontoken':
          f.nontoken = true;
        case 'nonartifact':
          f.nonartifact = true;
        case 'legendary':
          f.legendary = true;
        case 'or':
          break;
        case 'other':
        case 'another':
          f.other = true;
        default:
          final o = original.where((x) => x.toLowerCase() == w).firstOrNull;
          if (o != null && _isUpper(o) && f.kind == FilterKind.creature) {
            f.subtype = o;
          } else {
            return null;
          }
      }
    }
    return f;
  }

  // MARK: Card phrases the general patterns don't cover

  static TokenSpec get _officer => TokenSpec(name: 'Officer', power: 1, toughness: 1, colors: [ManaColor.red], subtypes: ['Officer']);
  static TokenSpec get _borg => TokenSpec(name: 'Borg', power: 1, toughness: 1, subtypes: ['Borg'], isArtifact: true);

  /// Single sentences with their own shape.
  List<Effect>? extraEffect(String s, String l) {
    List<String>? m;
    if (l == 'you may exile a card from your hand') return const [ExileFromHand()];
    if (l == 'investigate twice') return [CreateTokens(TokenSpec.clue, const Amount.fixed(2), Target.you)];
    if (l == 'you lose the game') return const [LoseGame()];
    if (l == 'you win the game') return const [WinGame()];
    if (l == 'draw that many cards') return const [Draw(Amount.counted(AmountKind.eventAmount), Target.you)];
    if (l == 'when that creature dies this turn, you draw a card') return const [Delayed(DelayedEventKind.lastTouchedDies, [Draw(Amount.one, Target.you)])];
    if (l == 'if that creature would die this turn, exile it instead') return const [ExileIfDiesThisTurn(Target.lastTarget)];
    if (l == 'until end of turn, it gets +1/+1 and becomes a doctor') return const [Pump(1, 1, Target.lastTarget, EffectDuration.endOfTurn), BecomeType('Doctor', Target.lastTarget, replace: true)];
    if (l == 'draw a card if you control a permanent with a counter on it') return const [Conditional(Condition.controlPermanentWithCounter, [Draw(Amount.one, Target.you)])];
    if (l == "look at target opponent's hand") return [HandChoice(ChosenTarget(Filter.opponent), CardPred.any, lookOnly: true)];
    if (l == 'double the number of +1/+1 counters on each creature you control') return [DoubleCounters(EachTarget(Filter(FilterKind.creature, controller: Controller.you)))];
    if (l == 'destroy each nonland permanent with mana value equal to the number of charge counters on ~') return const [DestroyNonlandWithManaValue(Amount.counted(AmountKind.eventAmount))];
    if (l == "create a tapped token that's a copy of target token you control") return [CopyToken(ChosenTarget(Filter(FilterKind.token, controller: Controller.you)), const [], tapped: true)];
    // The color is chosen as the mana is added.
    if (l == 'choose a color') return const [];
    if (l == 'add an amount of mana of that color equal to the number of creature types among non-borg creatures you control') {
      return const [AddManaOfChosenColor(Amount.counted(AmountKind.creatureTypesNonBorg))];
    }
    if (l == 'exile the top card of your library') return const [ExileTopPlayable(Amount.one)];
    if ((m = rx(l, r'they lose (\d+) life')) != null) return [LoseLife(Amount.fixed(int.parse(m![1])), Target.lastTarget)];
    if ((m = rx(l, r'put a \+1/\+1 counter on each (\w+) you control')) != null && !const ['creature', 'artifact', 'permanent'].contains(m![1])) {
      final f = Filter(FilterKind.creature, controller: Controller.you)..subtype = m[1][0].toUpperCase() + m[1].substring(1);
      return [AddCounters(CounterKind.plusOne, Amount.one, EachTarget(f))];
    }
    if ((m = rx(l, r'lose (\d+) life')) != null) return [LoseLife(Amount.fixed(int.parse(m![1])), Target.you)];
    if ((m = rx(l, r"~'s base power and toughness become (\d+)/(\d+)")) != null) return [SetBasePT(int.parse(m![1]), int.parse(m[2]))];
    if ((m = rx(l, r'if this is the second time this ability has resolved this turn, (.+)')) != null) {
      final fx = effect(m![1]);
      return fx == null ? null : [Conditional(Condition.resolvedTimes, fx, n: 2)];
    }
    if ((m = rx(s, r'if you sacrificed an? (\w+) this way, (.+)')) != null) {
      final fx = effect(m![2]);
      return fx == null ? null : [Conditional(Condition.lastHasSubtype, fx, subtype: m[1][0].toUpperCase() + m[1].substring(1))];
    }
    if ((m = rx(l, r"if it's a creature, (.+)")) != null) {
      final fx = effect(m![1]);
      return fx == null ? null : [Conditional(Condition.lastIsCreature, fx)];
    }
    if ((m = rx(l, r"if ~ is the first spell you've cast this game, (.+)")) != null) {
      final fx = effect(m![1]);
      return fx == null ? null : [Conditional(Condition.firstSpellThisGame, fx)];
    }
    if ((m = rx(l, r"if ~ was kicked, instead for each creature target opponent controls, create a token that's a copy of that creature, except it has (.+)")) != null) {
      final k = keyword(m![1]);
      return k == null
          ? null
          : [
              KickedInstead([
                CopyToken(ChosenTarget(Filter.opponent), [k], eachCreatureOfTarget: true),
              ]),
            ];
    }
    if ((m = rx(l, r'exile (.+?) until ~ leaves the battlefield')) != null) {
      final t = target(m![1]);
      return t == null ? null : [ExileUntilLeaves(t)];
    }
    if ((m = rx(l, r'exile the top (\w+) cards? of your library')) != null) {
      final a = amount(m![1]);
      return a == null ? null : [ExileTopPlayable(a)];
    }
    if ((m = rx(l, r'(?:~|it|he|she) deals (twice )?x damage to (.+?)(?:, where x is (.+))?')) != null) {
      final t = target(m![2]);
      final a = m[1].isNotEmpty ? const Amount.counted(AmountKind.twiceX) : (m[3].isEmpty ? const Amount.counted(AmountKind.x) : amountPhrase(m[3]));
      return t == null || a == null ? null : [Damage(a, t)];
    }
    if ((m = rx(s, r'(.+?) gets? \+x/\+(x|0) until end of turn, where x is (.+)')) != null) {
      final t = target(m![1]);
      final a = amountPhrase(m[3]);
      if (t == null || a == null) return null;
      return [PumpAmount(a, m[2].toLowerCase() == 'x' ? a : Amount.zero, t)];
    }
    if ((m = rx(l, r"double ~'s power until end of turn")) != null) return const [PumpAmount(Amount.counted(AmountKind.thisPower), Amount.zero, Target.thisObject)];
    if ((m = rx(s, r'(.+?) gets? ([+-]\d+)/([+-]\d+) until end of turn and can.t be blocked this turn')) != null) {
      final t = target(m![1]);
      return t == null ? null : [Pump(int.parse(m[2]), int.parse(m[3]), t, EffectDuration.endOfTurn), GrantKeyword(Keyword.unblockable, Target.lastTarget, EffectDuration.endOfTurn)];
    }
    if ((m = rx(s, r'(.+?) gets? ([+-]\d+)/([+-]\d+) until your next turn')) != null) {
      final t = target(m![1]);
      return t == null ? null : [PumpUntilYourNextTurn(int.parse(m[2]), int.parse(m[3]), t)];
    }
    if ((m = rx(s, r'attacking (\w+) you control get ([+-]\d+)/([+-]\d+) until end of turn')) != null) {
      var sub = m![1];
      if (sub.endsWith('s')) sub = sub.substring(0, sub.length - 1);
      final f = Filter(FilterKind.creature, controller: Controller.you)
        ..attacking = true
        ..subtype = sub[0].toUpperCase() + sub.substring(1);
      return [Pump(int.parse(m[2]), int.parse(m[3]), EachTarget(f), EffectDuration.endOfTurn)];
    }
    if ((m = rx(s, r'put (a|two|three) \+1/\+1 counters? on each (.+)')) != null) {
      final t = target('each ${m![2]}');
      final a = amount(m[1]);
      if (t != null && a != null) return [AddCounters(CounterKind.plusOne, a, t)];
    }
    if ((m = rx(l, r'(.+?) each deal damage equal to their power to (.+)')) != null) {
      final a = target(m![1]), b = target(m[2]);
      return a == null || b == null ? null : [EachBites(a, b)];
    }
    if ((m = rx(l, r"(target creature or spacecraft)'s owner puts it on their choice of the top or bottom of their library")) != null) {
      return [TopOrBottom(ChosenTarget(Filter(FilterKind.creatureOrSpacecraft)))];
    }
    if ((m = rx(l, r'return (.+?) from your graveyard to the battlefield with a (\w+) counter on it')) != null) {
      final f = graveyardFilter(m![1]);
      final k = CounterKind.values.where((c) => c.text == m![2]).firstOrNull;
      return f == null ? null : [ReturnFromGraveyard(f, LibraryDestination.battlefield, counter: k)];
    }
    if ((m = rx(l, r'put (target (?:creature )?card) from your graveyard on (top|the bottom) of your library')) != null) {
      final f = graveyardFilter(m![1]);
      return f == null ? null : [ReturnFromGraveyard(f, m[2] == 'top' ? LibraryDestination.libraryTop : LibraryDestination.libraryBottom)];
    }
    if (l == "put target creature card from a graveyard onto the battlefield under its owner's control") {
      return [ReturnFromGraveyard(Filter(FilterKind.creatureCardInGraveyard), LibraryDestination.battlefield, underOwnersControl: true)];
    }
    if ((m = rx(l, r'(?:you may )?sacrifice (another|a|an) (creature or artifact|artifact or creature|nonland permanent)')) != null) {
      final kind = m![2] == 'nonland permanent' ? FilterKind.nonlandPermanent : FilterKind.artifactOrCreature;
      final eff = Sacrifice(Target.you, Filter(kind, controller: Controller.you)..other = m[1] == 'another');
      return l.startsWith('you may')
          ? [
              Optional([eff]),
            ]
          : [eff];
    }
    return null;
  }

  /// Whole texts of several sentences that only make sense together.
  List<Effect>? wholeText(String t) {
    var l = t.toLowerCase().trim().replaceAll('\n', ' ');
    while (l.endsWith('.')) {
      l = l.substring(0, l.length - 1);
    }
    l = l.replaceAll(' her.', ' ~.').replaceAll(' on her', ' on ~').replaceAll(' she deals', ' ~ deals');
    switch (l) {
      case "look at target opponent's hand. you may choose a nonland card from it. if you do, that player exiles that card, then draws a card":
        return [HandChoice(ChosenTarget(Filter.opponent), const CardPred(nonland: true), drawAfter: true)];
      case "look at target opponent's hand. you may exile a nonland card from it. for as long as that card remains exiled, its owner may play it. a spell cast this way costs {2} more to cast":
        return [HandChoice(ChosenTarget(Filter.opponent), const CardPred(nonland: true), ownerMayPlayForMore: 2)];
      case 'target opponent exiles cards from the top of their library until they exile a creature card. assimilate that card. they put the rest on the bottom in a random order':
        return [AssimilateFromLibrary(ChosenTarget(Filter.opponent))];
      case 'exile the top four cards of your library. put all permanent cards exiled this way onto the battlefield':
        return const [ExileTopPutPermanents(4)];
      case 'assimilate a creature card exiled with it. if you can\'t, exile up to one target creature':
        return [AssimilateExiledOrExile(ChosenTarget(Filter.creature, optional: true))];
      case 'reveal the top card of your library. you may cast that card without paying its mana cost if that spell\'s mana value is equal to or less than the number of differently named lands you control. if it\'s a land card, you may put it onto the battlefield tapped. if that card is still on top of your library, draw a card':
        return const [RevealTopCastFree(Amount.counted(AmountKind.differentlyNamedLands))];
      case 'exile the top five cards of your library. you may cast any number of spells with mana value less than or equal to the number of officers you control from among those cards without paying their mana costs':
        return const [ExileTopCastFree(5, Amount.counted(AmountKind.subtypeYouControl, subtype: 'Officer'))];
      case 'search your library and/or graveyard for a basic land card or a card named starship enterprise, reveal it, and put it into your hand. if you search your library this way, shuffle':
        return const [
          SearchCard(CardPred(basicLand: true, or: CardPred(names: ['Starship Enterprise'])), LibraryDestination.hand, alsoGraveyard: true),
        ];
      case 'search your library for a spacecraft card, put it onto the battlefield with seven charge counters on it, then shuffle':
        return const [
          SearchCard(CardPred(types: ['Spacecraft']), LibraryDestination.battlefield, counter: CounterKind.charge, counterAmount: 7),
        ];
      case 'put a promotion counter on ~. then if there are three or more promotion counters on ~, remove those counters and ~ deals 2 damage to each opponent':
        return [
          const AddCounters(CounterKind.promotion, Amount.one, Target.thisObject),
          Conditional(
            Condition.selfCountersAtLeast,
            [const RemoveCounters(CounterKind.promotion, Target.thisObject), Damage(const Amount.fixed(2), EachTarget(Filter.opponent))],
            n: 3,
            counter: CounterKind.promotion,
          ),
        ];
      case 'target creature you control gets +1/+0 until end of turn. then that creature gains menace until end of turn if creatures you control have total power 8 or greater':
        return [
          Pump(1, 0, ChosenTarget(Filter(FilterKind.creature, controller: Controller.you)), EffectDuration.endOfTurn),
          const Conditional(Condition.totalPowerAtLeast, [GrantKeyword(Keyword.menace, Target.lastTarget, EffectDuration.endOfTurn)], n: 8),
        ];
      case 'for each opponent, gain control of up to one target creature that player controls with mana value 3 or less until end of turn. untap those creatures. until end of turn, they become warriors in addition to their other types and gain haste':
        return [
          GainControl(ChosenTarget(Filter(FilterKind.creature, controller: Controller.opponent)..maxManaValue = 3, optional: true), untilEndOfTurn: true),
          const Untap(Target.lastTarget),
          const BecomeType('Warrior', Target.lastTarget),
          const GrantKeyword(Keyword.haste, Target.lastTarget, EffectDuration.endOfTurn),
        ];
      case '~ deals 4 damage to target creature an opponent controls. at the beginning of the next combat this turn, gain control of that creature until end of turn. untap it. it gains haste until end of turn':
        return [
          Damage(const Amount.fixed(4), ChosenTarget(Filter(FilterKind.creature, controller: Controller.opponent))),
          const Delayed(DelayedEventKind.nextCombat, [
            GainControl(Target.lastTarget, untilEndOfTurn: true),
            Untap(Target.lastTarget),
            GrantKeyword(Keyword.haste, Target.lastTarget, EffectDuration.endOfTurn),
          ]),
        ];
      case 'you may exile a card from your hand. if you do, draw a card':
        return const [
          ExileFromHand(),
          IfDidPrevious([Draw(Amount.one, Target.you)]),
        ];
      case 'all artifacts and creatures phase out. create a 0/1 white human creature token with "permanents can\'t phase in."':
      case 'all artifacts and creatures phase out. create a 0/1 white human creature token with "permanents can\'t phase in.':
        return [
          PhaseOut(EachTarget(Filter(FilterKind.artifactOrCreature))),
          CreateTokens(TokenSpec(name: 'Human', power: 0, toughness: 1, colors: [ManaColor.white], subtypes: ['Human'], text: "Permanents can't phase in."), Amount.one, Target.you),
        ];
      case 'put a quest counter on ~. create a 1/1 colorless borg artifact creature token. if ~ has six or more quest counters on it, create two of those tokens instead':
        return [
          const AddCounters(CounterKind.quest, Amount.one, Target.thisObject),
          Conditional(
            Condition.selfCountersAtLeast,
            [CreateTokens(_borg, const Amount.fixed(2), Target.you)],
            otherwise: [CreateTokens(_borg, Amount.one, Target.you)],
            n: 6,
            counter: CounterKind.quest,
          ),
        ];
      case 'put a quest counter on ~. put a +1/+1 counter on that creature. if ~ has five or more quest counters on it, instead put two +1/+1 counters on that creature':
        return const [
          AddCounters(CounterKind.quest, Amount.one, Target.thisObject),
          Conditional(
            Condition.selfCountersAtLeast,
            [AddCounters(CounterKind.plusOne, Amount.fixed(2), Target.triggering)],
            otherwise: [AddCounters(CounterKind.plusOne, Amount.one, Target.triggering)],
            n: 5,
            counter: CounterKind.quest,
          ),
        ];
      case 'put a +1/+1 counter on each creature you control that entered this turn. if you put two or more +1/+1 counters on creatures this way, draw a card':
        return [
          AddCounters(CounterKind.plusOne, Amount.one, EachTarget(Filter(FilterKind.creature, controller: Controller.you)..enteredThisTurn = true)),
          const Conditional(Condition.countedAtLeast, [Draw(Amount.one, Target.you)], n: 2),
        ];
      case 'destroy all creatures. create x 1/1 colorless borg artifact creature tokens, where x is the number of nonartifact creatures destroyed this way':
        return [Destroy(EachTarget(Filter.creature)), CreateTokens(_borg, const Amount.counted(AmountKind.countedThisWay), Target.you)];
      case 'mill two cards, then put a +1/+1 counter on ~ for each artifact and/or creature card in your graveyard':
        return const [Mill(2, Target.you), AddCounters(CounterKind.plusOne, Amount.counted(AmountKind.artifactOrCreatureCardsInGraveyard), Target.thisObject)];
      case 'draw a card. then discard a card unless you control five or more differently named lands':
        return const [
          Draw(Amount.one, Target.you),
          Conditional(Condition.differentLandsAtLeast, [Discard(1, Target.you)], n: 5, negate: true),
        ];
      case 'put a +1/+1 counter on up to one other target creature and two charge counters on up to one target spacecraft':
        return [
          AddCounters(CounterKind.plusOne, Amount.one, ChosenTarget(Filter.creature..other = true, optional: true)),
          AddCounters(CounterKind.charge, const Amount.fixed(2), ChosenTarget(Filter(FilterKind.spacecraft), optional: true)),
        ];
      case 'exile the top x cards of your library, where x is the number of opponents you attacked this turn. until the end of your next turn, you may play those cards':
        return const [ExileTopPlayable(Amount.counted(AmountKind.opponentsAttacked), untilNextTurn: true)];
      case 'draw x cards, then you may put up to x land cards from your hand onto the battlefield tapped, where x is the number of other creatures you control with a communicator attached to them':
        return const [Draw(Amount.counted(AmountKind.otherCreaturesWithCommunicator), Target.you), PutLandsFromHand(Amount.counted(AmountKind.otherCreaturesWithCommunicator))];
      case 'shuffle your library, then exile cards from the top of your library until you exile a nonland card. that nonland card gains "exile a card from your hand: create a copy of ~. you may cast the copy. activate only during your turn and only if ~ is exiled."':
      case 'shuffle your library, then exile cards from the top of your library until you exile a nonland card. that nonland card gains "exile a card from your hand: create a copy of ~. you may cast the copy. activate only during your turn and only if ~ is exiled.':
        return const [QStackTheDeck()];
    }
    return null;
  }

  /// Whole ability lines with their own shape (lowercase, "~" for the card's name).
  List<Ability>? specialLine(String l) {
    switch (l) {
      case 'whenever ~ becomes tapped, until end of turn, if one or more counters would be put on a permanent you control, that many plus one of each of those kinds of counters are put on that permanent instead':
        return const [
          Triggered(SimpleTrigger.becomesTapped, [ExtraCountersThisTurn()]),
        ];
      case "at the beginning of your end step, create a 1/1 red officer creature token for each dilemma you've faced this turn":
        return [
          Triggered(SimpleTrigger.endStep, [CreateTokens(_officer, const Amount.counted(AmountKind.dilemmasThisTurn), Target.you)]),
        ];
      case "artifacts creatures you control have vigilance":
        return [StaticAbilityEntry(GrantKeywordStatic(Filter(FilterKind.artifactCreature, controller: Controller.you), Keyword.vigilance))];
      case 'all tribbles get +1/+0 and are goaded':
        final f = Filter(FilterKind.creature)..subtype = 'Tribble';
        return [StaticAbilityEntry(Anthem(f, 1, 0)), StaticAbilityEntry(GrantKeywordStatic(f, Keyword(KeywordKind.mustAttack)))];
      case 'spacecraft creatures you control get +3/+3':
        return [StaticAbilityEntry(Anthem(Filter(FilterKind.creature, controller: Controller.you)..subtype = 'Spacecraft', 3, 3))];
      case 'whenever ~ or another nontoken legendary permanent you control enters, create a food token':
        return [
          Triggered(SimpleTrigger.enters, [CreateTokens(TokenSpec.food, Amount.one, Target.you)]),
          Triggered(
            PermanentEntersTrigger(
              Filter(FilterKind.permanent, controller: Controller.you)
                ..other = true
                ..nontoken = true
                ..legendary = true,
            ),
            [CreateTokens(TokenSpec.food, Amount.one, Target.you)],
          ),
        ];
      case 'whenever another historic permanent you control with mana value 3 or greater enters, draw a card':
        return [
          Triggered(
            PermanentEntersTrigger(
              Filter(FilterKind.permanent, controller: Controller.you)
                ..other = true
                ..historic = true
                ..minManaValue = 3,
            ),
            const [Draw(Amount.one, Target.you)],
          ),
        ];
      case 'whenever a creature you control enters, put a quest counter on ~. put a +1/+1 counter on that creature. if ~ has five or more quest counters on it, instead put two +1/+1 counters on that creature':
        return [
          Triggered(
            PermanentEntersTrigger(Filter(FilterKind.creature, controller: Controller.you)),
            wholeText('put a quest counter on ~. put a +1/+1 counter on that creature. if ~ has five or more quest counters on it, instead put two +1/+1 counters on that creature')!,
          ),
        ];
      case 'whenever a nontoken artifact you control enters, put a quest counter on ~. create a 1/1 colorless borg artifact creature token. if ~ has six or more quest counters on it, create two of those tokens instead':
        return [
          Triggered(
            PermanentEntersTrigger(Filter(FilterKind.artifact, controller: Controller.you)..nontoken = true),
            wholeText('put a quest counter on ~. create a 1/1 colorless borg artifact creature token. if ~ has six or more quest counters on it, create two of those tokens instead')!,
          ),
        ];
      case 'at the beginning of combat on your turn, if you\'ve cast a noncreature spell this turn, create a token that\'s a copy of target creature you control, except it isn\'t legendary. it gains haste until end of turn. sacrifice it at the beginning of the next end step':
        return [
          Triggered(SimpleTrigger.beginCombat, [
            CopyToken(ChosenTarget(Filter(FilterKind.creature, controller: Controller.you)), const [], nonLegendary: true, hasteUntilEndOfTurn: true, sacrificeAtEnd: true),
          ], condition: const TriggerCondition(TriggerConditionKind.castNoncreatureThisTurn)),
        ];
      case 'at the beginning of combat on each player\'s turn, that player may draw a card. if they do, they can\'t attack this turn and you put a peace counter on ~':
        return const [
          Triggered(SimpleTrigger.eachBeginCombat, [PeaceOffer()]),
        ];
      case 'equipped creature gets +2/+2 and has "whenever ~ attacks, look at the top five cards of your library. you may put a klingon or warrior creature card from among them onto the battlefield. put the rest on the bottom of your library in a random order."':
        return const [
          StaticAbilityEntry(AttachedGets(2, 2)),
          Triggered(SimpleTrigger.equippedAttacks, [
            LookAtTop(
              Amount.fixed(5),
              CardPred(types: ['Creature'], subtypes: ['Klingon', 'Warrior']),
              destination: LibraryDestination.battlefield,
            ),
          ]),
        ];
      case 'equipped creature has "whenever ~ attacks, draw x cards, then you may put up to x land cards from your hand onto the battlefield tapped, where x is the number of other creatures you control with a communicator attached to them."':
        return const [
          Triggered(SimpleTrigger.equippedAttacks, [
            Draw(Amount.counted(AmountKind.otherCreaturesWithCommunicator), Target.you),
            PutLandsFromHand(Amount.counted(AmountKind.otherCreaturesWithCommunicator)),
          ]),
        ];
      case "enchanted permanent doesn't untap during its controller's untap step and can't be beamed up":
        return const [StaticAbilityEntry(SimpleStatic(SimpleStaticKind.attachedDoesntUntap)), StaticAbilityEntry(SimpleStatic(SimpleStaticKind.attachedCantBeBeamedUp))];
      case 'when you cast ~, copy it':
        return const [
          Triggered(SimpleTrigger.castThis, [CopyThisSpell()]),
        ];
      case 'as ~ enters, choose a number between 0 and 10':
        return const [ChooseNumberOnEnter(0, 10)];
      case "you may have ~ enter as a copy of any artifact or creature on the battlefield, except it isn't legendary. if you do, it enters with additional counters on it equal to the same number and kinds of counters the copied permanent has on it":
        return [EnterAsCopy(Filter(FilterKind.artifactOrCreature))];
      case '~ costs {1} less to cast if it targets an attacking creature':
        return const [CostReductionIfTargetsAttacker(1)];
      case "{6}: create a tapped planet land token named new planet with \"{t}: add one mana of any color.\" activate only as a sorcery":
        return [
          Activated(ActivationCost(mana: ManaCost(generic: 6)), [
            CreateTokens(TokenSpec(name: 'New Planet', subtypes: ['Planet'], isCreature: false, isLand: true, text: '{T}: Add one mana of any color.'), Amount.one, Target.you, tapped: true),
          ], sorcerySpeed: true),
        ];
    }
    return null;
  }

  /// "a Plains card or nonland permanent card with mana value 3 or less", "a noncreature, nonland
  /// card", "a Klingon or Warrior creature card", "one of them".
  CardPred? cardPred(String textIn) {
    var t = textIn.toLowerCase().trim();
    if (t == 'one of them' || t == 'a card') return CardPred.any;
    final both = rx(t, r'(.+? card) or (.+ card(?: with mana value \d+ or less)?)');
    if (both != null) {
      final a = cardPred(both[1]), b = cardPred(both[2]);
      if (a == null || b == null) return null;
      return CardPred(types: a.types, notTypes: a.notTypes, subtypes: a.subtypes, maxManaValue: a.maxManaValue, permanent: a.permanent, nonland: a.nonland, basicLand: a.basicLand, or: b);
    }
    int? maxMv;
    final mv = rx(t, r'(.+?) with mana value (\d+) or less');
    if (mv != null) {
      t = mv[1];
      maxMv = int.parse(mv[2]);
    }
    t = t.replaceFirst(RegExp(r'^(a|an) '), '').replaceFirst(RegExp(r' cards?$'), '');
    final types = <String>[], notTypes = <String>[], subtypes = <String>[];
    var permanent = false, nonland = false;
    final words = t.replaceAll(',', '').split(' ').where((w) => w.isNotEmpty).toList();
    for (var i = 0; i < words.length; i++) {
      final w = words[i];
      switch (w) {
        case 'permanent':
          permanent = true;
        case 'nonland':
          nonland = true;
        case 'noncreature':
          notTypes.add('Creature');
        case 'land':
        case 'creature':
        case 'artifact':
        case 'enchantment':
        case 'instant':
        case 'sorcery':
          types.add(w[0].toUpperCase() + w.substring(1));
        case 'plains':
        case 'island':
        case 'swamp':
        case 'mountain':
        case 'forest':
        case 'spacecraft':
          types.add(w[0].toUpperCase() + w.substring(1));
        case 'or':
          break;
        default:
          // "klingon or warrior": creature types, any of them.
          subtypes.add(w[0].toUpperCase() + w.substring(1));
      }
    }
    return CardPred(types: types, notTypes: notTypes, subtypes: subtypes, maxManaValue: maxMv, permanent: permanent, nonland: nonland);
  }
}

/// Collects "Look at the top N cards of your library. ... from among them ... . Put the rest ..."
class _LookBuilder {
  _LookBuilder(this.n);
  final Amount n;
  CardPred pick = CardPred.any;
  var optional = false;
  var destination = LibraryDestination.hand;
  var rest = RestDestination.bottomRandom;

  bool absorb(String l, _Parser p) {
    List<String>? m;
    if ((m = rx(l, r'(?:you may )?(?:reveal )?(.+?) from among them and put it into your hand')) != null) {
      final pred = p.cardPred(m![1]);
      if (pred == null) return false;
      pick = pred;
      optional = l.startsWith('you may');
      destination = LibraryDestination.hand;
      return true;
    }
    if ((m = rx(l, r'put one of them into your hand and the rest on the bottom of your library in (?:a random|any) order')) != null) {
      pick = CardPred.any;
      optional = false;
      rest = RestDestination.bottomRandom;
      return true;
    }
    if ((m = rx(l, r'(?:you may )?put (.+?) from among them onto the battlefield( tapped)?(?: and the rest into your graveyard)?')) != null) {
      final pred = p.cardPred(m![1]);
      if (pred == null) return false;
      pick = pred;
      optional = l.startsWith('you may');
      destination = m[2].isEmpty ? LibraryDestination.battlefield : LibraryDestination.battlefieldTapped;
      if (l.endsWith('the rest into your graveyard')) rest = RestDestination.graveyard;
      return true;
    }
    if ((m = rx(l, r'put the rest on the bottom(?: of your library)? in (a random|any) order')) != null) {
      rest = m![1] == 'any' ? RestDestination.bottom : RestDestination.bottomRandom;
      return true;
    }
    return false;
  }

  LookAtTop build() => LookAtTop(n, pick, destination: destination, rest: rest, optional: optional);
}
