import Foundation

/// One of the five colors of mana.
public enum ManaColor: String, Codable, CaseIterable, Hashable, Comparable, Sendable {
    case white = "W", blue = "U", black = "B", red = "R", green = "G"

    public static func < (a: ManaColor, b: ManaColor) -> Bool { a.order < b.order }
    private var order: Int { ManaColor.allCases.firstIndex(of: self)! }

    public var name: String {
        switch self {
        case .white: return "White"
        case .blue: return "Blue"
        case .black: return "Black"
        case .red: return "Red"
        case .green: return "Green"
        }
    }

    /// The basic land type that produces this color.
    public var basicLandType: String {
        switch self {
        case .white: return "Plains"
        case .blue: return "Island"
        case .black: return "Swamp"
        case .red: return "Mountain"
        case .green: return "Forest"
        }
    }
}

public enum Rarity: String, Codable, CaseIterable, Hashable, Comparable, Sendable {
    case common, uncommon, rare, mythic
    public static func < (a: Rarity, b: Rarity) -> Bool { a.order < b.order }
    private var order: Int { Rarity.allCases.firstIndex(of: self)! }
}

/// A printed card: what is on the face, as decoded from cards.json. Abilities derived from the
/// rules text are in `Card.parsed` (see AbilityParser).
public struct Card: Codable, Identifiable, Hashable, Sendable {
    /// The image file's stem, e.g. "captainjeanlucpicard" (promo printings end in "p").
    public let id: String
    public let name: String
    public let file: String
    public let set: String
    public let collectorNumber: String
    public let rarity: Rarity
    public let manaCost: String
    public let manaValue: Int
    public let colors: [ManaColor]
    public let colorIdentity: [ManaColor]
    public let typeLine: String
    public let supertypes: [String]
    public let types: [String]
    public let subtypes: [String]
    public let oracleText: String
    public let flavorText: String
    public let keywords: [String]
    public let power: String?
    public let toughness: String?
    public let producedMana: [ManaColor]
    /// Taps for {C} (colorless) as well, or only.
    public let producesColorless: Bool
    public let layout: String
    public let artist: String
    /// An alternate printing (promo, showcase, extra basic land art) of a card that also has a main printing.
    public let variant: Bool
    /// A high-resolution scan, for zooming in; the bundled JPG is the one actually dealt.
    public let imageLarge: String

    private enum CodingKeys: String, CodingKey {
        case id, name, file, set, collectorNumber, rarity, manaCost, manaValue, colors, colorIdentity, typeLine, supertypes, types,
             subtypes, oracleText, flavorText, keywords, power, toughness, producedMana, layout, artist, variant, imageLarge
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(file, forKey: .file); try c.encode(set, forKey: .set)
        try c.encode(collectorNumber, forKey: .collectorNumber); try c.encode(rarity.rawValue, forKey: .rarity); try c.encode(manaCost, forKey: .manaCost)
        try c.encode(manaValue, forKey: .manaValue); try c.encode(colors, forKey: .colors); try c.encode(colorIdentity, forKey: .colorIdentity)
        try c.encode(typeLine, forKey: .typeLine); try c.encode(supertypes, forKey: .supertypes); try c.encode(types, forKey: .types)
        try c.encode(subtypes, forKey: .subtypes); try c.encode(oracleText, forKey: .oracleText); try c.encode(flavorText, forKey: .flavorText)
        try c.encode(keywords, forKey: .keywords); try c.encodeIfPresent(power, forKey: .power); try c.encodeIfPresent(toughness, forKey: .toughness)
        try c.encode(producedMana.map(\.rawValue) + (producesColorless ? ["C"] : []), forKey: .producedMana)
        try c.encode(layout, forKey: .layout); try c.encode(artist, forKey: .artist); try c.encode(variant, forKey: .variant); try c.encode(imageLarge, forKey: .imageLarge)
    }

    public init(id: String, name: String, file: String, set: String = "trk", collectorNumber: String = "", rarity: Rarity = .common,
                manaCost: String, manaValue: Int, colors: [ManaColor], colorIdentity: [ManaColor]? = nil, typeLine: String,
                supertypes: [String] = [], types: [String], subtypes: [String] = [], oracleText: String, flavorText: String = "",
                keywords: [String] = [], power: String? = nil, toughness: String? = nil, producedMana: [ManaColor] = [],
                producesColorless: Bool = false, layout: String = "normal", artist: String = "", variant: Bool = false, imageLarge: String = "") {
        self.id = id; self.name = name; self.file = file; self.set = set; self.collectorNumber = collectorNumber
        self.rarity = rarity; self.manaCost = manaCost; self.manaValue = manaValue; self.colors = colors
        self.colorIdentity = colorIdentity ?? colors; self.typeLine = typeLine; self.supertypes = supertypes
        self.types = types; self.subtypes = subtypes; self.oracleText = oracleText; self.flavorText = flavorText
        self.keywords = keywords; self.power = power; self.toughness = toughness; self.producedMana = producedMana
        self.producesColorless = producesColorless; self.layout = layout; self.artist = artist; self.variant = variant; self.imageLarge = imageLarge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        file = try c.decode(String.self, forKey: .file)
        set = try c.decodeIfPresent(String.self, forKey: .set) ?? ""
        collectorNumber = try c.decodeIfPresent(String.self, forKey: .collectorNumber) ?? ""
        rarity = Rarity(rawValue: try c.decodeIfPresent(String.self, forKey: .rarity) ?? "common") ?? .common
        manaCost = try c.decodeIfPresent(String.self, forKey: .manaCost) ?? ""
        manaValue = try c.decodeIfPresent(Int.self, forKey: .manaValue) ?? 0
        colors = try c.decodeIfPresent([ManaColor].self, forKey: .colors) ?? []
        colorIdentity = try c.decodeIfPresent([ManaColor].self, forKey: .colorIdentity) ?? colors
        typeLine = try c.decode(String.self, forKey: .typeLine)
        supertypes = try c.decodeIfPresent([String].self, forKey: .supertypes) ?? []
        types = try c.decodeIfPresent([String].self, forKey: .types) ?? []
        subtypes = try c.decodeIfPresent([String].self, forKey: .subtypes) ?? []
        oracleText = try c.decodeIfPresent(String.self, forKey: .oracleText) ?? ""
        flavorText = try c.decodeIfPresent(String.self, forKey: .flavorText) ?? ""
        keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        power = try c.decodeIfPresent(String.self, forKey: .power)
        toughness = try c.decodeIfPresent(String.self, forKey: .toughness)
        let produced = try c.decodeIfPresent([String].self, forKey: .producedMana) ?? []
        producedMana = produced.compactMap { ManaColor(rawValue: $0) }
        producesColorless = produced.contains("C")
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? "normal"
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        variant = try c.decodeIfPresent(Bool.self, forKey: .variant) ?? false
        imageLarge = try c.decodeIfPresent(String.self, forKey: .imageLarge) ?? ""
    }

