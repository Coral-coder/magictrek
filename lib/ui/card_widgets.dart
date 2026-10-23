import 'package:flutter/material.dart' hide Card;

import '../app/session.dart';
import '../engine/abilities.dart';
import '../engine/cards.dart';
import '../engine/game.dart';
import '../engine/state.dart';
import 'lcars.dart';

const cardAspect = 370 / 265;

/// A card face at any size, with a drawn fallback when there is no scan (tokens).
class CardFace extends StatelessWidget {
  const CardFace({super.key, this.card, this.token, this.width = 80, this.border, this.glow});
  final Card? card;
  final TokenSpec? token;
  final double width;
  final Color? border;
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final h = width * cardAspect;
    final radius = BorderRadius.circular(width * 0.045);
    final c = card;
    Widget face = c != null
        ? Image.asset(c.imagePath, width: width, height: h, fit: BoxFit.cover, filterQuality: FilterQuality.medium, errorBuilder: (_, _, _) => TokenFace(card: c, token: token, width: width))
        : TokenFace(card: null, token: token, width: width);
    face = ClipRRect(borderRadius: radius, child: face);
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(
        borderRadius: radius,
        border: border == null ? null : Border.all(color: border!, width: 2.5),
        boxShadow: glow == null ? null : [BoxShadow(color: glow!.withValues(alpha: 0.8), blurRadius: 8, spreadRadius: 1)],
      ),
      child: face,
    );
  }
}

/// A token with no printed scan, drawn as a card: name bar, art, type line, rules text and
/// power/toughness in a frame of its color.
class TokenFace extends StatelessWidget {
  const TokenFace({super.key, this.card, this.token, required this.width});
  final Card? card;
  final TokenSpec? token;
  final double width;

  // Frame and pale panel colors, like a card's frame.
  static const _frames = {
    'W': (Color(0xFFE6DCC0), Color(0xFFF8F3E3)),
    'U': (Color(0xFF2A6FB0), Color(0xFFD3E3F2)),
    'B': (Color(0xFF3B3533), Color(0xFFD6CDCA)),
    'R': (Color(0xFFC0432C), Color(0xFFF4D0C2)),
    'G': (Color(0xFF2E7A47), Color(0xFFD0E6D3)),
    'multi': (Color(0xFFC6A445), Color(0xFFF2E6B8)),
    'land': (Color(0xFF8A6D4C), Color(0xFFE9DCC8)),
    'none': (Color(0xFF8F99A3), Color(0xFFE0E4E8)),
  };

  /// A picture for the art box, from what the token is.
  static IconData iconFor(String name, List<String> subtypes, {bool land = false, bool artifact = false}) {
    final words = {name.toLowerCase(), ...subtypes.map((s) => s.toLowerCase())};
    bool has(String w) => words.any((x) => x.contains(w));
    if (land || has('planet')) return Icons.public;
    if (has('borg')) return Icons.hub;
    if (has('klingon') || has('warrior')) return Icons.shield;
    if (has('romulan')) return Icons.visibility;
    if (has('officer')) return Icons.badge;
    if (has('human')) return Icons.person;
    if (has('dog') || has('porthos')) return Icons.pets;
    if (has('tribble')) return Icons.blur_on;
    if (has('worm')) return Icons.gesture;
    if (has('illusion')) return Icons.auto_awesome;
    if (has('treasure')) return Icons.diamond;
    if (has('clue')) return Icons.search;
    if (has('food')) return Icons.restaurant;
    if (has('spacecraft') || has('ship')) return Icons.rocket_launch;
    return artifact ? Icons.settings : Icons.auto_awesome;
  }

