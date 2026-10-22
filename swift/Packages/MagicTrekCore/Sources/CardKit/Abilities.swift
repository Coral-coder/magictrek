import Foundation

// The vocabulary the engine understands. AbilityParser turns a card's rules text into these;
// anything it can't express is kept as `.unsupported(text)` so the card still plays with the
// rest of its text and the UI can say what is missing.

public enum KeywordKind: String, Codable, Hashable, CaseIterable, Sendable {
    case flying, firstStrike = "first strike", doubleStrike = "double strike", deathtouch, lifelink, trample, haste,
         vigilance, menace, reach, defender, flash, indestructible, hexproof, ward, station,
         unblockable = "can't be blocked", cantBlock = "can't block", mustAttack = "attacks each combat if able"
}

public struct Keyword: Hashable, Codable, Sendable, CustomStringConvertible {
    public var kind: KeywordKind
    /// Ward's cost; otherwise 0.
    public var value: Int
    public init(_ kind: KeywordKind, value: Int = 0) { self.kind = kind; self.value = value }
    public static let flying = Keyword(.flying), firstStrike = Keyword(.firstStrike), doubleStrike = Keyword(.doubleStrike),
        deathtouch = Keyword(.deathtouch), lifelink = Keyword(.lifelink), trample = Keyword(.trample), haste = Keyword(.haste),
        vigilance = Keyword(.vigilance), menace = Keyword(.menace), reach = Keyword(.reach), defender = Keyword(.defender),
        flash = Keyword(.flash), indestructible = Keyword(.indestructible), hexproof = Keyword(.hexproof),
        unblockable = Keyword(.unblockable), cantBlock = Keyword(.cantBlock)
    public var description: String { kind == .ward ? "Ward {\(value)}" : kind.rawValue.capitalized }
}

/// How many: usually a number; sometimes counted from the board.
public enum Amount: Hashable, Codable, Sendable {
    case fixed(Int)
    case creaturesYouControl
    case artifactsYouControl
    case landsYouControl
    case cardsInHand
    case differentlyNamedLands
    case thisPower
    public static let one = Amount.fixed(1)
}

public enum Controller: String, Hashable, Codable, Sendable { case any, you, opponent }

/// Which permanents or players something applies to.
public struct Filter: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case creature, player, opponent, creatureOrPlayer, permanent, nonlandPermanent, artifact, enchantment,
             artifactOrEnchantment, land, spacecraft, creatureOrSpacecraft, artifactCreature, token, creatureCardInGraveyard,
             basicLandCardInLibrary, artifactOrCreature
    }
    public var kind: Kind
    public var controller: Controller = .any
    public var other: Bool = false          // "another creature": not this one
    public var attacking = false, tapped = false, untapped = false, nontoken = false, nonartifact = false, blocking = false
    public var subtype: String? = nil       // "target Klingon"
    public var maxPower: Int? = nil
    public var maxManaValue: Int? = nil
    public var minPower: Int? = nil
    public var withCounters = false      // "creatures you control with counters on them"

    public init(_ kind: Kind, controller: Controller = .any) { self.kind = kind; self.controller = controller }
    public static let creature = Filter(.creature), anyTarget = Filter(.creatureOrPlayer), player = Filter(.player),
        opponent = Filter(.opponent), permanent = Filter(.permanent)
    public var isPlayerFilter: Bool { kind == .player || kind == .opponent }
}

/// Who or what an effect hits.
public enum Target: Hashable, Codable, Sendable {
    case this                                   // the source itself
    case you
    case target(Filter, count: Int = 1, optional: Bool = false)   // chosen when cast/triggered
    case each(Filter)                           // every matching permanent or player
    case lastTarget                             // "it" / "that creature": the previous target in the same ability
    case controllerOfLastTarget
    case attachedCreature                       // "equipped creature" / "enchanted creature"
}

public struct TokenSpec: Hashable, Codable, Sendable {
    public var name: String
    public var power: Int, toughness: Int
    public var colors: [ManaColor]
    public var subtypes: [String]
    public var keywords: [Keyword]
    public var isArtifact: Bool
    public var isCreature: Bool
    public init(name: String, power: Int = 0, toughness: Int = 0, colors: [ManaColor] = [], subtypes: [String] = [],
                keywords: [Keyword] = [], isArtifact: Bool = false, isCreature: Bool = true) {
        self.name = name; self.power = power; self.toughness = toughness; self.colors = colors
        self.subtypes = subtypes; self.keywords = keywords; self.isArtifact = isArtifact; self.isCreature = isCreature
    }
    public static let treasure = TokenSpec(name: "Treasure", subtypes: ["Treasure"], isArtifact: true, isCreature: false)
    public static let clue = TokenSpec(name: "Clue", subtypes: ["Clue"], isArtifact: true, isCreature: false)
    public static let food = TokenSpec(name: "Food", subtypes: ["Food"], isArtifact: true, isCreature: false)
}

