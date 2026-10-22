// Developer tool: how much of the set the parser covers, and what it gives up on.
//   swift run CardTool            summary + the most common unsupported clauses
//   swift run CardTool <name>     the parsed abilities of one card
import CardKit
import Foundation

let db = try CardDatabase.bundled()
let args = CommandLine.arguments.dropFirst()
if let query = args.first {
    for card in db.distinctCards where card.name.lowercased().contains(query.lowercased()) {
        print("## \(card.name) \(card.manaCost) | \(card.typeLine) | \(card.power ?? "-")/\(card.toughness ?? "-")")
        print(card.oracleText)
        let p = db.parsed(card)
        for a in p.abilities { print("  +", a) }
        for u in p.unsupported { print("  ✗", u) }
    }
    exit(0)
}
var full = 0, partial = 0, none = 0
var clauses: [String: Int] = [:]
var byType: [String: (Int, Int)] = [:]
for card in db.distinctCards {
    let p = db.parsed(card)
    let kind = card.types.last ?? "?"
    var entry = byType[kind] ?? (0, 0)
    entry.1 += 1
    if p.fullySupported { full += 1; entry.0 += 1 } else if p.abilities.contains(where: { !$0.isUnsupported }) { partial += 1 } else { none += 1 }
    byType[kind] = entry
    for u in p.unsupported { clauses[u, default: 0] += 1 }
}
print("\(db.distinctCards.count) cards: \(full) fully supported, \(partial) partially, \(none) stats only")
for (k, v) in byType.sorted(by: { $0.key < $1.key }) { print("  \(k): \(v.0)/\(v.1)") }
print("\nUnsupported clauses:")
for (c, n) in clauses.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(Int(ProcessInfo.processInfo.environment["LIMIT"] ?? "80") ?? 80) {
    print("  \(n)× \(c)")
}
