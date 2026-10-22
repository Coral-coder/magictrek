import CardKit
import GameEngine
import SwiftUI

/// The table. Opponent on top, you below, hand at the bottom, LCARS controls in the middle.
struct GameView: View {
    @ObservedObject var session: GameSession
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    enum Interaction: Equatable {
        case idle
        case targeting(requirements: [TargetRequirement], chosen: [ObjectID], purpose: Purpose)
        case attacking(Set<ObjectID>)
        case blocking(assignments: [ObjectID: ObjectID], blocker: ObjectID?)
        case stationing(spacecraft: ObjectID)
        case equipping(equipment: ObjectID)
        case beamingUp(card: ObjectID)
        case decisionTargets(chosen: [ObjectID])
        case pickingCards(chosen: [ObjectID])
    }
    struct TargetRequirement: Equatable { var filter: Filter; var count: Int; var optional: Bool }
    enum Purpose: Equatable { case cast(card: ObjectID, kicked: Bool, mode: Int?), activate(object: ObjectID, index: Int) }

    @State private var interaction: Interaction = .idle
    @State private var selectedHandCard: ObjectID? = nil
    @State private var inspecting: Inspect? = nil
    @State private var showLog = false
    @State private var showGraveyard: GraveyardSelection? = nil
    @State private var showConcede = false
    @State private var permanentMenu: ObjectID? = nil
    @State private var castMenu: ObjectID? = nil
    @State private var lifeFlash: PlayerID? = nil
    @State private var damageTick = 0

    var me: PlayerID { session.localSeat }
    var them: PlayerID { session.state.opponent(of: me) }
    var state: GameState { session.state }
    var game: Game { session.game }
    var myTurn: Bool { state.activePlayer == me && state.pending == nil }