public enum CounterKind: String, Hashable, Codable, Sendable { case plusOne = "+1/+1", minusOne = "-1/-1", charge, lore, finality, stun }

public enum Duration: String, Hashable, Codable, Sendable { case endOfTurn, permanent }

public enum LibraryDestination: String, Hashable, Codable, Sendable { case hand, battlefield, battlefieldTapped }

public indirect enum Effect: Hashable, Codable, Sendable {
    case damage(Amount, Target)
    case draw(Amount, Target)
    case gainLife(Amount, Target)
    case loseLife(Amount, Target)
    case destroy(Target)
    case exile(Target)
    case bounce(Target)                                  // to owner's hand
    case tap(Target, freeze: Bool)                       // freeze: doesn't untap next untap step
    case untap(Target)
    case pump(power: Int, toughness: Int, Target, Duration)
    case addCounters(CounterKind, Amount, Target)
    case createTokens(TokenSpec, Amount, Target)          // Target: who gets them (.you, .each(.player)...)
    case surveil(Int), scry(Int)
    case mill(Int, Target)
    case discard(Int, Target)
    case searchBasicLand(LibraryDestination, Target)      // Target: whose library (.you / .controllerOfLastTarget)
    case sacrifice(Target, Filter)                       // the player(s) in Target sacrifice something matching Filter
    case grantKeyword(Keyword, Target, Duration)
    case returnFromGraveyard(Filter, to: LibraryDestination)
    case fight(Target)                                   // this fights the target
    case bite(Target)                                    // this deals damage equal to its power to the target
    case explore(Target)
    case addMana([ManaColor])                            // choose one of these colors
    case doubleLife
    case noMaxHandSize
    case putLandFromHand(tapped: Bool)
    case modal([[Effect]])                               // choose one
    case optional([Effect])                              // "you may"
    case cantBlock(Target, Duration)
    case gainControl(Target)
    case sacrificeAtEndOfTurn(Target)                    // "Sacrifice it at the beginning of the next end step"
    case kickedInstead([Effect])                         // "If this spell was kicked, ... instead": replaces the effects before it
    case ifDidPrevious([Effect])                         // "If you do, ...": only when the previous effect happened
    case fightBetween(Target, Target)
    case assimilate(Filter)                              // Borg: a creature card from a graveyard joins you as an artifact creature
    case assimilateFromLibrary(Target)                   // target opponent exiles from the top until a creature card; you assimilate it
    case assimilateExiledOrExile(Target)                 // assimilate a card exiled with this; if none, exile the target
    case discover(Int)                                   // exile from the top until a nonland card with MV <= n; play it free
    case payLife(Int)                                    // as part of an optional: "you may pay 1 life. If you do, ..."
    case payMana(ManaCost)
    case copyToken(Target, extra: [Keyword])             // "create a token that's a copy of ~"
    case conditional(Condition, [Effect])
}

public enum Condition: Hashable, Codable, Sendable { case thisIsCreature, thisIsNotCreature }

public enum TriggerEvent: Hashable, Codable, Sendable {
    case enters                      // this enters the battlefield
    case dies
    case leaves
    case attacks
    case blocks
    case blocked                     // becomes blocked
    case combatDamageToPlayer
    case entersUntapped
    case upkeep                      // beginning of your upkeep
    case eachUpkeep                  // beginning of each player's upkeep
    case endStep                     // beginning of your end step
    case beginCombat                 // beginning of combat on your turn
    case landfall
    case permanentEnters(Filter)     // another creature/artifact you control enters
    case permanentDies(Filter)       // a creature you control dies
    case castSpell(SpellKind)        // you cast a spell of this kind
    case becomesTapped
    case gainLife
    case drawCard                    // you draw a card (beyond the first each turn is not tracked)
    case stationed                   // this Spacecraft becomes a creature / you station
}

public enum SpellKind: String, Hashable, Codable, Sendable { case any, creature, noncreature, artifact, instantOrSorcery }

