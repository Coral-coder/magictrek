import CardKit
import GameEngine
import SwiftUI
import UIKit

/// Loads the bundled card scans (the cards/ folder) once each.
final class CardImages {
    static let shared = CardImages()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 400 }

    func image(for card: Card) -> UIImage? {
        if let img = cache.object(forKey: card.file as NSString) { return img }
        guard let url = Bundle.main.url(forResource: card.file, withExtension: nil, subdirectory: "cards")
                ?? Bundle.main.url(forResource: (card.file as NSString).deletingPathExtension, withExtension: "jpg", subdirectory: "cards")
                ?? Bundle.main.url(forResource: (card.file as NSString).deletingPathExtension, withExtension: "jpg"),
              let img = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(img, forKey: card.file as NSString)
        return img
    }
}

/// A card face at any size, with a drawn fallback when the scan is missing (tokens).
struct CardFace: View {
    var card: Card?
    var token: TokenSpec? = nil
    var width: CGFloat = 80
    var height: CGFloat { width * 370 / 265 }

    var body: some View {
        Group {
            if let card, let img = CardImages.shared.image(for: card) {
                Image(uiImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                TokenFace(card: card, token: token, width: width)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.045))
    }
}

/// Tokens have no scan: an LCARS card drawn from the spec.
struct TokenFace: View {
    var card: Card?
    var token: TokenSpec?
    var width: CGFloat
    var body: some View {
        let name = token?.name ?? card?.name ?? "Token"
        let color = token?.colors.first.map { LCARS.color(forMana: $0.rawValue) } ?? LCARS.gray
        ZStack {
            RoundedRectangle(cornerRadius: width * 0.045).fill(LCARS.panel)
            RoundedRectangle(cornerRadius: width * 0.045).strokeBorder(color, lineWidth: 2)
            VStack(spacing: 2) {
                Text(name.isEmpty ? "TOKEN" : name.uppercased()).font(LCARS.font(width * 0.11)).foregroundStyle(color).multilineTextAlignment(.center).padding(.horizontal, 4)
                if let t = token, t.isCreature { Text("\(t.power)/\(t.toughness)").font(LCARS.font(width * 0.16)).foregroundStyle(LCARS.peach) }
                if let t = token, !t.keywords.isEmpty { Text(t.keywords.map(\.description).joined(separator: ", ")).font(LCARS.font(width * 0.08, weight: .regular)).foregroundStyle(LCARS.gray) }
                Image(systemName: "sparkles").foregroundStyle(color.opacity(0.6))
            }
        }
    }
}

/// Mana symbols as colored pips.
struct ManaCostView: View {
    var cost: String
    var size: CGFloat = 14
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in
                Text(s).font(.system(size: size * 0.7, weight: .heavy)).foregroundStyle(.black)
                    .frame(width: size, height: size).background(Circle().fill(LCARS.color(forMana: s)))
            }
        }
    }
    var symbols: [String] {
        var out: [String] = []; var cur = ""; var inside = false
        for ch in cost {
            if ch == "{" { inside = true; cur = ""; continue }
            if ch == "}" { inside = false; out.append(cur); continue }
            if inside { cur.append(ch) }
        }
        return out
    }
}

/// A permanent on the table: face, tap rotation, counters, current power/toughness and status rings.
struct PermanentView: View {
    @ObservedObject var session: GameSession
    let objectID: ObjectID
    var width: CGFloat = 74
    var highlighted = false
    var selected = false
    var dimmed = false

    var body: some View {
        let obj = session.state.objects[objectID]
        let card = obj.flatMap { session.db[$0.cardID] }
        let c = session.game.characteristics(objectID)
        ZStack(alignment: .bottom) {
            CardFace(card: card, token: obj?.token, width: width)
                .overlay(RoundedRectangle(cornerRadius: width * 0.045).strokeBorder(ringColor, lineWidth: selected ? 3 : (highlighted ? 2 : 0)))
                .shadow(color: highlighted ? LCARS.gold.opacity(0.9) : .clear, radius: 6)
            if c.isCreature {
                Text("\(c.power)/\(c.toughness)")
                    .font(LCARS.font(width * 0.17)).foregroundStyle(.black).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(powerColor(obj: obj, c: c))).offset(y: 4)
            }
            if let obj {
                VStack(alignment: .leading, spacing: 2) {
                    counterBadge("+", obj.plusOneCounters, LCARS.green)
                    counterBadge("⚡︎", obj.chargeCounters, LCARS.blue)
                    counterBadge("☰", obj.counters[.lore] ?? 0, LCARS.lavender)
                    counterBadge("✕", obj.counters[.stun] ?? 0, LCARS.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(3)
                if obj.attacking != nil { statusTag("ATK", LCARS.alert) }
                else if obj.blocking != nil { statusTag("BLK", LCARS.skyBlue) }
                else if obj.attachedTo != nil { statusTag("⇡", LCARS.gold) }
            }
        }
        .rotationEffect(.degrees(obj?.tapped == true ? 90 : 0))
        .frame(width: obj?.tapped == true ? width * 370 / 265 : width, height: obj?.tapped == true ? width * 370 / 265 : width * 370 / 265)
        .opacity(dimmed ? 0.45 : 1)
        .animation(.spring(duration: 0.35), value: obj?.tapped)
    }

    var ringColor: Color { selected ? LCARS.gold : (highlighted ? LCARS.ice : .clear) }

    func powerColor(obj: GameObject?, c: Characteristics) -> Color {
        guard let obj, let card = session.db[obj.cardID] else { return LCARS.peach }
        if (obj.damage) > 0 { return LCARS.red }
        if c.power > card.basePower || c.toughness > card.baseToughness { return LCARS.green }
        if c.power < card.basePower || c.toughness < card.baseToughness { return LCARS.butterscotch }
        return LCARS.peach
    }

    @ViewBuilder func counterBadge(_ symbol: String, _ n: Int, _ color: Color) -> some View {
        if n > 0 {
            Text("\(symbol)\(n)").font(LCARS.font(width * 0.13)).foregroundStyle(.black).padding(.horizontal, 4).padding(.vertical, 1)
                .background(Capsule().fill(color))
        }
    }

    func statusTag(_ s: String, _ color: Color) -> some View {
        Text(s).font(LCARS.font(width * 0.13)).foregroundStyle(.black).padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(3)
    }
}

/// A card in hand: face plus a glow when it can be played.
struct HandCardView: View {
    @ObservedObject var session: GameSession
    let objectID: ObjectID
    var width: CGFloat = 92
    var playable = false
    var selected = false
    var body: some View {
        let obj = session.state.objects[objectID]
        let card = obj.flatMap { session.db[$0.cardID] }
        CardFace(card: card, width: width)
            .overlay(RoundedRectangle(cornerRadius: width * 0.045).strokeBorder(selected ? LCARS.gold : (playable ? LCARS.ice : .clear), lineWidth: selected ? 3 : 2))
            .shadow(color: playable ? LCARS.ice.opacity(0.7) : .clear, radius: 5)
            .offset(y: selected ? -14 : 0)
            .animation(.spring(duration: 0.25), value: selected)
    }
}
