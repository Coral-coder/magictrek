import CardKit
import Foundation

/// A deck: card ids with counts. 60 cards, at most 4 of a name (basic lands unlimited).
public struct Deck: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var cards: [String: Int]
    public var colors: [ManaColor]
    public var isStarter: Bool

    public init(id: UUID = UUID(), name: String, cards: [String: Int], colors: [ManaColor] = [], isStarter: Bool = false) {
        self.id = id; self.name = name; self.cards = cards; self.colors = colors; self.isStarter = isStarter
    }

    public var count: Int { cards.values.reduce(0, +) }
    public static let size = 60
    public static let maxCopies = 4

    /// The card ids expanded to a list, main-set printings as stored.
    public var cardList: [String] { cards.sorted { $0.key < $1.key }.flatMap { Array(repeating: $0.key, count: $0.value) } }

    public func problems(db: CardDatabase) -> [String] {
        var out: [String] = []
        if count != Deck.size { out.append("A deck needs \(Deck.size) cards (this one has \(count))") }
        var byName: [String: Int] = [:]
        for (id, n) in cards { if let c = db[id] { byName[c.name, default: 0] += n } else { out.append("Unknown card \(id)") } }
        for (name, n) in byName where n > Deck.maxCopies {
            if let c = db.card(named: name), !c.isBasicLand { out.append("Only \(Deck.maxCopies) copies of \(name) allowed (\(n))") }
        }
        return out
    }
    public func isLegal(db: CardDatabase) -> Bool { problems(db: db).isEmpty }
}

/// Ready-made decks per faction, built from the cards the engine fully implements.
public enum StarterDecks {
    public struct Faction: Hashable, Sendable {
        public let name: String, colors: [ManaColor], blurb: String
    }

    public static let factions: [Faction] = [
        Faction(name: "Starfleet Command", colors: [.white, .blue], blurb: "Officers, Spacecraft and the United Federation of Planets."),
        Faction(name: "Klingon Empire", colors: [.red, .black], blurb: "Warriors who attack early and die with honor."),
        Faction(name: "The Borg Collective", colors: [.blue, .black], blurb: "Artifact creatures that assimilate what they destroy."),
        Faction(name: "Frontier Explorers", colors: [.green, .white], blurb: "Strange new worlds, Landfall and growing crews."),
        Faction(name: "Romulan Star Empire", colors: [.blue, .red], blurb: "Cloaked ships and tricks at instant speed."),
        Faction(name: "Dominion War", colors: [.black, .green], blurb: "Attrition, sacrifice and relentless growth."),
    ]

    /// Builds a deck for a color pair: supported spells of those colors by curve, then lands.
    public static func deck(for faction: Faction, db: CardDatabase = .shared) -> Deck {
        let colors = Set(faction.colors)
        var pool = db.fullySupportedCards.filter { card in
            !card.isLand && !card.colors.isEmpty && Set(card.colors).isSubset(of: colors) && card.set != "sds"
        }
        // Colorless artifacts and creatures help every deck.
        pool += db.fullySupportedCards.filter { $0.colors.isEmpty && !$0.isLand && $0.manaValue <= 4 && $0.set != "sds" }
        // Score: creatures and cheap spells first, then curve.
        func score(_ c: Card) -> Int {
            var s = c.isCreature ? 10 : 5
            if c.isSpacecraft { s += 6 }
            s += max(0, 6 - abs(c.manaValue - 3)) * 2
            if c.rarity == .rare || c.rarity == .mythic { s += 3 }
            if c.colors.count == 2 { s += 2 }
            if c.colors.isEmpty { s -= 4 }
            return s
        }
        let ranked = pool.sorted { score($0) != score($1) ? score($0) > score($1) : $0.name < $1.name }
        var cards: [String: Int] = [:]
        var total = 0
        var curve: [Int: Int] = [:]
        let spells = 36
        for c in ranked where total < spells {
            let copies = c.isLegendary ? 2 : (c.rarity == .mythic ? 2 : 3)
            let bucket = min(c.manaValue, 6)
            let cap = [0: 2, 1: 6, 2: 10, 3: 10, 4: 8, 5: 6, 6: 4][bucket] ?? 4
            if (curve[bucket] ?? 0) >= cap { continue }
            let n = min(copies, spells - total)
            cards[c.id] = n; total += n; curve[bucket, default: 0] += n
        }
        // Lands: dual lands that match, then basics split by color weight.
        var lands = 0
        let duals = db.fullySupportedCards.filter { $0.isLand && !$0.isBasicLand && Set($0.producedMana) == colors && $0.set != "sds" }
        for d in duals.prefix(2) { cards[d.id] = 4; lands += 4 }
        var weight: [ManaColor: Int] = [:]
        for (id, n) in cards { if let c = db[id] { for (col, k) in c.cost.colored { weight[col, default: 0] += k * n } } }
        let need = Deck.size - total - lands
        let totalWeight = max(faction.colors.map { weight[$0] ?? 0 }.reduce(0, +), 1)
        var given = 0
        for (i, color) in faction.colors.enumerated() {
            let n = i == faction.colors.count - 1 ? need - given : Int((Double(weight[color] ?? 0) / Double(totalWeight) * Double(need)).rounded())
            if let basic = db.card(named: color.basicLandType) { cards[basic.id, default: 0] += n; given += n }
        }
        return Deck(name: faction.name, cards: cards, colors: faction.colors, isStarter: true)
    }

    public static func all(db: CardDatabase = .shared) -> [Deck] { factions.map { deck(for: $0, db: db) } }
}
