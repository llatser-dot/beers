import SwiftUI

/// Quiet dark materials + one accent. Craft over chrome (Emil / Apple design).
enum LlatserTheme {
    static let accent = Color(red: 0.45, green: 0.78, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.40)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.32)
    static let ink = Color(red: 0.06, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.13)
    static let panelRaised = Color(red: 0.14, green: 0.15, blue: 0.16)
    static let hairline = Color.white.opacity(0.08)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.38)

    static var windowBackground: some View {
        Color(red: 0.06, green: 0.065, blue: 0.07)
    }

    static var primarySurface: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(panelRaised)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
    }

    static func panelBackground(cornerRadius: CGFloat = 14) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(panel)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(hairline, lineWidth: 1)
            )
    }
}

struct SectionLabel: View {
    let title: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LlatserTheme.accent)
            }
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LlatserTheme.textSecondary)
        }
    }
}

/// Back-compat alias used across settings / status bar.
typealias JarvisSectionLabel = SectionLabel

struct StatusBadge: View {
    let status: AppState.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
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

    private var color: Color {
        switch status {
        case .loading, .transcribing, .ready: return LlatserTheme.accent
        case .recording: return LlatserTheme.danger
        case .error: return LlatserTheme.warn
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

extension View {
    func llatserPanel(minHeight: CGFloat? = nil, cornerRadius: CGFloat = 14) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .background(LlatserTheme.panelBackground(cornerRadius: cornerRadius))
    }

    func jarvisField() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(LlatserTheme.hairline, lineWidth: 1)
            )
    }
}
