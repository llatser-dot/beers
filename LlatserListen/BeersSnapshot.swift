import AppKit
import SwiftUI

/// Offscreen design-verification harness. Launch the app with
/// `--beers-snapshot` and every surface renders to /tmp/beers-snapshots
/// as PNGs, then the app exits. No screen recording required.
enum BeersSnapshot {
    @MainActor
    static func runIfRequested(appState: AppState) {
        guard CommandLine.arguments.contains("--beers-snapshot") else { return }

        let dir = URL(fileURLWithPath: "/tmp/beers-snapshots")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Delay slightly so fonts/assets settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            snap(FirstRoundView().environmentObject(appState),
                 size: CGSize(width: 380, height: 540), name: "first-round", in: dir)

            snap(StatusBarView().environmentObject(appState),
                 size: nil, name: "bar-tap", in: dir)

            snap(BrewControlsView().environmentObject(appState),
                 size: CGSize(width: 560, height: 720), name: "brew-controls", in: dir)

            let store = seededStore()
            snap(TaproomView(store: store).environmentObject(appState),
                 size: CGSize(width: 940, height: 620), name: "taproom", in: dir)

            snapHUD(mode: .pouring, name: "hud-pouring", in: dir)
            snapHUD(mode: .settling, name: "hud-settling", in: dir)
            snapHUD(mode: .served(words: 42), name: "hud-served", in: dir)

            llog("BeersSnapshot: wrote snapshots to \(dir.path)")
            exit(0)
        }
    }

    @MainActor
    private static func snapHUD(mode: OverlayMode, name: String, in dir: URL) {
        let presentation = OverlayPresentationState()
        presentation.isVisible = true
        presentation.mode = mode
        snap(
            PourHUDView(presentation: presentation),
            size: PourHUDLayout.canvasSize,
            name: name,
            in: dir
        )
    }

    @MainActor
    private static func seededStore() -> PourStore {
        let store = PourStore()
        store.persistenceEnabled = false
        guard store.active.isEmpty else { return store }
        let samples: [(String, String, TimeInterval)] = [
            ("Send the invoice over to Dave and cc the accountant, tell him it's the March one.", "Mail", 19),
            ("Standup notes — shipped the tunnel fix, blocked on the cert, next up the retry queue.", "Slack", 12),
            ("Idea: the onboarding should literally pour the first beer for you.", "Notes", 48),
        ]
        for (text, app, duration) in samples {
            store.add(Pour(text: text, appName: app, duration: duration))
        }
        return store
    }

    @MainActor
    private static func snap<V: View>(
        _ view: V,
        size: CGSize?,
        name: String,
        in dir: URL
    ) {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
        let target = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: target)
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).png"))
        llog("BeersSnapshot: \(name) \(Int(target.width))x\(Int(target.height))")
    }
}
