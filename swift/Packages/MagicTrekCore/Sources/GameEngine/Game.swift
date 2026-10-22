import CardKit
import Foundation

/// The game: a state plus the rules that move it. Apply actions in order; the same actions on the
/// same seed always give the same state, which is what keeps two phones in sync.
public struct Game: Hashable, Sendable {
    public var state: GameState
    public let db: CardDatabase

    public static func == (a: Game, b: Game) -> Bool { a.state == b.state }
    public func hash(into h: inout Hasher) { state.hash(into: &h) }

    public init(state: GameState, db: CardDatabase = .shared) { self.state = state; self.db = db }

    public init(playerNames: [String], bots: [Bool] = [false, false], seed: UInt64, db: CardDatabase = .shared) {
        self.init(state: GameState(playerNames: playerNames, bots: bots, seed: seed), db: db)
    }

    public static let startingLife = 20
    public static let handSize = 7

    // MARK: - Applying actions

    public mutating func apply(_ action: GameAction) throws {
        if state.isOver { throw GameError("The game is over") }
        switch action {
        case .start(let decks): try start(decks: decks)
        case .respond(let r): try respond(r)
        case .concede: lose(state.activePlayer, reason: "\(state.players[state.activePlayer].name) conceded")
        case .timeOut(let p): lose(p, reason: "\(state.players[p].name) ran out of time")
        default:
            guard state.started else { throw GameError("The game hasn't started") }
            guard state.pending == nil else { throw GameError("Waiting for a decision") }
            switch action {
            case .playLand(let id): try playLand(id)
            case .cast(let id, let targets, let kicked, let mode, let bounce): try cast(id, targets: targets, kicked: kicked, mode: mode, beamUpBounce: bounce)
            case .activate(let id, let ability, let targets, let sac, let discard): try activate(id, ability: ability, targets: targets, sacrifice: sac, discard: discard)
            case .station(let s, let c): try station(s, with: c)
            case .equip(let e, let to): try equip(e, to: to)
            case .cycle(let id): try cycle(id)
            case .declareAttackers(let ids): try declareAttackers(ids); runContinuations()
            case .passPhase: try passPhase()
            case .endTurn: try endTurn()
            default: break
            }
        }
        state.actionCount += 1
        checkStateBasedActions()
    }

    /// Applies an action for a specific player, checking it is theirs to take.
    public mutating func apply(_ action: GameAction, as player: PlayerID) throws {
        switch action {
        case .start, .timeOut: break
        case .concede: lose(player, reason: "\(state.players[player].name) conceded"); return
        default:
            guard state.playerToAct == player else { throw GameError("Not your move") }
        }
        try apply(action)
    }

    // MARK: - Setup

    mutating func start(decks: [[String]]) throws {
        guard !state.started, decks.count == state.players.count else { throw GameError("Bad setup") }
        for (p, deck) in decks.enumerated() {
            for cardID in deck {
                guard db[cardID] != nil else { throw GameError("Unknown card \(cardID)") }
                let id = newObject(cardID: cardID, owner: p, zone: .library)
                state.players[p].library.append(id)
            }
            state.players[p].library.shuffle(using: &state.rng)
            state.players[p].life = Game.startingLife
        }
        state.started = true
        state.startingPlayer = Int(state.rng.next() % UInt64(state.players.count))
        state.activePlayer = state.startingPlayer
        log(.gameStarted(first: state.startingPlayer))
        for p in state.players.indices { draw(p, Game.handSize) }
        state.turn = 0
        askMulligan(state.startingPlayer)
    }

    mutating func askMulligan(_ p: PlayerID) {
        state.pending = PendingDecision(player: p, decision: .mulligan, resume: Resume(source: nil, controller: p, effects: [], context: EffectContext(), kind: .mulligan))
    }

    mutating func beginFirstTurn() {
        state.pending = nil
        beginTurn(state.startingPlayer, first: true)
    }

    @discardableResult
    mutating func newObject(cardID: String, owner: PlayerID, zone: Zone, token: TokenSpec? = nil) -> ObjectID {
        let id = state.nextObjectID
        state.nextObjectID += 1
        state.objects[id] = GameObject(id: id, cardID: cardID, owner: owner, zone: zone, token: token)
        return id
    }

