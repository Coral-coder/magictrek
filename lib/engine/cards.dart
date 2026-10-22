import 'dart:convert';

import 'abilities.dart';
import 'parser.dart';
import 'props.dart';

/// One of the five colors of mana.
enum ManaColor {
  white('W', 'White', 'Plains'),
  blue('U', 'Blue', 'Island'),
  black('B', 'Black', 'Swamp'),
  red('R', 'Red', 'Mountain'),
  green('G', 'Green', 'Forest');

  const ManaColor(this.symbol, this.label, this.basicLandType);
  final String symbol;
  final String label;
  final String basicLandType;

  static ManaColor? fromSymbol(String s) {
    for (final c in values) {
      if (c.symbol == s) return c;
    }
    return null;
  }
}

enum Rarity { common, uncommon, rare, mythic }

/// A printed card: what is on the face, as decoded from cards.json.
class Card with Props {
  Card({
    required this.id,
    required this.name,
    required this.file,
    this.set = 'trk',
    this.collectorNumber = '',
    this.rarity = Rarity.common,
    this.manaCost = '',
    this.manaValue = 0,
    this.colors = const [],
    List<ManaColor>? colorIdentity,
    required this.typeLine,
    this.supertypes = const [],
    this.types = const [],
    this.subtypes = const [],
    this.oracleText = '',
    this.flavorText = '',
    this.keywords = const [],
    this.power,
    this.toughness,
    this.producedMana = const [],
    this.producesColorless = false,
    this.layout = 'normal',
    this.artist = '',
    this.variant = false,
    this.imageLarge = '',
  }) : colorIdentity = colorIdentity ?? colors;

  /// The image file's stem, e.g. "captainjeanlucpicard".
  final String id;
  final String name;
  final String file;
  final String set;
  final String collectorNumber;
  final Rarity rarity;
  final String manaCost;
  final int manaValue;
  final List<ManaColor> colors;
  final List<ManaColor> colorIdentity;
  final String typeLine;
  final List<String> supertypes;
  final List<String> types;
  final List<String> subtypes;
  final String oracleText;
  final String flavorText;
  final List<String> keywords;
  final String? power;
  final String? toughness;
  final List<ManaColor> producedMana;
  final bool producesColorless;
  final String layout;
  final String artist;
  final bool variant;
  final String imageLarge;

  factory Card.fromJson(Map<String, dynamic> j) {
    List<String> strings(String k) => (j[k] as List?)?.map((e) => e.toString()).toList() ?? const [];
    List<ManaColor> colors(String k) => strings(k).map(ManaColor.fromSymbol).whereType<ManaColor>().toList();
    final produced = strings('producedMana');
    return Card(
      id: j['id'] as String,
      name: j['name'] as String,
      file: j['file'] as String,
      set: (j['set'] as String?) ?? '',
      collectorNumber: (j['collectorNumber'] as String?) ?? '',
      rarity: Rarity.values.firstWhere((r) => r.name == j['rarity'], orElse: () => Rarity.common),
      manaCost: (j['manaCost'] as String?) ?? '',
      manaValue: (j['manaValue'] as num?)?.toInt() ?? 0,
      colors: colors('colors'),
      colorIdentity: j['colorIdentity'] == null ? null : colors('colorIdentity'),
      typeLine: j['typeLine'] as String,
      supertypes: strings('supertypes'),
      types: strings('types'),
      subtypes: strings('subtypes'),
      oracleText: (j['oracleText'] as String?) ?? '',
      flavorText: (j['flavorText'] as String?) ?? '',
      keywords: strings('keywords'),
      power: j['power'] as String?,
      toughness: j['toughness'] as String?,
      producedMana: produced.map(ManaColor.fromSymbol).whereType<ManaColor>().toList(),
      producesColorless: produced.contains('C'),
      layout: (j['layout'] as String?) ?? 'normal',
      artist: (j['artist'] as String?) ?? '',
      variant: (j['variant'] as bool?) ?? false,
      imageLarge: (j['imageLarge'] as String?) ?? '',
    );
  }

  bool get isLand => types.contains('Land');
  bool get isBasicLand => isLand && supertypes.contains('Basic');
  bool get isCreature => types.contains('Creature');
  bool get isArtifact => types.contains('Artifact');
  bool get isEnchantment => types.contains('Enchantment');
  bool get isInstant => types.contains('Instant');
  bool get isSorcery => types.contains('Sorcery');
  bool get isLegendary => supertypes.contains('Legendary');
  bool get isSpacecraft => subtypes.contains('Spacecraft');
  bool get isSaga => subtypes.contains('Saga');
  bool get isAura => subtypes.contains('Aura');
  bool get isEquipment => subtypes.contains('Equipment');
  bool get isPermanent => !isInstant && !isSorcery;
  bool get isSpell => !isLand;

  ManaCost get cost => ManaCost.parse(manaCost);
  int get basePower => int.tryParse(power ?? '') ?? 0;
  int get baseToughness => int.tryParse(toughness ?? '') ?? 0;

  /// For a Spacecraft: the number of charge counters at which it becomes a creature.
  int? get stationThreshold {
    if (!isSpacecraft) return null;
    for (final line in oracleText.split('\n')) {
      final m = RegExp(r'^(\d+)\+\s*\|').firstMatch(line);
      if (m != null) return int.parse(m.group(1)!);
    }
    return null;
  }

