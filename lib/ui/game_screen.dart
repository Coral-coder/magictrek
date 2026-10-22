import 'package:flutter/material.dart' hide Card;

import '../app/session.dart';
import '../app/sound.dart';
import '../app/store.dart';
import '../engine/abilities.dart';
import '../engine/actions.dart';
import '../engine/bot.dart';
import '../engine/cards.dart';
import '../engine/game.dart';
import '../engine/state.dart';
import 'card_widgets.dart';
import 'lcars.dart';
import 'tour.dart';

/// What the player is in the middle of doing on the table.
sealed class Interaction {
  const Interaction();
}

class Idle extends Interaction {
  const Idle();
}

class Targeting extends Interaction {
  const Targeting({required this.requirements, required this.chosen, required this.purpose, this.inCurrent = 0});
  /// The requirements still to fill; the first is the one being chosen now.
  final List<TargetRequirement> requirements;
  /// Every target chosen so far, in order.
  final List<ObjectID> chosen;
  final Purpose purpose;
  /// How many of [chosen] belong to the current requirement ("one or two target creatures").
  final int inCurrent;
}

class Attacking extends Interaction {
  const Attacking(this.selected);
  final Set<ObjectID> selected;
}

class Blocking extends Interaction {
  const Blocking({required this.assignments, this.blocker});
  final Map<ObjectID, ObjectID> assignments;
  final ObjectID? blocker;
}

class Stationing extends Interaction {
  const Stationing(this.ship);
  final ObjectID ship;
}

class Equipping extends Interaction {
  const Equipping(this.equipment);
  final ObjectID equipment;
}

class BeamingUp extends Interaction {
  const BeamingUp(this.card);
  final ObjectID card;
}

class DecisionTargets extends Interaction {
  const DecisionTargets(this.chosen);
  final List<ObjectID> chosen;
}

class PickingCards extends Interaction {
  const PickingCards(this.chosen);
  final List<ObjectID> chosen;
}

sealed class Purpose {
  const Purpose();
}

class CastPurpose extends Purpose {
  const CastPurpose(this.card, {this.kicked = false, this.mode, this.x = 0});
  final ObjectID card;
  final bool kicked;
  final int? mode;
  final int x;
}

class ActivatePurpose extends Purpose {
  const ActivatePurpose(this.object, this.index);
  final ObjectID object;
  final int index;
}

