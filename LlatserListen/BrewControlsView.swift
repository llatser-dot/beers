import AppKit
import SwiftUI

/// Brew Controls: settings as labelled crates, not a grey table.
struct BrewControlsView: View {
    @EnvironmentObject var appState: AppState
    @State private var showSmashSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                pourCrate
                tapCrate
                dictionaryCrate
                polishCrate
                cellarCrate
                footer
            }
            .padding(22)
        }
        .frame(width: 560, height: 720)
        .background(Beers.cream)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showSmashSheet) {
            SmashTheGlassesSheet(isPresented: $showSmashSheet) {
                appState.pourStore.smashTheGlasses()
                appState.lastTranscription = ""
            }
        }
        .onAppear { appState.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BeersAppIcon(size: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Brew Controls")
                    .font(Beers.display(22))
                    .foregroundStyle(Beers.stout)
                Text("One screen, no grey, everything on tap.")
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.6))
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    // MARK: 🍺 The Pour

    private var pourCrate: some View {
        BeersCrate(title: "The Pour", emoji: "🍺", headerColor: Beers.lager) {
            BeersSettingRow(label: "Pour key", hint: "Hold to talk, release to serve") {
                Menu {
                    ForEach(HotkeyOption.allCases) { option in
                        Button(option.displayName) { appState.hotkeyChoice = option }
                    }
                } label: {
                    BeersChip(fill: Beers.cream) {
                        HStack(spacing: 7) {
                            Text(appState.hotkeyChoice.keycapLabel)
                                .font(Beers.ui(13, .bold))
                            Text("▾")
                                .font(Beers.ui(12, .semibold))
                                .foregroundStyle(Beers.amber)
                        }
                    }
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            BeersSettingRow(label: "Serve style", hint: "Where the words land") {
                BeersChip { Text("Paste at cursor") }
            }

            BeersSettingRow(label: "Add a space after serving", hint: "Ready for the next pour") {
                Toggle("", isOn: $appState.addSpaceAfterPaste)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }

            BeersSettingRow(
                label: "Clink on serve",
                hint: "And a cap-pop when the pour key goes down",
                showDivider: false
            ) {
                Toggle("", isOn: $appState.clinkOnServe)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }
        }
    }

    // MARK: 🎙 The Tap

    private var tapCrate: some View {
        BeersCrate(title: "The Tap", emoji: "🎙", headerColor: Beers.hops) {
            BeersSettingRow(
                label: "Microphone",
                hint: "Pinned — Bluetooth mics are never captured, so AirPods never lag"
            ) {
                BeersChip { Text("Built-in, auto") }
            }

            BeersSettingRow(label: "Brew engine", hint: "Local Parakeet — nothing leaves the Mac") {
                HStack(spacing: 7) {
                    ForEach(DictationEngine.allCases) { engine in
                        engineChip(engine)
                    }
                }
            }

            BeersSettingRow(
                label: "Quiet the bar while pouring",
                hint: "Ducks Mac audio while the pour key is held",
                showDivider: false
            ) {
                Toggle("", isOn: $appState.suppressComputerAudio)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }
        }
    }

    private func engineChip(_ engine: DictationEngine) -> some View {
        let selected = appState.engineChoice == engine
        return Button {
            withAnimation(Beers.spring) { appState.engineChoice = engine }
        } label: {
            Text(engineShortName(engine))
                .font(Beers.ui(12, .bold))
                .foregroundStyle(selected ? Beers.paper : Beers.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    selected ? Beers.amber : Beers.cream2,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Beers.ink, lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
    }

    private func engineShortName(_ engine: DictationEngine) -> String {
        switch engine {
        case .parakeetV3: return "Parakeet v3"
        case .parakeetV2: return "Parakeet v2"
        }
    }

    // MARK: 📖 Brewer's dictionary

    private var dictionaryCrate: some View {
        BeersCrate(title: "Brewer’s Dictionary", emoji: "📖", headerColor: Beers.cream2) {
            VStack(alignment: .leading, spacing: 0) {
                VocabularyEditorView(compact: true, showsTitle: false)
                    .padding(16)
            }
        }
    }

    // MARK: ✍️ The Polish

    private var polishCrate: some View {
        BeersCrate(title: "The Polish", emoji: "✍️", headerColor: Beers.lager) {
            BeersSettingRow(label: "Adapt to the app you’re pouring into", hint: "Chat, code or prose — matched automatically") {
                Toggle("", isOn: adaptiveWriting)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }

            BeersSettingRow(label: "Polish before serving", hint: "Cleans fillers, repeats and casing") {
                Toggle("", isOn: $appState.polishBeforePaste)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }

            if appState.polishBeforePaste {
                polishToggleGrid
            }

            BeersSettingRow(
                label: "AI rewrite",
                hint: "Optional local model pass",
                showDivider: appState.aiRewriteEnabled
            ) {
                Toggle("", isOn: $appState.aiRewriteEnabled)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }

            if appState.aiRewriteEnabled {
                VStack(spacing: 8) {
                    aiField("Local endpoint", text: $appState.aiRewriteEndpoint)
                    aiField("Model", text: $appState.aiRewriteModel)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
    }

    private var polishToggleGrid: some View {
        VStack(spacing: 0) {
            miniToggleRow("Speech cleanup", $appState.cleanSpeechScaffolding)
            miniToggleRow("Collapse repeats", $appState.collapseRepeats)
            miniToggleRow("Smart capitalisation", $appState.smartCapitalization)
            miniToggleRow("Links and emails", $appState.normalizeLinks)
            miniToggleRow("No final full stop", $appState.removeTrailingFullStop)
        }
    }

    private func miniToggleRow(_ label: String, _ binding: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(Beers.ui(13, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.85))
                Spacer()
                Toggle("", isOn: binding)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
                    .scaleEffect(0.85, anchor: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            DashedDivider().padding(.horizontal, 12)
        }
    }

    private func aiField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Beers.ui(13, .medium))
            .foregroundStyle(Beers.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Beers.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
    }

    // MARK: 🔒 The Cellar

    private var cellarCrate: some View {
        BeersCrate(title: "The Cellar", emoji: "🔒", headerColor: Beers.stout, headerText: Beers.paper) {
            BeersSettingRow(label: "Open bar at login", hint: "Beers waits in the menu bar") {
                Toggle("", isOn: $appState.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }

            permissionRow("Microphone", granted: appState.microphoneGranted) {
                appState.microphoneGranted
                    ? Permissions.openMicrophoneSettings()
                    : appState.requestMicrophonePermission()
            }
            permissionRow("Input Monitoring", granted: appState.inputMonitoringGranted) {
                appState.inputMonitoringGranted
                    ? Permissions.openInputMonitoringSettings()
                    : appState.requestInputMonitoringPermission()
            }
            permissionRow("Accessibility", granted: appState.accessibilityGranted) {
                appState.accessibilityGranted
                    ? Permissions.openAccessibilitySettings()
                    : appState.requestAccessibilityPermission()
            }

            BeersSettingRow(
                label: "Smash the glasses",
                hint: "Delete every pour, forever",
                showDivider: false
            ) {
                Button("Smash…") { showSmashSheet = true }
                    .buttonStyle(BeersButtonStyle(kind: .stoutGhost, small: true))
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        BeersSettingRow(label: title, hint: granted ? "Granted" : "Needed for the full pour") {
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: granted ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(granted ? "On tap" : "Grant")
                        .font(Beers.ui(12, .bold))
                }
                .foregroundStyle(Beers.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(
                    granted ? Beers.hops : Beers.lager,
                    in: Capsule()
                )
                .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 2))
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            BeersMark(size: 26)
            Text("There’s nothing better than a free Beer.")
                .font(Beers.display(12))
                .foregroundStyle(Beers.ink.opacity(0.55))
        }
        .padding(.top, 8)
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
}

/// Destructive confirm with the scalloped seal as the warning mark.
/// Requires typing SMASH.
struct SmashTheGlassesSheet: View {
    @Binding var isPresented: Bool
    let onConfirm: () -> Void
    @State private var confirmation = ""

    private var armed: Bool { confirmation.uppercased() == "SMASH" }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                SealShape()
                    .fill(Beers.lager)
                SealShape()
                    .stroke(Beers.ink, lineWidth: 2.5)
                Text("💥").font(.system(size: 26))
            }
            .frame(width: 74, height: 74)

            Text("Smash the glasses?")
                .font(Beers.display(18))
                .foregroundStyle(Beers.stout)

            Text("Every pour in the Taproom — keepers, drip tray, the lot — is deleted forever. Type SMASH to confirm.")
                .font(Beers.ui(13, .medium))
                .foregroundStyle(Beers.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            TextField("SMASH", text: $confirmation)
                .textFieldStyle(.plain)
                .font(Beers.ui(15, .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Beers.stout)
                .padding(.vertical, 9)
                .background(Beers.cream, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(armed ? Beers.stout : Beers.ink, lineWidth: 2.5)
                )

            HStack(spacing: 12) {
                Button("Keep them") { isPresented = false }
                    .buttonStyle(BeersButtonStyle(kind: .ghost, small: true))
                Button("Smash 💥") {
                    onConfirm()
                    isPresented = false
                }
                .buttonStyle(BeersButtonStyle(kind: .amber, small: true))
                .disabled(!armed)
                .opacity(armed ? 1 : 0.45)
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(Beers.paper)
        .environment(\.colorScheme, .light)
    }
}
