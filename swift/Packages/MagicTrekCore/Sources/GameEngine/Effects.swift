import CardKit
import Foundation

extension Game {
    /// A permanent's own triggers plus the ones statics on the battlefield grant it.
    func grantedAndOwnTriggers(_ id: ObjectID) -> [(TriggerEvent, [Effect])] {
        guard let o = state.objects[id] else { return [] }
        var out: [(TriggerEvent, [Effect])] = []
        if let parsed = parsed(o) {
            for a in parsed.abilities { if case .triggered(let e, let fx) = a { out.append((e, fx)) } }
        }
        for other in state.allPermanents {
            guard let p = parsed(other) else { continue }
            for s in p.statics {
                if case .grantTrigger(let f, let e, let fx) = s, matches(f, id, controller: other.controller, source: other.id) { out.append((e, fx)) }
            }
        }
        return out
    }

    mutating func fireTriggers(_ event: TriggerEvent, on id: ObjectID, touched: ObjectID? = nil) {
        guard state.objects[id]?.zone == .battlefield else { return }
        for (e, fx) in grantedAndOwnTriggers(id) where e == event { runTrigger(fx, source: id, touched: touched) }
    }

    mutating func runTrigger(_ effects: [Effect], source: ObjectID, touched: ObjectID?, leftBattlefield: Bool = false) {
        guard let o = state.objects[source] else { return }
        if !leftBattlefield, o.zone != .battlefield { return }
        log(.triggered(object: source, text: name(source)))
        var context = EffectContext()
        context.lastTouched = touched ?? source
        context.triggeringObject = touched
        resolve(effects, source: source, controller: o.controller, context: context)
    }

    // MARK: - Resolving

    /// Resolves effects in order. Pauses (storing the rest in `state.pending`) when a player must choose.
    mutating func resolve(_ effects: [Effect], source: ObjectID?, controller: PlayerID, context: EffectContext) {
        var ctx = context
        var queue = effects
        // A kicked spell replaces the base effects with the kicked ones.
        if ctx.kicked, let i = queue.firstIndex(where: { if case .kickedInstead = $0 { return true } else { return false } }), case .kickedInstead(let alt) = queue[i] {
            queue = alt + Array(queue[(i + 1)...])
        }
        while !queue.isEmpty, !state.isOver {
            if state.pending != nil {
                // Something earlier in this list needs a decision: park what's left.
                state.pending!.resume.effects = queue + state.pending!.resume.effects
                return
            }
            let e = queue.removeFirst()
            let happened = apply(e, source: source, controller: controller, context: &ctx, remaining: &queue)
            if state.pending != nil {
                // The effect asked a question; what is left resumes after the answer.
                state.pending!.resume.effects = queue
                state.pending!.resume.context = ctx
                return
            }
            ctx.previousHappened = happened
        }
    }

    /// The chosen target(s) of a Target in the current context, as object ids (players as player objects).
    func resolveTarget(_ t: Target, source: ObjectID?, controller: PlayerID, context: inout EffectContext) -> [ObjectID] {
        switch t {
        case .this: return source.map { [$0] } ?? []
        case .you: return [EffectContext.playerObject(controller)]
        case .lastTarget:
            if let last = context.lastTouched { return [last] }
            if !context.targets.isEmpty { return [context.targets.removeFirst()] }   // kicked "instead" effects inherit the spell's target
            return source.map { [$0] } ?? []
        case .controllerOfLastTarget:
            guard let last = context.lastTouched else { return [] }
            if let p = EffectContext.player(fromObject: last) { return [last] }
            return state.objects[last].map { [EffectContext.playerObject($0.controller)] } ?? []
        case .attachedCreature: return source.flatMap { state.objects[$0]?.attachedTo }.map { [$0] } ?? []
        case .each(let f):
            if f.isPlayerFilter { return state.players.filter { !$0.lost && (f.kind == .player || $0.id != controller) }.map { EffectContext.playerObject($0.id) } }
            return state.allPermanents.filter { matches(f, $0.id, controller: controller, source: source) }.map(\.id)
        case .target(let f, let count, _):
            // Take the next chosen targets that fit this filter.
            var taken: [ObjectID] = []
            while taken.count < count, !context.targets.isEmpty {
                let id = context.targets[0]
                if legalTargets(f, controller: controller, source: source).contains(id) || (EffectContext.player(fromObject: id) != nil && (f.isPlayerFilter || f.kind == .creatureOrPlayer)) {
                    taken.append(id); context.targets.removeFirst()
                } else { break }
            }
            return taken
        }
    }