/// The table. Opponent on top, you below, hand at the bottom, LCARS controls in the middle.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});
  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  Interaction interaction = const Idle();
  ObjectID? selectedHandCard;
  PlayerID? lifeFlash;
  int lastEventCount = 0;

  /// The guided tour of the table: the current step, or null when it is not showing.
  int? tourStep;
  final _tourOpponent = GlobalKey();
  final _tourBar = GlobalKey();
  final _tourMine = GlobalKey();
  final _tourStrip = GlobalKey();
  final _tourHand = GlobalKey();
  final _tourHelp = GlobalKey();

  List<TourStep> get tourSteps => [
    const TourStep('Welcome aboard', 'A one-minute look around the table. You can see it again any time from the ? button at the top.'),
    TourStep('Your opponent', 'Their name, life, and how many cards they hold, have in their deck and in their graveyard. Below: the cards they have in play, with their lands as labels.', target: _tourOpponent),
    TourStep('The command bar', 'The light bulb line tells you what you can do right now. The buttons move the game on: Attack, End turn, and answers when a card asks you something.', target: _tourBar),
    TourStep('Your battlefield', 'Your creatures and other cards in play. Your lands are the labels underneath: each says how many are ready to tap for mana this turn.', target: _tourMine),
    TourStep('Your status', 'Your life (lose it all and you lose), cards in hand, deck and graveyard. Tap GRAVE to look through a graveyard.', target: _tourStrip),
    TourStep('Your hand', 'Cards with a blue glow can be played now. Tap any card to see it large and choose what to do with it. Slide sideways to see the rest.', target: _tourHand),
    TourStep('Help', 'Lost? Tap here for help on what to do now, the full rules, and to turn these hints off. Good luck, Captain.', target: _tourHelp),
  ];

  void closeTour() {
    setState(() => tourStep = null);
    AppStore.shared.setTourSeen(true);
  }

  GameSession? get session => AppStore.shared.session;
  Game get game => session!.game;
  GameState get state => session!.state;
  PlayerID get me => session!.localSeat;
  PlayerID get them => state.opponentOf(me);
  bool get myTurn => state.activePlayer == me && state.pending == null;

  /// Whether this player may act now: their own turn, or holding priority to respond.
  bool get canAct => state.playerToAct == me && state.pending == null && !state.isOver;

  @override
  void initState() {
    super.initState();
    session?.addListener(_onSession);
    _syncBlocking();
    // First time at the table: show the tour once the layout exists.
    if (!AppStore.shared.tourSeen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => tourStep = 0);
      });
    }
  }

  @override
  void dispose() {
    session?.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    for (final e in session!.recentEvents) {
      if (e.kind == 'lifeChanged' && (e.amount ?? 0) < 0) {
        lifeFlash = e.player;
        Future<void>.delayed(const Duration(milliseconds: 450), () {
          if (mounted && lifeFlash == e.player) setState(() => lifeFlash = null);
        });
      }
      if (e.kind == 'gameOver') interaction = const Idle();
    }
    _syncBlocking();
    setState(() {});
  }

  void _syncBlocking() {
    final p = state.pending;
    if (p != null && p.decision is DeclareBlockersDecision && p.player == me && interaction is! Blocking) {
      interaction = const Blocking(assignments: {});
    } else if (p == null && interaction is Blocking) {
      interaction = const Idle();
    }
  }

  // MARK: Actions

  void perform(GameAction a) => session!.perform(a);

  void tapHandCard(ObjectID id) {
    Console.shared.play(Fx.tap);
    if (interaction is PickingCards) {
      togglePick(id);
      return;
    }
    if (interaction is! Idle) return;
    if (AppStore.shared.tapToInspect || !canAct) {
      showCardSheet(id, handActions(id));
      return;
    }
    if (game.canPlayLand(id, me)) {
      perform(PlayLandAction(id));
      return;
    }
    final card = game.card(id);
    if (card == null) return;
    final parsed = game.db.parsed(card);
    var kickable = false;
    final k = parsed.kicker;
    if (k != null) {
      final c = card.cost..add(k);
      kickable = game.canPay(c, me);
    }
    if (game.canSacrificeKick(id, me)) kickable = true;
    final modal = parsed.spellEffects.any((e) => e is Modal);
    if (kickable || modal || canCycle(id) || zoneAbilities(id).isNotEmpty || !game.canCast(id, me)) {
      showCastMenu(id);
    } else {
      beginCast(id, kicked: false, mode: null);
    }
  }

  bool canCycle(ObjectID id) {
    if (!canAct) return false;
    final card = game.card(id);
    if (card == null) return false;
    final cyc = game.db.parsed(card).cycling;
    return cyc != null && game.canPay(cyc.cost, me);
  }

  void showCastMenu(ObjectID id) {
    final card = game.card(id);
    if (card == null) return;
    _showSheet(card.name, [...handActions(id), _sheetButton('Inspect', () => inspect(id), color: LCARS.lavender)]);
  }

  /// What can be done with a card in hand (or playable from exile, the library or a graveyard)
  /// right now, as buttons.
  List<Widget> handActions(ObjectID id) {
    final card = game.card(id);
    if (card == null || !canAct) return const [];
    final parsed = game.db.parsed(card);
    final items = <Widget>[];
    if (game.canPlayLand(id, me)) items.add(_sheetButton('Play this land', () => perform(PlayLandAction(id)), color: LCARS.green));
    if (game.canCast(id, me)) {
      final modal = parsed.spellEffects.whereType<Modal>().firstOrNull;
      if (modal != null) {
        for (var i = 0; i < modal.modes.length; i++) {
          items.add(_sheetButton('Cast: ${game.describeEffects(modal.modes[i])}', () => beginCast(id, kicked: false, mode: i)));
        }
      } else {
        items.add(_sheetButton(card.manaCost.isEmpty ? 'Cast' : 'Cast for ${card.manaCost}', () => beginCast(id, kicked: false, mode: null), color: LCARS.green));
      }
      final k = parsed.kicker;
      if (k != null) items.add(_sheetButton('Cast with kicker (+$k)', () => beginCast(id, kicked: true, mode: null)));
      final sk = parsed.abilities.whereType<SacrificeKicker>().firstOrNull;
      if (sk != null) {
        items.add(_sheetButton('Cast with kicker (sacrifice ${sk.filter.kind == FilterKind.artifactOrCreature ? 'an artifact or creature' : 'a permanent'})', () => beginCast(id, kicked: true, mode: null), enabled: game.canSacrificeKick(id, me)));
      }
    }
    final cyc = parsed.cycling;
    if (cyc != null && canCycle(id)) items.add(_sheetButton('${cyc.landType == null ? 'Cycling' : 'Landcycling'} ${cyc.cost}', () => perform(CycleAction(id))));
    for (final (i, a) in zoneAbilities(id)) {
      items.add(_sheetButton('${costText(a.cost)}: ${game.describeEffects(a.effects)}', () => beginActivate(id, i, a.cost, a.effects), color: LCARS.blue));
    }
    return items;
  }

  Widget _sheetButton(String label, VoidCallback onTap, {Color color = LCARS.orange, bool enabled = true}) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: LcarsButton(
      label,
      color: color,
      height: 48,
      onPressed: enabled
          ? () {
              Navigator.pop(context);
              onTap();
            }
          : null,
    ),
  );

  /// Pick between `min` and `max` items: card faces (returned as object ids) or text labels
  /// (returned as indices).
  void showPickSheet(String title, {List<ObjectID> cards = const [], List<String> labels = const [], required int min, required int max, required void Function(List<int>) onDone}) {
    final chosen = <int>{};
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: LCARS.panel,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) {
          final n = cards.isNotEmpty ? cards.length : labels.length;
          void toggle(int i) => setSheet(() {
            if (!chosen.remove(i)) {
              if (max == 1) chosen.clear();
              if (chosen.length < max) chosen.add(i);
            }
          });
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LcarsHeader(title, color: LCARS.gold),
                  const SizedBox(height: 6),
                  if (cards.isNotEmpty)
                    SizedBox(
                      height: 200,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (var i = 0; i < n; i++)
                            GestureDetector(
                              onTap: () => toggle(i),
                              onLongPress: () => inspect(cards[i]),
                              child: Container(
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: chosen.contains(i) ? LCARS.gold : Colors.transparent, width: 3),
                                ),
                                child: CardFace(card: game.card(cards[i]), width: 130),
                              ),
                            ),
                        ],
                      ),
                    )
                  else
                    for (var i = 0; i < n; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: LcarsButton(labels[i], color: LCARS.lavender, fill: chosen.contains(i), height: 46, onPressed: () => toggle(i)),
                      ),
                  const SizedBox(height: 8),
                  Text(min == 0 ? 'Choose up to $max (or none)' : (min == max ? 'Choose $min' : 'Choose $min to $max'), style: LCARS.small.copyWith(color: LCARS.gray)),
                  const SizedBox(height: 6),
                  LcarsButton(
                    'Done',
                    color: LCARS.gold,
                    height: 38,
                    onPressed: chosen.length >= min && chosen.length <= max
                        ? () {
                            Navigator.pop(sheetContext);
                            final picks = chosen.toList()..sort();
                            onDone(cards.isNotEmpty ? [for (final i in picks) cards[i]] : picks);
                          }
                        : null,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSheet(String title, List<Widget> items) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: LCARS.panel,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [LcarsHeader(title), const SizedBox(height: 8), ...items]),
        ),
      ),
    );
  }

  void beginCast(ObjectID id, {required bool kicked, int? mode, int? x}) {
    final card = game.card(id);
    if (card == null) return;
    if (card.cost.hasX && x == null) {
      final most = game.maxX(id, me);
      final labels = [for (var i = 0; i <= most; i++) 'X = $i'];
      showPickSheet('${card.name}: choose X', labels: labels, min: 1, max: 1, onDone: (picks) {
        if (picks.isNotEmpty) beginCast(id, kicked: kicked, mode: mode, x: picks.first);
      });
      return;
    }
    final reqs = game.targetRequirementsForCard(card, mode, kicked: kicked).where((r) => game.legalTargets(r.filter, me, id).isNotEmpty).toList();
    if (reqs.isEmpty) {
      perform(CastAction(id, kicked: kicked, mode: mode, x: x ?? 0));
    } else {
      setState(() {
        selectedHandCard = id;
        interaction = Targeting(
          requirements: reqs,
          chosen: const [],
          purpose: CastPurpose(id, kicked: kicked, mode: mode, x: x ?? 0),
        );
      });
    }
  }

  void tapPermanent(ObjectID id) {
    Console.shared.play(Fx.tap);
    final obj = state.objects[id];
    if (obj == null) return;
    final i = interaction;
    switch (i) {
      case Targeting t:
        final req = t.requirements.firstOrNull;
        if (req == null || !game.legalTargets(req.filter, me, null).contains(id) || t.chosen.contains(id)) return;
        final chosen = [...t.chosen, id];
        if (t.inCurrent + 1 >= req.count) {
          nextTargetRequirement(t, chosen);
        } else {
          setState(() => interaction = Targeting(requirements: t.requirements, chosen: chosen, purpose: t.purpose, inCurrent: t.inCurrent + 1));
        }
      case Attacking a:
        if (obj.controller != me || !game.canAttack(id)) return;
        final set = Set<ObjectID>.of(a.selected);
        if (!set.remove(id)) set.add(id);
        setState(() => interaction = Attacking(set));
      case Blocking b:
        final assignments = Map<ObjectID, ObjectID>.of(b.assignments);
        if (obj.controller == me) {
          if (assignments.containsKey(id)) {
            assignments.remove(id);
            setState(() => interaction = Blocking(assignments: assignments));
          } else if (game.characteristics(id).isCreature && !obj.tapped) {
            setState(() => interaction = Blocking(assignments: assignments, blocker: id));
          }
        } else if (b.blocker != null && state.combat.attackers.contains(id) && game.canBlock(b.blocker!, id)) {
          assignments[b.blocker!] = id;
          setState(() => interaction = Blocking(assignments: assignments));
        }
      case Stationing s:
        if (obj.controller != me) return;
        perform(StationAction(s.ship, id));
        setState(() => interaction = const Idle());
      case Equipping e:
        if (obj.controller != me) return;
        perform(EquipAction(e.equipment, id));
        setState(() => interaction = const Idle());
      case BeamingUp bu:
        if (obj.controller != me || !game.characteristics(id).isCreature) return;
        perform(CastAction(bu.card, beamUpBounce: id));
        setState(() => interaction = const Idle());
      case DecisionTargets d:
        final decision = state.pending?.decision;
        if (decision is ChooseTargetsDecision && decision.candidates.contains(id)) {
          final chosen = List<ObjectID>.of(d.chosen);
          if (!chosen.remove(id)) chosen.add(id);
          if (chosen.length >= decision.count) {
            perform(RespondAction(TargetsResponse(chosen)));
            setState(() => interaction = const Idle());
          } else {
            setState(() => interaction = DecisionTargets(chosen));
          }
        } else if (decision is ChooseSacrificeDecision && decision.candidates.contains(id)) {
          perform(RespondAction(SacrificeResponse(id)));
          setState(() => interaction = const Idle());
        }
      case PickingCards _:
        break;
      case Idle _:
        final mine = obj.controller == me && canAct;
        if (AppStore.shared.tapToInspect || !mine) {
          showCardSheet(id, mine ? permanentActions(id) : const []);
        } else {
          showPermanentMenu(id);
        }
    }
  }

  void showPermanentMenu(ObjectID id) => _showSheet(game.name(id), [...permanentActions(id), _sheetButton('Inspect', () => inspect(id), color: LCARS.lavender)]);

  /// What can be done with one of your permanents right now, as buttons.
  List<Widget> permanentActions(ObjectID id) {
    final obj = state.objects[id];
    final parsed = obj == null ? null : game.parsedOf(obj);
    if (obj == null || parsed == null) return const [];
    final c = game.characteristics(id);
    final items = <Widget>[];
    final all = game.abilitiesIn(obj);
    for (var i = 0; i < all.length; i++) {
      final a = all[i];
      if (a is! Activated) continue;
      if (a.effects.length == 1 && a.effects[0] is AddMana) continue;
      final cost = a.cost;
      final usable = game.activationProblem(id, i, me) == null;
      items.add(_sheetButton('${costText(cost)}: ${game.describeEffects(a.effects)}', () => beginActivate(id, i, cost, a.effects), enabled: usable));
    }
    if (c.isSpacecraft && parsed.has(KeywordKind.station) && state.phase.isMain) {
      items.add(_sheetButton('Station (tap a creature)', () => setState(() => interaction = Stationing(id)), color: LCARS.blue));
    }
    final equip = parsed.equipCost;
    if (equip != null && state.phase.isMain) {
      items.add(_sheetButton('Equip $equip', () => setState(() => interaction = Equipping(id)), color: LCARS.gold, enabled: game.canPay(equip, me)));
    }
    if ((state.phase == Phase.main1 || state.phase == Phase.beginCombat || state.phase == Phase.declareAttackers) && game.canAttack(id)) {
      items.add(_sheetButton('Attack with this', () => setState(() => interaction = Attacking({id})), color: LCARS.alert));
    }
    return items;
  }

  String costText(ActivationCost cost) {
    final parts = <String>[];
    if (!cost.mana.isFree) parts.add(cost.mana.toString());
    if (cost.tap) parts.add('Tap');
    if (cost.sacrificeSelf) parts.add('Sacrifice');
    if (cost.sacrifice != null) parts.add('Sacrifice a permanent');
    if (cost.payLife > 0) parts.add('Pay ${cost.payLife} life');
    if (cost.discard > 0) parts.add('Discard');
    if (cost.tapOthers > 0) parts.add('Tap ${cost.tapOthers} untapped ${cost.tapOthersFilter?.subtype != null ? '${cost.tapOthersFilter!.subtype}s' : 'artifacts/creatures'}');
    if (cost.removeCounters > 0) parts.add('Remove ${cost.removeCounters} counters');
    switch (cost.zone) {
      case AbilityZone.battlefield:
        break;
      case AbilityZone.hand:
        parts.add('Discard this');
      case AbilityZone.graveyard:
        parts.add(cost.exileSelf ? 'Exile this from graveyard' : 'Put this on the bottom of your library');
    }
    return parts.isEmpty ? 'Free' : parts.join(', ');
  }

  ObjectID? _cheapestMatching(Filter f, ObjectID source) {
    final candidates = state.permanentsOf(me).where((o) => game.matches(f, o.id, me, source)).map((o) => o.id).toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => Bot.value(a, game) - Bot.value(b, game));
    return candidates.first;
  }

  void beginActivate(ObjectID id, int index, ActivationCost cost, List<Effect> effects) {
    ObjectID? sacrifice;
    final f = cost.sacrifice;
    if (f != null) {
      sacrifice = _cheapestMatching(f, id);
      if (sacrifice == null) {
        setState(() => session!.lastError = 'Nothing to sacrifice');
        return;
      }
    }
    final discard = cost.discard > 0 ? state.players[me].hand.firstOrNull : null;
    final reqs = game.targetRequirementsIn(effects).where((r) => game.legalTargets(r.filter, me, id).isNotEmpty).toList();
    if (reqs.isEmpty) {
      perform(ActivateAbilityAction(id, index, sacrifice: sacrifice, discard: discard));
    } else {
      setState(() => interaction = Targeting(requirements: reqs, chosen: const [], purpose: ActivatePurpose(id, index)));
    }
  }

  void finishTargeting() {
    final t = interaction;
    if (t is! Targeting) return;
    switch (t.purpose) {
      case CastPurpose p:
        perform(CastAction(p.card, targets: t.chosen, kicked: p.kicked, mode: p.mode, x: p.x));
      case ActivatePurpose p:
        ObjectID? sacrifice;
        final obj = state.objects[p.object];
        final a = obj == null ? null : game.abilitiesIn(obj).elementAtOrNull(p.index);
        if (a is Activated && a.cost.sacrifice != null) sacrifice = _cheapestMatching(a.cost.sacrifice!, p.object);
        perform(ActivateAbilityAction(p.object, p.index, targets: t.chosen, sacrifice: sacrifice));
    }
    setState(() {
      interaction = const Idle();
      selectedHandCard = null;
    });
  }

  void chooseTargetPlayer(PlayerID p) {
    final t = interaction;
    if (t is! Targeting) return;
    nextTargetRequirement(t, [...t.chosen, EffectContext.playerObject(p)]);
  }

  /// The current requirement is filled (or the player is done with it): on to the next, or cast.
  void nextTargetRequirement(Targeting t, List<ObjectID> chosen) {
    final rest = t.requirements.sublist(1);
    if (rest.isEmpty) {
      interaction = Targeting(requirements: t.requirements, chosen: chosen, purpose: t.purpose);
      finishTargeting();
    } else {
      setState(() => interaction = Targeting(requirements: rest, chosen: chosen, purpose: t.purpose));
    }
  }

  void togglePick(ObjectID id) {
    final chosen = interaction is PickingCards ? List<ObjectID>.of((interaction as PickingCards).chosen) : <ObjectID>[];
    if (!chosen.remove(id)) chosen.add(id);
    setState(() => interaction = PickingCards(chosen));
  }

  /// A card shown large with what you can do with it. Tapping a card opens this (unless turned
  /// off in Settings), so you always see what you are about to play.
  void showCardSheet(ObjectID id, List<Widget> actions) {
    final obj = state.objects[id];
    if (obj == null) return;
    final card = game.card(id) ?? (obj.token == null ? null : game.db.tokenCard(obj.token!.name, power: obj.token!.power, toughness: obj.token!.toughness));
    final c = game.characteristics(id);
    final screen = MediaQuery.sizeOf(context);
    final width = (screen.width - 48).clamp(200.0, 340.0);
    final facts = <String>[];
    if (obj.zone == Zone.battlefield) {
      if (c.isCreature) facts.add('${c.power}/${c.toughness}${obj.damage > 0 ? ', ${obj.damage} damage' : ''}');
      if (c.isLand) {
        final colors = game.parsedOf(obj)?.manaColors ?? const <ManaColor>[];
        final mana = colors.isEmpty ? 'colorless' : colors.map((m) => m.label.toLowerCase()).join(' or ');
        facts.add(obj.tapped ? 'tapped: used this turn' : 'ready: taps for $mana mana');
      } else if (obj.tapped) {
        facts.add('tapped');
      }
      if (obj.attacking != null) facts.add('attacking');
      if (obj.blocking != null) facts.add('blocking');
      if (obj.counters.isNotEmpty) facts.add(obj.counters.entries.map((e) => '${e.value} ${e.key.text}').join(', '));
      final kw = (c.keywords.map((k) => k.toString()).toList()..sort());
      if (kw.isNotEmpty) facts.add(kw.join(', '));
      if (obj.controller != me) facts.add('${state.players[obj.controller].name} controls this');
    } else if (obj.zone != Zone.hand) {
      facts.add(zoneLabel(id).toLowerCase());
    }
    final why = actions.isEmpty ? whyNotPlayable(id) : null;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LCARS.panel,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.92,
        maxChildSize: 0.95,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
          children: [
            Center(
              child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 10), decoration: BoxDecoration(color: LCARS.gray, borderRadius: BorderRadius.circular(2))),
            ),
            Center(
              child: GestureDetector(
                onTap: () => Navigator.pop(sheetContext),
                child: CardFace(card: card, token: obj.token, width: width),
              ),
            ),
            if (facts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(facts.join(' · '), style: LCARS.font(15, color: LCARS.gold), textAlign: TextAlign.center),
              ),
            const SizedBox(height: 14),
            ...actions,
            if (why != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(why, style: LCARS.body.copyWith(color: LCARS.skyBlue), textAlign: TextAlign.center),
              ),
            Row(
              children: [
                Expanded(
                  child: LcarsButton('Rules & details', color: LCARS.lavender, fill: false, height: 44, onPressed: () {
                    Navigator.pop(sheetContext);
                    inspect(id);
                  }),
                ),
                const SizedBox(width: 8),
                Expanded(child: LcarsButton('Close', color: LCARS.gray, fill: false, height: 44, onPressed: () => Navigator.pop(sheetContext))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Why a card shown in the large view has nothing to do, in plain words.
  String? whyNotPlayable(ObjectID id) {
    final obj = state.objects[id];
    final card = game.card(id);
    if (obj == null || card == null) return null;
    if (obj.zone == Zone.battlefield) {
      if (obj.controller != me) return null;
      if (!canAct) return 'You can use its abilities when it is your move.';
      return null;
    }
    if (obj.zone != Zone.hand) return null;
    if (state.isOver) return null;
    if (!canAct) {
      return state.pending != null && state.pending!.player == me ? 'Answer the question in the middle bar first.' : "It's ${state.players[them].name}'s move. You can play cards when it's yours.";
    }
    final instantSpeed = card.isInstant || game.db.parsed(card).has(KeywordKind.flash);
    final myMain = state.activePlayer == me && state.phase.isMain && state.stack.isEmpty && state.priority == null;
    if (card.isLand) {
      if (!myMain) return 'Lands are played in your main phase.';
      return 'You have already played a land this turn (one per turn).';
    }
    if (!instantSpeed && !myMain) return '${card.isCreature ? 'Creatures' : 'This card'} can be cast only in your main phase, when nothing else is happening.';
    final ready = state.permanentsOf(me).where((o) => game.characteristics(o.id).isLand && !o.tapped).length;
    if (!game.canPay(card.cost, me)) return 'Not enough mana: it costs ${card.manaCost.replaceAll(RegExp(r'[{}]'), '')} and you have $ready untapped land${ready == 1 ? '' : 's'}.';
    final parsed = game.db.parsed(card);
    if (parsed.isAura || game.targetRequirementsForCard(card, null).isNotEmpty) return 'There is nothing it can target right now.';
    return null;
  }

  void inspect(ObjectID id) {
    final obj = state.objects[id];
    if (obj == null) return;
    final card = obj.cardID.isEmpty ? null : game.db[obj.cardID];
    final c = game.characteristics(id);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LCARS.panel,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        builder: (_, controller) => SingleChildScrollView(
          controller: controller,
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              if (card != null) CardDetailBody(card: card, db: game.db) else TokenFace(token: obj.token, width: 240),
              if (obj.zone == Zone.battlefield)
                LcarsPanel(
                  title: 'On the battlefield',
                  color: LCARS.gold,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (c.isCreature) Text('${c.power}/${c.toughness}, ${obj.damage} damage marked', style: LCARS.body),
                      if (c.keywords.isNotEmpty) Text((c.keywords.map((k) => k.toString()).toList()..sort()).join(', '), style: LCARS.label.copyWith(color: LCARS.lavender)),
                      if (obj.counters.isNotEmpty) Text('${obj.counters.entries.map((e) => '${e.value} ${e.key.text}').join(', ')} counters', style: LCARS.label.copyWith(color: LCARS.blue)),
                      if (obj.tapped) Text('Tapped', style: LCARS.label.copyWith(color: LCARS.gray)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void showGraveyard(PlayerID p) {
    final ids = state.players[p].graveyard;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: LCARS.panel,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, controller) => Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              LcarsHeader("${state.players[p].name}'s graveyard", color: LCARS.violet),
              Expanded(
                child: ids.isEmpty
                    ? Center(
                        child: Text('Empty', style: LCARS.body.copyWith(color: LCARS.gray)),
                      )
                    : GridView.builder(
                        controller: controller,
                        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 100, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1 / (cardAspect + 0.4)),
                        itemCount: ids.length,
                        itemBuilder: (_, i) {
                          final id = ids[i];
                          final card = game.card(id);
                          final beam = card == null ? null : game.db.parsed(card).beamMeUp;
                          final canBeam = p == me && beam != null && state.activePlayer == me && state.phase.isMain && game.canPay(beam, me) && state.pending == null;
                          // While a spell or ability is choosing targets, a card here that is a
                          // legal target is picked by tapping it, like a permanent on the table.
                          final targetable = (interaction is Targeting || interaction is DecisionTargets) && isCandidate(id);
                          return Column(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (_, box) => GestureDetector(
                                    onTap: () {
                                      if (!targetable) return inspect(id);
                                      Navigator.pop(context);
                                      tapPermanent(id);
                                    },
                                    onLongPress: () => inspect(id),
                                    child: Container(
                                      decoration: targetable
                                          ? BoxDecoration(
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(color: LCARS.gold, width: 3),
                                            )
                                          : null,
                                      child: CardFace(card: card, width: box.maxWidth),
                                    ),
                                  ),
                                ),
                              ),
                              if (targetable) Text('TAP TO TARGET', style: LCARS.font(9, color: LCARS.gold)),
                              if (canBeam)
                                LcarsButton(
                                  'Beam up $beam',
                                  height: 26,
                                  color: LCARS.blue,
                                  onPressed: () {
                                    Navigator.pop(context);
                                    setState(() => interaction = BeamingUp(id));
                                  },
                                ),
                              if (p == me && interaction is Idle)
                                for (final (index, a) in zoneAbilities(id))
                                  LcarsButton(
                                    costText(a.cost).replaceAll(', Exile this from graveyard', '').replaceAll(', Put this on the bottom of your library', ''),
                                    height: 26,
                                    color: LCARS.blue,
                                    onPressed: () {
                                      Navigator.pop(context);
                                      beginActivate(id, index, a.cost, a.effects);
                                    },
                                  ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showLog() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: LCARS.panel,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) {
          final lines = <(String, Color)>[];
          for (final e in state.log) {
            final t = EventText.describe(e, game);
            if (t != null) lines.add((t, EventText.color(e)));
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                const LcarsHeader("Captain's log", color: LCARS.lavender),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    reverse: true,
                    itemCount: lines.length,
                    itemBuilder: (_, i) {
                      final (t, c) = lines[lines.length - 1 - i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          t,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> confirmConcede() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Concede the game?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Concede')),
        ],
      ),
    );
    if (ok == true) session!.concede();
  }

  // MARK: Highlights

  bool isCandidate(ObjectID id) {
    final obj = state.objects[id];
    switch (interaction) {
      case Targeting t:
        final r = t.requirements.firstOrNull;
        return r != null && !t.chosen.contains(id) && game.legalTargets(r.filter, me, null).contains(id);
      case Attacking _:
        return obj?.controller == me && game.canAttack(id);
      case Blocking b:
        if (b.blocker != null) return state.combat.attackers.contains(id) && game.canBlock(b.blocker!, id);
        return obj?.controller == me && game.characteristics(id).isCreature && obj?.tapped == false;
      case Stationing s:
        return obj?.controller == me && id != s.ship && game.characteristics(id).isCreature && obj?.tapped == false;
      case Equipping _:
      case BeamingUp _:
        return obj?.controller == me && game.characteristics(id).isCreature;
      case DecisionTargets _:
        final d = state.pending?.decision;
        if (d is ChooseTargetsDecision) return d.candidates.contains(id);
        if (d is ChooseSacrificeDecision) return d.candidates.contains(id);
        return false;
      default:
        return false;
    }
  }

  bool isSelected(ObjectID id) {
    switch (interaction) {
      case Targeting t:
        return t.chosen.contains(id);
      case Attacking a:
        return a.selected.contains(id);
      case Blocking b:
        return b.assignments.containsKey(id) || b.blocker == id;
      case DecisionTargets d:
        return d.chosen.contains(id);
      default:
        return false;
    }
  }

  bool isDimmed(ObjectID id) => interaction is! Idle && interaction is! PickingCards && !isCandidate(id) && !isSelected(id);

  bool playable(ObjectID id) => interaction is Idle && (game.canPlayLand(id, me) || game.canCast(id, me) || canCycle(id) || zoneAbilities(id).isNotEmpty);

  // MARK: Build

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const Scaffold(body: Center(child: Text('No game')));
    final step = tourStep;
    return Stack(
      children: [
        table(),
        if (step != null) Positioned.fill(child: TourOverlay(steps: tourSteps, index: step, onNext: () => setState(() => tourStep = step + 1), onClose: closeTour)),
      ],
    );
  }

  Widget table() {
    return Scaffold(
      backgroundColor: LCARS.black,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.chevron_left), onPressed: leave),
        title: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text((state.turn == 0 ? 'Opening hand' : 'Turn ${state.turn} · ${state.phase.label}').toUpperCase(), style: LCARS.font(14, color: LCARS.peach))),
        actions: [
          IconButton(
            key: _tourHelp,
            tooltip: 'Help',
            icon: const Icon(Icons.help_outline, color: LCARS.skyBlue),
            onPressed: showHelp,
          ),
          IconButton(
            tooltip: "Captain's log",
            icon: const Icon(Icons.list_alt, color: LCARS.lavender),
            onPressed: showLog,
          ),
          IconButton(
            tooltip: 'Concede',
            icon: const Icon(Icons.flag, color: LCARS.red),
            onPressed: confirmConcede,
          ),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    key: _tourOpponent,
                    children: [
                      playerStrip(them, top: true),
                      Expanded(child: battlefield(them, top: true)),
                    ],
                  ),
                ),
                controlBar(),
                Expanded(flex: 5, child: KeyedSubtree(key: _tourMine, child: battlefield(me, top: false))),
                KeyedSubtree(key: _tourStrip, child: playerStrip(me, top: false)),
                KeyedSubtree(key: _tourHand, child: hand()),
              ],
            ),
            if (state.isOver) Positioned.fill(child: gameOverOverlay()),
          ],
        ),
      ),
    );
  }

  Widget playerStrip(PlayerID p, {required bool top}) {
    final ps = state.players[p];
    final active = state.activePlayer == p;
    final life = ps.life;
    Widget stat(String label, String value, Color color, {VoidCallback? onTap}) => GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value, style: LCARS.font(17, color: color)),
            Text(label, style: LCARS.font(9, color: onTap != null ? LCARS.lavender : LCARS.gray)),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 6, 2),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 30,
            decoration: BoxDecoration(color: active ? LCARS.orange : LCARS.gray.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(ps.name.toUpperCase(), style: LCARS.font(15, color: active ? LCARS.orange : LCARS.peach), maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(active ? (top ? 'their turn' : 'your turn') : (top ? 'opponent' : (session!.mode == SessionMode.hotseat ? 'your seat' : 'you')), style: LCARS.small.copyWith(color: active ? LCARS.orange : LCARS.gray)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(color: (lifeFlash == p ? LCARS.alert : (life <= 5 ? LCARS.red : LCARS.peach)).withValues(alpha: 0.18), borderRadius: BorderRadius.circular(12)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$life', style: LCARS.font(22, color: lifeFlash == p ? LCARS.alert : (life <= 5 ? LCARS.red : LCARS.peach))),
                const SizedBox(width: 4),
                Text('LIFE', style: LCARS.font(9, color: LCARS.gray)),
              ],
            ),
          ),
          stat('HAND', '${ps.hand.length}', LCARS.blue),
          stat('DECK', '${ps.library.length}', LCARS.lavender),
          stat('GRAVE', '${ps.graveyard.length}', LCARS.violet, onTap: () => showGraveyard(p)),
        ],
      ),
    );
  }

  /// Lands that are only lands (not animated into creatures): shown as labels, not cards.
  bool _plainLand(GameObject o) {
    final c = game.characteristics(o.id);
    return c.isLand && !c.isCreature && o.attachedTo == null;
  }

  Widget battlefield(PlayerID p, {required bool top}) {
    final perms = state.permanentsOf(p);
    final lands = perms.where(_plainLand).toList();
    final others = perms.where((o) => !_plainLand(o)).toList();
    // Lands grouped by name: "3× Plains · 2 ready".
    final groups = <String, List<GameObject>>{};
    for (final o in lands) {
      groups.putIfAbsent(game.name(o.id), () => []).add(o);
    }
    Widget landRow() => SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
        children: [
          if (groups.isEmpty)
            Center(
              child: Text('no lands yet', style: LCARS.small.copyWith(color: LCARS.gray)),
            ),
          for (final e in groups.entries) landChip(e.key, e.value),
        ],
      ),
    );
    Widget mainRow() => Expanded(
      child: LayoutBuilder(
        builder: (_, box) {
          if (others.isEmpty) {
            return Center(
              child: Text(top ? 'No creatures or other cards in play' : 'Your creatures and other cards appear here', style: LCARS.small.copyWith(color: LCARS.gray)),
            );
          }
          // Cards as tall as the space allows, so the art and stats can be read.
          final h = (box.maxHeight - 12).clamp(56.0, 240.0);
          final w = h / cardAspect;
          return ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            children: [
              for (final o in others)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    child: PermanentView(
                      key: ValueKey('perm-${o.id}'),
                      session: session!,
                      objectID: o.id,
                      width: w,
                      highlighted: isCandidate(o.id),
                      selected: isSelected(o.id),
                      dimmed: isDimmed(o.id),
                      onTap: () => tapPermanent(o.id),
                      onLongPress: () => inspect(o.id),
                      tag: blockTag(o.id),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: LCARS.panel.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(10)),
      child: Column(children: top ? [landRow(), mainRow()] : [mainRow(), landRow()]),
    );
  }

  /// A group of same-named lands as one label. Tapping it acts on one of them: the one a
  /// spell can target, else an untapped one.
  Widget landChip(String name, List<GameObject> group) {
    final ready = group.where((o) => !o.tapped).length;
    final colors = game.parsedOf(group.first)?.manaColors ?? const <ManaColor>[];
    final color = colors.isEmpty ? LCARS.gray : LCARS.forMana(colors.first.symbol);
    final candidate = group.where((o) => isCandidate(o.id)).firstOrNull;
    final chosen = group.any((o) => isSelected(o.id));
    final target = candidate ?? group.where((o) => !o.tapped).firstOrNull ?? group.first;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        key: ValueKey('land-$name'),
        onTap: () => tapPermanent(target.id),
        onLongPress: () => inspect(target.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: candidate != null || chosen ? LCARS.gold : color.withValues(alpha: 0.8), width: candidate != null || chosen ? 3 : 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text('${group.length > 1 ? '${group.length}× ' : ''}$name', style: LCARS.font(13, color: LCARS.peach)),
              const SizedBox(width: 6),
              Text(ready == group.length ? (ready == 1 ? 'ready' : 'all ready') : '$ready ready', style: LCARS.font(11, color: ready > 0 ? LCARS.green : LCARS.gray)),
            ],
          ),
        ),
      ),
    );
  }

  String? blockTag(ObjectID id) {
    final i = interaction;
    if (i is Blocking && i.assignments.containsKey(id)) return '→${game.name(i.assignments[id]!).split(' ').first}';
    return null;
  }

  Widget controlBar() {
    final s = session!;
    final hint = AppStore.shared.coachOn ? coachHint() : null;
    final text = s.lastError ?? hint ?? (s.match?.status ?? '');
    return Container(
      key: _tourBar,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (text.isNotEmpty || s.thinking)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(s.lastError != null ? Icons.error_outline : (hint != null ? Icons.lightbulb_outline : Icons.circle), size: 16, color: s.lastError != null ? LCARS.alert : (hint != null ? LCARS.gold : (myTurn ? LCARS.orange : LCARS.skyBlue))),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      text,
                      style: LCARS.font(13, weight: FontWeight.w500, color: s.lastError != null ? LCARS.alert : (hint != null ? LCARS.ice : LCARS.gray)),
                      maxLines: 3,
                    ),
                  ),
                  if (s.thinking) const ScanLine(color: LCARS.blue, width: 60),
                ],
              ),
            ),
          stackStrip(),
          promptBar(),
        ],
      ),
    );
  }

  /// For new players: what is happening and what they can do now, in a sentence or two.
  String? coachHint() {
    if (state.isOver) return null;
    final i = interaction;
    switch (i) {
      case Targeting _:
        return 'Tap a card with a gold glow to target it (or a player button). Cancel to back out.';
      case Attacking _:
        return 'Tap each creature you want to attack with, then Attack! Creatures that came in this turn must wait (unless they have haste).';
      case Blocking b:
        return b.blocker == null
            ? 'You are being attacked. To block, tap one of your untapped creatures, then the attacker it should stop. Unblocked attackers hit you.'
            : 'Now tap the attacking creature that ${game.name(b.blocker!)} should block.';
      case PickingCards _:
        return 'Tap cards in your hand to choose them, then Done.';
      case DecisionTargets _:
        return 'Tap one of the glowing cards to choose it.';
      case Stationing _:
        return 'Tap one of your untapped creatures: it taps and adds charge counters equal to its power to the ship.';
      case Equipping _:
        return 'Tap the creature to attach the equipment to.';
      case BeamingUp _:
        return 'Tap a creature you control: it returns to your hand as part of the cost.';
      case Idle _:
        break;
    }
    final pending = state.pending;
    if (pending != null) {
      if (pending.player != me) return '${state.players[pending.player].name} is deciding something.';
      return switch (pending.decision) {
        MulliganDecision _ => 'This is your opening hand. Keep it, or Mulligan to shuffle it away and draw a new one. Tip: keep a hand with 2 to 4 lands.',
        DeclareBlockersDecision _ => 'You are being attacked! Tap Declare blockers to choose which of your creatures block, or block nothing and take the damage.',
        PayOrCounterDecision _ => 'Pay the extra mana to keep your spell, or let it be countered.',
        ChooseBottomDecision _ => 'Pick the cards from your hand to put on the bottom of your library.',
        DiscardToHandSizeDecision _ => 'Too many cards in hand at the end of your turn: pick which to discard.',
        _ => 'A card is asking you something: answer it with the buttons below.',
      };
    }
    if (state.priority == me) {
      return state.stack.isEmpty
          ? 'You may cast an instant now (glowing cards in your hand), or Pass to continue.'
          : '${state.players[state.stack.last.controller].name} is casting ${game.name(state.stack.last.id)}. Respond with a glowing instant, or let it resolve.';
    }
    if (state.playerToAct != me) return "${state.players[them].name}'s move. Their actions appear on the table and in the log (top right).";
    final hand = state.players[me].hand;
    final canLand = hand.any((id) => game.canPlayLand(id, me));
    final castable = [...hand, ...game.extraPlayables(me)].where((id) => game.canCast(id, me)).length;
    final attackers = state.permanentsOf(me).where((o) => game.canAttack(o.id)).length;
    switch (state.phase) {
      case Phase.main1:
        if (canLand) return 'Your turn. Start by playing a land: tap a land in your hand, then Play this land. One land per turn.';
        if (castable > 0) return 'Cards with a blue glow can be played now. Tap one to see it, then Cast. Your lands pay the mana automatically.';
        if (attackers > 0) return 'Ready for combat: tap Attack and choose creatures, or End turn.';
        return 'Nothing more to play. Tap End turn to pass to ${state.players[them].name}.';
      case Phase.main2:
        if (canLand) return 'Combat is over. You can still play a land.';
        if (castable > 0) return 'Combat is over. You can still cast glowing cards, then End turn.';
        return 'Tap End turn to pass to ${state.players[them].name}.';
      case Phase.beginCombat:
      case Phase.declareAttackers:
        return 'Combat: tap Attack to choose attackers, or No attack.';
      default:
        return null;
    }
  }

  /// Explains the table and the turn, with shortcuts to the tour and the full rules.
  void showHelp() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: LCARS.panel,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, controller) => ListenableBuilder(
          listenable: AppStore.shared,
          builder: (context, _) => ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              const LcarsHeader('Help', color: LCARS.skyBlue),
              Text('Right now: ${state.phase.label}', style: LCARS.font(15, color: LCARS.gold)),
              const SizedBox(height: 6),
              Text(coachHint() ?? 'Follow the buttons in the middle bar.', style: LCARS.body),
              const SizedBox(height: 12),
              for (final (title, text) in _helpLines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: LcarsPanel(title: title, color: LCARS.lavender, child: Text(text, style: const TextStyle(fontSize: 15, color: LCARS.peach))),
                ),
              const SizedBox(height: 6),
              LcarsButton('Show me around the table', icon: Icons.tour, color: LCARS.gold, height: 48, onPressed: () {
                Navigator.pop(sheetContext);
                setState(() => tourStep = 0);
              }),
              const SizedBox(height: 8),
              LcarsButton('Full rules: How to Play', icon: Icons.menu_book, color: LCARS.skyBlue, height: 48, onPressed: () {
                Navigator.pop(sheetContext);
                Navigator.pushNamed(context, '/help');
              }),
              const SizedBox(height: 8),
              SwitchListTile(title: Text('Coach hints on the table', style: LCARS.body), value: AppStore.shared.coachOn, activeThumbColor: LCARS.orange, onChanged: (v) {
                AppStore.shared.setCoach(v);
                setState(() {});
              }, contentPadding: EdgeInsets.zero),
              SwitchListTile(title: Text('Tap a card to see it first', style: LCARS.body), value: AppStore.shared.tapToInspect, activeThumbColor: LCARS.orange, onChanged: AppStore.shared.setTapToInspect, contentPadding: EdgeInsets.zero),
            ],
          ),
        ),
      ),
    );
  }

  static const _helpLines = [
    ('Goal', 'Bring your opponent from 20 life to 0. Creatures that attack and are not blocked deal their power in damage.'),
    ('Your turn', 'You draw a card. Then: play one land, cast cards you can pay for, attack with your creatures, cast more if you like, and End turn.'),
    ('Mana', 'Each land taps for one mana of its color. The cost is in the card\'s top right corner: a number is any mana, a symbol needs that color. The game taps your lands for you.'),
    ('Creatures', 'A creature can attack the turn after it comes in (haste: right away). The numbers are power/toughness: damage dealt / damage it survives.'),
    ('Blocking', 'When attacked, your untapped creatures can block. Blocker and attacker deal damage to each other; the player takes none from a blocked attacker.'),
    ('Reading cards', 'Tap any card to see it large with what you can do. Glowing cards in your hand can be played now. Tap GRAVE to look in a graveyard.'),
  ];

  Widget _small(String label, VoidCallback? onTap, {Color color = LCARS.orange, bool fill = true, double width = 86}) => SizedBox(
    width: width,
    child: LcarsButton(label, height: 42, color: color, fill: fill, onPressed: onTap),
  );

  /// Buttons opening each graveyard that holds a legal target for the current choice; the
  /// cards there are not on the table, so this is how the player reaches them.
  List<Widget> graveyardTargetButtons(Iterable<ObjectID> candidates) {
    final out = <Widget>[];
    for (final p in state.players) {
      if (!candidates.any((id) => p.graveyard.contains(id))) continue;
      out.add(_small(p.id == me ? 'My grave' : "${p.name}'s grave", () => showGraveyard(p.id), color: LCARS.violet, width: 96));
      out.add(const SizedBox(width: 4));
    }
    return out;
  }

  Widget promptBar() {
    final i = interaction;
    switch (i) {
      case Targeting t:
        final req = t.requirements.firstOrNull;
        return Row(
          children: [
            Expanded(
              child: Text(targetPrompt(req, t.chosen), style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            if (req != null) ...graveyardTargetButtons(game.legalTargets(req.filter, me, null)),
            if (req != null && (req.filter.isPlayerFilter || req.filter.kind == FilterKind.creatureOrPlayer)) ...[
              if (req.filter.kind != FilterKind.opponent) _small('You', () => chooseTargetPlayer(me), color: LCARS.peach, fill: false, width: 60),
              const SizedBox(width: 4),
              _small(state.players[them].name, () => chooseTargetPlayer(them), color: LCARS.alert, width: 90),
            ],
            if (req != null && (req.optional || t.inCurrent > 0)) ...[const SizedBox(width: 4), _small(t.requirements.length > 1 ? 'Next' : 'Done', () => nextTargetRequirement(t, t.chosen), color: LCARS.gold, width: 64)],
            const SizedBox(width: 4),
            _small(
              'Cancel',
              () => setState(() {
                interaction = const Idle();
                selectedHandCard = null;
              }),
              color: LCARS.red,
              fill: false,
              width: 70,
            ),
          ],
        );
      case Attacking a:
        return Row(
          children: [
            Expanded(
              child: Text('Choose attackers (${a.selected.length})', style: LCARS.font(12, color: LCARS.gold)),
            ),
            _small(
              'All',
              () => setState(() => interaction = Attacking(state.permanentsOf(me).where((o) => game.canAttack(o.id)).map((o) => o.id).toSet())),
              color: LCARS.peach,
              fill: false,
              width: 54,
            ),
            const SizedBox(width: 4),
            _small(
              a.selected.isEmpty ? 'No attack' : 'Attack!',
              () {
                perform(DeclareAttackersAction(a.selected.toList()));
                setState(() => interaction = const Idle());
              },
              color: LCARS.alert,
              width: 90,
            ),
            const SizedBox(width: 4),
            _small('Cancel', () => setState(() => interaction = const Idle()), color: LCARS.red, fill: false, width: 70),
          ],
        );
      case Blocking b:
        return Row(
          children: [
            Expanded(
              child: Text(
                b.blocker == null ? 'Blocks: tap your creature, then the attacker' : 'Now tap the attacker ${game.name(b.blocker!)} blocks',
                style: LCARS.font(12, color: LCARS.gold),
                maxLines: 2,
              ),
            ),
            _small(
              b.assignments.isEmpty ? 'No blocks' : 'Confirm',
              () {
                perform(RespondAction(BlockersResponse(Map.of(b.assignments))));
                setState(() => interaction = const Idle());
              },
              color: LCARS.skyBlue,
              width: 90,
            ),
            const SizedBox(width: 4),
            _small('Clear', () => setState(() => interaction = const Blocking(assignments: {})), color: LCARS.red, fill: false, width: 62),
          ],
        );
      case Stationing _:
      case Equipping _:
      case BeamingUp _:
        final text = switch (i) {
          Stationing _ => 'Tap an untapped creature to station',
          Equipping _ => 'Tap a creature to equip',
          _ => 'Beam me up: tap a creature you control to return to hand',
        };
        return Row(
          children: [
            Expanded(
              child: Text(text, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Cancel', () => setState(() => interaction = const Idle()), color: LCARS.red, fill: false, width: 70),
          ],
        );
      case DecisionTargets d:
        final decision = state.pending?.decision;
        if (decision is ChooseTargetsDecision) {
          return Row(
            children: [
              Expanded(
                child: Text('${decision.prompt} (${d.chosen.length}/${decision.count})', style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
              ),
              ...graveyardTargetButtons(decision.candidates),
              if (decision.filter.isPlayerFilter || decision.filter.kind == FilterKind.creatureOrPlayer)
                for (final pid in decision.candidates.where((c) => EffectContext.playerFromObject(c) != null)) ...[
                  _small(
                    game.name(pid),
                    () {
                      perform(RespondAction(TargetsResponse([pid])));
                      setState(() => interaction = const Idle());
                    },
                    color: LCARS.peach,
                    width: 80,
                  ),
                  const SizedBox(width: 4),
                ],
              if (decision.optional || d.chosen.isNotEmpty)
                _small(
                  'Done',
                  () {
                    perform(RespondAction(TargetsResponse(d.chosen)));
                    setState(() => interaction = const Idle());
                  },
                  color: LCARS.gold,
                  width: 64,
                ),
            ],
          );
        }
        if (decision is ChooseSacrificeDecision) return Text(decision.prompt, style: LCARS.font(12, color: LCARS.gold));
        return const SizedBox.shrink();
      case PickingCards p:
        final decision = state.pending?.decision;
        final need = switch (decision) {
          DiscardToHandSizeDecision d => d.count,
          ChooseBottomDecision d => d.count,
          _ => 0,
        };
        final verb = decision is ChooseBottomDecision ? 'To the bottom' : 'Discard';
        return Row(
          children: [
            Expanded(
              child: Text('$verb: ${p.chosen.length}/$need chosen (tap cards in hand)', style: LCARS.font(12, color: LCARS.gold)),
            ),
            _small(
              'Done',
              p.chosen.length == need
                  ? () {
                      perform(RespondAction(CardsResponse(p.chosen)));
                      setState(() => interaction = const Idle());
                    }
                  : null,
              color: LCARS.gold,
              width: 64,
            ),
          ],
        );
      case Idle _:
        return idleButtons();
    }
  }

  Widget idleButtons() {
    final s = session!;
    if (state.isOver) return const SizedBox.shrink();
    final pending = state.pending;
    if (pending != null && pending.player == me) return decisionButtons(pending);
    if (pending == null && state.priority == me) return priorityButtons();
    if (pending != null || state.playerToAct != me) {
      return Row(
        children: [
          Expanded(
            child: Text(s.isLinked ? 'Waiting for ${state.players[state.playerToAct ?? them].name}…' : '${state.players[them].name} is thinking…', style: LCARS.font(12, color: LCARS.skyBlue)),
          ),
        ],
      );
    }
    final canAttackAny = state.permanentsOf(me).any((o) => game.canAttack(o.id));
    switch (state.phase) {
      case Phase.main1:
        return Row(
          children: [
            Expanded(
              child: LcarsButton('Attack', color: LCARS.alert, height: 46, onPressed: canAttackAny ? () => setState(() => interaction = const Attacking({})) : null),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: LcarsButton('Skip combat', color: LCARS.peach, fill: false, height: 46, onPressed: () => perform(const DeclareAttackersAction([]))),
            ),
            const SizedBox(width: 4),
            Expanded(child: LcarsButton('End turn', height: 46, onPressed: () => perform(const EndTurnAction()))),
          ],
        );
      case Phase.declareAttackers:
      case Phase.beginCombat:
        return Row(
          children: [
            Expanded(
              child: LcarsButton('Attack', color: LCARS.alert, height: 46, onPressed: () => setState(() => interaction = const Attacking({}))),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: LcarsButton('No attack', color: LCARS.peach, fill: false, height: 46, onPressed: () => perform(const DeclareAttackersAction([]))),
            ),
          ],
        );
      case Phase.main2:
        return LcarsButton('End turn', height: 46, onPressed: () => perform(const EndTurnAction()));
      default:
        return LcarsButton('Continue', height: 46, onPressed: () => perform(const PassPhaseAction()));
    }
  }

  /// Holding priority: respond with an instant (tap it in hand) or let things go on.
  Widget priorityButtons() {
    final top = state.stack.isEmpty ? null : state.stack.last;
    final String text;
    if (top != null) {
      text = '${state.players[top.controller].name} casts ${game.name(top.id)}. Respond?';
    } else {
      text = switch (state.phase) {
        Phase.declareAttackers => 'Attackers declared. Cast an instant?',
        Phase.declareBlockers => 'Blockers declared. Cast an instant?',
        Phase.end => 'End of turn. Cast an instant?',
        _ => 'Cast an instant?',
      };
    }
    return Row(
      children: [
        Expanded(
          child: Text(text, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
        ),
        _small(top != null ? 'Let it resolve' : 'Pass', () => perform(const PassPriorityAction()), color: LCARS.skyBlue, width: top != null ? 128 : 70),
      ],
    );
  }

  /// Spells waiting to resolve, newest on the right. Tap one to target it (counterspells).
  Widget stackStrip() {
    if (state.stack.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 74,
      child: Row(
        children: [
          RotatedBox(
            quarterTurns: 3,
            child: Text('STACK', style: LCARS.font(10, color: LCARS.gold)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final item in state.stack)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onTap: () => isCandidate(item.id) ? tapPermanent(item.id) : inspect(item.id),
                      onLongPress: () => inspect(item.id),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(color: isCandidate(item.id) ? LCARS.gold : (item.controller == me ? LCARS.orange : LCARS.alert), width: 2),
                        ),
                        child: CardFace(card: game.card(item.id), width: 50),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget decisionButtons(PendingDecision pending) {
    final d = pending.decision;
    switch (d) {
      case PayOrCounterDecision c:
        final canPay = game.canPay(c.cost, me);
        return Row(
          children: [
            Expanded(
              child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Pay ${c.cost}', canPay ? () => perform(const RespondAction(YesResponse())) : null, color: LCARS.green, width: 96),
            const SizedBox(width: 4),
            _small("Don't", () => perform(const RespondAction(NoResponse())), color: LCARS.red, fill: false, width: 70),
          ],
        );
      case MulliganDecision _:
        final taken = state.players[pending.player].mulligans;
        return Row(
          children: [
            Expanded(
              child: Text(taken == 0 ? 'Keep this hand?' : 'Keep this hand of ${state.players[pending.player].hand.length}?', style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Keep', () => perform(const RespondAction(KeepResponse())), color: LCARS.green, width: 76),
            const SizedBox(width: 4),
            _small('Mulligan', () => perform(const RespondAction(MulliganResponse())), color: LCARS.red, fill: false, width: 124),
          ],
        );
      case DeclareBlockersDecision _:
        return LcarsButton(
          'Declare blockers',
          color: LCARS.skyBlue,
          height: 36,
          onPressed: () => setState(() => interaction = const Blocking(assignments: {})),
        );
      case ChooseTargetsDecision c:
        return Row(
          children: [
            Expanded(
              child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small(
              'Choose',
              () {
                setState(() => interaction = const DecisionTargets([]));
                // Every candidate is in a graveyard (Death Is Irrelevant, Daniels…): open it.
                final inGrave = state.players.where((p) => c.candidates.any(p.graveyard.contains)).toList();
                if (inGrave.isNotEmpty && c.candidates.every((id) => inGrave.any((p) => p.graveyard.contains(id)))) showGraveyard(inGrave.first.id);
              },
              color: LCARS.gold,
              width: 80,
            ),
          ],
        );
      case ChooseModeDecision c:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            const SizedBox(height: 4),
            if (c.modes.every((m) => m.length <= 8) && c.modes.length > 3)
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < c.modes.length; i++)
                    SizedBox(
                      width: 52,
                      child: LcarsButton(c.modes[i], color: LCARS.lavender, height: 32, onPressed: () => perform(RespondAction(ModeResponse(i)))),
                    ),
                ],
              )
            else if (c.modes.length <= 2 && c.modes.every((m) => m.length <= 24))
              Row(
                children: [
                  for (var i = 0; i < c.modes.length; i++) ...[
                    Expanded(
                      child: LcarsButton(c.modes[i], color: LCARS.lavender, height: 34, onPressed: () => perform(RespondAction(ModeResponse(i)))),
                    ),
                    if (i < c.modes.length - 1) const SizedBox(width: 4),
                  ],
                ],
              )
            else
              LcarsButton(
                'Choose',
                color: LCARS.lavender,
                height: 34,
                onPressed: () => _showSheet(c.prompt, [for (var i = 0; i < c.modes.length; i++) _sheetButton(c.modes[i], () => perform(RespondAction(ModeResponse(i))), color: LCARS.lavender)]),
              ),
          ],
        );
      case ChooseModesDecision c:
        return Row(
          children: [
            Expanded(
              child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small(
              'Choose',
              () => showPickSheet(c.prompt, labels: c.modes, min: c.min, max: c.max, onDone: (picks) => perform(RespondAction(CardsResponse(picks)))),
              color: LCARS.gold,
              width: 80,
            ),
          ],
        );
      case ChooseCardsDecision c:
        return Row(
          children: [
            Expanded(
              child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small(
              'Choose',
              () => showPickSheet(c.prompt, cards: c.cards, min: c.min, max: c.max, onDone: (picks) => perform(RespondAction(CardsResponse(picks)))),
              color: LCARS.gold,
              width: 80,
            ),
          ],
        );
      case ChooseOptionalDecision c:
        return Row(
          children: [
            Expanded(
              child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Yes', () => perform(const RespondAction(YesResponse())), color: LCARS.green, width: 60),
            const SizedBox(width: 4),
            _small('No', () => perform(const RespondAction(NoResponse())), color: LCARS.red, fill: false, width: 60),
          ],
        );
      case DiscardToHandSizeDecision c:
        return Row(
          children: [
            Expanded(
              child: Text('Discard ${c.count} card${c.count == 1 ? '' : 's'}', style: LCARS.font(12, color: LCARS.gold)),
            ),
            _small('Choose', () => setState(() => interaction = const PickingCards([])), color: LCARS.gold, width: 80),
          ],
        );
      case ChooseBottomDecision c:
        return Row(
          children: [
            Expanded(
              child: Text('Mulligan: put ${c.count} card${c.count == 1 ? '' : 's'} on the bottom', style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Choose', () => setState(() => interaction = const PickingCards([])), color: LCARS.gold, width: 80),
          ],
        );
      case ChooseSacrificeDecision c:
        return Row(
          children: [
            Expanded(
              child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Choose', () => setState(() => interaction = const DecisionTargets([])), color: LCARS.gold, width: 80),
          ],
        );
      case SurveilDecision _:
      case ScryDecision _:
        final cards = d is SurveilDecision ? d.cards : (d as ScryDecision).cards;
        final chosen = interaction is PickingCards ? (interaction as PickingCards).chosen : const <ObjectID>[];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(d is SurveilDecision ? 'Surveil: tap cards to put in your graveyard' : 'Scry: tap cards to put on the bottom', style: LCARS.font(12, color: LCARS.gold)),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final id in cards)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: GestureDetector(
                      onTap: () => togglePick(id),
                      child: CardFace(card: game.card(id), width: 46, border: chosen.contains(id) ? LCARS.gold : null),
                    ),
                  ),
                const Spacer(),
                _small(
                  'Done',
                  () {
                    perform(RespondAction(CardsResponse(List.of(chosen))));
                    setState(() => interaction = const Idle());
                  },
                  color: LCARS.gold,
                  width: 64,
                ),
              ],
            ),
          ],
        );
      case ExploreDecision c:
        return Row(
          children: [
            CardFace(card: game.card(c.card), width: 40),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Explore: keep ${game.name(c.card)} on top?', style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Keep', () => perform(const RespondAction(ExploreResponse(false))), color: LCARS.green, width: 60),
            const SizedBox(width: 4),
            _small('Graveyard', () => perform(const RespondAction(ExploreResponse(true))), color: LCARS.red, fill: false, width: 90),
          ],
        );
      case DiscoverDecision c:
        return Row(
          children: [
            CardFace(card: game.card(c.card), width: 40),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Discover: play ${game.name(c.card)} for free?', style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
            ),
            _small('Play', () => perform(const RespondAction(DiscoverResponse(true))), color: LCARS.green, width: 60),
            const SizedBox(width: 4),
            _small('To hand', () => perform(const RespondAction(DiscoverResponse(false))), color: LCARS.peach, fill: false, width: 80),
          ],
        );
    }
  }

  String targetPrompt(TargetRequirement? req, List<ObjectID> chosen) {
    if (req == null) return 'Choose targets';
    final what = switch (req.filter.kind) {
      FilterKind.creature => 'creature',
      FilterKind.creatureOrPlayer => 'creature or player',
      FilterKind.player || FilterKind.opponent => 'player',
      FilterKind.artifact => 'artifact',
      FilterKind.enchantment => 'enchantment',
      FilterKind.land => 'land',
      FilterKind.creatureCardInGraveyard => 'creature card in a graveyard',
      FilterKind.cardInGraveyard => 'card in a graveyard',
      FilterKind.permanentCardInGraveyard => 'permanent card in a graveyard',
      FilterKind.spacecraft => 'Spacecraft',
      FilterKind.creatureOrSpacecraft => 'creature or Spacecraft',
      _ => 'permanent',
    };
    final who = req.filter.controller == Controller.opponent ? ' an opponent controls' : (req.filter.controller == Controller.you ? ' you control' : '');
    return 'Tap ${req.optional ? 'up to one ' : ''}target $what$who${req.count > 1 ? ' (up to ${req.count})' : ''}';
  }

  String zoneLabel(ObjectID id) => switch (state.objects[id]?.zone) {
    Zone.exile => 'FROM EXILE',
    Zone.library => 'TOP OF LIBRARY',
    Zone.graveyard => 'FROM GRAVEYARD',
    _ => '',
  };

  /// Abilities of a card in a hand or graveyard that can be used from there right now.
  List<(int, Activated)> zoneAbilities(ObjectID id) {
    final o = state.objects[id];
    if (o == null || !canAct) return const [];
    final all = game.abilitiesIn(o);
    return [
      for (var i = 0; i < all.length; i++)
        if (all[i] case final Activated a when a.cost.zone != AbilityZone.battlefield && game.activationProblem(id, i, me) == null) (i, a),
    ];
  }

  Widget hand() {
    final hidden = session!.mode == SessionMode.hotseat && state.playerToAct != me;
    final ids = state.players[me].hand;
    final picked = interaction is PickingCards ? (interaction as PickingCards).chosen : const <ObjectID>[];
    // About a fifth of the screen, so cards in hand can be recognized at a glance.
    final height = (MediaQuery.sizeOf(context).height * 0.21).clamp(130.0, 230.0);
    final cardW = (height - 22) / cardAspect;
    final otherW = (height - 36) / cardAspect;
    return SizedBox(
      height: height,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
        children: [
          for (final id in ids)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: hidden
                  ? Container(
                      width: cardW,
                      height: cardW * cardAspect,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: LCARS.panel, borderRadius: BorderRadius.circular(4)),
                      child: Text('MT', style: LCARS.label.copyWith(color: LCARS.gray)),
                    )
                  : HandCardView(
                      key: ValueKey('hand-$id'),
                      session: session!,
                      objectID: id,
                      width: cardW,
                      playable: playable(id),
                      selected: selectedHandCard == id || picked.contains(id),
                      onTap: () => tapHandCard(id),
                      onLongPress: () => inspect(id),
                    ),
            ),
          // Cards playable from elsewhere right now: exiled by an effect, the top of the library,
          // the graveyard. They sit after the hand with where they are written above them.
          // Captain Pike, Benjamin Sisko: the top card of the library is always visible to its owner.
          if (!hidden && game.controlsStatic(me, SimpleStaticKind.lookAtTop))
            if (state.players[me].library.firstOrNull case final top? when !game.extraPlayables(me).contains(top))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('TOP (LOOK)', style: LCARS.font(9, color: LCARS.lavender)),
                    HandCardView(session: session!, objectID: top, width: otherW, playable: false, selected: false, onTap: () => inspect(top), onLongPress: () => inspect(top)),
                  ],
                ),
              ),
          if (!hidden)
            for (final id in game.extraPlayables(me))
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(zoneLabel(id), style: LCARS.font(9, color: LCARS.gold)),
                    HandCardView(session: session!, objectID: id, width: otherW, playable: playable(id), selected: selectedHandCard == id, onTap: () => tapHandCard(id), onLongPress: () => inspect(id)),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget gameOverOverlay() {
    final won = state.winner == me;
    final reason = state.log.lastWhere((e) => e.kind == 'gameOver', orElse: () => GameEvent('note')).text ?? '';
    return Container(
      color: LCARS.black.withValues(alpha: 0.6),
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.all(30),
        padding: const EdgeInsets.all(26),
        decoration: BoxDecoration(
          color: LCARS.panel.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: won ? LCARS.gold : LCARS.red, width: 3),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(won ? 'VICTORY' : 'DEFEAT', style: LCARS.font(44, color: won ? LCARS.gold : LCARS.red)),
            const SizedBox(height: 8),
            Text(reason, style: LCARS.body, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(won ? 'Live long and prosper.' : 'Today was a good day to die.', style: LCARS.label.copyWith(color: LCARS.lavender)),
            const SizedBox(height: 16),
            SizedBox(width: 220, child: LcarsButton('Return to bridge', onPressed: () => Navigator.pop(context))),
          ],
        ),
      ),
    );
  }

  void leave() {
    final s = session!;
    if (!s.isLinked && !state.isOver) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('GAME SAVED · RESUME FROM THE MENU')));
    }
    Navigator.pop(context);
  }
}

