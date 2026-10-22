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
  mustAttack('attacks each combat if able');

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
  String toString() => kind == KeywordKind.ward ? 'Ward {$value}' : kind.text[0].toUpperCase() + kind.text.substring(1);
}

/// How many: usually a number; sometimes counted from the board.
enum AmountKind { fixed, creaturesYouControl, artifactsYouControl, landsYouControl, cardsInHand, differentlyNamedLands, thisPower }

class Amount with Props {
  const Amount.fixed(this.n) : kind = AmountKind.fixed;
  const Amount.counted(this.kind) : n = 0;
  final AmountKind kind;
  final int n;
  static const one = Amount.fixed(1);
  @override
  List<Object?> get props => [kind, n];
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
  creatureCardInGraveyard,
  basicLandCardInLibrary,
  artifactOrCreature,
  spell,
}

/// Which permanents or players something applies to.
class Filter with Props {
  Filter(this.kind, {this.controller = Controller.any});
  FilterKind kind;
  Controller controller;
  bool other = false; // "another creature": not this one
  bool attacking = false, tapped = false, untapped = false, nontoken = false, nonartifact = false, blocking = false, withCounters = false;
  String? subtype; // "target Klingon"
  int? maxPower, minPower, maxManaValue;

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
    ..subtype = subtype
    ..maxPower = maxPower
    ..minPower = minPower
    ..maxManaValue = maxManaValue;

  @override
  List<Object?> get props => [kind, controller, other, attacking, tapped, untapped, nontoken, nonartifact, blocking, withCounters, subtype, maxPower, minPower, maxManaValue];

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
  TokenSpec({required this.name, this.power = 0, this.toughness = 0, List<ManaColor>? colors, List<String>? subtypes, List<Keyword>? keywords, this.isArtifact = false, this.isCreature = true})
    : colors = colors ?? [],
      subtypes = subtypes ?? [],
      keywords = keywords ?? [];

  String name;
  final int power, toughness;
  final List<ManaColor> colors;
  final List<String> subtypes;
  final List<Keyword> keywords;
  final bool isArtifact, isCreature;

  static TokenSpec get treasure => TokenSpec(name: 'Treasure', subtypes: ['Treasure'], isArtifact: true, isCreature: false);
  static TokenSpec get clue => TokenSpec(name: 'Clue', subtypes: ['Clue'], isArtifact: true, isCreature: false);
  static TokenSpec get food => TokenSpec(name: 'Food', subtypes: ['Food'], isArtifact: true, isCreature: false);

  TokenSpec copyWith({List<Keyword>? keywords, String? name}) => TokenSpec(
    name: name ?? this.name,
    power: power,
    toughness: toughness,
    colors: List.of(colors),
    subtypes: List.of(subtypes),
    keywords: keywords ?? List.of(this.keywords),
    isArtifact: isArtifact,
    isCreature: isCreature,
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
  );

  @override
  List<Object?> get props => [name, power, toughness, colors, subtypes, keywords, isArtifact, isCreature];
}

enum CounterKind {
  plusOne('+1/+1'),
  minusOne('-1/-1'),
  charge('charge'),
  lore('lore'),
  finality('finality'),
  stun('stun');

  const CounterKind(this.text);
  final String text;
}

enum EffectDuration { endOfTurn, permanent }

enum LibraryDestination { hand, battlefield, battlefieldTapped }

enum Condition { thisIsCreature, thisIsNotCreature }

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
  const AddCounters(this.kind, this.amount, this.target);
  final CounterKind kind;
  final Amount amount;
  final Target target;
  @override
  List<Object?> get props => [kind, amount, target];
}

class CreateTokens extends Effect {
  const CreateTokens(this.spec, this.amount, this.target);
  final TokenSpec spec;
  final Amount amount;
  final Target target; // who gets them
  @override
  List<Object?> get props => [spec, amount, target];
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
  const ReturnFromGraveyard(this.filter, this.destination);
  final Filter filter;
  final LibraryDestination destination;
  @override
  List<Object?> get props => [filter, destination];
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
  const Modal(this.modes);
  final List<List<Effect>> modes;
  @override
  List<Object?> get props => [modes];
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
  const GainControl(this.target);
  final Target target;
  @override
  List<Object?> get props => [target];
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
  const CopyToken(this.target, this.extra);
  final Target target;
  final List<Keyword> extra;
  @override
  List<Object?> get props => [target, extra];
}

class Conditional extends Effect {
  const Conditional(this.condition, this.effects);
  final Condition condition;
  final List<Effect> effects;
  @override
  List<Object?> get props => [condition, effects];
}

/// Counter target spell (unless its controller pays a cost).
class CounterSpell extends Effect {
  const CounterSpell(this.target, {this.unlessPays});
  final Target target;
  final ManaCost? unlessPays;
  @override
  List<Object?> get props => [target, unlessPays];
}

enum SpellKind { any, creature, noncreature, artifact, instantOrSorcery }

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
  const CastSpellTrigger(this.kind);
  final SpellKind kind;
  @override
  List<Object?> get props => [kind];
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
  enchantCreatureOpponentControls,
  attachedCantAttackOrBlock,
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
  static const enchantCreatureOpponentControls = SimpleStatic(SimpleStaticKind.enchantCreatureOpponentControls);
  static const attachedCantAttackOrBlock = SimpleStatic(SimpleStaticKind.attachedCantAttackOrBlock);
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

class ActivationCost with Props {
  ActivationCost({ManaCost? mana, this.tap = false, this.sacrificeSelf = false, this.sacrifice, this.payLife = 0, this.discard = 0, this.oncePerTurn = false}) : mana = mana ?? ManaCost();
  final ManaCost mana;
  bool tap, sacrificeSelf, oncePerTurn;
  Filter? sacrifice;
  int payLife, discard;
  bool get isFree => mana.isFree && !tap && !sacrificeSelf && sacrifice == null && payLife == 0 && discard == 0;
  @override
  List<Object?> get props => [mana, tap, sacrificeSelf, sacrifice, payLife, discard, oncePerTurn];
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
  const ManaAbility(this.colors); // {T}: Add one of these (empty = colorless)
  final List<ManaColor> colors;
  @override
  List<Object?> get props => [colors];
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
  const Triggered(this.event, this.effects);
  final TriggerEvent event;
  final List<Effect> effects;
  @override
  List<Object?> get props => [event, effects];
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
  const StationAbilities(this.threshold, this.keywords);
  final int threshold;
  final List<Keyword> keywords;
  @override
  List<Object?> get props => [threshold, keywords];
  @override
  String toString() => 'station($threshold+, $keywords)';
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
  bool get isAura => statics.contains(SimpleStatic.enchantCreature) || statics.contains(SimpleStatic.enchantCreatureOpponentControls);
  List<List<Effect>> triggers(TriggerEvent event) => abilities.whereType<Triggered>().where((t) => t.event == event).map((t) => t.effects).toList();
  int? get stationThreshold => abilities.whereType<StationAbilities>().map((s) => s.threshold).firstOrNull;
  List<Keyword> get stationKeywords => abilities.whereType<StationAbilities>().map((s) => s.keywords).firstOrNull ?? const [];
  List<List<Effect>>? get sagaChapters => abilities.whereType<Saga>().map((s) => s.chapters).firstOrNull;
}
