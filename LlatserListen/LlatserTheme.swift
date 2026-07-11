import AppKit
import SwiftUI

/// Monochrome semantic tokens. Light values follow the product palette;
/// dark values invert the same hierarchy for the active macOS appearance.
enum LlatserTheme {
    static let brandInk = Color(hex: 0x101A38)
    static let brandCream = Color(hex: 0xFFF6DE)
    static let deepInk = adaptive(light: 0x101A38, dark: 0xFFF6DE)
    static let oxblood = Color(hex: 0x9E1520)
    static let tangerine = Color(hex: 0xF4511E)
    static let butter = Color(hex: 0xFFC247)
    static let mint = adaptive(light: 0x78B9A5, dark: 0x8ED8BF)
    static let cream = adaptive(light: 0xFFF6DE, dark: 0x101A38)
    static let subtle = adaptive(light: 0x56617A, dark: 0xB8C0CF)
    static let defaultText = adaptive(light: 0x2A334D, dark: 0xE2E6ED)
    static let strong = deepInk
    static let selected = adaptive(light: 0xFFF0D0, dark: 0x2A334D)
    static let border = adaptive(light: 0xE5D7B6, dark: 0x56617A)

    static let background = cream
    static let panel = adaptive(light: 0xFFFAEC, dark: 0x172340)
    static let panelRaised = adaptive(light: 0xFFF3D4, dark: 0x0E142A)
    static let accent = oxblood
    static let danger = oxblood
    static let warn = tangerine
    static let ink = cream
    static let hairline = border
    static let textPrimary = strong
    static let textSecondary = defaultText
    static let textTertiary = subtle

    static var windowBackground: some View { background }

    static var primarySurface: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(panelRaised)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(border, lineWidth: 1)
            )
    }

    static func panelBackground(cornerRadius: CGFloat = 12) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(panel)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 1.2)
            )
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return nsColor(hex: match == .darkAqua ? dark : light)
        })
    }

    private static func nsColor(hex: UInt32) -> NSColor {
        NSColor(
            calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

enum LlatserType {
    static let caption: CGFloat = 12
    static let base: CGFloat = 13
    static let control: CGFloat = 14
    static let section: CGFloat = 16
    static let title: CGFloat = 18
    static let hero: CGFloat = 24
}

struct SectionLabel: View {
    let title: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: LlatserType.caption, weight: .medium))
            }
            Text(title)
                .font(.system(size: LlatserType.caption, weight: .medium))
        }
        .foregroundStyle(LlatserTheme.textSecondary)
    }
}

typealias JarvisSectionLabel = SectionLabel

struct StatusBadge: View {
    let status: AppState.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(LlatserTheme.strong).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: LlatserType.caption, weight: .medium))
                .foregroundStyle(LlatserTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(LlatserTheme.selected, in: Capsule())
        .accessibilityLabel("Status: \(title)")
    }

    private var title: String {
        switch status {
        case .loading: return "Preparing"
        case .ready: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Processing"
        case .error: return "Attention"
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func llatserPanel(minHeight: CGFloat? = nil, cornerRadius: CGFloat = 12) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(LlatserTheme.panelBackground(cornerRadius: cornerRadius))
    }

    func jarvisField() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(LlatserTheme.selected, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(LlatserTheme.border, lineWidth: 1)
            )
    }
}
