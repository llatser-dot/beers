import Foundation

@main
enum AppRecipesSmoke {
    @MainActor
    static func main() {
        let suiteName = "com.llatser.beers.app-recipes-smoke.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fail("Could not create isolated UserDefaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storageKey = "recipes-smoke"
        let notes = ActiveAppContext(name: "Notes", bundleIdentifier: "com.apple.Notes")
        let unknown = ActiveAppContext(name: "Mail", bundleIdentifier: "com.apple.mail")
        let missingBundle = ActiveAppContext(name: "Current app", bundleIdentifier: "")
        let beers = ActiveAppContext(
            name: "Beers",
            bundleIdentifier: ActiveAppContext.beersBundleIdentifier
        )

        let store = AppRecipeStore(defaults: defaults, storageKey: storageKey)
        expect(store.recipes.isEmpty, "New store was not empty")
        expect(
            store.upsert(for: notes, writingMode: .command, addSpaceAfterPaste: true),
            "Valid recipe was rejected"
        )

        guard let persistedData = defaults.data(forKey: storageKey) else {
            fail("Recipe envelope was not persisted")
        }
        validatePersistenceShape(persistedData)

        let reloaded = AppRecipeStore(defaults: defaults, storageKey: storageKey)
        let caseVariant = ActiveAppContext(name: "Notes", bundleIdentifier: "COM.APPLE.NOTES")
        expect(reloaded.recipe(for: caseVariant)?.appName == "Notes", "Bundle matching was not canonical")

        let recipeSettings = reloaded.settings(
            for: notes,
            globalWritingMode: .message,
            globalAddSpaceAfterPaste: false
        )
        expect(recipeSettings == AppRecipeSettings(writingMode: .command, addSpaceAfterPaste: true),
               "Recipe did not take precedence over global settings")

        let pourStartSnapshot = recipeSettings
        expect(reloaded.upsert(for: notes, writingMode: .message, addSpaceAfterPaste: false),
               "Recipe update failed")
        expect(pourStartSnapshot == AppRecipeSettings(writingMode: .command, addSpaceAfterPaste: true),
               "Start-of-pour value snapshot changed after a store update")
        expect(
            reloaded.settings(
                for: notes,
                globalWritingMode: .clean,
                globalAddSpaceAfterPaste: true
            ) == AppRecipeSettings(writingMode: .message, addSpaceAfterPaste: false),
            "A later pour did not see the updated recipe"
        )

        let unknownSettings = reloaded.settings(
            for: unknown,
            globalWritingMode: .automatic,
            globalAddSpaceAfterPaste: false
        )
        expect(unknownSettings == AppRecipeSettings(writingMode: .automatic, addSpaceAfterPaste: false),
               "Unknown app did not preserve global settings")

        let missingBundleSettings = reloaded.settings(
            for: missingBundle,
            globalWritingMode: .clean,
            globalAddSpaceAfterPaste: true
        )
        expect(missingBundleSettings == AppRecipeSettings(writingMode: .clean, addSpaceAfterPaste: true),
               "Missing bundle identifier did not preserve global settings")

        expect(!reloaded.upsert(for: beers, writingMode: .message, addSpaceAfterPaste: false),
               "Beers was accepted as its own recipe target")
        expect(reloaded.recipes.count == 1, "Rejected Beers recipe changed persistence")

        expect(reloaded.upsert(for: notes, writingMode: .clean, addSpaceAfterPaste: true),
               "Second recipe update failed")
        expect(reloaded.recipes.count == 1, "Recipe update created a duplicate")
        expect(reloaded.recipe(for: notes)?.writingMode == .clean, "Recipe update was not applied")

        expect(reloaded.remove(for: notes), "Recipe removal failed")
        expect(reloaded.recipes.isEmpty, "Recipe remained after removal")

        print("App recipes smoke passed: persistence, safe shape, matching, fallback, precedence, update and removal.")
    }

    private static func validatePersistenceShape(_ data: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(envelope.keys) == Set(["version", "recipes"]),
              let recipes = envelope["recipes"] as? [[String: Any]],
              let recipe = recipes.first
        else {
            fail("Recipe persistence was not the expected versioned JSON envelope")
        }

        let allowedRecipeKeys = Set([
            "bundleIdentifier",
            "appName",
            "writingMode",
            "addSpaceAfterPaste",
        ])
        expect(Set(recipe.keys) == allowedRecipeKeys,
               "Recipe persistence contains fields outside the local preference contract")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("App recipes smoke failed: \(message)\n", stderr)
        exit(1)
    }
}
