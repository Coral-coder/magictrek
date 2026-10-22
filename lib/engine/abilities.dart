import 'cards.dart';
import 'props.dart';

// The vocabulary the engine understands. The parser turns a card's rules text into these;
// anything it can't express is kept as `Unsupported` so the card still plays with the rest.

enum KeywordKind {
  flying('flying'),
  firstStrike('first strike'),
  doubleStrike('double strike'),
  deathtouch('deathtouch'),
  lifelink('lifelink'),
  trample('trample'),
  haste('haste'),
  vigilance('vigilance'),
  menace('menace'),
  reach('reach'),
  defender('defender'),
  flash('flash'),
  indestructible('indestructible'),
  hexproof('hexproof'),
  ward('ward'),
  station('station'),
  unblockable("can't be blocked"),
  cantBlock("can't block"),
  mustAttack('attacks each combat if able'),

  /// "can't be blocked by creatures with power N or less" (value = N).
  evadesSmall("can't be blocked by small creatures"),

  /// "can't be blocked by more than one creature".
  oneBlocker("can't be blocked by more than one creature");

  const KeywordKind(this.text);
  final String text;
  static KeywordKind? fromText(String t) {
    for (final k in values) {
      if (k.text == t) return k;
    }
    return null;
  }
}

class Keyword with Props {
  const Keyword(this.kind, [this.value = 0]);
  final KeywordKind kind;

  /// Ward's cost; otherwise 0.
  final int value;

  static const flying = Keyword(KeywordKind.flying);
  static const firstStrike = Keyword(KeywordKind.firstStrike);
  static const doubleStrike = Keyword(KeywordKind.doubleStrike);
  static const deathtouch = Keyword(KeywordKind.deathtouch);
  static const lifelink = Keyword(KeywordKind.lifelink);
  static const trample = Keyword(KeywordKind.trample);
  static const haste = Keyword(KeywordKind.haste);
  static const vigilance = Keyword(KeywordKind.vigilance);
  static const menace = Keyword(KeywordKind.menace);
  static const reach = Keyword(KeywordKind.reach);
  static const defender = Keyword(KeywordKind.defender);
  static const flash = Keyword(KeywordKind.flash);
  static const indestructible = Keyword(KeywordKind.indestructible);
  static const hexproof = Keyword(KeywordKind.hexproof);
  static const unblockable = Keyword(KeywordKind.unblockable);
  static const cantBlock = Keyword(KeywordKind.cantBlock);
  static const station = Keyword(KeywordKind.station);

  @override
  List<Object?> get props => [kind, value];

  @override
  String toString() {
    if (kind == KeywordKind.ward) return 'Ward {$value}';
    if (kind == KeywordKind.evadesSmall) return "Can't be blocked by creatures with power $value or less";
    return kind.text[0].toUpperCase() + kind.text.substring(1);
  }
}

/// How many: usually a number; sometimes counted from the board.
enum AmountKind {
  fixed,
  creaturesYouControl,
  artifactsYouControl,
  artifactCreaturesYouControl,
  landsYouControl,
  cardsInHand,
  differentlyNamedLands,
  thisPower,

  /// Federation: the number of creature types among non-Borg creatures you control.
  creatureTypesNonBorg,

  /// The X paid when the spell was cast.
  x,
  twiceX,

  /// A number carried by the trigger (combat damage dealt...).
  eventAmount,

  /// Artifact and/or creature cards in your graveyard.
  artifactOrCreatureCardsInGraveyard,

  /// Dilemmas (modes chosen) you've faced this turn.
  dilemmasThisTurn,

  /// Opponents attacked this turn.
  opponentsAttacked,

  /// Permanents of a creature type you control ("the number of Officers you control").
  subtypeYouControl,

  /// How many things the previous effect affected "this way".
  countedThisWay,

  /// Other creatures you control with a Communicator attached.
  otherCreaturesWithCommunicator,
}

class Amount with Props {
  const Amount.fixed(this.n) : kind = AmountKind.fixed, subtype = null;
  const Amount.counted(this.kind, {this.subtype}) : n = 0;
  final AmountKind kind;
  final int n;

  /// For `AmountKind.subtypeYouControl`: "the number of Officers you control".
  final String? subtype;
  static const one = Amount.fixed(1);
  static const zero = Amount.fixed(0);
  @override
  List<Object?> get props => [kind, n, subtype];
  @override
  String toString() => kind == AmountKind.fixed ? '$n' : kind.name;
}

enum Controller { any, you, opponent }

enum FilterKind {
  creature,
  player,
  opponent,
  creatureOrPlayer,
  permanent,
  nonlandPermanent,
  artifact,
  enchantment,
  artifactOrEnchantment,
  land,
  spacecraft,
  creatureOrSpacecraft,
  artifactCreature,
  token,
  creatureToken,
  creatureCardInGraveyard,
  basicLandCardInLibrary,
  artifactOrCreature,
  spell,

  /// Any card in a graveyard / a permanent card in a graveyard.
  cardInGraveyard,
  permanentCardInGraveyard,
}

/// Which permanents or players something applies to.
class Filter with Props {
  Filter(this.kind, {this.controller = Controller.any});
  FilterKind kind;
  Controller controller;
  bool other = false; // "another creature": not this one
  bool legendary = false, nonBorg = false, enteredThisTurn = false, historic = false;
  bool attacking = false, tapped = false, untapped = false, nontoken = false, nonartifact = false, blocking = false, withCounters = false;
  String? subtype; // "target Klingon"
  int? maxPower, minPower, maxManaValue, minManaValue;

  static Filter get creature => Filter(FilterKind.creature);
  static Filter get anyTarget => Filter(FilterKind.creatureOrPlayer);
  static Filter get player => Filter(FilterKind.player);
  static Filter get opponent => Filter(FilterKind.opponent);
  static Filter get permanent => Filter(FilterKind.permanent);

  bool get isPlayerFilter => kind == FilterKind.player || kind == FilterKind.opponent;

  Filter copy() => Filter(kind, controller: controller)
    ..other = other
    ..attacking = attacking
    ..tapped = tapped
    ..untapped = untapped
    ..nontoken = nontoken
    ..nonartifact = nonartifact
    ..blocking = blocking
    ..withCounters = withCounters
    ..legendary = legendary
    ..nonBorg = nonBorg
    ..enteredThisTurn = enteredThisTurn
    ..historic = historic
    ..subtype = subtype
    ..maxPower = maxPower
    ..minPower = minPower
    ..maxManaValue = maxManaValue
    ..minManaValue = minManaValue;