    mutating func log(_ e: GameEvent) { state.log.append(e) }

    // MARK: - Zones

    mutating func removeFromZone(_ id: ObjectID) {
        guard let o = state.objects[id] else { return }
        let owner = o.owner
        switch o.zone {
        case .library: state.players[owner].library.removeAll { $0 == id }
        case .hand: state.players[owner].hand.removeAll { $0 == id }
        case .graveyard: state.players[owner].graveyard.removeAll { $0 == id }
        case .exile: state.players[owner].exile.removeAll { $0 == id }
        case .battlefield: state.players[o.controller].battlefield.removeAll { $0 == id }
        }
    }

    /// Moves an object to a zone of its owner (or controller, for the battlefield) and resets battlefield state.
    mutating func move(_ id: ObjectID, to zone: Zone, controller: PlayerID? = nil, tapped: Bool = false, toBottom: Bool = false) {
        guard var o = state.objects[id] else { return }
        let wasOnBattlefield = o.zone == .battlefield
        removeFromZone(id)
        if wasOnBattlefield {
            // Anything attached falls off.
            for other in state.allPermanents where other.attachedTo == id {
                state.objects[other.id]?.attachedTo = nil
                if parsed(other)?.isAura == true { move(other.id, to: .graveyard) }
            }
        }
        if o.isToken, zone != .battlefield {
            state.objects[id] = nil
            return
        }
        o.zone = zone
        o.tapped = tapped; o.damage = 0; o.counters = [:]; o.attachedTo = nil; o.untilEndOfTurn = []; o.frozen = false
        o.sacrificeAtEnd = false; o.activatedThisTurn = []; o.attacking = nil; o.blocking = nil; o.assimilated = false
        o.exiledWithThis = []; o.hasDealtDamage = false
        o.controller = zone == .battlefield ? (controller ?? o.owner) : o.owner
        if zone == .battlefield { o.enteredTurn = state.turn }
        state.objects[id] = o
        switch zone {
        case .library: if toBottom { state.players[o.owner].library.append(id) } else { state.players[o.owner].library.insert(id, at: 0) }
        case .hand: state.players[o.owner].hand.append(id)
        case .graveyard: state.players[o.owner].graveyard.append(id)
        case .exile: state.players[o.owner].exile.append(id)
        case .battlefield: state.players[o.controller].battlefield.append(id)
        }
    }

    mutating func draw(_ p: PlayerID, _ n: Int) {
        var drawn = 0
        for _ in 0..<n {
            guard let top = state.players[p].library.first else {
                lose(p, reason: "\(state.players[p].name) drew from an empty library"); break
            }
            move(top, to: .hand)
            drawn += 1
        }
        if drawn > 0 { log(.drew(player: p, count: drawn)) }
    }

    mutating func lose(_ p: PlayerID, reason: String) {
        guard state.winner == nil else { return }
        state.players[p].lost = true
        let remaining = state.players.filter { !$0.lost }
        if remaining.count == 1 {
            state.winner = remaining[0].id
            state.pending = nil
            log(.gameOver(winner: remaining[0].id, reason: reason))
        }
    }

    // MARK: - Turn structure

    mutating func beginTurn(_ p: PlayerID, first: Bool = false) {
        state.turn += 1
        state.activePlayer = p
        state.phase = .untap
        state.combat = CombatState()
        state.declaredAttackersThisTurn = false
        state.players[p].landsPlayedThisTurn = 0
        state.players[p].spellsCastThisTurn = 0
        state.players[p].lifeGainedThisTurn = 0
        state.players[p].noMaxHandSizeUntilNextTurn = false
        log(.turnBegan(turn: state.turn, player: p))
        // Untap
        for o in state.permanents(of: p) {
            var obj = state.objects[o.id]!
            obj.activatedThisTurn = []
            if obj.tapped {
                if obj.frozen { obj.frozen = false }
                else if let stun = obj.counters[.stun], stun > 0 {
                    obj.counters[.stun] = stun - 1
                    if obj.counters[.stun] == 0 { obj.counters[.stun] = nil }
                    log(.counters(object: o.id, kind: .stun, delta: -1))
                } else { obj.tapped = false; log(.untapped(object: o.id)) }
            }
            state.objects[o.id] = obj
        }
        // Upkeep
        state.phase = .upkeep
        log(.phase(.upkeep))
        for o in state.permanents(of: p) { fireTriggers(.upkeep, on: o.id) }
        for o in state.allPermanents { fireTriggers(.eachUpkeep, on: o.id) }
        guard state.pending == nil else { queueContinuation(.drawStep); return }
        drawStep(first: first)
    }

