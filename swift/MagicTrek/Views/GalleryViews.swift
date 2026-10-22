import CardKit
import SwiftUI

/// Browse every card: search, filter by color, type and rarity.
struct CardGalleryView: View {
    @EnvironmentObject var store: AppStore
    @State private var search = ""
    @State private var color: ManaColor? = nil
    @State private var type: String? = nil
    @State private var rarity: Rarity? = nil
    @State private var onlySupported = false
    @State private var showVariants = false

    var cards: [Card] {
        let base = showVariants ? store.db.cards.sorted { $0.sortKey < $1.sortKey } : store.db.distinctCards
        return base.filter { c in
            if let color, !c.colors.contains(color) { return false }
            if let type, !c.types.contains(type) { return false }
            if let rarity, c.rarity != rarity { return false }
            if onlySupported, !store.db.parsed(c).fullySupported { return false }
            if !search.isEmpty, !c.name.localizedCaseInsensitiveContains(search), !c.oracleText.localizedCaseInsensitiveContains(search), !c.typeLine.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    var body: some View {
        LCARSFrame(title: "Card Database", subtitle: "\(store.db.distinctCards.count) cards", color: LCARS.lavender, blocks: [LCARS.blue, LCARS.peach, LCARS.orange, LCARS.violet, LCARS.skyBlue]) {
            VStack(spacing: 6) {
                TextField("Search names and rules", text: $search).textFieldStyle(.plain).font(LCARS.body).foregroundStyle(LCARS.peach)
                    .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(LCARS.panel)).autocorrectionDisabled()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ManaColor.allCases, id: \.self) { c in
                            chip(c.name, selected: color == c, color: LCARS.color(forMana: c.rawValue)) { color = color == c ? nil : c }
                        }
                        ForEach(["Creature", "Artifact", "Instant", "Sorcery", "Enchantment", "Land"], id: \.self) { t in
                            chip(t, selected: type == t, color: LCARS.lavender) { type = type == t ? nil : t }
                        }
                        ForEach(Rarity.allCases, id: \.self) { r in
                            chip(r.rawValue, selected: rarity == r, color: LCARS.gold) { rarity = rarity == r ? nil : r }
                        }
                        chip("Fully playable", selected: onlySupported, color: LCARS.green) { onlySupported.toggle() }
                        chip("Alt art", selected: showVariants, color: LCARS.peach) { showVariants.toggle() }
                    }
                }
                Text("\(cards.count) cards").font(LCARS.small).foregroundStyle(LCARS.gray).frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 10) {
                        ForEach(cards) { card in
                            Button { store.path.append(Route.card(card.id)) } label: {
                                VStack(spacing: 2) {
                                    CardFace(card: card, width: 84)
                                    Text(card.name).font(LCARS.small).foregroundStyle(LCARS.peach).lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 30)
                }
            }
        }
        .navigationBarHidden(true)
        .overlay(alignment: .topLeading) { BackButton() }
    }

    func chip(_ text: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text.uppercased()).font(LCARS.small).foregroundStyle(selected ? .black : color).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(selected ? color : color.opacity(0.15))).overlay(Capsule().strokeBorder(color, lineWidth: 1))
        }
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button { dismiss() } label: { Image(systemName: "chevron.left").font(.system(size: 18, weight: .bold)).foregroundStyle(.black) }
            .padding(.leading, 18).padding(.top, 10)
    }
}

struct CardDetailView: View {
    @EnvironmentObject var store: AppStore
    let cardID: String
    var body: some View {
        ScrollView {
            if let card = store.db[cardID] { CardDetailBody(card: card) } else { Text("Unknown card").foregroundStyle(LCARS.red) }
        }
        .background(LCARS.black)
        .navigationTitle(store.db[cardID]?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(LCARS.black, for: .navigationBar)
    }
}

/// The card face (hi-res from Scryfall when reachable, else the bundled scan), rules text, and what the engine implements.
struct CardDetailBody: View {
    @EnvironmentObject var store: AppStore
    let card: Card
    @State private var hiRes: UIImage? = nil

    var body: some View {
        let parsed = store.db.parsed(card)
        VStack(spacing: 12) {
            ZStack {
                CardFace(card: card, width: 300)
                if let hiRes { Image(uiImage: hiRes).resizable().aspectRatio(contentMode: .fit).frame(width: 300).clipShape(RoundedRectangle(cornerRadius: 14)) }
            }
            .shadow(color: LCARS.blue.opacity(0.4), radius: 16)
            .padding(.top, 8)
            .task { await loadHiRes() }
            HStack(spacing: 8) {
                ManaCostView(cost: card.manaCost, size: 18)
                Text(card.typeLine).font(LCARS.label).foregroundStyle(LCARS.lavender)
                Spacer()
                if let p = card.power, let t = card.toughness { Text("\(p)/\(t)").font(LCARS.heading).foregroundStyle(LCARS.peach) }
            }
            .padding(.horizontal)
            LCARSPanel(color: LCARS.orange, title: "Rules") {
                Text(card.oracleText.isEmpty ? "(No rules text.)" : card.oracleText).font(.system(size: 15)).foregroundStyle(LCARS.peach)
            }.padding(.horizontal)
            if !card.flavorText.isEmpty {
                Text(card.flavorText).font(.system(size: 14).italic()).foregroundStyle(LCARS.gray).padding(.horizontal)
            }
            LCARSPanel(color: parsed.fullySupported ? LCARS.green : (parsed.abilities.contains { !$0.isUnsupported } ? LCARS.gold : LCARS.red), title: "Engine") {
                VStack(alignment: .leading, spacing: 4) {
                    if parsed.fullySupported { Text("Fully playable: every ability on this card works in the game.").font(LCARS.label).foregroundStyle(LCARS.green) }
                    else if parsed.abilities.contains(where: { !$0.isUnsupported }) { Text("Partly playable: stats and some abilities work; the text below is not yet implemented.").font(LCARS.label).foregroundStyle(LCARS.gold) }
                    else { Text("Stats only: this card plays as a vanilla card for now.").font(LCARS.label).foregroundStyle(LCARS.red) }
                    ForEach(parsed.unsupported, id: \.self) { u in Text("• " + u).font(.system(size: 13)).foregroundStyle(LCARS.gray) }
                }
            }.padding(.horizontal)
            HStack {
                Text("\(card.set.uppercased()) #\(card.collectorNumber) · \(card.rarity.rawValue) · art \(card.artist)").font(LCARS.small).foregroundStyle(LCARS.gray)
                Spacer()
            }.padding(.horizontal)
        }
        .padding(.bottom, 30)
    }

    func loadHiRes() async {
        guard !card.imageLarge.isEmpty, let url = URL(string: card.imageLarge) else { return }
        if let cached = HiResCache.shared.object(forKey: url.absoluteString as NSString) { hiRes = cached; return }
        guard let (data, _) = try? await URLSession.shared.data(from: url), let img = UIImage(data: data) else { return }
        HiResCache.shared.setObject(img, forKey: url.absoluteString as NSString)
        hiRes = img
    }
}

final class HiResCache { static let shared = NSCache<NSString, UIImage>() }