  @override
  List<Object?> get props => [
    kind,
    controller,
    other,
    attacking,
    tapped,
    untapped,
    nontoken,
    nonartifact,
    blocking,
    withCounters,
    legendary,
    nonBorg,
    enteredThisTurn,
    historic,
    subtype,
    maxPower,
    minPower,
    maxManaValue,
    minManaValue,
  ];

  @override
  String toString() => 'Filter(${kind.name}${controller != Controller.any ? ' ${controller.name}' : ''}${subtype != null ? ' $subtype' : ''})';
}

/// Who or what an effect hits.
sealed class Target with Props {
  const Target();
  static const Target thisObject = ThisTarget();
  static const Target you = YouTarget();
  static const Target lastTarget = LastTarget();
  static const Target controllerOfLastTarget = ControllerOfLastTarget();
  static const Target attachedCreature = AttachedCreatureTarget();
  static const Target triggering = TriggeringTarget();
}

class ThisTarget extends Target {
  const ThisTarget();
  @override
  List<Object?> get props => const [];
}

class YouTarget extends Target {
  const YouTarget();
  @override
  List<Object?> get props => const [];
}

class LastTarget extends Target {
  const LastTarget();
  @override
  List<Object?> get props => const [];
}

class ControllerOfLastTarget extends Target {
  const ControllerOfLastTarget();
  @override
  List<Object?> get props => const [];
}

/// The permanent or player that made a trigger fire ("that creature" in "Whenever a creature
/// you control enters, put a +1/+1 counter on that creature").
class TriggeringTarget extends Target {
  const TriggeringTarget();
  @override
  List<Object?> get props => const [];
}

class AttachedCreatureTarget extends Target {
  const AttachedCreatureTarget();
  @override
  List<Object?> get props => const [];
}

/// Chosen when cast or triggered.
class ChosenTarget extends Target {
  ChosenTarget(this.filter, {this.count = 1, this.optional = false});
  final Filter filter;
  final int count;
  final bool optional;
  @override
  List<Object?> get props => [filter, count, optional];
  @override
  String toString() => 'target $filter${count > 1 ? ' x$count' : ''}${optional ? ' (optional)' : ''}';
}

/// Every matching permanent or player.
class EachTarget extends Target {
  EachTarget(this.filter);
  final Filter filter;
  @override
  List<Object?> get props => [filter];
  @override
  String toString() => 'each $filter';
}

class TokenSpec with Props {
  TokenSpec({
    required this.name,
    this.power = 0,
    this.toughness = 0,
    List<ManaColor>? colors,
    List<String>? subtypes,
    List<Keyword>? keywords,
    this.isArtifact = false,
    this.isCreature = true,
    this.isLand = false,
    this.isLegendary = false,
    this.text = '',
  }) : colors = colors ?? [],
       subtypes = subtypes ?? [],
       keywords = keywords ?? [];

  String name;
  final int power, toughness;
  final List<ManaColor> colors;
  final List<String> subtypes;
  final List<Keyword> keywords;
  final bool isArtifact, isCreature, isLand;
  bool isLegendary;

  /// The token's own rules text ("{T}, Sacrifice ~: Add one mana of any color."), parsed like a
  /// card's.
  String text;

  static TokenSpec get treasure => TokenSpec(name: 'Treasure', subtypes: ['Treasure'], isArtifact: true, isCreature: false, text: '{T}, Sacrifice ~: Add one mana of any color.');
  static TokenSpec get clue => TokenSpec(name: 'Clue', subtypes: ['Clue'], isArtifact: true, isCreature: false, text: '{2}, Sacrifice ~: Draw a card.');
  static TokenSpec get food => TokenSpec(name: 'Food', subtypes: ['Food'], isArtifact: true, isCreature: false, text: '{2}, {T}, Sacrifice ~: You gain 3 life.');

  TokenSpec copyWith({List<Keyword>? keywords, String? name, bool? isLegendary}) => TokenSpec(
    name: name ?? this.name,
    power: power,
    toughness: toughness,
    colors: List.of(colors),
    subtypes: List.of(subtypes),
    keywords: keywords ?? List.of(this.keywords),
    isArtifact: isArtifact,
    isCreature: isCreature,
    isLand: isLand,
    isLegendary: isLegendary ?? this.isLegendary,
    text: text,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'power': power,
    'toughness': toughness,
    'colors': colors.map((c) => c.symbol).toList(),
    'subtypes': subtypes,
    'keywords': keywords.map((k) => [k.kind.name, k.value]).toList(),
    'isArtifact': isArtifact,
    'isCreature': isCreature,
    if (isLand) 'isLand': true,
    if (isLegendary) 'isLegendary': true,
    if (text.isNotEmpty) 'text': text,
  };

  factory TokenSpec.fromJson(Map<String, dynamic> j) => TokenSpec(
    name: j['name'] as String,
    power: j['power'] as int,
    toughness: j['toughness'] as int,
    colors: (j['colors'] as List).map((e) => ManaColor.fromSymbol(e as String)).whereType<ManaColor>().toList(),
    subtypes: (j['subtypes'] as List).cast<String>(),
    keywords: (j['keywords'] as List).map((e) => Keyword(KeywordKind.values.byName((e as List)[0] as String), e[1] as int)).toList(),
    isArtifact: j['isArtifact'] as bool,
    isCreature: j['isCreature'] as bool,
    isLand: j['isLand'] as bool? ?? false,
    isLegendary: j['isLegendary'] as bool? ?? false,
    text: j['text'] as String? ?? '',
  );

  @override
  List<Object?> get props => [name, power, toughness, colors, subtypes, keywords, isArtifact, isCreature, isLand, isLegendary, text];
}

enum CounterKind {
  plusOne('+1/+1'),
  minusOne('-1/-1'),
  charge('charge'),
  lore('lore'),
  finality('finality'),
  stun('stun'),
  quest('quest'),
  promotion('promotion'),
  peace('peace');

  const CounterKind(this.text);
  final String text;
}

enum EffectDuration { endOfTurn, permanent }

enum LibraryDestination { hand, battlefield, battlefieldTapped, libraryTop, libraryBottom, graveyard }

enum Condition {
  thisIsCreature,
  thisIsNotCreature,

  /// The last thing touched is a creature ("If it's a creature, ...").
  lastIsCreature,

  /// You control a permanent with a counter on it.
  controlPermanentWithCounter,

  /// This permanent has at least `n` counters of `counter` on it.
  selfCountersAtLeast,