    var body: some View {
        ZStack {
            LCARS.black.ignoresSafeArea()
            VStack(spacing: 4) {
                playerStrip(them, top: true)
                battlefield(them, top: true)
                controlBar
                battlefield(me, top: false)
                playerStrip(me, top: false)
                hand
            }
            .padding(.horizontal, 6)
            if state.isOver { gameOverOverlay }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { leave() } label: { Label("Menu", systemImage: "chevron.left") }.foregroundStyle(LCARS.orange)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    Button { showLog = true } label: { Image(systemName: "list.bullet.rectangle") }.foregroundStyle(LCARS.lavender)
                    Button { showConcede = true } label: { Image(systemName: "flag") }.foregroundStyle(LCARS.red)
                }
            }
        }
        .toolbarBackground(LCARS.black, for: .navigationBar)
        .sheet(isPresented: $showLog) { LogSheet(session: session) }
        .sheet(item: $inspecting) { i in InspectSheet(session: session, objectID: i.id) }
        .sheet(item: $showGraveyard) { g in GraveyardSheet(session: session, player: g.id, onBeamUp: beamUp) }
        .confirmationDialog("Concede the game?", isPresented: $showConcede, titleVisibility: .visible) {
            Button("Concede", role: .destructive) { session.concede() }
        }
        .confirmationDialog(permanentMenuTitle, isPresented: Binding(get: { permanentMenu != nil }, set: { if !$0 { permanentMenu = nil } }), titleVisibility: .visible) {
            if let id = permanentMenu { permanentActions(id) }
        }
        .confirmationDialog(castMenuTitle, isPresented: Binding(get: { castMenu != nil }, set: { if !$0 { castMenu = nil } }), titleVisibility: .visible) {
            if let id = castMenu { castActions(id) }
        }
        .onChange(of: session.recentEvents) { _, events in react(to: events) }
        .onChange(of: state.pending) { _, pending in
            if case .declareBlockers = pending?.decision, pending?.player == me { interaction = .blocking(assignments: [:], blocker: nil) }
            else if pending == nil, case .blocking = interaction { interaction = .idle }
        }
        .onAppear {
            if case .declareBlockers = state.pending?.decision, state.pending?.player == me { interaction = .blocking(assignments: [:], blocker: nil) }
        }
        .sensoryFeedback(.impact(weight: .heavy), trigger: damageTick)
    }

    // MARK: Strips

    func playerStrip(_ p: PlayerID, top: Bool) -> some View {
        let ps = state.players[p]
        let active = state.activePlayer == p
        return HStack(spacing: 8) {
            Capsule().fill(active ? LCARS.orange : LCARS.gray).frame(width: 34, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(ps.name.uppercased()).font(LCARS.heading).foregroundStyle(active ? LCARS.orange : LCARS.peach).lineLimit(1)
                Text(top ? "opponent" : (session.mode == .hotseat ? "your seat" : "you")).font(LCARS.small).foregroundStyle(LCARS.gray)
            }
            Spacer()
            LCARSReadout(label: "life", value: "\(ps.life)", color: lifeFlash == p ? LCARS.alert : (ps.life <= 5 ? LCARS.red : LCARS.peach))
            LCARSReadout(label: "hand", value: "\(ps.hand.count)", color: LCARS.blue)
            LCARSReadout(label: "library", value: "\(ps.library.count)", color: LCARS.lavender)
            Button { showGraveyard = GraveyardSelection(id: p) } label: {
                LCARSReadout(label: "grave", value: "\(ps.graveyard.count)", color: LCARS.violet)
            }
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: ps.life)
    }

    // MARK: Battlefield

    func battlefield(_ p: PlayerID, top: Bool) -> some View {
        let perms = state.permanents(of: p)
        let lands = perms.filter { game.characteristics($0.id).isLand && $0.attachedTo == nil }
        let others = perms.filter { !game.characteristics($0.id).isLand }
        return VStack(spacing: 3) {
            if top { landRow(lands, p) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: 5) {
                    if others.isEmpty { Text(top ? "no permanents" : "your battlefield").font(LCARS.small).foregroundStyle(LCARS.gray).frame(height: 104) }
                    ForEach(others, id: \.id) { o in
                        PermanentView(session: session, objectID: o.id, width: 72, highlighted: isCandidate(o.id), selected: isSelected(o.id), dimmed: isDimmed(o.id))
                            .onTapGesture { tapPermanent(o.id) }
                            .onLongPressGesture { inspecting = Inspect(id: o.id) }
                            .overlay(alignment: .bottom) { blockArrow(o.id) }
                    }
                }
                .padding(.horizontal, 4).frame(minHeight: 108)
            }
            if !top { landRow(lands, p) }
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(LCARS.panel.opacity(0.7)))
    }

    func landRow(_ lands: [GameObject], _ p: PlayerID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(lands, id: \.id) { o in
                    PermanentView(session: session, objectID: o.id, width: 34, highlighted: isCandidate(o.id), selected: isSelected(o.id))
                        .onTapGesture { tapPermanent(o.id) }
                        .onLongPressGesture { inspecting = Inspect(id: o.id) }
                }
                if lands.isEmpty { Text("no lands").font(LCARS.small).foregroundStyle(LCARS.gray) }
            }
            .padding(.horizontal, 6).frame(height: 52)
        }
    }

    @ViewBuilder func blockArrow(_ id: ObjectID) -> some View {
        if case .blocking(let assignments, _) = interaction, let attacker = assignments[id] {
            Text("→ \(game.name(attacker))").font(LCARS.small).foregroundStyle(.black).padding(.horizontal, 4).background(Capsule().fill(LCARS.skyBlue)).offset(y: 10)
        }
    }

    // MARK: Control bar

    var controlBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Capsule().fill(myTurn ? LCARS.orange : LCARS.skyBlue).frame(width: 14, height: 14)
                Text("Turn \(state.turn) · \(state.phase.label)".uppercased()).font(LCARS.label).foregroundStyle(LCARS.peach).lineLimit(1)
                Spacer()
                if session.thinking { ScanLine(color: LCARS.blue).frame(width: 90) }
                if let err = session.lastError { Text(err).font(LCARS.small).foregroundStyle(LCARS.alert).lineLimit(1) }
            }
            promptBar
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var promptBar: some View {
        switch interaction {
        case .targeting(let reqs, let chosen, _):
            let req = reqs.first
            HStack {
                Text(targetPrompt(req, chosen: chosen)).font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                Spacer()
                playerTargetButtons(req?.filter)
                if req?.optional == true || !chosen.isEmpty { Button("Done") { finishTargeting() }.lcarsButton(LCARS.gold, height: 34) .frame(width: 80) }
                Button("Cancel") { interaction = .idle; selectedHandCard = nil }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 80)
            }
        case .attacking(let set):
            HStack {
                Text("Choose attackers (\(set.count))").font(LCARS.label).foregroundStyle(LCARS.gold)
                Spacer()
                Button("All") { interaction = .attacking(Set(state.permanents(of: me).filter { game.canAttack($0.id) }.map(\.id))) }.lcarsButton(LCARS.peach, height: 34, fill: false).frame(width: 60)
                Button(set.isEmpty ? "No attack" : "Attack!") { session.perform(.declareAttackers(Array(set))); interaction = .idle }.lcarsButton(LCARS.alert, height: 34).frame(width: 110)
                Button("Cancel") { interaction = .idle }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 80)
            }
        case .blocking(let assignments, let blocker):
            HStack {
                Text(blocker == nil ? "Blocks: tap your creature, then the attacker" : "Now tap the attacker \(game.name(blocker!)) blocks").font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                Spacer()
                Button(assignments.isEmpty ? "No blocks" : "Confirm") { session.perform(.respond(.blockers(assignments))); interaction = .idle }.lcarsButton(LCARS.skyBlue, height: 34).frame(width: 100)
                Button("Clear") { interaction = .blocking(assignments: [:], blocker: nil) }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 70)
            }
        case .stationing:
            HStack { Text("Tap an untapped creature to station").font(LCARS.label).foregroundStyle(LCARS.gold); Spacer(); Button("Cancel") { interaction = .idle }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 80) }
        case .equipping:
            HStack { Text("Tap a creature to equip").font(LCARS.label).foregroundStyle(LCARS.gold); Spacer(); Button("Cancel") { interaction = .idle }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 80) }
        case .beamingUp:
            HStack { Text("Beam me up: tap a creature you control to return to hand").font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2); Spacer(); Button("Cancel") { interaction = .idle }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 80) }
        case .decisionTargets(let chosen):
            if case .chooseTargets(let prompt, let f, let count, let optional, let candidates) = state.pending?.decision {
                HStack {
                    Text("\(prompt) (\(chosen.count)/\(count))").font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                    Spacer()
                    if f.isPlayerFilter || f.kind == .creatureOrPlayer {
                        ForEach(candidates.filter { EffectContext.player(fromObject: $0) != nil }, id: \.self) { pid in
                            Button(game.name(pid)) { session.perform(.respond(.targets([pid]))); interaction = .idle }.lcarsButton(LCARS.peach, height: 34).frame(width: 90)
                        }
                    }
                    if optional || !chosen.isEmpty { Button("Done") { session.perform(.respond(.targets(chosen))); interaction = .idle }.lcarsButton(LCARS.gold, height: 34).frame(width: 80) }
                }
            }
        case .pickingCards(let chosen):
            if let pending = state.pending, pending.player == me {
                HStack {
                    Text(pickPrompt(pending.decision, chosen: chosen)).font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                    Spacer()
                    Button("Done") { session.perform(.respond(.cards(chosen))); interaction = .idle }.lcarsButton(LCARS.gold, height: 34).frame(width: 80)
                }
            }
        case .idle:
            idleButtons
        }
    }

    @ViewBuilder var idleButtons: some View {
        if state.isOver {
            EmptyView()
        } else if let pending = state.pending, pending.player == me {
            decisionButtons(pending)
        } else if state.pending != nil || state.activePlayer != me {
            HStack {
                Text(session.mode == .online ? "Waiting for \(state.players[state.playerToAct ?? them].name)…" : "\(state.players[them].name) is thinking…").font(LCARS.label).foregroundStyle(LCARS.skyBlue)
                Spacer()
                if session.mode == .online { Button("Refresh") { refreshOnline() }.lcarsButton(LCARS.skyBlue, height: 34, fill: false).frame(width: 90) }
            }
        } else {
            HStack(spacing: 6) {
                switch state.phase {
                case .main1:
                    Button("Attack") { interaction = .attacking([]) }.lcarsButton(LCARS.alert, height: 36).disabled(!state.permanents(of: me).contains { game.canAttack($0.id) })
                    Button("Skip to Main 2") { session.perform(.declareAttackers([])) }.lcarsButton(LCARS.peach, height: 36, fill: false)
                    Button("End Turn") { session.perform(.endTurn) }.lcarsButton(LCARS.orange, height: 36)
                case .declareAttackers, .beginCombat:
                    Button("Attack") { interaction = .attacking([]) }.lcarsButton(LCARS.alert, height: 36)
                    Button("No attack") { session.perform(.declareAttackers([])) }.lcarsButton(LCARS.peach, height: 36, fill: false)
                case .main2:
                    Button("End Turn") { session.perform(.endTurn) }.lcarsButton(LCARS.orange, height: 36)
                default:
                    Button("Continue") { session.perform(.passPhase) }.lcarsButton(LCARS.orange, height: 36)
                }
            }
        }
    }

    @ViewBuilder func decisionButtons(_ pending: PendingDecision) -> some View {
        switch pending.decision {
        case .mulligan:
            HStack {
                Text("Keep this hand?").font(LCARS.label).foregroundStyle(LCARS.gold)
                Spacer()
                Button("Keep") { session.perform(.respond(.keep)) }.lcarsButton(LCARS.green, height: 34).frame(width: 90)
                Button("Mulligan") { session.perform(.respond(.mulligan)) }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 100)
            }
        case .declareBlockers:
            Button("Declare blockers") { interaction = .blocking(assignments: [:], blocker: nil) }.lcarsButton(LCARS.skyBlue, height: 36)
        case .chooseTargets(let prompt, _, _, _, _):
            HStack { Text(prompt).font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2); Spacer(); Button("Choose") { interaction = .decisionTargets(chosen: []) }.lcarsButton(LCARS.gold, height: 34).frame(width: 90) }
        case .chooseMode(let prompt, let modes):
            VStack(alignment: .leading, spacing: 4) {
                Text(prompt).font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                HStack { ForEach(Array(modes.enumerated()), id: \.offset) { i, m in Button(m) { session.perform(.respond(.mode(i))) }.lcarsButton(LCARS.lavender, height: 34) } }
            }
        case .chooseOptional(let prompt):
            HStack {
                Text(prompt).font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                Spacer()
                Button("Yes") { session.perform(.respond(.yes)) }.lcarsButton(LCARS.green, height: 34).frame(width: 70)
                Button("No") { session.perform(.respond(.no)) }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 70)
            }
        case .discardToHandSize(let n):
            HStack { Text("Discard \(n) card\(n == 1 ? "" : "s"): tap cards in hand").font(LCARS.label).foregroundStyle(LCARS.gold); Spacer(); Button("Choose") { interaction = .pickingCards(chosen: []) }.lcarsButton(LCARS.gold, height: 34).frame(width: 90) }
        case .chooseSacrifice(let prompt, _):
            HStack { Text(prompt).font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2); Spacer(); Button("Choose") { interaction = .decisionTargets(chosen: []) }.lcarsButton(LCARS.gold, height: 34).frame(width: 90) }
        case .surveil(let cards), .scry(let cards):
            VStack(alignment: .leading, spacing: 4) {
                if case .surveil = pending.decision { Text("Surveil: tap cards to put in your graveyard").font(LCARS.label).foregroundStyle(LCARS.gold) }
                else { Text("Scry: tap cards to put on the bottom").font(LCARS.label).foregroundStyle(LCARS.gold) }
                HStack {
                    ForEach(cards, id: \.self) { id in
                        let chosen: [ObjectID] = { if case .pickingCards(let c) = interaction { return c } else { return [] } }()
                        CardFace(card: game.card(id), width: 54).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(chosen.contains(id) ? LCARS.gold : .clear, lineWidth: 3))
                            .onTapGesture { togglePick(id) }
                    }
                    Spacer()
                    Button("Done") { let c: [ObjectID] = { if case .pickingCards(let c) = interaction { return c } else { return [] } }(); session.perform(.respond(.cards(c))); interaction = .idle }.lcarsButton(LCARS.gold, height: 34).frame(width: 80)
                }
            }
        case .explore(let card, _):
            HStack {
                CardFace(card: game.card(card), width: 44)
                Text("Explore: keep \(game.name(card)) on top?").font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                Spacer()
                Button("Keep") { session.perform(.respond(.exploreGraveyard(false))) }.lcarsButton(LCARS.green, height: 34).frame(width: 70)
                Button("Graveyard") { session.perform(.respond(.exploreGraveyard(true))) }.lcarsButton(LCARS.red, height: 34, fill: false).frame(width: 100)
            }
        case .discoverChoice(let card):
            HStack {
                CardFace(card: game.card(card), width: 44)
                Text("Discover: play \(game.name(card)) for free?").font(LCARS.label).foregroundStyle(LCARS.gold).lineLimit(2)
                Spacer()
                Button("Play") { session.perform(.respond(.discoverPlay(true))) }.lcarsButton(LCARS.green, height: 34).frame(width: 70)
                Button("To hand") { session.perform(.respond(.discoverPlay(false))) }.lcarsButton(LCARS.peach, height: 34, fill: false).frame(width: 90)
            }
        }
    }

    // MARK: Hand

    var hand: some View {
        let hidden = session.mode == .hotseat && state.playerToAct != me
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(state.players[me].hand, id: \.self) { id in
                    if hidden {
                        RoundedRectangle(cornerRadius: 4).fill(LCARS.panel).frame(width: 60, height: 84).overlay(Text("MT").font(LCARS.label).foregroundStyle(LCARS.gray))
                    } else {
                        HandCardView(session: session, objectID: id, width: 88, playable: playable(id), selected: selectedHandCard == id || isPicked(id))
                            .onTapGesture { tapHandCard(id) }
                            .onLongPressGesture { inspecting = Inspect(id: id) }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 6)
        }
        .frame(height: 150)
    }

    func playable(_ id: ObjectID) -> Bool {
        guard interaction == .idle else { return false }
        return game.canPlayLand(id, by: me) || game.canCast(id, by: me) || canCycle(id)
    }

    func canCycle(_ id: ObjectID) -> Bool {
        guard myTurn, let card = game.card(id), let (cost, _) = game.db.parsed(card).cycling else { return false }
        return game.canPay(cost, player: me)
    }

    // MARK: Taps

    func tapHandCard(_ id: ObjectID) {
        Feedback.shared.play(.tap)
        if case .pickingCards = interaction { togglePick(id); return }
        guard interaction == .idle, myTurn else { return }
        if game.canPlayLand(id, by: me) { session.perform(.playLand(id)); return }
        guard let card = game.card(id) else { return }
        let parsed = game.db.parsed(card)
        let kickable = parsed.kicker.map { k -> Bool in var c = card.cost; c.generic += k.generic; for (col, n) in k.colored { c.colored[col, default: 0] += n }; return game.canPay(c, player: me) } ?? false
        let modal = parsed.spellEffects.contains { if case .modal = $0 { return true } else { return false } }
        if kickable || modal || canCycle(id) || !game.canCast(id, by: me) {
            castMenu = id
        } else {
            beginCast(id, kicked: false, mode: nil)
        }
    }

    var castMenuTitle: String { castMenu.map { game.name($0) } ?? "" }

    @ViewBuilder func castActions(_ id: ObjectID) -> some View {
        if let card = game.card(id) {
            let parsed = game.db.parsed(card)
            if game.canCast(id, by: me) {
                if let modal = parsed.spellEffects.first(where: { if case .modal = $0 { return true } else { return false } }), case .modal(let modes) = modal {
                    ForEach(Array(modes.enumerated()), id: \.offset) { i, m in Button("Cast: \(game.describe(m))") { beginCast(id, kicked: false, mode: i) } }
                } else {
                    Button("Cast \(card.manaCost)") { beginCast(id, kicked: false, mode: nil) }
                }
                if let k = parsed.kicker { Button("Cast with kicker (+\(k))") { beginCast(id, kicked: true, mode: nil) } }
            }
            if canCycle(id), let (cost, type) = parsed.cycling { Button("\(type == nil ? "Cycling" : "Landcycling") \(cost)") { session.perform(.cycle(id)) } }
            Button("Inspect") { inspecting = Inspect(id: id) }
        }
    }

    func beginCast(_ id: ObjectID, kicked: Bool, mode: Int?) {
        guard let card = game.card(id) else { return }
        let reqs = game.targetRequirements(for: card, mode: mode).map { TargetRequirement(filter: $0.0, count: $0.1, optional: $0.2) }
            .filter { !game.legalTargets($0.filter, controller: me, source: id).isEmpty }
        if reqs.isEmpty {
            session.perform(.cast(id, targets: [], kicked: kicked, mode: mode, beamUpBounce: nil))
        } else {
            selectedHandCard = id
            interaction = .targeting(requirements: reqs, chosen: [], purpose: .cast(card: id, kicked: kicked, mode: mode))
        }
    }

    func tapPermanent(_ id: ObjectID) {
        Feedback.shared.play(.tap)
        guard let obj = state.objects[id] else { return }
        switch interaction {
        case .targeting(let reqs, var chosen, let purpose):
            guard let req = reqs.first, game.legalTargets(req.filter, controller: me, source: nil).contains(id), !chosen.contains(id) else { return }
            chosen.append(id)
            if chosen.count >= req.count {
                let rest = Array(reqs.dropFirst())
                if rest.isEmpty { interaction = .targeting(requirements: reqs, chosen: chosen, purpose: purpose); finishTargeting() }
                else { interaction = .targeting(requirements: rest, chosen: chosen, purpose: purpose) }
            } else { interaction = .targeting(requirements: reqs, chosen: chosen, purpose: purpose) }
        case .attacking(var set):
            guard obj.controller == me, game.canAttack(id) else { return }
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            interaction = .attacking(set)
        case .blocking(var assignments, let blocker):
            if obj.controller == me {
                if assignments[id] != nil { assignments[id] = nil; interaction = .blocking(assignments: assignments, blocker: nil) }
                else if game.characteristics(id).isCreature, !obj.tapped { interaction = .blocking(assignments: assignments, blocker: id) }
            } else if let b = blocker, state.combat.attackers.contains(id), game.canBlock(b, id) {
                assignments[b] = id
                interaction = .blocking(assignments: assignments, blocker: nil)
            }
        case .stationing(let ship):
            guard obj.controller == me else { return }
            session.perform(.station(spacecraft: ship, creature: id)); interaction = .idle
        case .equipping(let equipment):
            guard obj.controller == me else { return }
            session.perform(.equip(equipment, to: id)); interaction = .idle
        case .beamingUp(let card):
            guard obj.controller == me, game.characteristics(id).isCreature else { return }
            session.perform(.cast(card, targets: [], kicked: false, mode: nil, beamUpBounce: id)); interaction = .idle
        case .decisionTargets(var chosen):
            if case .chooseTargets(_, _, let count, _, let candidates) = state.pending?.decision, candidates.contains(id) {
                if chosen.contains(id) { chosen.removeAll { $0 == id } } else { chosen.append(id) }
                if chosen.count >= count { session.perform(.respond(.targets(chosen))); interaction = .idle } else { interaction = .decisionTargets(chosen: chosen) }
            } else if case .chooseSacrifice(_, let candidates) = state.pending?.decision, candidates.contains(id) {
                session.perform(.respond(.sacrifice(id))); interaction = .idle
            }
        case .pickingCards: break
        case .idle:
            if obj.controller == me, myTurn { permanentMenu = id } else { inspecting = Inspect(id: id) }
        }
    }

    var permanentMenuTitle: String { permanentMenu.map { game.name($0) } ?? "" }

    @ViewBuilder func permanentActions(_ id: ObjectID) -> some View {
        if let obj = state.objects[id], let parsed = game.parsed(obj) {
            let c = game.characteristics(id)
            ForEach(Array(parsed.abilities.enumerated()), id: \.offset) { i, a in
                if case .activated(let cost, let fx, let sorcery) = a, !isManaOnly(fx) {
                    let usable = (!sorcery || state.phase.isMain) && !(cost.tap && obj.tapped) && game.canPay(cost.mana, player: me) && !(cost.oncePerTurn && obj.activatedThisTurn.contains(i))
                    Button("\(costText(cost)): \(game.describe(fx))") { beginActivate(id, index: i, cost: cost, effects: fx) }.disabled(!usable)
                }
            }
            if c.isSpacecraft, parsed.has(.station), state.phase.isMain {
                Button("Station (tap a creature)") { interaction = .stationing(spacecraft: id) }
            }
            if let cost = parsed.equipCost, state.phase.isMain {
                Button("Equip \(cost)") { interaction = .equipping(equipment: id) }.disabled(!game.canPay(cost, player: me))
            }
            if state.phase == .main1 || state.phase == .declareAttackers, game.canAttack(id) {
                Button("Attack with this") { interaction = .attacking([id]) }
            }
            Button("Inspect") { inspecting = Inspect(id: id) }
        }
    }

    func isManaOnly(_ fx: [Effect]) -> Bool {
        if fx.count == 1, case .addMana = fx[0] { return true }
        return false
    }

    func costText(_ cost: ActivationCost) -> String {
        var parts: [String] = []
        if !cost.mana.isFree { parts.append(cost.mana.description) }
        if cost.tap { parts.append("Tap") }
        if cost.sacrificeSelf { parts.append("Sacrifice") }
        if cost.sacrifice != nil { parts.append("Sacrifice a permanent") }
        if cost.payLife > 0 { parts.append("Pay \(cost.payLife) life") }
        if cost.discard > 0 { parts.append("Discard") }
        return parts.isEmpty ? "Free" : parts.joined(separator: ", ")
    }

    func beginActivate(_ id: ObjectID, index: Int, cost: ActivationCost, effects: [Effect]) {
        var sacrifice: ObjectID? = nil
        if let f = cost.sacrifice {
            // Simplest useful choice: the least valuable matching permanent.
            let candidates = state.permanents(of: me).filter { game.matches(f, $0.id, controller: me, source: id) }.map(\.id)
            sacrifice = candidates.min { Bot.value($0, game: game) < Bot.value($1, game: game) }
            if sacrifice == nil { session.lastError = "Nothing to sacrifice"; return }
        }
        var discard: ObjectID? = nil
        if cost.discard > 0 { discard = state.players[me].hand.first }
        let reqs = game.targetRequirements(in: effects).map { TargetRequirement(filter: $0.0, count: $0.1, optional: $0.2) }
            .filter { !game.legalTargets($0.filter, controller: me, source: id).isEmpty }
        if reqs.isEmpty {
            session.perform(.activate(id, ability: index, targets: [], sacrifice: sacrifice, discard: discard))
        } else {
            interaction = .targeting(requirements: reqs, chosen: [], purpose: .activate(object: id, index: index))
        }
    }

    func finishTargeting() {
        guard case .targeting(_, let chosen, let purpose) = interaction else { return }
        switch purpose {
        case .cast(let card, let kicked, let mode): session.perform(.cast(card, targets: chosen, kicked: kicked, mode: mode, beamUpBounce: nil))
        case .activate(let object, let index):
            var sacrifice: ObjectID? = nil
            if let obj = state.objects[object], let parsed = game.parsed(obj), case .activated(let cost, _, _) = parsed.abilities[index], let f = cost.sacrifice {
                sacrifice = state.permanents(of: me).filter { game.matches(f, $0.id, controller: me, source: object) }.map(\.id).min { Bot.value($0, game: game) < Bot.value($1, game: game) }
            }
            session.perform(.activate(object, ability: index, targets: chosen, sacrifice: sacrifice, discard: nil))
        }
        interaction = .idle
        selectedHandCard = nil
    }

    @ViewBuilder func playerTargetButtons(_ filter: Filter?) -> some View {
        if let f = filter, f.isPlayerFilter || f.kind == .creatureOrPlayer {
            if f.kind != .opponent { Button("You") { chooseTargetPlayer(me) }.lcarsButton(LCARS.peach, height: 34, fill: false).frame(width: 64) }
            Button(state.players[them].name) { chooseTargetPlayer(them) }.lcarsButton(LCARS.alert, height: 34).frame(width: 100)
        }
    }

    func chooseTargetPlayer(_ p: PlayerID) {
        guard case .targeting(let reqs, var chosen, let purpose) = interaction else { return }
        chosen.append(EffectContext.playerObject(p))
        let rest = Array(reqs.dropFirst())
        if rest.isEmpty { interaction = .targeting(requirements: reqs, chosen: chosen, purpose: purpose); finishTargeting() }
        else { interaction = .targeting(requirements: rest, chosen: chosen, purpose: purpose) }
    }

    func targetPrompt(_ req: TargetRequirement?, chosen: [ObjectID]) -> String {
        guard let req else { return "Choose targets" }
        let what: String
        switch req.filter.kind {
        case .creature: what = "creature"
        case .creatureOrPlayer: what = "creature or player"
        case .player, .opponent: what = "player"
        case .artifact: what = "artifact"
        case .enchantment: what = "enchantment"
        case .land: what = "land"
        case .spacecraft: what = "Spacecraft"
        case .creatureOrSpacecraft: what = "creature or Spacecraft"
        default: what = "permanent"
        }
        let who = req.filter.controller == .opponent ? " an opponent controls" : (req.filter.controller == .you ? " you control" : "")
        return "Tap target \(what)\(who)\(req.count > 1 ? " (\(chosen.count)/\(req.count))" : "")"
    }

    func pickPrompt(_ d: Decision, chosen: [ObjectID]) -> String {
        if case .discardToHandSize(let n) = d { return "Discard: \(chosen.count)/\(n) chosen" }
        return "Choose cards (\(chosen.count))"
    }

    func togglePick(_ id: ObjectID) {
        var chosen: [ObjectID] = []
        if case .pickingCards(let c) = interaction { chosen = c }
        if chosen.contains(id) { chosen.removeAll { $0 == id } } else { chosen.append(id) }
        interaction = .pickingCards(chosen: chosen)
    }

    func beamUp(_ cardID: ObjectID) {
        showGraveyard = nil
        interaction = .beamingUp(card: cardID)
    }

    // MARK: Highlights

    func isCandidate(_ id: ObjectID) -> Bool {
        switch interaction {
        case .targeting(let reqs, let chosen, _):
            guard let r = reqs.first else { return false }
            return !chosen.contains(id) && game.legalTargets(r.filter, controller: me, source: nil).contains(id)
        case .attacking: return state.objects[id]?.controller == me && game.canAttack(id)
        case .blocking(_, let blocker):
            if let b = blocker { return state.combat.attackers.contains(id) && game.canBlock(b, id) }
            return state.objects[id]?.controller == me && game.characteristics(id).isCreature && state.objects[id]?.tapped == false
        case .stationing(let ship): return state.objects[id]?.controller == me && id != ship && game.characteristics(id).isCreature && state.objects[id]?.tapped == false
        case .equipping: return state.objects[id]?.controller == me && game.characteristics(id).isCreature
        case .beamingUp: return state.objects[id]?.controller == me && game.characteristics(id).isCreature
        case .decisionTargets:
            if case .chooseTargets(_, _, _, _, let candidates) = state.pending?.decision { return candidates.contains(id) }
            if case .chooseSacrifice(_, let candidates) = state.pending?.decision { return candidates.contains(id) }
            return false
        default: return false
        }
    }

    func isSelected(_ id: ObjectID) -> Bool {
        switch interaction {
        case .targeting(_, let chosen, _): return chosen.contains(id)
        case .attacking(let set): return set.contains(id)
        case .blocking(let assignments, let blocker): return assignments[id] != nil || blocker == id
        case .decisionTargets(let chosen): return chosen.contains(id)
        default: return false
        }
    }

    func isDimmed(_ id: ObjectID) -> Bool {
        if case .idle = interaction { return false }
        return !isCandidate(id) && !isSelected(id)
    }

    func isPicked(_ id: ObjectID) -> Bool { if case .pickingCards(let c) = interaction { return c.contains(id) } else { return false } }

    // MARK: Events

    func react(to events: [GameEvent]) {
        for e in events {
            switch e {
            case .lifeChanged(let p, let delta) where delta < 0:
                lifeFlash = p; damageTick += 1
                Task { try? await Task.sleep(nanoseconds: 400_000_000); if lifeFlash == p { lifeFlash = nil } }
            case .gameOver: interaction = .idle
            default: break
            }
        }
    }

    func refreshOnline() {
        guard let id = session.matchID else { return }
        Task { _ = await MatchService.shared.session(for: id) }
    }

    func leave() {
        if session.mode != .online, !state.isOver { store.show("Game saved · resume from the menu") }
        dismiss()
    }

    var gameOverOverlay: some View {
        let won = state.winner == me
        return VStack(spacing: 14) {
            Text(won ? "Victory" : "Defeat").font(LCARS.font(48)).foregroundStyle(won ? LCARS.gold : LCARS.red)
            if case .gameOver(_, let reason) = state.log.last(where: { if case .gameOver = $0 { return true } else { return false } }) ?? .note("") {
                Text(reason).font(LCARS.body).foregroundStyle(LCARS.peach).multilineTextAlignment(.center)
            }
            Text(won ? "Live long and prosper." : "Today was a good day to die.").font(LCARS.label).foregroundStyle(LCARS.lavender)
            Button("Return to bridge") { dismiss() }.lcarsButton(LCARS.orange).frame(width: 220)
        }
        .padding(30)
        .background(RoundedRectangle(cornerRadius: 24).fill(LCARS.panel.opacity(0.95)).overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(won ? LCARS.gold : LCARS.red, lineWidth: 3)))
        .padding(30)
    }
}

