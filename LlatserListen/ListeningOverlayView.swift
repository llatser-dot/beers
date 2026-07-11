import SwiftUI

enum PourHUDLayout {
    static let canvasSize = CGSize(width: 520, height: 130)
    static let bottomMargin: CGFloat = 26
}

@MainActor
final class OverlayPresentationState: ObservableObject {
    @Published var mode: OverlayMode = .pouring
    @Published var isVisible = false
    @Published var pourStart = Date()
}

/// The pill. Ink capsule in a lager+ink double ring, B badge, live
/// waveform, timer. Serve flips the ring hops-green and does one hop.
struct PourHUDView: View {
    @ObservedObject var presentation: OverlayPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    var body: some View {
        GeometryReader { proxy in
            pill
                .position(x: proxy.size.width / 2, y: proxy.size.height - 44)
                .offset(y: presentation.isVisible ? (hop ? -16 : 0) : 110)
                .opacity(presentation.isVisible ? 1 : 0)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.15) : Beers.springSlow,
                    value: presentation.isVisible
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.42),
                    value: hop
                )
        }
        .onChange(of: presentation.mode) { _, newMode in
            if case .served = newMode, !reduceMotion {
                hop = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { hop = false }
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var isServed: Bool {
        if case .served = presentation.mode { return true }
        return false
    }

    private var pill: some View {
        HStack(spacing: 14) {
            badge

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Beers.ui(16, .bold))
                    .foregroundStyle(Beers.cream)
                Text(sublabel)
                    .font(Beers.ui(10, .semibold))
                    .tracking(2.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Beers.hops)
            }

            switch presentation.mode {
            case .pouring:
                LiveWaveform(active: !reduceMotion)
                    .frame(width: 96, height: 30)
                timerChip
            case .settling:
                FoamDots(active: !reduceMotion)
                    .frame(width: 44, height: 30)
            case .served:
                Text("🍻").font(.system(size: 22))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 22)
        .padding(.vertical, 11)
        .background(Beers.ink, in: Capsule())
        .background(Capsule().fill(isServed ? Beers.hops : Beers.lager).padding(-4))
        .background(Capsule().fill(Beers.ink).padding(-6.5))
        .shadow(color: Beers.ink.opacity(0.35), radius: 16, y: 10)
        .animation(.easeOut(duration: 0.18), value: presentation.mode)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(Beers.cream)
            BeersMark(size: 32)
        }
        .frame(width: 48, height: 48)
        .overlay(Circle().strokeBorder(isServed ? Beers.hopsDeep : Beers.amber, lineWidth: 3))
    }

    private var timerChip: some View {
        TimelineView(.periodic(from: presentation.pourStart, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(presentation.pourStart)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(Beers.ui(13, .bold))
                .monospacedDigit()
                .foregroundStyle(Beers.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Beers.cream, in: Capsule())
        }
    }

    private var label: String {
        switch presentation.mode {
        case .pouring: return "Pouring…"
        case .settling: return "Settling the foam…"
        case .served: return "Served!"
        }
    }

    private var sublabel: String {
        switch presentation.mode {
        case .pouring: return "Release to serve"
        case .settling: return "Half a second, tops"
        case .served(let words): return words == 1 ? "1 word" : "\(words) words"
        }
    }
}

/// 13 chunky lager bars driven by the real mic RMS.
private struct LiveWaveform: View {
    let active: Bool
    private let barCount = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 30.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(LiveMicLevel.shared.level)

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Beers.lager)
                        .frame(width: 4.5, height: active ? height(for: index, time: time, level: level) : 7)
                }
            }
        }
    }

    private func height(for index: Int, time: TimeInterval, level: CGFloat) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - distance * 0.5
        let jitter = (sin(time * 9.2 + Double(index) * 1.7) + 1) / 2
        let energy = max(0.06, level)
        return CGFloat(6 + envelope * energy * (10 + jitter * 18))
    }
}

/// Foam settling: three lager blobs bouncing while transcription runs.
private struct FoamDots: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 24.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Beers.lager)
                        .frame(width: 8, height: 8)
                        .offset(y: active ? sin(time * 6.2 - Double(index) * 0.7) * 5 : 0)
                }
            }
        }
    }
}
