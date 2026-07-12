import SwiftUI

enum PourHUDLayout {
    static let canvasSize = CGSize(width: 640, height: 130)
    static let bottomMargin: CGFloat = 26
}

/// Where the pill pours. Notch mode tucks it into the menu bar strip so
/// it slides out either side of the MacBook notch.
enum HUDPosition: String, CaseIterable, Identifiable {
    case notch
    case topRight
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch: return "At the notch"
        case .topRight: return "Top right"
        case .bottom: return "Bottom"
        }
    }

    static var current: HUDPosition {
        HUDPosition(rawValue: UserDefaults.standard.string(forKey: "hudPosition") ?? "") ?? .notch
    }
}

@MainActor
final class OverlayPresentationState: ObservableObject {
    @Published var mode: OverlayMode = .pouring
    @Published var isVisible = false
    @Published var pourStart = Date()
    @Published var position: HUDPosition = .notch
    /// Physical notch metrics of the target screen (set by the controller).
    @Published var notchWidth: CGFloat = 190
    @Published var notchHeight: CGFloat = 38
}

/// The pill. Ink capsule in a lager+ink double ring, B badge, live
/// waveform, timer. Serve flips the ring hops-green and does one hop.
struct PourHUDView: View {
    @ObservedObject var presentation: OverlayPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hop = false

    private var anchor: Alignment {
        switch presentation.position {
        case .notch: return .top
        case .topRight: return .topTrailing
        case .bottom: return .bottom
        }
    }

    /// Top placements slide in from above (out of the notch / screen edge);
    /// bottom slides up like a coaster.
    private var hiddenOffset: CGFloat {
        presentation.position == .bottom ? 110 : -110
    }

    private var hopOffset: CGFloat {
        presentation.position == .bottom ? -16 : 14
    }