  /// This is the `n`th time this ability resolved this turn.
  resolvedTimes,

  /// The previous effect counted at least `n` things "this way".
  countedAtLeast,

  /// Creatures you control have total power `n` or greater.
  totalPowerAtLeast,

  /// This is the first spell you've cast this game.
  firstSpellThisGame,

  /// You control at least `n` differently named lands.
  differentLandsAtLeast,

  /// The thing sacrificed or touched "this way" has the creature type `subtype`.
  lastHasSubtype,

  /// You have no cards in hand.
  handEmpty,
}

/// What an ability does. One subclass per effect kind.
sealed class Effect with Props {
  const Effect();
}

class Damage extends Effect {
  const Damage(this.amount, this.target);
  final Amount amount;
  final Target target;
  @override
  List<Object?> get props => [amount, target];
}

class Draw extends Effect {
  const Draw(this.amount, this.target);
  final Amount amount;
  final Target target;
  @override
  List<Object?> get props => [amount, target];
}

class GainLife extends Effect {
  const GainLife(this.amount, this.target);
  final Amount amount;
  final Target target;
  @override
  List<Object?> get props => [amount, target];
}

class LoseLife extends Effect {
  const LoseLife(this.amount, this.target);
  final Amount amount;
  final Target target;
  @override
  List<Object?> get props => [amount, target];
}

