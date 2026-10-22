import 'package:flutter/material.dart' hide Card;

import '../app/sound.dart';
import '../app/store.dart';
import '../engine/cards.dart';
import '../engine/decks.dart';
import 'card_widgets.dart';
import 'lcars.dart';

class DeckListScreen extends StatelessWidget {
  const DeckListScreen({super.key});

  Widget row(BuildContext context, Deck deck, CardDatabase db) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/deck', arguments: deck.id),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: deck.isStarter ? LCARS.lavender : LCARS.peach.withValues(alpha: 0.15),
          border: deck.isStarter ? null : Border.all(color: LCARS.peach, width: 2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            for (final c in deck.colors)
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(color: LCARS.forMana(c.symbol), shape: BoxShape.circle),
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                deck.name.toUpperCase(),
                style: LCARS.font(14, color: deck.isStarter ? LCARS.black : LCARS.peach),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text('${deck.count}', style: LCARS.font(11, color: deck.isStarter ? LCARS.black : LCARS.peach)),
            if (!deck.isLegal(db))
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.warning_amber, size: 14, color: LCARS.alert),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final store = AppStore.shared;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => LcarsFrame(
        title: 'Decks',
        subtitle: '${store.decks.length} decks',
        color: LCARS.violet,
        blocks: const [LCARS.lavender, LCARS.orange, LCARS.blue, LCARS.peach, LCARS.butterscotch],
        onBack: () => Navigator.pop(context),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 30),
          children: [
            LcarsButton(
              'New deck',
              icon: Icons.add,
              onPressed: () async {
                final deck = Deck(name: 'New deck');
                await store.saveDeck(deck);
                if (context.mounted) Navigator.pushNamed(context, '/deck', arguments: deck.id);
              },
            ),
            const LcarsHeader('Your decks', color: LCARS.peach),
            if (store.customDecks.isEmpty) Text('None yet. Copy a starter deck to begin.', style: LCARS.label.copyWith(color: LCARS.gray)),
            for (final d in store.customDecks) row(context, d, store.db),
            const LcarsHeader('Starter decks', color: LCARS.lavender),
            for (final d in store.starterDecks) row(context, d, store.db),
          ],
        ),
      ),
    );
  }
}

/// Edit a deck: the list on top, the card pool below with filters. Starter decks are copied on edit.
class DeckEditorScreen extends StatefulWidget {
  const DeckEditorScreen({super.key, required this.deckID});
  final String deckID;
  @override
  State<DeckEditorScreen> createState() => _DeckEditorScreenState();
}

class _DeckEditorScreenState extends State<DeckEditorScreen> {
  String search = '';
  ManaColor? color;
  late final TextEditingController nameController;

  AppStore get store => AppStore.shared;
  Deck? get deck => store.deck(widget.deckID);

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(text: deck?.name ?? '');
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  List<Card> get pool => store.db.distinctCards.where((c) {
    if (color != null && !c.colors.contains(color) && !(c.isLand && c.producedMana.contains(color))) return false;
    final q = search.toLowerCase();
    if (q.isNotEmpty && !c.name.toLowerCase().contains(q) && !c.typeLine.toLowerCase().contains(q)) return false;
    return true;
  }).toList();

  List<(Card, int)> entries(Deck d) {
    final out = <(Card, int)>[];
    d.cards.forEach((id, n) {
      final c = store.db[id];
      if (c != null) out.add((c, n));
    });
    out.sort((a, b) {
      if (a.$1.isLand != b.$1.isLand) return a.$1.isLand ? 1 : -1;
      if (a.$1.manaValue != b.$1.manaValue) return a.$1.manaValue - b.$1.manaValue;
      return a.$1.name.compareTo(b.$1.name);
    });
    return out;
  }

  Future<void> change(Card card, int delta) async {
    final d = deck;
    if (d == null || d.isStarter) return;
    final current = d.cards[card.id] ?? 0;
    final next = (current + delta).clamp(0, 99);
    if (delta > 0 && !card.isBasicLand && next > Deck.maxCopies) {
      Console.shared.play(Fx.deny);
      return;
    }
    if (next == 0) {
      d.cards.remove(card.id);
    } else {
      d.cards[card.id] = next;
    }
    final colors = <ManaColor>{};
    for (final id in d.cards.keys) {
      colors.addAll(store.db[id]?.colors ?? const []);
    }
    d.colors = ManaColor.values.where(colors.contains).toList();
    await store.saveDeck(d);
    Console.shared.play(Fx.tap);
    setState(() {});
  }

