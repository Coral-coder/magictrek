import CardKit
import Foundation

/// What a permanent is right now, with counters, pumps, attachments and statics applied.
public struct Characteristics: Hashable, Sendable {
    public var name: String
    public var power: Int
    public var toughness: Int
    public var keywords: Set<Keyword>
    public var isCreature: Bool
    public var isArtifact: Bool
    public var isEnchantment: Bool
    public var isLand: Bool
    public var isSpacecraft: Bool
    public var subtypes: Set<String>
    public var cantAttackOrBlock = false

    public func has(_ kind: KeywordKind) -> Bool { keywords.contains { $0.kind == kind } }
    public var wardCost: Int { keywords.first { $0.kind == .ward }?.value ?? 0 }
}

extension Game {
    public func card(of object: GameObject) -> Card? { object.cardID.isEmpty ? nil : db[object.cardID] }
    public func card(_ id: ObjectID) -> Card? { state.objects[id].flatMap(card(of:)) }
    public func parsed(_ object: GameObject) -> ParsedCard? { card(of: object).map(db.parsed) }
    public func name(_ id: ObjectID) -> String {
        if let p = EffectContext.player(fromObject: id) { return state.players[p].name }
        guard let o = state.objects[id] else { return "?" }
        return o.token?.name ?? card(of: o)?.name ?? "Token"
    }

    /// Full characteristics for anything on the battlefield.
    public func characteristics(_ id: ObjectID) -> Characteristics {
        guard let o = state.objects[id] else {
            return Characteristics(name: "?", power: 0, toughness: 0, keywords: [], isCreature: false, isArtifact: false, isEnchantment: false, isLand: false, isSpacecraft: false, subtypes: [])
        }
        let card = card(of: o)
        let parsedCard = card.map(db.parsed)
        var c: Characteristics
        if let t = o.token, card == nil {
            c = Characteristics(name: t.name, power: t.power, toughness: t.toughness, keywords: Set(t.keywords), isCreature: t.isCreature,
                                isArtifact: t.isArtifact, isEnchantment: false, isLand: false, isSpacecraft: false, subtypes: Set(t.subtypes))
        } else if let card, let parsed = parsedCard {
            c = Characteristics(name: card.name, power: card.basePower, toughness: card.baseToughness, keywords: Set(parsed.keywords),
                                isCreature: card.isCreature, isArtifact: card.isArtifact, isEnchantment: card.isEnchantment, isLand: card.isLand,
                                isSpacecraft: card.isSpacecraft, subtypes: Set(card.subtypes))
            if let t = o.token { c.keywords.formUnion(t.keywords) }
            // Spacecraft become artifact creatures once stationed enough.
            if card.isSpacecraft, let threshold = parsed.stationThreshold ?? card.stationThreshold {
                if o.chargeCounters >= threshold { c.isCreature = true; c.keywords.formUnion(parsed.stationKeywords) }
            }
            for s in parsed.statics {
                switch s {
                case .powerEquals(let a, let andToughness):
                    let n = amount(a, controller: o.controller, source: id, context: EffectContext())
                    c.power = n; if andToughness { c.toughness = n }
                case .selfPumpPerCount(let a, let p, let t):
                    let n = amount(a, controller: o.controller, source: id, context: EffectContext())
                    c.power += p * n; c.toughness += t * n
                case .keywordDuringYourTurn(let k) where state.activePlayer == o.controller: c.keywords.insert(k)
                case .hexproofWhileNotCreature where !c.isCreature: c.keywords.insert(.hexproof)
                default: break
                }
            }
        } else {
            c = Characteristics(name: "?", power: 0, toughness: 0, keywords: [], isCreature: false, isArtifact: false, isEnchantment: false, isLand: false, isSpacecraft: false, subtypes: [])
        }
        if o.assimilated { c.isCreature = true; c.isArtifact = true; c.subtypes = ["Borg"] }
        c.power += o.plusOneCounters - (o.counters[.minusOne] ?? 0)
        c.toughness += o.plusOneCounters - (o.counters[.minusOne] ?? 0)
        for e in o.untilEndOfTurn {
            switch e {
            case .pump(let p, let t): c.power += p; c.toughness += t
            case .keyword(let k): c.keywords.insert(k)
            case .cantBlock: c.keywords.insert(.cantBlock)
            case .noMaxHandSize: break
            }
        }
        // Attachments on this permanent.
        for other in state.allPermanents where other.attachedTo == id {
            guard let p = parsed(other) else { continue }
            for s in p.statics {
                switch s {
                case .attachedGets(let pw, let t): c.power += pw; c.toughness += t
                case .attachedHas(let k): c.keywords.insert(k)
                case .attachedCantAttackOrBlock: c.cantAttackOrBlock = true
                default: break
                }
            }
        }
        // Anthems and granted keywords from everything on the battlefield.
        for other in state.allPermanents {
            guard let p = parsed(other) else { continue }
            for s in p.statics {
                switch s {
                case .anthem(let f, let pw, let t) where matches(f, id, controller: other.controller, source: other.id, base: c):
                    c.power += pw; c.toughness += t
                case .grantKeyword(let f, let k) where matches(f, id, controller: other.controller, source: other.id, base: c):
                    c.keywords.insert(k)
                case .grantKeywordDuringYourTurn(let f, let k) where state.activePlayer == other.controller && matches(f, id, controller: other.controller, source: other.id, base: c):
                    c.keywords.insert(k)
                default: break
                }
            }
        }
        if o.counters[.stun] != nil { /* stun only affects untapping */ }
        return c
    }

