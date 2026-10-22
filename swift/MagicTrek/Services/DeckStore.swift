import Foundation
import GameEngine

/// Decks live in Documents/decks.json.
enum DeckStore {
    static var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("decks.json") }

    static func load() -> [Deck] {
        guard let data = try? Data(contentsOf: url), let decks = try? JSONDecoder().decode([Deck].self, from: data) else { return [] }
        return decks
    }

    static func save(_ decks: [Deck]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try? encoder.encode(decks).write(to: url, options: .atomic)
    }
}
