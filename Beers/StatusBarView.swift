import AppKit
import SwiftUI

/// The Bar Tap: the menu bar popover. One giant pour cap, nothing else
/// fighting for attention.
struct StatusBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updater = UpdateController.shared
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var inputDeviceName = AudioRecorder.currentInputDisplayName()

    var body: some View {
        VStack(spacing: 0) {
            header
            pourSection
            rows
        }
        .frame(width: 308)
        .background(Beers.paper)
        .environment(\.colorScheme, .light)
        .onAppear {
            appState.refreshPermissions()
            // The popover is rebuilt each time it opens, but a device can
            // change while it is on screen.
            inputDeviceName = AudioRecorder.currentInputDisplayName()
        }
        .onReceive(NotificationCenter.default.publisher(for: .beersInputDeviceChanged)) { _ in
            inputDeviceName = AudioRecorder.currentInputDisplayName()
        }
    }

    // MARK: Header — stout with a bottle-cap scallop cut into its bottom edge

    private var header: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                BeersMenuBadge(size: 32)
                Text("eers")
                    .font(Beers.display(21))
                    .foregroundStyle(Beers.paper)
            }

            HStack(spacing: 6) {
                StatusPulseDot(color: statusDotColor)
                Text(statusLine)
                    .font(Beers.ui(10, .semibold))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundStyle(Beers.lager)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.top, 15)
        .padding(.bottom, 18)
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
        .background(ScallopEdge(scallopRadius: 7).fill(Beers.stout))
        // Settings is also a row further down, but that row sits below the
        // fold of attention — the cap and the mic get looked at first. A gear
        // in the corner is where people reach for settings without reading.
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Beers.lager)
                    .padding(7)
                    .background(Beers.paper.opacity(0.14), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Brew Settings")
            .padding(.top, 11)
            .padding(.trailing, 12)
        }
    }

    private var statusLine: String {
        if case .loading = appState.status {
            return appState.loadingMessage.isEmpty ? "Warming the taps…" : appState.loadingMessage
        }
        if let error = appState.errorMessage { return error }
        switch appState.status {
        case .recording: return "Pouring…"
        case .transcribing: return "Settling the foam…"
        default: return "On tap — ready to pour"
        }
    }

    private var statusDotColor: Color {
        switch appState.status {
        case .ready: return Beers.hops
        case .recording: return Beers.amber
        case .transcribing, .loading: return Beers.lager
        case .error: return Beers.amber
        }
    }

    // MARK: Pour cap

    private var pourSection: some View {
        VStack(spacing: 11) {
            PourCapButton(
                isRecording: appState.status == .recording,
                isBusy: appState.status == .loading || appState.status == .transcribing,
                action: appState.manualRecordToggle
            )

            HStack(spacing: 5) {
                Text("Hold")
                BeersKeycap(label: appState.hotkeyChoice.keycapLabel)
                Text("anywhere")
                Text("— or click me")
                    .foregroundStyle(Beers.ink.opacity(0.55))
                    .font(Beers.ui(13, .medium))
            }
            .font(Beers.ui(14, .bold))
            .foregroundStyle(Beers.ink)
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 9) {
            if case .loading = appState.status {
                loadingRow
            }

            popRow {
                dismiss()
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } content: {
                // The real capture device. This row used to read
                // "built-in · pinned … no AirPods lag" no matter what was
                // plugged in, which was wrong for anyone on a USB mic and
                // meaningless to anyone who never had the AirPods problem.
                Text("🎙 Mic")
                    .font(Beers.ui(13, .semibold))
                Spacer()
                Text(inputDeviceName)
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            popRow {
                copyLastPour()
            } content: {
                Text("Last pour")
                    .font(Beers.ui(13, .semibold))
                Spacer()
                Text(lastPourPreview)
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.6))
                    .lineLimit(1)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Beers.ink.opacity(0.6))
            }

            statsRow

            popRow {
                dismiss()
                MainWindowPresenter.shared.show()
            } content: {
                Text("Open the Taproom").font(Beers.ui(13, .semibold))
                Spacer()
                Text("↗").font(Beers.ui(14, .bold))
            }

            popRow {
                dismiss()
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            } content: {
                Text("Brew Settings").font(Beers.ui(13, .semibold))
                Spacer()
                Text("⚙️").font(.system(size: 12))
            }

            popRow {
                updater.checkForUpdates()
            } content: {
                Image(systemName: updater.availableVersion == nil ? "arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(updater.availableVersion == nil ? Beers.stout : Beers.amber)
                Text(updater.actionTitle).font(Beers.ui(13, .semibold))
                Spacer()
                Text("v\(updater.currentVersion)")
                    .font(Beers.ui(11, .semibold))
                    .foregroundStyle(Beers.ink.opacity(0.55))
            }
            .disabled(!updater.canCheckForUpdates || updater.isChecking)
            .opacity(updater.canCheckForUpdates ? 1 : 0.55)

            popRow {
                NSApp.terminate(nil)
            } content: {
                Text("Last orders — quit").font(Beers.ui(13, .semibold))
                Spacer()
                Image(systemName: "power")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Beers.stout)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

    private var loadingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: appState.modelProgress)
                .tint(Beers.amber)
            Text(appState.loadingMessage)
                .font(Beers.ui(11, .medium))
                .foregroundStyle(Beers.ink.opacity(0.6))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Beers.cream, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Beers.ink, lineWidth: 2)
        )
    }

    private var statsRow: some View {
        HStack {
            Text("🏆 Today ")
                .font(Beers.ui(13, .semibold))
                .foregroundStyle(Beers.cream)
            + Text("\(appState.pourStore.poursToday) pours")
                .font(Beers.ui(13, .bold))
                .foregroundStyle(Beers.lager)
            Spacer()
            Text("\(appState.pourStore.wordsToday) words")
                .font(Beers.ui(12, .medium))
                .foregroundStyle(Beers.hops)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Beers.ink, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var lastPourPreview: String {
        let text = appState.lastTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "nothing yet" }
        return "“\(String(text.prefix(24)))\(text.count > 24 ? "…" : "")”"
    }

    private func copyLastPour() {
        let text = appState.lastTranscription
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func popRow<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .foregroundStyle(Beers.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(Beers.cream, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Beers.ink, lineWidth: 2)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PopRowButtonStyle())
    }
}