/// The event log as sentences.
class EventText {
  static String? describe(GameEvent e, Game game) {
    String n(ObjectID? id) => id == null ? '?' : game.name(id);
    String p(PlayerID? id) => id == null ? '?' : game.state.players[id].name;
    switch (e.kind) {
      case 'gameStarted':
        return 'Game on. ${p(e.player)} goes first. Rules: ${game.rules.summary}.';
      case 'turnBegan':
        return '— Turn ${e.amount}: ${p(e.player)} —';
      case 'drew':
        return '${p(e.player)} draws ${e.amount} card${e.amount == 1 ? '' : 's'}.';
      case 'mulliganed':
        return '${p(e.player)} mulligans to ${e.amount}.';
      case 'playedLand':
        return '${p(e.player)} plays ${n(e.object)}.';
      case 'cast':
        return '${p(e.player)} casts ${n(e.object)}${e.amount == 1 ? ' with kicker' : ''}.';
      case 'countered':
        return '${n(e.object)} is countered.';
      case 'paid':
        return '${p(e.player)} pays ${e.text}.';
      case 'fizzled':
        return '${n(e.object)} has no legal target and fizzles.';
      case 'tokenCreated':
        return '${p(e.player)} creates a ${n(e.object)} token.';
      case 'damage':
        return '${e.other == null ? 'Something' : n(e.other)} deals ${e.amount} damage to ${n(e.object)}.';
      case 'lifeChanged':
        return (e.amount ?? 0) > 0 ? '${p(e.player)} gains ${e.amount} life.' : null;
      case 'died':
        return '${n(e.object)} dies.';
      case 'exiled':
        return '${n(e.object)} is exiled.';
      case 'bounced':
        return '${n(e.object)} returns to hand.';
      case 'destroyed':
        return '${n(e.object)} is destroyed.';
      case 'discarded':
        return '${p(e.player)} discards ${n(e.object)}.';
      case 'milled':
        return '${p(e.player)} mills ${n(e.object)}.';
      case 'counters':
        return (e.amount ?? 0) > 0 ? '${n(e.object)} gets ${e.amount} ${e.counter?.text} counter${e.amount == 1 ? '' : 's'}.' : null;
      case 'attackersDeclared':
        return '${p(e.player)} attacks with ${(e.ids ?? const []).map(n).join(', ')}.';
      case 'blockersDeclared':
        final m = e.map ?? const {};
        return m.isEmpty ? "${p(e.player)} doesn't block." : '${p(e.player)} blocks: ${m.entries.map((x) => '${n(x.key)} blocks ${n(x.value)}').join(', ')}.';
      case 'triggered':
        return '${e.text} triggers.';
      case 'activated':
        return '${e.text} activates.';
      case 'stationed':
        return '${n(e.other)} stations ${n(e.object)} (+${e.amount} charge).';
      case 'becameCreature':
        return '${n(e.object)} is now a creature!';
      case 'equipped':
        return '${n(e.object)} equips ${n(e.other)}.';
      case 'fought':
        return '${n(e.object)} fights ${n(e.other)}.';
      case 'searched':
        return e.object == null ? '${p(e.player)} finds nothing.' : '${p(e.player)} finds ${n(e.object)}.';
      case 'surveilled':
        return '${p(e.player)} surveils: ${e.amount} to graveyard, ${e.other} on top.';
      case 'explored':
        return '${n(e.object)} explores and ${e.amount == 1 ? 'finds a land' : 'grows'}.';
      case 'assimilated':
        return '${p(e.player)} assimilates ${n(e.object)}. Resistance is futile.';
      case 'sagaChapter':
        return '${n(e.object)}: chapter ${e.amount}.';
      case 'gameOver':
        return '${p(e.player)} wins! ${e.text}';
      case 'note':
        return e.text;
      default:
        return null;
    }
  }

  static Color color(GameEvent e) => switch (e.kind) {
    'turnBegan' => LCARS.orange,
    'damage' || 'died' || 'destroyed' => LCARS.red,
    'cast' || 'playedLand' => LCARS.peach,
    'gameOver' => LCARS.gold,
    _ => LCARS.lavender,
  };
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