  @override
  Widget build(BuildContext context) {
    final t = token, c = card;
    final name = (t?.name ?? c?.name ?? '').isEmpty ? 'Token' : (t?.name ?? c!.name);
    final colors = t != null ? t.colors.map((m) => m.symbol).toList() : (c?.colors ?? const <String>[]);
    final isLand = t?.isLand ?? c?.isLand ?? false;
    final isArtifact = t?.isArtifact ?? c?.types.contains('Artifact') ?? false;
    final isCreature = t?.isCreature ?? c?.isCreature ?? false;
    final subtypes = t?.subtypes ?? c?.subtypes ?? const <String>[];
    final String typeLine;
    final String rules;
    final String? pt;
    if (t != null) {
      final types = [if (t.isLegendary) 'Legendary', 'Token', if (t.isArtifact) 'Artifact', if (t.isCreature) 'Creature', if (t.isLand) 'Land'];
      typeLine = '${types.join(' ')}${t.subtypes.isEmpty ? '' : ' — ${t.subtypes.join(' ')}'}';
      rules = [if (t.keywords.isNotEmpty) t.keywords.map((k) => '$k').join(', '), if (t.text.isNotEmpty) t.text.replaceAll('~', name)].join('\n');
      pt = t.isCreature ? '${t.power}/${t.toughness}' : null;
    } else {
      typeLine = c?.typeLine ?? 'Token';
      rules = c?.oracleText ?? '';
      pt = c != null && c.power != null ? '${c.power}/${c.toughness}' : null;
    }
    final key = isLand && colors.isEmpty ? 'land' : (colors.length > 1 ? 'multi' : (colors.isEmpty ? 'none' : colors.first));
    final (frame, pale) = _frames[key] ?? _frames['none']!;
    final w = width, h = width * cardAspect;
    final ink = const Color(0xFF151515);
    Widget bar(String text, double size) => Container(
      height: h * 0.072,
      padding: EdgeInsets.symmetric(horizontal: w * 0.035),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: pale,
        borderRadius: BorderRadius.circular(w * 0.03),
        border: Border.all(color: Color.lerp(frame, Colors.black, 0.35)!, width: w * 0.008 + 0.5),
      ),
      child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(text, maxLines: 1, style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: ink, height: 1.1))),
    );
    return Container(
      width: w,
      height: h,
      padding: EdgeInsets.all(w * 0.035),
      decoration: BoxDecoration(color: const Color(0xFF0B0B0B), borderRadius: BorderRadius.circular(w * 0.045)),
      child: Container(
        padding: EdgeInsets.all(w * 0.03),
        decoration: BoxDecoration(color: frame, borderRadius: BorderRadius.circular(w * 0.025)),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bar(name, w * 0.075),
                SizedBox(height: h * 0.01),
                Expanded(
                  flex: 11,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black54, width: w * 0.006 + 0.5),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color.lerp(frame, Colors.black, 0.55)!, Color.lerp(frame, Colors.white, 0.15)!],
                      ),
                    ),
                    child: Center(child: Icon(iconFor(name, subtypes, land: isLand, artifact: isArtifact && !isCreature), size: w * 0.36, color: Colors.white.withValues(alpha: 0.85))),
                  ),
                ),
                SizedBox(height: h * 0.01),
                bar(typeLine, w * 0.058),
                SizedBox(height: h * 0.01),
                Expanded(
                  flex: 8,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(w * 0.04, w * 0.03, w * 0.04, pt != null ? w * 0.09 : w * 0.03),
                    decoration: BoxDecoration(color: pale, border: Border.all(color: Color.lerp(frame, Colors.black, 0.35)!, width: w * 0.006 + 0.5)),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: w * 0.78,
                        child: Text(rules, style: TextStyle(fontSize: w * 0.06, color: ink, height: 1.2)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (pt != null)
              Positioned(
                right: -w * 0.005,
                bottom: -h * 0.012,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: w * 0.04, vertical: w * 0.01),
                  decoration: BoxDecoration(
                    color: pale,
                    borderRadius: BorderRadius.circular(w * 0.03),
                    border: Border.all(color: Color.lerp(frame, Colors.black, 0.35)!, width: w * 0.01 + 0.5),
                  ),
                  child: Text(pt, style: TextStyle(fontSize: w * 0.08, fontWeight: FontWeight.w800, color: ink, height: 1.1)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A permanent on the table: face, tap rotation, counters, current power/toughness and status.
class PermanentView extends StatelessWidget {
  const PermanentView({super.key, required this.session, required this.objectID, this.width = 70, this.highlighted = false, this.selected = false, this.dimmed = false, this.onTap, this.onLongPress, this.tag});
  final GameSession session;
  final ObjectID objectID;
  final double width;
  final bool highlighted, selected, dimmed;
  final VoidCallback? onTap, onLongPress;
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final obj = session.state.objects[objectID];
    final t = obj?.token;
    final card = obj == null ? null : (obj.cardID.isEmpty ? (t == null ? null : session.db.tokenCard(t.name, power: t.power, toughness: t.toughness)) : session.db[obj.cardID]);
    final c = session.game.characteristics(objectID);
    final h = width * cardAspect;
    final tapped = obj?.tapped ?? false;
    final badges = <Widget>[];
    if (obj != null) {
      void badge(String text, Color color) => badges.add(Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(8)),
            child: Text(text, style: LCARS.font(width * 0.13, color: LCARS.black)),
          ));
      if (obj.plusOneCounters > 0) badge('+${obj.plusOneCounters}', LCARS.green);
      if (obj.chargeCounters > 0) badge('⚡${obj.chargeCounters}', LCARS.blue);
      final lore = obj.counters[CounterKind.lore] ?? 0;
      if (lore > 0) badge('☰$lore', LCARS.lavender);
      final stun = obj.counters[CounterKind.stun] ?? 0;
      if (stun > 0) badge('✕$stun', LCARS.red);
    }
    String? status = tag;
    Color statusColor = LCARS.skyBlue;
    if (status == null && obj != null) {
      if (obj.attacking != null) {
        status = 'ATK';
        statusColor = LCARS.alert;
      } else if (obj.blocking != null) {
        status = 'BLK';
      } else if (obj.attachedTo != null) {
        status = '⇡';
        statusColor = LCARS.gold;
      }
    }
    Color ptColor = LCARS.peach;
    if (obj != null && card != null) {
      if (obj.damage > 0) {
        ptColor = LCARS.red;
      } else if (c.power > card.basePower || c.toughness > card.baseToughness) {
        ptColor = LCARS.green;
      } else if (c.power < card.basePower || c.toughness < card.baseToughness) {
        ptColor = LCARS.butterscotch;
      }
    }
    final body = SizedBox(
      width: width,
      height: h,
      child: Stack(clipBehavior: Clip.none, children: [
        CardFace(card: card, token: obj?.token, width: width, border: selected ? LCARS.gold : (highlighted ? LCARS.ice : null), glow: highlighted ? LCARS.gold : null),
        if (c.isCreature)
          Positioned(
            bottom: -4,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: ptColor, borderRadius: BorderRadius.circular(10)),
                child: Text('${c.power}/${c.toughness}', style: LCARS.font(width * 0.17, color: LCARS.black)),
              ),
            ),
          ),
        Positioned(top: 3, left: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: badges)),
        if (status != null)
          Positioned(
            top: 3,
            right: 3,
            child: Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(8)), child: Text(status, style: LCARS.font(width * 0.13, color: LCARS.black))),
          ),
      ]),
    );
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: dimmed ? 0.4 : 1,
        child: SizedBox(
          width: tapped ? h : width,
          height: h,
          child: Center(child: AnimatedRotation(duration: const Duration(milliseconds: 300), turns: tapped ? 0.25 : 0, child: body)),
        ),
      ),
    );
  }
}

