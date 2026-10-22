import 'package:flutter/material.dart' hide Card;

import '../app/session.dart';
import '../app/sound.dart';
import '../app/store.dart';
import '../engine/abilities.dart';
import '../engine/actions.dart';
import '../engine/bot.dart';
import '../engine/game.dart';
import '../engine/state.dart';
import 'card_widgets.dart';
import 'lcars.dart';

/// What the player is in the middle of doing on the table.
sealed class Interaction {
  const Interaction();
}

class Idle extends Interaction {
  const Idle();
}

class Targeting extends Interaction {
  const Targeting({required this.requirements, required this.chosen, required this.purpose});
  final List<TargetRequirement> requirements;
  final List<ObjectID> chosen;
  final Purpose purpose;
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
  const CastPurpose(this.card, {this.kicked = false, this.mode});
  final ObjectID card;
  final bool kicked;
  final int? mode;
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
    if (interaction is! Idle || !canAct) return;
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
    final modal = parsed.spellEffects.any((e) => e is Modal);
    if (kickable || modal || canCycle(id) || !game.canCast(id, me)) {
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
    final parsed = game.db.parsed(card);
    final items = <Widget>[];
    if (game.canCast(id, me)) {
      final modal = parsed.spellEffects.whereType<Modal>().firstOrNull;
      if (modal != null) {
        for (var i = 0; i < modal.modes.length; i++) {
          items.add(_sheetButton('Cast: ${game.describeEffects(modal.modes[i])}', () => beginCast(id, kicked: false, mode: i)));
        }
      } else {
        items.add(_sheetButton('Cast ${card.manaCost}', () => beginCast(id, kicked: false, mode: null)));
      }
      final k = parsed.kicker;
      if (k != null) items.add(_sheetButton('Cast with kicker (+$k)', () => beginCast(id, kicked: true, mode: null)));
    }
    final cyc = parsed.cycling;
    if (cyc != null && canCycle(id)) items.add(_sheetButton('${cyc.landType == null ? 'Cycling' : 'Landcycling'} ${cyc.cost}', () => perform(CycleAction(id))));
    items.add(_sheetButton('Inspect', () => inspect(id), color: LCARS.lavender));
    _showSheet(card.name, items);
  }

  Widget _sheetButton(String label, VoidCallback onTap, {Color color = LCARS.orange, bool enabled = true}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: LcarsButton(label, color: color, height: 40, onPressed: enabled
            ? () {
                Navigator.pop(context);
                onTap();
              }
            : null),
      );

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

