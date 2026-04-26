import SwiftUI

enum ListeningOverlayLayout {
    static let canvasSize = CGSize(width: 1000, height: 72)
    static let notchWidth: CGFloat = 220
    static let sideGap: CGFloat = 8
    static let dotSize = CGSize(width: 32, height: 24)
    static let waveformSize = CGSize(width: 104, height: 24)
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

    private var animation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.78)
    }

    var body: some View {
        GeometryReader { proxy in
            let centerX = proxy.size.width / 2
            let topBandHeight = min(proxy.size.height, max(24, presentation.menuBarHeight))
            let dotVisibleX = centerX - ListeningOverlayLayout.notchWidth / 2 - ListeningOverlayLayout.sideGap - ListeningOverlayLayout.dotSize.width / 2
            let dotHiddenX = centerX - ListeningOverlayLayout.notchWidth / 2 + ListeningOverlayLayout.dotSize.width / 2
            let waveformVisibleX = centerX + ListeningOverlayLayout.notchWidth / 2 + ListeningOverlayLayout.sideGap + ListeningOverlayLayout.waveformSize.width / 2
            let waveformHiddenX = centerX + ListeningOverlayLayout.notchWidth / 2 - ListeningOverlayLayout.waveformSize.width / 2
            let y = max(3, floor((topBandHeight - ListeningOverlayLayout.dotSize.height) / 2)) + ListeningOverlayLayout.dotSize.height / 2

            ZStack {
                dotIndicator
                    .frame(width: ListeningOverlayLayout.dotSize.width, height: ListeningOverlayLayout.dotSize.height)
                    .position(x: presentation.isVisible ? dotVisibleX : dotHiddenX, y: y)
                    .opacity(presentation.isVisible ? 1 : 0)

                waveformIndicator
                    .frame(width: ListeningOverlayLayout.waveformSize.width, height: ListeningOverlayLayout.waveformSize.height)
                    .position(x: presentation.isVisible ? waveformVisibleX : waveformHiddenX, y: y)
                    .opacity(presentation.isVisible ? 1 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .animation(animation, value: presentation.isVisible)
            .animation(animation, value: presentation.mode)
        }
        .environment(\.colorScheme, .dark)
    }

    private var dotIndicator: some View {
        Capsule()
            .fill(.black.opacity(0.82))
            .overlay {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 20.0, paused: reduceMotion || !presentation.isVisible)) { timeline in
                    let pulse = reduceMotion ? 1 : 0.78 + 0.22 * ((sin(timeline.date.timeIntervalSinceReferenceDate * 5.8) + 1) / 2)

                    Circle()
                        .fill(Color(red: 1.0, green: 0.22, blue: 0.18))
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulse)
                        .shadow(color: Color(red: 1.0, green: 0.22, blue: 0.18).opacity(0.45), radius: 5)
                }
            }
    }

    @ViewBuilder
    private var waveformIndicator: some View {
        Capsule()
            .fill(.black.opacity(0.82))
            .overlay {
                switch presentation.mode {
                case .listening:
                    CompactWaveform(active: presentation.isVisible && !reduceMotion)
                        .frame(width: 72, height: 17)
                case .processing:
                    ProcessingDots(active: presentation.isVisible && !reduceMotion)
                        .frame(width: 58, height: 17)
                }
            }
    }
}

private struct CompactWaveform: View {
    let active: Bool
    private let barCount = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 20.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(alignment: .center, spacing: 2.2) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.2)
                        .fill(LlatserTheme.accent.opacity(0.95))
                        .frame(width: 2.5, height: active ? height(for: index, time: time) : 4)
                }
            }
            .frame(height: 17)
        }
    }

    private func height(for index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(barCount - 1) / 2.0
        let distance = abs(Double(index) - center) / center
        let peak = 1.0 - distance * 0.56
        let phase = Double(index) * 0.55
        let wave = (sin(time * 7.2 + phase) + 1.0) / 2.0
        return CGFloat(3.0 + peak * (4.0 + wave * 8.5))
    }
}

private struct ProcessingDots: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 20.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(LlatserTheme.accent.opacity(0.95))
                        .frame(width: 5, height: 5)
                        .scaleEffect(active ? scale(for: index, time: time) : 0.8)
                }
            }
        }
    }

    private func scale(for index: Int, time: TimeInterval) -> CGFloat {
        let phase = time * 5.0 - Double(index) * 0.52
        return CGFloat(0.68 + 0.32 * ((sin(phase) + 1) / 2))
    }
}