/// A card in hand: face plus a glow when it can be played.
class HandCardView extends StatelessWidget {
  const HandCardView({super.key, required this.session, required this.objectID, this.width = 84, this.playable = false, this.selected = false, this.onTap, this.onLongPress});
  final GameSession session;
  final ObjectID objectID;
  final double width;
  final bool playable, selected;
  final VoidCallback? onTap, onLongPress;
  @override
  Widget build(BuildContext context) {
    final obj = session.state.objects[objectID];
    final card = obj == null || obj.cardID.isEmpty ? null : session.db[obj.cardID];
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        transform: Matrix4.translationValues(0, selected ? -14 : 0, 0),
        child: CardFace(card: card, token: obj?.token, width: width, border: selected ? LCARS.gold : (playable ? LCARS.ice : null), glow: playable ? LCARS.ice : null),
      ),
    );
  }
}

/// The card face (hi-res from Scryfall when reachable, else the bundled scan), rules text and what the engine implements.
class CardDetailBody extends StatelessWidget {
  const CardDetailBody({super.key, required this.card, required this.db});
  final Card card;
  final CardDatabase db;

  @override
  Widget build(BuildContext context) {
    final parsed = db.parsed(card);
    final supportColor = parsed.fullySupported ? LCARS.green : (parsed.anySupported ? LCARS.gold : LCARS.red);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 30),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 12),
            child: Container(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: LCARS.blue.withValues(alpha: 0.4), blurRadius: 18)]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 300,
                  height: 300 * cardAspect,
                  child: Stack(fit: StackFit.expand, children: [
                    Image.asset(card.imagePath, fit: BoxFit.cover, filterQuality: FilterQuality.high),
                  ]),
                ),
              ),
            ),
          ),
        ),
        Row(children: [
          ManaCostPips(card.manaCost, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(card.typeLine, style: LCARS.font(12, color: LCARS.lavender))),
          if (card.power != null) Text('${card.power}/${card.toughness}', style: LCARS.heading),
        ]),
        const SizedBox(height: 8),
        LcarsPanel(title: 'Rules', color: LCARS.orange, child: Text(card.oracleText.isEmpty ? '(No rules text.)' : card.oracleText, style: const TextStyle(fontSize: 15, color: LCARS.peach))),
        if (card.flavorText.isNotEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(card.flavorText, style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic, color: LCARS.gray))),
        LcarsPanel(
          title: 'Engine',
          color: supportColor,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              parsed.fullySupported
                  ? 'Fully playable: every ability on this card works in the game.'
                  : (parsed.anySupported ? 'Partly playable: stats and some abilities work; the text below is not yet implemented.' : 'Stats only: this card plays as a vanilla card for now.'),
              style: LCARS.font(12, color: supportColor),
            ),
            for (final u in parsed.unsupported) Text('• $u', style: const TextStyle(fontSize: 13, color: LCARS.gray)),
          ]),
        ),
        const SizedBox(height: 8),
        Text('${card.set.toUpperCase()} #${card.collectorNumber} · ${card.rarity.name} · art ${card.artist}', style: LCARS.small.copyWith(color: LCARS.gray)),
      ]),
    );
  }
}
