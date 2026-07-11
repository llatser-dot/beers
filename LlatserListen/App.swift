import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: never take a Dock icon, even while a window is open.
        NSApp.setActivationPolicy(.accessory)

        if Permissions.isMicrophoneGranted()
            && Permissions.isInputMonitoringGranted()
            && Permissions.isAccessibilityGranted() {
            closeRestoredWindows()
        } else {
            // First run / missing grants: surface the permission checklist.
            showSettingsWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    private func closeRestoredWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                window.close()
            }
        }
    }

    private func showSettingsWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            NSApp.activate(ignoringOtherApps: true)
            llog("App: settings window requested")
        }
    }
}

@main
struct LlatserListenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Beers", id: "main") {
            RedesignedSettingsView()
                .environmentObject(appState)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            StatusBarView()
                .environmentObject(appState)
        } label: {
            if appState.status == .recording {
                Image(systemName: "waveform")
            } else if appState.status == .transcribing {
                Image(systemName: "ellipsis.circle")
            } else {
                Image(systemName: "ear")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            RedesignedSettingsView()
                .environmentObject(appState)
        }
    }
}
