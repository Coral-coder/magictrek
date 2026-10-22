import Foundation

/// Every card image in the app with its rules data, loaded from cards.json (built by tools/build-card-db.py).
public final class CardDatabase: @unchecked Sendable {
    public let cards: [Card]
    public let generated: String
    private let byID: [String: Card]
    private let byName: [String: Card]
    private var parsedCache: [String: ParsedCard] = [:]
    private let lock = NSLock()

    private struct File: Decodable { var generated: String?; var cards: [Card] }

    public init(cards: [Card], generated: String = "") {
        self.cards = cards
        self.generated = generated
        byID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The main printing wins for look-ups by name; variants only add art.
        var names: [String: Card] = [:]
        for c in cards.sorted(by: { !$0.variant && $1.variant }) where names[c.name] == nil { names[c.name] = c }
        byName = names
    }

    public convenience init(data: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: data)
        self.init(cards: file.cards, generated: file.generated ?? "")
    }

    /// The database shipped inside this package.
    public static func bundled() throws -> CardDatabase {
        guard let url = Bundle.module.url(forResource: "cards", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try CardDatabase(data: Data(contentsOf: url))
    }

    public static let shared: CardDatabase = {
        (try? CardDatabase.bundled()) ?? CardDatabase(cards: [])
    }()

    public subscript(id: String) -> Card? { byID[id] }
    public func card(id: String) -> Card? { byID[id] }
    public func card(named name: String) -> Card? { byName[name] }

    /// One card per name: the main printing of each.
    public var distinctCards: [Card] { byName.values.sorted { $0.sortKey < $1.sortKey } }

    /// The abilities parsed from a card's rules text, cached.
    public func parsed(_ card: Card) -> ParsedCard {
        lock.lock(); defer { lock.unlock() }
        if let p = parsedCache[card.id] { return p }
        let p = AbilityParser.parse(card)
        parsedCache[card.id] = p
        return p
    }

    /// Cards whose rules text the engine implements completely; the starter decks are drawn from these.
    public var fullySupportedCards: [Card] { distinctCards.filter { parsed($0).fullySupported } }
}

extension Card {
    /// Sort by set, then collector number, so the gallery reads like the printed set.
    public var sortKey: (Int, Int, String) {
        let setOrder = set == "trk" ? 0 : (set == "trc" ? 1 : 2)
        let num = Int(collectorNumber.filter(\.isNumber)) ?? 9999
        return (setOrder, num, id)
    }
}

extension Array where Element == Card {
    public func sorted(by key: KeyPath<Card, (Int, Int, String)>) -> [Card] { sorted { $0[keyPath: key] < $1[keyPath: key] } }
}
