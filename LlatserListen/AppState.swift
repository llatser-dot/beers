import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    enum Status: Equatable {
        case loading
        case ready
        case recording
        case transcribing
        case error(String)

        var label: String {
            switch self {
            case .loading: return "Preparing"
            case .ready: return "Ready"
            case .recording: return "Listening"
            case .transcribing: return "Processing"
            case .error: return "Attention"
            }
        }
    }

    private enum PermissionCopy {
        static let microphone = "Microphone permission is required."
        static let inputMonitoring = "Enable Input Monitoring for the push-to-talk hotkey."
        static let accessibility = "Enable Accessibility to paste automatically."
        static let clipboardFallback = "Text copied to clipboard. Enable Accessibility to auto-paste."
    }

    @Published var status: Status = .ready
    @Published var engineChoice: DictationEngine {
        didSet {
            UserDefaults.standard.set(engineChoice.rawValue, forKey: "engineChoice")
            loadSelectedEngine(showLoadingUI: true)
        }
    }
    @Published var loadingMessage = "Preparing Parakeet..."
    @Published var modelProgress: Double = 0
    @Published var lastTranscription = ""
    @Published var lastTargetApp = "Current app"
    @Published var polishBeforePaste: Bool {
        didSet {
            UserDefaults.standard.set(polishBeforePaste, forKey: "polishBeforePaste")
        }
    }
    @Published var writingMode: WritingMode {
        didSet {
            UserDefaults.standard.set(writingMode.rawValue, forKey: "writingMode")
        }
    }
    @Published var cleanSpeechScaffolding: Bool {
        didSet {
            UserDefaults.standard.set(cleanSpeechScaffolding, forKey: "cleanSpeechScaffolding")
        }
    }
    @Published var collapseRepeats: Bool {
        didSet {
            UserDefaults.standard.set(collapseRepeats, forKey: "collapseRepeats")
        }
    }
    @Published var smartCapitalization: Bool {
        didSet {
            UserDefaults.standard.set(smartCapitalization, forKey: "smartCapitalization")
        }
    }
    @Published var normalizeLinks: Bool {
        didSet {
            UserDefaults.standard.set(normalizeLinks, forKey: "normalizeLinks")
        }
    }
    @Published var removeTrailingFullStop: Bool {
        didSet {
            UserDefaults.standard.set(removeTrailingFullStop, forKey: "removeTrailingFullStop")
        }
    }
    @Published var adaptiveTone: Bool {
        didSet {
            UserDefaults.standard.set(adaptiveTone, forKey: "adaptiveTone")
        }
    }
    @Published var addSpaceAfterPaste: Bool {
        didSet {
            UserDefaults.standard.set(addSpaceAfterPaste, forKey: "addSpaceAfterPaste")
        }
    }
    @Published var aiRewriteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(aiRewriteEnabled, forKey: "aiRewriteEnabled")
        }
    }
    @Published var aiRewriteEndpoint: String {
        didSet {
            UserDefaults.standard.set(aiRewriteEndpoint, forKey: "aiRewriteEndpoint")
        }
    }
    @Published var aiRewriteModel: String {
        didSet {
            UserDefaults.standard.set(aiRewriteModel, forKey: "aiRewriteModel")
        }
    }
    @Published var suppressComputerAudio: Bool {
        didSet {
            UserDefaults.standard.set(suppressComputerAudio, forKey: "suppressComputerAudio")
            audioRecorder.setSuppressComputerAudio(suppressComputerAudio)
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                llog("AppState: launch at login \(launchAtLogin ? "enabled" : "disabled")")
            } catch {
                llog("AppState: launch at login change failed: \(error.localizedDescription)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var hotkeyChoice: HotkeyOption {
        didSet {
            UserDefaults.standard.set(hotkeyChoice.rawValue, forKey: "hotkeyChoice")
            hotkeyManager.setOption(hotkeyChoice)
        }
    }
    @Published var vocabularyCorrections: [VocabularyCorrection] {
        didSet {
            VocabularyCorrections.save(vocabularyCorrections)
        }
    }
    /// One-tap vocabulary suggestions mined from the user's own keyboard fixes.
    /// Populated by `refreshVocabularySuggestions()` when Brew Controls opens.
    @Published var vocabularySuggestions: [VocabularySuggestion] = []
    @Published var clinkOnServe: Bool {
        didSet {
            UserDefaults.standard.set(clinkOnServe, forKey: "clinkOnServe")
        }
    }
    @Published var commandModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(commandModeEnabled, forKey: "commandModeEnabled")
        }
    }
    /// Flywheel learning opt-out (absent key == enabled). Read directly from
    /// UserDefaults by FlywheelLog/OrderKitchen; these mirror the same keys so
    /// the Brew Controls / First Round toggles have a single source of truth.
    @Published var flywheelLoggingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(flywheelLoggingEnabled, forKey: "flywheelLoggingEnabled")
        }
    }
    @Published var correctionWatcherEnabled: Bool {
        didSet {
            UserDefaults.standard.set(correctionWatcherEnabled, forKey: "correctionWatcherEnabled")
        }
    }
    @Published var bouncerShadowEnabled: Bool {
        didSet {
            UserDefaults.standard.set(bouncerShadowEnabled, forKey: "bouncerShadowEnabled")
        }
    }
    @Published var hudPosition: HUDPosition {
        didSet {
            UserDefaults.standard.set(hudPosition.rawValue, forKey: "hudPosition")
        }
    }
    let pourStore = PourStore()
    let appRecipeStore = AppRecipeStore()
    /// The last non-Beers app where a real pour began. Brew Controls only
    /// offers this explicit target; opening settings cannot target Beers.
    @Published private(set) var recipeTargetContext: ActiveAppContext?

    // Command Mode (an "order"): rewrite the selected text with a spoken instruction.
    private var isCommandOrder = false
    private var orderSelection = ""
    @Published var microphoneGranted: Bool
    @Published var inputMonitoringGranted: Bool
    @Published var accessibilityGranted: Bool

    private let audioRecorder = AudioRecorder()
    private let transcriptionEngine = TranscriptionEngine()
    private let hotkeyManager = HotkeyManager()
    private let textPaster = TextPaster()
    private let overlay = OverlayWindowController()
    let correctionWatcher = CorrectionWatcher()
    private var permissionMonitor: Timer?
    private var loadTask: Task<Void, Error>?
    private var isRecording = false
    private var activePourContext: ActiveAppContext?
    private var activePourPreferences: WritingPreferences?

    // Re-dictation detector: the previous ordinary pour, so a fresh pour that
    // closely echoes it soon after serving can mark it superseded.
    private var lastPourTs: String?
    private var lastPourRaw = ""
    private var lastPourServedAt = Date.distantPast

    var errorMessage: String? {
        if case .error(let message) = status {
            return message
        }
        return nil
    }

    var engineLoaded: Bool {
        transcriptionEngine.loadedEngine == engineChoice
    }

    var writingPreferences: WritingPreferences {
        WritingPreferences(
            mode: writingMode,
            cleanSpeechScaffolding: cleanSpeechScaffolding,
            collapseRepeats: collapseRepeats,
            smartCapitalization: smartCapitalization,
            normalizeLinks: normalizeLinks,
            removeTrailingFullStop: removeTrailingFullStop,
            adaptiveTone: adaptiveTone,
            addSpaceAfterPaste: addSpaceAfterPaste,
            aiRewrite: AIRewriteSettings(
                isEnabled: aiRewriteEnabled,
                endpoint: aiRewriteEndpoint,
                model: aiRewriteModel
            )
        )
    }

    private func resolvedWritingPreferences(for context: ActiveAppContext) -> WritingPreferences {
        var preferences = writingPreferences
        let recipeSettings = appRecipeStore.settings(
            for: context,
            globalWritingMode: preferences.mode,
            globalAddSpaceAfterPaste: preferences.addSpaceAfterPaste
        )
        preferences.mode = recipeSettings.writingMode
        preferences.addSpaceAfterPaste = recipeSettings.addSpaceAfterPaste
        if appRecipeStore.recipe(for: context) != nil {
            // An explicit recipe writing mode must remain effective even when
            // the global automatic-tone switch is off.
            preferences.adaptiveTone = true
        }
        return preferences
    }

    init() {
        VocabularyCorrections.ensureSeeded()

        let savedEngine = UserDefaults.standard.string(forKey: "engineChoice")
        self.engineChoice = DictationEngine.savedValue(savedEngine)
        self.polishBeforePaste = Self.boolDefaultTrue(forKey: "polishBeforePaste")
        let savedWritingMode = UserDefaults.standard.string(forKey: "writingMode")
        self.writingMode = WritingMode(rawValue: savedWritingMode ?? "") ?? WritingPreferences.defaults.mode
        self.cleanSpeechScaffolding = Self.boolDefaultTrue(forKey: "cleanSpeechScaffolding")
        self.collapseRepeats = Self.boolDefaultTrue(forKey: "collapseRepeats")
        self.smartCapitalization = Self.boolDefaultTrue(forKey: "smartCapitalization")
        self.normalizeLinks = Self.boolDefaultTrue(forKey: "normalizeLinks")
        self.removeTrailingFullStop = Self.boolDefaultTrue(forKey: "removeTrailingFullStop")
        self.adaptiveTone = Self.boolDefaultTrue(forKey: "adaptiveTone")
        self.addSpaceAfterPaste = UserDefaults.standard.bool(forKey: "addSpaceAfterPaste")
        self.aiRewriteEnabled = UserDefaults.standard.bool(forKey: "aiRewriteEnabled")
        self.aiRewriteEndpoint = UserDefaults.standard.string(forKey: "aiRewriteEndpoint") ?? AIRewriteSettings.defaults.endpoint
        self.aiRewriteModel = UserDefaults.standard.string(forKey: "aiRewriteModel") ?? AIRewriteSettings.defaults.model
        self.suppressComputerAudio = Self.boolDefaultTrue(forKey: "suppressComputerAudio")
        self.clinkOnServe = Self.boolDefaultTrue(forKey: "clinkOnServe")
        self.commandModeEnabled = Self.boolDefaultTrue(forKey: "commandModeEnabled")
        self.flywheelLoggingEnabled = Self.boolDefaultTrue(forKey: "flywheelLoggingEnabled")
        self.correctionWatcherEnabled = Self.boolDefaultTrue(forKey: "correctionWatcherEnabled")
        self.bouncerShadowEnabled = Self.boolDefaultTrue(forKey: "bouncerShadowEnabled")
        self.hudPosition = HUDPosition.current
        self.hotkeyChoice = HotkeyOption.savedValue(UserDefaults.standard.string(forKey: "hotkeyChoice"))

        // Launch at login is opt-in from Brew Controls; first launch must not
        // silently add a persistent login item.
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.vocabularyCorrections = VocabularyCorrections.load()
        self.microphoneGranted = Permissions.isMicrophoneGranted()
        self.inputMonitoringGranted = Permissions.isInputMonitoringGranted()
        self.accessibilityGranted = Permissions.isAccessibilityGranted()
        self.recipeTargetContext = nil

        audioRecorder.setSuppressComputerAudio(suppressComputerAudio)
        setupHotkey()
        startPermissionMonitor()
        loadSelectedEngine(showLoadingUI: false)

        // Fast learning loop: the moment a hand-correction is harvested, try to
        // auto-teach it if it's a recurring brand/name fix (see autoLearnVocabulary).
        correctionWatcher.onCorrectionRecorded = { [weak self] in
            self?.autoLearnVocabulary()
        }

        MainWindowPresenter.shared.appStateProvider = { [weak self] in self }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            BeersSnapshot.runIfRequested(appState: self)
            BeersSnapshot.runPasteTestIfRequested()
            BeersSnapshot.runCorrectionTestIfRequested(appState: self)
            BeersSnapshot.runOrderTestIfRequested(appState: self)
            BeersSnapshot.runPolishTestIfRequested(appState: self)
            BeersSnapshot.runBouncerTestIfRequested()
            BeersSnapshot.runVocabSuggestTestIfRequested(appState: self)
            BeersSnapshot.runWipeTestIfRequested()
        }
    }

    func refreshPermissions() {
        microphoneGranted = Permissions.isMicrophoneGranted()
        inputMonitoringGranted = Permissions.isInputMonitoringGranted()
        accessibilityGranted = Permissions.isAccessibilityGranted()
    }

    func requestMicrophonePermission() {
        switch Permissions.microphoneStatus() {
        case .authorized:
            reconcilePermissions()
        case .notDetermined:
            Task { @MainActor [weak self] in
                let granted = await Permissions.requestMicrophone()
                self?.microphoneGranted = granted
                self?.reconcilePermissions()
            }
        case .denied:
            Permissions.openMicrophoneSettings()
        }
    }

    func requestInputMonitoringPermission() {
        let granted = Permissions.requestInputMonitoring()
        reconcilePermissions()
        if granted || inputMonitoringGranted {
            // Even when System Settings already shows ON, the running process
            // often still sees false until relaunch. Prefer relaunch over a
            // half-working hotkey registration.
            if hotkeyManager.isRegistered {
                return
            }
            Permissions.relaunchApp()
            return
        }
        Permissions.openInputMonitoringSettings()
    }

    func requestAccessibilityPermission() {
        let granted = Permissions.requestAccessibility(prompt: true)
        reconcilePermissions()
        if granted || accessibilityGranted {
            return
        }
        Permissions.openAccessibilitySettings()
    }

    func relaunchToApplyPermissions() {
        Permissions.relaunchApp()
    }

    func manualRecordToggle() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording(fromHotkey: false, commandMode: false)
        }
    }

    func addVocabularyCorrection(heard: String, replacement: String) {
        let cleanedHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedHeard.isEmpty, !cleanedReplacement.isEmpty else { return }

        if let index = vocabularyCorrections.firstIndex(where: { $0.heard.caseInsensitiveCompare(cleanedHeard) == .orderedSame }) {
            vocabularyCorrections[index].replacement = cleanedReplacement
            return
        }

        vocabularyCorrections.append(VocabularyCorrection(heard: cleanedHeard, replacement: cleanedReplacement))
    }

    func removeVocabularyCorrection(_ correction: VocabularyCorrection) {
        vocabularyCorrections.removeAll { $0.id == correction.id }
    }

    /// Re-scan the flywheel for correction-driven vocabulary suggestions. Reads
    /// off the main thread; the scan is file-signature cached so this is cheap
    /// unless the log actually changed since the last open.
    func refreshVocabularySuggestions() {
        let existing = vocabularyCorrections
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = VocabularySuggestions.suggestions(
                existing: existing,
                dismissed: VocabularySuggestions.dismissedKeys()
            )
            DispatchQueue.main.async {
                guard let self else { return }
                if self.vocabularySuggestions != found {
                    self.vocabularySuggestions = found
                }
            }
        }
    }

    /// Accept a suggestion: teach the word (user tap only — never automatic),
    /// then drop it from the live list. Also dismissed so it can't resurface.
    func acceptVocabularySuggestion(_ suggestion: VocabularySuggestion) {
        addVocabularyCorrection(heard: suggestion.heard, replacement: suggestion.replacement)
        VocabularySuggestions.dismiss(suggestion)
        vocabularySuggestions.removeAll { $0.id == suggestion.id }
    }

    /// Dismiss a suggestion for good.
    func dismissVocabularySuggestion(_ suggestion: VocabularySuggestion) {
        VocabularySuggestions.dismiss(suggestion)
        vocabularySuggestions.removeAll { $0.id == suggestion.id }
    }

    /// The fast learning loop. Called right after a hand-correction is harvested.
    /// Promotes any correction-driven vocabulary suggestion that already cleared
    /// the manual bar — recurred >= 2x, reads as a brand/name (not grammar or
    /// casing), phonetically/orthographically related — straight into the live
    /// dictionary, automatically. This is the same conservative filter the manual
    /// Brew Controls suggestions use (VocabularySuggestions.suggestions), just
    /// applied without waiting for a tap the user never makes.
    ///
    /// Fully reversible and local: each learned word lands in the normal
    /// dictionary (removable in Brew Controls) and nothing leaves the Mac. A brief
    /// HUD flash tells the user what was learned, but only when idle so it never
    /// competes with a live pour.
    func autoLearnVocabulary() {
        // Respect the capture kill switch, and an optional auto-learn opt-out
        // (defaults ON — this is the whole point of the feature).
        guard correctionWatcherEnabled else { return }
        guard Self.boolDefaultTrue(forKey: "autoLearnVocabularyEnabled") else { return }

        let existing = vocabularyCorrections
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // The correction that triggered us is written via queue.async, so it
            // may not be on disk yet. Wait for pending appends before scanning,
            // otherwise the fix that just hit count 2 is missed until next time.
            FlywheelLog.flush()
            let found = VocabularySuggestions.suggestions(
                existing: existing,
                dismissed: VocabularySuggestions.dismissedKeys(),
                limit: 10
            )
            guard !found.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                var learned: [VocabularySuggestion] = []
                for s in found {
                    // Re-check against the current dictionary on the main thread —
                    // it may have changed since the background scan started.
                    let taken = self.vocabularyCorrections.contains {
                        $0.heard.caseInsensitiveCompare(s.heard) == .orderedSame
                            || $0.replacement.lowercased() == s.replacement.lowercased()
                    }
                    if taken { continue }
                    self.addVocabularyCorrection(heard: s.heard, replacement: s.replacement)
                    VocabularySuggestions.dismiss(s)   // don't also surface it manually
                    self.vocabularySuggestions.removeAll { $0.id == s.id }
                    llog("AppState: auto-learned vocabulary '\(s.heard)' -> '\(s.replacement)' (seen \(s.count)x)")
                    learned.append(s)
                }
                guard let first = learned.first else { return }
                // Only flash the HUD when nothing is pouring, so we never stomp
                // the pouring/settling/served overlay.
                if self.status == .ready {
                    let msg = learned.count == 1
                        ? "Learned: \(first.replacement)"
                        : "Learned \(learned.count) words, incl. \(first.replacement)"
                    self.overlay.show(mode: .notice(msg))
                    self.overlay.hide(after: 2.0)
                }
            }
        }
    }

    func resetWritingPreferences() {
        let defaults = WritingPreferences.defaults
        AITranscriptRewriter.revokeRemoteEndpointApproval()
        polishBeforePaste = true
        writingMode = defaults.mode
        cleanSpeechScaffolding = defaults.cleanSpeechScaffolding
        collapseRepeats = defaults.collapseRepeats
        smartCapitalization = defaults.smartCapitalization
        normalizeLinks = defaults.normalizeLinks
        removeTrailingFullStop = defaults.removeTrailingFullStop
        adaptiveTone = defaults.adaptiveTone
        addSpaceAfterPaste = defaults.addSpaceAfterPaste
        aiRewriteEnabled = defaults.aiRewrite.isEnabled
        aiRewriteEndpoint = defaults.aiRewrite.endpoint
        aiRewriteModel = defaults.aiRewrite.model
        suppressComputerAudio = true
    }

    func loadSelectedEngine(showLoadingUI: Bool = true) {
        if transcriptionEngine.loadedEngine == engineChoice {
            loadingMessage = ""
            reconcilePermissions()
            return
        }

        if let loadTask {
            loadTask.cancel()
            self.loadTask = nil
        }

        let selected = engineChoice
        if showLoadingUI {
            status = .loading
        }
        loadingMessage = "Preparing \(selected.displayName)..."
        modelProgress = 0

        let engine = transcriptionEngine
        let appState = self
        let task = Task.detached(priority: showLoadingUI ? .userInitiated : .utility) { [weak appState] in
            guard let appState else { return }
            try await engine.load(selected) { progress, message in
                Task { @MainActor [weak appState] in
                    guard let appState, appState.engineChoice == selected else { return }
                    appState.modelProgress = progress
                    appState.loadingMessage = message
                }
            }
        }
        loadTask = task

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await task.value
                if self.loadTask == task {
                    self.loadTask = nil
                }
                llog("AppState: loaded \(selected.displayName)")
                self.loadingMessage = ""
                self.modelProgress = 1
                if self.status == .loading {
                    self.status = .ready
                }
                self.reconcilePermissions()
            } catch is CancellationError {
                llog("AppState: cancelled load for \(selected.displayName)")
            } catch {
                if self.loadTask == task {
                    self.loadTask = nil
                }
                llog("AppState: model load failed: \(error.localizedDescription)")
                guard self.engineChoice == selected else { return }
                self.loadingMessage = ""
                self.modelProgress = 0
                if selected != .parakeetV3 {
                    llog("AppState: falling back to Parakeet v3 after \(selected.displayName) load failure")
                    self.engineChoice = .parakeetV3
                    self.loadingMessage = "Falling back to Parakeet v3..."
                    return
                }
                self.status = .error("Could not load \(selected.displayName). Check the log or network and try again.")
            }
        }
    }

    private func setupHotkey() {
        hotkeyManager.setOption(hotkeyChoice)
        hotkeyManager.onKeyDown = { [weak self] shiftHeld in
            guard let self else { return }
            let commandMode = shiftHeld && self.commandModeEnabled
            llog("Hotkey: DOWN\(commandMode ? " (order)" : "")")
            self.startRecording(fromHotkey: true, commandMode: commandMode)
        }
        hotkeyManager.onKeyUp = { [weak self] in
            llog("Hotkey: UP")
            self?.stopRecordingAndTranscribe()
        }
        hotkeyManager.register()
        refreshPermissions()
    }

    private var didSchedulePermissionRelaunch = false

    private func startPermissionMonitor() {
        permissionMonitor?.invalidate()
        permissionMonitor = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcilePermissions()
            }
        }
    }

    private func reconcilePermissions() {
        let previousMic = microphoneGranted
        let previousInput = inputMonitoringGranted
        let previousAccessibility = accessibilityGranted
        refreshPermissions()

        if microphoneGranted != previousMic
            || inputMonitoringGranted != previousInput
            || accessibilityGranted != previousAccessibility {
            llog(
                "Permissions: mic=\(microphoneGranted) inputMonitoring=\(inputMonitoringGranted) accessibility=\(accessibilityGranted) hotkeyRegistered=\(hotkeyManager.isRegistered)"
            )
        }

        // Input Monitoring / Accessibility flips often only take effect after
        // relaunch. If the user just enabled one in System Settings, bounce
        // the process so the grant actually applies to this binary.
        let inputJustGranted = inputMonitoringGranted && !previousInput
        let accessibilityJustGranted = accessibilityGranted && !previousAccessibility
        if (inputJustGranted || accessibilityJustGranted) && !didSchedulePermissionRelaunch {
            didSchedulePermissionRelaunch = true
            llog("Permissions: grant detected — relaunching so TCC applies to this process")
            Permissions.relaunchApp()
            return
        }

        if inputMonitoringGranted && !hotkeyManager.isRegistered {
            hotkeyManager.register()
        }

        guard status != .loading, status != .recording, status != .transcribing else {
            return
        }

        if !microphoneGranted {
            status = .error(PermissionCopy.microphone)
            return
        }

        if !accessibilityGranted {
            status = .error(PermissionCopy.accessibility)
            return
        }

        if !inputMonitoringGranted {
            status = .error(PermissionCopy.inputMonitoring)
            return
        }

        status = .ready
    }

    private func ensureEngineLoaded() async throws {
        guard transcriptionEngine.loadedEngine != engineChoice else { return }
        let selected = engineChoice
        loadSelectedEngine(showLoadingUI: true)
        if let loadTask {
            do {
                try await loadTask.value
            } catch {
                if selected != .parakeetV3 {
                    if engineChoice == selected {
                        engineChoice = .parakeetV3
                    }
                    if transcriptionEngine.loadedEngine == .parakeetV3 {
                        return
                    }
                    if let fallbackTask = self.loadTask, engineChoice == .parakeetV3 {
                        try await fallbackTask.value
                        return
                    }
                }
                throw error
            }
        }
    }

    private func startRecording(fromHotkey: Bool, commandMode: Bool = false) {
        guard status != .loading, status != .recording, status != .transcribing else {
            llog("AppState: start skipped, status=\(status.label)")
            return
        }

        // A new pour supersedes any correction watch on the previous one.
        correctionWatcher.stop()

        isCommandOrder = commandMode
        orderSelection = ""
        if commandMode {
            // Grab the selection while the mic spins up.
            SelectionReader.selectedText { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.orderSelection = text
                }
            }
        }

        if fromHotkey && !inputMonitoringGranted {
            llog("AppState: hotkey start skipped, Input Monitoring is not granted")
            status = .error(PermissionCopy.inputMonitoring)
            requestInputMonitoringPermission()
            return
        }

        refreshPermissions()
        guard microphoneGranted else {
            status = .error(PermissionCopy.microphone)
            requestMicrophonePermission()
            return
        }

        // Resolve the target and its recipe exactly once. The user can switch
        // apps while Beers transcribes without changing this pour's behaviour.
        let context = ActiveAppContext.frontmost
        let preferences = resolvedWritingPreferences(for: context)

        do {
            // Duck + overlay first for instant feedback; capture uses a warm engine when possible.
            try audioRecorder.startRecording()
            isRecording = true
            activePourContext = context
            activePourPreferences = preferences
            if context.recipeBundleIdentifier != nil {
                recipeTargetContext = context
            }
            status = .recording
            LiveMicLevel.shared.reset()
            overlay.show(mode: isCommandOrder ? .takingOrder : .pouring)
            // Command Mode always uses the model, so prewarm for it too.
            if preferences.aiRewrite.isEnabled || isCommandOrder {
                OrderKitchen.prewarmPolish(settings: preferences.aiRewrite)
            }
            Beers.popCap()
            llog("AppState: recording started\(isCommandOrder ? " (order)" : "")")
        } catch {
            llog("AppState: record failed: \(error.localizedDescription)")
            status = .error("Mic error: \(error.localizedDescription)")
            overlay.hide()
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        let audio = audioRecorder.stopRecording()
        // Tear down immediately so the menu-bar mic indicator goes off.
        audioRecorder.stopEngine()
        isRecording = false
        let context = activePourContext ?? ActiveAppContext.frontmost
        let preferences = activePourPreferences ?? resolvedWritingPreferences(for: context)
        activePourContext = nil
        activePourPreferences = nil

        let duration = Float(audio.count) / 16000.0
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(max(1, audio.count)))

        guard duration >= 0.3 else {
            llog("AppState: audio too short (\(String(format: "%.2f", duration))s)")
            status = .ready
            overlay.hide()
            return
        }

        // Threshold is on post-gain audio. Keep a floor so pure silence still drops.
        guard rms >= 0.0004 else {
            llog("AppState: audio too quiet (RMS=\(String(format: "%.4f", rms)))")
            status = .ready
            overlay.hide()
            return
        }

        let isOrder = isCommandOrder
        isCommandOrder = false
        status = .transcribing
        overlay.show(mode: isOrder ? .workingOrder : .settling)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ensureEngineLoaded()
                let text = try await self.transcriptionEngine.transcribe(audio)
                self.status = .ready

                guard !text.isEmpty else {
                    llog("AppState: empty transcription")
                    self.overlay.hide()
                    self.reconcilePermissions()
                    return
                }

                if isOrder, !self.orderSelection.isEmpty {
                    await self.serveOrder(
                        instruction: text,
                        duration: TimeInterval(duration),
                        context: context
                    )
                    return
                }

                self.lastTargetApp = context.name

                var outputText: String
                let rulePolished: String?
                let resolvedMode = preferences.mode == .automatic ? context.inferredWritingMode : preferences.mode
                if self.polishBeforePaste {
                    outputText = TranscriptPolisher.polish(
                        text,
                        options: preferences.polisherOptions,
                        context: context
                    )
                    rulePolished = outputText
                    llog("AppState: polished transcription='\(outputText)'")
                } else {
                    outputText = text
                    rulePolished = nil
                }
                // Track which tier serves + the tier-0 shadow verdict for the
                // flywheel. When AI rewrite is off, no model or shadow runs.
                var servingTier: ServingTier = .ruleFallback
                var bouncerShadow: BouncerVerdict? = nil
                if preferences.aiRewrite.isEnabled {
                    let result = await OrderKitchen.polish(
                        outputText,
                        detectOn: text,
                        mode: resolvedMode,
                        context: context,
                        settings: preferences.aiRewrite
                    )
                    outputText = result.text
                    servingTier = result.tier
                    bouncerShadow = result.shadow
                    llog("AppState: AI-polished transcription='\(outputText)' [tier=\(result.tier.rawValue)]")
                }
                let vocabularyFinal = VocabularyCorrections.apply(to: outputText)
                if vocabularyFinal != outputText {
                    outputText = vocabularyFinal
                    llog("AppState: vocabulary corrections re-applied='\(outputText)'")
                }
                if preferences.addSpaceAfterPaste, !outputText.hasSuffix(" ") {
                    outputText += " "
                }
                self.lastTranscription = outputText

                let pour = Pour(
                    text: outputText.trimmingCharacters(in: .whitespacesAndNewlines),
                    appName: context.name,
                    duration: TimeInterval(duration)
                )
                self.pourStore.add(pour)

                // Flywheel: capture this real (raw -> served) pair locally for
                // future Bouncer retraining. Fire-and-forget; never blocks the
                // pour. Command Mode is excluded (handled by serveOrder).
                // Beers never transmits these records (see FlywheelLog).
                let pourTs = FlywheelLog.record(
                    raw: text,
                    rulePolished: rulePolished,
                    served: outputText,
                    tier: servingTier.rawValue,
                    bouncerWouldDelete: bouncerShadow?.deletedIndices,
                    bouncerMs: bouncerShadow?.elapsedMillis
                )

                // Re-dictation detector: a fresh pour that closely echoes the
                // last one, soon after it served, means the user re-said it
                // rather than keeping it — mark the previous record superseded.
                if let prevTs = self.lastPourTs, let newTs = pourTs {
                    let dt = Date().timeIntervalSince(self.lastPourServedAt)
                    if dt <= 20, Self.jaccard(self.lastPourRaw, text) >= 0.5 {
                        FlywheelLog.recordRedictation(pourTs: prevTs, newPourTs: newTs)
                        llog("AppState: re-dictation detected (Jaccard>=0.5, \(String(format: "%.1f", dt))s) — pour \(prevTs) superseded")
                    }
                }
                if let newTs = pourTs {
                    self.lastPourTs = newTs
                    self.lastPourRaw = text
                    self.lastPourServedAt = Date()
                }

                let pasted = self.textPaster.paste(outputText)
                if pasted {
                    self.overlay.show(mode: .served(words: pour.words))
                    self.overlay.hide(after: 1.0)
                    Beers.clink()
                    // Watch for the user's keyboard corrections to this pour.
                    if let ts = pourTs {
                        self.correctionWatcher.start(servedText: outputText, pourTs: ts)
                    }
                } else {
                    self.overlay.hide()
                    self.status = .error(PermissionCopy.clipboardFallback)
                }
                self.reconcilePermissions()
            } catch {
                llog("AppState: transcription failed: \(error.localizedDescription)")
                self.status = .error("Transcription failed: \(error.localizedDescription)")
                self.overlay.hide(after: 0.2)
            }
        }
    }

    /// Command Mode serve: apply the spoken instruction to the captured
    /// selection via the local model, then paste over the selection.
    private func serveOrder(
        instruction: String,
        duration: TimeInterval,
        context: ActiveAppContext
    ) async {
        let selection = orderSelection
        orderSelection = ""
        llog("AppState: order '\(instruction)' on \(selection.count) selected chars")
        overlay.show(mode: .workingOrder)

        let settings = AIRewriteSettings(
            isEnabled: true,
            endpoint: aiRewriteEndpoint,
            model: aiRewriteModel
        )

        do {
            let edited = try await OrderKitchen.applyInstruction(
                instruction,
                to: String(selection.prefix(12_000)),
                settings: settings
            )
            lastTargetApp = context.name
            lastTranscription = edited

            let pour = Pour(
                text: edited.trimmingCharacters(in: .whitespacesAndNewlines),
                appName: context.name,
                duration: duration
            )
            pourStore.add(pour)

            let pasted = textPaster.paste(edited)
            if pasted {
                overlay.show(mode: .served(words: pour.words))
                overlay.hide(after: 1.0)
                Beers.clink()
            } else {
                overlay.hide()
                status = .error("Order copied to clipboard — enable Accessibility to paste.")
            }
        } catch {
            llog("AppState: order failed: \(error.localizedDescription)")
            overlay.show(mode: .notice("Kitchen's closed — no on-device or local model"))
            overlay.hide(after: 1.8)
        }
        reconcilePermissions()
    }

    private func fixCurrentPermissionIssue() {
        if !microphoneGranted {
            requestMicrophonePermission()
            return
        }
        if !inputMonitoringGranted {
            requestInputMonitoringPermission()
            return
        }
        if !accessibilityGranted {
            requestAccessibilityPermission()
        }
    }

    /// Word-set Jaccard overlap of two raw transcripts (lowercased). Used to
    /// spot a re-dictation of the same thought.
    private static func jaccard(_ a: String, _ b: String) -> Double {
        let wa = Set(a.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        let wb = Set(b.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        if wa.isEmpty || wb.isEmpty { return 0 }
        let inter = wa.intersection(wb).count
        let uni = wa.union(wb).count
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }

    private static func boolDefaultTrue(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
