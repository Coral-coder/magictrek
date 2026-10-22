import CloudKit
import Combine
import Foundation
import GameEngine

/// An online match as stored in CloudKit's public database.
struct MatchSummary: Identifiable, Hashable {
    var id: String            // record name
    var code: String
    var hostName: String
    var guestName: String?
    var hostUser: String
    var guestUser: String?
    var seed: UInt64
    var status: String        // waiting, active, finished
    var hostDeck: [String]
    var guestDeck: [String]?
    var lastSeq: Int
    var turnUser: String?
    var created: Date

    static let recordType = "Match"

    init?(record: CKRecord) {
        guard let code = record["code"] as? String, let hostName = record["hostName"] as? String, let hostUser = record["hostUser"] as? String else { return nil }
        id = record.recordID.recordName
        self.code = code; self.hostName = hostName; self.hostUser = hostUser
        guestName = record["guestName"] as? String
        guestUser = record["guestUser"] as? String
        seed = UInt64(bitPattern: (record["seed"] as? Int64) ?? 1)
        status = (record["status"] as? String) ?? "waiting"
        hostDeck = MatchSummary.decode(record["hostDeck"] as? String) ?? []
        guestDeck = MatchSummary.decode(record["guestDeck"] as? String)
        lastSeq = (record["lastSeq"] as? Int) ?? -1
        turnUser = record["turnUser"] as? String
        created = record.creationDate ?? Date()
    }

    static func decode(_ s: String?) -> [String]? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
    static func encode(_ ids: [String]) -> String { String(data: (try? JSONEncoder().encode(ids)) ?? Data(), encoding: .utf8) ?? "[]" }

    func seat(for user: String) -> PlayerID? { user == hostUser ? 0 : (user == guestUser ? 1 : nil) }
    func isMyTurn(user: String) -> Bool { turnUser == user }
}

/// Online play over iCloud. Matches and their actions are records in the public database; a
/// subscription on the actions of each match pushes the other player's moves to this device.
///
/// Set-up (once, in CloudKit Console): deploy MagicTrek/CloudKit/schema.ckdb to the container and
/// give the _icloud role write access on Match. See README.
@MainActor
final class MatchService: ObservableObject {
    static let shared = MatchService()

    @Published private(set) var matches: [MatchSummary] = []
    @Published private(set) var userID: String? = nil
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var lastError: String? = nil
    @Published private(set) var busy = false

    private let container = CKContainer.default()
    private var db: CKDatabase { container.publicCloudDatabase }
    private var sessions: [String: GameSession] = [:]

    private init() {}

    var available: Bool { accountStatus == .available && userID != nil }

    // MARK: Identity

