import CardKit
import Foundation

/// The computer opponent: simple, fast heuristics. Also answers choices the engine makes on a
/// player's behalf (an opponent discarding, a bot's surveil).
public enum Bot {
    /// The next action for the bot, or nil when it has nothing left to do this phase.
    public static func nextAction(game: Game, player p: PlayerID) -> GameAction? {
        let s = game.state
        guard !s.isOver else { return nil }
        if let pending = s.pending {
            guard pending.player == p else { return nil }
            return .respond(decide(game: game, decision: pending.decision, player: p))
        }
        guard s.activePlayer == p else { return nil }
        switch s.phase {
        case .main1, .main2:
            if let land = bestLand(game: game, player: p) { return .playLand(land) }
            if let station = bestStation(game: game, player: p) { return station }
            if let cast = bestCast(game: game, player: p) { return cast }
            if let equip = bestEquip(game: game, player: p) { return equip }
            if let act = bestActivation(game: game, player: p) { return act }
            if let cyc = bestCycle(game: game, player: p) { return cyc }
            if s.phase == .main1 {
                let attackers = chooseAttackers(game: game, player: p)
                return .declareAttackers(attackers)
            }
            return .endTurn
        case .declareAttackers, .beginCombat:
            return .declareAttackers(chooseAttackers(game: game, player: p))
        case .endCombat: return .passPhase
        default: return .passPhase
        }
    }

    // MARK: Decisions

    public static func decide(game: Game, decision: Decision, player p: PlayerID) -> DecisionResponse {
        switch decision {
        case .mulligan:
            let hand = game.state.players[p].hand
            let lands = hand.filter { game.card($0)?.isLand == true }.count
            let bad = (lands <= 1 || lands >= 6) && game.state.players[p].mulligans < 2
            return bad ? .mulligan : .keep
        case .declareBlockers(let attackers): return .blockers(chooseBlockers(game: game, player: p, attackers: attackers))
        case .chooseTargets(_, let f, let count, let optional, let candidates):
            return .targets(chooseTargets(game: game, filter: f, count: count, optional: optional, candidates: candidates, controller: p, effect: nil))
        case .chooseMode(_, let modes): return .mode(modes.isEmpty ? 0 : min(1, modes.count - 1))
        case .chooseOptional: return .yes
        case .discardToHandSize(let count): return .cards(discardChoice(game: game, player: p, count: count))
        case .chooseSacrifice(_, let candidates): return .sacrifice(sacrificeChoice(game: game, candidates: candidates))
        case .surveil(let cards): return .cards(surveil(game: game, cards: cards, controller: p))
        case .scry(let cards): return .cards(scry(game: game, cards: cards, controller: p))
        case .explore(let card, _): return .exploreGraveyard(exploreToGraveyard(game: game, card: card, controller: p))
        case .discoverChoice: return .discoverPlay(true)
        }
    }

    // MARK: Valuation

    /// Rough worth of a permanent: used to pick targets and trades.
    public static func value(_ id: ObjectID, game: Game) -> Int {
        if EffectContext.player(fromObject: id) != nil { return 0 }
        let c = game.characteristics(id)
        var v = 0
        if c.isCreature { v += c.power * 2 + c.toughness + c.keywords.count * 2 }
        if c.isLand { v += 2 }
        if c.isArtifact || c.isEnchantment { v += 3 }
        if let card = game.card(id) { v += card.manaValue }
        return v
    }

    static func cardValue(_ id: ObjectID, game: Game) -> Int {
        guard let card = game.card(id) else { return 0 }
        return card.manaValue * 2 + (card.isCreature ? card.basePower + card.baseToughness : 2) + (card.isLand ? 1 : 0)
    }