    private var pillPadding: EdgeInsets {
        switch presentation.position {
        case .notch: return EdgeInsets(top: 2, leading: 0, bottom: 0, trailing: 0)
        case .topRight: return EdgeInsets(top: 10, leading: 0, bottom: 0, trailing: 22)
        case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0)
        }
    }

    var body: some View {
        Group {
            if presentation.position == .notch {
                NotchIslandView(presentation: presentation)
            } else {
                pillLayout
            }
        }
        .environment(\.colorScheme, .light)
    }

    private var pillLayout: some View {
        ZStack(alignment: anchor) {
            Color.clear
            pill
                .padding(pillPadding)
                .offset(y: presentation.isVisible ? (hop ? hopOffset : 0) : hiddenOffset)
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
    }

    private var isServed: Bool {
        if case .served = presentation.mode { return true }
        return false
    }

    private var isOrder: Bool {
        switch presentation.mode {
        case .takingOrder, .workingOrder: return true
        default: return false
        }
    }

    private var ringColor: Color {
        if isServed { return Beers.hops }
        if case .notice = presentation.mode { return Beers.stout }
        return Beers.lager
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
            case .pouring, .takingOrder:
                LiveWaveform(active: !reduceMotion)
                    .frame(width: 96, height: 30)
                timerChip
            case .settling, .workingOrder:
                FoamDots(active: !reduceMotion)
                    .frame(width: 44, height: 30)
            case .served:
                Text("🍻").font(.system(size: 22))
            case .notice:
                Text("🫗").font(.system(size: 20))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 22)
        .padding(.vertical, 11)
        .background(Beers.ink, in: Capsule())
        .background(Capsule().fill(ringColor).padding(-4))
        .background(Capsule().fill(Beers.ink).padding(-6.5))
        .shadow(color: Beers.ink.opacity(0.35), radius: 16, y: 10)
        .animation(.easeOut(duration: 0.18), value: presentation.mode)
    }

    private var badge: some View {
        BeersAppIcon(size: 44)
            .frame(width: 48, height: 48)
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
        case .takingOrder: return "Taking your order…"
        case .workingOrder: return "Working the order…"
        case .notice: return "No pour"
        }
    }

    private var sublabel: String {
        switch presentation.mode {
        case .pouring: return "Release to serve"
        case .settling: return "Half a second, tops"
        case .served(let words): return words == 1 ? "1 word" : "\(words) words"
        case .takingOrder: return "Say the change you want"
        case .workingOrder: return "The kitchen's on it"
        case .notice(let message): return message
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

// MARK: - Notch island

/// Dynamic-island treatment: a true-black shape that reads as part of the
/// physical notch, growing wings out of either side while listening.
/// Deliberately subtle — tiny badge left, waveform + timer right.
private struct NotchIslandView: View {
    @ObservedObject var presentation: OverlayPresentationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var wings: (left: CGFloat, right: CGFloat) {
        switch presentation.mode {
        case .pouring, .takingOrder: return (44, 118)
        case .settling, .workingOrder: return (44, 64)
        case .served: return (44, 96)
        case .notice: return (44, 240)
        }
    }

    private var islandHeight: CGFloat { presentation.notchHeight + 8 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear

            HStack(spacing: 0) {
                leftWing
                    .frame(width: presentation.isVisible ? wings.left : 0)
                    .clipped()
                Color.clear
                    .frame(width: presentation.notchWidth)
                rightWing
                    .frame(width: presentation.isVisible ? wings.right : 0)
                    .clipped()
            }
            .frame(height: islandHeight)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(bottomLeading: 13, bottomTrailing: 13),
                    style: .continuous
                )
                .fill(.black)
                .shadow(color: .black.opacity(presentation.isVisible ? 0.35 : 0), radius: 9, y: 5)
            )
            .opacity(presentation.isVisible ? 1 : 0)
            .animation(
                reduceMotion ? .easeOut(duration: 0.15) : Beers.springTight,
                value: presentation.isVisible
            )
            .animation(reduceMotion ? nil : Beers.springTight, value: presentation.mode)
        }
    }

    private var leftWing: some View {
        HStack {
            Spacer(minLength: 0)
            BeersAppIcon(size: 19)
            Spacer(minLength: 6)
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 6)
            switch presentation.mode {
            case .pouring, .takingOrder:
                IslandWaveform(active: !reduceMotion)
                    .frame(width: 52, height: 16)
                IslandTimer(start: presentation.pourStart)
            case .settling, .workingOrder:
                IslandFoam(active: !reduceMotion)
                    .frame(width: 34, height: 16)
            case .served(let words):
                Text("🍻")
                    .font(.system(size: 13))
                Text("\(words)")
                    .font(Beers.ui(12, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Beers.hops)
            case .notice(let message):
                Text(message)
                    .font(Beers.ui(10.5, .semibold))
                    .foregroundStyle(Beers.lager)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 10)
        }
    }
}

private struct IslandTimer: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(Beers.ui(11, .bold))
                .monospacedDigit()
                .foregroundStyle(Beers.cream)
        }
    }
}

/// Slimmer lager bars for the island's right wing.
private struct IslandWaveform: View {
    let active: Bool
    private let barCount = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 30.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(LiveMicLevel.shared.level)

            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(Beers.lager)
                        .frame(width: 3, height: active ? height(for: index, time: time, level: level) : 4)
                }
            }
        }
    }

    private func height(for index: Int, time: TimeInterval, level: CGFloat) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let envelope = 1.0 - abs(Double(index) - center) / center * 0.5
        let jitter = (sin(time * 9.2 + Double(index) * 1.7) + 1) / 2
        let energy = max(0.08, level)
        return CGFloat(3.5 + envelope * energy * (5 + jitter * 9))
    }
}

private struct IslandFoam: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1.0 / 24.0 : 1.0, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Beers.lager)
                        .frame(width: 5, height: 5)
                        .offset(y: active ? sin(time * 6.2 - Double(index) * 0.7) * 3 : 0)
                }
            }
        }
    }
}
