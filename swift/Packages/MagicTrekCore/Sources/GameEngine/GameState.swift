import CardKit
import Foundation

public typealias PlayerID = Int
public typealias ObjectID = Int

public enum Zone: String, Codable, Hashable, Sendable { case library, hand, battlefield, graveyard, exile }

/// A card in the game. Tokens are objects too, with `token` set and `cardID` naming what they copy (if anything).
public struct GameObject: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public var cardID: String          // CardDatabase id; "" for a token that copies nothing
    public let owner: PlayerID
    public var token: TokenSpec?
    public var zone: Zone
    public var controller: PlayerID
    // Battlefield state
    public var tapped = false
    public var damage = 0
    public var counters: [CounterKind: Int] = [:]
    public var enteredTurn = -1                  // for summoning sickness
    public var attachedTo: ObjectID? = nil       // auras and equipment
    public var untilEndOfTurn: [TemporaryEffect] = []
    public var frozen = false                    // doesn't untap during the next untap step
    public var sacrificeAtEnd = false
    public var activatedThisTurn: Set<Int> = []  // ability indexes used (once-per-turn abilities)
    public var exiledWithThis: [ObjectID] = []   // Borg Cube keeps what it exiled
    public var assimilated = false               // a Borg artifact creature now
    public var attacking: PlayerID? = nil
    public var blocking: ObjectID? = nil
    public var hasDealtDamage = false

    public init(id: ObjectID, cardID: String, owner: PlayerID, zone: Zone, token: TokenSpec? = nil) {
        self.id = id; self.cardID = cardID; self.owner = owner; self.zone = zone; self.controller = owner; self.token = token
    }
    public var isToken: Bool { token != nil }
    public var plusOneCounters: Int { counters[.plusOne] ?? 0 }
    public var chargeCounters: Int { counters[.charge] ?? 0 }
}

public enum TemporaryEffect: Codable, Hashable, Sendable {
    case pump(power: Int, toughness: Int)
    case keyword(Keyword)
    case cantBlock
    case noMaxHandSize
}

public struct PlayerState: Codable, Hashable, Sendable {
    public let id: PlayerID
    public var name: String
    public var life = 20
    public var library: [ObjectID] = []       // index 0 is the top
    public var hand: [ObjectID] = []
    public var battlefield: [ObjectID] = []
    public var graveyard: [ObjectID] = []
    public var exile: [ObjectID] = []
    public var landsPlayedThisTurn = 0
    public var noMaxHandSizeUntilNextTurn = false
    public var mulligans = 0
    public var keptHand = false
    public var isBot = false
    public var lost = false
    public var spellsCastThisTurn = 0
    public var lifeGainedThisTurn = 0
    public init(id: PlayerID, name: String, isBot: Bool = false) { self.id = id; self.name = name; self.isBot = isBot }
}

public enum Phase: String, Codable, Hashable, Sendable, CaseIterable {
    case untap, upkeep, draw, main1, beginCombat, declareAttackers, declareBlockers, combatDamage, endCombat, main2, end, cleanup
    public var isMain: Bool { self == .main1 || self == .main2 }
    public var label: String {
        switch self {
        case .untap: return "Untap"
        case .upkeep: return "Upkeep"
        case .draw: return "Draw"
        case .main1: return "Main Phase 1"
        case .beginCombat: return "Begin Combat"
        case .declareAttackers: return "Declare Attackers"
        case .declareBlockers: return "Declare Blockers"
        case .combatDamage: return "Combat Damage"
        case .endCombat: return "End Combat"
        case .main2: return "Main Phase 2"
        case .end: return "End Step"
        case .cleanup: return "Cleanup"
        }
    }
}

/// Something the game needs from a player before it can go on.
public enum Decision: Codable, Hashable, Sendable {
    case mulligan                                            // keep or mulligan the opening hand
    case declareBlockers(attackers: [ObjectID])
    case chooseTargets(prompt: String, filter: Filter, count: Int, optional: Bool, candidates: [ObjectID])
    case chooseMode(prompt: String, modes: [String])
    case chooseOptional(prompt: String)                      // "you may ..."
    case discardToHandSize(count: Int)
    case chooseSacrifice(prompt: String, candidates: [ObjectID])
    case surveil(cards: [ObjectID])                          // which go to the graveyard
    case scry(cards: [ObjectID])                             // which go to the bottom
    case explore(card: ObjectID, creature: ObjectID)         // keep the nonland on top or graveyard it
    case discoverChoice(card: ObjectID)                      // play it free, or put it in hand

