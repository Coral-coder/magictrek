import CardKit

/// Everything a player can do. Actions are the unit of replay and of multiplayer sync: a game is
/// its seed plus its ordered actions.
public enum GameAction: Codable, Hashable, Sendable {
    case start(decks: [[String]])                       // card ids per player, in seat order
    case respond(DecisionResponse)
    case playLand(ObjectID)
    case cast(ObjectID, targets: [ObjectID], kicked: Bool, mode: Int?, beamUpBounce: ObjectID?)
    case activate(ObjectID, ability: Int, targets: [ObjectID], sacrifice: ObjectID?, discard: ObjectID?)
    case station(spacecraft: ObjectID, creature: ObjectID)
    case equip(ObjectID, to: ObjectID)
    case cycle(ObjectID)
    case declareAttackers([ObjectID])
    case passPhase                                      // move on from the current phase
    case endTurn
    case concede
    case timeOut(PlayerID)                              // a player ran out of time: counts as a concession

    public var isDecisionResponse: Bool { if case .respond = self { return true } else { return false } }
}

public struct GameError: Error, CustomStringConvertible, Hashable, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}
