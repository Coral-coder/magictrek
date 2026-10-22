import 'package:flutter/material.dart' hide Card;

import '../app/store.dart';
import '../engine/cards.dart';
import 'card_widgets.dart';
import 'lcars.dart';

/// Browse every card: search, filter by color, type and rarity.
class CardGalleryScreen extends StatefulWidget {
  const CardGalleryScreen({super.key});
  @override
  State<CardGalleryScreen> createState() => _CardGalleryScreenState();
}

class _CardGalleryScreenState extends State<CardGalleryScreen> {
  String search = '';
  ManaColor? color;
  String? type;
  Rarity? rarity;
  bool onlySupported = false, showVariants = false, showTokens = false;

  List<Card> get cards {
    final db = AppStore.shared.db;
    final base = showTokens ? db.tokens : (showVariants ? (db.cards.where((c) => !c.token).toList()..sort((a, b) => a.compareTo(b))) : db.distinctCards);
    final q = search.toLowerCase();
    return base.where((c) {
      if (color != null && !c.colors.contains(color)) return false;
      if (type != null && !c.types.contains(type)) return false;
      if (rarity != null && c.rarity != rarity) return false;
      if (onlySupported && !db.parsed(c).fullySupported) return false;
      if (q.isNotEmpty && !c.name.toLowerCase().contains(q) && !c.oracleText.toLowerCase().contains(q) && !c.typeLine.toLowerCase().contains(q)) return false;
      return true;
    }).toList();
  }

  Widget chip(String text, bool selected, Color c, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: selected ? c : c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14), border: Border.all(color: c)),
            child: Text(text.toUpperCase(), style: LCARS.font(10, color: selected ? LCARS.black : c)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final db = AppStore.shared.db;
    final list = cards;
    return LcarsFrame(
      title: 'Card Database',
      subtitle: '${db.distinctCards.length} cards',
      color: LCARS.lavender,
      blocks: const [LCARS.blue, LCARS.peach, LCARS.orange, LCARS.violet, LCARS.skyBlue],
      onBack: () => Navigator.pop(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          decoration: const InputDecoration(hintText: 'Search names and rules', isDense: true, filled: true, fillColor: LCARS.panel, border: OutlineInputBorder(borderSide: BorderSide.none)),
          style: LCARS.body,
          onChanged: (v) => setState(() => search = v),
        ),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final c in ManaColor.values) chip(c.label, color == c, LCARS.forMana(c.symbol), () => setState(() => color = color == c ? null : c)),
            for (final t in const ['Creature', 'Artifact', 'Instant', 'Sorcery', 'Enchantment', 'Land']) chip(t, type == t, LCARS.lavender, () => setState(() => type = type == t ? null : t)),
            for (final r in Rarity.values) chip(r.name, rarity == r, LCARS.gold, () => setState(() => rarity = rarity == r ? null : r)),
            chip('Fully playable', onlySupported, LCARS.green, () => setState(() => onlySupported = !onlySupported)),
            chip('All printings', showVariants, LCARS.peach, () => setState(() => showVariants = !showVariants)),
            chip('Tokens', showTokens, LCARS.ice, () => setState(() => showTokens = !showTokens)),
          ]),
        ),
        Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text('${list.length} cards', style: LCARS.small.copyWith(color: LCARS.gray))),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.only(bottom: 30),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 96, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1 / (cardAspect + 0.2)),
            itemCount: list.length,
            itemBuilder: (_, i) {
              final card = list[i];
              return GestureDetector(
                onTap: () => Navigator.pushNamed(context, '/card', arguments: card.id),
                child: Column(children: [
                  Expanded(child: LayoutBuilder(builder: (_, box) => CardFace(card: card, width: box.maxWidth))),
                  Text(card.name, style: LCARS.small, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class CardDetailScreen extends StatelessWidget {
  const CardDetailScreen({super.key, required this.cardID});
  final String cardID;
  @override
  Widget build(BuildContext context) {
    final db = AppStore.shared.db;
    final card = db[cardID];
    return Scaffold(
      appBar: AppBar(title: Text(card?.name ?? 'Card', style: LCARS.font(18, color: LCARS.orange))),
      body: card == null ? const Center(child: Text('Unknown card')) : Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: CardDetailBody(card: card, db: db)),
    );
  }
}
