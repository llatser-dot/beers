import AppKit
import SwiftUI

/// A small always-on-top window that survives System Settings taking focus.
///
/// Accessibility and Input Monitoring are the two grants macOS will not let an
/// app turn on for you. Worse, a fresh install is not even *listed* in those
/// panes, so "open System Settings" drops the user in front of a list with no
/// Beers row and no switch to flip — nothing tells them the app has to be
/// dragged in first.
///
/// The First Round window already explained the drag, but explained it in an
/// ordinary window: opening System Settings put that explanation behind the
/// thing it was explaining. This panel floats above it and does not take focus,
/// so the badge stays draggable and the steps stay readable while the user is
/// standing in the list.
@MainActor
final class GrantCoach {
    static let shared = GrantCoach()

    enum Grant {
        case accessibility
        case inputMonitoring

        var listName: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .inputMonitoring: return "Input Monitoring"
            }
        }

        var why: String {
            switch self {
            case .accessibility: return "so Beers can type into the app you're in"
            case .inputMonitoring: return "so Beers hears your pour key"
            }
        }
    }

    private var panel: NSPanel?

    private init() {}

    func show(_ grant: Grant, appState: AppState) {
        dismiss()

        let content = GrantCoachView(grant: grant, onDone: { [weak self] in
            self?.dismiss()
        })
        .environmentObject(appState)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 400)

        // .nonactivatingPanel keeps System Settings frontmost — stealing focus
        // would bounce the user out of the very list they need to be in.
        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        // Follow the user across Spaces and over full-screen System Settings.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear

        positionOnScreen(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// `--beers-grant-coach-test`: raise the coach, open the pane it points at,
    /// then report the on-screen window order. The whole point of this panel is
    /// that it outranks System Settings, and that cannot be checked by
    /// rendering the view — only by looking at where the real window lands.
    @MainActor
    static func runLayeringTestIfRequested(appState: AppState) {
        guard CommandLine.arguments.contains("--beers-grant-coach-test") else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            GrantCoach.shared.show(.accessibility, appState: appState)
            Permissions.openAccessibilitySettings()

            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let windows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
                ) as? [[String: Any]] ?? []

                llog("GrantCoach TEST: on-screen windows, front to back:")
                for (index, window) in windows.enumerated() where index < 12 {
                    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
                    let layer = window[kCGWindowLayer as String] as? Int ?? -1
                    let name = window[kCGWindowName as String] as? String ?? ""
                    llog("GrantCoach TEST:   [\(index)] layer=\(layer) \(owner) \(name)")
                }

                let beersIndex = windows.firstIndex {
                    ($0[kCGWindowOwnerName as String] as? String) == "Beers"
                }
                let settingsIndex = windows.firstIndex {
                    let owner = ($0[kCGWindowOwnerName as String] as? String) ?? ""
                    return owner.contains("System Settings") || owner.contains("System Preferences")
                }
                llog("GrantCoach TEST: beersIndex=\(String(describing: beersIndex)) settingsIndex=\(String(describing: settingsIndex))")
                if let beersIndex, let settingsIndex {
                    llog(beersIndex < settingsIndex
                        ? "GrantCoach TEST: PASS — coach is in front of System Settings"
                        : "GrantCoach TEST: FAIL — System Settings is covering the coach")
                } else {
                    llog("GrantCoach TEST: INCONCLUSIVE — one of the windows was not on screen")
                }
                exit(0)
            }
        }
    }

    /// Top-right of the active screen: System Settings opens centred, so this
    /// sits clear of it rather than on top of the list being pointed at.
    private func positionOnScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrameOrigin(origin)
    }
}

struct GrantCoachView: View {
    let grant: GrantCoach.Grant
    var onDone: () -> Void = {}
    /// Snapshot-only: render the pre-grant state on a Mac that has already
    /// granted everything, so the harness can capture what a new user sees.
    var forceUngrantedForSnapshot = false

    @EnvironmentObject var appState: AppState

    private var granted: Bool {
        if forceUngrantedForSnapshot { return false }
        switch grant {
        case .accessibility: return appState.accessibilityGranted
        case .inputMonitoring: return appState.inputMonitoringGranted
        }
    }

    var body: some View {
        VStack(spacing: 13) {
            HStack {
                Text(granted ? "Poured!" : "One switch to flip")
                    .font(Beers.display(15))
                    .foregroundStyle(Beers.stout)
                Spacer()
                Button(action: onDone) {
                    Text("✕")
                        .font(Beers.ui(13, .bold))
                        .foregroundStyle(Beers.ink.opacity(0.55))
                }
                .buttonStyle(.plain)
            }

            if granted {
                Text("\(grant.listName) is on. You can close this.")
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else {
                Text("Find the **\(grant.listName)** list in System Settings — \(grant.why).")
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.75))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                DraggableAppBadge()

                VStack(alignment: .leading, spacing: 7) {
                    line("1", "Beers won't be in the list yet — drag this bottle straight in.")
                    line("2", "Flip the Beers switch on.")
                    line("3", "Come back here; Beers spots it on its own.")
                }

                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Beers.amber)
                            .frame(width: 5, height: 5)
                            .opacity(0.35)
                            .scaleEffect(1)
                            .animation(
                                .easeInOut(duration: 0.7)
                                    .repeatForever()
                                    .delay(Double(index) * 0.2),
                                value: granted
                            )
                    }
                    Text("Watching the door…")
                        .font(Beers.ui(11, .medium))
                        .foregroundStyle(Beers.ink.opacity(0.5))
                }
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(Beers.paper)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Beers.ink, lineWidth: 3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .light)
        // The panel is the only thing on screen while System Settings has
        // focus, so it has to notice the toggle itself.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !granted { appState.refreshPermissions() }
        }
        .onChange(of: granted) { _, isGranted in
            if isGranted {
                Beers.popCap()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onDone() }
            }
        }
    }

    private func line(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number)
                .font(Beers.display(10))
                .foregroundStyle(Beers.paper)
                .frame(width: 18, height: 18)
                .background(Beers.stout, in: Circle())
            Text(text)
                .font(Beers.ui(12, .medium))
                .foregroundStyle(Beers.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
