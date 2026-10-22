import 'abilities.dart';
import 'cards.dart';
import 'props.dart';
import 'rng.dart';
import 'rules.dart';

typedef PlayerID = int;
typedef ObjectID = int;

enum Zone { library, hand, battlefield, graveyard, exile, stack }

/// A card in the game. Tokens are objects too, with `token` set.
class GameObject {
  GameObject({required this.id, required this.cardID, required this.owner, required this.zone, this.token}) : controller = owner;
  final ObjectID id;
  String cardID; // CardDatabase id; "" for a token that copies nothing
  final PlayerID owner;
  TokenSpec? token;
  Zone zone;
  PlayerID controller;
  bool tapped = false;
  int damage = 0;
  Map<CounterKind, int> counters = {};
  int enteredTurn = -1;
  ObjectID? attachedTo;
  List<TemporaryEffect> untilEndOfTurn = [];
  bool frozen = false;
  bool sacrificeAtEnd = false;
  Set<int> activatedThisTurn = {};
  List<ObjectID> exiledWithThis = [];
  bool assimilated = false;
  PlayerID? attacking;
  ObjectID? blocking;

  /// Arrived on the battlefield by being cast ("if you cast it").
  bool wasCast = false;

  /// Nyota Uhura: the number chosen as it entered.
  int? chosenNumber;

  /// Entered as a copy of this card (Dominion Saboteur); the printed card is `cardID`.
  String? copiedCardID;

  /// A copy "except it isn't legendary".
  bool nonLegendary = false;

  /// May be played from exile by `playableBy` until the end of turn `playableUntilTurn`
  /// (Reckless Impulse, Silicate Surveyor...), for `extraCost` more (Zero).
  PlayerID? playableBy;
  int playableUntilTurn = 0;
  int extraCost = 0;

  /// Effects lasting until the start of a player's next turn (V'Ger's -1/-0).
  List<LastingEffect> lasting = [];

  /// Control returns to this player at end of turn (gain control until end of turn).
  PlayerID? controlRevertsTo;

  /// Phased out: treated as though it doesn't exist.
  bool phasedOut = false;

  /// "If that creature would die this turn, exile it instead."
  bool exileIfDiesThisTurn = false;

  /// Q: an exiled card that can be copied by exiling a card from hand.
  bool qCopyable = false;

  /// Charge counters were put on it this turn (Enterprise-D's "first time each turn").
  bool chargedThisTurn = false;

  /// Seven of Nine: base power and toughness set by an ability.
  int? basePowerOverride, baseToughnessOverride;

  /// Kobayashi Maru: modes already chosen.
  Set<int> usedModes = {};

  /// Exiled "until ~ leaves the battlefield".
  List<ObjectID> exiledUntilLeaves = [];

  /// Temporary creature types ("becomes a Doctor").
  List<String> addedTypes = [];

  bool get isToken => token != null;
  int get plusOneCounters => counters[CounterKind.plusOne] ?? 0;
  int get chargeCounters => counters[CounterKind.charge] ?? 0;

  /// Canonical text for state digests.
  String digest() =>
      '$id|$cardID|$owner|${zone.name}|$controller|$tapped|$damage|${(counters.entries.map((e) => '${e.key.name}=${e.value}').toList()..sort()).join(',')}|$enteredTurn|$attachedTo|${untilEndOfTurn.map((e) => e.digest()).join(',')}|$frozen|$sacrificeAtEnd|${(activatedThisTurn.toList()..sort()).join(',')}|${exiledWithThis.join(',')}|$assimilated|$attacking|$blocking|${token == null ? '' : token!.props.toString()}|$wasCast|$chosenNumber|$copiedCardID|$nonLegendary|$playableBy|$playableUntilTurn|$extraCost|${lasting.map((e) => e.digest()).join(',')}|$controlRevertsTo|$phasedOut|$exileIfDiesThisTurn|$qCopyable|$chargedThisTurn|$basePowerOverride|$baseToughnessOverride|${(usedModes.toList()..sort()).join(',')}|${exiledUntilLeaves.join(',')}';
}

