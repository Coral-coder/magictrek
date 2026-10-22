import CardKit
import GameEngine
import SwiftUI

struct DeckListView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        LCARSFrame(title: "Decks", subtitle: "\(store.decks.count) decks", color: LCARS.violet, blocks: [LCARS.lavender, LCARS.orange, LCARS.blue, LCARS.peach, LCARS.butterscotch]) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button { newDeck() } label: { Label("New deck", systemImage: "plus") }.lcarsButton(LCARS.orange)
                    LCARSHeader(title: "Your decks", color: LCARS.peach)
                    if store.customDecks.isEmpty { Text("None yet. Copy a starter deck to begin.").font(LCARS.label).foregroundStyle(LCARS.gray) }
                    ForEach(store.customDecks) { deck in deckRow(deck) }
                    LCARSHeader(title: "Starter decks", color: LCARS.lavender).padding(.top, 8)
                    ForEach(store.starterDecks) { deck in deckRow(deck) }
                }
                .padding(.bottom, 30)
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) { BackButton() }
    }

    func deckRow(_ deck: Deck) -> some View {
        Button { store.path.append(Route.deckEditor(deck.id)) } label: {
            HStack(spacing: 8) {
                HStack(spacing: 2) { ForEach(deck.colors, id: \.self) { c in Circle().fill(LCARS.color(forMana: c.rawValue)).frame(width: 12, height: 12) } }
                Text(deck.name).lineLimit(1)
                Spacer()
                Text("\(deck.count)").font(LCARS.small)
                if !deck.isLegal(db: store.db) { Image(systemName: "exclamationmark.triangle").font(.system(size: 12)) }
            }
        }
        .lcarsButton(deck.isStarter ? LCARS.lavender : LCARS.peach, height: 40, fill: !deck.isStarter)
    }

    func newDeck() {
        let deck = Deck(name: "New deck", cards: [:], colors: [])
        store.save(deck)
        store.path.append(Route.deckEditor(deck.id))
    }
}

/// Edit a deck: the list on top, the card pool below with filters. Starter decks are copied on edit.
struct DeckEditorView: View {
    @EnvironmentObject var store: AppStore
    let deckID: UUID
    @State private var search = ""
    @State private var color: ManaColor? = nil
    @State private var showDeleteConfirm = false

    var deck: Deck? { store.decks.first { $0.id == deckID } }

