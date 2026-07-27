import AppKit
import SwiftUI

/// Owns the app's one real window (First Round → Taproom). A plain
/// NSWindow so the AppDelegate and the popover can open it reliably —
/// SwiftUI Window scenes can't be summoned from AppKit.
@MainActor
final class MainWindowPresenter {
    static let shared = MainWindowPresenter()

    var appStateProvider: (() -> AppState?)?
    private var window: NSWindow?

    /// Open the window on a specific Taproom section (e.g. Drunk Slurs from
    /// Brew Settings). Works whether or not the window is already up.
    func show(section: TaproomView.TapFilter) {
        appStateProvider?()?.requestedTaproomSection = section
        show()
    }

    func show() {
        guard let appState = appStateProvider?() ?? nil else {
            // App body hasn't run yet — retry shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.show()
            }
            return
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: MainWindowView().environmentObject(appState)
        )
        let newWindow = NSWindow(contentViewController: host)
        newWindow.title = "Beers"
        newWindow.styleMask = [.titled, .closable, .miniaturizable]
        newWindow.titlebarAppearsTransparent = true
        newWindow.backgroundColor = NSColor(
            red: 0xFD / 255, green: 0xF4 / 255, blue: 0xE0 / 255, alpha: 1
        )
        newWindow.isReleasedWhenClosed = false
        newWindow.center()

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// First Round until it's been completed once; the Taproom after that.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("firstRoundDone") private var firstRoundDone = false

    var body: some View {
        if firstRoundDone {
            TaproomView(store: appState.pourStore)
        } else {
            FirstRoundView()
        }
    }
}
