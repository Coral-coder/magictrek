import 'cards.dart';

/// A deck: card ids with counts. 60 cards, at most 4 of a name (basic lands unlimited).
class Deck {
  Deck({String? id, required this.name, Map<String, int>? cards, List<ManaColor>? colors, this.isStarter = false})
      : id = id ?? _newId(),
        cards = cards ?? {},
        colors = colors ?? [];

  final String id;
  String name;
  final Map<String, int> cards;
  List<ManaColor> colors;
  final bool isStarter;

  static int _counter = 0;
  static String _newId() => '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_counter++).toRadixString(36)}';

  static const size = 60;
  static const maxCopies = 4;

  int get count => cards.values.fold<int>(0, (a, b) => a + b);

  /// The card ids expanded to a list, sorted so the same deck always serialises the same way.
  List<String> get cardList {
    final keys = cards.keys.toList()..sort();
    return [for (final k in keys) for (var i = 0; i < cards[k]!; i++) k];
  }

  List<String> problems(CardDatabase db) {
    final out = <String>[];
    if (count != size) out.add('A deck needs $size cards (this one has $count)');
    final byName = <String, int>{};
    cards.forEach((id, n) {
      final c = db[id];
      if (c == null) {
        out.add('Unknown card $id');
      } else {
        byName[c.name] = (byName[c.name] ?? 0) + n;
      }
    });
    byName.forEach((name, n) {
      if (n > maxCopies) {
        final c = db.byName(name);
        if (c != null && !c.isBasicLand) out.add('Only $maxCopies copies of $name allowed ($n)');
      }
    });
    return out;
  }

  bool isLegal(CardDatabase db) => problems(db).isEmpty;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'cards': cards, 'colors': colors.map((c) => c.symbol).toList(), 'isStarter': isStarter};

  factory Deck.fromJson(Map<String, dynamic> j) => Deck(
        id: j['id'] as String,
        name: j['name'] as String,
        cards: (j['cards'] as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
        colors: (j['colors'] as List? ?? const []).map((e) => ManaColor.fromSymbol(e as String)).whereType<ManaColor>().toList(),
        isStarter: j['isStarter'] as bool? ?? false,
      );

  Deck copy({String? name, bool? isStarter}) => Deck(name: name ?? this.name, cards: Map.of(cards), colors: List.of(colors), isStarter: isStarter ?? false);
}

class Faction {
  const Faction(this.name, this.colors, this.blurb);
  final String name;
  final List<ManaColor> colors;
  final String blurb;
}

/// Ready-made decks per faction, built from the cards the engine fully implements.
class StarterDecks {
  static const factions = [
    Faction('Starfleet Command', [ManaColor.white, ManaColor.blue], 'Officers, Spacecraft and the United Federation of Planets.'),
    Faction('Klingon Empire', [ManaColor.red, ManaColor.black], 'Warriors who attack early and die with honor.'),
    Faction('The Borg Collective', [ManaColor.blue, ManaColor.black], 'Artifact creatures that assimilate what they destroy.'),
    Faction('Frontier Explorers', [ManaColor.green, ManaColor.white], 'Strange new worlds, Landfall and growing crews.'),
    Faction('Romulan Star Empire', [ManaColor.blue, ManaColor.red], 'Cloaked ships and tricks at instant speed.'),
    Faction('Dominion War', [ManaColor.black, ManaColor.green], 'Attrition, sacrifice and relentless growth.'),
  ];

  /// Builds a deck for a color pair: supported spells of those colors by curve, then lands.
  static Deck deck(Faction faction, CardDatabase db) {
    final colors = faction.colors.toSet();
    final supported = db.fullySupportedCards;
    final pool = <Card>[
      ...supported.where((c) => !c.isLand && c.colors.isNotEmpty && c.colors.every(colors.contains) && c.set != 'sds'),
      ...supported.where((c) => c.colors.isEmpty && !c.isLand && c.manaValue <= 4 && c.set != 'sds'),
    ];
    int score(Card c) {
      var s = c.isCreature ? 10 : 5;
      if (c.isSpacecraft) s += 6;
      s += ((6 - (c.manaValue - 3).abs()).clamp(0, 6)) * 2;
      if (c.rarity == Rarity.rare || c.rarity == Rarity.mythic) s += 3;
      if (c.colors.length == 2) s += 2;
      if (c.colors.isEmpty) s -= 4;
      return s;
    }
    final ranked = List.of(pool)..sort((a, b) => score(a) != score(b) ? score(b) - score(a) : a.name.compareTo(b.name));
    final cards = <String, int>{};
    var total = 0;
    final curve = <int, int>{};
    const spells = 36;
    const caps = {0: 2, 1: 6, 2: 10, 3: 10, 4: 8, 5: 6, 6: 4};
    for (final c in ranked) {
      if (total >= spells) break;
      final copies = c.isLegendary ? 2 : (c.rarity == Rarity.mythic ? 2 : 3);
      final bucket = c.manaValue > 6 ? 6 : c.manaValue;
      final cap = caps[bucket] ?? 4;
      if ((curve[bucket] ?? 0) >= cap) continue;
      final n = copies < spells - total ? copies : spells - total;
      cards[c.id] = n;
      total += n;
      curve[bucket] = (curve[bucket] ?? 0) + n;
    }
    var lands = 0;
    final duals = supported.where((c) => c.isLand && !c.isBasicLand && c.producedMana.toSet().length == colors.length && c.producedMana.every(colors.contains) && c.set != 'sds').toList();
    for (final d in duals.take(2)) {
      cards[d.id] = 4;
      lands += 4;
    }
    final weight = <ManaColor, int>{};
    cards.forEach((id, n) {
      db[id]?.cost.colored.forEach((col, k) => weight[col] = (weight[col] ?? 0) + k * n);
    });
    final need = Deck.size - total - lands;
    final totalWeight = faction.colors.fold<int>(0, (a, c) => a + (weight[c] ?? 0)).clamp(1, 1 << 30);
    var given = 0;
    for (var i = 0; i < faction.colors.length; i++) {
      final color = faction.colors[i];
      final n = i == faction.colors.length - 1 ? need - given : ((weight[color] ?? 0) / totalWeight * need).round();
      final basic = db.byName(color.basicLandType);
      if (basic != null) {
        cards[basic.id] = (cards[basic.id] ?? 0) + n;
        given += n;
      }
    }
    return Deck(name: faction.name, cards: cards, colors: List.of(faction.colors), isStarter: true);
  }

  static List<Deck> all(CardDatabase db) => factions.map((f) => deck(f, db)).toList();
}
