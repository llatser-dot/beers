import AppKit
import CoreText
import SwiftUI

/// The Beers design system. Six tokens, two faces, hard shadows, no grey.
/// Laws: no grey · no system controls · no blur/glass · everything overshoots.
enum Beers {
    // MARK: Tokens
    static let cream = Color(hex: 0xFDF4E0)
    static let cream2 = Color(hex: 0xF6EBD2)
    static let ink = Color(hex: 0x1B2142)
    static let inkSoft = Color(hex: 0x2A3158)
    static let stout = Color(hex: 0xA31D1D)
    static let amber = Color(hex: 0xF05E1C)
    static let lager = Color(hex: 0xF8AE21)
    static let hops = Color(hex: 0x9EC3AF)
    static let hopsDeep = Color(hex: 0x6FA98C)
    static let paper = Color(hex: 0xFFFDF6)

    static let inkNS = NSColor(red: 0x1B / 255, green: 0x21 / 255, blue: 0x42 / 255, alpha: 1)

    // MARK: Springs — everything overshoots
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.62)
    static let springSlow = Animation.spring(response: 0.5, dampingFraction: 0.62)
    static let springTight = Animation.spring(response: 0.22, dampingFraction: 0.55)

    // MARK: Type
    static func display(_ size: CGFloat) -> Font {
        BeersFonts.registerOnce()
        return .custom("RammettoOne-Regular", size: size)
    }

    static func ui(_ size: CGFloat, _ weight: UIWeight = .medium) -> Font {
        BeersFonts.registerOnce()
        return .custom(weight.postScriptName, size: size)
    }

    enum UIWeight {
        case regular, medium, semibold, bold
        var postScriptName: String {
            switch self {
            case .regular: return "Fredoka-Regular"
            case .medium: return "Fredoka-Medium"
            case .semibold: return "Fredoka-SemiBold"
            case .bold: return "Fredoka-Bold"
            }
        }
    }

    // MARK: Images
    static func brandImage(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "BrandAssets")
        else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: Sounds
    static func popCap() {
        guard UserDefaults.standard.object(forKey: "clinkOnServe") == nil
            || UserDefaults.standard.bool(forKey: "clinkOnServe") else { return }
        NSSound(named: "Pop")?.play()
    }

    static func clink() {
        guard UserDefaults.standard.object(forKey: "clinkOnServe") == nil
            || UserDefaults.standard.bool(forKey: "clinkOnServe") else { return }
        NSSound(named: "Glass")?.play()
    }
}

/// Runtime font registration; ATSApplicationFontsPath alone is unreliable
/// when xcodegen flattens resources.
enum BeersFonts {
    private static var registered = false

    static func registerOnce() {
        guard !registered else { return }
        registered = true
        let names = [
            "RammettoOne-Regular", "Fredoka-Regular", "Fredoka-Medium",
            "Fredoka-SemiBold", "Fredoka-Bold",
        ]
        for name in names {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else {
                llog("BeersFonts: missing \(name).ttf")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Brand marks

struct BeersMark: View {
    let size: CGFloat

    var body: some View {
        if let image = Beers.brandImage("brand-badge") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("Beers")
        } else {
            Text("B")
                .font(Beers.display(size * 0.8))
                .foregroundStyle(Beers.ink)
                .frame(width: size, height: size)
        }
    }
}

struct BeersMenuBadge: View {
    let size: CGFloat

    var body: some View {
        BeersMark(size: size)
    }
}

// MARK: - Shapes

/// Bottle-cap scallop for the underside of headers.
struct ScallopEdge: Shape {
    var scallopRadius: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - scallopRadius))
        let count = max(1, Int(rect.width / (scallopRadius * 2)))
        let step = rect.width / CGFloat(count)
        var x = rect.maxX
        while x > rect.minX + 0.5 {
            path.addArc(
                center: CGPoint(x: x - step / 2, y: rect.maxY - scallopRadius),
                radius: step / 2,
                startAngle: .degrees(0),
                endAngle: .degrees(180),
                clockwise: false
            )
            x -= step
        }
        path.closeSubpath()
        return path
    }
}

/// Scalloped seal for warnings and badges.
struct SealShape: Shape {
    var points: Int = 18
    var depth: CGFloat = 0.10

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * (1 - depth)
        var path = Path()
        let steps = points * 2
        for i in 0...steps {
            let angle = CGFloat(i) / CGFloat(steps) * .pi * 2 - .pi / 2
            let radius = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Control styles (law 2: no system controls)

/// Chunky pill button: ink outline, hard drop, press = sink.
struct BeersButtonStyle: ButtonStyle {
    enum Kind { case amber, lager, ghost, stoutGhost }
    var kind: Kind = .amber
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Beers.ui(small ? 13 : 15, .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, small ? 16 : 24)
            .padding(.vertical, small ? 7 : 11)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 2.5))
            .background(
                Capsule()
                    .fill(Beers.ink)
                    .offset(y: configuration.isPressed ? 1 : 4)
            )
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(Beers.springTight, value: configuration.isPressed)
    }

    private var background: Color {
        switch kind {
        case .amber: return Beers.amber
        case .lager: return Beers.lager
        case .ghost, .stoutGhost: return Beers.paper
        }
    }

    private var foreground: Color {
        switch kind {
        case .amber: return Beers.paper
        case .lager, .ghost: return Beers.ink
        case .stoutGhost: return Beers.stout
        }
    }
}

