import GameEngine
import SwiftUI

/// Pick decks for a game against the computer or on one device.
struct NewGameView: View {
    @EnvironmentObject var store: AppStore
    let hotseat: Bool
    @State private var deck: Deck? = nil
    @State private var opponentDeck: Deck? = nil

    var body: some View {
        LCARSFrame(title: hotseat ? "Pass & Play" : "Versus Computer", subtitle: "choose decks", color: hotseat ? LCARS.butterscotch : LCARS.orange) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let saved = store.savedSoloGame {
                        LCARSPanel(color: LCARS.gold, title: "Saved game") {
                            VStack(alignment: .leading) {
                                Text("A \(saved.mode == .hotseat ? "pass & play" : "solo") game is in progress. Starting a new one replaces it.").font(LCARS.label).foregroundStyle(LCARS.peach)
                                Button("Resume it instead") { store.resumeSoloGame() }.lcarsButton(LCARS.gold, height: 34)
                            }
                        }
                    }
                    LCARSHeader(title: hotseat ? "Player 1 deck" : "Your deck", color: LCARS.peach)
                    deckPicker(selection: $deck)
                    LCARSHeader(title: hotseat ? "Player 2 deck" : "Computer's deck", color: LCARS.lavender)
                    deckPicker(selection: $opponentDeck)
                    Button("Engage") { start() }.lcarsButton(LCARS.orange, height: 50).disabled(deck == nil || opponentDeck == nil).padding(.top, 8)
                    Text("Decks need 60 cards. The computer plays any legal deck.").font(LCARS.small).foregroundStyle(LCARS.gray)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) { BackButton() }
        .onAppear {
            let legal = store.decks.filter { $0.isLegal(db: store.db) }
            if deck == nil { deck = legal.first }
            if opponentDeck == nil { opponentDeck = legal.count > 1 ? legal[1] : legal.first }
        }
    }

    func deckPicker(selection: Binding<Deck?>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.decks.filter { $0.isLegal(db: store.db) }) { d in
                    Button {
                        selection.wrappedValue = d; Feedback.shared.play(.tap)
                    } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 2) { ForEach(d.colors, id: \.self) { c in Circle().fill(LCARS.color(forMana: c.rawValue)).frame(width: 10, height: 10) } }
                            Text(d.name).lineLimit(2).multilineTextAlignment(.center).font(LCARS.label)
                        }
                        .frame(width: 120, height: 54)
                    }
                    .lcarsButton(d.isStarter ? LCARS.lavender : LCARS.peach, height: 60, fill: selection.wrappedValue?.id == d.id)
                    .frame(width: 130)
                }
            }
        }
    }

    func start() {
        guard let deck, let opponentDeck else { return }
        Feedback.shared.play(.confirm)
        store.startSoloGame(deck: deck, opponentDeck: opponentDeck, hotseat: hotseat)
    }
}