    public static func chooseTargets(game: Game, filter f: Filter, count: Int, optional: Bool, candidates: [ObjectID], controller p: PlayerID, effect: Effect?) -> [ObjectID] {
        guard !candidates.isEmpty else { return [] }
        // Is this effect good or bad for its target?
        var harmful = true
        if let e = effect {
            switch e {
            case .pump(let pw, let t, _, _): harmful = pw < 0 || t < 0
            case .addCounters(let k, _, _): harmful = k == .minusOne || k == .stun
            case .grantKeyword, .untap, .explore, .draw, .gainLife, .createTokens, .searchBasicLand: harmful = false
            case .exile, .destroy, .bounce, .damage, .tap, .loseLife, .discard, .mill, .sacrifice, .cantBlock, .fight, .bite, .gainControl: harmful = true
            default: harmful = true
            }
        }
        let opponents = candidates.filter { id in
            if let pl = EffectContext.player(fromObject: id) { return pl != p }
            return game.state.objects[id]?.controller != p
        }
        let mine = candidates.filter { !opponents.contains($0) }
        var pool = harmful ? opponents : mine
        if pool.isEmpty { if optional { return [] }; pool = candidates }
        // Damage: go face when it is lethal, otherwise kill the biggest creature it can.
        if case .damage(let a, _) = effect ?? .doubleLife, case .fixed(let n) = a {
            let opp = game.state.opponent(of: p)
            if pool.contains(EffectContext.playerObject(opp)), game.state.players[opp].life <= n { return [EffectContext.playerObject(opp)] }
            let killable = pool.filter { EffectContext.player(fromObject: $0) == nil && game.characteristics($0).toughness - (game.state.objects[$0]?.damage ?? 0) <= n }
            if let best = killable.max(by: { value($0, game: game) < value($1, game: game) }) { return [best] }
            if pool.contains(EffectContext.playerObject(opp)) { return [EffectContext.playerObject(opp)] }
        }
        let sorted = pool.sorted { value($0, game: game) > value($1, game: game) }
        return Array(sorted.prefix(count))
    }

    public static func discardChoice(game: Game, player p: PlayerID, count: Int) -> [ObjectID] {
        let hand = game.state.players[p].hand
        let lands = game.state.permanents(of: p).filter { game.characteristics($0.id).isLand }.count
        // Spare lands first when flooded, then the most expensive spells.
        let sorted = hand.sorted { a, b in
            let ca = game.card(a), cb = game.card(b)
            let la = ca?.isLand == true, lb = cb?.isLand == true
            if la != lb { return lands >= 6 ? la : lb }
            return (ca?.manaValue ?? 0) > (cb?.manaValue ?? 0)
        }
        return Array(sorted.prefix(count))
    }

    public static func sacrificeChoice(game: Game, candidates: [ObjectID]) -> ObjectID {
        candidates.min { value($0, game: game) < value($1, game: game) } ?? candidates[0]
    }

    public static func bestCard(game: Game, among: [ObjectID]) -> ObjectID? {
        among.max { cardValue($0, game: game) < cardValue($1, game: game) }
    }

    public static func surveil(game: Game, cards: [ObjectID], controller p: PlayerID) -> [ObjectID] {
        let lands = game.state.permanents(of: p).filter { game.characteristics($0.id).isLand }.count
        return cards.filter { id in
            guard let c = game.card(id) else { return false }
            if c.isLand { return lands >= 5 }
            return c.manaValue > lands + 3
        }
    }

    public static func scry(game: Game, cards: [ObjectID], controller p: PlayerID) -> [ObjectID] { surveil(game: game, cards: cards, controller: p) }

    public static func exploreToGraveyard(game: Game, card: ObjectID, controller p: PlayerID) -> Bool { !surveil(game: game, cards: [card], controller: p).isEmpty }

    public static func chooseMode(game: Game, modes: [[Effect]], controller p: PlayerID, source: ObjectID?) -> Int {
        // Prefer a mode whose targets exist; otherwise the first.
        for (i, m) in modes.enumerated() {
            let reqs = game.targetRequirements(in: m)
            if reqs.allSatisfy({ !game.legalTargets($0.0, controller: p, source: source).isEmpty }) { return i }
        }
        return 0
    }

    public static func wantsOptional(game: Game, effects: [Effect], controller p: PlayerID, source: ObjectID?) -> Bool {
        for e in effects {
            switch e {
            case .sacrifice(let t, _) where t == .you: return false
            case .payLife(let n): return game.state.players[p].life > n + 5
            case .discard(_, let t) where t == .you: return false
            case .loseLife(_, let t) where t == .you: return false
            default: break
            }
        }
        return true
    }

    /// The basic land type a player would most like to find.
    public static func preferredBasicLand(game: Game, player p: PlayerID) -> String? {
        var need: [ManaColor: Int] = [:]
        for id in game.state.players[p].hand { for (c, n) in (game.card(id)?.cost.colored ?? [:]) { need[c, default: 0] += n } }
        var have: [ManaColor: Int] = [:]
        for o in game.state.permanents(of: p) { for c in game.parsed(o)?.manaColors ?? [] { have[c, default: 0] += 1 } }
        let best = ManaColor.allCases.filter { need[$0] != nil }.max { (need[$0]! - (have[$0] ?? 0)) < (need[$1]! - (have[$1] ?? 0)) }
        return best?.basicLandType
    }

