// Developer tool: plays bot-vs-bot games and prints what happened.
//   swift run -c release SimTool [seed] [maxActions]
import CardKit
import GameEngine
import Foundation

let db = CardDatabase.shared
let args = CommandLine.arguments.dropFirst()
let seed = UInt64(args.first ?? "1") ?? 1
let maxActions = Int(args.dropFirst().first ?? "3000") ?? 3000
let decks = StarterDecks.all(db: db)
var game = Game(playerNames: ["Kirk", "Picard"], bots: [true, true], seed: seed, db: db)
let d1 = decks[Int(seed) % decks.count], d2 = decks[(Int(seed) + 1) % decks.count]
try game.apply(.start(decks: [d1.cardList, d2.cardList]))
print("\(d1.name) vs \(d2.name)")
var steps = 0
let start = Date()
var lastTurn = 0
while !game.state.isOver, steps < maxActions {
    guard let p = game.state.playerToAct, let action = Bot.nextAction(game: game, player: p) else {
        print("STUCK: phase \(game.state.phase) turn \(game.state.turn) pending \(String(describing: game.state.pending?.decision))"); break
    }
    if game.state.turn != lastTurn {
        lastTurn = game.state.turn
        let s = game.state
        print("T\(s.turn) \(s.players[s.activePlayer].name): life \(s.players[0].life)/\(s.players[1].life) perms \(s.permanents(of: 0).count)/\(s.permanents(of: 1).count) hand \(s.players[0].hand.count)/\(s.players[1].hand.count) [\(String(format: "%.1f", Date().timeIntervalSince(start)))s, \(steps) actions]")
    }
    if ProcessInfo.processInfo.environment["VERBOSE"] != nil { print("  \(p): \(action)") }
    do { try game.apply(action, as: p) } catch { print("ERROR \(action): \(error)"); break }
    steps += 1
}
print("done after \(steps) actions, \(game.state.turn) turns, winner \(game.state.winner.map { game.state.players[$0].name } ?? "none") in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
for e in game.state.log.suffix(12) { print("  ", e) }

// Determinism: replay the same actions and compare.
if ProcessInfo.processInfo.environment["REPLAY"] != nil {
    var original = Game(playerNames: ["Kirk", "Picard"], bots: [true, true], seed: seed, db: db)
    var actions: [GameAction] = [.start(decks: [d1.cardList, d2.cardList])]
    try original.apply(actions[0])
    var n = 0
    while !original.state.isOver, n < maxActions, let p = original.state.playerToAct, let a = Bot.nextAction(game: original, player: p) {
        try original.apply(a, as: p); actions.append(a); n += 1
    }
    var replay = Game(playerNames: ["Kirk", "Picard"], bots: [true, true], seed: seed, db: db)
    for (i, a) in actions.enumerated() {
        try replay.apply(a)
        if replay.state.log != original.state.log.prefix(replay.state.log.count).map({ $0 }) {
            let j = (0..<min(replay.state.log.count, original.state.log.count)).first { replay.state.log[$0] != original.state.log[$0] } ?? min(replay.state.log.count, original.state.log.count)
            print("DIVERGED at action \(i) \(a): log[\(j)] original=\(j < original.state.log.count ? "\(original.state.log[j])" : "-") replay=\(j < replay.state.log.count ? "\(replay.state.log[j])" : "-")")
            break
        }
    }
    print(replay.state == original.state ? "replay identical" : "replay DIFFERS (log same length \(replay.state.log.count == original.state.log.count))")
}
