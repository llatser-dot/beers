import SwiftUI

/// First Round: three steps, ninety seconds, and the last one pours
/// your first Beer before you ever see a settings screen.
struct FirstRoundView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("firstRoundDone") private var firstRoundDone = false
    @State private var step: Int
    @State private var celebrated = false
    @State private var guiding: GuidedGrant?

    /// The two grants macOS won't prompt-and-toggle for you — they need the
    /// switch flipped in System Settings, so we walk the user there.
    enum GuidedGrant {
        case accessibility
        case inputMonitoring

        var listName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }
    }

    /// `initialStep` lets the snapshot harness open First Round on a specific
    /// step (e.g. the learning disclosure). Production resumes from the saved
    /// step, because granting Input Monitoring/Accessibility relaunches the
    /// app mid-onboarding and the user should land right back where they were.
    /// Snapshot-only: keeps the doorman guide visible even when this Mac has
    /// already granted everything, so the harness can render it.
    private let forceGuideForSnapshot: Bool

    init(initialStep: Int? = nil, initialGuide: GuidedGrant? = nil) {
        let saved = UserDefaults.standard.integer(forKey: "firstRoundStep")
        _step = State(initialValue: initialStep ?? min(max(saved, 0), 3))
        _guiding = State(initialValue: initialGuide)
        forceGuideForSnapshot = initialGuide != nil
    }

    private var allPermissionsGranted: Bool {
        appState.microphoneGranted && appState.inputMonitoringGranted && appState.accessibilityGranted
    }

    /// One switch for the whole flywheel: flips pour-logging and the
    /// correction watcher together (both default on; writes through AppState so
    /// UserDefaults stays the single source of truth the pipeline reads).
    private var learnBinding: Binding<Bool> {
        Binding(
            get: { appState.flywheelLoggingEnabled },
            set: { on in
                appState.flywheelLoggingEnabled = on
                appState.correctionWatcherEnabled = on
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            stepBadge

            Group {
                switch step {
                case 0: permissionsStep
                case 1: pourKeyStep
                case 2: learningStep
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
                .strokeBorder(Beers.lager, lineWidth: step == 3 ? 5 : 0)
        )
        .environment(\.colorScheme, .light)
        .animation(Beers.spring, value: step)
        .onChange(of: appState.lastTranscription) { _, newValue in
            if step == 3, !newValue.isEmpty {
                celebrated = true
            }
        }
        .onChange(of: step) { _, newStep in
            UserDefaults.standard.set(newStep, forKey: "firstRoundStep")
        }
        // Live-poll while the doorman step is up: the moment a toggle flips in
        // System Settings the row goes green (and the TCC relaunch fires) with
        // no clicking back and forth.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if step == 0 && !allPermissionsGranted {
                appState.refreshPermissions()
            }
        }
        .onChange(of: appState.accessibilityGranted) { _, granted in
            if granted && guiding == .accessibility {
                Beers.popCap()
                withAnimation(Beers.spring) { advanceGuide() }
            }
        }
        .onChange(of: appState.inputMonitoringGranted) { _, granted in
            if granted && guiding == .inputMonitoring {
                Beers.popCap()
                withAnimation(Beers.spring) { advanceGuide() }
            }
        }
    }

    private func advanceGuide() {
        if !appState.accessibilityGranted {
            guiding = .accessibility
        } else if !appState.inputMonitoringGranted {
            guiding = .inputMonitoring
        } else {
            guiding = nil
        }
    }

    private var stepBadge: some View {
        HStack {
            Text("\(step + 1) of 4")
                .font(Beers.display(12))
                .foregroundStyle(Beers.paper)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Beers.ink, in: Capsule())
                .rotationEffect(.degrees(-6))
            Spacer()
            BeersMenuBadge(size: 30)
        }
        .padding(.bottom, 8)
    }

    // MARK: Step 1 — permissions

    private var permissionsStep: some View {
        VStack(spacing: 12) {
            if guiding == nil {
                Text("👂").font(.system(size: 44)).rotationEffect(.degrees(-5))

                Text("Can we borrow your ears?")
                    .font(Beers.display(19))
                    .foregroundStyle(Beers.stout)
                    .multilineTextAlignment(.center)

                Text("Beers needs three grants — that’s how your words land wherever the cursor is.")
                    .font(Beers.ui(13, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            VStack(spacing: 8) {
                grantRow("Microphone", granted: appState.microphoneGranted, highlighted: false) {
                    appState.requestMicrophonePermission()
                }
                grantRow("Accessibility", granted: appState.accessibilityGranted, highlighted: guiding == .accessibility) {
                    appState.requestAccessibilityPermission()
                    withAnimation(Beers.spring) { guiding = .accessibility }
                }
                grantRow("Input Monitoring", granted: appState.inputMonitoringGranted, highlighted: guiding == .inputMonitoring) {
                    appState.requestInputMonitoringPermission()
                    Permissions.openInputMonitoringSettings()
                    withAnimation(Beers.spring) { guiding = .inputMonitoring }
                }
            }
            .padding(.top, guiding == nil ? 6 : 2)

            if let guiding, forceGuideForSnapshot || !isGranted(guiding) {
                guidePanel(for: guiding)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else if !allPermissionsGranted {
                Text("Tap a grant and Beers walks you through it — no hunting through System Settings.")
                    .font(Beers.ui(11, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.top, guiding == nil ? 14 : 2)
    }

    private func isGranted(_ grant: GuidedGrant) -> Bool {
        switch grant {
        case .accessibility: return appState.accessibilityGranted
        case .inputMonitoring: return appState.inputMonitoringGranted
        }
    }

    /// The doorman: System Settings is open next to us — the user drags the
    /// badge straight into the permission list (no + button, no file picker),
    /// flips the switch, and Beers pours itself back in.
    private func guidePanel(for grant: GuidedGrant) -> some View {
        VStack(spacing: 10) {
            Text("System Settings just opened — find the \(grant.listName) list.")
                .font(Beers.ui(12.5, .semibold))
                .foregroundStyle(Beers.ink)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)

            HStack(spacing: 14) {
                DraggableAppBadge()

                VStack(alignment: .leading, spacing: 7) {
                    guideLine("1", "Beers not in the list? Drag this bottle straight in.")
                    guideLine("2", "Flip the Beers switch on.")
                    guideLine("3", "Beers restarts itself and lands right back here.")
                }
            }
            .padding(.top, 2)

            HStack(spacing: 6) {
                WatchingDots()
                Text("Watching the door…")
                    .font(Beers.ui(11, .semibold))
                    .foregroundStyle(Beers.ink.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Beers.lager.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Beers.ink, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5]))
        )
    }

    private func guideLine(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .font(Beers.display(11))
                .foregroundStyle(Beers.paper)
                .frame(width: 18, height: 18)
                .background(Beers.stout, in: Circle())
            Text(text)
                .font(Beers.ui(11.5, .medium))
                .foregroundStyle(Beers.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func grantRow(_ title: String, granted: Bool, highlighted: Bool, action: @escaping () -> Void) -> some View {
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
        .padding(.vertical, highlighted ? 8 : 10)
        .background(
            highlighted ? Beers.lager.opacity(0.35) : Beers.cream,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(highlighted ? Beers.amber : Beers.ink, lineWidth: highlighted ? 3 : 2)
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

    // MARK: Step 3 — learning disclosure

    private var learningStep: some View {
        VStack(spacing: 13) {
            Text("📓").font(.system(size: 46)).rotationEffect(.degrees(-5))

            Text("Beers learns your taste")
                .font(Beers.display(19))
                .foregroundStyle(Beers.stout)
                .multilineTextAlignment(.center)

            Text("As you pour, Beers keeps a private notebook on this Mac only — your words and the keyboard fixes you make afterwards — so your own cleanup model can learn how you talk.")
                .font(Beers.ui(13, .medium))
                .foregroundStyle(Beers.ink.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            Text("Nothing ever leaves the machine. Turn it off or pour it away any time in Brew Controls.")
                .font(Beers.ui(12, .semibold))
                .foregroundStyle(Beers.hopsDeep)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Learn from my pours")
                        .font(Beers.ui(14, .semibold))
                        .foregroundStyle(Beers.ink)
                    Text("On this Mac only")
                        .font(Beers.ui(11.5, .medium))
                        .foregroundStyle(Beers.ink.opacity(0.55))
                }
                Spacer()
                Toggle("", isOn: learnBinding)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Beers.cream, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
            .padding(.top, 4)
        }
        .padding(.top, 14)
    }

    // MARK: Step 4 — first pour

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
                ForEach(0..<4, id: \.self) { index in
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
                case 2:
                    Button(learnBinding.wrappedValue ? "Sounds good →" : "No thanks →") { step = 3 }
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

/// Three amber bubbles rising in turn — the brand's stand-in for a spinner
/// while we poll for the grant to land.
private struct WatchingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Beers.amber)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Beers.ink, lineWidth: 1))
                    .offset(y: animating ? -3 : 2)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.14),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

/// The draggable bottle: a Beers badge the user drags straight into the
/// System Settings permission list, ChatGPT-style. The drag payload is the
/// app bundle's file URL, which the TCC lists accept as a drop — no + button,
/// no file picker.
private struct DraggableAppBadge: View {
    @State private var wiggle = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Beers.paper)
                    .frame(width: 76, height: 76)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Beers.ink, lineWidth: 2.5)
                    )
                    .shadow(color: Beers.ink.opacity(0.35), radius: 0, x: 3, y: 3)
                BeersMenuBadge(size: 58)
                AppBundleDragSource()
                    .frame(width: 76, height: 76)
            }
            .rotationEffect(.degrees(wiggle ? -3 : 3))
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: wiggle)
            .onAppear { wiggle = true }

            Text("DRAG ME")
                .font(Beers.display(10))
                .foregroundStyle(Beers.paper)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Beers.amber, in: Capsule())
                .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 1.5))
        }
    }
}

/// Transparent AppKit layer that turns the badge into a real Finder-grade
/// drag source for the app bundle. SwiftUI's onDrag can't reliably feed the
/// System Settings TCC lists; an NSDraggingSession with the bundle URL can.
private struct AppBundleDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> AppBundleDragView {
        AppBundleDragView()
    }

    func updateNSView(_ nsView: AppBundleDragView, context: Context) {}
}

final class AppBundleDragView: NSView, NSDraggingSource {
    override func mouseDragged(with event: NSEvent) {
        let bundleURL = Bundle.main.bundleURL
        let draggingItem = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 64, height: 64)
        draggingItem.setDraggingFrame(
            NSRect(x: bounds.midX - 32, y: bounds.midY - 32, width: 64, height: 64),
            contents: icon
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        llog("FirstRound: dragging app bundle out to System Settings")
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic, .link] : []
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
