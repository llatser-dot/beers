import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            actionPanel
            enginePanel

            if !appState.lastTranscription.isEmpty {
                transcriptPanel
            }

            if let permissionMessage {
                Label(permissionMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            }

            Divider()

            HStack {
                Button("Open Llatser Listen", systemImage: "slider.horizontal.3", action: openMainWindow)
                Spacer()
                Button("Quit", systemImage: "power", action: quit)
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(18)
        .frame(width: 360)
        .background(LlatserTheme.windowBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(statusColor.opacity(0.13))
                Image(systemName: statusIcon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("Llatser Listen")
                    .font(.title3.bold())
                Text(appState.status.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineDetail

            Button(action: appState.manualRecordToggle) {
                Label(appState.status == .recording ? "Stop and Paste" : "Record", systemImage: appState.status == .recording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(appState.status == .recording ? .red : LlatserTheme.accent)
            .disabled(appState.status == .loading || appState.status == .transcribing)
        }
        .padding(14)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.09), lineWidth: 0.8)
        )
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Engine")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            Picker("Engine", selection: $appState.engineChoice) {
                ForEach(DictationEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Last transcript", systemImage: "text.quote")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(appState.lastTranscription)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var engineDetail: some View {
        if appState.status == .loading {
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: appState.modelProgress)
                    .tint(LlatserTheme.accent)
                Text(appState.loadingMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let errorMessage = appState.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.engineChoice.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Hold Right Option, release to transcribe and paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionMessage: String? {
        if !appState.microphoneGranted {
            return "Microphone access is missing."
        }
        if !appState.inputMonitoringGranted {
            return "Input Monitoring is missing."
        }
        if !appState.accessibilityGranted {
            return "Accessibility is missing."
        }
        return nil
    }

    private var statusIcon: String {
        switch appState.status {
        case .loading: return "arrow.triangle.2.circlepath"
        case .ready: return "mic.circle.fill"
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "waveform"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .loading, .transcribing: return .blue
        case .ready: return LlatserTheme.accent
        case .recording: return .red
        case .error: return .orange
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}
