import AVFAudio
import AppKit
import ApplicationServices
import IOKit.hid

enum Permissions {
    private struct SystemGrantSnapshot {
        let microphone: Bool
        let inputMonitoring: Bool
        let accessibility: Bool
    }

    private static var systemGrantBaseline: SystemGrantSnapshot?
    private static var relaunchHelperStarted = false

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
        // CGPreflight often stays false until the process relaunches after
        // the System Settings toggle flips, which used to leave onboarding
        // blind to the grant. IOHIDCheckAccess reads the TCC database live,
        // so the flip is seen the moment it happens — refreshPermissions
        // then relaunches to make the grant apply to this process.
        CGPreflightListenEventAccess()
            || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
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

    /// Remember the grants in place before sending someone to System Settings.
    /// The relaunch helper must be alive before macOS offers "Quit & Reopen":
    /// that termination can bypass both our permission poll and app delegate.
    static func beginSystemGrantFlow() {
        if systemGrantBaseline == nil {
            systemGrantBaseline = SystemGrantSnapshot(
                microphone: isMicrophoneGranted(),
                inputMonitoring: isInputMonitoringGranted(),
                accessibility: isAccessibilityGranted()
            )
        }
        startRelaunchHelper()
    }

    /// Called from the app-termination callback. System Settings can terminate
    /// Beers before the one-second permission monitor observes the new grant,
    /// so arm the relaunch here when a grant changed during the guided flow.
    static func prepareRelaunchAfterSystemGrantIfNeeded() {
        guard let baseline = systemGrantBaseline else { return }
        let microphone = isMicrophoneGranted()
        let inputMonitoring = isInputMonitoringGranted()
        let accessibility = isAccessibilityGranted()
        let gainedMicrophone = microphone && !baseline.microphone
        let gainedInputMonitoring = inputMonitoring && !baseline.inputMonitoring
        let gainedAccessibility = accessibility && !baseline.accessibility

        guard gainedMicrophone || gainedInputMonitoring || gainedAccessibility else { return }
        llog(
            "Permissions: terminating after system grant "
                + "(microphone=\(gainedMicrophone) "
                + "inputMonitoring=\(gainedInputMonitoring) accessibility=\(gainedAccessibility)); "
                + "arming relaunch"
        )
        startRelaunchHelper()
    }

    /// Input Monitoring / Accessibility grants frequently do not apply to the
    /// already-running process. Relaunch so TCC re-evaluates this binary.
    static func relaunchApp() {
        guard startRelaunchHelper() else { return }
        NSApp.terminate(nil)
    }

    /// A small child process survives our termination, waits for this PID to
    /// disappear, then asks Launch Services to open the bundle. Without `-n`,
    /// this also raises the copy macOS may already have reopened instead of
    /// creating a duplicate.
    /// It expires after ten minutes so abandoning a grant flow cannot cause a
    /// surprise reopen much later. Paths are shell arguments, not interpolated.
    @discardableResult
    private static func startRelaunchHelper() -> Bool {
        guard !relaunchHelperStarted else { return true }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            attempt=0
            while /bin/kill -0 "$1" 2>/dev/null; do
                [ "$attempt" -ge 6000 ] && exit 0
                /bin/sleep 0.1
                attempt=$((attempt + 1))
            done
            exec /usr/bin/open "$2" --args --beers-permission-relaunch
            """,
            "beers-permission-relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path
        ]

        do {
            try helper.run()
            relaunchHelperStarted = true
            llog("Permissions: relaunch helper armed")
            return true
        } catch {
            llog("Permissions: could not arm relaunch helper: \(error.localizedDescription)")
            return false
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
        llog("Permissions: OPENING System Settings pane '\(pane)' — caller stack: \(Thread.callStackSymbols.prefix(6).joined(separator: " | "))")
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