    mutating func drawStep(first: Bool) {
        state.phase = .draw
        log(.phase(.draw))
        if !(first && state.players.count == 2) { draw(state.activePlayer, 1) }
        // Sagas get a lore counter after the draw step.
        for o in state.permanents(of: state.activePlayer) where card(of: o)?.isSaga == true { advanceSaga(o.id) }
        guard state.pending == nil else { queueContinuation(.main1); return }
        state.phase = .main1
        log(.phase(.main1))
    }

    /// Steps the engine goes through on its own; if a decision interrupts, the next step is queued here.
    public enum TurnStep: Codable, Hashable, Sendable { case drawStep, main1, blockers, combatDamage, main2, endStep, cleanup, nextTurn }
    mutating func queueContinuation(_ step: TurnStep) { continuation.append(step) }
    var continuation: [TurnStep] { get { state.turnContinuation } set { state.turnContinuation = newValue } }

    mutating func runContinuations() {
        while state.pending == nil, !continuation.isEmpty, !state.isOver {
            let step = continuation.removeFirst()
            switch step {
            case .drawStep: drawStep(first: state.turn == 1)
            case .main1: state.phase = .main1; log(.phase(.main1))
            case .blockers: askBlockers()
            case .combatDamage: combatDamage()
            case .main2: state.phase = .main2; log(.phase(.main2))
            case .endStep: endStep()
            case .cleanup: cleanup()
            case .nextTurn: beginTurn(state.opponent(of: state.activePlayer))
            }
        }
    }

    mutating func passPhase() throws {
        switch state.phase {
        case .main1:
            state.phase = .beginCombat
            log(.phase(.beginCombat))
            for o in state.permanents(of: state.activePlayer) { fireTriggers(.beginCombat, on: o.id) }
            // Creatures that must attack are handled by the attacker declaration.
            state.phase = .declareAttackers
            log(.phase(.declareAttackers))
        case .beginCombat: state.phase = .declareAttackers
        case .declareAttackers: try declareAttackers([])
        case .main2: try endTurn()
        default: throw GameError("Nothing to pass in \(state.phase.label)")
        }
        runContinuations()
    }

    mutating func endTurn() throws {
        guard state.phase.isMain || state.phase == .declareAttackers || state.phase == .endCombat else { throw GameError("Can't end the turn now") }
        if state.phase == .main1 || state.phase == .declareAttackers {
            // Skip combat entirely.
            state.phase = .main2
        }
        queueContinuation(.endStep)
        runContinuations()
    }

    mutating func endStep() {
        state.phase = .end
        log(.phase(.end))
        let p = state.activePlayer
        for o in state.permanents(of: p) { fireTriggers(.endStep, on: o.id) }
        for o in state.allPermanents where o.sacrificeAtEnd { move(o.id, to: .graveyard); log(.died(object: o.id)) }
        queueContinuation(.cleanup)
    }

    mutating func cleanup() {
        state.phase = .cleanup
        let p = state.activePlayer
        let max = Game.handSize
        let noMax = state.players[p].noMaxHandSizeUntilNextTurn || state.permanents(of: p).contains { parsed($0)?.statics.contains(.noMaxHandSize) == true }
        if !noMax, state.players[p].hand.count > max {
            state.pending = PendingDecision(player: p, decision: .discardToHandSize(count: state.players[p].hand.count - max),
                                            resume: Resume(source: nil, controller: p, effects: [], context: EffectContext(), kind: .cleanup))
            queueContinuation(.nextTurn)
            return
        }
        finishCleanup()
        queueContinuation(.nextTurn)
    }

