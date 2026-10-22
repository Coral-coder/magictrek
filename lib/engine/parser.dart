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
    'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5, 'six': 6, 'seven': 7, 'eight': 8,
    'nine': 9, 'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13, 'twenty': 20,
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
      if (line.endsWith('—') || line.toLowerCase().endsWith('choose one —')) {
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
    if (comma >= 0) names.add(fullName.substring(0, comma));
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
        abilities.add(StationAbilities(int.parse(station[1]), const []));
        unsupported.add(line);
      }
      return;
    }
    // Ability words ("Landfall — ", "Cloaking Device — ") are just labels.
    var body = line;
    final label = rx(line, r"([A-Z][A-Za-z' ]+) — (.+)");
    if (label != null && !label[1].toLowerCase().startsWith('choose')) body = label[2];
    final bl = body.toLowerCase();

    final kws = keywordLine(body);
    if (kws != null) {
      abilities.addAll(kws);
      return;
    }
    final mana = rx(body, r'\{T\}: Add (.+?)\.?');
    if (mana != null) {
      final colors = manaColors(mana[1]);
      if (colors != null) {
        abilities.add(ManaAbility(colors));
        return;
      }
    }
    final s = staticAbility(bl);
    if (s != null) {
      abilities.add(StaticAbilityEntry(s));
      return;
    }
    if (bl.startsWith('when') || bl.startsWith('at the beginning of')) {
      parseTriggered(body);
      return;
    }
    final act = rx(body, r'([^:]+): (.+)');
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
        final (fx, bad) = effects(effectText);
        if (bad.isEmpty && fx.isNotEmpty) {
          abilities.add(Activated(cost, fx, sorcerySpeed: sorcery));
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
        out.add(const StaticAbilityEntry(SimpleStatic.enchantCreature));
        continue;
      }
      if (p == 'enchant creature an opponent controls') {
        out.add(const StaticAbilityEntry(SimpleStatic.enchantCreatureOpponentControls));
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

  StaticAbility? staticAbility(String l) {
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
    if ((m = rx(l, r'(.+?) have "(.+)"')) != null) {
      final f = filterFromPlural(m![1]);
      if (f != null) {
        final inner = m[2][0].toUpperCase() + m[2].substring(1);
        final parts = triggerParts(inner);
        if (parts != null && parts.length == 1) return GrantTrigger(f, parts[0].$1, parts[0].$2);
      }
      return null;
    }
    if ((m = rx(l, r'(.+?) (?:get|have) (.+?)\.')) != null) {
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
    final f = Filter(FilterKind.permanent, controller: controller)..withCounters = withCounters;
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

  bool _endsWith(List<String> words, List<String> suffix) {
    if (words.length < suffix.length) return false;
    for (var i = 0; i < suffix.length; i++) {
      if (words[words.length - suffix.length + i] != suffix[i]) return false;
    }
    return true;
  }

  bool _isUpper(String s) => s.isNotEmpty && s[0].toUpperCase() == s[0] && s[0].toLowerCase() != s[0];

  // MARK: Triggers

  void parseTriggered(String line) {
    final parts = triggerParts(line);
    if (parts != null) {
      for (final (e, fx) in parts) {
        abilities.add(Triggered(e, fx));
      }
    } else {
      unsupported.add(line);
    }
  }

  List<(TriggerEvent, List<Effect>)>? triggerParts(String l) {
    var m = rx(l, r"At the beginning of (your upkeep|your end step|combat on your turn|each combat|your precombat main phase|each upkeep|each end step|each opponent's upkeep), (.+)", dotAll: true);
    if (m != null) {
      TriggerEvent? event;
      switch (m[1].toLowerCase()) {
        case 'your upkeep':
          event = SimpleTrigger.upkeep;
        case 'your end step':
          event = SimpleTrigger.endStep;
        case 'combat on your turn':
          event = SimpleTrigger.beginCombat;
        case 'each upkeep':
          event = SimpleTrigger.eachUpkeep;
      }
      final fx = triggerEffects(m[2]);
      if (event == null || fx == null) return null;
      return [(event, fx)];
    }
    m = rx(l, r'(When|Whenever) (.+?) (enters or attacks|attacks or blocks|enters untapped|enters|dies|die|attacks|blocks|becomes blocked|leaves the battlefield|deals combat damage to a player|deals combat damage to a player or planeswalker|deals combat damage to an opponent|becomes tapped|is put into a graveyard from the battlefield), (.+)', dotAll: true);
    if (m == null) {
      var n = rx(l, r'Whenever you cast (a|an) (noncreature|creature|artifact|instant or sorcery)? ?spell, (.+)', dotAll: true);
      if (n != null) {
        final kind = const {'noncreature': SpellKind.noncreature, 'creature': SpellKind.creature, 'artifact': SpellKind.artifact, 'instant or sorcery': SpellKind.instantOrSorcery}[n[2].toLowerCase()] ?? SpellKind.any;
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

  List<Effect>? triggerEffects(String text) {
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
      var m = rx(p, r'sacrifice (a|an|another) (creature|artifact|land|permanent|token)');
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
    final modal = rx(t, r'choose one —\s*(.+)', dotAll: true);
    if (modal != null) {
      final modes = <List<Effect>>[];
      for (final mode in modal[1].split('\n').map((s) => s.trim()).where((s) => s.startsWith('•'))) {
        var modeText = mode.substring(1).trim();
        final named = rx(modeText, r'[A-Z][^—]+ — (.+)', dotAll: true);
        if (named != null) modeText = named[1];
        final (fx, b) = effects(modeText);
        if (b.isNotEmpty || fx.isEmpty) return ([], [t]);
        modes.add(fx);
      }
      return modes.isEmpty ? ([], [t]) : ([Modal(modes)], []);
    }
    for (final sentence in sentences(t)) {
      final l = sentence.toLowerCase();
      if (l.startsWith('if you do, ') && out.isNotEmpty) {
        final fx = effect(sentence.substring(11));
        if (fx != null) {
          final last = out.last;
          if (last is Optional) {
            out[out.length - 1] = Optional([...last.effects, ...fx]);
          } else {
            out.add(IfDidPrevious(fx));
          }
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
    return result.map((s) {
      var x = s.trim();
      while (x.endsWith('.')) {
        x = x.substring(0, x.length - 1);
      }
      if (x.startsWith('Then ') || x.startsWith('then ')) x = x.substring(5);
      return x;
    }).where((s) => s.isNotEmpty).toList();
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
    }
    return null;
  }

  /// One sentence to effects, or null.
  List<Effect>? effect(String sentenceIn) {
    var s = sentenceIn.trim();
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    final l = s.toLowerCase();
    List<String>? m;

    if (l.startsWith('you may ')) {
      final inner = effect(s.substring(8));
      return inner == null ? null : [Optional(inner)];
    }
    if ((m = rx(s, r'(.+?), then (.+)')) != null) {
      final a = effect(m![1]), b = effect(m[2]);
      if (a != null && b != null) return [...a, ...b];
    }
    if ((m = rx(s, r"if ~ (isn't|is) a creature, (.+)")) != null) {
      final inner = effect(m![2]);
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
      if (a != null) return [AddCounters(CounterKind.plusOne, a, ChosenTarget(Filter.creature))];
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
        if (m[4].isNotEmpty) {
          for (final kw in m[4].split(' and ').map((s) => s.trim())) {
            final k = keyword(kw);
            if (k == null) return null;
            fx.add(GrantKeyword(k, t, EffectDuration.endOfTurn));
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
          fx.add(GrantKeyword(k, t, EffectDuration.endOfTurn));
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
    if ((m = rx(l, '(?:(each player|each opponent|target player|target opponent) )?creates? (?:[^,]+, )?$_num (?:legendary )?(\\d+)/(\\d+) (.+?) creature tokens?(?: with (.+?))?(?: named .+)?')) != null) {
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
      return const [Optional([SearchBasicLand(LibraryDestination.hand, Target.controllerOfLastTarget)])];
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
    if ((m = rx(l, r'(each opponent|target opponent|target player|each player) sacrifices? (a|an) (nontoken )?(creature|artifact|land|permanent|enchantment|artifact or enchantment|artifact or creature)(?: of their choice)?')) != null) {
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
          f.kind = FilterKind.token;
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
    final m = rx(l, r'target (artifact )?creature card with mana value (\d+) or less');
    if (m != null) return Filter(FilterKind.creatureCardInGraveyard, controller: Controller.you)..maxManaValue = int.parse(m[2]);
    return null;
  }

  // MARK: Targets

  Target? target(String textIn) {
    final t = textIn.trim().toLowerCase();
    switch (t) {
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
    var m = rx(t, r'up to (one|two|three) (?:other )?target (.+)');
    if (m != null) {
      final n = numberWord(m[1]);
      final f = targetFilter(m[2]);
      if (n != null && f != null) return ChosenTarget(f, count: n, optional: true);
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
      ('creature', FilterKind.creature),
      ('spacecraft', FilterKind.spacecraft),
      ('artifact', FilterKind.artifact),
      ('enchantment', FilterKind.enchantment),
      ('permanent', FilterKind.permanent),
      ('land', FilterKind.land),
      ('opponent', FilterKind.opponent),
      ('player', FilterKind.player),
      ('token', FilterKind.token),
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
}