  Widget curve(Deck d) {
    final buckets = List.filled(7, 0);
    d.cards.forEach((id, n) {
      final c = store.db[id];
      if (c != null && !c.isLand) buckets[c.manaValue > 6 ? 6 : c.manaValue] += n;
    });
    final maxN = buckets.fold<int>(1, (a, b) => a > b ? a : b);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < 7; i++)
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: (buckets[i] / maxN * 28).clamp(2, 28),
                  decoration: BoxDecoration(color: LCARS.blue, borderRadius: BorderRadius.circular(2)),
                ),
                Text(i == 6 ? '6+' : '$i', style: const TextStyle(fontSize: 8, color: LCARS.gray)),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = deck;
    if (d == null) return const Scaffold(body: Center(child: Text('Deck not found')));
    final problems = d.problems(store.db);
    return LcarsFrame(
      title: d.name,
      subtitle: d.isStarter ? 'starter' : '${d.count} cards',
      color: d.isStarter ? LCARS.lavender : LCARS.peach,
      onBack: () => Navigator.pop(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.isStarter)
            LcarsButton(
              'Copy to edit',
              height: 36,
              onPressed: () async {
                final copy = await store.duplicateDeck(d);
                if (context.mounted) Navigator.pushReplacementNamed(context, '/deck', arguments: copy.id);
              },
            )
          else
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    style: LCARS.body,
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: LCARS.panel,
                      border: OutlineInputBorder(borderSide: BorderSide.none),
                      hintText: 'Deck name',
                    ),
                    onChanged: (v) {
                      d.name = v;
                      store.saveDeck(d);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 50,
                  child: LcarsButton(
                    '',
                    icon: Icons.delete_outline,
                    color: LCARS.red,
                    fill: false,
                    height: 36,
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => AlertDialog(
                          title: Text('Delete ${d.name}?'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await store.deleteDeck(d);
                        if (context.mounted) Navigator.pop(context);
                      }
                    },
                  ),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  problems.isEmpty ? 'Ready to play' : problems.first,
                  style: LCARS.small.copyWith(color: problems.isEmpty ? LCARS.green : LCARS.gold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              curve(d),
            ],
          ),
          Container(
            constraints: const BoxConstraints(maxHeight: 230),
            decoration: BoxDecoration(color: LCARS.panel.withValues(alpha: 0.6), borderRadius: BorderRadius.circular(8)),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(4),
              children: [
                for (final (card, n) in entries(d))
                  InkWell(
                    onTap: () => Navigator.pushNamed(context, '/card', arguments: card.id),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 28,
                          child: Text('$n×', style: LCARS.font(12, color: LCARS.gold)),
                        ),
                        ManaCostPips(card.manaCost, size: 12),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            card.name,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: LCARS.peach),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!d.isStarter) ...[
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.remove_circle_outline, color: LCARS.red, size: 20),
                            onPressed: () => change(card, -1),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.add_circle_outline, color: LCARS.green, size: 20),
                            onPressed: () => change(card, 1),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (!d.isStarter) ...[
            const LcarsHeader('Add cards', color: LCARS.blue),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    style: LCARS.body,
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: true,
                      fillColor: LCARS.panel,
                      border: OutlineInputBorder(borderSide: BorderSide.none),
                      hintText: 'Search',
                    ),
                    onChanged: (v) => setState(() => search = v),
                  ),
                ),
                for (final c in ManaColor.values)
                  GestureDetector(
                    onTap: () => setState(() => color = color == c ? null : c),
                    child: Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(left: 4),
                      decoration: BoxDecoration(
                        color: LCARS.forMana(c.symbol),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: color == c ? 2 : 0),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.only(bottom: 30),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 76, mainAxisSpacing: 6, crossAxisSpacing: 6, childAspectRatio: 1 / (cardAspect + 0.25)),
                itemCount: pool.length,
                itemBuilder: (_, i) {
                  final card = pool[i];
                  return Column(
                    children: [
                      Expanded(
                        child: LayoutBuilder(
                          builder: (_, box) => GestureDetector(
                            onTap: () => change(card, 1),
                            onLongPress: () => Navigator.pushNamed(context, '/card', arguments: card.id),
                            child: CardFace(card: card, width: box.maxWidth),
                          ),
                        ),
                      ),
                      Text('${d.cards[card.id] ?? 0}/${card.isBasicLand ? '∞' : '4'}', style: LCARS.small.copyWith(color: LCARS.gray)),
                    ],
                  );
                },
              ),
            ),
          ] else
            const Spacer(),
        ],
      ),
    );
  }
}
