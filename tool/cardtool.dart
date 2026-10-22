// ignore_for_file: avoid_print
// Developer tool: how much of the set the parser covers, and what it gives up on.
//   dart run tool/cardtool.dart            summary + the most common unsupported clauses
//   dart run tool/cardtool.dart <name>     the parsed abilities of one card
//   dart run tool/cardtool.dart --all      every card's text next to what the engine understood
import 'dart:io';

import 'package:magictrek/engine/abilities.dart';
import 'package:magictrek/engine/cards.dart';
import 'package:magictrek/engine/props.dart';

/// Filters spelled out with the names of the flags they set.
String showFilter(Filter f) {
  final bits = <String>[f.kind.name, if (f.controller != Controller.any) f.controller.name];
  void flag(bool on, String name) {
    if (on) bits.add(name);
  }

  flag(f.other, 'other');
  flag(f.legendary, 'legendary');
  flag(f.nonBorg, 'nonBorg');
  flag(f.enteredThisTurn, 'enteredThisTurn');
  flag(f.historic, 'historic');
  flag(f.attacking, 'attacking');
  flag(f.blocking, 'blocking');
  flag(f.tapped, 'tapped');
  flag(f.untapped, 'untapped');
  flag(f.nontoken, 'nontoken');
  flag(f.nonartifact, 'nonartifact');
  flag(f.withCounters, 'withCounters');
  if (f.subtype != null) bits.add('subtype=${f.subtype}');
  if (f.maxPower != null) bits.add('power<=${f.maxPower}');
  if (f.minPower != null) bits.add('power>=${f.minPower}');
  if (f.maxManaValue != null) bits.add('mv<=${f.maxManaValue}');
  if (f.minManaValue != null) bits.add('mv>=${f.minManaValue}');
  return 'Filter(${bits.join(' ')})';
}

/// A parsed ability or effect written out in full: `Damage(fixed 3, ChosenTarget(...))`.
/// Unset values (null, false, empty lists) are left out to keep it short.
String show(Object? o) {
  if (o == null) return 'null';
  if (o is Enum) return o.name;
  if (o is Filter) return showFilter(o);
  if (o is List) return '[${o.map(show).join(', ')}]';
  if (o is Set) return '{${o.map(show).join(', ')}}';
  if (o is Map) return '{${o.entries.map((e) => '${show(e.key)}: ${show(e.value)}').join(', ')}}';
  if (o is Props) {
    final parts = o.props.where((v) => v != null && v != false && !(v is List && v.isEmpty) && !(v is Set && v.isEmpty)).map(show);
    final name = o.runtimeType.toString();
    return parts.isEmpty ? name : '$name(${parts.join(', ')})';
  }
  return '$o';
}

void describe(Card card, CardDatabase db) {
  print('## ${card.name} ${card.manaCost} | ${card.typeLine} | ${card.power ?? '-'}/${card.toughness ?? '-'}');
  print(card.oracleText.split('\n').map((l) => '   | $l').join('\n'));
  final p = db.parsed(card);
  for (final a in p.abilities) {
    print('  + ${show(a)}');
  }
  if (p.spellEffects.isNotEmpty) print('  spell: ${show(p.spellEffects)}');
  if (p.kicker != null) print('  kicker: ${p.kicker}');
  for (final u in p.unsupported) {
    print('  x $u');
  }
}

void main(List<String> args) {
  final db = CardDatabase.fromJsonString(File('assets/cards.json').readAsStringSync());
  if (args.isNotEmpty && args.first == '--all') {
    for (final card in db.distinctCards.where((c) => !c.isBasicLand)) {
      describe(card, db);
      print('');
    }
    return;
  }
  if (args.isNotEmpty) {
    final q = args.first.toLowerCase();
    for (final card in db.distinctCards.where((c) => c.name.toLowerCase().contains(q))) {
      describe(card, db);
    }
    return;
  }
  var full = 0, partial = 0, none = 0;
  final clauses = <String, int>{};
  final byType = <String, List<int>>{};
  for (final card in db.distinctCards) {
    final p = db.parsed(card);
    final kind = card.types.isEmpty ? '?' : card.types.last;
    final entry = byType.putIfAbsent(kind, () => [0, 0]);
    entry[1]++;
    if (p.fullySupported) {
      full++;
      entry[0]++;
    } else if (p.anySupported) {
      partial++;
    } else {
      none++;
    }
    for (final u in p.unsupported) {
      clauses[u] = (clauses[u] ?? 0) + 1;
    }
  }
  print('${db.distinctCards.length} cards: $full fully supported, $partial partially, $none stats only');
  final types = byType.keys.toList()..sort();
  for (final k in types) {
    print('  $k: ${byType[k]![0]}/${byType[k]![1]}');
  }
  print('\nUnsupported clauses:');
  final sorted = clauses.entries.toList()..sort((a, b) => a.value != b.value ? b.value - a.value : a.key.compareTo(b.key));
  final limit = int.tryParse(Platform.environment['LIMIT'] ?? '') ?? 40;
  for (final e in sorted.take(limit)) {
    print('  ${e.value}x ${e.key}');
  }
}
