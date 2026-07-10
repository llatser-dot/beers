import AVFAudio
import AppKit
import ApplicationServices

enum Permissions {
    enum MicrophoneStatus: String {
        case authorized
        case notDetermined
        case denied
    }

    static func microphoneStatus() -> MicrophoneStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return .authorized
        case .undetermined:
            return .notDetermined
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    static func isMicrophoneGranted() -> Bool {
        microphoneStatus() == .authorized
    }

    static func requestMicrophone() async -> Bool {
        let status = microphoneStatus()
        llog("Permissions: microphone status before request=\(status.rawValue)")

        guard status == .notDetermined else {
            return isMicrophoneGranted()
        }

        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                llog("Permissions: microphone request returned granted=\(granted)")
                continuation.resume(returning: granted)
            }
        }
    }

    static func isInputMonitoringGranted() -> Bool {
        // macOS often keeps this false until the process is fully relaunched
        // after the System Settings toggle is flipped.
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func isAccessibilityGranted() -> Bool {
        // Prefer the AX trust bit; PostEvent is a useful secondary signal for paste.
        AXIsProcessTrusted() || CGPreflightPostEventAccess()
    }

    @discardableResult
    static func requestAccessibility(prompt: Bool) -> Bool {
        let axGranted: Bool
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            axGranted = AXIsProcessTrustedWithOptions(options)
        } else {
            axGranted = AXIsProcessTrusted()
        }
        let postGranted = prompt ? CGRequestPostEventAccess() : CGPreflightPostEventAccess()
        return axGranted || postGranted
    }

    /// Input Monitoring / Accessibility grants frequently do not apply to the
    /// already-running process. Relaunch so TCC re-evaluates this binary.
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                llog("Permissions: relaunch failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    static func openMicrophoneSettings() {
        openSystemSettingsPane("Privacy_Microphone")
    }

    static func openInputMonitoringSettings() {
        openSystemSettingsPane("Privacy_ListenEvent")
    }

    static func openAccessibilitySettings() {
        openSystemSettingsPane("Privacy_Accessibility")
    }

    private static func openSystemSettingsPane(_ pane: String) {
        // Prefer modern System Settings deep links; fall back to legacy pref pane URLs.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(pane)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