struct Inspect: Identifiable { let id: ObjectID }
struct GraveyardSelection: Identifiable { let id: PlayerID }

/// The event log as sentences.
struct LogSheet: View {
    @ObservedObject var session: GameSession
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(session.state.log.enumerated()), id: \.offset) { i, e in
                        if let text = EventText.describe(e, game: session.game) {
                            Text(text).font(LCARS.font(15, weight: .medium)).foregroundStyle(color(for: e)).id(i).listRowBackground(LCARS.black)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(LCARS.black)
                .onAppear { proxy.scrollTo(session.state.log.count - 1) }
            }
            .navigationTitle("Captain's log")
            .toolbarBackground(LCARS.black, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
    func color(for e: GameEvent) -> Color {
        switch e {
        case .turnBegan: return LCARS.orange
        case .damage, .died, .destroyed: return LCARS.red
        case .cast, .playedLand, .entered: return LCARS.peach
        case .gameOver: return LCARS.gold
        default: return LCARS.lavender
        }
    }
}

enum EventText {
    static func describe(_ e: GameEvent, game: Game) -> String? {
        let n = game.name
        func p(_ id: PlayerID) -> String { game.state.players[id].name }
        switch e {
        case .gameStarted(let first): return "Game on. \(p(first)) goes first."
        case .turnBegan(let t, let pl): return "— Turn \(t): \(p(pl)) —"
        case .phase: return nil
        case .drew(let pl, let c): return "\(p(pl)) draws \(c) card\(c == 1 ? "" : "s")."
        case .mulliganed(let pl, let to): return "\(p(pl)) mulligans to \(to)."
        case .playedLand(let pl, let o): return "\(p(pl)) plays \(n(o))."
        case .cast(let pl, let o, let k): return "\(p(pl)) casts \(n(o))\(k ? " with kicker" : "")."
        case .entered: return nil
        case .tokenCreated(let pl, let o): return "\(p(pl)) creates a \(n(o)) token."
        case .tapped, .untapped: return nil
        case .damage(let to, let a, let s): return "\(s.map(n) ?? "Something") deals \(a) damage to \(n(to))."
        case .lifeChanged(let pl, let d): return d > 0 ? "\(p(pl)) gains \(d) life." : nil
        case .died(let o): return "\(n(o)) dies."
        case .exiled(let o): return "\(n(o)) is exiled."
        case .bounced(let o): return "\(n(o)) returns to hand."
        case .destroyed(let o): return "\(n(o)) is destroyed."
        case .discarded(let pl, let o): return "\(p(pl)) discards \(n(o))."
        case .milled(let pl, let o): return "\(p(pl)) mills \(n(o))."
        case .counters(let o, let k, let d): return d > 0 ? "\(n(o)) gets \(d) \(k.rawValue) counter\(d == 1 ? "" : "s")." : nil
        case .attackersDeclared(let pl, let a): return "\(p(pl)) attacks with \(a.map(n).joined(separator: ", "))."
        case .blockersDeclared(let pl, let b): return b.isEmpty ? "\(p(pl)) doesn't block." : "\(p(pl)) blocks: " + b.map { "\(n($0.key)) blocks \(n($0.value))" }.joined(separator: ", ") + "."
        case .triggered(_, let t): return "\(t) triggers."
        case .activated(_, let t): return "\(t) activates."
        case .stationed(let s, let by, let c): return "\(n(by)) stations \(n(s)) (+\(c) charge)."
        case .becameCreature(let o): return "\(n(o)) is now a creature!"
        case .equipped(let e, let to): return "\(n(e)) equips \(n(to))."
        case .fought(let a, let b): return "\(n(a)) fights \(n(b))."
        case .searched(let pl, let o): return o.map { "\(p(pl)) finds \(n($0))." } ?? "\(p(pl)) finds nothing."
        case .surveilled(let pl, let g, let t): return "\(p(pl)) surveils: \(g) to graveyard, \(t) on top."
        case .explored(let c, let land): return "\(n(c)) explores and \(land ? "finds a land" : "grows")."
        case .assimilated(let o, let by): return "\(p(by)) assimilates \(n(o)). Resistance is futile."
        case .sagaChapter(let o, let ch): return "\(n(o)): chapter \(ch)."
        case .conceded(let pl): return "\(p(pl)) concedes."
        case .gameOver(let w, let r): return "\(p(w)) wins! \(r)"
        case .note(let s): return s
        }
    }
}

/// A card up close: the scan (high-resolution from Scryfall when online), its rules and what the engine does with them.
struct InspectSheet: View {
    @ObservedObject var session: GameSession
    let objectID: ObjectID
    var body: some View {
        let obj = session.state.objects[objectID]
        let card = obj.flatMap { session.db[$0.cardID] }
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let card { CardDetailBody(card: card) } else if let t = obj?.token { TokenFace(card: nil, token: t, width: 240).frame(height: 335) }
                    if let obj, obj.zone == .battlefield {
                        let c = session.game.characteristics(objectID)
                        LCARSPanel(color: LCARS.gold, title: "On the battlefield") {
                            VStack(alignment: .leading, spacing: 4) {
                                if c.isCreature { Text("\(c.power)/\(c.toughness), \(obj.damage) damage marked").font(LCARS.body).foregroundStyle(LCARS.peach) }
                                if !c.keywords.isEmpty { Text(c.keywords.map(\.description).sorted().joined(separator: ", ")).font(LCARS.label).foregroundStyle(LCARS.lavender) }
                                if !obj.counters.isEmpty { Text(obj.counters.map { "\($0.value) \($0.key.rawValue)" }.joined(separator: ", ") + " counters").font(LCARS.label).foregroundStyle(LCARS.blue) }
                                if obj.tapped { Text("Tapped").font(LCARS.label).foregroundStyle(LCARS.gray) }
                            }
                        }.padding(.horizontal)
                    }
                }
                .padding(.bottom, 30)
            }
            .background(LCARS.black)
            .navigationTitle(card?.name ?? obj?.token?.name ?? "Card")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }
}

struct GraveyardSheet: View {
    @ObservedObject var session: GameSession
    let player: PlayerID
    var onBeamUp: (ObjectID) -> Void
    @State private var inspecting: Inspect? = nil
    var body: some View {
        NavigationStack {
            ScrollView {
                let ids = session.state.players[player].graveyard
                if ids.isEmpty { Text("Empty").font(LCARS.body).foregroundStyle(LCARS.gray).padding(40) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 10) {
                    ForEach(ids, id: \.self) { id in
                        VStack(spacing: 4) {
                            CardFace(card: session.game.card(id), width: 90).onTapGesture { inspecting = Inspect(id: id) }
                            if player == session.localSeat, let card = session.game.card(id), let cost = session.db.parsed(card).beamMeUp,
                               session.state.activePlayer == player, session.state.phase.isMain, session.game.canPay(cost, player: player) {
                                Button("Beam up \(cost)") { onBeamUp(id) }.lcarsButton(LCARS.blue, height: 28)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(LCARS.black)
            .navigationTitle("\(session.state.players[player].name)'s graveyard")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $inspecting) { i in InspectSheet(session: session, objectID: i.id) }
        }
        .preferredColorScheme(.dark)
    }
}
