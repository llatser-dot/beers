import Foundation
import Sparkle

/// One updater shared by the menu-bar popover and the Taproom.
/// Sparkle owns the download, signature verification, app replacement and relaunch.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var isChecking = false

    private var updaterController: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?

    override private init() {
        super.init()

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var actionTitle: String {
        if let availableVersion { return "Update to v\(availableVersion)" }
        return isChecking ? "Checking for updates…" : "Check for updates"
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isChecking = true
        updaterController.checkForUpdates(nil)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            availableVersion = item.displayVersionString
            isChecking = false
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            availableVersion = nil
            isChecking = false
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            isChecking = false
        }
    }
}