/// A temporary effect that lasts until `untilTurnOf`'s next turn begins.
class LastingEffect {
  LastingEffect(this.effect, this.untilTurnOf);
  final TemporaryEffect effect;
  final PlayerID untilTurnOf;
  String digest() => '${effect.digest()}@$untilTurnOf';
}

sealed class TemporaryEffect with Props {
  const TemporaryEffect();
  String digest();
}

class PumpEffect extends TemporaryEffect {
  const PumpEffect(this.power, this.toughness);
  final int power, toughness;
  @override
  List<Object?> get props => [power, toughness];
  @override
  String digest() => 'pump$power/$toughness';
}

class KeywordEffect extends TemporaryEffect {
  const KeywordEffect(this.keyword);
  final Keyword keyword;
  @override
  List<Object?> get props => [keyword];
  @override
  String digest() => 'kw${keyword.kind.name}${keyword.value}';
}

class CantBlockEffect extends TemporaryEffect {
  const CantBlockEffect();
  @override
  List<Object?> get props => const [];
  @override
  String digest() => 'cantblock';
}

/// "becomes a Doctor" (replace) / "become Warriors in addition to their other types".
class TypeEffect extends TemporaryEffect {
  const TypeEffect(this.subtype, {this.replace = false});
  final String subtype;
  final bool replace;
  @override
  List<Object?> get props => [subtype, replace];
  @override
  String digest() => 'type$subtype$replace';
}

class PlayerState {
  PlayerState({required this.id, required this.name, this.isBot = false});
  final PlayerID id;
  String name;
  int life = 20;
  List<ObjectID> library = []; // index 0 is the top
  List<ObjectID> hand = [];
  List<ObjectID> battlefield = [];
  List<ObjectID> graveyard = [];
  List<ObjectID> exile = [];
  int landsPlayedThisTurn = 0;
  bool noMaxHandSizeUntilNextTurn = false;
  int mulligans = 0;
  bool keptHand = false;
  bool isBot;
  bool lost = false;
  int spellsCastThisTurn = 0;
  int lifeGainedThisTurn = 0;
  int noncreatureSpellsThisTurn = 0;
  int spellsCastThisGame = 0;
  int permanentsReturnedToHandThisTurn = 0;
  int cardsDrawnThisTurn = 0;
  int dilemmasThisTurn = 0;
  int opponentsAttackedThisTurn = 0;

  /// The Holodeck's once-per-turn play from the graveyard is used.
  bool usedGraveyardPlayThisTurn = false;

  /// Brad Boimler: counters put on your permanents get one more until end of turn.
  bool extraCounterThisTurn = false;

  /// Peace in Our Time: took the offered card, so can't attack this turn.
  bool cantAttackThisTurn = false;

  /// Mana added by abilities like Starfleet Academy's, by color symbol ('C' colorless), spent
  /// before tapping sources and emptied as steps end.
  Map<String, int> manaPool = {};

  String digest() =>
      '$id|$name|$life|${library.join(',')}|${hand.join(',')}|${battlefield.join(',')}|${graveyard.join(',')}|${exile.join(',')}|$landsPlayedThisTurn|$noMaxHandSizeUntilNextTurn|$mulligans|$keptHand|$lost|$spellsCastThisTurn|$noncreatureSpellsThisTurn|$spellsCastThisGame|$permanentsReturnedToHandThisTurn|$cardsDrawnThisTurn|$dilemmasThisTurn|$opponentsAttackedThisTurn|$usedGraveyardPlayThisTurn|$extraCounterThisTurn|$cantAttackThisTurn|${(manaPool.entries.map((e) => '${e.key}${e.value}').toList()..sort()).join(',')}';
}

enum Phase {
  untap('Untap'),
  upkeep('Upkeep'),
  draw('Draw'),
  main1('Main Phase 1'),
  beginCombat('Begin Combat'),
  declareAttackers('Declare Attackers'),
  declareBlockers('Declare Blockers'),
  combatDamage('Combat Damage'),
  endCombat('End Combat'),
  main2('Main Phase 2'),
  end('End Step'),
  cleanup('Cleanup');

