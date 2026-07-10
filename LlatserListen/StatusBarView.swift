import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showsVocabulary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            actionPanel
            enginePanel
            modePanel
            capturePanel
            writingPanel
            vocabularyPanel

            if !appState.lastTranscription.isEmpty {
                transcriptPanel
            }

            if let permissionMessage {
                Label(permissionMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LlatserTheme.warn)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LlatserTheme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Rectangle()
                .fill(LlatserTheme.hairline)
                .frame(height: 1)

            HStack {
                Button(action: openMainWindow) {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                Spacer()
                Button(action: quit) {
                    Label("Quit", systemImage: "power")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LlatserTheme.accent)
        }
        .padding(14)
        .frame(width: 340)
        .background(LlatserTheme.windowBackground)
        .preferredColorScheme(.dark)
        .onAppear { appState.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(statusColor.opacity(0.12))
                Image(systemName: statusIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Llatser Listen")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(appState.status.label)
                    .font(.system(size: 12))
                    .foregroundStyle(LlatserTheme.textSecondary)
            }
            Spacer()
            StatusBadge(status: appState.status)
        }
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            engineDetail

            Button(action: appState.manualRecordToggle) {
                HStack(spacing: 8) {
                    Image(systemName: appState.status == .recording ? "stop.fill" : "mic.fill")
                    Text(appState.status == .recording ? "Stop and Paste" : "Record")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(appState.status == .recording ? .white : LlatserTheme.ink)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(appState.status == .recording ? LlatserTheme.danger : LlatserTheme.accent)
            )
            .disabled(appState.status == .loading || appState.status == .transcribing)
            .opacity(appState.status == .loading || appState.status == .transcribing ? 0.5 : 1)
        }
        .padding(12)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    private var modePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Mode")
            Picker("Writing mode", selection: $appState.writingMode) {
                ForEach(WritingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Push-to-talk key", selection: $appState.hotkeyChoice) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 12))
        }
        .padding(12)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    private var enginePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Engine")
            HStack(spacing: 6) {
                ForEach(DictationEngine.allCases) { engine in
                    StatusEngineButton(
                        engine: engine,
                        isSelected: appState.engineChoice == engine,
                        action: { appState.engineChoice = engine }
                    )
                }
            }
        }
        .padding(12)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    private var writingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Writing")
            compactToggle("Polish", icon: "wand.and.sparkles", isOn: $appState.polishBeforePaste)
            compactToggle("AI rewrite", icon: "brain.head.profile", isOn: $appState.aiRewriteEnabled)
            compactToggle("Links", icon: "link", isOn: $appState.normalizeLinks)
            compactToggle("No final full stop", icon: "textformat.abc.dottedunderline", isOn: $appState.removeTrailingFullStop)
        }
        .padding(12)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    private var capturePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Capture")
            compactToggle("Suppress Mac audio", icon: "speaker.slash.fill", isOn: $appState.suppressComputerAudio)
            Text("Ducks volume while the hotkey is held.")
                .font(.system(size: 11))
                .foregroundStyle(LlatserTheme.textSecondary)
        }
        .padding(12)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    private var vocabularyPanel: some View {
        DisclosureGroup(isExpanded: $showsVocabulary) {
            VocabularyEditorView(compact: true, showsTitle: false)
                .padding(.top, 8)
        } label: {
            HStack {
                SectionLabel(title: "Vocabulary", icon: "text.badge.checkmark")
                Spacer()
                Text("\(appState.vocabularyCorrections.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LlatserTheme.textSecondary)
            }
        }
        .tint(LlatserTheme.accent)
        .padding(12)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Last paste", icon: "text.quote")
            Text(appState.lastTranscription)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LlatserTheme.panelBackground(cornerRadius: 12))
    }

    @ViewBuilder
    private var engineDetail: some View {
        if appState.status == .loading {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: appState.modelProgress)
                    .tint(LlatserTheme.accent)
                Text(appState.loadingMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(LlatserTheme.textSecondary)
            }
        } else if let errorMessage = appState.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(LlatserTheme.warn)
        } else {
            Text("Hold \(appState.hotkeyChoice.shortName) · release to paste")
                .font(.system(size: 11))
                .foregroundStyle(LlatserTheme.textSecondary)
        }
    }

    private func compactToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LlatserTheme.accent)
                .accessibilityLabel(title)
        }
    }

    private var permissionMessage: String? {
        if !appState.microphoneGranted { return "Microphone access is missing." }
        if !appState.inputMonitoringGranted { return "Input Monitoring is missing." }
        if !appState.accessibilityGranted { return "Accessibility is missing." }
        return nil
    }

    private var statusIcon: String {
        switch appState.status {
        case .loading: return "arrow.triangle.2.circlepath"
        case .ready: return "mic"
        case .recording: return "waveform"
        case .transcribing: return "ellipsis"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .loading, .transcribing, .ready: return LlatserTheme.accent
        case .recording: return LlatserTheme.danger
        case .error: return LlatserTheme.warn
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

private struct StatusEngineButton: View {
    let engine: DictationEngine
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? LlatserTheme.ink : .white)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? LlatserTheme.accent : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(engine.displayName), \(isSelected ? "selected" : "not selected")")
    }

    private var shortName: String {
        switch engine {
        case .parakeetV3: return "V3"
        case .parakeetV2: return "V2"
        case .nemotron: return "Nemo"
        }
    }

    private var icon: String {
        switch engine {
        case .parakeetV3: return "checkmark.seal.fill"
        case .parakeetV2: return "arrow.left.arrow.right"
        case .nemotron: return "bolt.horizontal.circle.fill"
        }
    }
}