    var body: some View {
        if let deck {
            LCARSFrame(title: deck.name, subtitle: deck.isStarter ? "starter" : "\(deck.count) cards", color: deck.isStarter ? LCARS.lavender : LCARS.peach) {
                VStack(spacing: 6) {
                    if deck.isStarter {
                        Button("Copy to edit") { let copy = store.duplicate(deck); store.path.removeLast(); store.path.append(Route.deckEditor(copy.id)) }.lcarsButton(LCARS.orange, height: 36)
                    } else {
                        HStack {
                            TextField("Deck name", text: Binding(get: { deck.name }, set: { var d = deck; d.name = $0; store.save(d) })).font(LCARS.body).foregroundStyle(LCARS.peach)
                                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(LCARS.panel))
                            Button { showDeleteConfirm = true } label: { Image(systemName: "trash") }.lcarsButton(LCARS.red, height: 36, fill: false).frame(width: 50)
                        }
                    }
                    let problems = deck.problems(db: store.db)
                    HStack {
                        Text(problems.isEmpty ? "Ready to play" : problems[0]).font(LCARS.small).foregroundStyle(problems.isEmpty ? LCARS.green : LCARS.gold).lineLimit(1)
                        Spacer()
                        curve(deck)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(deckEntries(deck), id: \.0.id) { card, n in
                                HStack(spacing: 6) {
                                    Text("\(n)×").font(LCARS.label).foregroundStyle(LCARS.gold).frame(width: 28)
                                    ManaCostView(cost: card.manaCost, size: 12)
                                    Text(card.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(LCARS.peach).lineLimit(1)
                                    Spacer()
                                    if !deck.isStarter {
                                        Button { change(card, -1) } label: { Image(systemName: "minus.circle") }.foregroundStyle(LCARS.red)
                                        Button { change(card, 1) } label: { Image(systemName: "plus.circle") }.foregroundStyle(LCARS.green)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { store.path.append(Route.card(card.id)) }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    .background(RoundedRectangle(cornerRadius: 8).fill(LCARS.panel.opacity(0.6)))
                    if !deck.isStarter {
                        LCARSHeader(title: "Add cards", color: LCARS.blue)
                        HStack {
                            TextField("Search", text: $search).font(LCARS.body).foregroundStyle(LCARS.peach).padding(6).background(RoundedRectangle(cornerRadius: 8).fill(LCARS.panel)).autocorrectionDisabled()
                            ForEach(ManaColor.allCases, id: \.self) { c in
                                Button { color = color == c ? nil : c } label: { Circle().fill(LCARS.color(forMana: c.rawValue)).frame(width: 22, height: 22).overlay(Circle().strokeBorder(.white, lineWidth: color == c ? 2 : 0)) }
                            }
                        }
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], spacing: 8) {
                                ForEach(pool) { card in
                                    VStack(spacing: 2) {
                                        CardFace(card: card, width: 70).onTapGesture { change(card, 1) }.onLongPressGesture { store.path.append(Route.card(card.id)) }
                                        Text("\(deck.cards[card.id] ?? 0)/\(card.isBasicLand ? "∞" : "4")").font(LCARS.small).foregroundStyle(LCARS.gray)
                                    }
                                }
                            }
                            .padding(.bottom, 30)
                        }
                    }
                }
            }
            .navigationBarHidden(true)
            .overlay(alignment: .topLeading) { BackButton() }
            .confirmationDialog("Delete \(deck.name)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { store.delete(deck); store.path.removeLast() }
            }
        } else {
            Text("Deck not found").foregroundStyle(LCARS.red)
        }
    }

    var pool: [Card] {
        store.db.distinctCards.filter { c in
            if let color, !c.colors.contains(color), !(c.isLand && c.producedMana.contains(color)) { return false }
            if !search.isEmpty, !c.name.localizedCaseInsensitiveContains(search), !c.typeLine.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    func deckEntries(_ deck: Deck) -> [(Card, Int)] {
        deck.cards.compactMap { id, n in store.db[id].map { ($0, n) } }
            .sorted { a, b in
                if a.0.isLand != b.0.isLand { return !a.0.isLand }
                if a.0.manaValue != b.0.manaValue { return a.0.manaValue < b.0.manaValue }
                return a.0.name < b.0.name
            }
    }

    func change(_ card: Card, _ delta: Int) {
        guard var d = deck, !d.isStarter else { return }
        let current = d.cards[card.id] ?? 0
        let new = max(0, current + delta)
        if delta > 0, !card.isBasicLand, new > Deck.maxCopies { Feedback.shared.play(.deny); return }
        if new == 0 { d.cards[card.id] = nil } else { d.cards[card.id] = new }
        var colors: Set<ManaColor> = []
        for (id, _) in d.cards { if let c = store.db[id] { colors.formUnion(c.colors) } }
        d.colors = ManaColor.allCases.filter { colors.contains($0) }
        store.save(d)
        Feedback.shared.play(.tap)
    }

    func curve(_ deck: Deck) -> some View {
        var buckets = Array(repeating: 0, count: 7)
        for (id, n) in deck.cards { if let c = store.db[id], !c.isLand { buckets[min(c.manaValue, 6)] += n } }
        let maxN = max(buckets.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: 1) {
                    RoundedRectangle(cornerRadius: 2).fill(LCARS.blue).frame(width: 10, height: max(2, CGFloat(buckets[i]) / CGFloat(maxN) * 28))
                    Text(i == 6 ? "6+" : "\(i)").font(.system(size: 8)).foregroundStyle(LCARS.gray)
                }
            }
        }
    }
}