    /// Does `id` match the filter, as seen by `controller` (the filter's "you")?
    public func matches(_ f: Filter, _ id: ObjectID, controller: PlayerID, source: ObjectID?, base: Characteristics? = nil) -> Bool {
        if let p = EffectContext.player(fromObject: id) {
            switch f.kind {
            case .player, .creatureOrPlayer: return true
            case .opponent: return p != controller
            default: return false
            }
        }
        guard let o = state.objects[id], o.zone == .battlefield else { return false }
        if f.other, id == source { return false }
        switch f.controller {
        case .any: break
        case .you: if o.controller != controller { return false }
        case .opponent: if o.controller == controller { return false }
        }
        let c = base ?? characteristics(id)
        switch f.kind {
        case .creature, .creatureOrPlayer: if !c.isCreature { return false }
        case .player, .opponent: return false
        case .permanent: break
        case .nonlandPermanent: if c.isLand { return false }
        case .artifact: if !c.isArtifact { return false }
        case .enchantment: if !c.isEnchantment { return false }
        case .artifactOrEnchantment: if !c.isArtifact && !c.isEnchantment { return false }
        case .artifactOrCreature: if !c.isArtifact && !c.isCreature { return false }
        case .land: if !c.isLand { return false }
        case .spacecraft: if !c.isSpacecraft { return false }
        case .creatureOrSpacecraft: if !c.isCreature && !c.isSpacecraft { return false }
        case .artifactCreature: if !c.isArtifact || !c.isCreature { return false }
        case .token: if !o.isToken { return false }
        case .creatureCardInGraveyard, .basicLandCardInLibrary: return false
        }
        if f.attacking, o.attacking == nil, !f.blocking { return false }
        if f.blocking, o.blocking == nil, !f.attacking { return false }
        if f.attacking, f.blocking, o.attacking == nil, o.blocking == nil { return false }
        if f.tapped, !o.tapped { return false }
        if f.untapped, o.tapped { return false }
        if f.nontoken, o.isToken { return false }
        if f.nonartifact, c.isArtifact { return false }
        if f.withCounters, o.counters.values.reduce(0, +) == 0 { return false }
        if let s = f.subtype, !c.subtypes.contains(s) { return false }
        if let m = f.maxPower, c.power > m { return false }
        if let m = f.minPower, c.power < m { return false }
        if let m = f.maxManaValue, (card(of: o)?.manaValue ?? 0) > m { return false }
        return true
    }

