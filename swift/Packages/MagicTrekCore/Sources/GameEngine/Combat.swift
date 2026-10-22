import CardKit

extension Game {
    mutating func declareAttackers(_ ids: [ObjectID]) throws {
        let p = state.activePlayer
        guard state.phase == .main1 || state.phase == .declareAttackers || state.phase == .beginCombat else { throw GameError("Not the time to attack") }
        if state.phase == .main1 {
            state.phase = .beginCombat
            for o in state.permanents(of: p) { fireTriggers(.beginCombat, on: o.id) }
        }
        var attackers: [ObjectID] = []
        for id in ids where !attackers.contains(id) { attackers.append(id) }
        for id in attackers { guard canAttack(id), state.objects[id]?.controller == p else { throw GameError("\(name(id)) can't attack") } }
        // Creatures that must attack do.
        for o in state.permanents(of: p) where canAttack(o.id) && characteristics(o.id).has(.mustAttack) && !attackers.contains(o.id) { attackers.append(o.id) }
        state.phase = .declareAttackers
        state.declaredAttackersThisTurn = true
        let defender = state.opponent(of: p)
        state.combat = CombatState(attackers: attackers, blockers: [:], defender: defender)
        if attackers.isEmpty {
            state.phase = .main2
            log(.phase(.main2))
            return
        }
        for id in attackers {
            state.objects[id]?.attacking = defender
            if !characteristics(id).has(.vigilance) { state.objects[id]?.tapped = true; log(.tapped(object: id)) }
        }
        log(.attackersDeclared(player: p, attackers: attackers))
        for id in attackers { fireTriggers(.attacks, on: id) }
        queueContinuation(.blockers)
    }

    mutating func askBlockers() {
        let defender = state.combat.defender
        let attackers = state.combat.attackers.filter { state.objects[$0]?.zone == .battlefield }
        state.combat.attackers = attackers
        state.phase = .declareBlockers
        log(.phase(.declareBlockers))
        let possible = state.permanents(of: defender).contains { b in attackers.contains { canBlock(b.id, $0) } }
        if attackers.isEmpty || !possible {
            queueContinuation(.combatDamage)
            return
        }
        state.pending = PendingDecision(player: defender, decision: .declareBlockers(attackers: attackers),
                                        resume: Resume(source: nil, controller: defender, effects: [], context: EffectContext(), kind: .blockers))
        queueContinuation(.combatDamage)
    }

    mutating func acceptBlockers(_ blocks: [ObjectID: ObjectID]) throws {
        let defender = state.combat.defender
        var counts: [ObjectID: Int] = [:]
        for (blocker, attacker) in blocks.sorted(by: { $0.key < $1.key }) {
            guard state.objects[blocker]?.controller == defender, state.combat.attackers.contains(attacker), canBlock(blocker, attacker) else {
                throw GameError("\(name(blocker)) can't block \(name(attacker))")
            }
            counts[attacker, default: 0] += 1
        }
        for (attacker, n) in counts where characteristics(attacker).has(.menace) && n < 2 { throw GameError("\(name(attacker)) needs two blockers") }
        state.combat.blockers = blocks
        for (blocker, attacker) in blocks { state.objects[blocker]?.blocking = attacker }
        log(.blockersDeclared(player: defender, blocks: blocks))
        for (blocker, attacker) in blocks.sorted(by: { $0.key < $1.key }) { fireTriggers(.blocks, on: blocker); fireTriggers(.blocked, on: attacker) }
    }

    mutating func combatDamage() {
        state.phase = .combatDamage
        log(.phase(.combatDamage))
        let attackers = state.combat.attackers.filter { state.objects[$0]?.zone == .battlefield }
        let anyFirstStrike = attackers.contains { characteristics($0).has(.firstStrike) || characteristics($0).has(.doubleStrike) }
            || state.combat.blockers.keys.contains { characteristics($0).has(.firstStrike) || characteristics($0).has(.doubleStrike) }
        if anyFirstStrike {
            dealCombatDamage(firstStrikeStep: true)
            checkStateBasedActions()
        }
        dealCombatDamage(firstStrikeStep: false)
        checkStateBasedActions()
        state.phase = .endCombat
        for id in state.combat.attackers { state.objects[id]?.attacking = nil }
        for id in state.combat.blockers.keys { state.objects[id]?.blocking = nil }
        state.combat = CombatState()
        state.phase = .main2
        log(.phase(.main2))
    }

    mutating func dealCombatDamage(firstStrikeStep: Bool) {
        let defender = state.combat.defender
        let attackers = state.combat.attackers.filter { state.objects[$0]?.zone == .battlefield }
        func strikesNow(_ id: ObjectID) -> Bool {
            let c = characteristics(id)
            if firstStrikeStep { return c.has(.firstStrike) || c.has(.doubleStrike) }
            return c.has(.doubleStrike) || !c.has(.firstStrike)
        }
        var pending: [(Int, ObjectID, ObjectID?)] = []   // amount, target, source
        for a in attackers where strikesNow(a) {
            let ac = characteristics(a)
            let power = max(ac.power, 0)
            let blockers = state.combat.blockers.filter { $0.value == a }.map(\.key).filter { state.objects[$0]?.zone == .battlefield }.sorted()
            if blockers.isEmpty {
                if state.objects[a]?.blocking == nil, state.combat.blockers.values.contains(a) {
                    // Was blocked but the blocker is gone: no damage unless trample.
                    if ac.has(.trample) { pending.append((power, EffectContext.playerObject(defender), a)) }
                } else { pending.append((power, EffectContext.playerObject(defender), a)) }
                continue
            }
            var remaining = power
            for (i, b) in blockers.sorted(by: { (characteristics($0).toughness, $0) < (characteristics($1).toughness, $1) }).enumerated() {
                let bc = characteristics(b)
                let lethal = ac.has(.deathtouch) ? 1 : max(bc.toughness - (state.objects[b]?.damage ?? 0), 0)
                let isLast = i == blockers.count - 1
                let give = (ac.has(.trample) || !isLast) ? min(remaining, lethal) : remaining
                pending.append((give, b, a))
                remaining -= give
            }
            if remaining > 0, ac.has(.trample) { pending.append((remaining, EffectContext.playerObject(defender), a)) }
        }
        for (b, a) in state.combat.blockers.sorted(by: { $0.key < $1.key }) where strikesNow(b) && state.objects[b]?.zone == .battlefield && state.objects[a]?.zone == .battlefield {
            pending.append((max(characteristics(b).power, 0), a, b))
        }
        var damagedPlayerBy: [ObjectID] = []
        for (amount, target, source) in pending {
            let dealt = dealDamage(amount, to: target, from: source, combat: true)
            if dealt > 0, EffectContext.player(fromObject: target) != nil, let s = source { damagedPlayerBy.append(s) }
        }
        for s in damagedPlayerBy { fireTriggers(.combatDamageToPlayer, on: s) }
    }
}
