import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            LlatserTheme.windowBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    statusPanel
                    enginePanel
                    hotkeyPanel
                    permissionsPanel
                    transcriptPanel
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 440, height: 520)
        .preferredColorScheme(.dark)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LlatserTheme.accent.opacity(0.14))
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LlatserTheme.accent)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Llatser Listen")
                    .font(.system(.largeTitle, design: .rounded).bold())
                    .foregroundStyle(.primary)
                Text("Private push-to-talk transcription for your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(status: appState.status)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(statusTitle)
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appState.status == .loading {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: appState.modelProgress)
                        .tint(LlatserTheme.accent)
                    Text(appState.loadingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    FlowStep(number: "1", title: "Hold", detail: "Right Option")
                    FlowStep(number: "2", title: "Speak", detail: "Local capture")
                    FlowStep(number: "3", title: "Release", detail: "Transcribe and paste")
                }
            }

            Button(action: appState.manualRecordToggle) {
                Label(recordButtonTitle, systemImage: appState.status == .recording ? "stop.fill" : "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(appState.status == .recording ? .red : LlatserTheme.accent)
            .disabled(appState.status == .loading || appState.status == .transcribing)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LlatserTheme.primarySurface)
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Last transcript", systemImage: "text.quote")
                .font(.headline)

            Text(appState.lastTranscription.isEmpty ? "Your last dictated text will appear here after a recording." : appState.lastTranscription)
                .font(.callout)
                .foregroundStyle(appState.lastTranscription.isEmpty ? .secondary : .primary)
                .lineLimit(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .background(LlatserTheme.secondarySurface)
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Engine")
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(DictationEngine.allCases) { engine in
                    EngineOptionRow(
                        engine: engine,
                        isSelected: appState.engineChoice == engine,
                        action: {
                            appState.engineChoice = engine
                        }
                    )
                }
            }
        }
        .padding(18)
        .background(LlatserTheme.secondarySurface)
    }

    private var hotkeyPanel: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.title3)
                .foregroundStyle(LlatserTheme.accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text("Push to talk")
                    .font(.headline)
                Text("Hold to capture, release to paste.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Right Option")
                .font(.callout.monospaced().bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        }
        .padding(18)
        .background(LlatserTheme.secondarySurface)
    }

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            PermissionRow(
                name: "Microphone",
                detail: "Records your voice locally.",
                granted: appState.microphoneGranted,
                action: appState.microphoneGranted ? "Open" : "Grant",
                handler: {
                    appState.microphoneGranted ? Permissions.openMicrophoneSettings() : appState.requestMicrophonePermission()
                }
            )

            PermissionRow(
                name: "Input Monitoring",
                detail: "Listens for Right Option.",
                granted: appState.inputMonitoringGranted,
                action: appState.inputMonitoringGranted ? "Open" : "Grant",
                handler: {
                    appState.inputMonitoringGranted ? Permissions.openInputMonitoringSettings() : appState.requestInputMonitoringPermission()
                }
            )

            PermissionRow(
                name: "Accessibility",
                detail: "Pastes text automatically.",
                granted: appState.accessibilityGranted,
                action: appState.accessibilityGranted ? "Open" : "Grant",
                handler: {
                    appState.accessibilityGranted ? Permissions.openAccessibilitySettings() : appState.requestAccessibilityPermission()
                }
            )
        }
        .padding(18)
        .background(LlatserTheme.secondarySurface)
    }

    private var recordButtonTitle: String {
        appState.status == .recording ? "Stop and Paste" : "Start Recording"
    }

    private var statusTitle: String {
        switch appState.status {
        case .loading: return "Preparing engine"
        case .ready: return "Ready to listen"
        case .recording: return "Listening now"
        case .transcribing: return "Turning speech into text"
        case .error: return "Needs attention"
        }
    }

    private var statusDetail: String {
        if let errorMessage = appState.errorMessage {
            return errorMessage
        }

        switch appState.status {
        case .loading:
            return "The selected local model is getting ready."
        case .ready:
            return "\(appState.engineChoice.displayName) is selected. Keep your workflow moving without a separate dictation window."
        case .recording:
            return "Speak naturally. Release Right Option when you are done."
        case .transcribing:
            return "Processing the recording locally, then pasting the result."
        case .error:
            return "Review the permission checklist and fix the missing item."
        }
    }
}

enum LlatserTheme {
    static let accent = Color(red: 0.24, green: 0.72, blue: 0.61)

    static var windowBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.06),
                Color(red: 0.08, green: 0.12, blue: 0.11)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var primarySurface: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(Color(red: 0.10, green: 0.13, blue: 0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.36), radius: 24, y: 14)
    }

    static var secondarySurface: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(red: 0.12, green: 0.15, blue: 0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
            )
    }
}

struct StatusBadge: View {
    let status: AppState.Status

    var body: some View {
        Label(title, systemImage: icon)
            .font(.callout.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.18), in: Capsule())
            .accessibilityLabel("Status: \(title)")
    }

    private var title: String {
        switch status {
        case .loading: return "Preparing"
        case .ready: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .error: return "Needs attention"
        }
    }

    private var icon: String {
        switch status {
        case .loading: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .recording: return "waveform.circle.fill"
        case .transcribing: return "waveform"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .loading, .transcribing: return .blue
        case .ready: return LlatserTheme.accent
        case .recording: return .red
        case .error: return .orange
        }
    }
}

private struct FlowStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.caption.monospaced().bold())
                .foregroundStyle(LlatserTheme.accent)
                .frame(width: 24, height: 24)
                .background(LlatserTheme.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EngineOptionRow: View {
    let engine: DictationEngine
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(engine.displayName)
                        .font(.callout.bold())
                        .foregroundStyle(.primary)
                    Text(engine.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? LlatserTheme.accent : Color.secondary.opacity(0.42))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? LlatserTheme.accent.opacity(0.18) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? LlatserTheme.accent.opacity(0.42) : .white.opacity(0.075), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSelected)
        .accessibilityLabel("\(engine.displayName), \(isSelected ? "selected" : "not selected")")
    }
}

private struct PermissionRow: View {
    let name: String
    let detail: String
    let granted: Bool
    let action: String
    let handler: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? LlatserTheme.accent : .orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action, action: handler)
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }
}