    mutating func finishCleanup() {
        for o in state.allPermanents {
            state.objects[o.id]?.damage = 0
            state.objects[o.id]?.untilEndOfTurn = []
            state.objects[o.id]?.attacking = nil
            state.objects[o.id]?.blocking = nil
            state.objects[o.id]?.hasDealtDamage = false
        }
        checkStateBasedActions()
    }

    // MARK: - Playing cards

    mutating func playLand(_ id: ObjectID) throws {
        let p = state.activePlayer
        guard canPlayLand(id, by: p) else { throw GameError("Can't play that land now") }
        state.players[p].landsPlayedThisTurn += 1
        var tapped = false
        if let parsed = parsed(state.objects[id]!) {
            for s in parsed.statics {
                switch s {
                case .entersTapped: tapped = true
                case .entersTappedUnless(let n): tapped = state.permanents(of: p).filter { characteristics($0.id).isLand }.count < n
                case .shockLand:
                    if state.players[p].life > 4 { changeLife(p, -2) } else { tapped = true }
                default: break
                }
            }
        }
        move(id, to: .battlefield, controller: p, tapped: tapped)
        log(.playedLand(player: p, object: id))
        enteredBattlefield(id, untapped: !tapped)
        for o in state.permanents(of: p) where o.id != id { fireTriggers(.landfall, on: o.id, touched: id) }
        runContinuations()
    }

    mutating func cast(_ id: ObjectID, targets: [ObjectID], kicked: Bool, mode: Int?, beamUpBounce: ObjectID?) throws {
        let p = state.activePlayer
        guard let o = state.objects[id], let card = card(of: o) else { throw GameError("No such card") }
        let parsed = db.parsed(card)
        var cost = card.cost
        var fromGraveyard = false
        if o.zone == .graveyard {
            guard let beam = parsed.beamMeUp, let bounce = beamUpBounce, let b = state.objects[bounce], b.zone == .battlefield, b.controller == p,
                  characteristics(bounce).isCreature else { throw GameError("Can't beam that up") }
            cost = beam; fromGraveyard = true
        } else {
            guard canCast(id, by: p) else { throw GameError("Can't cast that now") }
        }
        if kicked {
            guard let k = parsed.kicker else { throw GameError("No kicker") }
            cost.generic += k.generic
            for (c, n) in k.colored { cost.colored[c, default: 0] += n }
        }
        // Check targets.
        let reqs = targetRequirements(for: card, mode: mode)
        try validateTargets(targets, against: reqs, controller: p, source: id)
        // Ward: an opponent's permanent targeted costs extra.
        for t in targets where EffectContext.player(fromObject: t) == nil {
            if let tgt = state.objects[t], tgt.controller != p { cost.generic += characteristics(t).wardCost }
        }
        guard let plan = manaPlan(for: cost, player: p) else { throw GameError("Not enough mana") }
        payMana(plan)
        if fromGraveyard, let bounce = beamUpBounce { move(bounce, to: .hand); log(.bounced(object: bounce)) }
        state.players[p].spellsCastThisTurn += 1
        log(.cast(player: p, object: id, kicked: kicked))
        var context = EffectContext()
        context.targets = targets
        context.kicked = kicked
        if card.isPermanent {
            move(id, to: .battlefield, controller: p)
            if parsed.isAura, let host = targets.first { state.objects[id]?.attachedTo = host }
            enteredBattlefield(id, untapped: true)
        } else {
            var effects = parsed.spellEffects
            if let m = mode, let i = effects.firstIndex(where: { if case .modal = $0 { return true } else { return false } }), case .modal(let modes) = effects[i], m < modes.count {
                effects.replaceSubrange(i...i, with: modes[m])
            }
            resolve(effects, source: id, controller: p, context: context)
            if state.objects[id]?.zone != .battlefield { move(id, to: fromGraveyard ? .exile : .graveyard) }
        }
        // Spell-cast triggers.
        let kind: SpellKind = card.isCreature ? .creature : .noncreature
        for o in state.allPermanents where o.controller == p {
            for (event, fx) in grantedAndOwnTriggers(o.id) {
                if case .castSpell(let k) = event, k == .any || k == kind || (k == .artifact && card.isArtifact) || (k == .instantOrSorcery && (card.isInstant || card.isSorcery)) {
                    runTrigger(fx, source: o.id, touched: id)
                }
            }
        }
        runContinuations()
    }

