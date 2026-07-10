import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            LlatserTheme.windowBackground
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HeroPanel()
                    DashboardGrid()
                    WritingPanel()
                    VocabularyEditorView(compact: false, showsTitle: true)
                        .llatserPanel()
                    LastOutputPanel()
                }
                .padding(18)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 700, height: 780)
        .preferredColorScheme(.dark)
        .onAppear { appState.refreshPermissions() }
    }
}

// MARK: - Hero

private struct HeroPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                    Image(systemName: statusIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Llatser Listen")
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(.white)

                    Text(statusDetail)
                        .font(.system(size: 13))
                        .foregroundStyle(LlatserTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
                StatusBadge(status: appState.status)
            }

            HStack(spacing: 8) {
                StepChip(title: "Hold", detail: appState.hotkeyChoice.shortName)
                StepChip(title: "Speak", detail: appState.engineChoice.displayName)
                StepChip(title: "Release", detail: "Paste")
            }

            Button(action: appState.manualRecordToggle) {
                HStack(spacing: 8) {
                    Image(systemName: appState.status == .recording ? "stop.fill" : "mic.fill")
                    Text(appState.status == .recording ? "Stop and Paste" : "Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
            }
            .buttonStyle(PressableButtonStyle())
            .foregroundStyle(appState.status == .recording ? .white : LlatserTheme.ink)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(appState.status == .recording ? LlatserTheme.danger : LlatserTheme.accent)
            )
            .disabled(appState.status == .loading || appState.status == .transcribing)
            .opacity(appState.status == .loading || appState.status == .transcribing ? 0.5 : 1)

            if appState.status == .loading {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: appState.modelProgress)
                        .tint(LlatserTheme.accent)
                    Text(appState.loadingMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(LlatserTheme.textSecondary)
                }
            }
        }
        .padding(20)
        .background(LlatserTheme.primarySurface)
    }

    private var statusDetail: String {
        if let errorMessage = appState.errorMessage { return errorMessage }
        switch appState.status {
        case .loading: return "Preparing the local speech engine."
        case .ready: return "Hold \(appState.hotkeyChoice.shortName) to dictate. Mic stays off otherwise."
        case .recording: return "Listening. Release \(appState.hotkeyChoice.shortName) when done."
        case .transcribing: return "Processing for \(appState.lastTargetApp)."
        case .error: return "Check permissions below."
        }
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
}

private struct StepChip: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(LlatserTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Dashboard

private struct DashboardGrid: View {
    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow { EnginePanel().gridCellColumns(2) }
            GridRow {
                TrustPanel()
                ModePanel()
            }
            GridRow { CapturePanel().gridCellColumns(2) }
            GridRow { PermissionsPanel().gridCellColumns(2) }
        }
    }
}

private struct EnginePanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(title: "Voice engine", icon: "cpu")
                Spacer()
                Text(engineStatusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(engineStatusColor)
            }

            HStack(spacing: 8) {
                ForEach(DictationEngine.allCases) { engine in
                    EngineChoiceButton(
                        engine: engine,
                        isSelected: appState.engineChoice == engine,
                        action: { appState.engineChoice = engine }
                    )
                }
            }

            Text(appState.engineChoice.detail)
                .font(.system(size: 12))
                .foregroundStyle(LlatserTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if appState.engineChoice.isExperimental {
                Label("Experimental", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LlatserTheme.warn)
            }
        }
        .llatserPanel(minHeight: 176)
    }

    private var engineStatusLabel: String {
        if appState.errorMessage != nil { return "Error" }
        if appState.engineLoaded { return "Loaded" }
        return appState.status == .loading ? "Preparing" : "Standby"
    }

    private var engineStatusColor: Color {
        if appState.errorMessage != nil { return LlatserTheme.warn }
        return appState.engineLoaded ? LlatserTheme.accent : LlatserTheme.textSecondary
    }
}

private struct TrustPanel: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Privacy", icon: "lock.shield")
            CheckLine(text: "No analytics")
            CheckLine(text: "Local rewrite is opt-in")
            CheckLine(text: "Mic only on push-to-talk")
            Spacer(minLength: 0)
        }
        .llatserPanel(minHeight: 140)
    }
}