/// Rows nudge right and tilt on press.
private struct PopRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(x: configuration.isPressed ? 3 : 0)
            .rotationEffect(.degrees(configuration.isPressed ? -0.4 : 0))
            .animation(Beers.springTight, value: configuration.isPressed)
    }
}

private struct StatusPulseDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(0.55 + 0.45 * (sin(time * 3.5) + 1) / 2)
        }
    }
}

/// The 98pt bottle-cap pour button: amber cap in a lager+ink double ring.
struct PourCapButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Beers.amber)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Beers.paper.opacity(0.22), .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Beers.paper)
            }
            .frame(width: 98, height: 98)
            .overlay(Circle().strokeBorder(Beers.ink, lineWidth: 3.5))
            .background(
                Circle()
                    .fill(Beers.lager)
                    .frame(width: 118, height: 118)
                    .overlay(Circle().strokeBorder(Beers.ink, lineWidth: 3))
            )
            .scaleEffect(hovering && !isBusy ? 1.06 : 1)
            .rotationEffect(.degrees(hovering && !isBusy ? -3 : 0))
            .opacity(isBusy ? 0.55 : 1)
            .animation(Beers.springTight, value: hovering)
        }
        .buttonStyle(PourCapPressStyle())
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .accessibilityLabel(isRecording ? "Stop and serve" : "Start a pour")
    }
}

private struct PourCapPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Beers.springTight, value: configuration.isPressed)
    }
}
