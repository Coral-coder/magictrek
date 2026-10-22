import XCTest
@testable import GameEngine
import CardKit

final class GameEngineTests: XCTestCase {
    let db = CardDatabase.shared

    func testStarterDecksAreLegal() {
        for faction in StarterDecks.factions {
            let deck = StarterDecks.deck(for: faction, db: db)
            XCTAssertEqual(deck.count, 60, faction.name)
            XCTAssertTrue(deck.isLegal(db: db), "\(faction.name): \(deck.problems(db: db))")
            let lands = deck.cards.filter { db[$0.key]?.isLand == true }.values.reduce(0, +)
            XCTAssertTrue((20...27).contains(lands), "\(faction.name) has \(lands) lands")
            let creatures = deck.cards.filter { db[$0.key]?.isCreature == true }.values.reduce(0, +)
            XCTAssertGreaterThan(creatures, 10, faction.name)
        }
    }

    /// Plays a whole game between two bots and returns the actions taken.
    @discardableResult
    func playBotGame(seed: UInt64, decks: [Deck], maxActions: Int = 3000, file: StaticString = #filePath, line: UInt = #line) throws -> (Game, [GameAction]) {
        var game = Game(playerNames: ["Kirk", "Picard"], bots: [true, true], seed: seed, db: db)
        var actions: [GameAction] = [.start(decks: decks.map(\.cardList))]
        try game.apply(actions[0])
        var steps = 0
        while !game.state.isOver, steps < maxActions {
            guard let p = game.state.playerToAct, let action = Bot.nextAction(game: game, player: p) else {
                XCTFail("Seed \(seed): nobody can act in \(game.state.phase) turn \(game.state.turn), pending \(String(describing: game.state.pending?.decision))", file: file, line: line)
                break
            }
            do { try game.apply(action, as: p) } catch {
                XCTFail("Seed \(seed) turn \(game.state.turn) \(game.state.phase): \(action) failed: \(error)", file: file, line: line)
                break
            }
            actions.append(action)
            steps += 1
        }
        return (game, actions)
    }

    func testBotGamesFinishAndReplayDeterministically() throws {
        let decks = StarterDecks.all(db: db)
        var finished = 0
        var totalTurns = 0
        for seed in 1...24 {
            let d1 = decks[Int(seed) % decks.count], d2 = decks[(Int(seed) + 1) % decks.count]
            let (game, actions) = try playBotGame(seed: UInt64(seed), decks: [d1, d2])
            if game.state.isOver { finished += 1 }
            totalTurns += game.state.turn
            // Replay: same seed and actions give the same state.
            var replay = Game(playerNames: ["Kirk", "Picard"], bots: [true, true], seed: UInt64(seed), db: db)
            for a in actions { try replay.apply(a) }
            XCTAssertEqual(replay.state, game.state, "seed \(seed) replay diverged")
            // Encoding round trip.
            let data = try JSONEncoder().encode(game.state)
            let decoded = try JSONDecoder().decode(GameState.self, from: data)
            XCTAssertEqual(decoded, game.state)
        }
        XCTAssertGreaterThanOrEqual(finished, 22, "only \(finished)/24 games finished")
        print("average turns per game: \(totalTurns / 24)")
    }

    func testEveryCardCanBeInAGameWithoutCrashing() throws {
        // Decks of every supported card, shuffled by seed, to shake out effect-resolution crashes.
        let all = db.distinctCards.filter { !$0.isBasicLand && $0.set != "sds" }
        let basics = ["Plains", "Island", "Swamp", "Mountain", "Forest"].compactMap { db.card(named: $0) }
        for seed in 1...8 {
            var rng = SeededRNG(seed: UInt64(seed) * 7919)
            let pick = all.shuffled(using: &rng)
            func deck(_ slice: ArraySlice<Card>) -> Deck {
                var cards: [String: Int] = [:]
                for c in slice.prefix(36) { cards[c.id] = 1 }
                for (i, b) in basics.enumerated() { cards[b.id] = i < 4 ? 5 : 4 }
                return Deck(name: "Chaos", cards: cards)
            }
            let d1 = deck(pick[0...]), d2 = deck(pick[40...])
            try playBotGame(seed: UInt64(seed), decks: [d1, d2], maxActions: 1500)
        }
    }

    // MARK: Rules

    func makeGame(hand1: [String], hand2: [String] = [], seed: UInt64 = 1) throws -> Game {
        var game = Game(playerNames: ["A", "B"], bots: [false, false], seed: seed, db: db)
        let filler = Array(repeating: db.card(named: "Plains")!.id, count: 40)
        try game.apply(.start(decks: [filler, filler]))
        // Deterministic setup: clear hands and give the chosen cards.
        for p in 0..<2 {
            for id in game.state.players[p].hand { game.move(id, to: .library, toBottom: true) }
            for cardID in (p == 0 ? hand1 : hand2) {
                let id = game.newObject(cardID: cardID, owner: p, zone: .hand)
                game.state.players[p].hand.append(id)
            }
        }
        try game.apply(.respond(.keep)); try game.apply(.respond(.keep))
        // Make player 0 active in main 1 regardless of the coin flip.
        if game.state.activePlayer != 0 {
            try game.apply(.endTurn)
            if let pending = game.state.pending, case .discardToHandSize = pending.decision { try game.apply(.respond(.cards(Array(game.state.players[1].hand.prefix(1))))) }
        }
        XCTAssertEqual(game.state.activePlayer, 0)
        XCTAssertEqual(game.state.phase, .main1)
        return game
    }