private struct ModePanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Writing mode", icon: "slider.horizontal.3")
            Picker("Writing mode", selection: $appState.writingMode) {
                ForEach(WritingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(appState.writingMode.detail)
                .font(.system(size: 12))
                .foregroundStyle(LlatserTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .llatserPanel(minHeight: 140)
    }
}

private struct CapturePanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Capture", icon: "ear.badge.waveform")

            Picker(selection: $appState.hotkeyChoice) {
                ForEach(HotkeyOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            } label: {
                Label("Push-to-talk key", systemImage: "keyboard")
                    .font(.system(size: 13, weight: .semibold))
            }

            Toggle(isOn: $appState.suppressComputerAudio) {
                Label("Suppress Mac audio", systemImage: "speaker.slash.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(LlatserTheme.accent)

            Text("Ducks system volume while the hotkey is held. Mic stays off otherwise.")
                .font(.system(size: 12))
                .foregroundStyle(LlatserTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $appState.launchAtLogin) {
                Label("Start at login", systemImage: "power")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(LlatserTheme.accent)
        }
        .llatserPanel()
    }
}

private struct PermissionsPanel: View {
    @EnvironmentObject var appState: AppState

    private var needsRelaunch: Bool {
        !appState.inputMonitoringGranted || !appState.accessibilityGranted || !appState.microphoneGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Permissions", icon: "checkmark.shield")

            Text("Grant only the /Applications copy. If a toggle is ON but still denied here, relaunch.")
                .font(.system(size: 11))
                .foregroundStyle(LlatserTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionRow(
                name: "Microphone",
                detail: "Record speech locally.",
                granted: appState.microphoneGranted,
                action: appState.microphoneGranted ? "Open" : "Grant",
                handler: {
                    appState.microphoneGranted ? Permissions.openMicrophoneSettings() : appState.requestMicrophonePermission()
                }
            )
            PermissionRow(
                name: "Input Monitoring",
                detail: "Hold \(appState.hotkeyChoice.shortName).",
                granted: appState.inputMonitoringGranted,
                action: appState.inputMonitoringGranted ? "Open" : "Grant",
                handler: {
                    appState.inputMonitoringGranted ? Permissions.openInputMonitoringSettings() : appState.requestInputMonitoringPermission()
                }
            )
            PermissionRow(
                name: "Accessibility",
                detail: "Paste into apps.",
                granted: appState.accessibilityGranted,
                action: appState.accessibilityGranted ? "Open" : "Grant",
                handler: {
                    appState.accessibilityGranted ? Permissions.openAccessibilitySettings() : appState.requestAccessibilityPermission()
                }
            )

            if needsRelaunch {
                Button(action: appState.relaunchToApplyPermissions) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Relaunch to apply grants")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(LlatserTheme.ink)
                .background(LlatserTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .llatserPanel()
    }
}

// MARK: - Writing

private struct WritingPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(title: "Writing", icon: "wand.and.sparkles")
                Spacer()
                Button("Reset", systemImage: "arrow.counterclockwise", action: appState.resetWritingPreferences)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(LlatserTheme.accent)
            }

            Toggle(isOn: $appState.polishBeforePaste) {
                Label("Polish before paste", systemImage: "wand.and.sparkles")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(LlatserTheme.accent)

            Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    SettingSwitch(title: "Speech cleanup", detail: "Removes filler phrases.", isOn: $appState.cleanSpeechScaffolding)
                    SettingSwitch(title: "Collapse repeats", detail: "Fixes stutters and repeats.", isOn: $appState.collapseRepeats)
                }
                GridRow {
                    SettingSwitch(title: "Smart capitalization", detail: "Capitalizes sentence starts.", isOn: $appState.smartCapitalization)
                    SettingSwitch(title: "Links and emails", detail: "Normalizes domains and URLs.", isOn: $appState.normalizeLinks)
                }
                GridRow {
                    SettingSwitch(title: "No final full stop", detail: "Keeps pasted text open-ended.", isOn: $appState.removeTrailingFullStop)
                    SettingSwitch(title: "Adaptive tone", detail: "Uses active app as a hint.", isOn: $appState.adaptiveTone)
                }
            }

            Toggle(isOn: $appState.addSpaceAfterPaste) {
                Label("Add space after paste", systemImage: "space")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(LlatserTheme.accent)

            Rectangle()
                .fill(LlatserTheme.hairline)
                .frame(height: 1)

            Toggle(isOn: $appState.aiRewriteEnabled) {
                Label("AI rewrite", systemImage: "brain.head.profile")
                    .font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(LlatserTheme.accent)

            Grid(horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    TextSetting(title: "Local endpoint", detail: "OpenAI-compatible URL.", text: $appState.aiRewriteEndpoint)
                    TextSetting(title: "Model", detail: "Local model name.", text: $appState.aiRewriteModel)
                }
            }
            .disabled(!appState.aiRewriteEnabled)
            .opacity(appState.aiRewriteEnabled ? 1 : 0.45)
        }
        .llatserPanel()
    }
}

private struct LastOutputPanel: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "Last output", icon: "text.quote")
                Spacer()
                Text(appState.lastTargetApp)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(LlatserTheme.textTertiary)
            }

            Text(appState.lastTranscription.isEmpty ? "Your last dictation will appear here." : appState.lastTranscription)
                .font(.system(size: 13))
                .foregroundStyle(appState.lastTranscription.isEmpty ? LlatserTheme.textTertiary : .white)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        }
        .llatserPanel()
    }
}

// MARK: - Shared

private struct EngineChoiceButton: View {
    let engine: DictationEngine
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? LlatserTheme.ink : LlatserTheme.accent)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? LlatserTheme.ink.opacity(0.7) : LlatserTheme.textTertiary)
                }
                Text(engine.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? LlatserTheme.ink : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(shortDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? LlatserTheme.ink.opacity(0.7) : LlatserTheme.textSecondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? LlatserTheme.accent : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.clear : LlatserTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("\(engine.displayName), \(isSelected ? "selected" : "not selected")")
    }

    private var icon: String {
        switch engine {
        case .parakeetV3: return "checkmark.seal.fill"
        case .parakeetV2: return "arrow.left.arrow.right"
        case .nemotron: return "bolt.horizontal.circle.fill"
        }
    }

    private var shortDetail: String {
        switch engine {
        case .parakeetV3: return "Default quality"
        case .parakeetV2: return "Compare output"
        case .nemotron: return "Experimental"
        }
    }
}

private struct SettingSwitch: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(LlatserTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LlatserTheme.accent)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct TextSetting: View {
    let title: String
    let detail: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(LlatserTheme.textSecondary)
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .jarvisField()
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CheckLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(LlatserTheme.accent)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(LlatserTheme.textSecondary)
        }
    }
}

private struct PermissionRow: View {
    let name: String
    let detail: String
    let granted: Bool
    let action: String
    let handler: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? LlatserTheme.accent : LlatserTheme.warn)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(LlatserTheme.textSecondary)
            }

            Spacer()

            Button(action, action: handler)
                .font(.system(size: 12, weight: .semibold))
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(granted ? LlatserTheme.textSecondary : LlatserTheme.accent)
        }
        .padding(.vertical, 2)
    }
}
