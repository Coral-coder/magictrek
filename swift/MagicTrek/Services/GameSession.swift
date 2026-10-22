import CardKit
import Combine
import Foundation
import GameEngine
import SwiftUI
import UIKit
import UserNotifications

/// One game being played on this device: drives the engine, runs the computer player, keeps the
/// action log, syncs online matches and tells the views what changed.
@MainActor
final class GameSession: ObservableObject, Identifiable {
    enum Mode: String, Codable { case solo, hotseat, online }

    let id = UUID()
    let mode: Mode
    let seed: UInt64
    let playerNames: [String]
    let decks: [[String]]
    @Published private(set) var game: Game
    @Published private(set) var actions: [GameAction] = []
    @Published var lastError: String? = nil
    /// Events since the last time a view consumed them, for animation.
    @Published private(set) var recentEvents: [GameEvent] = []
    @Published var thinking = false
    /// Online: the seat of the player on this device. Solo: 0. Hotseat: the active player.
    @Published var localSeat: PlayerID = 0
    var matchID: String? = nil
    private var lastLogCount = 0
    private var botTask: Task<Void, Never>? = nil

    init(mode: Mode, playerNames: [String], seed: UInt64, decks: [Deck], matchID: String? = nil, localSeat: PlayerID = 0) {
        self.mode = mode; self.seed = seed; self.playerNames = playerNames; self.matchID = matchID; self.localSeat = localSeat
        self.decks = decks.map(\.cardList)
        let bots = mode == .solo ? [false, true] : [false, false]
        game = Game(playerNames: playerNames, bots: bots, seed: seed)
    }

    /// Resumes a saved local game by replaying its actions.
    convenience init(resuming saved: SavedGame) {
        self.init(mode: saved.mode, playerNames: saved.playerNames, seed: saved.seed, decks: saved.decks.map { Deck(name: "", cards: Dictionary($0.map { ($0, 1) }, uniquingKeysWith: +)) })
        for a in saved.actions { try? game.apply(a); actions.append(a) }
        lastLogCount = game.state.log.count
        if mode == .hotseat { localSeat = game.state.playerToAct ?? 0 }
        runBotIfNeeded()
    }

    /// Online: rebuilds from the match's action list.
    convenience init(online match: MatchSummary, actions: [GameAction], localSeat: PlayerID) {
        self.init(mode: .online, playerNames: [match.hostName, match.guestName ?? "Opponent"], seed: match.seed,
                  decks: [Deck(name: "", cards: [:]), Deck(name: "", cards: [:])], matchID: match.id, localSeat: localSeat)
        for a in actions { try? game.apply(a); self.actions.append(a) }
        lastLogCount = game.state.log.count
    }

    var state: GameState { game.state }
    var db: CardDatabase { game.db }
    var isLocalTurn: Bool { state.playerToAct == localSeat }
    var opponentSeat: PlayerID { state.opponent(of: localSeat) }

    func start() {
        perform(.start(decks: decks))
    }

    /// Applies an action for the local player, then lets the bot respond.
    func perform(_ action: GameAction) {
        do {
            if case .start = action { try game.apply(action) } else { try game.apply(action, as: localSeat) }
            actions.append(action)
            lastError = nil
            afterChange()
            if mode == .online, let matchID { Task { await MatchService.shared.send(action, matchID: matchID, seq: actions.count - 1, game: game) } }
        } catch {
            lastError = "\(error)"
            Feedback.shared.play(.deny)
        }
    }

    /// Online: an action from the other player arrived.
    func applyRemote(_ action: GameAction) {
        do { try game.apply(action); actions.append(action); afterChange() } catch { Log.info("Remote action rejected: \(error)") }
    }

    func replaceActions(_ all: [GameAction]) {
        guard all.count > actions.count else { return }
        for a in all.dropFirst(actions.count) { applyRemote(a) }
    }

    private func afterChange() {
        let newEvents = Array(state.log.dropFirst(lastLogCount))
        lastLogCount = state.log.count
        recentEvents = newEvents
        for e in newEvents { sound(for: e) }
        if mode == .hotseat, let p = state.playerToAct { localSeat = p }
        if mode != .online { save() }
        if state.isOver, mode != .online { AppStore.shared.clearSavedGame() }
        runBotIfNeeded()
    }

    private func sound(for e: GameEvent) {
        switch e {
        case .drew(let p, _) where p == localSeat: Feedback.shared.play(.draw)
        case .attackersDeclared: Feedback.shared.play(.attack)
        case .damage(let to, _, _) where EffectContext.player(fromObject: to) != nil: Feedback.shared.play(.damage)
        case .gameOver(let w, _): Feedback.shared.play(w == localSeat ? .victory : .defeat)
        case .cast: Feedback.shared.play(.chirp)
        default: break
        }
    }

    private func runBotIfNeeded() {
        guard mode == .solo, !state.isOver, let p = state.playerToAct, state.players[p].isBot else { return }
        botTask?.cancel()
        thinking = true
        botTask = Task { [weak self] in
            // A short pause so the table reads as a turn, not a flash.
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard let self, !Task.isCancelled else { return }
            var steps = 0
            while !self.state.isOver, let p = self.state.playerToAct, self.state.players[p].isBot, steps < 200 {
                guard let action = Bot.nextAction(game: self.game, player: p) else { break }
                do { try self.game.apply(action, as: p); self.actions.append(action) } catch { Log.info("Bot action failed: \(error)"); break }
                steps += 1
                let newEvents = Array(self.state.log.dropFirst(self.lastLogCount))
                self.lastLogCount = self.state.log.count
                self.recentEvents = newEvents
                for e in newEvents { self.sound(for: e) }
                let pause: UInt64
                switch action {
                case .cast, .declareAttackers, .playLand: pause = 650_000_000
                case .respond: pause = 400_000_000
                default: pause = 250_000_000
                }
                try? await Task.sleep(nanoseconds: pause)
                if Task.isCancelled { return }
            }
            self.thinking = false
            self.save()
            if self.state.isOver { AppStore.shared.clearSavedGame() }
            if UIApplication.shared.applicationState != .active { self.notifyYourTurn() }
        }
    }

    private func save() {
        guard mode != .online, !state.isOver else { return }
        SavedGame(mode: mode, seed: seed, playerNames: playerNames, decks: decks, actions: actions, date: Date()).save()
        AppStore.shared.savedSoloGame = SavedGame.load()
    }

    /// Local notification when the computer finishes while the app is in the background.
    func notifyYourTurn() {
        let content = UNMutableNotificationContent()
        content.title = "Your move, \(playerNames[localSeat])"
        content.body = state.isOver ? "The game is over." : "Turn \(state.turn): the computer has finished its turn."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "turn-\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func concede() { perform(.concede) }
}
