import Foundation

/// Turns a card's rules text into `Ability` values. Pattern-based: it knows the phrasings this set
/// uses and leaves the rest as `.unsupported`, so every card is at least playable for its stats.
public enum AbilityParser {
    public static func parse(_ card: Card) -> ParsedCard {
        var p = Parser(card: card)
        return p.run()
    }
}

// MARK: - Regex helpers

func rx(_ text: String, _ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: "^(?:" + pattern + ")$", options: [.caseInsensitive]) else { return nil }
    let ns = text as NSString
    guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }
}

func replacing(_ text: String, _ pattern: String, with template: String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
}

func number(_ word: String) -> Int? {
    let w = word.lowercased().trimmingCharacters(in: .whitespaces)
    if let n = Int(w) { return n }
    let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
                 "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "twenty": 20]
    return words[w]
}

private let numberWord = "(a|an|one|two|three|four|five|six|seven|eight|nine|ten|twelve|\\d+|x)"

// MARK: - Parser

struct Parser {
    let card: Card
    var abilities: [Ability] = []
    var unsupported: [String] = []

    init(card: Card) { self.card = card }

    mutating func run() -> ParsedCard {
        let text = normalize(card.rulesText)
        var lines = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }

        // "Choose one —" followed by bullet lines is one ability.
        var grouped: [String] = []
        var i = 0
        while i < lines.count {
            var line = lines[i]
            if line.hasSuffix("—") || line.lowercased().hasSuffix("choose one —") {
                var j = i + 1
                while j < lines.count, lines[j].hasPrefix("•") { line += "\n" + lines[j]; j += 1 }
                i = j
            } else { i += 1 }
            grouped.append(line)
        }
        lines = grouped