    public var player: PlayerID? { nil }
}

/// What a player answers a `Decision` with.
public enum DecisionResponse: Codable, Hashable, Sendable {
    case keep, mulligan
    case blockers([ObjectID: ObjectID])        // blocker -> attacker
    case targets([ObjectID])
    case mode(Int)
    case yes, no
    case cards([ObjectID])                     // discard / surveil-to-graveyard / scry-to-bottom
    case sacrifice(ObjectID)
    case exploreGraveyard(Bool)
    case discoverPlay(Bool)
}

public struct PendingDecision: Codable, Hashable, Sendable {
    public var player: PlayerID
    public var decision: Decision
    /// What to resume once answered: the engine keeps the continuation as data.
    public var resume: Resume
}

/// The continuation of an interrupted effect sequence (serialisable so multiplayer can pause here).
public struct Resume: Codable, Hashable, Sendable {
    public var source: ObjectID?
    public var controller: PlayerID
    public var effects: [Effect]           // what is left to resolve after the decision
    public var context: EffectContext
    public var kind: ResumeKind
    public init(source: ObjectID?, controller: PlayerID, effects: [Effect], context: EffectContext, kind: ResumeKind) {
        self.source = source; self.controller = controller; self.effects = effects; self.context = context; self.kind = kind
    }
}

public enum ResumeKind: Codable, Hashable, Sendable {
    case targets          // the response's targets become the context's targets, then continue
    case mode([[Effect]]) // chosen mode's effects are prepended
    case optional([Effect])
    case surveil, scry, explore, discover, sacrifice(Filter), none
    case cleanup, blockers, mulligan
}

/// Targets chosen and the last thing an effect touched, carried through an effect list.
public struct EffectContext: Codable, Hashable, Sendable {
    public var targets: [ObjectID] = []          // permanents or player objects (players use negative ids: -1 - playerID)
    public var lastTouched: ObjectID? = nil
    public var kicked = false
    public var previousHappened = true
    public var triggeringObject: ObjectID? = nil
    public init() {}
    public static func playerObject(_ p: PlayerID) -> ObjectID { -1 - p }
    public static func player(fromObject id: ObjectID) -> PlayerID? { id < 0 ? -1 - id : nil }
}

public struct CombatState: Codable, Hashable, Sendable {
    public var attackers: [ObjectID] = []
    public var blockers: [ObjectID: ObjectID] = [:]   // blocker -> attacker
    public var defender: PlayerID = 1
    public var firstStrikeDone = false
}

public struct GameState: Codable, Hashable, Sendable {
    public var players: [PlayerState]
    public var objects: [ObjectID: GameObject] = [:]
    public var nextObjectID: ObjectID = 1
    public var turn = 0
    public var activePlayer: PlayerID = 0
    public var phase: Phase = .untap
    public var combat = CombatState()
    public var pending: PendingDecision? = nil
    public var rng: SeededRNG
    public var winner: PlayerID? = nil
    public var started = false
    public var log: [GameEvent] = []
    public var actionCount = 0
    public var startingPlayer: PlayerID = 0
    public var declaredAttackersThisTurn = false
    /// Automatic turn steps still to run once the current decision is answered.
    public var turnContinuation: [Game.TurnStep] = []

    public init(playerNames: [String], bots: [Bool] = [false, false], seed: UInt64) {
        players = playerNames.enumerated().map { PlayerState(id: $0.offset, name: $0.element, isBot: bots.count > $0.offset ? bots[$0.offset] : false) }
        rng = SeededRNG(seed: seed)
    }

    public var isOver: Bool { winner != nil }
    public var playerCount: Int { players.count }
    public func opponent(of p: PlayerID) -> PlayerID { (p + 1) % players.count }
    public subscript(p: PlayerID) -> PlayerState { get { players[p] } set { players[p] = newValue } }

    /// The player who has to act right now.
    public var playerToAct: PlayerID? {
        if isOver { return nil }
        if let p = pending { return p.player }
        return activePlayer
    }

    public func object(_ id: ObjectID) -> GameObject? { objects[id] }
    public func permanents(of p: PlayerID) -> [GameObject] { players[p].battlefield.compactMap { objects[$0] } }
    public var allPermanents: [GameObject] { players.flatMap { permanents(of: $0.id) } }
}
