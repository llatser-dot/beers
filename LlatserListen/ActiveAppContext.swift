import AppKit
import Foundation

struct ActiveAppContext: Equatable {
    static let beersBundleIdentifier = "com.llatser.listen"

    let name: String
    let bundleIdentifier: String

    /// Canonical stable key for a user-created recipe. Beers and contexts with
    /// no bundle identifier are intentionally ineligible.
    var recipeBundleIdentifier: String? {
        let candidate = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !candidate.isEmpty, candidate != Self.beersBundleIdentifier else { return nil }
        return candidate
    }

    var inferredWritingMode: WritingMode {
        let haystack = "\(name) \(bundleIdentifier)".lowercased()

        if haystack.contains("codex") ||
            haystack.contains("cursor") ||
            haystack.contains("xcode") ||
            haystack.contains("terminal") ||
            haystack.contains("iterm") ||
            haystack.contains("warp")
        {
            return .command
        }

        if haystack.contains("slack") ||
            haystack.contains("messages") ||
            haystack.contains("whatsapp") ||
            haystack.contains("telegram") ||
            haystack.contains("discord")
        {
            return .message
        }

        return .clean
    }

    static var frontmost: ActiveAppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ActiveAppContext(name: "Current app", bundleIdentifier: "")
        }

        return ActiveAppContext(
            name: app.localizedName ?? "Current app",
            bundleIdentifier: app.bundleIdentifier ?? ""
        )
    }
}