/// Hops track, lager knob, overshoot slide.
struct BeersToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 0)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? Beers.hops : Beers.cream2)
                        .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 2.5))
                        .frame(width: 52, height: 29)
                    Circle()
                        .fill(configuration.isOn ? Beers.lager : Beers.paper)
                        .overlay(Circle().strokeBorder(Beers.ink, lineWidth: 2.5))
                        .frame(width: 21, height: 21)
                        .padding(.horizontal, 4)
                }
                .animation(Beers.springTight, value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared components

/// Cream chip with ink border — the custom "select" / info chip.
struct BeersChip<Content: View>: View {
    var fill: Color = Beers.cream2
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(Beers.ui(13, .semibold))
            .foregroundStyle(Beers.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
    }
}

/// A dropdown that looks like a dropdown.
///
/// SwiftUI's `Menu` cannot be used here. With `.menuStyle(.borderlessButton)`
/// AppKit discards the custom label's fill, border and caret and draws the
/// bare text, so "Where the pill pours" rendered as the plain word "Top right"
/// with nothing to suggest it could be changed at all. It also drops a system
/// menu on screen, which the four laws forbid.
///
/// This is the whole control instead: a chip that presses like every other
/// Beers button, a caret that flips when open, and a paper sheet of options
/// with the current one badged in lager.
struct BeersDropdown<Option: Identifiable & Equatable>: View {
    let options: [Option]
    let title: (Option) -> String
    @Binding var selection: Option
    /// Rendered on the chip. Defaults to the selected option's title.
    var display: ((Option) -> String)? = nil

    @State private var open = false
    @State private var pressed = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 8) {
                Text((display ?? title)(selection))
                    .font(Beers.ui(13, .semibold))
                    .foregroundStyle(Beers.ink)
                Text("▾")
                    .font(Beers.ui(12, .bold))
                    .foregroundStyle(Beers.amber)
                    .rotationEffect(.degrees(open ? 180 : 0))
                    .animation(Beers.springTight, value: open)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Beers.cream2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
            // Hard shadow, same idiom as BeersButtonStyle.
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Beers.ink)
                    .offset(y: pressed ? 1 : 3)
            )
            .offset(y: pressed ? 2 : 0)
            .animation(Beers.springTight, value: pressed)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { _ in }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(options) { option in
                    BeersDropdownRow(
                        label: title(option),
                        selected: option == selection
                    ) {
                        selection = option
                        open = false
                    }
                    if option.id != options.last?.id {
                        Rectangle()
                            .fill(Beers.ink.opacity(0.12))
                            .frame(height: 1)
                            .padding(.horizontal, 10)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(minWidth: 190)
            .background(Beers.paper)
        }
    }
}

/// One option inside a `BeersDropdown`. Hover fills hops, selection badges lager.
private struct BeersDropdownRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(selected ? Beers.lager : .clear)
                    .overlay(Circle().strokeBorder(Beers.ink, lineWidth: selected ? 2 : 1.5))
                    .frame(width: 13, height: 13)
                Text(label)
                    .font(Beers.ui(13, selected ? .bold : .semibold))
                    .foregroundStyle(Beers.ink)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hovering ? Beers.hops.opacity(0.45) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Keycap for hotkeys.
struct BeersKeycap: View {
    let label: String
    var size: CGFloat = 13

    var body: some View {
        Text(label)
            .font(Beers.ui(size, .bold))
            .foregroundStyle(Beers.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Beers.paper, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Beers.ink)
                    .offset(y: 2.5)
            )
    }
}

/// A labelled crate: coloured Rammetto header + paper body + hard shadow.
struct BeersCrate<Content: View>: View {
    let title: String
    let emoji: String
    var headerColor: Color = Beers.lager
    var headerText: Color = Beers.ink
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(emoji).font(.system(size: 13))
                Text(title)
                    .font(Beers.display(13))
                    .foregroundStyle(headerText)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(headerColor)

            Rectangle().fill(Beers.ink).frame(height: 2.5)

            VStack(spacing: 0) { content }
                .background(Beers.paper)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Beers.ink, lineWidth: 2.5)
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Beers.ink.opacity(0.8))
                .offset(y: 3)
        )
    }
}

/// A settings row inside a crate.
struct BeersSettingRow<Trailing: View>: View {
    let label: String
    var hint: String? = nil
    var showDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(Beers.ui(14, .semibold))
                        .foregroundStyle(Beers.ink)
                    if let hint {
                        Text(hint)
                            .font(Beers.ui(11.5, .medium))
                            .foregroundStyle(Beers.ink.opacity(0.55))
                    }
                }
                Spacer(minLength: 10)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if showDivider {
                DashedDivider()
                    .padding(.horizontal, 12)
            }
        }
    }
}

struct DashedDivider: View {
    var body: some View {
        Line()
            .stroke(Beers.ink.opacity(0.16), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
            .frame(height: 2)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

/// Beer-cap stamp: coloured circle with the target app's initial.
struct CapStamp: View {
    let letter: String
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(color)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Beers.ink.opacity(0.22)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            Text(letter)
                .font(Beers.display(size * 0.38))
                .foregroundStyle(Beers.paper)
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Beers.ink, lineWidth: 2.5))
    }

    static func color(for appName: String) -> Color {
        let palette: [Color] = [Beers.amber, Beers.stout, Beers.hopsDeep, Beers.ink, Beers.lager]
        let index = abs(appName.hashValue) % palette.count
        return palette[index]
    }
}