public enum StaticAbility: Hashable, Codable, Sendable {
    case entersTapped
    case entersTappedUnless(landsAtLeast: Int)        // "unless you control two or more other lands"
    case shockLand                                     // pay 2 life or enters tapped
    case anthem(Filter, power: Int, toughness: Int)    // "Creatures you control get +1/+1"
    case grantKeyword(Filter, Keyword)                 // "Artifact creatures you control have indestructible"
    case attachedGets(power: Int, toughness: Int)      // equipped / enchanted creature gets
    case attachedHas(Keyword)
    case attachedCantAttackOrBlock
    case selfPumpPerCount(Amount, power: Int, toughness: Int)   // "~ gets +1/+1 for each artifact you control"
    case extraLandEachTurn
    case noMaxHandSize
    case hexproofWhileNotCreature                      // Romulan cloaking
    case cantBeCountered                               // no stack here, so a no-op
    case enchantCreature
    case enchantCreatureOpponentControls
    case keywordDuringYourTurn(Keyword)                // "During your turn, ~ has flying"
    case grantKeywordDuringYourTurn(Filter, Keyword)
    case powerEquals(Amount, andToughness: Bool)        // "~'s power is equal to the number of ..."
    case grantTrigger(Filter, TriggerEvent, [Effect])   // "Artifact creatures you control have \"Whenever ~ attacks, ...\""
}

public struct ActivationCost: Hashable, Codable, Sendable {
    public var mana = ManaCost()
    public var tap = false
    public var sacrificeSelf = false
    public var sacrifice: Filter? = nil
    public var payLife = 0
    public var discard = 0
    public var oncePerTurn = false
    public init() {}
    public var isFree: Bool { mana.isFree && !tap && !sacrificeSelf && sacrifice == nil && payLife == 0 && discard == 0 }
}

public enum Ability: Hashable, Codable, Sendable {
    case keyword(Keyword)
    case mana([ManaColor])                                  // {T}: Add one of these (empty = one colorless)
    case staticAbility(StaticAbility)
    case triggered(TriggerEvent, [Effect])
    case activated(ActivationCost, [Effect], sorcerySpeed: Bool)
    case spell([Effect])                                    // what an instant or sorcery does
    case cycling(ManaCost, landType: String?)               // landType "basic" or a basic land type
    case equip(ManaCost)
    case kicker(ManaCost)
    case saga([[Effect]])                                   // chapters I, II, III...
    case stationAbilities(threshold: Int, [Keyword])        // what a Spacecraft has once stationed
    case beamMeUp(ManaCost)                                 // cast from the graveyard by also bouncing one of your creatures
    case unsupported(String)

    public var isUnsupported: Bool { if case .unsupported = self { return true } else { return false } }
}

/// A card's rules text as abilities, plus the clauses the parser had to give up on.
public struct ParsedCard: Hashable, Codable, Sendable {
    public var abilities: [Ability]
    public var unsupported: [String]
    public var fullySupported: Bool { unsupported.isEmpty }
    public init(abilities: [Ability], unsupported: [String]) { self.abilities = abilities; self.unsupported = unsupported }

    public var keywords: [Keyword] { abilities.compactMap { if case .keyword(let k) = $0 { return k } else { return nil } } }
    public func has(_ kind: KeywordKind) -> Bool { keywords.contains { $0.kind == kind } }
    public var spellEffects: [Effect] { abilities.flatMap { if case .spell(let e) = $0 { return e } else { return [] } } }
    public var manaColors: [ManaColor] { abilities.flatMap { if case .mana(let c) = $0 { return c } else { return [] } } }
    public var statics: [StaticAbility] { abilities.compactMap { if case .staticAbility(let s) = $0 { return s } else { return nil } } }
    public var kicker: ManaCost? { for a in abilities { if case .kicker(let c) = a { return c } }; return nil }
    public var equipCost: ManaCost? { for a in abilities { if case .equip(let c) = a { return c } }; return nil }
    public var cycling: (ManaCost, String?)? { for a in abilities { if case .cycling(let c, let t) = a { return (c, t) } }; return nil }
    public var isAura: Bool { statics.contains(.enchantCreature) || statics.contains(.enchantCreatureOpponentControls) }
    public var beamMeUp: ManaCost? { for a in abilities { if case .beamMeUp(let c) = a { return c } }; return nil }
    public func triggers(_ event: TriggerEvent) -> [[Effect]] {
        abilities.compactMap { if case .triggered(let e, let fx) = $0, e == event { return fx } else { return nil } }
    }
    public var stationThreshold: Int? { for a in abilities { if case .stationAbilities(let t, _) = a { return t } }; return nil }
    public var stationKeywords: [Keyword] { for a in abilities { if case .stationAbilities(_, let k) = a { return k } }; return [] }
}
