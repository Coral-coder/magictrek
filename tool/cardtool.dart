// ignore_for_file: avoid_print
// Developer tool: how much of the set the parser covers, and what it gives up on.
//   dart run tool/cardtool.dart            summary + the most common unsupported clauses
//   dart run tool/cardtool.dart <name>     the parsed abilities of one card
import 'dart:io';

import 'package:magictrek/engine/cards.dart';

void main(List<String> args) {
  final db = CardDatabase.fromJsonString(File('assets/cards.json').readAsStringSync());
  if (args.isNotEmpty) {
    final q = args.first.toLowerCase();
    for (final card in db.distinctCards.where((c) => c.name.toLowerCase().contains(q))) {
      print('## ${card.name} ${card.manaCost} | ${card.typeLine} | ${card.power ?? '-'}/${card.toughness ?? '-'}');
      print(card.oracleText);
      final p = db.parsed(card);
      for (final a in p.abilities) {
        print('  + $a');
      }
      for (final u in p.unsupported) {
        print('  x $u');
      }
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
