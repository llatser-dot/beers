import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only: never take a Dock icon, even while a window is open.
        NSApp.setActivationPolicy(.accessory)
        // Law: the Beers palette is one fixed light appearance.
        NSApp.appearance = NSAppearance(named: .aqua)
        BeersFonts.registerOnce()
        _ = UpdateController.shared

        // A menu-bar app starts windowless: macOS restoration otherwise
        // brings back whatever was open at quit (Brew Controls included)
        // on every relaunch.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        closeRestoredWindows()

        let allGranted = Permissions.isMicrophoneGranted()
            && Permissions.isInputMonitoringGranted()
            && Permissions.isAccessibilityGranted()

        // Installs that already have every grant never need onboarding.
        if allGranted && !UserDefaults.standard.bool(forKey: "firstRoundDone") {
            UserDefaults.standard.set(true, forKey: "firstRoundDone")
        }

        if !UserDefaults.standard.bool(forKey: "firstRoundDone") {
            // First run / reset grants: show First Round.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainWindowPresenter.shared.show()
                llog("App: First Round window shown")
            }
        }
    }

    private func closeRestoredWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows {
                let id = window.identifier?.rawValue ?? ""
                let isAppWindow = id.contains("main")
                    || id.contains("Settings")
                    || window.title == "Brew Controls"
                    || window.title == "Beers"
                if isAppWindow {
                    window.isRestorable = false
                    window.close()
                    llog("App: closed restored window '\(window.title)'")
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowPresenter.shared.show()
        return true
    }
}

@main
struct BeersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            StatusBarView()
                .environmentObject(appState)
        } label: {
            // Full-colour brand icon — never a grey template glyph.
            MenuBarIconView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            BrewControlsView()
                .environmentObject(appState)
        }
    }
}

/// Always alive in the status bar; also hands AppState to the window presenter.
private struct MenuBarIconView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        iconImage
    }

    private var iconImage: Image {
        let name: String
        switch appState.status {
        case .recording: name = "menubar-recording"
        case .transcribing, .loading: name = "menubar-busy"
        default: name = "menubar-idle"
        }
        guard let image = Beers.brandImage(name) else {
            return Image(systemName: "ear")
        }
        image.size = NSSize(width: 20, height: 20)
        return Image(nsImage: image)
    }
}
