import SwiftUI

enum ListeningOverlayLayout {
    static let canvasSize = CGSize(width: 480, height: 88)
    static let pillSize = CGSize(width: 168, height: 40)
}

@MainActor
final class OverlayPresentationState: ObservableObject {
    @Published var mode: OverlayMode = .listening
    @Published var isVisible = false
    @Published var menuBarHeight: CGFloat = 32
}

struct ListeningOverlayView: View {
    @ObservedObject var presentation: OverlayPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Occasional UI: ease-out, under 300ms. Never scale(0) — start at 0.95.
    private var animation: Animation? {
        if reduceMotion {
            return .easeOut(duration: 0.12)
        }
        // Critically damped spring (Apple-style): snappy, no bounce.
        return .spring(response: 0.28, dampingFraction: 1.0)
    }

    var body: some View {
        GeometryReader { proxy in
            let topInset = min(proxy.size.height, max(24, presentation.menuBarHeight))
            let y = topInset + 8 + ListeningOverlayLayout.pillSize.height / 2

            ZStack {
                FlowPill(
                    mode: presentation.mode,
                    isVisible: presentation.isVisible,
                    reduceMotion: reduceMotion
                )
                .frame(
                    width: ListeningOverlayLayout.pillSize.width,
                    height: ListeningOverlayLayout.pillSize.height
                )
                .scaleEffect(presentation.isVisible ? 1 : 0.95, anchor: .center)
                .opacity(presentation.isVisible ? 1 : 0)
                .position(x: proxy.size.width / 2, y: y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .animation(animation, value: presentation.isVisible)
            .animation(.easeOut(duration: 0.18), value: presentation.mode)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct FlowPill: View {
    let mode: OverlayMode
    let isVisible: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)

            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.45))

            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)

            HStack(spacing: 10) {
                Circle()
                    .fill(mode == .listening ? LlatserTheme.accent : LlatserTheme.accent.opacity(0.7))
                    .frame(width: 7, height: 7)

                Group {
                    switch mode {
                    case .listening:
                        QuietWaveform(active: isVisible && !reduceMotion)
                            .frame(width: 96, height: 18)
                    case .processing:
                        QuietDots(active: isVisible && !reduceMotion)
                            .frame(width: 96, height: 18)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .shadow(color: .black.opacity(isVisible ? 0.35 : 0), radius: 12, y: 6)
    }
}

/// Soft waveform — state feedback only, not decoration overload.
private struct QuietWaveform: View {
    let active: Bool
    private let barCount = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 24.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2.4) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: 2.2, height: active ? height(for: index, time: time) : 3)
                }
            }
            .frame(height: 18)
        }
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center) / max(center, 1)
        let envelope = 1.0 - distance * 0.55
        let phase = Double(index) * 0.48
        let wave = (sin(time * 7.6 + phase) + 1.0) / 2.0
        return CGFloat(3.0 + envelope * (3.5 + wave * 9.0))
    }
}

private struct QuietDots: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 20.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.white.opacity(active ? opacity(for: index, time: time) : 0.35))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }

    private func opacity(for index: Int, time: TimeInterval) -> Double {
        let phase = time * 4.2 - Double(index) * 0.55
        return 0.28 + 0.72 * ((sin(phase) + 1) / 2)
    }
}
