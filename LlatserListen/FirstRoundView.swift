import SwiftUI

/// First Round: three steps, ninety seconds, and the last one pours
/// your first Beer before you ever see a settings screen.
struct FirstRoundView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("firstRoundDone") private var firstRoundDone = false
    @State private var step = 0
    @State private var celebrated = false

    private var allPermissionsGranted: Bool {
        appState.microphoneGranted && appState.inputMonitoringGranted && appState.accessibilityGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            stepBadge

            Group {
                switch step {
                case 0: permissionsStep
                case 1: pourKeyStep
                default: firstPourStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))

            footerControls
        }
        .padding(26)
        .frame(width: 380, height: 540)
        .background(Beers.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Beers.lager, lineWidth: step == 2 ? 5 : 0)
        )
        .environment(\.colorScheme, .light)
        .animation(Beers.spring, value: step)
        .onChange(of: appState.lastTranscription) { _, newValue in
            if step == 2, !newValue.isEmpty {
                celebrated = true
            }
        }
    }

    private var stepBadge: some View {
        HStack {
            Text("\(step + 1) of 3")
                .font(Beers.display(12))
                .foregroundStyle(Beers.paper)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Beers.ink, in: Capsule())
                .rotationEffect(.degrees(-6))
            Spacer()
            BeersMark(size: 30)
        }
        .padding(.bottom, 8)
    }

    // MARK: Step 1 — permissions

    private var permissionsStep: some View {
        VStack(spacing: 14) {
            Text("👂").font(.system(size: 52)).rotationEffect(.degrees(-5))

            Text("Can we borrow your ears?")
                .font(Beers.display(19))
                .foregroundStyle(Beers.stout)
                .multilineTextAlignment(.center)

            Text("Beers needs three grants — that’s how your words land wherever the cursor is.")
                .font(Beers.ui(13, .medium))
                .foregroundStyle(Beers.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            VStack(spacing: 9) {
                grantRow("Microphone", granted: appState.microphoneGranted, action: appState.requestMicrophonePermission)
                grantRow("Input Monitoring", granted: appState.inputMonitoringGranted, action: appState.requestInputMonitoringPermission)
                grantRow("Accessibility", granted: appState.accessibilityGranted, action: appState.requestAccessibilityPermission)
            }
            .padding(.top, 6)

            if !allPermissionsGranted {
                Text("Granting Input Monitoring or Accessibility relaunches Beers — that’s normal, it’ll come straight back.")
                    .font(Beers.ui(11, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.top, 18)
    }

    private func grantRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(Beers.ui(14, .semibold))
                .foregroundStyle(Beers.ink)
            Spacer()
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: granted ? "checkmark" : "hand.tap.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(granted ? "On tap" : "Grant")
                        .font(Beers.ui(12, .bold))
                }
                .foregroundStyle(Beers.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(granted ? Beers.hops : Beers.lager, in: Capsule())
                .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .disabled(granted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Beers.cream, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Beers.ink, lineWidth: 2)
        )
    }

    // MARK: Step 2 — pour key

    private var pourKeyStep: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                BeersKeycap(label: appState.hotkeyChoice.keycapLabel, size: 24)
                Text("💬").font(.system(size: 34)).rotationEffect(.degrees(6))
            }
            .padding(.top, 10)

            Text("Pick your pour key")
                .font(Beers.display(19))
                .foregroundStyle(Beers.stout)

            Text("Hold it, talk, let go. Fn is lonely and deserves a job — but any of these will pull a pint.")
                .font(Beers.ui(13, .medium))
                .foregroundStyle(Beers.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            let columns = [GridItem(.flexible()), GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(HotkeyOption.allCases) { option in
                    keyChoice(option)
                }
            }
            .padding(.top, 4)
        }
    }

    private func keyChoice(_ option: HotkeyOption) -> some View {
        let selected = appState.hotkeyChoice == option
        return Button {
            withAnimation(Beers.spring) { appState.hotkeyChoice = option }
        } label: {
            Text(option.displayName)
                .font(Beers.ui(12, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? Beers.paper : Beers.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    selected ? Beers.amber : Beers.cream,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Beers.ink, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 3 — first pour

    private var firstPourStep: some View {
        VStack(spacing: 14) {
            PourWaveHint().padding(.top, 8)

            Text("Pour your first Beer")
                .font(Beers.display(19))
                .foregroundStyle(Beers.stout)

            Text("Hold \(appState.hotkeyChoice.shortName) and say anything at all — “I am talking to my computer and it is writing this down” works great.")
                .font(Beers.ui(13, .medium))
                .foregroundStyle(Beers.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 4) {
                if appState.lastTranscription.isEmpty {
                    Text("…")
                        .font(Beers.ui(13, .semibold))
                        .foregroundStyle(Beers.ink.opacity(0.4))
                } else {
                    Text(appState.lastTranscription)
                        .font(Beers.ui(13, .semibold))
                        .foregroundStyle(Beers.ink)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .padding(12)
            .background(Beers.hops.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Beers.hopsDeep, style: StrokeStyle(lineWidth: 2.5, dash: [6, 5]))
            )

            if celebrated {
                Text("🍻 That’s a pour! It’s pinned in the Taproom.")
                    .font(Beers.ui(13, .bold))
                    .foregroundStyle(Beers.hopsDeep)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: Footer

    private var footerControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Beers.amber : Beers.cream2)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Beers.ink, lineWidth: 2))
                }
            }

            HStack(spacing: 10) {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(BeersButtonStyle(kind: .ghost, small: true))
                }

                switch step {
                case 0:
                    Button(allPermissionsGranted ? "All poured — next →" : "Next anyway →") { step = 1 }
                        .buttonStyle(BeersButtonStyle(kind: allPermissionsGranted ? .amber : .lager))
                case 1:
                    Button("\(appState.hotkeyChoice.keycapLabel) it is →") { step = 2 }
                        .buttonStyle(BeersButtonStyle(kind: .lager))
                default:
                    Button(celebrated ? "Cheers — open the Taproom 🍻" : "I’ll pour later") {
                        withAnimation(Beers.spring) { firstRoundDone = true }
                    }
                    .buttonStyle(BeersButtonStyle(kind: celebrated ? .amber : .ghost))
                }
            }
        }
        .padding(.top, 12)
    }
}

/// Static brand waveform used as the step-3 sticker.
private struct PourWaveHint: View {
    private let heights: [CGFloat] = [10, 20, 32, 14, 26, 36, 12, 24, 30, 11]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(Beers.amber)
                    .frame(width: 5, height: heights[index])
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Beers.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Beers.ink, lineWidth: 2.5)
        )
        .rotationEffect(.degrees(-2))
    }
}