    /// Asks the player for targets if the effect needs some that weren't chosen up front (triggers).
    mutating func needTargets(_ t: Target, source: ObjectID?, controller: PlayerID, context: inout EffectContext, prompt: String, remaining: [Effect], current: Effect) -> Bool {
        guard case .target(let f, let count, let optional) = t, context.targets.isEmpty else { return false }
        let candidates = legalTargets(f, controller: controller, source: source)
        if candidates.isEmpty { return false }
        if candidates.count == 1, !optional { context.targets = candidates; return false }
        if state.players[controller].isBot {
            context.targets = Bot.chooseTargets(game: self, filter: f, count: count, optional: optional, candidates: candidates, controller: controller, effect: current)
            return false
        }
        state.pending = PendingDecision(player: controller, decision: .chooseTargets(prompt: prompt, filter: f, count: count, optional: optional, candidates: candidates),
                                        resume: Resume(source: source, controller: controller, effects: [current] + remaining, context: context, kind: .targets))
        return true
    }

    /// Applies one effect. Returns whether it did anything (for "If you do").
    mutating func apply(_ e: Effect, source: ObjectID?, controller: PlayerID, context ctx: inout EffectContext, remaining: inout [Effect]) -> Bool {
        func targets(_ t: Target, prompt: String) -> [ObjectID]? {
            if needTargets(t, source: source, controller: controller, context: &ctx, prompt: prompt, remaining: remaining, current: e) { remaining = []; return nil }
            let ids = resolveTarget(t, source: source, controller: controller, context: &ctx)
            if let last = ids.last { ctx.lastTouched = last }
            return ids
        }
        let srcName = source.map(name) ?? "Effect"
        switch e {
        case .damage(let a, let t):
            guard let ids = targets(t, prompt: "\(srcName): choose what to damage") else { return false }
            let n = amount(a, controller: controller, source: source, context: ctx)
            var any = false
            for id in ids { any = dealDamage(n, to: id, from: source) > 0 || any }
            return any
        case .draw(let a, let t):
            guard let ids = targets(t, prompt: "\(srcName): who draws") else { return false }
            let n = amount(a, controller: controller, source: source, context: ctx)
            for id in ids { if let p = EffectContext.player(fromObject: id) { draw(p, n) } }
            return true
        case .gainLife(let a, let t):
            guard let ids = targets(t, prompt: "\(srcName): who gains life") else { return false }
            let n = amount(a, controller: controller, source: source, context: ctx)
            for id in ids { if let p = EffectContext.player(fromObject: id) { changeLife(p, n) } }
            return true
        case .loseLife(let a, let t):
            guard let ids = targets(t, prompt: "\(srcName): who loses life") else { return false }
            let n = amount(a, controller: controller, source: source, context: ctx)
            for id in ids { if let p = EffectContext.player(fromObject: id) { changeLife(p, -n) } }
            return true
        case .destroy(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose what to destroy") else { return false }
            for id in ids { destroy(id) }
            return !ids.isEmpty
        case .exile(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose what to exile") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield {
                move(id, to: .exile); log(.exiled(object: id))
                if let s = source { state.objects[s]?.exiledWithThis.append(id) }
            }
            return !ids.isEmpty
        case .bounce(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose what to return") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { move(id, to: .hand); log(.bounced(object: id)) }
            return !ids.isEmpty
        case .tap(let t, _):
            guard let ids = targets(t, prompt: "\(srcName): choose what to tap") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { state.objects[id]?.tapped = true; log(.tapped(object: id)); fireTriggers(.becomesTapped, on: id) }
            return !ids.isEmpty
        case .untap(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose what to untap") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { state.objects[id]?.tapped = false; log(.untapped(object: id)) }
            return !ids.isEmpty
        case .pump(let p, let tg, let t, _):
            guard let ids = targets(t, prompt: "\(srcName): choose a creature") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { state.objects[id]?.untilEndOfTurn.append(.pump(power: p, toughness: tg)) }
            return !ids.isEmpty
        case .addCounters(let kind, let a, let t):
            guard let ids = targets(t, prompt: "\(srcName): choose where the counters go") else { return false }
            let n = amount(a, controller: controller, source: source, context: ctx)
            for id in ids { addCounters(kind, n, to: id) }
            return !ids.isEmpty
        case .createTokens(let spec, let a, let t):
            guard let ids = targets(t, prompt: "\(srcName): who gets the tokens") else { return false }
            let n = amount(a, controller: controller, source: source, context: ctx)
            for id in ids { if let p = EffectContext.player(fromObject: id) { for _ in 0..<n { createToken(spec, for: p) } } }
            return true
        case .surveil(let n):
            let top = Array(state.players[controller].library.prefix(n))
            if top.isEmpty { return false }
            if state.players[controller].isBot {
                let toGrave = Bot.surveil(game: self, cards: top, controller: controller)
                finishSurveil(controller, toGraveyard: toGrave, cards: top); return true
            }
            state.pending = PendingDecision(player: controller, decision: .surveil(cards: top), resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .surveil))
            remaining = []
            return true
        case .scry(let n):
            let top = Array(state.players[controller].library.prefix(n))
            if top.isEmpty { return false }
            if state.players[controller].isBot {
                let toBottom = Bot.scry(game: self, cards: top, controller: controller)
                finishScry(controller, toBottom: toBottom, cards: top); return true
            }
            state.pending = PendingDecision(player: controller, decision: .scry(cards: top), resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .scry))
            remaining = []
            return true
        case .mill(let n, let t):
            guard let ids = targets(t, prompt: "\(srcName): who mills") else { return false }
            for id in ids { if let p = EffectContext.player(fromObject: id) { for _ in 0..<n { if let top = state.players[p].library.first { move(top, to: .graveyard); log(.milled(player: p, object: top)) } } } }
            return true
        case .discard(let n, let t):
            guard let ids = targets(t, prompt: "\(srcName): who discards") else { return false }
            for id in ids {
                guard let p = EffectContext.player(fromObject: id) else { continue }
                let hand = state.players[p].hand
                if hand.isEmpty { continue }
                let count = min(n, hand.count)
                if p == controller, !state.players[p].isBot {
                    state.pending = PendingDecision(player: p, decision: .discardToHandSize(count: count), resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .none))
                    remaining = []
                    return true
                }
                // Opponents and bots discard the highest-cost cards automatically.
                let chosen = Bot.discardChoice(game: self, player: p, count: count)
                for c in chosen { move(c, to: .graveyard); log(.discarded(player: p, object: c)) }
            }
            return true
        case .searchBasicLand(let dest, let t):
            guard let ids = targets(t, prompt: "\(srcName): whose library") else { return false }
            for id in ids {
                guard let p = EffectContext.player(fromObject: id) else { continue }
                let want = Bot.preferredBasicLand(game: self, player: p)
                if let found = state.players[p].library.first(where: { card($0)?.isBasicLand == true && (want == nil || card($0)?.name == want) })
                    ?? state.players[p].library.first(where: { card($0)?.isBasicLand == true }) {
                    switch dest {
                    case .hand: move(found, to: .hand)
                    case .battlefield: move(found, to: .battlefield, controller: p); enteredBattlefield(found, untapped: true)
                    case .battlefieldTapped: move(found, to: .battlefield, controller: p, tapped: true); enteredBattlefield(found, untapped: false)
                    }
                    log(.searched(player: p, object: found))
                    if dest != .hand { for o in state.permanents(of: p) where o.id != found { fireTriggers(.landfall, on: o.id, touched: found) } }
                } else { log(.searched(player: p, object: nil)) }
                state.players[p].library.shuffle(using: &state.rng)
            }
            return true
        case .sacrifice(let t, let f):
            guard let ids = targets(t, prompt: "\(srcName): who sacrifices") else { return false }
            if f.kind == .token, source != nil, t == .you, f == Filter(.token), let s = source, state.objects[s]?.cardID != "", !(state.objects[s]?.isToken ?? false) {
                // "Sacrifice ~" as an effect.
                move(s, to: .graveyard); log(.died(object: s)); fireDies(s); return true
            }
            var any = false
            for id in ids {
                guard let p = EffectContext.player(fromObject: id) else { continue }
                let candidates = state.permanents(of: p).filter { matches(f, $0.id, controller: p, source: nil) }.map(\.id)
                if candidates.isEmpty { continue }
                if !state.players[p].isBot, candidates.count > 1 {
                    state.pending = PendingDecision(player: p, decision: .chooseSacrifice(prompt: "\(srcName): choose what to sacrifice", candidates: candidates),
                                                    resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .sacrifice(f)))
                    remaining = []
                    return true
                }
                let chosen = candidates.count == 1 ? candidates[0] : Bot.sacrificeChoice(game: self, candidates: candidates)
                move(chosen, to: .graveyard); log(.died(object: chosen)); fireDies(chosen); any = true
            }
            return any
        case .grantKeyword(let k, let t, _):
            guard let ids = targets(t, prompt: "\(srcName): choose a creature") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { state.objects[id]?.untilEndOfTurn.append(.keyword(k)) }
            return !ids.isEmpty
        case .cantBlock(let t, _):
            guard let ids = targets(t, prompt: "\(srcName): choose a creature") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { state.objects[id]?.untilEndOfTurn.append(.cantBlock) }
            return !ids.isEmpty
        case .returnFromGraveyard(let f, let dest):
            var filter = f; filter.controller = f.controller == .any ? .you : f.controller
            let candidates = legalTargets(filter, controller: controller, source: source)
            if candidates.isEmpty { return false }
            var chosen: ObjectID? = ctx.targets.first(where: { candidates.contains($0) })
            if let c = chosen { ctx.targets.removeAll { $0 == c } }
            if chosen == nil {
                if state.players[controller].isBot || candidates.count == 1 { chosen = Bot.bestCard(game: self, among: candidates) }
                else {
                    state.pending = PendingDecision(player: controller, decision: .chooseTargets(prompt: "\(srcName): choose a card in your graveyard", filter: filter, count: 1, optional: false, candidates: candidates),
                                                    resume: Resume(source: source, controller: controller, effects: [e] + remaining, context: ctx, kind: .targets))
                    remaining = []
                    return true
                }
            }
            guard let id = chosen else { return false }
            switch dest {
            case .hand: move(id, to: .hand)
            case .battlefield: move(id, to: .battlefield, controller: controller); enteredBattlefield(id, untapped: true)
            case .battlefieldTapped: move(id, to: .battlefield, controller: controller, tapped: true); enteredBattlefield(id, untapped: false)
            }
            ctx.lastTouched = id
            return true
        case .fight(let t):
            guard let s = source, let ids = targets(t, prompt: "\(srcName): choose what to fight"), let other = ids.first else { return false }
            fight(s, other); return true
        case .fightBetween(let a, let b):
            guard let first = targets(a, prompt: "\(srcName): choose your creature"), let x = first.first else { return false }
            guard let second = targets(b, prompt: "\(srcName): choose the creature it fights"), let y = second.first else { return false }
            fight(x, y); return true
        case .bite(let t):
            guard let s = source, let ids = targets(t, prompt: "\(srcName): choose what to bite"), let other = ids.first else { return false }
            dealDamage(characteristics(s).power, to: other, from: s); return true
        case .explore(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose a creature to explore") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield {
                guard let top = state.players[controller].library.first else { continue }
                if card(top)?.isLand == true { move(top, to: .hand); log(.explored(creature: id, landFound: true)) }
                else {
                    addCounters(.plusOne, 1, to: id); log(.explored(creature: id, landFound: false))
                    if state.players[controller].isBot {
                        if Bot.exploreToGraveyard(game: self, card: top, controller: controller) { move(top, to: .graveyard) }
                    } else {
                        state.pending = PendingDecision(player: controller, decision: .explore(card: top, creature: id), resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .explore))
                        remaining = []
                        return true
                    }
                }
            }
            return true
        case .addMana:
            return false   // mana abilities are used through manaPlan, not as resolved effects
        case .doubleLife:
            let l = state.players[controller].life; changeLife(controller, l); return true
        case .noMaxHandSize:
            state.players[controller].noMaxHandSizeUntilNextTurn = true; return true
        case .putLandFromHand(let tapped):
            if let land = state.players[controller].hand.first(where: { card($0)?.isLand == true }) {
                move(land, to: .battlefield, controller: controller, tapped: tapped)
                enteredBattlefield(land, untapped: !tapped)
                for o in state.permanents(of: controller) where o.id != land { fireTriggers(.landfall, on: o.id, touched: land) }
                return true
            }
            return false
        case .modal(let modes):
            if state.players[controller].isBot {
                let i = Bot.chooseMode(game: self, modes: modes, controller: controller, source: source)
                remaining = modes[i] + remaining; return true
            }
            if modes.count == 1 { remaining = modes[0] + remaining; return true }
            state.pending = PendingDecision(player: controller, decision: .chooseMode(prompt: "\(srcName): choose one", modes: modes.map { describe($0) }),
                                            resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .mode(modes)))
            remaining = []
            return true
        case .optional(let inner):
            if state.players[controller].isBot {
                if Bot.wantsOptional(game: self, effects: inner, controller: controller, source: source) { remaining = inner + remaining; return true }
                return false
            }
            state.pending = PendingDecision(player: controller, decision: .chooseOptional(prompt: "\(srcName): \(describe(inner))?"),
                                            resume: Resume(source: source, controller: controller, effects: remaining, context: ctx, kind: .optional(inner)))
            remaining = []
            return true
        case .ifDidPrevious(let inner):
            if ctx.previousHappened { remaining = inner + remaining }
            return ctx.previousHappened
        case .kickedInstead: return false
        case .conditional(let cond, let inner):
            guard let s = source else { return false }
            let isCreature = characteristics(s).isCreature
            if (cond == .thisIsCreature) == isCreature { remaining = inner + remaining; return true }
            return false
        case .gainControl(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose what to take") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield && state.objects[id]?.controller != controller {
                removeFromZone(id); state.objects[id]?.controller = controller; state.players[controller].battlefield.append(id)
                state.objects[id]?.enteredTurn = state.turn
            }
            return !ids.isEmpty
        case .sacrificeAtEndOfTurn(let t):
            guard let ids = targets(t, prompt: "") else { return false }
            for id in ids { state.objects[id]?.sacrificeAtEnd = true }
            return true
        case .assimilate(let f):
            var filter = f
            let candidates = legalTargets(filter, controller: controller, source: source)
            if candidates.isEmpty { return false }
            var chosen: ObjectID? = ctx.targets.first(where: { candidates.contains($0) })
            if let c = chosen { ctx.targets.removeAll { $0 == c } }
            if chosen == nil {
                if state.players[controller].isBot || candidates.count == 1 { chosen = Bot.bestCard(game: self, among: candidates) }
                else {
                    filter.controller = f.controller
                    state.pending = PendingDecision(player: controller, decision: .chooseTargets(prompt: "\(srcName): choose a creature card to assimilate", filter: filter, count: 1, optional: false, candidates: candidates),
                                                    resume: Resume(source: source, controller: controller, effects: [e] + remaining, context: ctx, kind: .targets))
                    remaining = []
                    return true
                }
            }
            guard let id = chosen else { return false }
            assimilate(id, by: controller); return true
        case .assimilateFromLibrary(let t):
            guard let ids = targets(t, prompt: "\(srcName): choose an opponent"), let who = ids.first, let p = EffectContext.player(fromObject: who) else { return false }
            var exiled: [ObjectID] = []
            var found: ObjectID? = nil
            while let top = state.players[p].library.first {
                move(top, to: .exile)
                if card(top)?.isCreature == true { found = top; break }
                exiled.append(top)
            }
            if let f = found { assimilate(f, by: controller) }
            exiled.shuffle(using: &state.rng)
            for id in exiled { move(id, to: .library, toBottom: true) }
            return found != nil
        case .assimilateExiledOrExile(let t):
            guard let s = source else { return false }
            let exiledCreatures = (state.objects[s]?.exiledWithThis ?? []).filter { state.objects[$0]?.zone == .exile && card($0)?.isCreature == true }
            if let pick = exiledCreatures.first {
                state.objects[s]?.exiledWithThis.removeAll { $0 == pick }
                assimilate(pick, by: controller); return true
            }
            guard let ids = targets(t, prompt: "\(srcName): choose a creature to exile") else { return false }
            for id in ids where state.objects[id]?.zone == .battlefield { move(id, to: .exile); log(.exiled(object: id)); state.objects[s]?.exiledWithThis.append(id) }
            return !ids.isEmpty
        case .discover(let n):
            var exiled: [ObjectID] = []
            var found: ObjectID? = nil
            while let top = state.players[controller].library.first {
                move(top, to: .exile)
                if let c = card(top), !c.isLand, c.manaValue <= n { found = top; break }
                exiled.append(top)
            }
            exiled.shuffle(using: &state.rng)
            for id in exiled { move(id, to: .library, toBottom: true) }
            guard let f = found else { return false }
            playFree(f, controller: controller)
            return true
        case .payLife(let n):
            if state.players[controller].life > n { changeLife(controller, -n); return true }
            return false
        case .payMana(let cost):
            if let plan = manaPlan(for: cost, player: controller) { payMana(plan); return true }
            return false
        case .copyToken(let t, let extra):
            guard let ids = targets(t, prompt: "\(srcName): choose what to copy") else { return false }
            for id in ids {
                guard let o = state.objects[id], o.zone == .battlefield else { continue }
                var spec = o.token ?? TokenSpec(name: name(id))
                spec.keywords += extra
                let copy = newObject(cardID: o.cardID, owner: controller, zone: .battlefield, token: spec)
                state.objects[copy]?.controller = controller
                state.objects[copy]?.enteredTurn = state.turn
                state.players[controller].battlefield.append(copy)
                log(.tokenCreated(player: controller, object: copy))
                enteredBattlefield(copy, untapped: true)
            }
            return !ids.isEmpty
        }
    }

    mutating func createToken(_ spec: TokenSpec, for p: PlayerID) {
        let id = newObject(cardID: "", owner: p, zone: .battlefield, token: spec)
        state.objects[id]?.controller = p
        state.objects[id]?.enteredTurn = state.turn
        state.players[p].battlefield.append(id)
        log(.tokenCreated(player: p, object: id))
        enteredBattlefield(id, untapped: true)
    }

    mutating func fight(_ a: ObjectID, _ b: ObjectID) {
        guard state.objects[a]?.zone == .battlefield, state.objects[b]?.zone == .battlefield else { return }
        let pa = characteristics(a).power, pb = characteristics(b).power
        dealDamage(pa, to: b, from: a)
        dealDamage(pb, to: a, from: b)
        log(.fought(a: a, b: b))
    }

    mutating func assimilate(_ id: ObjectID, by p: PlayerID) {
        move(id, to: .battlefield, controller: p)
        state.objects[id]?.assimilated = true
        addCounters(.plusOne, 1, to: id)
        log(.assimilated(object: id, by: p))
        enteredBattlefield(id, untapped: true)
    }

    /// Puts a permanent onto the battlefield, or resolves a spell with bot-chosen targets, for free.
    mutating func playFree(_ id: ObjectID, controller p: PlayerID) {
        guard let c = card(id) else { return }
        if c.isPermanent {
            move(id, to: .battlefield, controller: p)
            if db.parsed(c).isAura {
                if let host = legalTargets(.creature, controller: p, source: id).first { state.objects[id]?.attachedTo = host } else { move(id, to: .graveyard); return }
            }
            enteredBattlefield(id, untapped: true)
        } else {
            let parsed = db.parsed(c)
            var ctx = EffectContext()
            for (f, n, _) in targetRequirements(for: c, mode: nil) {
                let legal = legalTargets(f, controller: p, source: id)
                ctx.targets += Bot.chooseTargets(game: self, filter: f, count: n, optional: true, candidates: legal, controller: p, effect: nil)
            }
            log(.cast(player: p, object: id, kicked: false))
            resolve(parsed.spellEffects, source: id, controller: p, context: ctx)
            if state.objects[id]?.zone == .exile { move(id, to: .graveyard) }
        }
    }

    mutating func advanceSaga(_ id: ObjectID) {
        guard let o = state.objects[id], o.zone == .battlefield, let parsed = parsed(o) else { return }
        var chapters: [[Effect]] = []
        for a in parsed.abilities { if case .saga(let c) = a { chapters = c } }
        addCounters(.lore, 1, to: id)
        let n = state.objects[id]?.counters[.lore] ?? 1
        log(.sagaChapter(object: id, chapter: n))
        if n - 1 < chapters.count {
            var ctx = EffectContext(); ctx.lastTouched = id
            resolve(chapters[n - 1], source: id, controller: o.controller, context: ctx)
        }
        let last = max(chapters.count, 3)
        if n >= last, state.pending == nil { move(id, to: .graveyard); log(.died(object: id)) }
    }

    mutating func finishSurveil(_ p: PlayerID, toGraveyard: [ObjectID], cards: [ObjectID]) {
        for id in cards where toGraveyard.contains(id) { move(id, to: .graveyard) }
        log(.surveilled(player: p, graveyard: toGraveyard.count, top: cards.count - toGraveyard.count))
    }

    mutating func finishScry(_ p: PlayerID, toBottom: [ObjectID], cards: [ObjectID]) {
        for id in cards where toBottom.contains(id) { move(id, to: .library, toBottom: true) }
    }

    // MARK: - Decisions

    mutating func respond(_ r: DecisionResponse) throws {
        guard let pending = state.pending else { throw GameError("Nothing to decide") }
        let resume = pending.resume
        state.pending = nil
        switch (pending.decision, r) {
        case (.mulligan, .keep):
            state.players[pending.player].keptHand = true
            let next = state.opponent(of: pending.player)
            if !state.players[next].keptHand { askMulligan(next) } else { beginFirstTurn() }
            runContinuations()
            return
        case (.mulligan, .mulligan):
            let p = pending.player
            state.players[p].mulligans += 1
            for id in state.players[p].hand { move(id, to: .library) }
            state.players[p].library.shuffle(using: &state.rng)
            let n = max(Game.handSize - state.players[p].mulligans, 1)
            draw(p, n)
            log(.mulliganed(player: p, to: n))
            askMulligan(p)
            return
        case (.declareBlockers, .blockers(let blocks)):
            do { try acceptBlockers(blocks) } catch { state.pending = pending; throw error }
        case (.declareBlockers, .no):
            try acceptBlockers([:])
        case (.chooseTargets(_, let f, let count, let optional, let candidates), .targets(let ids)):
            let chosen = ids.filter { candidates.contains($0) }.prefix(count)
            if chosen.isEmpty, !optional, !candidates.isEmpty { state.pending = pending; throw GameError("Choose a target") }
            var ctx = resume.context
            ctx.targets = Array(chosen)
            if chosen.isEmpty {
                // Optional target skipped: drop the effect waiting on it.
                let rest = Array(resume.effects.dropFirst())
                resolve(rest, source: resume.source, controller: resume.controller, context: ctx)
            } else {
                _ = f
                resolve(resume.effects, source: resume.source, controller: resume.controller, context: ctx)
            }
        case (.chooseMode(_, let labels), .mode(let i)):
            guard case .mode(let modes) = resume.kind, i < modes.count, i < labels.count else { state.pending = pending; throw GameError("Bad mode") }
            resolve(modes[i] + resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        case (.chooseOptional, .yes):
            guard case .optional(let inner) = resume.kind else { break }
            resolve(inner + resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        case (.chooseOptional, .no):
            var ctx = resume.context; ctx.previousHappened = false
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: ctx)
        case (.discardToHandSize(let count), .cards(let ids)):
            let p = pending.player
            let valid = ids.filter { state.players[p].hand.contains($0) }
            guard valid.count == min(count, state.players[p].hand.count) else { state.pending = pending; throw GameError("Discard \(count) cards") }
            for id in valid { move(id, to: .graveyard); log(.discarded(player: p, object: id)) }
            if case .cleanup = resume.kind { finishCleanup() }
            else { resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context) }
        case (.chooseSacrifice(_, let candidates), .sacrifice(let id)):
            guard candidates.contains(id) else { state.pending = pending; throw GameError("Choose one of the candidates") }
            move(id, to: .graveyard); log(.died(object: id)); fireDies(id)
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        case (.surveil(let cards), .cards(let ids)):
            finishSurveil(pending.player, toGraveyard: ids.filter { cards.contains($0) }, cards: cards)
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        case (.scry(let cards), .cards(let ids)):
            finishScry(pending.player, toBottom: ids.filter { cards.contains($0) }, cards: cards)
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        case (.explore(let cardID, _), .exploreGraveyard(let yes)):
            if yes, state.players[pending.player].library.first == cardID { move(cardID, to: .graveyard) }
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        case (.discoverChoice(let cardID), .discoverPlay(let play)):
            if play { playFree(cardID, controller: pending.player) } else { move(cardID, to: .hand) }
            resolve(resume.effects, source: resume.source, controller: resume.controller, context: resume.context)
        default:
            state.pending = pending
            throw GameError("That answer doesn't fit the question")
        }
        runContinuations()
    }

    /// A short description of effects, for prompts.
    public func describe(_ effects: [Effect]) -> String {
        effects.map { describe($0) }.joined(separator: "; ")
    }

    public func describe(_ e: Effect) -> String {
        func amt(_ a: Amount) -> String { if case .fixed(let n) = a { return "\(n)" } else { return "X" } }
        switch e {
        case .damage(let a, _): return "deal \(amt(a)) damage"
        case .draw(let a, _): return "draw \(amt(a))"
        case .gainLife(let a, _): return "gain \(amt(a)) life"
        case .loseLife(let a, _): return "lose \(amt(a)) life"
        case .destroy: return "destroy"
        case .exile: return "exile"
        case .bounce: return "return to hand"
        case .tap: return "tap"
        case .untap: return "untap"
        case .pump(let p, let t, _, _): return "\(p >= 0 ? "+" : "")\(p)/\(t >= 0 ? "+" : "")\(t) until end of turn"
        case .addCounters(let k, let a, _): return "put \(amt(a)) \(k.rawValue) counter(s)"
        case .createTokens(let s, let a, _): return "create \(amt(a)) \(s.name.isEmpty ? "token" : s.name)"
        case .surveil(let n): return "surveil \(n)"
        case .scry(let n): return "scry \(n)"
        case .mill(let n, _): return "mill \(n)"
        case .discard(let n, _): return "discard \(n)"
        case .searchBasicLand: return "search for a basic land"
        case .sacrifice: return "sacrifice"
        case .grantKeyword(let k, _, _): return "gain \(k)"
        case .returnFromGraveyard: return "return from graveyard"
        case .fight, .fightBetween: return "fight"
        case .bite: return "deal damage equal to power"
        case .explore: return "explore"
        case .addMana: return "add mana"
        case .doubleLife: return "double your life"
        case .noMaxHandSize: return "no maximum hand size"
        case .putLandFromHand: return "put a land onto the battlefield"
        case .modal(let m): return m.map { describe($0) }.joined(separator: " / ")
        case .optional(let inner): return "you may " + describe(inner)
        case .cantBlock: return "can't block"
        case .gainControl: return "gain control"
        case .sacrificeAtEndOfTurn: return "sacrifice at end of turn"
        case .kickedInstead(let inner): return "if kicked, " + describe(inner)
        case .ifDidPrevious(let inner): return "if you do, " + describe(inner)
        case .assimilate, .assimilateFromLibrary, .assimilateExiledOrExile: return "assimilate"
        case .discover(let n): return "discover \(n)"
        case .payLife(let n): return "pay \(n) life"
        case .payMana(let c): return "pay \(c)"
        case .copyToken: return "create a copy"
        case .conditional(_, let inner): return describe(inner)
        }
    }
}