    // MARK: Types

    public var isLand: Bool { types.contains("Land") }
    public var isBasicLand: Bool { isLand && supertypes.contains("Basic") }
    public var isCreature: Bool { types.contains("Creature") }
    public var isArtifact: Bool { types.contains("Artifact") }
    public var isEnchantment: Bool { types.contains("Enchantment") }
    public var isInstant: Bool { types.contains("Instant") }
    public var isSorcery: Bool { types.contains("Sorcery") }
    public var isLegendary: Bool { supertypes.contains("Legendary") }
    public var isSpacecraft: Bool { subtypes.contains("Spacecraft") }
    public var isSaga: Bool { subtypes.contains("Saga") }
    public var isAura: Bool { subtypes.contains("Aura") }
    public var isEquipment: Bool { subtypes.contains("Equipment") }
    public var isVehicle: Bool { subtypes.contains("Vehicle") }
    /// Goes onto the battlefield when it resolves (everything but instants and sorceries).
    public var isPermanent: Bool { !isInstant && !isSorcery }
    public var isSpell: Bool { !isLand }

    public var cost: ManaCost { ManaCost(parsing: manaCost) }

    /// Printed power as a number; "*" and the like read as 0.
    public var basePower: Int { Int(power ?? "") ?? 0 }
    public var baseToughness: Int { Int(toughness ?? "") ?? 0 }

    /// For a Spacecraft: the number of charge counters at which it becomes a creature.
    public var stationThreshold: Int? {
        guard isSpacecraft else { return nil }
        for line in oracleText.split(separator: "\n") {
            if let plus = line.firstIndex(of: "+"), line.contains("|"), let n = Int(line[line.startIndex..<plus]) { return n }
        }
        return nil
    }

    /// Short description of the color for sorting and theming ("W", "UB", "C" for colorless).
    public var colorKey: String { colors.isEmpty ? "C" : colors.sorted().map(\.rawValue).joined() }

    /// The rules text as it reads with reminder text (parentheses) removed.
    public var rulesText: String { Card.stripReminders(oracleText) }

    public static func stripReminders(_ text: String) -> String {
        var out = ""; var depth = 0
        for ch in text {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// A mana cost such as {2}{W}{W} or {X}{R}, broken into what has to be paid.
public struct ManaCost: Hashable, Codable, Sendable, CustomStringConvertible {
    public var generic: Int = 0
    public var colored: [ManaColor: Int] = [:]
    /// Hybrid symbols like {W/U}: pay either color.
    public var hybrid: [[ManaColor]] = []
    public var hasX: Bool = false

    public init() {}
    public init(generic: Int = 0, colored: [ManaColor: Int] = [:], hybrid: [[ManaColor]] = [], hasX: Bool = false) {
        self.generic = generic; self.colored = colored; self.hybrid = hybrid; self.hasX = hasX
    }

    /// Parses Scryfall's notation: {1}{W}, {U/B}, {X}, {C}. Anything unknown counts as generic 0.
    public init(parsing text: String) {
        var symbol = ""; var inSymbol = false
        for ch in text {
            if ch == "{" { inSymbol = true; symbol = ""; continue }
            if ch == "}" {
                inSymbol = false
                if let n = Int(symbol) { generic += n }
                else if symbol == "X" { hasX = true }
                else if symbol == "C" { generic += 1 }
                else if symbol.contains("/") {
                    let parts = symbol.split(separator: "/").compactMap { ManaColor(rawValue: String($0)) }
                    if parts.count == 2 { hybrid.append(parts) }
                    else if let one = parts.first { colored[one, default: 0] += 1 } // {2/W} and phyrexian: pay the color
                } else if let c = ManaColor(rawValue: symbol) { colored[c, default: 0] += 1 }
                continue
            }
            if inSymbol { symbol.append(ch) }
        }
    }

    public var manaValue: Int { generic + colored.values.reduce(0, +) + hybrid.count }
    public var isFree: Bool { manaValue == 0 && !hasX }

    public func adding(generic extra: Int) -> ManaCost { var c = self; c.generic += extra; return c }

    public var description: String {
        var s = hasX ? "{X}" : ""
        if generic > 0 { s += "{\(generic)}" }
        for c in ManaColor.allCases { for _ in 0..<(colored[c] ?? 0) { s += "{\(c.rawValue)}" } }
        for h in hybrid { s += "{" + h.map(\.rawValue).joined(separator: "/") + "}" }
        return s.isEmpty ? "{0}" : s
    }
}