    // MARK: Main phase choices

    static func bestLand(game: Game, player p: PlayerID) -> ObjectID? {
        let lands = game.state.players[p].hand.filter { game.canPlayLand($0, by: p) }
        guard !lands.isEmpty else { return nil }
        // The land that adds a color the hand needs; untapped lands when something is castable.
        var have: Set<ManaColor> = []
        for o in game.state.permanents(of: p) { for c in game.parsed(o)?.manaColors ?? [] { have.insert(c) } }
        var need: Set<ManaColor> = []
        for id in game.state.players[p].hand { for c in game.card(id)?.cost.colored.keys ?? [:].keys { need.insert(c) } }
        return lands.max { a, b in
            func score(_ id: ObjectID) -> Int {
                guard let card = game.card(id) else { return 0 }
                let parsed = game.db.parsed(card)
                let colors = Set(parsed.manaColors)
                var s = colors.intersection(need).subtracting(have).count * 10 + colors.count
                if parsed.statics.contains(.entersTapped) { s -= 3 }
                return s
            }
            return score(a) < score(b)
        }
    }

    static func bestCast(game: Game, player p: PlayerID) -> GameAction? {
        let hand = game.state.players[p].hand.filter { game.canCast($0, by: p) }
        let opp = game.state.opponent(of: p)
        var best: (GameAction, Int)? = nil
        for id in hand {
            guard let card = game.card(id) else { continue }
            let parsed = game.db.parsed(card)
            // Unsupported spells do nothing: don't waste mana on instants and sorceries with no effects.
            if (card.isInstant || card.isSorcery), parsed.spellEffects.isEmpty { continue }
            var mode: Int? = nil
            if let modal = parsed.spellEffects.first(where: { if case .modal = $0 { return true } else { return false } }), case .modal(let modes) = modal {
                mode = chooseMode(game: game, modes: modes, controller: p, source: id)
            }
            var targets: [ObjectID] = []
            var ok = true
            var targetValue = 0
            for (f, n, optional) in game.targetRequirements(for: card, mode: mode) {
                let legal = game.legalTargets(f, controller: p, source: id)
                let effect = parsed.spellEffects.first { if case .target(let ff, _, _) = targetOf($0) { return ff == f } else { return false } }
                let chosen = chooseTargets(game: game, filter: f, count: n, optional: optional, candidates: legal, controller: p, effect: effect)
                if chosen.isEmpty, !optional { ok = false; break }
                // Don't aim removal at our own stuff.
                if let first = chosen.first, EffectContext.player(fromObject: first) == nil, game.state.objects[first]?.controller == p, isHarmful(effect) { ok = false; break }
                targetValue += chosen.map { value($0, game: game) }.reduce(0, +)
                targets += chosen
            }
            if !ok { continue }
            var kicked = false
            if let k = parsed.kicker {
                var cost = card.cost; cost.generic += k.generic; for (c, n) in k.colored { cost.colored[c, default: 0] += n }
                kicked = game.canPay(cost, player: p)
            }
            var score = card.manaValue * 3 + (card.isCreature ? card.basePower + card.baseToughness : 0) + targetValue
            if card.isInstant || card.isSorcery {
                if targetValue == 0, parsed.spellEffects.contains(where: { if case .damage = $0 { return true } else { return false } }) { score -= 5 }
            }
            if card.isLegendary, game.state.permanents(of: p).contains(where: { game.card(of: $0)?.name == card.name }) { continue }
            if game.state.players[opp].life <= 0 { continue }
            if score > (best?.1 ?? Int.min) { best = (.cast(id, targets: targets, kicked: kicked, mode: mode, beamUpBounce: nil), score) }
        }
        return best?.0
    }

    static func targetOf(_ e: Effect) -> Target? {
        switch e {
        case .damage(_, let t), .destroy(let t), .exile(let t), .bounce(let t), .tap(let t, _), .pump(_, _, let t, _), .addCounters(_, _, let t),
             .grantKeyword(_, let t, _), .fight(let t), .bite(let t), .cantBlock(let t, _), .gainControl(let t), .untap(let t), .explore(let t): return t
        default: return nil
        }
    }