    /// Legal targets for a filter chosen by `controller`: hexproof and ward are checked here.
    public func legalTargets(_ f: Filter, controller: PlayerID, source: ObjectID?) -> [ObjectID] {
        var out: [ObjectID] = []
        if f.isPlayerFilter || f.kind == .creatureOrPlayer {
            for p in state.players where !p.lost {
                if f.kind == .opponent, p.id == controller { continue }
                out.append(EffectContext.playerObject(p.id))
            }
            if f.isPlayerFilter { return out }
        }
        if f.kind == .creatureCardInGraveyard {
            for p in state.players {
                if f.controller == .you, p.id != controller { continue }
                if f.controller == .opponent, p.id == controller { continue }
                for id in p.graveyard {
                    guard let o = state.objects[id], let c = card(of: o), c.isCreature else { continue }
                    if let m = f.maxManaValue, c.manaValue > m { continue }
                    out.append(id)
                }
            }
            return out
        }
        for o in state.allPermanents where matches(f, o.id, controller: controller, source: source) {
            if o.controller != controller {
                let c = characteristics(o.id)
                if c.has(.hexproof) { continue }
            }
            out.append(o.id)
        }
        return out
    }

    public func amount(_ a: Amount, controller: PlayerID, source: ObjectID?, context: EffectContext) -> Int {
        switch a {
        case .fixed(let n): return n
        case .creaturesYouControl: return state.permanents(of: controller).filter { characteristics($0.id).isCreature }.count
        case .artifactsYouControl: return state.permanents(of: controller).filter { characteristics($0.id).isArtifact }.count
        case .landsYouControl: return state.permanents(of: controller).filter { characteristics($0.id).isLand }.count
        case .cardsInHand: return state.players[controller].hand.count
        case .differentlyNamedLands: return Set(state.permanents(of: controller).filter { characteristics($0.id).isLand }.map { name($0.id) }).count
        case .thisPower: return source.map { characteristics($0).power } ?? 0
        }
    }

    // MARK: Player-facing queries

    public func isCreature(_ id: ObjectID) -> Bool { characteristics(id).isCreature }

    public func hasSummoningSickness(_ o: GameObject) -> Bool {
        o.enteredTurn == state.turn && !characteristics(o.id).has(.haste)
    }

    public func canAttack(_ id: ObjectID) -> Bool {
        guard let o = state.objects[id], o.zone == .battlefield, !o.tapped else { return false }
        let c = characteristics(id)
        return c.isCreature && !c.has(.defender) && !c.cantAttackOrBlock && !hasSummoningSickness(o)
    }

    public func canBlock(_ blocker: ObjectID, _ attacker: ObjectID) -> Bool {
        guard let b = state.objects[blocker], b.zone == .battlefield, !b.tapped else { return false }
        let bc = characteristics(blocker), ac = characteristics(attacker)
        if !bc.isCreature || bc.has(.cantBlock) || bc.cantAttackOrBlock { return false }
        if ac.has(.unblockable) { return false }
        if ac.has(.flying), !bc.has(.flying), !bc.has(.reach) { return false }
        return true
    }

    /// Untapped sources of mana for a player, as (object, colors it can make; empty = colorless, usesSacrifice).
    func manaSources(_ p: PlayerID) -> [(ObjectID, [ManaColor], Bool)] {
        var out: [(ObjectID, [ManaColor], Bool)] = []
        for o in state.permanents(of: p) where !o.tapped {
            guard let parsed = parsed(o) else { continue }
            let colors = parsed.manaColors
            if !colors.isEmpty || parsed.abilities.contains(where: { if case .mana = $0 { return true } else { return false } }) {
                let c = characteristics(o.id)
                if c.isCreature, hasSummoningSickness(o) { continue }
                out.append((o.id, colors, false)); continue
            }
            for a in parsed.abilities {
                if case .activated(let cost, let fx, _) = a, cost.tap, fx.count == 1, case .addMana(let colors) = fx[0], cost.mana.isFree, cost.payLife == 0 {
                    out.append((o.id, colors, cost.sacrificeSelf))
                }
            }
        }
        return out
    }

    /// Which sources to tap to pay a cost, or nil if it can't be paid. Colored needs first, from
    /// the pickiest sources; Treasures last.
    public func manaPlan(for cost: ManaCost, player: PlayerID) -> [ObjectID]? {
        var sources = manaSources(player).sorted { a, b in
            if a.2 != b.2 { return !a.2 }           // keep sacrifice sources for last
            return a.1.count < b.1.count
        }
        var used: [ObjectID] = []
        var needs: [ManaColor] = []
        for (c, n) in cost.colored.sorted(by: { $0.key < $1.key }) { needs += Array(repeating: c, count: n) }
        for color in needs {
            guard let i = sources.firstIndex(where: { $0.1.contains(color) }) else { return nil }
            used.append(sources[i].0); sources.remove(at: i)
        }
        for pair in cost.hybrid {
            guard let i = sources.firstIndex(where: { !Set($0.1).isDisjoint(with: pair) }) else { return nil }
            used.append(sources[i].0); sources.remove(at: i)
        }
        var generic = cost.generic
        // Colorless-only sources first for generic, then the rest.
        sources.sort { a, b in a.1.isEmpty && !b.1.isEmpty }
        while generic > 0 {
            guard !sources.isEmpty else { return nil }
            used.append(sources.removeFirst().0); generic -= 1
        }
        return used
    }

