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
    let pourStore = PourStore()

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
    private var permissionMonitor: Timer?
    private var loadTask: Task<Void, Error>?
    private var isRecording = false

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
        self.hotkeyChoice = HotkeyOption.savedValue(UserDefaults.standard.string(forKey: "hotkeyChoice"))

        // Register as a login item once by default; the toggle stays in control after that.
        if !UserDefaults.standard.bool(forKey: "didAutoRegisterLoginItem"), SMAppService.mainApp.status != .enabled {
            UserDefaults.standard.set(true, forKey: "didAutoRegisterLoginItem")
            do {
                try SMAppService.mainApp.register()
                llog("AppState: auto-registered launch at login")
            } catch {
                llog("AppState: launch at login auto-registration failed: \(error.localizedDescription)")
            }
        }
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.vocabularyCorrections = VocabularyCorrections.load()
        self.microphoneGranted = Permissions.isMicrophoneGranted()
        self.inputMonitoringGranted = Permissions.isInputMonitoringGranted()
        self.accessibilityGranted = Permissions.isAccessibilityGranted()

        audioRecorder.setSuppressComputerAudio(suppressComputerAudio)
        setupHotkey()
        startPermissionMonitor()
        loadSelectedEngine(showLoadingUI: false)

        MainWindowPresenter.shared.appStateProvider = { [weak self] in self }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            BeersSnapshot.runIfRequested(appState: self)
            BeersSnapshot.runPasteTestIfRequested()
            BeersSnapshot.runOrderTestIfRequested(appState: self)
            BeersSnapshot.runPolishTestIfRequested(appState: self)
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

    func resetWritingPreferences() {
        let defaults = WritingPreferences.defaults
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

        do {
            // Duck + overlay first for instant feedback; capture uses a warm engine when possible.
            try audioRecorder.startRecording()
            isRecording = true
            status = .recording
            LiveMicLevel.shared.reset()
            overlay.show(mode: isCommandOrder ? .takingOrder : .pouring)
            if aiRewriteEnabled && !isCommandOrder {
                OrderKitchen.prewarmPolish()
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
                    await self.serveOrder(instruction: text, duration: TimeInterval(duration))
                    return
                }

                let context = ActiveAppContext.frontmost
                self.lastTargetApp = context.name

                var outputText: String
                let preferences = self.writingPreferences
                let resolvedMode = preferences.mode == .automatic ? context.inferredWritingMode : preferences.mode
                if self.polishBeforePaste {
                    outputText = TranscriptPolisher.polish(
                        text,
                        options: preferences.polisherOptions,
                        context: context
                    )
                    llog("AppState: polished transcription='\(outputText)'")
                } else {
                    outputText = text
                }
                if preferences.aiRewrite.isEnabled {
                    do {
                        outputText = try await OrderKitchen.polish(
                            outputText,
                            mode: resolvedMode,
                            context: context,
                            settings: preferences.aiRewrite
                        )
                        llog("AppState: AI-polished transcription='\(outputText)'")
                    } catch {
                        llog("AppState: AI polish failed, serving as-is: \(error.localizedDescription)")
                    }
                }
                let vocabularyFinal = VocabularyCorrections.apply(to: outputText)
                if vocabularyFinal != outputText {
                    outputText = vocabularyFinal
                    llog("AppState: vocabulary corrections re-applied='\(outputText)'")
                }
                if self.addSpaceAfterPaste, !outputText.hasSuffix(" ") {
                    outputText += " "
                }
                self.lastTranscription = outputText

                let pour = Pour(
                    text: outputText.trimmingCharacters(in: .whitespacesAndNewlines),
                    appName: context.name,
                    duration: TimeInterval(duration)
                )
                self.pourStore.add(pour)

                let pasted = self.textPaster.paste(outputText)
                if pasted {
                    self.overlay.show(mode: .served(words: pour.words))
                    self.overlay.hide(after: 1.0)
                    Beers.clink()
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
    private func serveOrder(instruction: String, duration: TimeInterval) async {
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
            let context = ActiveAppContext.frontmost
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

    private static func boolDefaultTrue(forKey key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }
}