  const Phase(this.label);
  final String label;
  bool get isMain => this == main1 || this == main2;
}

/// Something the game needs from a player before it can go on.
sealed class Decision {
  const Decision();
}

class MulliganDecision extends Decision {
  const MulliganDecision();
}

/// London mulligan: after drawing a full hand, put [count] cards on the bottom of the library.
class ChooseBottomDecision extends Decision {
  const ChooseBottomDecision(this.count);
  final int count;
}

class DeclareBlockersDecision extends Decision {
  const DeclareBlockersDecision(this.attackers);
  final List<ObjectID> attackers;
}

class ChooseTargetsDecision extends Decision {
  const ChooseTargetsDecision({required this.prompt, required this.filter, required this.count, required this.optional, required this.candidates});
  final String prompt;
  final Filter filter;
  final int count;
  final bool optional;
  final List<ObjectID> candidates;
}

class ChooseModeDecision extends Decision {
  const ChooseModeDecision(this.prompt, this.modes);
  final String prompt;
  final List<String> modes;
}

class ChooseOptionalDecision extends Decision {
  const ChooseOptionalDecision(this.prompt);
  final String prompt;
}

class DiscardToHandSizeDecision extends Decision {
  const DiscardToHandSizeDecision(this.count);
  final int count;
}

class ChooseSacrificeDecision extends Decision {
  const ChooseSacrificeDecision(this.prompt, this.candidates);
  final String prompt;
  final List<ObjectID> candidates;
}

class SurveilDecision extends Decision {
  const SurveilDecision(this.cards);
  final List<ObjectID> cards;
}

class ScryDecision extends Decision {
  const ScryDecision(this.cards);
  final List<ObjectID> cards;
}

class ExploreDecision extends Decision {
  const ExploreDecision(this.card, this.creature);
  final ObjectID card, creature;
}

/// "Counter target spell unless its controller pays {3}": the spell's controller decides.
class PayOrCounterDecision extends Decision {
  const PayOrCounterDecision(this.prompt, this.cost, this.spell);
  final String prompt;
  final ManaCost cost;
  final ObjectID spell;
}

/// Choose between `min` and `max` of these cards (from a library, a hand or exile).
class ChooseCardsDecision extends Decision {
  const ChooseCardsDecision(this.prompt, this.cards, {this.min = 0, this.max = 1});
  final String prompt;
  final List<ObjectID> cards;
  final int min, max;
}

/// Choose one or more modes (answered with CardsResponse holding mode indices).
class ChooseModesDecision extends Decision {
  const ChooseModesDecision(this.prompt, this.modes, {this.min = 1, this.max = 1});
  final String prompt;
  final List<String> modes;
  final int min, max;
}

class DiscoverDecision extends Decision {
  const DiscoverDecision(this.card);
  final ObjectID card;
}

/// What a player answers a `Decision` with. Serialised inside actions.
sealed class DecisionResponse with Props {
  const DecisionResponse();

  Map<String, dynamic> toJson();

  static DecisionResponse fromJson(Map<String, dynamic> j) {
    switch (j['t'] as String) {
      case 'keep':
        return const KeepResponse();
      case 'mulligan':
        return const MulliganResponse();
      case 'blockers':
        return BlockersResponse({for (final e in (j['b'] as Map).entries) int.parse(e.key as String): e.value as int});
      case 'targets':
        return TargetsResponse((j['ids'] as List).cast<int>());
      case 'mode':
        return ModeResponse(j['i'] as int);
      case 'yes':
        return const YesResponse();
      case 'no':
        return const NoResponse();
      case 'cards':
        return CardsResponse((j['ids'] as List).cast<int>());
      case 'sacrifice':
        return SacrificeResponse(j['id'] as int);
      case 'explore':
        return ExploreResponse(j['g'] as bool);
      case 'discover':
        return DiscoverResponse(j['p'] as bool);
    }
    throw ArgumentError('Unknown response ${j['t']}');
  }
}