    func validateTargets(_ targets: [ObjectID], against reqs: [(Filter, Int, Bool)], controller: PlayerID, source: ObjectID) throws {
        var i = 0
        for (filter, count, optional) in reqs {
            let legal = legalTargets(filter, controller: controller, source: source)
            var taken = 0
            while taken < count, i < targets.count, legal.contains(targets[i]) { taken += 1; i += 1 }
            if taken == 0, !optional, !legal.isEmpty { throw GameError("Choose a target") }
        }
    }

    mutating func payMana(_ plan: [ObjectID]) {
        for id in plan {
            guard let o = state.objects[id] else { continue }
            if let parsed = parsed(o), parsed.abilities.contains(where: { if case .activated(let c, _, _) = $0, c.sacrificeSelf, c.tap { return true } else { return false } }) {
                move(id, to: .graveyard)     // Treasure
            } else {
                state.objects[id]?.tapped = true
                log(.tapped(object: id))
                fireTriggers(.becomesTapped, on: id)
            }
        }
    }

    mutating func enteredBattlefield(_ id: ObjectID, untapped: Bool) {
        guard let o = state.objects[id] else { return }
        log(.entered(object: id))
        if card(of: o)?.isSaga == true { advanceSaga(id) }
        fireTriggers(.enters, on: id)
        if untapped { fireTriggers(.entersUntapped, on: id) }
        let c = characteristics(id)
        for other in state.allPermanents where other.id != id {
            for (event, fx) in grantedAndOwnTriggers(other.id) {
                if case .permanentEnters(let f) = event, matches(f, id, controller: other.controller, source: other.id, base: c) {
                    runTrigger(fx, source: other.id, touched: id)
                }
                if event == .landfall, c.isLand, other.controller == o.controller, o.zone == .battlefield, other.id != id, state.phase != .main1 || true {
                    // landfall is fired by playLand / land effects explicitly to avoid double counting
                }
            }
        }
    }

    mutating func activate(_ id: ObjectID, ability index: Int, targets: [ObjectID], sacrifice: ObjectID?, discard: ObjectID?) throws {
        let p = state.activePlayer
        guard let o = state.objects[id], o.controller == p, o.zone == .battlefield, let parsed = parsed(o),
              index < parsed.abilities.count, case .activated(let cost, let effects, let sorcerySpeed) = parsed.abilities[index] else { throw GameError("No such ability") }
        if sorcerySpeed, !state.phase.isMain { throw GameError("Only as a sorcery") }
        if cost.oncePerTurn, o.activatedThisTurn.contains(index) { throw GameError("Already used this turn") }
        if cost.tap { guard !o.tapped else { throw GameError("Already tapped") }; if characteristics(id).isCreature, hasSummoningSickness(o) { throw GameError("Summoning sick") } }
        if cost.payLife > 0, state.players[p].life <= cost.payLife { throw GameError("Not enough life") }
        var sacID: ObjectID? = nil
        if let f = cost.sacrifice {
            guard let s = sacrifice, matches(f, s, controller: p, source: id), state.objects[s]?.controller == p else { throw GameError("Choose something to sacrifice") }
            sacID = s
        }
        if cost.discard > 0 { guard let d = discard, state.objects[d]?.zone == .hand, state.objects[d]?.owner == p else { throw GameError("Choose a card to discard") } }
        try validateTargets(targets, against: targetRequirements(in: effects), controller: p, source: id)
        var mana = cost.mana
        for t in targets where EffectContext.player(fromObject: t) == nil {
            if let tgt = state.objects[t], tgt.controller != p { mana.generic += characteristics(t).wardCost }
        }
        guard let plan = manaPlan(for: mana, player: p) else { throw GameError("Not enough mana") }
        payMana(plan)
        if cost.tap { state.objects[id]?.tapped = true; log(.tapped(object: id)); fireTriggers(.becomesTapped, on: id) }
        if cost.payLife > 0 { changeLife(p, -cost.payLife) }
        if let d = discard, cost.discard > 0 { move(d, to: .graveyard); log(.discarded(player: p, object: d)) }
        if let s = sacID { move(s, to: .graveyard); log(.died(object: s)); fireDies(s) }
        if cost.sacrificeSelf { move(id, to: .graveyard); log(.died(object: id)) }
        state.objects[id]?.activatedThisTurn.insert(index)
        log(.activated(object: id, text: name(id)))
        var context = EffectContext(); context.targets = targets
        resolve(effects, source: id, controller: p, context: context)
        runContinuations()
    }

