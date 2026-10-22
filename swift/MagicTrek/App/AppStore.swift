import CardKit
import Combine
import GameEngine
import SwiftUI
import UserNotifications

/// App-wide state: settings, decks, the saved solo game, online matches and navigation.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @AppStorage("playerName") var playerName: String = "Captain" { didSet { objectWillChange.send() } }
    @AppStorage("soundOn") var soundOn: Bool = true { didSet { Feedback.shared.soundOn = soundOn; objectWillChange.send() } }
    @AppStorage("hapticsOn") var hapticsOn: Bool = true { didSet { Feedback.shared.hapticsOn = hapticsOn; objectWillChange.send() } }
    @AppStorage("notificationsAsked") var notificationsAsked: Bool = false

    @Published var decks: [Deck] = []
    @Published var savedSoloGame: SavedGame? = nil
    @Published var matches: [MatchSummary] = []
    @Published var path = NavigationPath()
    @Published var activeSession: GameSession? = nil
    @Published var banner: String? = nil

    let db = CardDatabase.shared
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        Feedback.shared.soundOn = soundOn
        Feedback.shared.hapticsOn = hapticsOn
        decks = DeckStore.load()
        if decks.isEmpty { decks = StarterDecks.all(db: db); DeckStore.save(decks) }
        savedSoloGame = SavedGame.load()
        MatchService.shared.$matches.receive(on: DispatchQueue.main).assign(to: &$matches)
        Task { await MatchService.shared.refreshMatches() }
    }

    // MARK: Decks

    var starterDecks: [Deck] { decks.filter(\.isStarter) }
    var customDecks: [Deck] { decks.filter { !$0.isStarter } }

    func save(_ deck: Deck) {
        if let i = decks.firstIndex(where: { $0.id == deck.id }) { decks[i] = deck } else { decks.append(deck) }
        DeckStore.save(decks)
    }

    func delete(_ deck: Deck) {
        decks.removeAll { $0.id == deck.id }
        DeckStore.save(decks)
    }

    func duplicate(_ deck: Deck) -> Deck {
        let copy = Deck(name: deck.name + " copy", cards: deck.cards, colors: deck.colors, isStarter: false)
        save(copy)
        return copy
    }

    // MARK: Games

    func startSoloGame(deck: Deck, opponentDeck: Deck, hotseat: Bool) {
        let seed = UInt64.random(in: 1...UInt64.max)
        let names = hotseat ? ["Player 1", "Player 2"] : [playerName, "Computer"]
        let session = GameSession(mode: hotseat ? .hotseat : .solo, playerNames: names, seed: seed, decks: [deck, opponentDeck])
        activeSession = session
        session.start()
        path.append(Route.game)
    }

    func resumeSoloGame() {
        guard let saved = savedSoloGame else { return }
        let session = GameSession(resuming: saved)
        activeSession = session
        path.append(Route.game)
    }

    func openMatch(id: String) {
        Task {
            if let session = await MatchService.shared.session(for: id) {
                activeSession = session
                if !path.isEmpty { path = NavigationPath() }
                path.append(Route.game)
            }
        }
    }

    func clearSavedGame() { savedSoloGame = nil; SavedGame.clear() }

    func show(_ message: String) {
        banner = message
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); if banner == message { banner = nil } }
    }

    // MARK: Notifications

    func requestNotificationsIfNeeded() {
        guard !notificationsAsked else { return }
        notificationsAsked = true
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }
}

enum Route: Hashable {
    case game, gallery, decks, deckEditor(UUID), newGame(hotseat: Bool), online, howToPlay, settings, card(String)
}

/// A solo or pass-and-play game saved to disk so it can be resumed.
struct SavedGame: Codable {
    var mode: GameSession.Mode
    var seed: UInt64
    var playerNames: [String]
    var decks: [[String]]
    var actions: [GameAction]
    var date: Date

    static var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("solo-game.json") }
    static func load() -> SavedGame? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedGame.self, from: data)
    }
    func save() { try? JSONEncoder().encode(self).write(to: SavedGame.url, options: .atomic) }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}