class KeepResponse extends DecisionResponse {
  const KeepResponse();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'keep'};
}

class MulliganResponse extends DecisionResponse {
  const MulliganResponse();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'mulligan'};
}

class BlockersResponse extends DecisionResponse {
  const BlockersResponse(this.blocks); // blocker -> attacker
  final Map<ObjectID, ObjectID> blocks;
  @override
  List<Object?> get props => [blocks];
  @override
  Map<String, dynamic> toJson() => {
    't': 'blockers',
    'b': {for (final e in blocks.entries) '${e.key}': e.value},
  };
}

class TargetsResponse extends DecisionResponse {
  const TargetsResponse(this.ids);
  final List<ObjectID> ids;
  @override
  List<Object?> get props => [ids];
  @override
  Map<String, dynamic> toJson() => {'t': 'targets', 'ids': ids};
}

class ModeResponse extends DecisionResponse {
  const ModeResponse(this.index);
  final int index;
  @override
  List<Object?> get props => [index];
  @override
  Map<String, dynamic> toJson() => {'t': 'mode', 'i': index};
}

class YesResponse extends DecisionResponse {
  const YesResponse();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'yes'};
}

class NoResponse extends DecisionResponse {
  const NoResponse();
  @override
  List<Object?> get props => const [];
  @override
  Map<String, dynamic> toJson() => {'t': 'no'};
}

class CardsResponse extends DecisionResponse {
  const CardsResponse(this.ids); // discard / surveil-to-graveyard / scry-to-bottom
  final List<ObjectID> ids;
  @override
  List<Object?> get props => [ids];
  @override
  Map<String, dynamic> toJson() => {'t': 'cards', 'ids': ids};
}

class SacrificeResponse extends DecisionResponse {
  const SacrificeResponse(this.id);
  final ObjectID id;
  @override
  List<Object?> get props => [id];
  @override
  Map<String, dynamic> toJson() => {'t': 'sacrifice', 'id': id};
}

class ExploreResponse extends DecisionResponse {
  const ExploreResponse(this.toGraveyard);
  final bool toGraveyard;
  @override
  List<Object?> get props => [toGraveyard];
  @override
  Map<String, dynamic> toJson() => {'t': 'explore', 'g': toGraveyard};
}

class DiscoverResponse extends DecisionResponse {
  const DiscoverResponse(this.play);
  final bool play;
  @override
  List<Object?> get props => [play];
  @override
  Map<String, dynamic> toJson() => {'t': 'discover', 'p': play};
}

/// The continuation of an interrupted effect sequence.
class Resume {
  Resume({
    required this.source,
    required this.controller,
    required this.effects,
    required this.context,
    required this.kind,
    this.modes,
    this.optionalEffects,
    this.sacrificeFilter,
    this.subject,
    this.effect,
    List<ObjectID>? cards,
  }) : cards = cards ?? [];
  ObjectID? source;
  PlayerID controller;
  List<Effect> effects;
  EffectContext context;
  ResumeKind kind;
  List<List<Effect>>? modes;
  List<Effect>? optionalEffects;
  Filter? sacrificeFilter;

  /// The object a decision is about (the spell a pay-or-counter decision may counter).
  ObjectID? subject;

  /// The effect waiting on this choice, and the cards it is choosing among.
  Effect? effect;
  List<ObjectID> cards;
}

enum ResumeKind {
  targets,
  mode,
  optional,
  surveil,
  scry,
  explore,
  discover,
  sacrifice,
  none,
  cleanup,
  blockers,
  mulligan,
  payOrCounter,
  chooseNumber,
  chooseCards,
  topOrBottom,
  chooseColor,
  peace,
  chooseModes,
}

/// A spell waiting to resolve. Abilities resolve at once; only spells use the stack, which is
/// what lets the other player respond to them (and counter them).
class StackItem {
  StackItem({required this.id, required this.controller, required this.effects, required this.context, this.fromGraveyard = false, this.x = 0, this.sunburst = 0});

  /// The card object, now in Zone.stack.
  final ObjectID id;
  final PlayerID controller;