    mutating func station(_ spacecraft: ObjectID, with creature: ObjectID) throws {
        let p = state.activePlayer
        guard state.phase.isMain, let s = state.objects[spacecraft], s.controller == p, let c = state.objects[creature], c.controller == p, !c.tapped,
              spacecraft != creature, characteristics(spacecraft).isSpacecraft, parsed(s)?.has(.station) == true else { throw GameError("Can't station that") }
        let cc = characteristics(creature)
        guard cc.isCreature, !hasSummoningSickness(c) else { throw GameError("That creature can't station yet") }
        let wasCreature = characteristics(spacecraft).isCreature
        state.objects[creature]?.tapped = true
        log(.tapped(object: creature))
        fireTriggers(.becomesTapped, on: creature)
        addCounters(.charge, max(cc.power, 0), to: spacecraft)
        log(.stationed(spacecraft: spacecraft, by: creature, counters: cc.power))
        for o in state.permanents(of: p) { fireTriggers(.stationed, on: o.id, touched: spacecraft) }
        if !wasCreature, characteristics(spacecraft).isCreature { log(.becameCreature(object: spacecraft)) }
        runContinuations()
    }

    mutating func equip(_ equipment: ObjectID, to creature: ObjectID) throws {
        let p = state.activePlayer
        guard state.phase.isMain, let e = state.objects[equipment], e.controller == p, let parsed = parsed(e), let cost = parsed.equipCost,
              let c = state.objects[creature], c.controller == p, characteristics(creature).isCreature else { throw GameError("Can't equip that") }
        guard let plan = manaPlan(for: cost, player: p) else { throw GameError("Not enough mana") }
        payMana(plan)
        state.objects[equipment]?.attachedTo = creature
        log(.equipped(equipment: equipment, to: creature))
    }

    mutating func cycle(_ id: ObjectID) throws {
        let p = state.activePlayer
        guard let o = state.objects[id], o.zone == .hand, o.owner == p, let parsed = parsed(o), let (cost, landType) = parsed.cycling else { throw GameError("Can't cycle that") }
        guard let plan = manaPlan(for: cost, player: p) else { throw GameError("Not enough mana") }
        payMana(plan)
        move(id, to: .graveyard)
        log(.discarded(player: p, object: id))
        if let landType {
            if let found = state.players[p].library.first(where: { lib in
                guard let c = card(lib) else { return false }
                return landType == "basic" ? c.isBasicLand : c.subtypes.contains(landType)
            }) { move(found, to: .hand); log(.searched(player: p, object: found)) }
            state.players[p].library.shuffle(using: &state.rng)
        } else { draw(p, 1) }
        runContinuations()
    }

    // MARK: - Life, damage, counters

    mutating func changeLife(_ p: PlayerID, _ delta: Int) {
        guard delta != 0 else { return }
        state.players[p].life += delta
        log(.lifeChanged(player: p, delta: delta))
        if delta > 0 {
            state.players[p].lifeGainedThisTurn += delta
            for o in state.permanents(of: p) { fireTriggers(.gainLife, on: o.id) }
        }
    }