  void beginCast(ObjectID id, {required bool kicked, int? mode}) {
    final card = game.card(id);
    if (card == null) return;
    final reqs = game.targetRequirementsForCard(card, mode).where((r) => game.legalTargets(r.filter, me, id).isNotEmpty).toList();
    if (reqs.isEmpty) {
      perform(CastAction(id, kicked: kicked, mode: mode));
    } else {
      setState(() {
        selectedHandCard = id;
        interaction = Targeting(requirements: reqs, chosen: const [], purpose: CastPurpose(id, kicked: kicked, mode: mode));
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
        if (chosen.length >= req.count) {
          final rest = t.requirements.sublist(1);
          if (rest.isEmpty) {
            interaction = Targeting(requirements: t.requirements, chosen: chosen, purpose: t.purpose);
            finishTargeting();
          } else {
            setState(() => interaction = Targeting(requirements: rest, chosen: chosen, purpose: t.purpose));
          }
        } else {
          setState(() => interaction = Targeting(requirements: t.requirements, chosen: chosen, purpose: t.purpose));
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
        if (obj.controller == me && canAct) {
          showPermanentMenu(id);
        } else {
          inspect(id);
        }
    }
  }

  void showPermanentMenu(ObjectID id) {
    final obj = state.objects[id];
    final parsed = obj == null ? null : game.parsedOf(obj);
    if (obj == null || parsed == null) return;
    final c = game.characteristics(id);
    final items = <Widget>[];
    for (var i = 0; i < parsed.abilities.length; i++) {
      final a = parsed.abilities[i];
      if (a is! Activated) continue;
      if (a.effects.length == 1 && a.effects[0] is AddMana) continue;
      final cost = a.cost;
      final usable = (!a.sorcerySpeed || state.phase.isMain) && !(cost.tap && obj.tapped) && game.canPay(cost.mana, me) && !(cost.oncePerTurn && obj.activatedThisTurn.contains(i));
      items.add(_sheetButton('${costText(cost)}: ${game.describeEffects(a.effects)}', () => beginActivate(id, i, cost, a.effects), enabled: usable));
    }
    if (c.isSpacecraft && parsed.has(KeywordKind.station) && state.phase.isMain) {
      items.add(_sheetButton('Station (tap a creature)', () => setState(() => interaction = Stationing(id)), color: LCARS.blue));
    }
    final equip = parsed.equipCost;
    if (equip != null && state.phase.isMain) {
      items.add(_sheetButton('Equip $equip', () => setState(() => interaction = Equipping(id)), color: LCARS.gold, enabled: game.canPay(equip, me)));
    }
    if ((state.phase == Phase.main1 || state.phase == Phase.declareAttackers) && game.canAttack(id)) {
      items.add(_sheetButton('Attack with this', () => setState(() => interaction = Attacking({id})), color: LCARS.alert));
    }
    items.add(_sheetButton('Inspect', () => inspect(id), color: LCARS.lavender));
    _showSheet(game.name(id), items);
  }

  String costText(ActivationCost cost) {
    final parts = <String>[];
    if (!cost.mana.isFree) parts.add(cost.mana.toString());
    if (cost.tap) parts.add('Tap');
    if (cost.sacrificeSelf) parts.add('Sacrifice');
    if (cost.sacrifice != null) parts.add('Sacrifice a permanent');
    if (cost.payLife > 0) parts.add('Pay ${cost.payLife} life');
    if (cost.discard > 0) parts.add('Discard');
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
        perform(CastAction(p.card, targets: t.chosen, kicked: p.kicked, mode: p.mode));
      case ActivatePurpose p:
        ObjectID? sacrifice;
        final obj = state.objects[p.object];
        final parsed = obj == null ? null : game.parsedOf(obj);
        final a = parsed?.abilities[p.index];
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
    final chosen = [...t.chosen, EffectContext.playerObject(p)];
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
          child: Column(children: [
            if (card != null) CardDetailBody(card: card, db: game.db) else TokenFace(token: obj.token, width: 240),
            if (obj.zone == Zone.battlefield)
              LcarsPanel(
                title: 'On the battlefield',
                color: LCARS.gold,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (c.isCreature) Text('${c.power}/${c.toughness}, ${obj.damage} damage marked', style: LCARS.body),
                  if (c.keywords.isNotEmpty) Text((c.keywords.map((k) => k.toString()).toList()..sort()).join(', '), style: LCARS.label.copyWith(color: LCARS.lavender)),
                  if (obj.counters.isNotEmpty) Text('${obj.counters.entries.map((e) => '${e.value} ${e.key.text}').join(', ')} counters', style: LCARS.label.copyWith(color: LCARS.blue)),
                  if (obj.tapped) Text('Tapped', style: LCARS.label.copyWith(color: LCARS.gray)),
                ]),
              ),
          ]),
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
          child: Column(children: [
            LcarsHeader("${state.players[p].name}'s graveyard", color: LCARS.violet),
            Expanded(
              child: ids.isEmpty
                  ? Center(child: Text('Empty', style: LCARS.body.copyWith(color: LCARS.gray)))
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
                        return Column(children: [
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
                                  decoration: targetable ? BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: LCARS.gold, width: 3)) : null,
                                  child: CardFace(card: card, width: box.maxWidth),
                                ),
                              ),
                            ),
                          ),
                          if (targetable) Text('TAP TO TARGET', style: LCARS.font(9, color: LCARS.gold)),
                          if (canBeam)
                            LcarsButton('Beam up $beam', height: 26, color: LCARS.blue, onPressed: () {
                              Navigator.pop(context);
                              setState(() => interaction = BeamingUp(id));
                            }),
                        ]);
                      },
                    ),
            ),
          ]),
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
            child: Column(children: [
              const LcarsHeader("Captain's log", color: LCARS.lavender),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  reverse: true,
                  itemCount: lines.length,
                  itemBuilder: (_, i) {
                    final (t, c) = lines[lines.length - 1 - i];
                    return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(t, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c)));
                  },
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Future<void> confirmConcede() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(title: const Text('Concede the game?'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Concede'))]),
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

  bool playable(ObjectID id) => interaction is Idle && (game.canPlayLand(id, me) || game.canCast(id, me) || canCycle(id));

  // MARK: Build

  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) return const Scaffold(body: Center(child: Text('No game')));
    return Scaffold(
      backgroundColor: LCARS.black,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.chevron_left), onPressed: leave),
        title: Text('Turn ${state.turn} · ${state.phase.label}'.toUpperCase(), style: LCARS.font(14, color: LCARS.peach)),
        actions: [
          IconButton(icon: const Icon(Icons.list_alt, color: LCARS.lavender), onPressed: showLog),
          IconButton(icon: const Icon(Icons.flag, color: LCARS.red), onPressed: confirmConcede),
        ],
      ),
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            playerStrip(them, top: true),
            Expanded(flex: 5, child: battlefield(them, top: true)),
            controlBar(),
            Expanded(flex: 5, child: battlefield(me, top: false)),
            playerStrip(me, top: false),
            hand(),
          ]),
          if (state.isOver) Positioned.fill(child: gameOverOverlay()),
        ]),
      ),
    );
  }

  Widget playerStrip(PlayerID p, {required bool top}) {
    final ps = state.players[p];
    final active = state.activePlayer == p;
    final life = ps.life;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(children: [
        Container(width: 30, height: 20, decoration: BoxDecoration(color: active ? LCARS.orange : LCARS.gray, borderRadius: BorderRadius.circular(10))),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(ps.name.toUpperCase(), style: LCARS.font(16, color: active ? LCARS.orange : LCARS.peach), maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(top ? 'opponent' : (session!.mode == SessionMode.hotseat ? 'your seat' : 'you'), style: LCARS.small.copyWith(color: LCARS.gray)),
          ]),
        ),
        LcarsReadout(label: 'life', value: '$life', color: lifeFlash == p ? LCARS.alert : (life <= 5 ? LCARS.red : LCARS.peach)),
        const SizedBox(width: 10),
        LcarsReadout(label: 'hand', value: '${ps.hand.length}', color: LCARS.blue),
        const SizedBox(width: 10),
        LcarsReadout(label: 'library', value: '${ps.library.length}', color: LCARS.lavender),
        const SizedBox(width: 10),
        GestureDetector(onTap: () => showGraveyard(p), child: LcarsReadout(label: 'grave', value: '${ps.graveyard.length}', color: LCARS.violet)),
      ]),
    );
  }

  Widget battlefield(PlayerID p, {required bool top}) {
    final perms = state.permanentsOf(p);
    final lands = perms.where((o) => game.characteristics(o.id).isLand && o.attachedTo == null).toList();
    final others = perms.where((o) => !game.characteristics(o.id).isLand).toList();
    Widget landRow() => SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 6), children: [
            if (lands.isEmpty) Center(child: Text('no lands', style: LCARS.small.copyWith(color: LCARS.gray))),
            for (final o in lands) Padding(padding: const EdgeInsets.only(right: 3), child: PermanentView(session: session!, objectID: o.id, width: 30, highlighted: isCandidate(o.id), selected: isSelected(o.id), onTap: () => tapPermanent(o.id), onLongPress: () => inspect(o.id))),
          ]),
        );
    Widget mainRow() => Expanded(
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 6), children: [
            if (others.isEmpty) Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(top ? 'no permanents' : 'your battlefield', style: LCARS.small.copyWith(color: LCARS.gray)))),
            for (final o in others)
              Padding(
                padding: const EdgeInsets.only(right: 5),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  LayoutBuilder(builder: (_, box) {
                    final w = (box.maxHeight / cardAspect).clamp(44.0, 80.0);
                    return PermanentView(session: session!, objectID: o.id, width: w, highlighted: isCandidate(o.id), selected: isSelected(o.id), dimmed: isDimmed(o.id), onTap: () => tapPermanent(o.id), onLongPress: () => inspect(o.id), tag: blockTag(o.id));
                  }),
                ]),
              ),
          ]),
        );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: LCARS.panel.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(10)),
      child: Column(children: top ? [landRow(), mainRow()] : [mainRow(), landRow()]),
    );
  }

  String? blockTag(ObjectID id) {
    final i = interaction;
    if (i is Blocking && i.assignments.containsKey(id)) return '→${game.name(i.assignments[id]!).split(' ').first}';
    return null;
  }

  Widget controlBar() {
    final s = session!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Container(width: 12, height: 12, decoration: BoxDecoration(color: myTurn ? LCARS.orange : LCARS.skyBlue, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Expanded(child: Text(s.lastError ?? (s.match?.status ?? ''), style: LCARS.small.copyWith(color: s.lastError != null ? LCARS.alert : LCARS.gray), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (s.thinking) const ScanLine(color: LCARS.blue, width: 70),
        ]),
        const SizedBox(height: 4),
        stackStrip(),
        promptBar(),
      ]),
    );
  }

  Widget _small(String label, VoidCallback? onTap, {Color color = LCARS.orange, bool fill = true, double width = 86}) => SizedBox(width: width, child: LcarsButton(label, height: 32, color: color, fill: fill, onPressed: onTap));

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
        return Row(children: [
          Expanded(child: Text(targetPrompt(req, t.chosen), style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          if (req != null) ...graveyardTargetButtons(game.legalTargets(req.filter, me, null)),
          if (req != null && (req.filter.isPlayerFilter || req.filter.kind == FilterKind.creatureOrPlayer)) ...[
            if (req.filter.kind != FilterKind.opponent) _small('You', () => chooseTargetPlayer(me), color: LCARS.peach, fill: false, width: 60),
            const SizedBox(width: 4),
            _small(state.players[them].name, () => chooseTargetPlayer(them), color: LCARS.alert, width: 90),
          ],
          if (req != null && (req.optional || t.chosen.isNotEmpty)) ...[const SizedBox(width: 4), _small('Done', finishTargeting, color: LCARS.gold, width: 64)],
          const SizedBox(width: 4),
          _small('Cancel', () => setState(() {
                interaction = const Idle();
                selectedHandCard = null;
              }), color: LCARS.red, fill: false, width: 70),
        ]);
      case Attacking a:
        return Row(children: [
          Expanded(child: Text('Choose attackers (${a.selected.length})', style: LCARS.font(12, color: LCARS.gold))),
          _small('All', () => setState(() => interaction = Attacking(state.permanentsOf(me).where((o) => game.canAttack(o.id)).map((o) => o.id).toSet())), color: LCARS.peach, fill: false, width: 54),
          const SizedBox(width: 4),
          _small(a.selected.isEmpty ? 'No attack' : 'Attack!', () {
            perform(DeclareAttackersAction(a.selected.toList()));
            setState(() => interaction = const Idle());
          }, color: LCARS.alert, width: 90),
          const SizedBox(width: 4),
          _small('Cancel', () => setState(() => interaction = const Idle()), color: LCARS.red, fill: false, width: 70),
        ]);
      case Blocking b:
        return Row(children: [
          Expanded(child: Text(b.blocker == null ? 'Blocks: tap your creature, then the attacker' : 'Now tap the attacker ${game.name(b.blocker!)} blocks', style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small(b.assignments.isEmpty ? 'No blocks' : 'Confirm', () {
            perform(RespondAction(BlockersResponse(Map.of(b.assignments))));
            setState(() => interaction = const Idle());
          }, color: LCARS.skyBlue, width: 90),
          const SizedBox(width: 4),
          _small('Clear', () => setState(() => interaction = const Blocking(assignments: {})), color: LCARS.red, fill: false, width: 62),
        ]);
      case Stationing _:
      case Equipping _:
      case BeamingUp _:
        final text = switch (i) {
          Stationing _ => 'Tap an untapped creature to station',
          Equipping _ => 'Tap a creature to equip',
          _ => 'Beam me up: tap a creature you control to return to hand',
        };
        return Row(children: [Expanded(child: Text(text, style: LCARS.font(12, color: LCARS.gold), maxLines: 2)), _small('Cancel', () => setState(() => interaction = const Idle()), color: LCARS.red, fill: false, width: 70)]);
      case DecisionTargets d:
        final decision = state.pending?.decision;
        if (decision is ChooseTargetsDecision) {
          return Row(children: [
            Expanded(child: Text('${decision.prompt} (${d.chosen.length}/${decision.count})', style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
            ...graveyardTargetButtons(decision.candidates),
            if (decision.filter.isPlayerFilter || decision.filter.kind == FilterKind.creatureOrPlayer)
              for (final pid in decision.candidates.where((c) => EffectContext.playerFromObject(c) != null)) ...[
                _small(game.name(pid), () {
                  perform(RespondAction(TargetsResponse([pid])));
                  setState(() => interaction = const Idle());
                }, color: LCARS.peach, width: 80),
                const SizedBox(width: 4),
              ],
            if (decision.optional || d.chosen.isNotEmpty)
              _small('Done', () {
                perform(RespondAction(TargetsResponse(d.chosen)));
                setState(() => interaction = const Idle());
              }, color: LCARS.gold, width: 64),
          ]);
        }
        if (decision is ChooseSacrificeDecision) return Text(decision.prompt, style: LCARS.font(12, color: LCARS.gold));
        return const SizedBox.shrink();
      case PickingCards p:
        final decision = state.pending?.decision;
        final need = switch (decision) { DiscardToHandSizeDecision d => d.count, ChooseBottomDecision d => d.count, _ => 0 };
        final verb = decision is ChooseBottomDecision ? 'To the bottom' : 'Discard';
        return Row(children: [
          Expanded(child: Text('$verb: ${p.chosen.length}/$need chosen (tap cards in hand)', style: LCARS.font(12, color: LCARS.gold))),
          _small('Done', p.chosen.length == need
              ? () {
                  perform(RespondAction(CardsResponse(p.chosen)));
                  setState(() => interaction = const Idle());
                }
              : null, color: LCARS.gold, width: 64),
        ]);
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
      return Row(children: [
        Expanded(child: Text(s.isLinked ? 'Waiting for ${state.players[state.playerToAct ?? them].name}…' : '${state.players[them].name} is thinking…', style: LCARS.font(12, color: LCARS.skyBlue))),
      ]);
    }
    final canAttackAny = state.permanentsOf(me).any((o) => game.canAttack(o.id));
    switch (state.phase) {
      case Phase.main1:
        return Row(children: [
          Expanded(child: LcarsButton('Attack', color: LCARS.alert, height: 36, onPressed: canAttackAny ? () => setState(() => interaction = const Attacking({})) : null)),
          const SizedBox(width: 4),
          Expanded(child: LcarsButton('Skip combat', color: LCARS.peach, fill: false, height: 36, onPressed: () => perform(const DeclareAttackersAction([])))),
          const SizedBox(width: 4),
          Expanded(child: LcarsButton('End turn', height: 36, onPressed: () => perform(const EndTurnAction()))),
        ]);
      case Phase.declareAttackers:
      case Phase.beginCombat:
        return Row(children: [
          Expanded(child: LcarsButton('Attack', color: LCARS.alert, height: 36, onPressed: () => setState(() => interaction = const Attacking({})))),
          const SizedBox(width: 4),
          Expanded(child: LcarsButton('No attack', color: LCARS.peach, fill: false, height: 36, onPressed: () => perform(const DeclareAttackersAction([])))),
        ]);
      case Phase.main2:
        return LcarsButton('End turn', height: 36, onPressed: () => perform(const EndTurnAction()));
      default:
        return LcarsButton('Continue', height: 36, onPressed: () => perform(const PassPhaseAction()));
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
    return Row(children: [
      Expanded(child: Text(text, style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
      _small(top != null ? 'Let it resolve' : 'Pass', () => perform(const PassPriorityAction()), color: LCARS.skyBlue, width: top != null ? 128 : 70),
    ]);
  }

  /// Spells waiting to resolve, newest on the right. Tap one to target it (counterspells).
  Widget stackStrip() {
    if (state.stack.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 74,
      child: Row(children: [
        RotatedBox(quarterTurns: 3, child: Text('STACK', style: LCARS.font(10, color: LCARS.gold))),
        const SizedBox(width: 4),
        Expanded(
          child: ListView(scrollDirection: Axis.horizontal, children: [
            for (final item in state.stack)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => isCandidate(item.id) ? tapPermanent(item.id) : inspect(item.id),
                  onLongPress: () => inspect(item.id),
                  child: Container(
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), border: Border.all(color: isCandidate(item.id) ? LCARS.gold : (item.controller == me ? LCARS.orange : LCARS.alert), width: 2)),
                    child: CardFace(card: game.card(item.id), width: 50),
                  ),
                ),
              ),
          ]),
        ),
      ]),
    );
  }

  Widget decisionButtons(PendingDecision pending) {
    final d = pending.decision;
    switch (d) {
      case PayOrCounterDecision c:
        final canPay = game.canPay(c.cost, me);
        return Row(children: [
          Expanded(child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small('Pay ${c.cost}', canPay ? () => perform(const RespondAction(YesResponse())) : null, color: LCARS.green, width: 96),
          const SizedBox(width: 4),
          _small("Don't", () => perform(const RespondAction(NoResponse())), color: LCARS.red, fill: false, width: 70),
        ]);
      case MulliganDecision _:
        final taken = state.players[pending.player].mulligans;
        return Row(children: [
          Expanded(child: Text(taken == 0 ? 'Keep this hand?' : 'Keep this hand of ${state.players[pending.player].hand.length}?', style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small('Keep', () => perform(const RespondAction(KeepResponse())), color: LCARS.green, width: 76),
          const SizedBox(width: 4),
          _small('Mulligan', () => perform(const RespondAction(MulliganResponse())), color: LCARS.red, fill: false, width: 124),
        ]);
      case DeclareBlockersDecision _:
        return LcarsButton('Declare blockers', color: LCARS.skyBlue, height: 36, onPressed: () => setState(() => interaction = const Blocking(assignments: {})));
      case ChooseTargetsDecision c:
        return Row(children: [
          Expanded(child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small('Choose', () {
            setState(() => interaction = const DecisionTargets([]));
            // Every candidate is in a graveyard (Death Is Irrelevant, Daniels…): open it.
            final inGrave = state.players.where((p) => c.candidates.any(p.graveyard.contains)).toList();
            if (inGrave.isNotEmpty && c.candidates.every((id) => inGrave.any((p) => p.graveyard.contains(id)))) showGraveyard(inGrave.first.id);
          }, color: LCARS.gold, width: 80),
        ]);
      case ChooseModeDecision c:
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2),
          const SizedBox(height: 4),
          Row(children: [for (var i = 0; i < c.modes.length; i++) ...[Expanded(child: LcarsButton(c.modes[i], color: LCARS.lavender, height: 34, onPressed: () => perform(RespondAction(ModeResponse(i))))), if (i < c.modes.length - 1) const SizedBox(width: 4)]]),
        ]);
      case ChooseOptionalDecision c:
        return Row(children: [
          Expanded(child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small('Yes', () => perform(const RespondAction(YesResponse())), color: LCARS.green, width: 60),
          const SizedBox(width: 4),
          _small('No', () => perform(const RespondAction(NoResponse())), color: LCARS.red, fill: false, width: 60),
        ]);
      case DiscardToHandSizeDecision c:
        return Row(children: [Expanded(child: Text('Discard ${c.count} card${c.count == 1 ? '' : 's'}', style: LCARS.font(12, color: LCARS.gold))), _small('Choose', () => setState(() => interaction = const PickingCards([])), color: LCARS.gold, width: 80)]);
      case ChooseBottomDecision c:
        return Row(children: [Expanded(child: Text('Mulligan: put ${c.count} card${c.count == 1 ? '' : 's'} on the bottom', style: LCARS.font(12, color: LCARS.gold), maxLines: 2)), _small('Choose', () => setState(() => interaction = const PickingCards([])), color: LCARS.gold, width: 80)]);
      case ChooseSacrificeDecision c:
        return Row(children: [Expanded(child: Text(c.prompt, style: LCARS.font(12, color: LCARS.gold), maxLines: 2)), _small('Choose', () => setState(() => interaction = const DecisionTargets([])), color: LCARS.gold, width: 80)]);
      case SurveilDecision _:
      case ScryDecision _:
        final cards = d is SurveilDecision ? d.cards : (d as ScryDecision).cards;
        final chosen = interaction is PickingCards ? (interaction as PickingCards).chosen : const <ObjectID>[];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(d is SurveilDecision ? 'Surveil: tap cards to put in your graveyard' : 'Scry: tap cards to put on the bottom', style: LCARS.font(12, color: LCARS.gold)),
          const SizedBox(height: 4),
          Row(children: [
            for (final id in cards) Padding(padding: const EdgeInsets.only(right: 4), child: GestureDetector(onTap: () => togglePick(id), child: CardFace(card: game.card(id), width: 46, border: chosen.contains(id) ? LCARS.gold : null))),
            const Spacer(),
            _small('Done', () {
              perform(RespondAction(CardsResponse(List.of(chosen))));
              setState(() => interaction = const Idle());
            }, color: LCARS.gold, width: 64),
          ]),
        ]);
      case ExploreDecision c:
        return Row(children: [
          CardFace(card: game.card(c.card), width: 40),
          const SizedBox(width: 6),
          Expanded(child: Text('Explore: keep ${game.name(c.card)} on top?', style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small('Keep', () => perform(const RespondAction(ExploreResponse(false))), color: LCARS.green, width: 60),
          const SizedBox(width: 4),
          _small('Graveyard', () => perform(const RespondAction(ExploreResponse(true))), color: LCARS.red, fill: false, width: 90),
        ]);
      case DiscoverDecision c:
        return Row(children: [
          CardFace(card: game.card(c.card), width: 40),
          const SizedBox(width: 6),
          Expanded(child: Text('Discover: play ${game.name(c.card)} for free?', style: LCARS.font(12, color: LCARS.gold), maxLines: 2)),
          _small('Play', () => perform(const RespondAction(DiscoverResponse(true))), color: LCARS.green, width: 60),
          const SizedBox(width: 4),
          _small('To hand', () => perform(const RespondAction(DiscoverResponse(false))), color: LCARS.peach, fill: false, width: 80),
        ]);
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
      FilterKind.spacecraft => 'Spacecraft',
      FilterKind.creatureOrSpacecraft => 'creature or Spacecraft',
      _ => 'permanent',
    };
    final who = req.filter.controller == Controller.opponent ? ' an opponent controls' : (req.filter.controller == Controller.you ? ' you control' : '');
    return 'Tap target $what$who${req.count > 1 ? ' (${chosen.length}/${req.count})' : ''}';
  }

  Widget hand() {
    final hidden = session!.mode == SessionMode.hotseat && state.playerToAct != me;
    final ids = state.players[me].hand;
    final picked = interaction is PickingCards ? (interaction as PickingCards).chosen : const <ObjectID>[];
    return SizedBox(
      height: 150,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(8, 14, 8, 6), children: [
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: hidden
                ? Container(width: 60, height: 84, alignment: Alignment.center, decoration: BoxDecoration(color: LCARS.panel, borderRadius: BorderRadius.circular(4)), child: Text('MT', style: LCARS.label.copyWith(color: LCARS.gray)))
                : HandCardView(session: session!, objectID: id, width: 84, playable: playable(id), selected: selectedHandCard == id || picked.contains(id), onTap: () => tapHandCard(id), onLongPress: () => inspect(id)),
          ),
      ]),
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
        decoration: BoxDecoration(color: LCARS.panel.withValues(alpha: 0.96), borderRadius: BorderRadius.circular(24), border: Border.all(color: won ? LCARS.gold : LCARS.red, width: 3)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(won ? 'VICTORY' : 'DEFEAT', style: LCARS.font(44, color: won ? LCARS.gold : LCARS.red)),
          const SizedBox(height: 8),
          Text(reason, style: LCARS.body, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(won ? 'Live long and prosper.' : 'Today was a good day to die.', style: LCARS.label.copyWith(color: LCARS.lavender)),
          const SizedBox(height: 16),
          SizedBox(width: 220, child: LcarsButton('Return to bridge', onPressed: () => Navigator.pop(context))),
        ]),
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
