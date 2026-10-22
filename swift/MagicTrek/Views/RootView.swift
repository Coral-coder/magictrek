import SwiftUI
import GameEngine

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationStack(path: $store.path) {
            MainMenuView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .game:
                        if let session = store.activeSession { GameView(session: session) } else { MainMenuView() }
                    case .gallery: CardGalleryView()
                    case .card(let id): CardDetailView(cardID: id)
                    case .decks: DeckListView()
                    case .deckEditor(let id): DeckEditorView(deckID: id)
                    case .newGame(let hotseat): NewGameView(hotseat: hotseat)
                    case .online: OnlineLobbyView()
                    case .howToPlay: HowToPlayView()
                    case .settings: SettingsView()
                    }
                }
        }
        .overlay(alignment: .top) {
            if let banner = store.banner {
                Text(banner.uppercased()).font(LCARS.label).foregroundStyle(.black).padding(.horizontal, 16).padding(.vertical, 8)
                    .background(LCARS.gold).clipShape(Capsule()).padding(.top, 54).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut, value: store.banner)
        .onAppear { store.requestNotificationsIfNeeded() }
    }
}

struct MainMenuView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        LCARSFrame(title: "MagicTrek", subtitle: "LCARS 47", color: LCARS.orange) {
            ZStack {
                Starfield().opacity(0.6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Multiplayer card battles across the final frontier").font(LCARS.label).foregroundStyle(LCARS.peach).padding(.bottom, 4)
                        if let saved = store.savedSoloGame {
                            Button { store.resumeSoloGame() } label: { Label("Resume game · turn \(resumeTurn(saved))", systemImage: "play.fill") }
                                .lcarsButton(LCARS.gold)
                        }
                        Button { store.path.append(Route.newGame(hotseat: false)) } label: { Label("Play vs Computer", systemImage: "cpu") }.lcarsButton(LCARS.orange)
                        Button { store.path.append(Route.newGame(hotseat: true)) } label: { Label("Pass & Play", systemImage: "person.2") }.lcarsButton(LCARS.butterscotch)
                        Button { store.path.append(Route.online) } label: { Label("Online via iCloud", systemImage: "icloud") }.lcarsButton(LCARS.blue)
                        if !store.matches.isEmpty { OngoingMatchesView() }
                        LCARSHeader(title: "Databanks", color: LCARS.lavender).padding(.top, 8)
                        Button { store.path.append(Route.gallery) } label: { Label("Card Database", systemImage: "rectangle.stack") }.lcarsButton(LCARS.lavender)
                        Button { store.path.append(Route.decks) } label: { Label("Decks", systemImage: "square.stack.3d.up") }.lcarsButton(LCARS.violet)
                        Button { store.path.append(Route.howToPlay) } label: { Label("How to Play", systemImage: "questionmark.circle") }.lcarsButton(LCARS.skyBlue)
                        Button { store.path.append(Route.settings) } label: { Label("Settings", systemImage: "gearshape") }.lcarsButton(LCARS.peach, fill: false)
                        Text("Card images: mythicspoiler.com · card data: Scryfall · Magic: The Gathering is a trademark of Wizards of the Coast; Star Trek of CBS Studios. Fan project, not affiliated.")
                            .font(LCARS.small).foregroundStyle(LCARS.gray).padding(.top, 12)
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationBarHidden(true)
    }

    func resumeTurn(_ saved: SavedGame) -> Int {
        var g = Game(playerNames: saved.playerNames, seed: saved.seed)
        for a in saved.actions { try? g.apply(a) }
        return g.state.turn
    }
}

struct OngoingMatchesView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        LCARSPanel(color: LCARS.blue, title: "Online matches") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.matches.prefix(4)) { m in
                    Button { store.openMatch(id: m.id) } label: {
                        HStack {
                            Text("\(m.hostName) vs \(m.guestName ?? "…")").lineLimit(1)
                            Spacer()
                            Text(status(m)).font(LCARS.small)
                        }
                    }
                    .lcarsButton(m.isMyTurn(user: MatchService.shared.userID ?? "") ? LCARS.gold : LCARS.skyBlue, height: 36, fill: m.isMyTurn(user: MatchService.shared.userID ?? ""))
                }
            }
        }
    }
    func status(_ m: MatchSummary) -> String {
        if m.status == "waiting" { return "code \(m.code)" }
        if m.status == "finished" { return "finished" }
        return m.isMyTurn(user: MatchService.shared.userID ?? "") ? "your move" : "their move"
    }
}