    /// Damage to a creature or player object. Returns the damage actually dealt.
    @discardableResult
    mutating func dealDamage(_ amount: Int, to target: ObjectID, from source: ObjectID?, combat: Bool = false) -> Int {
        guard amount > 0 else { return 0 }
        if let p = EffectContext.player(fromObject: target) {
            changeLife(p, -amount)
            log(.damage(to: target, amount: amount, source: source))
            if let s = source, characteristics(s).has(.lifelink) { changeLife(state.objects[s]?.controller ?? p, amount) }
            return amount
        }
        guard let o = state.objects[target], o.zone == .battlefield, characteristics(target).isCreature else { return 0 }
        state.objects[target]?.damage += amount
        if let s = source, characteristics(s).has(.deathtouch) { state.objects[target]?.damage += 1000 }
        log(.damage(to: target, amount: amount, source: source))
        if let s = source, characteristics(s).has(.lifelink) { changeLife(state.objects[s]?.controller ?? o.controller, amount) }
        return amount
    }

    mutating func addCounters(_ kind: CounterKind, _ n: Int, to id: ObjectID) {
        guard n != 0, state.objects[id]?.zone == .battlefield else { return }
        state.objects[id]?.counters[kind, default: 0] += n
        log(.counters(object: id, kind: kind, delta: n))
    }

    mutating func destroy(_ id: ObjectID) {
        guard let o = state.objects[id], o.zone == .battlefield else { return }
        if characteristics(id).has(.indestructible) { return }
        move(id, to: .graveyard)
        log(.destroyed(object: id))
        fireDies(id)
    }

    mutating func fireDies(_ id: ObjectID) {
        // The object is already in the graveyard; its dies-triggers still fire from its card.
        guard let o = state.objects[id] ?? nil else { return }
        if let parsed = card(of: o).map(db.parsed) {
            for fx in parsed.triggers(.dies) { runTrigger(fx, source: id, touched: id, leftBattlefield: true) }
            for fx in parsed.triggers(.leaves) { runTrigger(fx, source: id, touched: id, leftBattlefield: true) }
        }
        for other in state.allPermanents {
            for (event, fx) in grantedAndOwnTriggers(other.id) {
                if case .permanentDies(let f) = event, matchesDead(f, id, controller: other.controller, source: other.id) { runTrigger(fx, source: other.id, touched: id) }
            }
        }
    }

    func matchesDead(_ f: Filter, _ id: ObjectID, controller: PlayerID, source: ObjectID?) -> Bool {
        guard let o = state.objects[id], let c = card(of: o) else { return false }
        if f.other, id == source { return false }
        if f.controller == .you, o.owner != controller { return false }
        if f.controller == .opponent, o.owner == controller { return false }
        switch f.kind {
        case .creature: return c.isCreature
        case .artifact: return c.isArtifact
        case .permanent: return true
        default: return c.isCreature
        }
    }

    // MARK: - State-based actions

    mutating func checkStateBasedActions() {
        guard state.started, !state.isOver else { return }
        var changed = true
        var rounds = 0
        while changed, rounds < 10 {
            changed = false; rounds += 1
            for p in state.players where !p.lost && p.life <= 0 { lose(p.id, reason: "\(p.name) is out of life"); changed = true }
            if state.isOver { return }
            for o in state.allPermanents {
                let c = characteristics(o.id)
                if c.isCreature {
                    if c.toughness <= 0 { move(o.id, to: .graveyard); log(.died(object: o.id)); fireDies(o.id); changed = true; continue }
                    if o.damage >= c.toughness, !c.has(.indestructible) { move(o.id, to: .graveyard); log(.died(object: o.id)); fireDies(o.id); changed = true; continue }
                }
                if let host = o.attachedTo {
                    if state.objects[host]?.zone != .battlefield || (parsed(o)?.isAura == true && !characteristics(host).isCreature) {
                        state.objects[o.id]?.attachedTo = nil
                        if parsed(o)?.isAura == true { move(o.id, to: .graveyard); log(.died(object: o.id)); changed = true }
                    }
                }
                // Legend rule: the newest stays.
                if let legend = card(of: o), legend.isLegendary {
                    let same = state.permanents(of: o.controller).filter { card(of: $0)?.name == legend.name }
                    if same.count > 1, let oldest = same.min(by: { $0.id < $1.id }), oldest.id == o.id {
                        move(o.id, to: .graveyard); log(.died(object: o.id)); changed = true
                    }
                }
            }
        }
    }
}