    static func isHarmful(_ e: Effect?) -> Bool {
        guard let e else { return false }
        switch e {
        case .pump(let pw, let t, _, _): return pw < 0 || t < 0
        case .addCounters(let k, _, _): return k == .minusOne || k == .stun
        case .grantKeyword, .untap, .explore: return false
        default: return true
        }
    }

    static func bestStation(game: Game, player p: PlayerID) -> GameAction? {
        guard game.state.phase.isMain else { return nil }
        let spacecraft = game.state.permanents(of: p).filter { game.characteristics($0.id).isSpacecraft && !game.characteristics($0.id).isCreature && game.parsed($0)?.has(.station) == true }
        guard let ship = spacecraft.first else { return nil }
        // Station with creatures that wouldn't attack profitably anyway: the weakest untapped, non-sick creature.
        let opp = game.state.opponent(of: p)
        let oppCreatures = game.state.permanents(of: opp).filter { game.characteristics($0.id).isCreature }
        let candidates = game.state.permanents(of: p).filter { o in
            o.id != ship.id && !o.tapped && game.characteristics(o.id).isCreature && !game.hasSummoningSickness(o) && game.characteristics(o.id).power > 0
        }
        guard let threshold = game.parsed(ship)?.stationThreshold else { return nil }
        let need = threshold - ship.chargeCounters
        // Only in main 2 (after attacking) unless a single creature gets it over the line, or there is nothing to attack into.
        let pick = candidates.max { game.characteristics($0.id).power < game.characteristics($1.id).power }
        guard let c = pick else { return nil }
        let power = game.characteristics(c.id).power
        if game.state.phase == .main2 || power >= need || oppCreatures.count > candidates.count {
            return .station(spacecraft: ship.id, creature: c.id)
        }
        return nil
    }

    static func bestEquip(game: Game, player p: PlayerID) -> GameAction? {
        guard game.state.phase.isMain else { return nil }
        for e in game.state.permanents(of: p) {
            guard let cost = game.parsed(e)?.equipCost, e.attachedTo == nil, game.canPay(cost, player: p) else { continue }
            let creatures = game.state.permanents(of: p).filter { game.characteristics($0.id).isCreature && !game.hasSummoningSickness($0) }
            if let best = creatures.max(by: { game.characteristics($0.id).power < game.characteristics($1.id).power }) { return .equip(e.id, to: best.id) }
        }
        return nil
    }

    static func bestActivation(game: Game, player p: PlayerID) -> GameAction? {
        for o in game.state.permanents(of: p) {
            guard let parsed = game.parsed(o) else { continue }
            for (i, a) in parsed.abilities.enumerated() {
                guard case .activated(let cost, let fx, let sorcery) = a else { continue }
                if sorcery, !game.state.phase.isMain { continue }
                if cost.oncePerTurn, o.activatedThisTurn.contains(i) { continue }
                if cost.tap, o.tapped { continue }
                if cost.sacrificeSelf, fx.count == 1, case .addMana = fx[0] { continue }      // Treasure: used by manaPlan
                if cost.sacrificeSelf, cost.tap, fx.count == 1, case .draw = fx[0], game.state.players[p].hand.count > 3 { continue } // Clue: keep for later
                if cost.discard > 0 || cost.sacrifice != nil || cost.payLife > 0 { continue }
                if cost.tap, game.characteristics(o.id).isCreature, (game.hasSummoningSickness(o) || game.state.phase == .main1) { continue }
                if fx.contains(where: { if case .addMana = $0 { return true } else { return false } }) { continue }
                guard game.canPay(cost.mana, player: p) else { continue }
                var targets: [ObjectID] = []
                var ok = true
                for (f, n, optional) in game.targetRequirements(in: fx) {
                    let legal = game.legalTargets(f, controller: p, source: o.id)
                    let chosen = chooseTargets(game: game, filter: f, count: n, optional: optional, candidates: legal, controller: p, effect: fx.first)
                    if chosen.isEmpty, !optional { ok = false; break }
                    if let first = chosen.first, EffectContext.player(fromObject: first) == nil, game.state.objects[first]?.controller == p, isHarmful(fx.first) { ok = false; break }
                    targets += chosen
                }
                if !ok { continue }
                // Keep mana for spells first: only activate in main 2 or when nothing castable remains.
                if game.state.phase == .main1, !cost.mana.isFree, bestCast(game: game, player: p) != nil { continue }
                return .activate(o.id, ability: i, targets: targets, sacrifice: nil, discard: nil)
            }
        }
        return nil
    }

