import SwiftUI

struct RedesignedSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("selectedSettingsSection") private var selectedSection = Section.record.rawValue
    @Namespace private var sidebarSelection

    enum Section: String, CaseIterable, Identifiable {
        case record = "Record"
        case engines = "Engines"
        case writing = "Writing"
        case capture = "Capture"
        case output = "Last Output"
        case vocabulary = "Vocabulary"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .record: return "mic"
            case .engines: return "cpu"
            case .writing: return "pencil.line"
            case .capture: return "keyboard"
            case .output: return "doc.text"
            case .vocabulary: return "book"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(LlatserTheme.border)
            detail
                .id(section)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity
                ))
        }
        .frame(width: 980, height: 720)
        .background(LlatserTheme.background)
        .foregroundStyle(LlatserTheme.textPrimary)
        .tint(LlatserTheme.strong)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: section)
        .onAppear {
            appState.refreshPermissions()
            if !appState.microphoneGranted || !appState.inputMonitoringGranted || !appState.accessibilityGranted {
                section = .capture
            }
        }
    }

    private var section: Section {
        get { Section(rawValue: selectedSection) ?? .record }
        nonmutating set { selectedSection = newValue.rawValue }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BeersMark(size: 42)
                Text("Beers")
                    .font(.system(size: 24, weight: .bold, design: .serif))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            ForEach(Section.allCases) { item in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.08)) {
                        section = item
                    }
                } label: {
                    Label(item.rawValue, systemImage: item.icon)
                        .font(.system(size: 14, weight: .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .foregroundStyle(LlatserTheme.brandCream)
                        .background {
                            if section == item {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(LlatserTheme.oxblood)
                                    .matchedGeometryEffect(id: "sidebar-selection", in: sidebarSelection)
                            }
                        }
                }
                .buttonStyle(.plain)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                Label(appState.status.label, systemImage: "circle.fill")
                    .font(.system(size: 13, weight: .medium))
                Text("Mic on  •  Push-to-talk")
                    .font(.system(size: 12))
                    .foregroundStyle(LlatserTheme.textSecondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .font(.system(size: 14))
        .padding(18)
        .frame(width: 250)
        .foregroundStyle(LlatserTheme.brandCream)
        .background(Color(red: 16.0 / 255, green: 26.0 / 255, blue: 56.0 / 255))
    }

    @ViewBuilder private var detail: some View {
        Group {
            switch section {
            case .record: recordView
            case .engines: enginesView
            case .writing: writingView
            case .capture: captureView
            case .output: outputView
            case .vocabulary: vocabularyView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var recordView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader("Record", subtitle: statusText)

                waveform

                Button(action: appState.manualRecordToggle) {
                    VStack(spacing: 10) {
                        Image(systemName: recordButtonIcon)
                            .font(.system(size: 24, weight: .medium))
                            .frame(width: 74, height: 74)
                            .background(LlatserTheme.oxblood, in: Circle())
                            .foregroundStyle(LlatserTheme.brandCream)
                            .scaleEffect(appState.status == .recording ? 1.06 : 1)
                            .shadow(color: LlatserTheme.strong.opacity(appState.status == .recording ? 0.22 : 0), radius: 18)
                        Text(recordButtonTitle)
                            .font(.system(size: 16, weight: .medium))
                        Text("⌥  Hold \(appState.hotkeyChoice.shortName)")
                            .font(.system(size: 12))
                            .foregroundStyle(LlatserTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .disabled(appState.status == .loading || appState.status == .transcribing)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: appState.status)

                engineRows

                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Writing style")
                    Toggle("Adapt to current app", isOn: adaptiveWriting)
                        .font(.system(size: 14, weight: .medium))
                    Text(adaptiveWriting.wrappedValue ? "Adapts for chat, coding tools, or normal writing." : "Uses neutral cleanup everywhere.")
                        .font(.system(size: 12))
                        .foregroundStyle(LlatserTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    compactSetting("Capture", icon: "keyboard", value: appState.hotkeyChoice.displayName)
                    compactSetting("Audio", icon: "speaker.slash", value: "Suppress Mac audio", toggle: $appState.suppressComputerAudio)
                    privacyCard
                }
            }
            .padding(32)
        }
    }

    private var enginesView: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) { pageHeader("Engines", subtitle: "Choose the local transcription model."); engineRows }.padding(32) }
    }

    private var writingView: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader("Writing", subtitle: "Control how speech becomes finished text.")

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())],
                alignment: .leading,
                spacing: 12
            ) {
                settingToggle("Adapt to current app", adaptiveWriting)
                settingToggle("Polish before paste", $appState.polishBeforePaste)
                settingToggle("Speech cleanup", $appState.cleanSpeechScaffolding)
                settingToggle("Collapse repeats", $appState.collapseRepeats)
                settingToggle("Smart capitalization", $appState.smartCapitalization)
                settingToggle("Links and emails", $appState.normalizeLinks)
                settingToggle("No final full stop", $appState.removeTrailingFullStop)
                settingToggle("Add space after paste", $appState.addSpaceAfterPaste)
                settingToggle("AI rewrite", $appState.aiRewriteEnabled)
            }

            if appState.aiRewriteEnabled {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Local endpoint", text: $appState.aiRewriteEndpoint)
                    TextField("Model", text: $appState.aiRewriteModel)
                    Text("OpenAI-compatible local endpoint and model name.")
                        .font(.system(size: 12)).foregroundStyle(LlatserTheme.textSecondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LlatserTheme.panelBackground())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Button("Reset writing settings", action: appState.resetWritingPreferences)
                .buttonStyle(.bordered)
            Spacer()
        }
        .padding(32)
    }

    private var captureView: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader("Capture", subtitle: "Configure push-to-talk and system audio.")
            Picker("Push-to-talk key", selection: $appState.hotkeyChoice) { ForEach(HotkeyOption.allCases) { Text($0.displayName).tag($0) } }
            settingToggle("Suppress Mac audio", $appState.suppressComputerAudio)
            settingToggle("Start at login", $appState.launchAtLogin)
            permissions
            Spacer()
        }.padding(32)
    }

    private var outputView: some View {
        VStack(alignment: .leading, spacing: 20) {
            pageHeader("Last Output", subtitle: appState.lastTargetApp)
            Text(appState.lastTranscription.isEmpty ? "Your last dictation will appear here." : appState.lastTranscription)
                .font(.system(size: 16)).textSelection(.enabled)
                .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
                .background(LlatserTheme.panelBackground())
            Spacer()
        }.padding(32)
    }

    private var vocabularyView: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) { pageHeader("Vocabulary", subtitle: "Teach Beers names and phrases."); VocabularyEditorView(compact: false, showsTitle: false) }.padding(32) }
    }

    private var engineRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Voice engine")
            ForEach(DictationEngine.allCases) { engine in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.1)) {
                        appState.engineChoice = engine
                    }
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: appState.engineChoice == engine ? "circle.inset.filled" : "circle")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(engine.displayName).font(.system(size: 18, weight: .bold, design: .serif))
                            Text(engine.choiceLabel)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(engine == .parakeetV3 ? LlatserTheme.mint : LlatserTheme.tangerine)
                        }
                        Spacer()
                        Text(engine.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(LlatserTheme.textSecondary)
                            .lineLimit(2)
                            .frame(width: 250, alignment: .leading)
                    }
                    .padding(.horizontal, 18).frame(height: 92)
                    .background(
                        appState.engineChoice == engine ? LlatserTheme.mint.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(appState.engineChoice == engine ? LlatserTheme.mint : LlatserTheme.border, lineWidth: 1.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var waveform: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.08, paused: appState.status != .recording)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<58, id: \.self) { index in
                    let base = Double(10 + ((index * 17) % 42))
                    let movement = appState.status == .recording && !reduceMotion
                        ? abs(sin(phase * 4 + Double(index) * 0.42)) * 22
                        : 0
                    Capsule().fill(index.isMultiple(of: 4) ? LlatserTheme.tangerine : LlatserTheme.mint)
                        .frame(width: 3, height: base + movement)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 94)
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Privacy")
            Label("No analytics", systemImage: "checkmark.circle.fill")
            Label("Local rewrite is opt-in", systemImage: "checkmark.circle.fill")
            Label("Mic only on push-to-talk", systemImage: "checkmark.circle.fill")
        }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading).background(LlatserTheme.panelBackground())
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Permissions")
            permissionButton("Microphone", granted: appState.microphoneGranted) {
                appState.microphoneGranted ? Permissions.openMicrophoneSettings() : appState.requestMicrophonePermission()
            }
            permissionButton("Input Monitoring", granted: appState.inputMonitoringGranted) {
                appState.inputMonitoringGranted ? Permissions.openInputMonitoringSettings() : appState.requestInputMonitoringPermission()
            }
            permissionButton("Accessibility", granted: appState.accessibilityGranted) {
                appState.accessibilityGranted ? Permissions.openAccessibilitySettings() : appState.requestAccessibilityPermission()
            }
        }.font(.system(size: 13)).padding(16).background(LlatserTheme.panelBackground())
    }

    private func permissionButton(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                Spacer()
                Text(granted ? "Open settings" : "Grant")
                    .foregroundStyle(LlatserTheme.textSecondary)
                Image(systemName: "chevron.right")
            }.frame(height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityHint(granted ? "Opens the macOS permission pane" : "Requests this permission")
    }

    private func pageHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("◆").foregroundStyle(LlatserTheme.tangerine)
                Text(title).font(.system(size: 24, weight: .bold, design: .serif))
                Rectangle().fill(LlatserTheme.mint).frame(height: 1)
                Text("◆").foregroundStyle(LlatserTheme.butter)
            }
            Text(subtitle).font(.system(size: 13)).foregroundStyle(LlatserTheme.textSecondary)
        }
    }

    private func sectionTitle(_ title: String) -> some View { Text(title.uppercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(LlatserTheme.textSecondary) }

    private func compactSetting(_ title: String, icon: String, value: String, toggle: Binding<Bool>? = nil) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title.uppercased(), systemImage: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(LlatserTheme.textSecondary)
            HStack { Text(value).font(.system(size: 13)); Spacer(); if let toggle { Toggle("", isOn: toggle).labelsHidden() } }
        }.padding(16).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).background(LlatserTheme.panelBackground())
    }

    private func settingToggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: binding).font(.system(size: 14, weight: .regular)).padding(16).background(LlatserTheme.panelBackground())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: binding.wrappedValue)
    }

    private var statusText: String { appState.errorMessage ?? "Hold \(appState.hotkeyChoice.shortName) to dictate. Mic stays off otherwise." }

    private var adaptiveWriting: Binding<Bool> {
        Binding(
            get: { appState.writingMode == .automatic && appState.adaptiveTone },
            set: { enabled in
                appState.writingMode = enabled ? .automatic : .clean
                appState.adaptiveTone = enabled
            }
        )
    }

    private var recordButtonTitle: String {
        switch appState.status {
        case .loading: return "Preparing engine…"
        case .recording: return "Stop and Paste"
        case .transcribing: return "Processing…"
        case .ready, .error: return "Start Recording"
        }
    }

    private var recordButtonIcon: String {
        switch appState.status {
        case .loading: return "arrow.triangle.2.circlepath"
        case .recording: return "stop.fill"
        case .transcribing: return "ellipsis"
        case .ready, .error: return "mic"
        }
    }
}

struct BeersMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LlatserTheme.tangerine)
            Text("B")
                .font(.system(size: size * 0.72, weight: .black, design: .serif))
                .foregroundStyle(LlatserTheme.brandInk)
            Image(systemName: "ear")
                .font(.system(size: size * 0.35, weight: .bold))
                .foregroundStyle(LlatserTheme.butter)
                .offset(x: -size * 0.06)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Beers")
    }
}