/// Online: create a match (share its code), join one, or open one in progress.
struct OnlineLobbyView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var service = MatchService.shared
    @State private var deck: Deck? = nil
    @State private var code = ""
    @State private var message: String? = nil
    @State private var created: MatchSummary? = nil

    var body: some View {
        LCARSFrame(title: "Subspace Link", subtitle: "online via iCloud", color: LCARS.blue, blocks: [LCARS.skyBlue, LCARS.lavender, LCARS.peach, LCARS.orange, LCARS.ice]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let err = service.lastError { Text(err).font(LCARS.label).foregroundStyle(LCARS.alert) }
                    Text("Playing as \(store.playerName). Both players need an iCloud account; moves arrive as push notifications.").font(LCARS.label).foregroundStyle(LCARS.peach)
                    LCARSHeader(title: "Your deck", color: LCARS.peach)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.decks.filter { $0.isLegal(db: store.db) }) { d in
                                Button { deck = d } label: { Text(d.name).lineLimit(2).font(LCARS.label).frame(width: 120, height: 44) }
                                    .lcarsButton(d.isStarter ? LCARS.lavender : LCARS.peach, height: 50, fill: deck?.id == d.id).frame(width: 130)
                            }
                        }
                    }
                    LCARSHeader(title: "Host a match", color: LCARS.orange)
                    Button(service.busy ? "Working…" : "Create match and get a code") { create() }.lcarsButton(LCARS.orange).disabled(deck == nil || service.busy)
                    if let created {
                        LCARSPanel(color: LCARS.gold, title: "Match code") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(created.code).font(LCARS.font(40)).foregroundStyle(LCARS.gold).textSelection(.enabled)
                                Text("Send this to your opponent. The game starts when they join; you'll get a notification on your turn.").font(LCARS.label).foregroundStyle(LCARS.peach)
                                ShareLink(item: "Join my MagicTrek game with code \(created.code)") { Label("Share code", systemImage: "square.and.arrow.up") }.lcarsButton(LCARS.gold, height: 36)
                            }
                        }
                    }
                    LCARSHeader(title: "Join a match", color: LCARS.lavender)
                    HStack {
                        TextField("CODE", text: $code).font(LCARS.font(24)).foregroundStyle(LCARS.peach).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(LCARS.panel))
                        Button("Join") { join() }.lcarsButton(LCARS.lavender).frame(width: 90).disabled(deck == nil || code.count < 6 || service.busy)
                    }
                    if let message { Text(message).font(LCARS.label).foregroundStyle(LCARS.gold) }
                    LCARSHeader(title: "Your matches", color: LCARS.skyBlue)
                    if service.matches.isEmpty { Text("No matches yet.").font(LCARS.label).foregroundStyle(LCARS.gray) }
                    ForEach(service.matches) { m in
                        Button { open(m) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(m.hostName) vs \(m.guestName ?? "waiting…")").lineLimit(1)
                                    Text(statusLine(m)).font(LCARS.small)
                                }
                                Spacer()
                                Image(systemName: m.status == "finished" ? "checkmark.seal" : (m.isMyTurn(user: service.userID ?? "") ? "bolt.fill" : "hourglass"))
                            }
                        }
                        .lcarsButton(m.isMyTurn(user: service.userID ?? "") ? LCARS.gold : LCARS.skyBlue, height: 46, fill: m.isMyTurn(user: service.userID ?? ""))
                    }
                    Button("Refresh") { Task { await service.refreshMatches() } }.lcarsButton(LCARS.skyBlue, height: 36, fill: false)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) { BackButton() }
        .task { await service.refreshMatches(); if deck == nil { deck = store.decks.first { $0.isLegal(db: store.db) } } }
    }

    func statusLine(_ m: MatchSummary) -> String {
        if m.status == "waiting" { return "Waiting for a player · code \(m.code)" }
        if m.status == "finished" { return "Finished" }
        return m.isMyTurn(user: service.userID ?? "") ? "Your move" : "Waiting for their move"
    }

    func create() {
        guard let deck else { return }
        Task {
            do { created = try await service.createMatch(deck: deck, name: store.playerName); Feedback.shared.play(.confirm) }
            catch { message = "\(error)"; Feedback.shared.play(.deny) }
        }
    }

    func join() {
        guard let deck else { return }
        Task {
            do {
                let m = try await service.join(code: code, deck: deck, name: store.playerName)
                Feedback.shared.play(.confirm)
                message = "Joined \(m.hostName)'s match."
                store.openMatch(id: m.id)
            } catch { message = "\(error)"; Feedback.shared.play(.deny) }
        }
    }

    func open(_ m: MatchSummary) {
        if m.status == "waiting" { message = "Still waiting for someone to join with code \(m.code)."; return }
        store.openMatch(id: m.id)
    }
}

