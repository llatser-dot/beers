import Foundation

/// A deliberately small, local-only override for one target app.
/// Recipes never contain dictated text, corrections, or network settings.
struct AppRecipe: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    var appName: String
    var writingMode: WritingMode
    var addSpaceAfterPaste: Bool

    var id: String { bundleIdentifier }

    static let supportedWritingModes: [WritingMode] = [.clean, .message, .command]
}