  /// What an instant or sorcery does (the chosen mode already picked); empty for a permanent.
  final List<Effect> effects;
  final EffectContext context;

  /// Cast with Beam me up: exiled instead of going to the graveyard.
  final bool fromGraveyard;
  final int x;

  /// Colors of mana spent to cast it (Sunburst).
  final int sunburst;

  /// Whether the other player has had their chance to respond.
  bool windowOffered = false;

  String digest() => '$id:$controller:$fromGraveyard:$x:$sunburst:$windowOffered:${context.targets.join(',')}:${context.kicked}';
}

/// "When that creature dies this turn, ...", "At the beginning of the next combat this turn, ...".
enum DelayedEvent { dies, nextCombat }

class DelayedTrigger {
  DelayedTrigger({required this.event, required this.object, required this.controller, required this.source, required this.effects, required this.turn});
  final DelayedEvent event;
  final ObjectID object;
  final PlayerID controller;
  final ObjectID source;
  final List<Effect> effects;

  /// Only during this turn.
  final int turn;
  String digest() => '${event.name}:$object:$controller:$source:${effects.length}:$turn';
}

/// A triggered ability waiting for an open decision to finish.
class QueuedTrigger {
  QueuedTrigger({required this.source, required this.controller, required this.effects, required this.context});
  final ObjectID source;
  final PlayerID controller;
  final List<Effect> effects;
  final EffectContext context;
}

class PendingDecision {
  PendingDecision({required this.player, required this.decision, required this.resume});
  final PlayerID player;
  final Decision decision;
  final Resume resume;
}

/// Targets chosen and the last thing an effect touched, carried through an effect list.
class EffectContext {
  EffectContext();
  List<ObjectID> targets = [];
  ObjectID? lastTouched;
  bool kicked = false;
  bool previousHappened = true;

  /// The value chosen for X when the spell was cast.
  int x = 0;

  /// A number carried by the triggering event (combat damage dealt...).
  int eventAmount = 0;

  /// Objects an effect affected, for "each of those creatures" and "this way" counts.
  List<ObjectID> affected = [];

  /// How many things the last counting effect did "this way".
  int counted = 0;

  /// Creature types of what was sacrificed to pay for this ("If you sacrificed a Klingon").
  Set<String> sacrificedSubtypes = {};

  /// Which time this ability has resolved this turn (Captain Burnham).
  int resolution = 0;
  ObjectID? triggeringObject;

  static ObjectID playerObject(PlayerID p) => -1 - p;
  static PlayerID? playerFromObject(ObjectID id) => id < 0 ? -1 - id : null;

  EffectContext copy() => EffectContext()
    ..targets = List.of(targets)
    ..lastTouched = lastTouched
    ..kicked = kicked
    ..previousHappened = previousHappened
    ..x = x
    ..eventAmount = eventAmount
    ..affected = List.of(affected)
    ..counted = counted
    ..sacrificedSubtypes = Set.of(sacrificedSubtypes)
    ..resolution = resolution
    ..triggeringObject = triggeringObject;
}

class CombatState {
  List<ObjectID> attackers = [];
  Map<ObjectID, ObjectID> blockers = {}; // blocker -> attacker
  PlayerID defender = 1;
}

/// What happened, for the log and for animating the table.
class GameEvent {
  GameEvent(this.kind, {this.player, this.object, this.other, this.amount, this.text, this.ids, this.map, this.phase, this.counter});
  final String kind;
  final PlayerID? player;
  final ObjectID? object;
  final ObjectID? other; // source / target / attacker
  final int? amount;
  final String? text;
  final List<ObjectID>? ids;
  final Map<ObjectID, ObjectID>? map;
  final Phase? phase;
  final CounterKind? counter;

  String digest() => '$kind:$player:$object:$other:$amount:$text:${ids?.join(',')}:${map?.entries.map((e) => '${e.key}>${e.value}').toList()?..sort()}:${phase?.name}:${counter?.name}';

  @override
  String toString() => digest();
}

enum TurnStep { drawStep, main1, attackWindow, blockers, blockWindowActive, blockWindowDefender, combatDamage, main2, endStep, endWindow, cleanup, nextTurn }

