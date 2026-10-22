import SwiftUI

/// The LCARS look: black screens, rounded bars in orange, peach, lavender and blue, text at the
/// ends of bars, everything in condensed capitals.
enum LCARS {
    static let orange = Color(hex: 0xFF9900)
    static let peach = Color(hex: 0xFFCC99)
    static let butterscotch = Color(hex: 0xFF9966)
    static let lavender = Color(hex: 0xCC99CC)
    static let violet = Color(hex: 0x9966CC)
    static let blue = Color(hex: 0x9999FF)
    static let skyBlue = Color(hex: 0x6688CC)
    static let ice = Color(hex: 0x99CCFF)
    static let gold = Color(hex: 0xFFCC66)
    static let red = Color(hex: 0xCC6666)
    static let alert = Color(hex: 0xFF3333)
    static let tan = Color(hex: 0xCC9966)
    static let green = Color(hex: 0x66CC99)
    static let gray = Color(hex: 0x666688)
    static let black = Color.black
    static let panel = Color(hex: 0x111118)

    static let palette: [Color] = [orange, peach, lavender, blue, butterscotch, gold, skyBlue, violet]

    /// Mana colors mapped to the panel palette.
    static func color(forMana symbol: String) -> Color {
        switch symbol {
        case "W": return peach
        case "U": return blue
        case "B": return violet
        case "R": return butterscotch
        case "G": return green
        default: return gray
        }
    }

    static func font(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .default).width(.condensed)
    }
    static let title = font(34)
    static let heading = font(22)
    static let body = font(17, weight: .semibold)
    static let label = font(13)
    static let small = font(11)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// The classic LCARS elbow: a bar along the top that turns down the left side.
struct LCARSElbow: Shape {
    var barHeight: CGFloat = 36
    var columnWidth: CGFloat = 90
    var outerRadius: CGFloat = 40
    var innerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.move(to: CGPoint(x: outerRadius, y: 0))
        p.addLine(to: CGPoint(x: w, y: 0))
        p.addLine(to: CGPoint(x: w, y: barHeight))
        p.addLine(to: CGPoint(x: columnWidth + innerRadius, y: barHeight))
        p.addArc(center: CGPoint(x: columnWidth + innerRadius, y: barHeight + innerRadius), radius: innerRadius,
                 startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: true)
        p.addLine(to: CGPoint(x: columnWidth, y: h))
        p.addLine(to: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: outerRadius))
        p.addArc(center: CGPoint(x: outerRadius, y: outerRadius), radius: outerRadius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// A rounded LCARS bar with a label at one end.
struct LCARSBar: View {
    var text: String = ""
    var color: Color = LCARS.orange
    var height: CGFloat = 28
    var alignment: Alignment = .trailing

    var body: some View {
        ZStack(alignment: alignment) {
            Capsule().fill(color)
            if !text.isEmpty {
                Text(text.uppercased()).font(LCARS.label).foregroundStyle(.black).padding(.horizontal, 14).lineLimit(1)
            }
        }
        .frame(height: height)
    }
}

/// A header line: a bar, a text label in the gap, a bar.
struct LCARSHeader: View {
    var title: String
    var color: Color = LCARS.orange
    var body: some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 40, height: 14)
            Text(title.uppercased()).font(LCARS.heading).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            Rectangle().fill(color).frame(height: 14).clipShape(Capsule())
        }
    }
}

/// LCARS pill buttons: solid color, black condensed text, press feedback.
struct LCARSButtonStyle: ButtonStyle {
    var color: Color = LCARS.orange
    var height: CGFloat = 44
    var fill = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LCARS.body)
            .textCase(.uppercase)
            .foregroundStyle(fill ? .black : color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(fill ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.18)))
            .overlay(Capsule().strokeBorder(color, lineWidth: fill ? 0 : 2))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func lcarsButton(_ color: Color = LCARS.orange, height: CGFloat = 44, fill: Bool = true) -> some View {
        buttonStyle(LCARSButtonStyle(color: color, height: height, fill: fill))
    }
}