    func hand(_ game: Game, _ p: PlayerID, named: String) -> ObjectID? {
        game.state.players[p].hand.first { game.card($0)?.name == named }
    }

    func testCastCreatureAttackAndBlock() throws {
        let mountain = db.card(named: "Mountain")!.id
        var game = try makeGame(hand1: [mountain, mountain, "amoktime"].filter { db[$0] != nil } + [db.card(named: "Klingon Strike Force")?.id ?? mountain],
                                hand2: [db.card(named: "Starfleet Crew")?.id ?? mountain])
        let p0Lands = game.state.players[0].hand.filter { game.card($0)?.isLand == true }
        try game.apply(.playLand(p0Lands[0]))
        XCTAssertThrowsError(try game.apply(.playLand(p0Lands[1])), "one land per turn")
        XCTAssertEqual(game.state.permanents(of: 0).count, 1)
        try game.apply(.endTurn)
        XCTAssertEqual(game.state.activePlayer, 1)
        try game.apply(.endTurn)
        XCTAssertEqual(game.state.activePlayer, 0)
        try game.apply(.playLand(p0Lands[1]))
        // Give player 0 a cheap creature directly for the combat check.
        let bear = TokenSpec(name: "Officer", power: 2, toughness: 2, colors: [.red], subtypes: ["Officer"])
        game.createToken(bear, for: 0)
        let token = game.state.permanents(of: 0).first { $0.isToken }!.id
        XCTAssertFalse(game.canAttack(token), "summoning sick")
        try game.apply(.endTurn); try game.apply(.endTurn)
        XCTAssertTrue(game.canAttack(token))
        let lifeBefore = game.state.players[1].life
        try game.apply(.declareAttackers([token]))
        // No blockers for B: damage goes through.
        XCTAssertEqual(game.state.players[1].life, lifeBefore - 2)
        XCTAssertEqual(game.state.phase, .main2)
        try game.apply(.endTurn)
        // B gets a blocker and blocks next time.
        game.createToken(TokenSpec(name: "Guard", power: 1, toughness: 3), for: 1)
        let guardID = game.state.permanents(of: 1).first { $0.isToken }!.id
        try game.apply(.endTurn)
        try game.apply(.declareAttackers([token]))
        XCTAssertNotNil(game.state.pending)
        XCTAssertEqual(game.state.playerToAct, 1)
        try game.apply(.respond(.blockers([guardID: token])), as: 1)
        XCTAssertEqual(game.state.players[1].life, lifeBefore - 2, "blocked")
        XCTAssertEqual(game.state.objects[guardID]?.damage, 2, "damage stays marked until cleanup")
        XCTAssertEqual(game.state.objects[guardID]?.zone, .battlefield, "a 1/3 survives a 2/2")
        XCTAssertEqual(game.state.objects[token]?.damage, 1)
        XCTAssertEqual(game.state.phase, .main2)
    }

    func testBurstLightningKicked() throws {
        let burst = db.card(named: "Burst Lightning")!.id
        let mountain = db.card(named: "Mountain")!.id
        var game = try makeGame(hand1: [burst, mountain, mountain, mountain, mountain, mountain])
        for _ in 0..<5 {
            let land = game.state.players[0].hand.first { game.card($0)?.isLand == true }!
            try game.apply(.playLand(land))
            try game.apply(.endTurn); try game.apply(.endTurn)
        }
        let spell = hand(game, 0, named: "Burst Lightning")!
        XCTAssertTrue(game.canCast(spell, by: 0))
        let life = game.state.players[1].life
        try game.apply(.cast(spell, targets: [EffectContext.playerObject(1)], kicked: true, mode: nil, beamUpBounce: nil))
        XCTAssertEqual(game.state.players[1].life, life - 4)
        XCTAssertEqual(game.state.objects[spell]?.zone, .graveyard)
        XCTAssertEqual(game.state.permanents(of: 0).filter(\.tapped).count, 5)
    }

    func testStationMakesSpacecraftACreature() throws {
        let ship = db.card(named: "Suurok-Class Science Vessel")!
        var game = try makeGame(hand1: [])
        let id = game.newObject(cardID: ship.id, owner: 0, zone: .hand)
        game.move(id, to: .battlefield, controller: 0)
        game.createToken(TokenSpec(name: "Crew", power: 3, toughness: 3), for: 0)
        let crew = game.state.permanents(of: 0).first { $0.isToken }!.id
        try game.apply(.endTurn); try game.apply(.endTurn)
        XCTAssertFalse(game.characteristics(id).isCreature)
        try game.apply(.station(spacecraft: id, creature: crew))
        XCTAssertEqual(game.state.objects[id]?.chargeCounters, 3)
        XCTAssertFalse(game.characteristics(id).isCreature)
        XCTAssertTrue(game.state.objects[crew]!.tapped)
        try game.apply(.endTurn); try game.apply(.endTurn)
        try game.apply(.station(spacecraft: id, creature: crew))
        XCTAssertTrue(game.characteristics(id).isCreature, "5+ charge counters")
        XCTAssertTrue(game.characteristics(id).has(.flying))
        XCTAssertEqual(game.characteristics(id).power, 3)
    }
}
