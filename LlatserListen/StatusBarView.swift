import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var showsVocabulary = false
    @AppStorage("selectedSettingsSection") private var selectedSettingsSection = "Record"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            Button(action: appState.manualRecordToggle) {
                Label(appState.status == .recording ? "Stop and Paste" : "Start Recording",
                      systemImage: appState.status == .recording ? "stop.fill" : "mic")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(LlatserTheme.oxblood, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(LlatserTheme.brandCream)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

            menuDivider
            menuSectionTitle("Voice engine")
            ForEach(DictationEngine.allCases) { engine in
                Button { appState.engineChoice = engine } label: {
                    HStack(spacing: 11) {
                        Image(systemName: appState.engineChoice == engine ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(engine.displayName).font(.system(size: 13, weight: .medium))
                            Text(engine.choiceLabel)
                                .font(.system(size: 12)).foregroundStyle(LlatserTheme.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(LlatserTheme.textTertiary)
                    }
                    .padding(.horizontal, 16).frame(height: 54)
                }.buttonStyle(.plain)
            }

            menuDivider
            Toggle(isOn: adaptiveWriting) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        menuSectionTitle("Writing style", inset: false)
                        Text("Adapt to current app").font(.system(size: 14, weight: .medium))
                    }
                    Spacer()
                }.padding(.horizontal, 16).frame(height: 64)
            }
            .toggleStyle(.switch)
            .padding(.trailing, 16)

            menuDivider
            menuRow("Last Output", icon: "doc.text") { openMainWindow(section: "Last Output") }
            menuRow("Vocabulary", icon: "book") { openMainWindow(section: "Vocabulary") }
            menuDivider
            menuRow("Open Beers", icon: "ear") { openMainWindow(section: "Record") }
            menuRow("Quit Beers", icon: "power", action: quit)
        }
        .frame(width: 360)
        .background(LlatserTheme.windowBackground)
        .tint(LlatserTheme.strong)
        .onAppear { appState.refreshPermissions() }
    }

    private var menuDivider: some View { Divider().overlay(LlatserTheme.border) }

    private func menuSectionTitle(_ title: String, inset: Bool = true) -> some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(LlatserTheme.textSecondary)
            .padding(.horizontal, inset ? 16 : 0)
            .padding(.top, inset ? 14 : 0)
            .padding(.bottom, inset ? 5 : 0)
    }

    private func menuRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).frame(height: 46)
        }.buttonStyle(.plain)
    }

    private var header: some View {
        HStack(spacing: 10) {
            BeersMark(size: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("Beers")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(LlatserTheme.textPrimary)
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
                .font(.system(size: 12))
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
                    .font(.system(size: 12, weight: .semibold))
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
                .foregroundStyle(LlatserTheme.textPrimary)
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
                    .font(.system(size: 12))
                    .foregroundStyle(LlatserTheme.textSecondary)
            }
        } else if let errorMessage = appState.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(LlatserTheme.warn)
        } else {
            Text("Hold \(appState.hotkeyChoice.shortName) · release to paste")
                .font(.system(size: 12))
                .foregroundStyle(LlatserTheme.textSecondary)
        }
    }

    private func compactToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LlatserTheme.textPrimary)
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
        dismiss()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openMainWindow(section: String) {
        selectedSettingsSection = section
        openMainWindow()
    }

    private var adaptiveWriting: Binding<Bool> {
        Binding(
            get: { appState.writingMode == .automatic && appState.adaptiveTone },
            set: { enabled in
                appState.writingMode = enabled ? .automatic : .clean
                appState.adaptiveTone = enabled
            }
        )
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
                    .font(.system(size: 12, weight: .semibold))
                Text(shortName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(LlatserTheme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? LlatserTheme.selected : LlatserTheme.panel)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(engine.displayName), \(isSelected ? "selected" : "not selected")")
    }

    private var shortName: String {
        switch engine {
        case .parakeetV3: return "V3"
        case .parakeetV2: return "V2"
        }
    }

    private var icon: String {
        switch engine {
        case .parakeetV3: return "checkmark.seal.fill"
        case .parakeetV2: return "arrow.left.arrow.right"
        }
    }
}