/// The screen frame: elbow in the corner, a column of colored blocks down the left, content on the right.
struct LCARSFrame<Content: View>: View {
    var title: String
    var subtitle: String = ""
    var color: Color = LCARS.orange
    var blocks: [Color] = [LCARS.lavender, LCARS.blue, LCARS.peach, LCARS.butterscotch, LCARS.skyBlue]
    @ViewBuilder var content: () -> Content

    private let column: CGFloat = 64
    private let blockHeights: [CGFloat] = [70, 40, 110, 55, 90]

    var body: some View {
        ZStack(alignment: .topLeading) {
            LCARS.black.ignoresSafeArea()
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    LCARSElbow(barHeight: 30, columnWidth: column, outerRadius: 44, innerRadius: 14)
                        .fill(color)
                        .frame(width: geo.size.width, height: 130)
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer().frame(height: 134)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { i, c in
                            RoundedRectangle(cornerRadius: 4).fill(c).frame(width: column, height: i == blocks.count - 1 ? nil : blockHeights[i % blockHeights.count])
                        }
                        UnevenRoundedRectangle(bottomLeadingRadius: 44).fill(color).frame(width: column, height: 60)
                    }
                    .frame(maxHeight: .infinity)
                    HStack(spacing: 8) {
                        Spacer()
                        Text(title.uppercased()).font(LCARS.title).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
                            .padding(.trailing, 6)
                    }
                    .frame(width: geo.size.width, height: 30, alignment: .trailing)
                    .background(alignment: .trailing) { LCARS.black.frame(width: 0) }
                    .padding(.top, 32)
                    content()
                        .padding(.leading, column + 10)
                        .padding(.top, 72)
                        .padding(.trailing, 10)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                }
            }
            .padding(.leading, 8)
        }
        .overlay(alignment: .topLeading) {
            if !subtitle.isEmpty {
                Text(subtitle.uppercased()).font(LCARS.small).foregroundStyle(.black).padding(.leading, 60).padding(.top, 8)
            }
        }
    }
}

/// A black panel outlined by a colored bar on the left, for lists and content blocks.
struct LCARSPanel<Content: View>: View {
    var color: Color = LCARS.lavender
    var title: String = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !title.isEmpty { LCARSHeader(title: title, color: color) }
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(color).frame(width: 6)
                content()
            }
        }
    }
}

/// A line of small numeric readouts (life, cards, mana) that blink when they change.
struct LCARSReadout: View {
    var label: String
    var value: String
    var color: Color = LCARS.peach
    var body: some View {
        VStack(spacing: 0) {
            Text(value).font(LCARS.font(26)).foregroundStyle(color).contentTransition(.numericText())
            Text(label.uppercased()).font(LCARS.small).foregroundStyle(LCARS.gray)
        }
        .frame(minWidth: 52)
    }
}

/// A sweeping scan line, for "working" states.
struct ScanLine: View {
    @State private var phase: CGFloat = 0
    var color: Color = LCARS.blue
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(color.opacity(0.9)).frame(width: 60, height: 4)
                .offset(x: phase * (geo.size.width - 60))
                .onAppear { withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { phase = 1 } }
        }
        .frame(height: 4)
    }
}

/// A starfield for the menu background.
struct Starfield: View {
    var count = 90
    @State private var seed = 7
    var body: some View {
        Canvas { ctx, size in
            var rng = StarRNG(seed: UInt64(seed))
            for _ in 0..<count {
                let x = CGFloat(rng.next01()) * size.width, y = CGFloat(rng.next01()) * size.height
                let r = CGFloat(rng.next01()) * 1.4 + 0.3
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.35 + 0.5 * rng.next01())))
            }
        }
        .allowsHitTesting(false)
    }
    struct StarRNG {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next01() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) % 10_000) / 10_000
        }
    }
}