class GameState {
  GameState({required List<String> playerNames, List<bool>? bots, required int seed}) : rng = SeededRng(seed) {
    players = [for (var i = 0; i < playerNames.length; i++) PlayerState(id: i, name: playerNames[i], isBot: bots != null && i < bots.length && bots[i])];
  }

  late List<PlayerState> players;
  Rules rules = Rules.standard;
  final Map<ObjectID, GameObject> objects = {};
  int nextObjectID = 1;
  int turn = 0;
  PlayerID activePlayer = 0;
  Phase phase = Phase.untap;
  CombatState combat = CombatState();
  PendingDecision? pending;
  SeededRng rng;
  PlayerID? winner;
  bool started = false;
  List<GameEvent> log = [];
  int actionCount = 0;
  PlayerID startingPlayer = 0;
  List<TurnStep> turnContinuation = [];

  /// Spells cast and not yet resolved, last one on top.
  List<StackItem> stack = [];

  /// Triggers that fired while a decision was open, resolved in order once it closes.
  List<QueuedTrigger> queuedTriggers = [];

  /// Keys of "only once each turn" triggers that already fired this turn.
  Set<String> firedThisTurn = {};

  /// Delayed triggers set up this turn.
  List<DelayedTrigger> delayed = [];

  /// How many times an ability resolved this turn, by key (Captain Burnham's "second time").
  Map<String, int> resolvedCounts = {};

  /// The player who may respond right now (cast an instant, or pass), when it isn't simply the
  /// active player's turn to act.
  PlayerID? priority;

  bool get isOver => winner != null;
  int get playerCount => players.length;
  PlayerID opponentOf(PlayerID p) => (p + 1) % players.length;

  /// The player who has to act right now.
  PlayerID? get playerToAct {
    if (isOver) return null;
    final p = pending;
    if (p != null) return p.player;
    return priority ?? activePlayer;
  }

  GameObject? object(ObjectID id) => objects[id];

  /// The permanents a player controls, leaving out phased-out ones (which are treated as though
  /// they don't exist).
  List<GameObject> permanentsOf(PlayerID p) => [
    for (final id in players[p].battlefield)
      if (objects[id] != null && !objects[id]!.phasedOut) objects[id]!,
  ];

  /// Every permanent on a player's side, phased out or not.
  List<GameObject> allOnBattlefieldOf(PlayerID p) => [
    for (final id in players[p].battlefield)
      if (objects[id] != null) objects[id]!,
  ];
  List<GameObject> get allPermanents => [for (final p in players) ...permanentsOf(p.id)];

  /// A canonical fingerprint of everything that matters for lockstep: two devices that agree on
  /// this after each action are in sync.
  String digest() {
    final b = StringBuffer();
    b.writeln(
      'turn=$turn active=$activePlayer phase=${phase.name} rng=${rng.state} next=$nextObjectID winner=$winner started=$started actions=$actionCount pending=${pending?.decision.runtimeType} rules=${rules.digest()}',
    );
    for (final p in players) {
      b.writeln(p.digest());
    }
    final ids = objects.keys.toList()..sort();
    for (final id in ids) {
      b.writeln(objects[id]!.digest());
    }
    b.writeln('combat=${combat.attackers.join(',')}|${(combat.blockers.entries.map((e) => '${e.key}>${e.value}').toList()..sort()).join(',')}|${combat.defender}');
    b.writeln('cont=${turnContinuation.map((s) => s.name).join(',')}');
    b.writeln('stack=${stack.map((s) => s.digest()).join(';')} priority=$priority');
    b.writeln('queued=${queuedTriggers.map((q) => '${q.source}:${q.effects.length}').join(',')} fired=${(firedThisTurn.toList()..sort()).join(',')}');
    b.writeln('delayed=${delayed.map((d) => d.digest()).join(',')} resolved=${(resolvedCounts.entries.map((e) => '${e.key}=${e.value}').toList()..sort()).join(',')}');
    return b.toString();
  }
}
