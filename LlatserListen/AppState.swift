import AppKit
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
            case .transcribing: return "Transcribing"
            case .error: return "Needs attention"
            }
        }
    }

    private enum PermissionCopy {
        static let microphone = "Microphone permission is required."
        static let inputMonitoring = "Enable Input Monitoring for the Right Option hotkey."
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

    init() {
        let savedEngine = UserDefaults.standard.string(forKey: "engineChoice")
        self.engineChoice = DictationEngine(rawValue: savedEngine ?? "") ?? .parakeet
        self.microphoneGranted = Permissions.isMicrophoneGranted()
        self.inputMonitoringGranted = Permissions.isInputMonitoringGranted()
        self.accessibilityGranted = Permissions.isAccessibilityGranted()

        setupHotkey()
        startPermissionMonitor()
        loadSelectedEngine(showLoadingUI: false)
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
        if granted {
            hotkeyManager.register()
        } else if !inputMonitoringGranted {
            Permissions.openInputMonitoringSettings()
        }
    }

    func requestAccessibilityPermission() {
        let granted = Permissions.requestAccessibility(prompt: true)
        reconcilePermissions()
        if !granted && !accessibilityGranted {
            Permissions.openAccessibilitySettings()
        }
    }

    func manualRecordToggle() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording(fromHotkey: false)
        }
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
        let task = Task.detached(priority: showLoadingUI ? .userInitiated : .utility) { [weak self] in
            try await engine.load(selected) { progress, message in
                Task { @MainActor [weak self] in
                    guard let self, self.engineChoice == selected else { return }
                    self.modelProgress = progress
                    self.loadingMessage = message
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
                self.status = .error("Could not load \(selected.displayName). Check the log or network and try again.")
            }
        }
    }

    private func setupHotkey() {
        hotkeyManager.onKeyDown = { [weak self] in
            llog("Hotkey: DOWN")
            self?.startRecording(fromHotkey: true)
        }
        hotkeyManager.onKeyUp = { [weak self] in
            llog("Hotkey: UP")
            self?.stopRecordingAndTranscribe()
        }
        hotkeyManager.register()
        refreshPermissions()
    }

    private func startPermissionMonitor() {
        permissionMonitor?.invalidate()
        permissionMonitor = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcilePermissions()
            }
        }
    }

    private func reconcilePermissions() {
        let hadInputMonitoring = inputMonitoringGranted
        refreshPermissions()

        if inputMonitoringGranted && (!hadInputMonitoring || !hotkeyManager.isRegistered) {
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
        loadSelectedEngine(showLoadingUI: true)
        if let loadTask {
            try await loadTask.value
        }
    }

    private func startRecording(fromHotkey: Bool) {
        guard status != .loading, status != .recording, status != .transcribing else {
            llog("AppState: start skipped, status=\(status.label)")
            return
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
            try audioRecorder.startRecording()
            isRecording = true
            status = .recording
            overlay.show(mode: .listening)
            llog("AppState: recording started")
        } catch {
            llog("AppState: record failed: \(error.localizedDescription)")
            status = .error("Mic error: \(error.localizedDescription)")
            overlay.hide()
        }
    }

    private func stopRecordingAndTranscribe() {
        guard isRecording else { return }

        let audio = audioRecorder.stopRecording()
        isRecording = false

        let duration = Float(audio.count) / 16000.0
        let rms = sqrt(audio.map { $0 * $0 }.reduce(0, +) / Float(max(1, audio.count)))

        guard duration >= 0.3 else {
            llog("AppState: audio too short (\(String(format: "%.2f", duration))s)")
            status = .ready
            overlay.hide()
            return
        }

        guard rms >= 0.001 else {
            llog("AppState: audio too quiet (RMS=\(String(format: "%.4f", rms)))")
            status = .ready
            overlay.hide()
            return
        }

        status = .transcribing
        overlay.show(mode: .processing)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.ensureEngineLoaded()
                let text = try await self.transcriptionEngine.transcribe(audio)
                self.status = .ready
                self.overlay.hide(after: 0.15)

                guard !text.isEmpty else {
                    llog("AppState: empty transcription")
                    self.reconcilePermissions()
                    return
                }

                self.lastTranscription = text
                let pasted = self.textPaster.paste(text)
                if !pasted {
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
}