class Destroy extends Effect {
  const Destroy(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Exile extends Effect {
  const Exile(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Bounce extends Effect {
  const Bounce(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Tap extends Effect {
  const Tap(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Untap extends Effect {
  const Untap(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Pump extends Effect {
  const Pump(this.power, this.toughness, this.target, this.duration);
  final int power, toughness;
  final Target target;
  final EffectDuration duration;
  @override
  List<Object?> get props => [power, toughness, target, duration];
}

class AddCounters extends Effect {
  const AddCounters(this.kind, this.amount, this.target, {this.distribute = false});
  final CounterKind kind;
  final Amount amount;
  final Target target;

  /// "Distribute two +1/+1 counters among one or two target creatures": the amount is split
  /// between the targets (each gets at least one) instead of going on each of them.
  final bool distribute;
  @override
  List<Object?> get props => [kind, amount, target, distribute];
}

class CreateTokens extends Effect {
  const CreateTokens(this.spec, this.amount, this.target, {this.tapped = false, this.sacrificeAtEnd = false});
  final TokenSpec spec;
  final Amount amount;
  final Target target; // who gets them
  final bool tapped;

  /// "Sacrifice it at the beginning of the next end step."
  final bool sacrificeAtEnd;
  @override
  List<Object?> get props => [spec, amount, target, tapped, sacrificeAtEnd];
}

class Surveil extends Effect {
  const Surveil(this.n);
  final int n;
  @override
  List<Object?> get props => [n];
}

class Scry extends Effect {
  const Scry(this.n);
  final int n;
  @override
  List<Object?> get props => [n];
}

class Mill extends Effect {
  const Mill(this.n, this.target);
  final int n;
  final Target target;
  @override
  List<Object?> get props => [n, target];
}

class Discard extends Effect {
  const Discard(this.n, this.target);
  final int n;
  final Target target;
  @override
  List<Object?> get props => [n, target];
}

class SearchBasicLand extends Effect {
  const SearchBasicLand(this.destination, this.target);
  final LibraryDestination destination;
  final Target target; // whose library
  @override
  List<Object?> get props => [destination, target];
}

class Sacrifice extends Effect {
  const Sacrifice(this.target, this.filter);
  final Target target; // the player(s) who sacrifice
  final Filter filter;
  @override
  List<Object?> get props => [target, filter];
}

class GrantKeyword extends Effect {
  const GrantKeyword(this.keyword, this.target, this.duration);
  final Keyword keyword;
  final Target target;
  final EffectDuration duration;
  @override
  List<Object?> get props => [keyword, target, duration];
}

class ReturnFromGraveyard extends Effect {
  const ReturnFromGraveyard(this.filter, this.destination, {this.underOwnersControl = false, this.counter});
  final Filter filter;
  final LibraryDestination destination;

  /// General Picard: "onto the battlefield under its owner's control".
  final bool underOwnersControl;

  /// "with a finality counter on it".
  final CounterKind? counter;
  @override
  List<Object?> get props => [filter, destination, underOwnersControl, counter];
}

class Fight extends Effect {
  const Fight(this.target); // this fights the target
  final Target target;
  @override
  List<Object?> get props => [target];
}

class FightBetween extends Effect {
  const FightBetween(this.a, this.b);
  final Target a, b;
  @override
  List<Object?> get props => [a, b];
}

class Bite extends Effect {
  const Bite(this.target); // this deals damage equal to its power
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Explore extends Effect {
  const Explore(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class AddMana extends Effect {
  const AddMana(this.colors);
  final List<ManaColor> colors; // choose one; empty = colorless
  @override
  List<Object?> get props => [colors];
}

class DoubleLife extends Effect {
  const DoubleLife();
  @override
  List<Object?> get props => const [];
}

class NoMaxHandSize extends Effect {
  const NoMaxHandSize();
  @override
  List<Object?> get props => const [];
}

class PutLandFromHand extends Effect {
  const PutLandFromHand(this.tapped);
  final bool tapped;
  @override
  List<Object?> get props => [tapped];
}

class Modal extends Effect {
  const Modal(this.modes, {this.labels = const [], this.unchosenOnly = false, this.oneOrMoreIfHandEmpty = false});
  final List<List<Effect>> modes;

  /// The modes' names ("Hail", "Sensors"...), when they have them.
  final List<String> labels;

  /// Kobayashi Maru: "choose one that hasn't been chosen".
  final bool unchosenOnly;

  /// Captain Kirk: "If you have no cards in hand, choose one or more instead."
  final bool oneOrMoreIfHandEmpty;
  @override
  List<Object?> get props => [modes, labels, unchosenOnly, oneOrMoreIfHandEmpty];
}

class Optional extends Effect {
  const Optional(this.effects);
  final List<Effect> effects;
  @override
  List<Object?> get props => [effects];
}

class CantBlock extends Effect {
  const CantBlock(this.target, this.duration);
  final Target target;
  final EffectDuration duration;
  @override
  List<Object?> get props => [target, duration];
}

class GainControl extends Effect {
  const GainControl(this.target, {this.untilEndOfTurn = false});
  final Target target;
  final bool untilEndOfTurn;
  @override
  List<Object?> get props => [target, untilEndOfTurn];
}

class SacrificeAtEndOfTurn extends Effect {
  const SacrificeAtEndOfTurn(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class KickedInstead extends Effect {
  const KickedInstead(this.effects);
  final List<Effect> effects;
  @override
  List<Object?> get props => [effects];
}

class IfDidPrevious extends Effect {
  const IfDidPrevious(this.effects);
  final List<Effect> effects;
  @override
  List<Object?> get props => [effects];
}

class Assimilate extends Effect {
  const Assimilate(this.filter);
  final Filter filter;
  @override
  List<Object?> get props => [filter];
}

class AssimilateFromLibrary extends Effect {
  const AssimilateFromLibrary(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class AssimilateExiledOrExile extends Effect {
  const AssimilateExiledOrExile(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class Discover extends Effect {
  const Discover(this.n);
  final int n;
  @override
  List<Object?> get props => [n];
}

class PayLife extends Effect {
  const PayLife(this.n);
  final int n;
  @override
  List<Object?> get props => [n];
}

class PayMana extends Effect {
  const PayMana(this.cost);
  final ManaCost cost;
  @override
  List<Object?> get props => [cost];
}

class CopyToken extends Effect {
  const CopyToken(this.target, this.extra, {this.nonLegendary = false, this.tapped = false, this.hasteUntilEndOfTurn = false, this.sacrificeAtEnd = false, this.eachCreatureOfTarget = false});
  final Target target;
  final List<Keyword> extra;
  final bool nonLegendary, tapped, hasteUntilEndOfTurn, sacrificeAtEnd;

  /// "for each creature target opponent controls, create a token that's a copy of that creature".
  final bool eachCreatureOfTarget;
  @override
  List<Object?> get props => [target, extra, nonLegendary, tapped, hasteUntilEndOfTurn, sacrificeAtEnd, eachCreatureOfTarget];
}

class Conditional extends Effect {
  const Conditional(this.condition, this.effects, {this.otherwise = const [], this.n = 0, this.counter, this.subtype, this.negate = false});
  final Condition condition;
  final List<Effect> effects;

  /// What happens when the condition fails ("... instead").
  final List<Effect> otherwise;
  final int n;
  final CounterKind? counter;
  final String? subtype;

  /// "unless": run the effects when the condition is false.
  final bool negate;
  @override
  List<Object?> get props => [condition, effects, otherwise, n, counter, subtype, negate];
}

/// Counter target spell (unless its controller pays a cost).
class CounterSpell extends Effect {
  const CounterSpell(this.target, {this.unlessPays});
  final Target target;
  final ManaCost? unlessPays;
  @override
  List<Object?> get props => [target, unlessPays];
}

/// What kind of card a library or graveyard search may pick.
class CardPred with Props {
  const CardPred({
    this.types = const [],
    this.notTypes = const [],
    this.subtypes = const [],
    this.names = const [],
    this.maxManaValue,
    this.permanent = false,
    this.nonland = false,
    this.basicLand = false,
    this.or,
  });

  /// All of these types ("Creature"); `or` widens it ("a Plains card or nonland permanent card").
  final List<String> types;
  final List<String> notTypes;

  /// Any of these subtypes ("Klingon or Warrior").
  final List<String> subtypes;
  final List<String> names;
  final int? maxManaValue;
  final bool permanent, nonland, basicLand;
  final CardPred? or;
  static const any = CardPred();
  @override
  List<Object?> get props => [types, notTypes, subtypes, names, maxManaValue, permanent, nonland, basicLand, or];
}

enum RestDestination { bottomRandom, bottom, graveyard, top }

/// "Look at the top N cards of your library. You may put a ... from among them into your hand.
/// Put the rest on the bottom in a random order."
class LookAtTop extends Effect {
  const LookAtTop(this.n, this.pick, {this.pickCount = 1, this.destination = LibraryDestination.hand, this.rest = RestDestination.bottomRandom, this.optional = true, this.fromAffected = false});
  final Amount n;
  final CardPred pick;
  final int pickCount;
  final LibraryDestination destination;
  final RestDestination rest;
  final bool optional;

  /// Pick among the cards the previous effect affected (First Contact's milled cards) instead.
  final bool fromAffected;
  @override
  List<Object?> get props => [n, pick, pickCount, destination, rest, optional, fromAffected];
}

/// Exile the top N cards of your library; you may play them this turn or until the end of your
/// next turn.
class ExileTopPlayable extends Effect {
  const ExileTopPlayable(this.n, {this.untilNextTurn = false});
  final Amount n;
  final bool untilNextTurn;
  @override
  List<Object?> get props => [n, untilNextTurn];
}

/// Deep Space 9: exile the top N; put all permanent cards exiled this way onto the battlefield.
class ExileTopPutPermanents extends Effect {
  const ExileTopPutPermanents(this.n);
  final int n;
  @override
  List<Object?> get props => [n];
}

/// Commander Spock: reveal the top card; cast it free if its mana value is at most `max`, or put
/// a land onto the battlefield tapped; if it's still on top, draw a card.
class RevealTopCastFree extends Effect {
  const RevealTopCastFree(this.max);
  final Amount max;
  @override
  List<Object?> get props => [max];
}

/// Search your library (and/or graveyard) for a card and put it somewhere.
class SearchCard extends Effect {
  const SearchCard(this.pick, this.destination, {this.alsoGraveyard = false, this.counter, this.counterAmount = 0});
  final CardPred pick;
  final LibraryDestination destination;
  final bool alsoGraveyard;
  final CounterKind? counter;
  final int counterAmount;
  @override
  List<Object?> get props => [pick, destination, alsoGraveyard, counter, counterAmount];
}

/// Look at target opponent's hand and choose a nonland card; that player exiles it and draws a
/// card (Salt Vampire), or it is exiled and its owner may play it for {2} more (Zero).
class HandChoice extends Effect {
  const HandChoice(this.target, this.pick, {this.drawAfter = false, this.ownerMayPlayForMore = 0, this.lookOnly = false});
  final Target target;
  final CardPred pick;
  final bool drawAfter;
  final int ownerMayPlayForMore;

  /// V'Ger: just look at the hand.
  final bool lookOnly;
  @override
  List<Object?> get props => [target, pick, drawAfter, ownerMayPlayForMore, lookOnly];
}

/// +X/+X (or +X/+0) until end of turn where X is counted.
class PumpAmount extends Effect {
  const PumpAmount(this.power, this.toughness, this.target, {this.duration = EffectDuration.endOfTurn});
  final Amount power, toughness;
  final Target target;
  final EffectDuration duration;
  @override
  List<Object?> get props => [power, toughness, target, duration];
}

/// "until your next turn": a temporary effect that outlasts this turn.
class PumpUntilYourNextTurn extends Effect {
  const PumpUntilYourNextTurn(this.power, this.toughness, this.target);
  final int power, toughness;
  final Target target;
  @override
  List<Object?> get props => [power, toughness, target];
}

/// The source becomes a copy of the target (Dominion Saboteur).
class BecomeCopy extends Effect {
  const BecomeCopy(this.target, {this.nonLegendary = true, this.copyCounters = true});
  final Target target;
  final bool nonLegendary, copyCounters;
  @override
  List<Object?> get props => [target, nonLegendary, copyCounters];
}

/// "As ~ enters, choose a number between 0 and 10."
class ChooseNumber extends Effect {
  const ChooseNumber(this.min, this.max);
  final int min, max;
  @override
  List<Object?> get props => [min, max];
}

/// Internal: run the source's enters triggers (after "as it enters" choices).
class EnterTriggers extends Effect {
  const EnterTriggers(this.untapped);
  final bool untapped;
  @override
  List<Object?> get props => [untapped];
}

/// The target's owner puts it on top or bottom of their library (their choice).
class TopOrBottom extends Effect {
  const TopOrBottom(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

class WinGame extends Effect {
  const WinGame();
  @override
  List<Object?> get props => const [];
}

class LoseGame extends Effect {
  const LoseGame();
  @override
  List<Object?> get props => const [];
}

/// "When that creature dies this turn, ..." / "At the beginning of the next combat this turn, ...".
class Delayed extends Effect {
  const Delayed(this.event, this.effects);
  final DelayedEventKind event;
  final List<Effect> effects;
  @override
  List<Object?> get props => [event, effects];
}

enum DelayedEventKind { lastTouchedDies, nextCombat }

/// "becomes a Doctor (loses all other creature types)" / "become Warriors in addition".
class BecomeType extends Effect {
  const BecomeType(this.subtype, this.target, {this.replace = false});
  final String subtype;
  final Target target;
  final bool replace;
  @override
  List<Object?> get props => [subtype, target, replace];
}

class PhaseOut extends Effect {
  const PhaseOut(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

/// Starfleet Communicator: copy this spell (the copy becomes a token).
class CopyThisSpell extends Effect {
  const CopyThisSpell();
  @override
  List<Object?> get props => const [];
}

/// "Double the number of +1/+1 counters on each creature you control."
class DoubleCounters extends Effect {
  const DoubleCounters(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

/// Common Goal: each of these creatures deals damage equal to its power to the other target.
class EachBites extends Effect {
  const EachBites(this.biters, this.target);
  final Target biters, target;
  @override
  List<Object?> get props => [biters, target];
}

/// Seven of Nine: "base power and toughness become 7/9".
class SetBasePT extends Effect {
  const SetBasePT(this.power, this.toughness);
  final int power, toughness;
  @override
  List<Object?> get props => [power, toughness];
}

/// Starfleet Academy: choose a color, add that much mana of it (it waits in your mana pool).
class AddManaOfChosenColor extends Effect {
  const AddManaOfChosenColor(this.amount);
  final Amount amount;
  @override
  List<Object?> get props => [amount];
}

/// Peace in Our Time: the active player may draw; if they do, they can't attack and the source
/// gets a peace counter.
class PeaceOffer extends Effect {
  const PeaceOffer();
  @override
  List<Object?> get props => const [];
}

/// Internal: the active player took Peace in Our Time's card.
class PeaceAccepted extends Effect {
  const PeaceAccepted(this.player);
  final int player;
  @override
  List<Object?> get props => [player];
}

/// Remove all counters of a kind from the source.
class RemoveCounters extends Effect {
  const RemoveCounters(this.kind, this.target);
  final CounterKind kind;
  final Target target;
  @override
  List<Object?> get props => [kind, target];
}

/// Engineered Explosives: destroy each nonland permanent whose mana value equals the amount.
class DestroyNonlandWithManaValue extends Effect {
  const DestroyNonlandWithManaValue(this.amount);
  final Amount amount;
  @override
  List<Object?> get props => [amount];
}

/// Q: shuffle, exile from the top until a nonland card; it can then be copied from exile.
class QStackTheDeck extends Effect {
  const QStackTheDeck();
  @override
  List<Object?> get props => const [];
}

/// Captain Sisko: exile the top N; cast any number of spells among them with mana value up to
/// the amount, free.
class ExileTopCastFree extends Effect {
  const ExileTopCastFree(this.n, this.maxManaValue);
  final int n;
  final Amount maxManaValue;
  @override
  List<Object?> get props => [n, maxManaValue];
}

/// Brad Boimler: counters you put this turn get one more.
class ExtraCountersThisTurn extends Effect {
  const ExtraCountersThisTurn();
  @override
  List<Object?> get props => const [];
}

/// "exile ... until ~ leaves the battlefield".
class ExileUntilLeaves extends Effect {
  const ExileUntilLeaves(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

/// "you may put up to X land cards from your hand onto the battlefield tapped".
class PutLandsFromHand extends Effect {
  const PutLandsFromHand(this.amount, {this.tapped = true});
  final Amount amount;
  final bool tapped;
  @override
  List<Object?> get props => [amount, tapped];
}

/// "You may exile a card from your hand. If you do, ..." (the exile is the "do").
class ExileFromHand extends Effect {
  const ExileFromHand();
  @override
  List<Object?> get props => const [];
}

/// Khaaaaaan!: "If that creature would die this turn, exile it instead."
class ExileIfDiesThisTurn extends Effect {
  const ExileIfDiesThisTurn(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
}

enum SpellKind { any, creature, noncreature, artifact, instantOrSorcery, creatureOrSpacecraft }

/// When a triggered ability fires.
sealed class TriggerEvent with Props {
  const TriggerEvent();
}

enum SimpleTriggerKind {
  enters,
  entersUntapped,
  dies,
  leaves,
  attacks,
  blocks,
  blocked,
  combatDamageToPlayer,
  upkeep,
  eachUpkeep,
  endStep,
  beginCombat,
  landfall,
  becomesTapped,
  gainLife,
  drawCard,
  stationed,

  /// Your first (precombat) main phase.
  firstMain,

  /// The beginning of combat on each player's turn.
  eachBeginCombat,

  /// You declare one or more attackers.
  youAttack,

  /// A card leaves your graveyard.
  cardLeavesYourGraveyard,

  /// You draw a card / an opponent draws a card / you draw your second card this turn.
  youDraw,
  opponentDraws,
  secondCardDrawn,

  /// You play a land or cast a spell from exile.
  playFromExile,

  /// You choose one or more modes for a spell or ability.
  faceDilemma,

  /// Charge counters are put on this for the first time this turn.
  chargedFirstTime,

  /// "When you cast this spell".
  castThis,

  /// The equipped creature attacks.
  equippedAttacks,

  /// The beginning of each player's end step.
  eachEndStep,

  /// A creature you control with a counter on it deals combat damage to a player.
  counteredCreatureHitsPlayer,
}

class SimpleTrigger extends TriggerEvent {
  const SimpleTrigger(this.kind);
  final SimpleTriggerKind kind;
  static const enters = SimpleTrigger(SimpleTriggerKind.enters);
  static const entersUntapped = SimpleTrigger(SimpleTriggerKind.entersUntapped);
  static const dies = SimpleTrigger(SimpleTriggerKind.dies);
  static const leaves = SimpleTrigger(SimpleTriggerKind.leaves);
  static const attacks = SimpleTrigger(SimpleTriggerKind.attacks);
  static const blocks = SimpleTrigger(SimpleTriggerKind.blocks);
  static const blocked = SimpleTrigger(SimpleTriggerKind.blocked);
  static const combatDamageToPlayer = SimpleTrigger(SimpleTriggerKind.combatDamageToPlayer);
  static const upkeep = SimpleTrigger(SimpleTriggerKind.upkeep);
  static const eachUpkeep = SimpleTrigger(SimpleTriggerKind.eachUpkeep);
  static const endStep = SimpleTrigger(SimpleTriggerKind.endStep);
  static const beginCombat = SimpleTrigger(SimpleTriggerKind.beginCombat);
  static const landfall = SimpleTrigger(SimpleTriggerKind.landfall);
  static const becomesTapped = SimpleTrigger(SimpleTriggerKind.becomesTapped);
  static const gainLife = SimpleTrigger(SimpleTriggerKind.gainLife);
  static const stationed = SimpleTrigger(SimpleTriggerKind.stationed);
  static const firstMain = SimpleTrigger(SimpleTriggerKind.firstMain);
  static const eachBeginCombat = SimpleTrigger(SimpleTriggerKind.eachBeginCombat);
  static const youAttack = SimpleTrigger(SimpleTriggerKind.youAttack);
  static const cardLeavesYourGraveyard = SimpleTrigger(SimpleTriggerKind.cardLeavesYourGraveyard);
  static const youDraw = SimpleTrigger(SimpleTriggerKind.youDraw);
  static const opponentDraws = SimpleTrigger(SimpleTriggerKind.opponentDraws);
  static const secondCardDrawn = SimpleTrigger(SimpleTriggerKind.secondCardDrawn);
  static const playFromExile = SimpleTrigger(SimpleTriggerKind.playFromExile);
  static const faceDilemma = SimpleTrigger(SimpleTriggerKind.faceDilemma);
  static const chargedFirstTime = SimpleTrigger(SimpleTriggerKind.chargedFirstTime);
  static const castThis = SimpleTrigger(SimpleTriggerKind.castThis);
  static const equippedAttacks = SimpleTrigger(SimpleTriggerKind.equippedAttacks);
  static const eachEndStep = SimpleTrigger(SimpleTriggerKind.eachEndStep);
  static const counteredCreatureHitsPlayer = SimpleTrigger(SimpleTriggerKind.counteredCreatureHitsPlayer);
  @override
  List<Object?> get props => [kind];
  @override
  String toString() => kind.name;
}

class PermanentEntersTrigger extends TriggerEvent {
  const PermanentEntersTrigger(this.filter);
  final Filter filter;
  @override
  List<Object?> get props => [filter];
}

class PermanentDiesTrigger extends TriggerEvent {
  const PermanentDiesTrigger(this.filter);
  final Filter filter;
  @override
  List<Object?> get props => [filter];
}

class CastSpellTrigger extends TriggerEvent {
  const CastSpellTrigger(this.kind, {this.who = Controller.you, this.manaValueIsChosenNumber = false});
  final SpellKind kind;

  /// Whose spells: yours, an opponent's, or anyone's.
  final Controller who;

  /// Nyota Uhura: only spells whose mana value is the number chosen as she entered.
  final bool manaValueIsChosenNumber;
  @override
  List<Object?> get props => [kind, who, manaValueIsChosenNumber];
}

/// "while creatures you control have total power 8 or greater", "if you've cast a noncreature
/// spell this turn", "if you cast it", "if ~ has twelve or more peace counters on it".
enum TriggerConditionKind { totalPowerAtLeast, castNoncreatureThisTurn, wasCast, selfCountersAtLeast, firstSpellThisGame, permanentReturnedToHandThisTurn }

class TriggerCondition with Props {
  const TriggerCondition(this.kind, {this.n = 0, this.counter});
  final TriggerConditionKind kind;
  final int n;
  final CounterKind? counter;
  @override
  List<Object?> get props => [kind, n, counter];
}

/// Always-on abilities.
sealed class StaticAbility with Props {
  const StaticAbility();
}

enum SimpleStaticKind {
  entersTapped,
  shockLand,
  extraLandEachTurn,
  noMaxHandSize,
  hexproofWhileNotCreature,
  cantBeCountered,
  enchantCreature,
  enchantArtifactOrCreature,

  /// Marooned: the enchanted permanent can't be returned to pay for Beam me up.
  attachedCantBeBeamedUp,
  enchantCreatureOpponentControls,
  attachedCantAttackOrBlock,

  /// Quark: you can't sacrifice Treasure tokens.
  cantSacrificeTreasures,

  /// Mr. Spock: if you would draw a card, draw two instead.
  drawTwoInstead,

  /// Geordi La Forge: charge counters on your artifacts are doubled.
  doubleChargeCounters,

  /// Dr. M'Benga: counters on your creatures are doubled.
  doubleCountersOnCreatures,

  /// Dr. Crusher: your life-gain triggers trigger an additional time.
  lifeGainTriggersTwice,

  /// Marooned: the enchanted permanent doesn't untap and can't be beamed up.
  attachedDoesntUntap,

  /// You may look at the top card of your library any time / play with it revealed.
  lookAtTop,

  /// Captain Pike: you may play lands from the top of your library.
  playLandsFromTop,

  /// Benjamin Sisko: lands and creature spells from the top of your library.
  playLandsAndCreaturesFromTop,

  /// "You may cast this card from exile."
  castSelfFromExile,

  /// The Holodeck: once during each of your turns, play a permanent card from your graveyard.
  playPermanentFromGraveyardOncePerTurn,

  /// The City on the Edge of Forever's Human token: permanents can't phase in.
  permanentsCantPhaseIn,
}

class SimpleStatic extends StaticAbility {
  const SimpleStatic(this.kind);
  final SimpleStaticKind kind;
  static const entersTapped = SimpleStatic(SimpleStaticKind.entersTapped);
  static const shockLand = SimpleStatic(SimpleStaticKind.shockLand);
  static const extraLandEachTurn = SimpleStatic(SimpleStaticKind.extraLandEachTurn);
  static const noMaxHandSize = SimpleStatic(SimpleStaticKind.noMaxHandSize);
  static const hexproofWhileNotCreature = SimpleStatic(SimpleStaticKind.hexproofWhileNotCreature);
  static const cantBeCountered = SimpleStatic(SimpleStaticKind.cantBeCountered);
  static const enchantCreature = SimpleStatic(SimpleStaticKind.enchantCreature);
  static const enchantArtifactOrCreature = SimpleStatic(SimpleStaticKind.enchantArtifactOrCreature);
  static const enchantCreatureOpponentControls = SimpleStatic(SimpleStaticKind.enchantCreatureOpponentControls);
  static const attachedCantAttackOrBlock = SimpleStatic(SimpleStaticKind.attachedCantAttackOrBlock);
  static SimpleStatic of(SimpleStaticKind kind) => SimpleStatic(kind);
  @override
  List<Object?> get props => [kind];
}

class EntersTappedUnless extends StaticAbility {
  const EntersTappedUnless(this.landsAtLeast);
  final int landsAtLeast;
  @override
  List<Object?> get props => [landsAtLeast];
}

class Anthem extends StaticAbility {
  const Anthem(this.filter, this.power, this.toughness);
  final Filter filter;
  final int power, toughness;
  @override
  List<Object?> get props => [filter, power, toughness];
}

class GrantKeywordStatic extends StaticAbility {
  const GrantKeywordStatic(this.filter, this.keyword, {this.duringYourTurn = false});
  final Filter filter;
  final Keyword keyword;
  final bool duringYourTurn;
  @override
  List<Object?> get props => [filter, keyword, duringYourTurn];
}

class AttachedGets extends StaticAbility {
  const AttachedGets(this.power, this.toughness);
  final int power, toughness;
  @override
  List<Object?> get props => [power, toughness];
}

class AttachedHas extends StaticAbility {
  const AttachedHas(this.keyword);
  final Keyword keyword;
  @override
  List<Object?> get props => [keyword];
}

class SelfPumpPerCount extends StaticAbility {
  const SelfPumpPerCount(this.amount, this.power, this.toughness);
  final Amount amount;
  final int power, toughness;
  @override
  List<Object?> get props => [amount, power, toughness];
}

class KeywordDuringYourTurn extends StaticAbility {
  const KeywordDuringYourTurn(this.keyword);
  final Keyword keyword;
  @override
  List<Object?> get props => [keyword];
}

class PowerEquals extends StaticAbility {
  const PowerEquals(this.amount, {this.andToughness = false});
  final Amount amount;
  final bool andToughness;
  @override
  List<Object?> get props => [amount, andToughness];
}

class GrantTrigger extends StaticAbility {
  const GrantTrigger(this.filter, this.event, this.effects);
  final Filter filter;
  final TriggerEvent event;
  final List<Effect> effects;
  @override
  List<Object?> get props => [filter, event, effects];
}

/// Where an activated ability is used from: the battlefield, or (for "Discard this card:",
/// "Exile this card from your graveyard:") the hand or the graveyard.
enum AbilityZone { battlefield, hand, graveyard }

class ActivationCost with Props {
  ActivationCost({ManaCost? mana, this.tap = false, this.sacrificeSelf = false, this.sacrifice, this.payLife = 0, this.discard = 0, this.oncePerTurn = false}) : mana = mana ?? ManaCost();
  final ManaCost mana;
  bool tap, sacrificeSelf, oncePerTurn;
  Filter? sacrifice;
  int payLife, discard;

  /// "Tap two untapped artifacts and/or creatures you control": how many, and which.
  int tapOthers = 0;
  Filter? tapOthersFilter;

  /// "Remove three counters from among creatures you control".
  int removeCounters = 0;
  AbilityZone zone = AbilityZone.battlefield;

  /// From the graveyard: exile this card, or put it on the bottom of the library, as the cost.
  bool exileSelf = false, bottomSelf = false;

  /// "Activate only if you control seven or more differently named lands".
  int minDifferentLands = 0;
  bool get isFree => mana.isFree && !tap && !sacrificeSelf && sacrifice == null && payLife == 0 && discard == 0 && tapOthers == 0 && removeCounters == 0;
  @override
  List<Object?> get props => [mana, tap, sacrificeSelf, sacrifice, payLife, discard, oncePerTurn, tapOthers, tapOthersFilter, removeCounters, zone, exileSelf, bottomSelf, minDifferentLands];
}

/// One ability on a card.
sealed class Ability with Props {
  const Ability();
  bool get isUnsupported => this is Unsupported;
}

class KeywordAbility extends Ability {
  const KeywordAbility(this.keyword);
  final Keyword keyword;
  @override
  List<Object?> get props => [keyword];
  @override
  String toString() => 'keyword($keyword)';
}

class ManaAbility extends Ability {
  const ManaAbility(this.colors, {this.artifactSpellsOnly = false, this.amount = 1}); // {T}: Add one of these (empty = colorless)
  final List<ManaColor> colors;

  /// "Spend this mana only to cast an artifact spell."
  final bool artifactSpellsOnly;

  /// How much mana one tap makes, all of one of [colors] ({G}{G}{G}: 3 of green; "three mana of
  /// any one color": 3 of any). Zero for an ability that can't make mana in this game.
  final int amount;
  @override
  List<Object?> get props => [colors, artifactSpellsOnly, amount];
  @override
  String toString() => 'mana(${colors.map((c) => c.symbol).join()})';
}

class StaticAbilityEntry extends Ability {
  const StaticAbilityEntry(this.ability);
  final StaticAbility ability;
  @override
  List<Object?> get props => [ability];
  @override
  String toString() => 'static($ability)';
}

class Triggered extends Ability {
  const Triggered(this.event, this.effects, {this.oncePerTurn = false, this.condition});
  final TriggerEvent event;
  final List<Effect> effects;

  /// "This ability triggers only once each turn."
  final bool oncePerTurn;

  /// An intervening "if"/"while" that must hold when the event happens.
  final TriggerCondition? condition;
  @override
  List<Object?> get props => [event, effects, oncePerTurn, condition];
  @override
  String toString() => 'triggered($event, $effects)';
}

class Activated extends Ability {
  const Activated(this.cost, this.effects, {this.sorcerySpeed = false});
  final ActivationCost cost;
  final List<Effect> effects;
  final bool sorcerySpeed;
  @override
  List<Object?> get props => [cost, effects, sorcerySpeed];
  @override
  String toString() => 'activated($cost: $effects)';
}

class Spell extends Ability {
  const Spell(this.effects); // what an instant or sorcery does
  final List<Effect> effects;
  @override
  List<Object?> get props => [effects];
  @override
  String toString() => 'spell($effects)';
}

class Cycling extends Ability {
  const Cycling(this.cost, this.landType); // landType "basic", a basic land type, or null
  final ManaCost cost;
  final String? landType;
  @override
  List<Object?> get props => [cost, landType];
}

class Equip extends Ability {
  const Equip(this.cost);
  final ManaCost cost;
  @override
  List<Object?> get props => [cost];
}

class Kicker extends Ability {
  const Kicker(this.cost);
  final ManaCost cost;
  @override
  List<Object?> get props => [cost];
}

class Saga extends Ability {
  const Saga(this.chapters);
  final List<List<Effect>> chapters;
  @override
  List<Object?> get props => [chapters];
}

class StationAbilities extends Ability {
  const StationAbilities(this.threshold, this.keywords, [this.extra = const []]);
  final int threshold;
  final List<Keyword> keywords;

  /// Other abilities the Spacecraft has once charged ("12+ | Artifact creatures you control have
  /// flying", "3+ | At the beginning of combat on your turn, ...").
  final List<Ability> extra;
  @override
  List<Object?> get props => [threshold, keywords, extra];
  @override
  String toString() => 'station($threshold+, $keywords)';
}

/// "Affinity for artifact creatures": costs {1} less for each one you control.
class Affinity extends Ability {
  const Affinity(this.filter);
  final Filter filter;
  @override
  List<Object?> get props => [filter];
}

/// "Sunburst": enters with a charge counter for each color of mana spent to cast it.
class Sunburst extends Ability {
  const Sunburst();
  @override
  List<Object?> get props => const [];
}

/// "As ~ enters, choose a number between 0 and 10."
class ChooseNumberOnEnter extends Ability {
  const ChooseNumberOnEnter(this.min, this.max);
  final int min, max;
  @override
  List<Object?> get props => [min, max];
}

/// "You may have ~ enter as a copy of any artifact or creature on the battlefield, except it
/// isn't legendary. If you do, it enters with additional counters ..."
class EnterAsCopy extends Ability {
  const EnterAsCopy(this.filter, {this.nonLegendary = true, this.copyCounters = true});
  final Filter filter;
  final bool nonLegendary, copyCounters;
  @override
  List<Object?> get props => [filter, nonLegendary, copyCounters];
}

/// "This spell costs {1} less to cast if it targets an attacking creature."
class CostReductionIfTargetsAttacker extends Ability {
  const CostReductionIfTargetsAttacker(this.amount);
  final int amount;
  @override
  List<Object?> get props => [amount];
}

/// Kicker paid by sacrificing ("Kicker—Sacrifice an artifact or creature").
class SacrificeKicker extends Ability {
  const SacrificeKicker(this.filter);
  final Filter filter;
  @override
  List<Object?> get props => [filter];
}

class BeamMeUp extends Ability {
  const BeamMeUp(this.cost);
  final ManaCost cost;
  @override
  List<Object?> get props => [cost];
}

class Unsupported extends Ability {
  const Unsupported(this.text);
  final String text;
  @override
  List<Object?> get props => [text];
  @override
  String toString() => 'unsupported($text)';
}

/// A card's rules text as abilities, plus the clauses the parser had to give up on.
class ParsedCard {
  ParsedCard(this.abilities, this.unsupported);
  final List<Ability> abilities;
  final List<String> unsupported;

  bool get fullySupported => unsupported.isEmpty;
  bool get anySupported => abilities.any((a) => !a.isUnsupported);

  List<Keyword> get keywords => abilities.whereType<KeywordAbility>().map((a) => a.keyword).toList();
  bool has(KeywordKind kind) => keywords.any((k) => k.kind == kind);
  List<Effect> get spellEffects => abilities.whereType<Spell>().expand((s) => s.effects).toList();
  List<ManaColor> get manaColors => abilities.whereType<ManaAbility>().expand((m) => m.colors).toList();
  bool get hasManaAbility => abilities.any((a) => a is ManaAbility);
  List<StaticAbility> get statics => abilities.whereType<StaticAbilityEntry>().map((s) => s.ability).toList();
  ManaCost? get kicker => abilities.whereType<Kicker>().map((k) => k.cost).firstOrNull;
  ManaCost? get equipCost => abilities.whereType<Equip>().map((e) => e.cost).firstOrNull;
  Cycling? get cycling => abilities.whereType<Cycling>().firstOrNull;
  ManaCost? get beamMeUp => abilities.whereType<BeamMeUp>().map((b) => b.cost).firstOrNull;
  bool get isAura => statics.contains(SimpleStatic.enchantCreature) || statics.contains(SimpleStatic.enchantArtifactOrCreature) || statics.contains(SimpleStatic.enchantCreatureOpponentControls);
  List<List<Effect>> triggers(TriggerEvent event) => abilities.whereType<Triggered>().where((t) => t.event == event).map((t) => t.effects).toList();
  int? get stationThreshold => abilities.whereType<StationAbilities>().map((s) => s.threshold).fold<int?>(null, (a, b) => a == null || b > a ? b : a);

  /// Every station line, lowest threshold first.
  List<StationAbilities> get stationLines => abilities.whereType<StationAbilities>().toList()..sort((a, b) => a.threshold - b.threshold);
  List<Keyword> get stationKeywords => abilities.whereType<StationAbilities>().map((s) => s.keywords).firstOrNull ?? const [];
  List<List<Effect>>? get sagaChapters => abilities.whereType<Saga>().map((s) => s.chapters).firstOrNull;
}
