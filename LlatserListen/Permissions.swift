import AVFoundation
import AppKit
import ApplicationServices

enum Permissions {
    enum MicrophoneStatus {
        case authorized
        case notDetermined
        case denied
    }

    static func microphoneStatus() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    static func isMicrophoneGranted() -> Bool {
        microphoneStatus() == .authorized
    }

    static func requestMicrophone() async -> Bool {
        guard microphoneStatus() == .notDetermined else {
            return isMicrophoneGranted()
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func isInputMonitoringGranted() -> Bool {
        CGPreflightListenEventAccess()
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func isAccessibilityGranted() -> Bool {
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
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