    static func bestCycle(game: Game, player p: PlayerID) -> GameAction? {
        let lands = game.state.permanents(of: p).filter { game.characteristics($0.id).isLand }.count
        for id in game.state.players[p].hand {
            guard let card = game.card(id), let (cost, _) = game.db.parsed(card).cycling, game.canPay(cost, player: p) else { continue }
            if card.manaValue > lands + 2, game.state.phase == .main2 { return .cycle(id) }
        }
        return nil
    }

    // MARK: Combat

    static func chooseAttackers(game: Game, player p: PlayerID) -> [ObjectID] {
        let opp = game.state.opponent(of: p)
        let blockers = game.state.permanents(of: opp).filter { !$0.tapped && game.characteristics($0.id).isCreature && !game.characteristics($0.id).has(.cantBlock) }
        let mine = game.state.permanents(of: p).filter { game.canAttack($0.id) }
        let oppLife = game.state.players[opp].life
        let totalPower = mine.map { max(game.characteristics($0.id).power, 0) }.reduce(0, +)
        var attackers: [ObjectID] = []
        for o in mine {
            let c = game.characteristics(o.id)
            if c.has(.mustAttack) { attackers.append(o.id); continue }
            if c.power <= 0 { continue }
            // All-in when it's lethal through no blocks, or the opponent is nearly dead.
            if totalPower >= oppLife + blockers.map { game.characteristics($0.id).toughness }.reduce(0, +) { attackers.append(o.id); continue }
            let canBeBlockedBy = blockers.filter { game.canBlock($0.id, o.id) }
            if canBeBlockedBy.isEmpty { attackers.append(o.id); continue }
            // Safe if no single blocker both survives and kills it.
            let dies = canBeBlockedBy.contains { b in
                let bc = game.characteristics(b.id)
                let kills = bc.power >= c.toughness || bc.has(.deathtouch)
                let survives = c.power < bc.toughness && !c.has(.deathtouch)
                return kills && (survives || bc.power + bc.toughness < c.power + c.toughness)
            }
            if !dies || c.has(.vigilance) && !dies { attackers.append(o.id) }
            else if oppLife <= 6, c.power >= 2 { attackers.append(o.id) }
        }
        return attackers
    }

    static func chooseBlockers(game: Game, player p: PlayerID, attackers: [ObjectID]) -> [ObjectID: ObjectID] {
        var blocks: [ObjectID: ObjectID] = [:]
        var free = game.state.permanents(of: p).filter { game.characteristics($0.id).isCreature && !$0.tapped }
        let life = game.state.players[p].life
        let incoming = attackers.map { max(game.characteristics($0).power, 0) }.reduce(0, +)
        let desperate = incoming >= life
        for a in attackers.sorted(by: { game.characteristics($0).power > game.characteristics($1).power }) {
            let ac = game.characteristics(a)
            let menace = ac.has(.menace)
            let options = free.filter { game.canBlock($0.id, a) }
            // Best block: kills the attacker and survives; else chump only when desperate.
            let good = options.filter { b in
                let bc = game.characteristics(b.id)
                let kills = bc.power >= ac.toughness || bc.has(.deathtouch)
                let survives = ac.power < bc.toughness && !ac.has(.deathtouch) || ac.has(.firstStrike) == false && bc.has(.firstStrike) && kills
                return kills && survives
            }
            let trade = options.filter { b in
                let bc = game.characteristics(b.id)
                let kills = bc.power >= ac.toughness || bc.has(.deathtouch)
                return kills && value(b.id, game: game) <= value(a, game: game)
            }
            var chosen: [ObjectID] = []
            if let g = good.min(by: { value($0.id, game: game) < value($1.id, game: game) }) { chosen = [g.id] }
            else if let t = trade.min(by: { value($0.id, game: game) < value($1.id, game: game) }) { chosen = [t.id] }
            else if desperate, let c = options.min(by: { value($0.id, game: game) < value($1.id, game: game) }) { chosen = [c.id] }
            if menace {
                if chosen.count == 1, let second = options.first(where: { $0.id != chosen[0] }) { chosen.append(second.id) } else { chosen = [] }
            }
            for b in chosen { blocks[b] = a; free.removeAll { $0.id == b } }
        }
        return blocks
    }
}