    func ensureIdentity() async {
        do {
            accountStatus = try await container.accountStatus()
            guard accountStatus == .available else { lastError = "Sign in to iCloud in Settings to play online."; return }
            if userID == nil { userID = try await container.userRecordID().recordName }
            lastError = nil
        } catch {
            lastError = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated: return "Sign in to iCloud in Settings to play online."
            case .networkUnavailable, .networkFailure: return "No network connection."
            case .unknownItem, .invalidArguments: return "The CloudKit schema isn't deployed yet (see README)."
            case .permissionFailure: return "CloudKit permissions: give the _icloud role write access on Match (see README)."
            default: break
            }
        }
        return error.localizedDescription
    }

    // MARK: Matches

    func refreshMatches() async {
        await ensureIdentity()
        guard let me = userID else { return }
        do {
            let predicate = NSPredicate(format: "hostUser == %@ OR guestUser == %@", me, me)
            let query = CKQuery(recordType: MatchSummary.recordType, predicate: predicate)
            let (results, _) = try await db.records(matching: query, resultsLimit: 50)
            var found: [MatchSummary] = []
            for (_, result) in results { if case .success(let r) = result, let m = MatchSummary(record: r) { found.append(m) } }
            matches = found.sorted { $0.created > $1.created }
            lastError = nil
        } catch { lastError = friendly(error) }
    }

    func createMatch(deck: Deck, name: String) async throws -> MatchSummary {
        await ensureIdentity()
        guard let me = userID else { throw GameError(lastError ?? "iCloud unavailable") }
        busy = true; defer { busy = false }
        let record = CKRecord(recordType: MatchSummary.recordType)
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        record["code"] = String((0..<6).map { _ in letters.randomElement()! })
        record["hostName"] = name
        record["hostUser"] = me
        record["seed"] = Int64(bitPattern: UInt64.random(in: 1...UInt64.max))
        record["status"] = "waiting"
        record["hostDeck"] = MatchSummary.encode(deck.cardList)
        record["lastSeq"] = -1
        let saved = try await db.save(record)
        guard let m = MatchSummary(record: saved) else { throw GameError("Bad record") }
        try? await subscribe(to: m)
        await refreshMatches()
        return m
    }

    func join(code: String, deck: Deck, name: String) async throws -> MatchSummary {
        await ensureIdentity()
        guard let me = userID else { throw GameError(lastError ?? "iCloud unavailable") }
        busy = true; defer { busy = false }
        let query = CKQuery(recordType: MatchSummary.recordType, predicate: NSPredicate(format: "code == %@", code.uppercased()))
        let (results, _) = try await db.records(matching: query, resultsLimit: 1)
        guard let first = results.first, case .success(let record) = first.1, var m = MatchSummary(record: record) else { throw GameError("No match with code \(code.uppercased())") }
        guard m.status == "waiting", m.guestUser == nil else { throw GameError("That match already has two players") }
        guard m.hostUser != me else { throw GameError("That's your own match; wait for a friend to join") }
        record["guestName"] = name
        record["guestUser"] = me
        record["guestDeck"] = MatchSummary.encode(deck.cardList)
        record["status"] = "active"
        record["turnUser"] = m.hostUser
        let saved = try await db.save(record)
        guard let joined = MatchSummary(record: saved) else { throw GameError("Bad record") }
        m = joined
        // The first action is the deterministic start; both sides replay it.
        let start = GameAction.start(decks: [m.hostDeck, deck.cardList])
        var game = Game(playerNames: [m.hostName, name], seed: m.seed)
        try game.apply(start)
        try await saveAction(start, matchID: m.id, seq: 0, player: 1)
        try await updateMatch(m.id, game: game)
        try? await subscribe(to: m)
        await refreshMatches()
        return m
    }

    // MARK: Actions

    private func saveAction(_ action: GameAction, matchID: String, seq: Int, player: PlayerID) async throws {
        let record = CKRecord(recordType: "MatchAction", recordID: CKRecord.ID(recordName: "\(matchID)-\(seq)"))
        record["match"] = CKRecord.Reference(recordID: CKRecord.ID(recordName: matchID), action: .deleteSelf)
        record["seq"] = seq
        record["player"] = player
        record["payload"] = String(data: try JSONEncoder().encode(action), encoding: .utf8)
        _ = try await db.save(record)
    }

    /// Records whose move it is on the match so the other device's subscription can say so.
    private func updateMatch(_ matchID: String, game: Game) async throws {
        let record = try await db.record(for: CKRecord.ID(recordName: matchID))
        guard let m = MatchSummary(record: record) else { return }
        let next = game.state.playerToAct
        record["turnUser"] = next == 0 ? m.hostUser : (next == 1 ? m.guestUser : nil)
        record["lastSeq"] = game.state.actionCount
        if game.state.isOver {
            record["status"] = "finished"
            record["winnerUser"] = game.state.winner == 0 ? m.hostUser : m.guestUser
        }
        _ = try await db.save(record)
    }

    func send(_ action: GameAction, matchID: String, seq: Int, game: Game) async {
        guard let me = userID, let m = matches.first(where: { $0.id == matchID }), let seat = m.seat(for: me) else { return }
        do {
            try await saveAction(action, matchID: matchID, seq: seq, player: seat)
            try await updateMatch(matchID, game: game)
            lastError = nil
        } catch { lastError = friendly(error) }
    }

    func fetchActions(matchID: String, after seq: Int) async throws -> [GameAction] {
        let ref = CKRecord.Reference(recordID: CKRecord.ID(recordName: matchID), action: .none)
        let query = CKQuery(recordType: "MatchAction", predicate: NSPredicate(format: "match == %@ AND seq > %d", ref, seq))
        query.sortDescriptors = [NSSortDescriptor(key: "seq", ascending: true)]
        let (results, _) = try await db.records(matching: query, resultsLimit: 400)
        var out: [(Int, GameAction)] = []
        for (_, r) in results {
            guard case .success(let rec) = r, let seq = rec["seq"] as? Int, let payload = rec["payload"] as? String, let data = payload.data(using: .utf8),
                  let action = try? JSONDecoder().decode(GameAction.self, from: data) else { continue }
            out.append((seq, action))
        }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// The session for a match, built from its actions (cached per match).
    func session(for matchID: String) async -> GameSession? {
        await refreshMatches()
        guard let me = userID, let m = matches.first(where: { $0.id == matchID }), let seat = m.seat(for: me) else { return nil }
        if let existing = sessions[matchID] {
            if let actions = try? await fetchActions(matchID: matchID, after: existing.actions.count - 1) { existing.replaceActions(existing.actions + actions) }
            return existing
        }
        guard m.guestUser != nil else { return nil }
        do {
            let actions = try await fetchActions(matchID: matchID, after: -1)
            let session = GameSession(online: m, actions: actions, localSeat: seat)
            sessions[matchID] = session
            return session
        } catch { lastError = friendly(error); return nil }
    }

    func subscribe(to m: MatchSummary) async throws {
        guard let me = userID, let seat = m.seat(for: me) else { return }
        let ref = CKRecord.Reference(recordID: CKRecord.ID(recordName: m.id), action: .none)
        let predicate = NSPredicate(format: "match == %@ AND player != %d", ref, seat)
        let sub = CKQuerySubscription(recordType: "MatchAction", predicate: predicate, subscriptionID: "match-\(m.id)", options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.title = "MagicTrek"
        info.alertBody = "Your move against \(seat == 0 ? (m.guestName ?? "your opponent") : m.hostName)."
        info.soundName = "default"
        info.shouldSendContentAvailable = true
        info.desiredKeys = ["seq"]
        sub.notificationInfo = info
        _ = try await db.save(sub)
    }

    /// A CloudKit push: pull the new actions into the open session (or refresh the list).
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async {
        guard let note = CKNotification(fromRemoteNotificationDictionary: userInfo) as? CKQueryNotification,
              let subID = note.subscriptionID, subID.hasPrefix("match-") else { return }
        let matchID = String(subID.dropFirst(6))
        if let session = sessions[matchID], let actions = try? await fetchActions(matchID: matchID, after: session.actions.count - 1) {
            session.replaceActions(session.actions + actions)
        }
        await refreshMatches()
    }

    func matchForOpenSession(_ session: GameSession) -> MatchSummary? { session.matchID.flatMap { id in matches.first { $0.id == id } } }
}