  String get colorKey => colors.isEmpty ? 'C' : (colors.map((c) => c.symbol).toList()..sort()).join();

  /// The rules text with reminder text (parentheses) removed.
  String get rulesText => stripReminders(oracleText);

  static String stripReminders(String text) {
    final out = StringBuffer();
    var depth = 0;
    for (final ch in text.runes) {
      final s = String.fromCharCode(ch);
      if (s == '(') {
        depth++;
        continue;
      }
      if (s == ')') {
        if (depth > 0) depth--;
        continue;
      }
      if (depth == 0) out.write(s);
    }
    return out.toString().split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).join('\n');
  }

  /// Sort by set, then collector number, so the gallery reads like the printed set.
  List<Comparable> get sortKey => [set == 'trk' ? 0 : (set == 'trc' ? 1 : 2), int.tryParse(collectorNumber.replaceAll(RegExp(r'\D'), '')) ?? 9999, id];

  int compareTo(Card other) {
    final a = sortKey, b = other.sortKey;
    for (var i = 0; i < a.length; i++) {
      final c = a[i].compareTo(b[i]);
      if (c != 0) return c;
    }
    return 0;
  }

  @override
  List<Object?> get props => [id];

  @override
  String toString() => name;
}

/// A mana cost such as {2}{W}{W} or {X}{R}.
class ManaCost with Props {
  ManaCost({this.generic = 0, Map<ManaColor, int>? colored, List<List<ManaColor>>? hybrid, this.hasX = false})
      : colored = colored ?? {},
        hybrid = hybrid ?? [];

  int generic;
  final Map<ManaColor, int> colored;
  final List<List<ManaColor>> hybrid;
  bool hasX;

  factory ManaCost.parse(String text) {
    final c = ManaCost();
    var symbol = '';
    var inSymbol = false;
    for (final ch in text.split('')) {
      if (ch == '{') {
        inSymbol = true;
        symbol = '';
        continue;
      }
      if (ch == '}') {
        inSymbol = false;
        final n = int.tryParse(symbol);
        if (n != null) {
          c.generic += n;
        } else if (symbol == 'X') {
          c.hasX = true;
        } else if (symbol == 'C') {
          c.generic += 1;
        } else if (symbol.contains('/')) {
          final parts = symbol.split('/').map(ManaColor.fromSymbol).whereType<ManaColor>().toList();
          if (parts.length == 2) {
            c.hybrid.add(parts);
          } else if (parts.isNotEmpty) {
            c.colored[parts.first] = (c.colored[parts.first] ?? 0) + 1;
          }
        } else {
          final col = ManaColor.fromSymbol(symbol);
          if (col != null) c.colored[col] = (c.colored[col] ?? 0) + 1;
        }
        continue;
      }
      if (inSymbol) symbol += ch;
    }
    return c;
  }

  ManaCost copy() => ManaCost(generic: generic, colored: Map.of(colored), hybrid: hybrid.map((h) => List.of(h)).toList(), hasX: hasX);

  int get manaValue => generic + colored.values.fold<int>(0, (a, b) => a + b) + hybrid.length;
  bool get isFree => manaValue == 0 && !hasX;

  void add(ManaCost other) {
    generic += other.generic;
    other.colored.forEach((k, v) => colored[k] = (colored[k] ?? 0) + v);
    hybrid.addAll(other.hybrid);
  }

  @override
  List<Object?> get props => [generic, colored, hybrid, hasX];

  @override
  String toString() {
    final s = StringBuffer(hasX ? '{X}' : '');
    if (generic > 0) s.write('{$generic}');
    for (final c in ManaColor.values) {
      for (var i = 0; i < (colored[c] ?? 0); i++) {
        s.write('{${c.symbol}}');
      }
    }
    for (final h in hybrid) {
      s.write('{${h.map((c) => c.symbol).join('/')}}');
    }
    return s.isEmpty ? '{0}' : s.toString();
  }
}

/// Every card image in the app with its rules data, loaded from cards.json.
class CardDatabase {
  CardDatabase(List<Card> cards, {this.generated = ''}) : cards = List.unmodifiable(cards) {
    for (final c in cards) {
      _byId[c.id] = c;
    }
    final sorted = List.of(cards)..sort((a, b) => (a.variant ? 1 : 0) - (b.variant ? 1 : 0));
    for (final c in sorted) {
      _byName.putIfAbsent(c.name, () => c);
    }
  }

  factory CardDatabase.fromJsonString(String json) {
    final d = jsonDecode(json) as Map<String, dynamic>;
    return CardDatabase((d['cards'] as List).map((e) => Card.fromJson(e as Map<String, dynamic>)).toList(), generated: (d['generated'] as String?) ?? '');
  }

  final List<Card> cards;
  final String generated;
  final Map<String, Card> _byId = {};
  final Map<String, Card> _byName = {};
  final Map<String, ParsedCard> _parsed = {};

  Card? operator [](String id) => _byId[id];
  Card? byName(String name) => _byName[name];

  /// One card per name: the main printing of each.
  List<Card> get distinctCards => _byName.values.toList()..sort((a, b) => a.compareTo(b));

  /// The abilities parsed from a card's rules text, cached.
  ParsedCard parsed(Card card) => _parsed.putIfAbsent(card.id, () => AbilityParser.parse(card));

  /// Cards whose rules text the engine implements completely.
  List<Card> get fullySupportedCards => distinctCards.where((c) => parsed(c).fullySupported).toList();
}