    public func canPay(_ cost: ManaCost, player: PlayerID) -> Bool { manaPlan(for: cost, player: player) != nil }

    public func availableMana(_ p: PlayerID) -> Int { manaSources(p).count }

    /// Whether a card in hand can be cast now (timing + mana), ignoring targets.
    public func canCast(_ id: ObjectID, by p: PlayerID) -> Bool {
        guard state.pending == nil, state.winner == nil, state.activePlayer == p, let o = state.objects[id], o.zone == .hand,
              let card = card(of: o), !card.isLand else { return false }
        let parsed = db.parsed(card)
        let instantSpeed = card.isInstant || parsed.has(.flash)
        if !state.phase.isMain && !instantSpeed { return false }
        if !state.phase.isMain && ![.beginCombat, .declareAttackers, .declareBlockers, .combatDamage, .endCombat, .end].contains(state.phase) { return false }
        if !canPay(card.cost, player: p) { return false }
        if parsed.isAura, legalTargets(.creature, controller: p, source: id).isEmpty { return false }
        return true
    }

    public func canPlayLand(_ id: ObjectID, by p: PlayerID) -> Bool {
        guard state.pending == nil, state.winner == nil, state.activePlayer == p, state.phase.isMain, let o = state.objects[id], o.zone == .hand,
              let card = card(of: o), card.isLand else { return false }
        return state.players[p].landsPlayedThisTurn < landsAllowed(p)
    }

    public func landsAllowed(_ p: PlayerID) -> Int {
        1 + state.permanents(of: p).filter { parsed($0)?.statics.contains(.extraLandEachTurn) == true }.count
    }

    /// The spell's targets the caster must pick, in order: each `.target` in its effects.
    public func targetRequirements(for card: Card, mode: Int?) -> [(Filter, Int, Bool)] {
        let parsed = db.parsed(card)
        var effects = parsed.spellEffects
        if parsed.isAura { return [(Filter(.creature), 1, false)] }
        if let m = mode, let modal = effects.first(where: { if case .modal = $0 { return true } else { return false } }), case .modal(let modes) = modal, m < modes.count {
            effects = modes[m]
        }
        return targetRequirements(in: effects)
    }

    public func targetRequirements(in effects: [Effect]) -> [(Filter, Int, Bool)] {
        var out: [(Filter, Int, Bool)] = []
        for e in effects {
            switch e {
            case .damage(_, let t), .draw(_, let t), .gainLife(_, let t), .loseLife(_, let t), .destroy(let t), .exile(let t), .bounce(let t),
                 .tap(let t, _), .untap(let t), .pump(_, _, let t, _), .addCounters(_, _, let t), .mill(_, let t), .discard(_, let t),
                 .sacrifice(let t, _), .grantKeyword(_, let t, _), .fight(let t), .bite(let t), .explore(let t), .cantBlock(let t, _),
                 .gainControl(let t), .sacrificeAtEndOfTurn(let t), .assimilateFromLibrary(let t), .assimilateExiledOrExile(let t),
                 .copyToken(let t, _), .createTokens(_, _, let t), .searchBasicLand(_, let t):
                if case .target(let f, let n, let opt) = t { out.append((f, n, opt)) }
            case .fightBetween(let a, let b):
                for t in [a, b] { if case .target(let f, let n, let opt) = t { out.append((f, n, opt)) } }
            case .returnFromGraveyard(let f, _): out.append((f, 1, false))
            case .assimilate(let f): out.append((f, 1, false))
            case .optional(let inner), .ifDidPrevious(let inner), .kickedInstead(let inner), .conditional(_, let inner): out += targetRequirements(in: inner)
            default: break
            }
        }
        return out
    }
}