struct HowToPlayView: View {
    var body: some View {
        LCARSFrame(title: "How to Play", subtitle: "briefing", color: LCARS.skyBlue, blocks: [LCARS.blue, LCARS.lavender, LCARS.peach, LCARS.orange, LCARS.ice]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section("The mission", "Reduce your opponent from 20 life to 0. Each player brings a 60-card deck of Star Trek cards: crew, starships, planets and events.")
                    section("Lands and mana", "Play one land each turn (tap it in your hand). Lands tap for mana, which pays for spells. The game taps lands for you when you cast.")
                    section("A turn", "Untap, draw, then your main phase: play a land, cast creatures and spells. Then attack with creatures that have been under your control since the start of your turn. After combat, a second main phase, then End Turn.")
                    section("Combat", "Tap Attack, pick attackers, confirm. The defender assigns blockers: tap a blocker, then the attacker it blocks. Unblocked attackers hit the player. Flying creatures can only be blocked by flying or reach.")
                    section("Spacecraft", "Starships enter as artifacts. Station them: tap one of your creatures to add charge counters equal to its power. At the threshold (for example 5+) the ship becomes an artifact creature with the listed abilities.")
                    section("Keywords", "Flying, first strike, double strike, deathtouch, lifelink, trample, haste, vigilance, menace, reach, defender, ward, hexproof and indestructible all work as printed.")
                    section("Decisions", "When a card asks you something (a target, a mode, surveil, discard) the prompt appears in the middle bar. Tap the highlighted cards.")
                    section("Sagas, Borg, Landfall", "Sagas gain a lore counter each turn and tell their story. Borg cards assimilate creature cards from graveyards. Landfall triggers when a land enters under your control.")
                    section("Online", "Host a match and share the code; your friend joins with it. Moves sync through iCloud and you get a push notification on your turn. Solo games save automatically.")
                    section("Card coverage", "Every card is playable for its stats. Cards marked 'Fully playable' in the database have all their text implemented; others show what is missing.")
                }
                .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) { BackButton() }
    }
    func section(_ title: String, _ text: String) -> some View {
        LCARSPanel(color: LCARS.palette[abs(title.hashValue) % LCARS.palette.count], title: title) {
            Text(text).font(.system(size: 15)).foregroundStyle(LCARS.peach)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        LCARSFrame(title: "Settings", subtitle: "ship systems", color: LCARS.peach, blocks: [LCARS.orange, LCARS.lavender, LCARS.blue, LCARS.gold, LCARS.skyBlue]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LCARSHeader(title: "Captain", color: LCARS.orange)
                    TextField("Your name", text: $store.playerName).font(LCARS.heading).foregroundStyle(LCARS.peach).padding(8).background(RoundedRectangle(cornerRadius: 8).fill(LCARS.panel))
                    LCARSHeader(title: "Console", color: LCARS.lavender)
                    Toggle("Console sounds", isOn: $store.soundOn).font(LCARS.body).foregroundStyle(LCARS.peach).tint(LCARS.orange)
                    Toggle("Haptics", isOn: $store.hapticsOn).font(LCARS.body).foregroundStyle(LCARS.peach).tint(LCARS.orange)
                    Button("Test console") { Feedback.shared.play(.victory) }.lcarsButton(LCARS.lavender, height: 36, fill: false)
                    LCARSHeader(title: "Notifications", color: LCARS.blue)
                    Text("Turn notifications arrive from iCloud for online matches, and locally when the computer finishes a turn while the app is in the background.").font(LCARS.label).foregroundStyle(LCARS.peach)
                    Button("Open notification settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }.lcarsButton(LCARS.blue, height: 36, fill: false)
                    LCARSHeader(title: "Data", color: LCARS.gold)
                    Button("Restore starter decks") { for d in StarterDecks.all(db: store.db) { if !store.decks.contains(where: { $0.name == d.name && $0.isStarter }) { store.save(d) } } }.lcarsButton(LCARS.gold, height: 36, fill: false)
                    if store.savedSoloGame != nil { Button("Discard saved game") { store.clearSavedGame() }.lcarsButton(LCARS.red, height: 36, fill: false) }
                    Text("Card database generated \(store.db.generated). \(store.db.distinctCards.count) cards, \(store.db.fullySupportedCards.count) fully playable.").font(LCARS.small).foregroundStyle(LCARS.gray)
                    Text("MagicTrek is a fan project. Card images from mythicspoiler.com, card data from Scryfall. Magic: The Gathering © Wizards of the Coast. Star Trek © CBS Studios.").font(LCARS.small).foregroundStyle(LCARS.gray)
                }
                .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) { BackButton() }
    }
}