        if card.isSaga { parseSaga(lines); return finish() }
        for line in lines { parseLine(line) }
        return finish()
    }

    mutating func finish() -> ParsedCard {
        // Basic lands and dual lands keep their mana ability in reminder text, which is stripped.
        if card.isLand, !abilities.contains(where: { if case .mana = $0 { return true } else { return false } }),
           !card.producedMana.isEmpty || card.producesColorless {
            abilities.append(.mana(card.producedMana))
        }
        if card.isSpacecraft, card.keywords.contains("Station"), !abilities.contains(.keyword(Keyword(.station))) {
            abilities.append(.keyword(Keyword(.station)))
        }
        return ParsedCard(abilities: abilities, unsupported: unsupported)
    }

    // MARK: Normalizing

    /// Self-references become "~", "U.S.S." stops looking like a sentence end, and smart quotes go.
    func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "U.S.S.", with: "USS").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "–", with: "-")
        let fullName = card.name.replacingOccurrences(of: "U.S.S.", with: "USS")
        var names = [fullName]
        if let comma = fullName.firstIndex(of: ",") { names.append(String(fullName[..<comma])) }
        for n in names.sorted(by: { $0.count > $1.count }) where !n.isEmpty {
            t = t.replacingOccurrences(of: n, with: "~")
        }
        t = replacing(t, "\\bthis (creature|Spacecraft|artifact|enchantment|land|permanent|token|card|Saga|Equipment|Aura|spell|vehicle)\\b", with: "~")
        return t
    }

    // MARK: Lines

    mutating func parseLine(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        let lower = line.lowercased()

        // Spacecraft: "6+ | Flying, lifelink"
        if let m = rx(line, "(\\d+)\\+\\s*\\|\\s*(.*)") {
            let parts = m[2].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let kws = parts.compactMap { keyword($0) }
            if kws.count == parts.count { abilities.append(.stationAbilities(threshold: Int(m[1]) ?? 0, kws)) }
            else { abilities.append(.stationAbilities(threshold: Int(m[1]) ?? 0, [])); unsupported.append(line) }
            return
        }
        // Ability words ("Landfall — ", "Cloaking Device — ") are just labels.
        var body = line
        if let m = rx(line, "([A-Z][A-Za-z' ]+) — (.+)"), !m[1].lowercased().hasPrefix("choose") { body = m[2] }
        let bl = body.lowercased()

        // A line of keywords: "Flying, lifelink" / "Ward {2}" / "Kicker {4}" / "Equip {2}".
        if let kws = keywordLine(body) { abilities.append(contentsOf: kws); return }

        // Mana abilities.
        if let m = rx(body, "\\{T\\}: Add (.+?)\\.?") {
            if let colors = manaColors(m[1]) { abilities.append(.mana(colors)); return }
        }

        // Static abilities.
        if let s = staticAbility(bl) { abilities.append(.staticAbility(s)); return }

        // Triggered abilities.
        if bl.hasPrefix("when") || bl.hasPrefix("at the beginning of") {
            parseTriggered(body); return
        }
        _ = lower

        // Activated abilities: "cost: effect".
        if let m = rx(body, "([^:]+): (.+)"), let cost = activationCost(m[1]) {
            var effectText = m[2]
            var c = cost
            var sorcery = false
            if let n = rx(effectText, "(.+?)\\s*Activate only as a sorcery\\.?") { effectText = n[1]; sorcery = true }
            if let n = rx(effectText, "(.+?)\\s*Activate only once each turn\\.?") { effectText = n[1]; c.oncePerTurn = true }
            if let n = rx(effectText, "(.+?)\\s*Activate only during your turn\\.?") { effectText = n[1]; sorcery = true }
            let (fx, bad) = effects(effectText)
            if bad.isEmpty, !fx.isEmpty { abilities.append(.activated(c, fx, sorcerySpeed: sorcery)) }
            else { unsupported.append(line) }
            return
        }

        // Instants and sorceries: the line is what the spell does.
        if card.isInstant || card.isSorcery {
            let (fx, bad) = effects(body)
            if bad.isEmpty, !fx.isEmpty { abilities.append(.spell(fx)) } else { unsupported.append(contentsOf: bad.isEmpty ? [line] : bad) }
            return
        }
        unsupported.append(line)
    }

    mutating func parseSaga(_ lines: [String]) {
        var chapters: [[Effect]] = []
        var bad: [String] = []
        for line in lines {
            guard let m = rx(line, "((?:I|II|III|IV|V)(?:, (?:I|II|III|IV|V))*) — (.+)") else {
                if !line.isEmpty { bad.append(line) }
                continue
            }
            let (fx, b) = effects(m[2])
            if !b.isEmpty || fx.isEmpty { bad.append(line); continue }
            for chapter in m[1].split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let n = ["I": 1, "II": 2, "III": 3, "IV": 4, "V": 5][chapter] ?? 1
                while chapters.count < n { chapters.append([]) }
                chapters[n - 1] = fx
            }
        }
        if bad.isEmpty { abilities.append(.saga(chapters)) } else { unsupported.append(contentsOf: bad) }
    }

    // MARK: Keywords

    func keyword(_ word: String) -> Keyword? {
        let w = word.lowercased().trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let m = rx(w, "ward \\{(\\d+)\\}") { return Keyword(.ward, value: Int(m[1]) ?? 0) }
        if w == "ward" { return Keyword(.ward, value: 1) }
        if w == "can't be blocked" || w == "~ can't be blocked" { return .unblockable }
        if w == "can't block" || w == "~ can't block" { return .cantBlock }
        return KeywordKind(rawValue: w).map { Keyword($0) }
    }

    func keywordLine(_ line: String) -> [Ability]? {
        var out: [Ability] = []
        for part in line.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let p = part.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if let k = keyword(p) { out.append(.keyword(k)); continue }
            if let m = rx(p, "kicker (\\{.+\\})") { out.append(.kicker(ManaCost(parsing: m[1]))); continue }
            if let m = rx(p, "beam me up (\\{.+\\})") { out.append(.beamMeUp(ManaCost(parsing: m[1]))); continue }
            if let m = rx(p, "equip (\\{.+\\})") { out.append(.equip(ManaCost(parsing: m[1]))); continue }
            if let m = rx(p, "cycling (\\{.+\\})") { out.append(.cycling(ManaCost(parsing: m[1]), landType: nil)); continue }
            if let m = rx(p, "basic landcycling (\\{.+\\})") { out.append(.cycling(ManaCost(parsing: m[1]), landType: "basic")); continue }
            if let m = rx(p, "(plains|island|swamp|mountain|forest)cycling (\\{.+\\})") {
                out.append(.cycling(ManaCost(parsing: m[2]), landType: m[1].capitalized)); continue
            }
            if p == "enchant creature" || p == "enchant artifact or creature" { out.append(.staticAbility(.enchantCreature)); continue }
            if p == "enchant creature an opponent controls" { out.append(.staticAbility(.enchantCreatureOpponentControls)); continue }
            if p == "prowess" { out.append(.triggered(.castSpell(.noncreature), [.pump(power: 1, toughness: 1, .this, .endOfTurn)])); continue }
            return nil
        }
        return out.isEmpty ? nil : out
    }

    func manaColors(_ text: String) -> [ManaColor]? {
        let t = text.lowercased()
        if t.contains("any color") || t.contains("any one color") { return ManaColor.allCases }
        if t == "{c}" || t == "{c}{c}" { return [] }
        var colors: [ManaColor] = []
        for ch in t where ch == "{" { _ = ch }
        var sym = ""; var inSym = false
        for ch in t {
            if ch == "{" { inSym = true; sym = ""; continue }
            if ch == "}" { inSym = false; if let c = ManaColor(rawValue: sym.uppercased()) { colors.append(c) } else if sym != "c" { return nil }; continue }
            if inSym { sym.append(ch) }
        }
        let rest = replacing(t, "\\{[a-z]\\}|or|,|\\s|\\.", with: "")
        return rest.isEmpty ? colors : nil
    }

    // MARK: Statics

    func staticAbility(_ l: String) -> StaticAbility? {
        if l == "~ enters tapped." || l == "~ enters the battlefield tapped." { return .entersTapped }
        if let m = rx(l, "~ enters tapped unless you control (two|three) or more other lands\\.") { return .entersTappedUnless(landsAtLeast: number(m[1]) ?? 2) }
        if l == "as ~ enters, you may pay 2 life. if you don't, it enters tapped." { return .shockLand }
        if l == "you may play an additional land on each of your turns." { return .extraLandEachTurn }
        if l == "you have no maximum hand size." { return .noMaxHandSize }
        if l == "~ can't be countered." { return .cantBeCountered }
        if l == "as long as ~ isn't a creature, it has hexproof." { return .hexproofWhileNotCreature }
        if let m = rx(l, "during your turn, ~ has (.+?)\\."), let k = keyword(m[1]) { return .keywordDuringYourTurn(k) }
        if let m = rx(l, "during your turn, (.+?) have (.+?)\\."), let f = filterFromPlural(m[1]), let k = keyword(m[2]) { return .grantKeywordDuringYourTurn(f, k) }
        if let m = rx(l, "~'s power( and toughness are each| is) equal to the number of (.+?)\\."), let a = countAmount(m[2]) {
            return .powerEquals(a, andToughness: m[1].contains("toughness"))
        }
        if let m = rx(l, "(equipped|enchanted) creature gets ([+-]\\d+)/([+-]\\d+)(?: and has (.+?))?\\.") {
            if m[4].isEmpty { return .attachedGets(power: Int(m[2]) ?? 0, toughness: Int(m[3]) ?? 0) }
            return nil
        }
        if let m = rx(l, "(equipped|enchanted) creature has (.+?)\\."), let k = keyword(m[2]) { return .attachedHas(k) }
        if l.hasPrefix("enchanted creature can't attack or block") { return .attachedCantAttackOrBlock }
        if let m = rx(l, "~ gets \\+(\\d+)/\\+(\\d+) for each (artifact|creature|land) you control\\.") {
            let amount: Amount = m[3] == "artifact" ? .artifactsYouControl : (m[3] == "creature" ? .creaturesYouControl : .landsYouControl)
            return .selfPumpPerCount(amount, power: Int(m[1]) ?? 0, toughness: Int(m[2]) ?? 0)
        }
        if let m = rx(l, "(.+?) have \"(.+)\""), let f = filterFromPlural(m[1]) {
            let inner = m[2].prefix(1).uppercased() + m[2].dropFirst()
            if let parts = triggerParts(inner), parts.count == 1 { return .grantTrigger(f, parts[0].0, parts[0].1) }
            return nil
        }
        if let m = rx(l, "(.+?) (?:get|have) (.+?)\\."), let f = filterFromPlural(m[1]) {
            if let n = rx(m[2], "([+-]\\d+)/([+-]\\d+)") { return .anthem(f, power: Int(n[1]) ?? 0, toughness: Int(n[2]) ?? 0) }
            if let k = keyword(m[2]) { return .grantKeyword(f, k) }
        }
        return nil
    }

    /// "creatures you control", "other Klingons you control", "artifact creatures you control".
    func filterFromPlural(_ s: String) -> Filter? {
        var text = s.lowercased()
        var withCounters = false
        if text.hasSuffix(" with counters on them") { withCounters = true; text = String(text.dropLast(22)) }
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 2 else { return nil }
        var controller = Controller.any
        if words.suffix(2) == ["you", "control"] { controller = .you; words.removeLast(2) }
        else if words.suffix(3) == ["your", "opponents", "control"] || words.suffix(3) == ["you", "don't", "control"] { controller = .opponent; words.removeLast(3) }
        guard controller != .any, !words.isEmpty else { return nil }
        var f = Filter(.permanent, controller: controller)
        f.withCounters = withCounters
        var noun = words.removeLast()
        if noun.hasSuffix("s") { noun.removeLast() }
        switch noun {
        case "creature": f.kind = .creature
        case "artifact": f.kind = .artifact
        case "spacecraft": f.kind = .spacecraft
        case "permanent": f.kind = .permanent
        case "land": f.kind = .land
        default:
            // A creature type: "Klingons", "Borg", "Officers" (subtype words are capitalized in the text).
            let original = s.split(separator: " ").map(String.init)
            let idx = words.count
            if idx < original.count, original[idx].first?.isUppercase == true {
                f.kind = .creature; f.subtype = original[idx].hasSuffix("s") && original[idx] != "Borg" ? String(original[idx].dropLast()) : original[idx]
            } else { return nil }
        }
        for w in words {
            switch w {
            case "other": f.other = true
            case "artifact": f.kind = f.kind == .creature ? .artifactCreature : .artifact
            case "nontoken": f.nontoken = true
            case "attacking": f.attacking = true
            case "tapped": f.tapped = true
            case "untapped": f.untapped = true
            case "legendary", "nonlegendary", "all": break
            default:
                let original = s.split(separator: " ").map(String.init)
                if let o = original.first(where: { $0.lowercased() == w }), o.first?.isUppercase == true, f.kind == .creature { f.subtype = o }
                else { return nil }
            }
        }
        return f
    }

    // MARK: Triggers

    mutating func parseTriggered(_ line: String) {
        if let parts = triggerParts(line) { for (e, fx) in parts { abilities.append(.triggered(e, fx)) } }
        else { unsupported.append(line) }
    }

    /// The events and effects of a triggered-ability line, or nil if any part is beyond the engine.
    func triggerParts(_ line: String) -> [(TriggerEvent, [Effect])]? {
        let l = line
        if let m = rx(l, "(?s)At the beginning of (your upkeep|your end step|combat on your turn|each combat|your precombat main phase|each upkeep|each end step|each opponent's upkeep), (.+)") {
            let event: TriggerEvent?
            switch m[1].lowercased() {
            case "your upkeep": event = .upkeep
            case "your end step": event = .endStep
            case "combat on your turn": event = .beginCombat
            case "each upkeep": event = .eachUpkeep
            default: event = nil
            }
            guard let e = event, let fx = triggerEffects(m[2]) else { return nil }
            return [(e, fx)]
        }
        guard let m = rx(l, "(?s)(When|Whenever) (.+?) (enters or attacks|attacks or blocks|enters untapped|enters|dies|die|attacks|blocks|becomes blocked|leaves the battlefield|deals combat damage to a player|deals combat damage to a player or planeswalker|deals combat damage to an opponent|becomes tapped|is put into a graveyard from the battlefield), (.+)") else {
            if let m = rx(l, "(?s)Whenever you cast (a|an) (noncreature|creature|artifact|instant or sorcery)? ?spell, (.+)") {
                let kind: SpellKind = ["noncreature": .noncreature, "creature": .creature, "artifact": .artifact, "instant or sorcery": .instantOrSorcery][m[2].lowercased()] ?? .any
                return triggerEffects(m[3]).map { [(.castSpell(kind), $0)] }
            }
            if let m = rx(l, "(?s)Whenever you gain life, (.+)") { return triggerEffects(m[1]).map { [(.gainLife, $0)] } }
            if let m = rx(l, "(?s)Whenever you station, (.+)") { return triggerEffects(m[1]).map { [(.stationed, $0)] } }
            if let m = rx(l, "(?s)Whenever a land enters (?:the battlefield )?under your control, (.+)") { return triggerEffects(m[1]).map { [(.landfall, $0)] } }
            return nil
        }
        let subject = m[2]
        let verb = m[3].lowercased()
        let effectText = m[4]
        let subjectLower = subject.lowercased()
        var events: [TriggerEvent] = []
        if verb == "enters", let m2 = rx(subject, "(.+?) or (another .+)"), isSelfSubject(m2[1]), let f = filterFromSingular(m2[2]) {
            events = [.enters, .permanentEnters(f)]
        } else if subjectLower == "~" || isSelfSubject(subject) {
            switch verb {
            case "enters": events = [.enters]
            case "enters untapped": events = [.entersUntapped]
            case "enters or attacks": events = [.enters, .attacks]
            case "attacks or blocks": events = [.attacks, .blocks]
            case "dies", "die", "is put into a graveyard from the battlefield": events = [.dies]
            case "attacks": events = [.attacks]
            case "blocks": events = [.blocks]
            case "becomes blocked": events = [.blocked]
            case "leaves the battlefield": events = [.leaves]
            case "deals combat damage to a player", "deals combat damage to a player or planeswalker", "deals combat damage to an opponent": events = [.combatDamageToPlayer]
            case "becomes tapped": events = [.becomesTapped]
            default: break
            }
        } else if verb == "enters" {
            if subjectLower == "a land you control" || subjectLower == "a land" { events = [.landfall] }
            else if subjectLower.hasPrefix("~ or another ") || subjectLower.hasPrefix("~ or a ") {
                let rest = String(subject.dropFirst(subjectLower.hasPrefix("~ or another ") ? 13 : 7))
                if let f = filterFromSingular(rest) { var g = f; g.other = true; events = [.enters, .permanentEnters(g)] }
            } else if let f = filterFromSingular(subject) { events = [.permanentEnters(f)] }
        } else if verb == "dies" || verb == "is put into a graveyard from the battlefield" {
            if let f = filterFromSingular(subject) { events = [.permanentDies(f)] }
        }
        guard !events.isEmpty, let fx = triggerEffects(effectText) else { return nil }
        return events.map { ($0, fx) }
    }

    func triggerEffects(_ text: String) -> [Effect]? {
        let (fx, bad) = effects(text)
        return bad.isEmpty && !fx.isEmpty ? fx : nil
    }

    /// Names of legendary permanents appear as the subject ("Captain Janeway", "USS Enterprise-A").
    func isSelfSubject(_ subject: String) -> Bool {
        let generic = ["a ", "an ", "another ", "one or more ", "each ", "you", "target ", "equipped", "enchanted", "that "]
        let l = subject.lowercased()
        if generic.contains(where: { l.hasPrefix($0) }) { return false }
        return subject.first?.isUppercase == true || l == "~"
    }

    /// "another creature you control", "a creature you control", "another Klingon you control", "an artifact you control".
    func filterFromSingular(_ s: String) -> Filter? {
        var words = s.lowercased().split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        var other = false
        if first == "another" { other = true; words.removeFirst() }
        else if first == "a" || first == "an" || first == "one" { words.removeFirst() }
        else if words.prefix(3) == ["one", "or", "more"] { words.removeFirst(3) }
        else { return nil }
        var controller = Controller.any
        if words.suffix(2) == ["you", "control"] { controller = .you; words.removeLast(2) }
        else if words.suffix(3) == ["an", "opponent", "controls"] || words.suffix(3) == ["you", "don't", "control"] { controller = .opponent; words.removeLast(3) }
        guard !words.isEmpty else { return nil }
        let original = s.split(separator: " ").map(String.init)
        var f = Filter(.creature, controller: controller); f.other = other
        let noun = words.removeLast()
        switch noun {
        case "creature": f.kind = .creature
        case "artifact": f.kind = .artifact
        case "permanent": f.kind = .permanent
        case "land": f.kind = .land
        case "spacecraft": f.kind = .spacecraft
        case "token": f.kind = .token
        default:
            if let o = original.first(where: { $0.lowercased() == noun }), o.first?.isUppercase == true { f.kind = .creature; f.subtype = o } else { return nil }
        }
        for w in words {
            switch w {
            case "artifact": f.kind = f.kind == .creature ? .artifactCreature : .artifact
            case "nontoken": f.nontoken = true
            case "other": f.other = true
            default:
                if let o = original.first(where: { $0.lowercased() == w }), o.first?.isUppercase == true, f.kind == .creature { f.subtype = o } else { return nil }
            }
        }
        return f
    }

    // MARK: Activation costs

    func activationCost(_ text: String) -> ActivationCost? {
        var cost = ActivationCost()
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let p = part.lowercased()
            if p == "{t}" { cost.tap = true; continue }
            if p.hasPrefix("{"), !p.contains("t}"), !p.contains("q}") {
                let c = ManaCost(parsing: p.uppercased())
                if c.manaValue == 0 && !c.hasX && p != "{0}" { return nil }
                if c.hasX { return nil }
                cost.mana.generic += c.generic
                for (k, v) in c.colored { cost.mana.colored[k, default: 0] += v }
                cost.mana.hybrid += c.hybrid
                continue
            }
            if p == "sacrifice ~" { cost.sacrificeSelf = true; continue }
            if let m = rx(p, "sacrifice (a|an|another) (creature|artifact|land|permanent|token)") {
                var f = Filter(.creature, controller: .you)
                switch m[2] { case "artifact": f.kind = .artifact; case "land": f.kind = .land; case "permanent": f.kind = .permanent; case "token": f.kind = .token; default: break }
                f.other = m[1] == "another"
                cost.sacrifice = f; continue
            }
            if let m = rx(p, "pay (\\d+) life") { cost.payLife = Int(m[1]) ?? 0; continue }
            if p == "discard a card" { cost.discard = 1; continue }
            return nil
        }
        return cost
    }

    // MARK: Effects

    /// Splits a text into sentences and parses each; returns what parsed and what didn't.
    func effects(_ text: String) -> ([Effect], [String]) {
        var out: [Effect] = []
        var bad: [String] = []
        let t = text.trimmingCharacters(in: .whitespaces)
        // Modal: "choose one —\n• A\n• B"
        if let m = rx(t, "(?s)choose one —\\s*(.+)") {
            var modes: [[Effect]] = []
            for mode in m[1].split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where mode.hasPrefix("•") {
                var modeText = String(mode.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let named = rx(modeText, "(?s)[A-Z][^—]+ — (.+)") { modeText = named[1] }   // "Temba, His Arms Wide — ..."
                let (fx, b) = effects(modeText)
                if !b.isEmpty || fx.isEmpty { return ([], [t]) }
                modes.append(fx)
            }
            return modes.isEmpty ? ([], [t]) : ([.modal(modes)], [])
        }
        for sentence in sentences(t) {
            let l = sentence.lowercased()
            if l.hasPrefix("if you do, "), !out.isEmpty, let fx = effect(String(sentence.dropFirst(11))) {
                // "You may X. If you do, Y" folds Y into the optional X.
                if case .optional(let inner) = out[out.count - 1] { out[out.count - 1] = .optional(inner + fx) }
                else { out.append(.ifDidPrevious(fx)) }
                continue
            }
            if let m = rx(sentence, "(?i)if ~ was kicked, (?:instead (.+)|(.+?) instead)"), let fx = effect(m[1].isEmpty ? m[2] : m[1]) {
                out.append(.kickedInstead(fx)); continue
            }
            if let fx = effect(sentence) { out.append(contentsOf: fx) } else { bad.append(sentence) }
        }
        return (out, bad)
    }

    func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            current.append(ch)
            if ch == ".", i + 1 < chars.count, chars[i + 1] == " " {
                result.append(current); current = ""; i += 2; continue
            }
            i += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .map { s in s.hasPrefix("Then ") ? String(s.dropFirst(5)) : (s.hasPrefix("then ") ? String(s.dropFirst(5)) : s) }
            .filter { !$0.isEmpty }
    }

    func amount(_ w: String) -> Amount? {
        if let n = number(w) { return .fixed(n) }
        return nil
    }

    /// One sentence to effects, or nil.
    func effect(_ sentenceIn: String) -> [Effect]? {
        var s = sentenceIn.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".") { s.removeLast() }
        let l = s.lowercased()

        if l.hasPrefix("you may ") {
            guard let inner = effect(String(s.dropFirst(8))) else { return nil }
            return [.optional(inner)]
        }
        // "Draw a card, then discard a card."
        if let m = rx(s, "(?i)(.+?), then (.+)"), let a = effect(m[1]), let b = effect(m[2]) { return a + b }
        if let m = rx(s, "(?i)if ~ (isn't|is) a creature, (.+)"), let inner = effect(m[2]) {
            return [.conditional(m[1].lowercased() == "is" ? .thisIsCreature : .thisIsNotCreature, inner)]
        }
        if let m = rx(l, "create a token that's a copy of (.+?)(?:, except it has (.+))?"), let t = target(m[1]) {
            var extra: [Keyword] = []
            if !m[2].isEmpty { guard let k = keyword(m[2]) else { return nil }; extra = [k] }
            return [.copyToken(t, extra: extra)]
        }
        // "X. If you do, Y" and "if ..." conditions are beyond the engine.
        if l.contains(" if ") || l.hasPrefix("if ") || l.contains(" instead") || l.contains(" unless ") { return nil }

        // Damage
        if let m = rx(l, "(?:~|it|he|she|they) deals? \(numberWord) damage to (.+?)(?: and \(numberWord) damage to (.+))?") {
            guard let a = amount(m[1]), let t = target(m[2]) else { return nil }
            var fx: [Effect] = [.damage(a, t)]
            if !m[3].isEmpty { guard let a2 = amount(m[3]), let t2 = target(m[4]) else { return nil }; fx.append(.damage(a2, t2)) }
            return fx
        }
        if let m = rx(l, "(?:~|it) deals \(numberWord) damage"), let a = amount(m[1]) { return [.damage(a, .lastTarget)] }
        if let m = rx(l, "pay (\\d+) life") { return [.payLife(Int(m[1]) ?? 0)] }
        if let m = rx(l, "pay (\\{.+\\})") { return [.payMana(ManaCost(parsing: m[1].uppercased()))] }
        if let m = rx(l, "discover (\\d+)") { return [.discover(Int(m[1]) ?? 0)] }
        if let m = rx(l, "target opponent exiles cards from the top of their library until they exile a creature card\\. assimilate that card\\. they put the rest on the bottom in a random order") { _ = m; return [.assimilateFromLibrary(.target(.opponent))] }
        if let m = rx(l, "assimilate a creature card exiled with it\\. if you can't, exile (.+)"), let t = target(m[1]) { return [.assimilateExiledOrExile(t)] }
        if let m = rx(l, "distribute \(numberWord) \\+1/\\+1 counters among one or two target creatures"), let a = amount(m[1]) { return [.addCounters(.plusOne, a, .target(.creature))] }
        if let m = rx(l, "(it|that creature) deals damage equal to its power to (.+)") { _ = m; return nil }
        if let m = rx(l, "~ deals damage equal to its power to (.+)"), let t = target(m[1]) { return [.bite(t)] }
        if let m = rx(l, "~ fights (.+)"), let t = target(m[1]) { return [.fight(t)] }
        // Draw
        if let m = rx(l, "(?:you )?draw \(numberWord) cards?"), let a = amount(m[1]) { return [.draw(a, .you)] }
        if l == "draw a card" { return [.draw(.one, .you)] }
        if let m = rx(l, "draw cards equal to the number of cards in your hand") { _ = m; return [.draw(.cardsInHand, .you)] }
        if let m = rx(l, "draw x cards, where x is the number of differently named lands you control") { _ = m; return [.draw(.differentlyNamedLands, .you)] }
        if let m = rx(l, "(target player|target opponent|each player|each opponent|its controller|that player) draws? \(numberWord) cards?"), let t = target(m[1]), let a = amount(m[2]) { return [.draw(a, t)] }
        // Life
        if let m = rx(l, "you gain life equal to the number of (.+)"), let a = countAmount(m[1]) { return [.gainLife(a, .you)] }
        if let m = rx(l, "(?:you )?draw cards equal to the number of (.+)"), let a = countAmount(m[1]) { return [.draw(a, .you)] }
        if let m = rx(l, "you gain \(numberWord) life(?: and (.+))?"), let a = amount(m[1]) {
            var fx: [Effect] = [.gainLife(a, .you)]
            if !m[2].isEmpty { guard let more = effect(m[2]) else { return nil }; fx += more }
            return fx
        }
        if let m = rx(l, "(target player|target opponent|each opponent|each player|its controller|that player) gains? \(numberWord) life"), let t = target(m[1]), let a = amount(m[2]) { return [.gainLife(a, t)] }
        if let m = rx(l, "(each opponent|target opponent|target player|each player|its controller|that player) loses? \(numberWord) life(?: and you gain \(numberWord) life)?"), let t = target(m[1]), let a = amount(m[2]) {
            var fx: [Effect] = [.loseLife(a, t)]
            if !m[3].isEmpty, let g = amount(m[3]) { fx.append(.gainLife(g, .you)) }
            return fx
        }
        if let m = rx(l, "you lose \(numberWord) life"), let a = amount(m[1]) { return [.loseLife(a, .you)] }
        if l == "double your life total" { return [.doubleLife] }
        if l.hasPrefix("you have no maximum hand size") { return [.noMaxHandSize] }
        // Removal
        if let m = rx(l, "destroy (.+)"), let t = target(m[1]) { return [.destroy(t)] }
        if let m = rx(l, "exile (.+?)(?: until .+)?"), m[0].range(of: "until") == nil, let t = target(m[1]) { return [.exile(t)] }
        if let m = rx(l, "return (.+?) to (?:its|their) owner'?s? hands?"), let t = target(m[1]) { return [.bounce(t)] }
        if let m = rx(l, "return (.+?) from your graveyard to (your hand|the battlefield)( tapped)?") {
            guard let f = graveyardFilter(m[1]) else { return nil }
            return [.returnFromGraveyard(f, to: m[2] == "your hand" ? .hand : (m[3].isEmpty ? .battlefield : .battlefieldTapped))]
        }
        if let m = rx(l, "tap (.+?) and put a stun counter on it"), let t = target(m[1]) { return [.tap(t, freeze: false), .addCounters(.stun, .one, .lastTarget)] }
        if let m = rx(l, "tap (.+?)(?:\\. it doesn't untap during its controller's next untap step)?"), let t = target(m[1]) {
            return [.tap(t, freeze: false)]
        }
        if let m = rx(l, "untap (.+)"), let t = target(m[1]) { return [.untap(t)] }
        // Pump and keywords
        if let m = rx(l, "(.+?) gets? ([+-]\\d+)/([+-]\\d+)(?: and (?:gains?|has) (.+?))? until end of turn"), let t = target(m[1]) {
            var fx: [Effect] = [.pump(power: Int(m[2]) ?? 0, toughness: Int(m[3]) ?? 0, t, .endOfTurn)]
            if !m[4].isEmpty {
                for kw in m[4].split(separator: " and ").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    guard let k = keyword(kw) else { return nil }
                    fx.append(.grantKeyword(k, t, .endOfTurn))
                }
            }
            return fx
        }
        if let m = rx(l, "(.+?) gains? (.+?) until end of turn"), let t = target(m[1]) {
            var fx: [Effect] = []
            for kw in m[2].split(separator: " and ").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                guard let k = keyword(kw) else { return nil }
                fx.append(.grantKeyword(k, t, .endOfTurn))
            }
            return fx
        }
        if let m = rx(l, "(.+?) can't be blocked this turn"), let t = target(m[1]) { return [.grantKeyword(.unblockable, t, .endOfTurn)] }
        if let m = rx(l, "(.+?) can't block this turn"), let t = target(m[1]) { return [.cantBlock(t, .endOfTurn)] }
        // Counters
        if let m = rx(l, "put \(numberWord) (\\+1/\\+1|-1/-1|charge|stun) counters? on (.+)"), let a = amount(m[1]), let t = target(m[3]) {
            let kind: CounterKind = m[2] == "charge" ? .charge : (m[2] == "-1/-1" ? .minusOne : (m[2] == "stun" ? .stun : .plusOne))
            return [.addCounters(kind, a, t)]
        }
        if let m = rx(l, "put \(numberWord) \\+1/\\+1 counters? on each of (.+)"), let a = amount(m[1]), let t = target(m[2]) { return [.addCounters(.plusOne, a, t)] }
        // Tokens
        if let m = rx(l, "(?:(each player|each opponent|target player|target opponent) )?creates? \(numberWord) treasure tokens?"), let a = amount(m[2]), let who = m[1].isEmpty ? .you : target(m[1]) { return [.createTokens(.treasure, a, who)] }
        if let m = rx(l, "create \(numberWord) food tokens?"), let a = amount(m[1]) { return [.createTokens(.food, a, .you)] }
        if let m = rx(l, "create \(numberWord) clue tokens?"), let a = amount(m[1]) { return [.createTokens(.clue, a, .you)] }
        if l == "investigate" { return [.createTokens(.clue, .one, .you)] }
        if let m = rx(l, "(?:(each player|each opponent|target player|target opponent) )?creates? (?:[^,]+, )?\(numberWord) (?:legendary )?(\\d+)/(\\d+) (.+?) creature tokens?(?: with (.+?))?(?: named .+)?"),
           let a = amount(m[2]), let who = m[1].isEmpty ? .you : target(m[1]) {
            var spec = TokenSpec(name: "", power: Int(m[3]) ?? 0, toughness: Int(m[4]) ?? 0)
            let m = [m[0], m[1], m[2], m[3], m[4], m[5], m[6]].enumerated().map { $0.offset == 4 ? m[5] : ($0.offset == 5 ? m[6] : $0.element) }
            let words = m[4].split(separator: " ").map(String.init)
            let original = s.split(separator: " ").map(String.init)
            for w in words {
                switch w {
                case "white": spec.colors.append(.white)
                case "blue": spec.colors.append(.blue)
                case "black": spec.colors.append(.black)
                case "red": spec.colors.append(.red)
                case "green": spec.colors.append(.green)
                case "colorless", "and": break
                case "artifact": spec.isArtifact = true
                default:
                    if let o = original.first(where: { $0.lowercased() == w }) { spec.subtypes.append(o) } else { return nil }
                }
            }
            if !m[5].isEmpty {
                for kw in m[5].split(separator: " and ").flatMap({ $0.split(separator: ",") }).map({ $0.trimmingCharacters(in: .whitespaces) }) {
                    let cleaned = kw.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "~ ", with: "").replacingOccurrences(of: "this token ", with: "")
                    guard let k = keyword(cleaned) else { return nil }
                    spec.keywords.append(k)
                }
            }
            spec.name = spec.subtypes.joined(separator: " ")
            return [.createTokens(spec, a, who)]
        }
        // Library and graveyard
        if let m = rx(l, "surveil (\\d+)") { return [.surveil(Int(m[1]) ?? 1)] }
        if let m = rx(l, "scry (\\d+)") { return [.scry(Int(m[1]) ?? 1)] }
        if let m = rx(l, "(?:you )?mill \(numberWord) cards?"), let a = number(m[1]) { return [.mill(a, .you)] }
        if let m = rx(l, "(target player|target opponent|each opponent|each player) mills? \(numberWord) cards?"), let t = target(m[1]), let a = number(m[2]) { return [.mill(a, t)] }
        if let m = rx(l, "(target player|target opponent|each opponent|each player) discards? \(numberWord) cards?"), let t = target(m[1]), let a = number(m[2]) { return [.discard(a, t)] }
        if let m = rx(l, "(?:you )?discard \(numberWord) cards?"), let a = number(m[1]) { return [.discard(a, .you)] }
        if l == "search your library for a basic land card, put it onto the battlefield tapped, then shuffle"
            || l == "search your library for a basic land card, put that card onto the battlefield tapped, then shuffle" { return [.searchBasicLand(.battlefieldTapped, .you)] }
        if l == "search your library for a basic land card, put it onto the battlefield, then shuffle" { return [.searchBasicLand(.battlefield, .you)] }
        if l == "search your library for a basic land card, reveal it, put it into your hand, then shuffle" { return [.searchBasicLand(.hand, .you)] }
        if l == "its controller may search their library for a basic land card, reveal it, put it into their hand, then shuffle" { return [.optional([.searchBasicLand(.hand, .controllerOfLastTarget)])] }
        if let m = rx(l, "sacrifice (it|that token|that creature) at the beginning of the next end step") { _ = m; return [.sacrificeAtEndOfTurn(.lastTarget)] }
        if let m = rx(l, "(.+?) fights (.+)"), let a = target(m[1]), let b = target(m[2]), a != .this { return [.fightBetween(a, b)] }
        if let m = rx(l, "assimilate target creature card from (a|an opponent's|your) graveyard") {
            var f = Filter(.creatureCardInGraveyard); f.controller = m[1] == "a" ? .any : (m[1] == "your" ? .you : .opponent); return [.assimilate(f)]
        }
        if let m = rx(l, "(?:you may )?put a land card from your hand onto the battlefield( tapped)?") { return [.putLandFromHand(tapped: !m[1].isEmpty)] }
        // Sacrifice
        if let m = rx(l, "(each opponent|target opponent|target player|each player) sacrifices? (a|an) (nontoken )?(creature|artifact|land|permanent|enchantment|artifact or enchantment|artifact or creature)(?: of their choice)?"), let t = target(m[1]) {
            var f = Filter(.creature)
            switch m[4] { case "artifact": f.kind = .artifact; case "land": f.kind = .land; case "permanent": f.kind = .permanent; case "enchantment": f.kind = .enchantment
            case "artifact or enchantment": f.kind = .artifactOrEnchantment; case "artifact or creature": f.kind = .artifactOrCreature; default: break }
            f.nontoken = !m[3].isEmpty
            return [.sacrifice(t, f)]
        }
        if let m = rx(l, "sacrifice (a|an) (creature|artifact|land|creature token|artifact or creature)") {
            var f = Filter(.creature)
            switch m[2] { case "artifact": f.kind = .artifact; case "land": f.kind = .land; case "creature token": f.kind = .token; case "artifact or creature": f.kind = .artifactOrCreature; default: break }
            return [.sacrifice(.you, f)]
        }
        if l == "sacrifice ~" { return [.sacrifice(.you, Filter(.token))] } // handled specially by the engine: sacrifices the source
        // Explore
        if let m = rx(l, "(.+?) explores?"), let t = target(m[1]) { return [.explore(t)] }
        if l == "it explores" || l == "that creature explores" { return [.explore(.lastTarget)] }
        // Mana
        if let m = rx(l, "add (.+)"), let colors = manaColors(m[1]) { return [.addMana(colors)] }
        if let m = rx(l, "gain control of (.+)"), let t = target(m[1]) { return [.gainControl(t)] }
        // "You draw two cards and each player loses 2 life."
        if let range = s.range(of: " and ", options: .caseInsensitive),
           let a = effect(String(s[s.startIndex..<range.lowerBound])), let b = effect(String(s[range.upperBound...])) { return a + b }
        return nil
    }

    /// "creatures you control", "differently named lands you control", "cards in your hand".
    func countAmount(_ text: String) -> Amount? {
        switch text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) {
        case "creatures you control": return .creaturesYouControl
        case "artifacts you control": return .artifactsYouControl
        case "lands you control": return .landsYouControl
        case "differently named lands you control": return .differentlyNamedLands
        case "cards in your hand": return .cardsInHand
        default: return nil
        }
    }

    func graveyardFilter(_ text: String) -> Filter? {
        let l = text.lowercased()
        if l == "target creature card" { var f = Filter(.creatureCardInGraveyard); f.controller = .you; return f }
        if let m = rx(l, "target (artifact )?creature card with mana value (\\d+) or less") {
            var f = Filter(.creatureCardInGraveyard); f.controller = .you; f.maxManaValue = Int(m[2]); f.nonartifact = false
            if !m[1].isEmpty { f.subtype = nil; f.kind = .creatureCardInGraveyard; f.attacking = false; f.withCounters = false; f.tapped = false; f.other = false; f.blocking = false; f.untapped = false; f.nontoken = false; f.minPower = nil; f.maxPower = nil }
            return f
        }
        return nil
    }

    // MARK: Targets

    func target(_ textIn: String) -> Target? {
        let t = textIn.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "~", "this": return .this
        case "you": return .you
        case "it", "that creature", "that permanent", "that player", "them", "that spacecraft": return .lastTarget
        case "its controller", "that creature's controller": return .controllerOfLastTarget
        case "any target": return .target(.anyTarget)
        case "equipped creature", "enchanted creature": return .attachedCreature
        case "each opponent", "your opponents": return .each(.opponent)
        case "each player": return .each(.player)
        case "target player", "target player or planeswalker": return .target(.player)
        case "target opponent", "target opponent or planeswalker": return .target(.opponent)
        default: break
        }
        if let m = rx(t, "up to (one|two|three) (?:other )?target (.+)"), let n = number(m[1]), let f = targetFilter(m[2]) {
            return .target(f, count: n, optional: true)
        }
        if let m = rx(t, "(another )?target (.+)"), var f = targetFilter(m[2]) {
            if !m[1].isEmpty { f.other = true }
            return .target(f)
        }
        if let m = rx(t, "(?:each|all) (.+)") {
            let rest = m[1]
            if rest == "creature" || rest == "creatures" { return .each(.creature) }
            if rest == "other creature" || rest == "other creatures" { var f = Filter.creature; f.other = true; return .each(f) }
            if rest == "opponent" { return .each(.opponent) }
            if rest == "player" { return .each(.player) }
            if let f = filterFromPlural(rest.hasSuffix("s") ? rest : rest + "s") { return .each(f) }
            if let f = filterFromPlural(rest) { return .each(f) }
            return nil
        }
        if let f = filterFromPlural(t) { return .each(f) }
        return nil
    }

    /// The words after "target": "creature", "creature or Spacecraft", "nonland permanent an opponent controls", "creature with power 2 or less".
    func targetFilter(_ textIn: String) -> Filter? {
        var t = textIn.lowercased().trimmingCharacters(in: .whitespaces)
        var f = Filter(.creature)
        if let m = rx(t, "(.+?) with power (\\d+) or less") { t = m[1]; f.maxPower = Int(m[2]) }
        if let m = rx(t, "(.+?) with power (\\d+) or greater") { t = m[1]; f.minPower = Int(m[2]) }
        if let m = rx(t, "(.+?) with mana value (\\d+) or less") { t = m[1]; f.maxManaValue = Int(m[2]) }
        if let m = rx(t, "(.+?) you control") { t = m[1]; f.controller = .you }
        else if let m = rx(t, "(.+?) (?:an opponent controls|you don't control|your opponents control)") { t = m[1]; f.controller = .opponent }
        var words = t.split(separator: " ").map(String.init)
        // Multi-word nouns first.
        let joined = words.joined(separator: " ")
        let nouns: [(String, Filter.Kind)] = [
            ("creature or spacecraft", .creatureOrSpacecraft), ("creature or planeswalker", .creature), ("artifact or enchantment", .artifactOrEnchantment),
            ("nonland permanent", .nonlandPermanent), ("artifact creature", .artifactCreature), ("artifact or creature", .artifactOrCreature), ("player or planeswalker", .player),
            ("creature or player", .creatureOrPlayer), ("creature", .creature), ("spacecraft", .spacecraft), ("artifact", .artifact),
            ("enchantment", .enchantment), ("permanent", .permanent), ("land", .land), ("opponent", .opponent), ("player", .player), ("token", .token)
        ]
        var matched = false
        for (noun, kind) in nouns {
            let plural = noun + "s"
            if joined == noun || joined == plural { f.kind = kind; words = []; matched = true; break }
            if joined.hasSuffix(" " + plural) {
                f.kind = kind; matched = true
                words = String(joined.prefix(joined.count - plural.count - 1)).split(separator: " ").map(String.init)
                break
            }
            if joined.hasSuffix(" " + noun) {
                f.kind = kind; matched = true
                let prefixCount = joined.count - noun.count - 1
                words = String(joined.prefix(prefixCount)).split(separator: " ").map(String.init)
                break
            }
        }
        let original = textIn.split(separator: " ").map(String.init)
        if !matched {
            // "target Klingon" / "target Borg you control"
            guard words.count == 1, let o = original.first(where: { $0.lowercased() == words[0] }), o.first?.isUppercase == true else { return nil }
            f.kind = .creature; f.subtype = o; return f
        }
        for w in words {
            switch w {
            case "attacking": f.attacking = true
            case "blocking": f.blocking = true
            case "tapped": f.tapped = true
            case "untapped": f.untapped = true
            case "nontoken": f.nontoken = true
            case "nonartifact": f.nonartifact = true
            case "other", "another": f.other = true
            case "attacking or blocking": f.attacking = true
            default:
                if let o = original.first(where: { $0.lowercased() == w }), o.first?.isUppercase == true, f.kind == .creature { f.subtype = o } else { return nil }
            }
        }
        return f
    }
}
