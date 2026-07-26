import Combine
import Foundation

/// Versioned UserDefaults persistence for per-app recipes. Bundle identifiers
/// are canonicalised before matching so recipe precedence is deterministic.
@MainActor
final class AppRecipeStore: ObservableObject {
    @Published private(set) var recipes: [AppRecipe]

    private struct Envelope: Codable {
        let version: Int
        let recipes: [AppRecipe]
    }

    private static let currentVersion = 1
    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "appRecipesEnvelope"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.recipes = Self.load(from: defaults, storageKey: storageKey)
    }

    func recipe(for context: ActiveAppContext) -> AppRecipe? {
        guard let bundleIdentifier = context.recipeBundleIdentifier else { return nil }
        return recipes.first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Recipe values take precedence over the current global values. Unknown
    /// apps and contexts without a bundle identifier are exact global fallbacks.
    func settings(
        for context: ActiveAppContext,
        globalWritingMode: WritingMode,
        globalAddSpaceAfterPaste: Bool
    ) -> AppRecipeSettings {
        guard let recipe = recipe(for: context) else {
            return AppRecipeSettings(
                writingMode: globalWritingMode,
                addSpaceAfterPaste: globalAddSpaceAfterPaste
            )
        }

        return AppRecipeSettings(
            writingMode: recipe.writingMode,
            addSpaceAfterPaste: recipe.addSpaceAfterPaste
        )
    }

    @discardableResult
    func upsert(
        for context: ActiveAppContext,
        writingMode: WritingMode,
        addSpaceAfterPaste: Bool
    ) -> Bool {
        guard let bundleIdentifier = context.recipeBundleIdentifier,
              AppRecipe.supportedWritingModes.contains(writingMode)
        else {
            return false
        }

        let trimmedName = context.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipe = AppRecipe(
            bundleIdentifier: bundleIdentifier,
            appName: trimmedName.isEmpty ? bundleIdentifier : trimmedName,
            writingMode: writingMode,
            addSpaceAfterPaste: addSpaceAfterPaste
        )

        if let index = recipes.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        sortRecipes()
        persist()
        return true
    }

    @discardableResult
    func remove(for context: ActiveAppContext) -> Bool {
        guard let bundleIdentifier = context.recipeBundleIdentifier,
              recipes.contains(where: { $0.bundleIdentifier == bundleIdentifier })
        else {
            return false
        }

        recipes.removeAll { $0.bundleIdentifier == bundleIdentifier }
        persist()
        return true
    }

    private func sortRecipes() {
        recipes.sort {
            if $0.appName.localizedStandardCompare($1.appName) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
        }
    }

    private func persist() {
        let envelope = Envelope(version: Self.currentVersion, recipes: recipes)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func load(from defaults: UserDefaults, storageKey: String) -> [AppRecipe] {
        guard let data = defaults.data(forKey: storageKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == currentVersion
        else {
            return []
        }

        var recipesByBundleIdentifier: [String: AppRecipe] = [:]
        for recipe in envelope.recipes {
            let context = ActiveAppContext(
                name: recipe.appName,
                bundleIdentifier: recipe.bundleIdentifier
            )
            guard let bundleIdentifier = context.recipeBundleIdentifier,
                  AppRecipe.supportedWritingModes.contains(recipe.writingMode)
            else {
                continue
            }

            let trimmedName = recipe.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            recipesByBundleIdentifier[bundleIdentifier] = AppRecipe(
                bundleIdentifier: bundleIdentifier,
                appName: trimmedName.isEmpty ? bundleIdentifier : trimmedName,
                writingMode: recipe.writingMode,
                addSpaceAfterPaste: recipe.addSpaceAfterPaste
            )
        }

        return recipesByBundleIdentifier.values.sorted {
            if $0.appName.localizedStandardCompare($1.appName) == .orderedSame {
                return $0.bundleIdentifier < $1.bundleIdentifier
            }
            return $0.appName.localizedStandardCompare($1.appName) == .orderedAscending
        }
    }
}
