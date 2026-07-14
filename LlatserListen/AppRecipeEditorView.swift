import SwiftUI

/// Edits only the last deliberate non-Beers pour target. Merely opening Brew
/// Controls never creates a recipe or selects Beers itself.
struct AppRecipeEditorView: View {
    @ObservedObject private var store: AppRecipeStore
    let target: ActiveAppContext?
    let globalWritingMode: WritingMode
    let globalAddSpaceAfterPaste: Bool

    init(
        store: AppRecipeStore,
        target: ActiveAppContext?,
        globalWritingMode: WritingMode,
        globalAddSpaceAfterPaste: Bool
    ) {
        self.store = store
        self.target = target
        self.globalWritingMode = globalWritingMode
        self.globalAddSpaceAfterPaste = globalAddSpaceAfterPaste
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashedDivider()
                .padding(.horizontal, 12)

            if let target, target.recipeBundleIdentifier != nil {
                AppRecipeDraftView(
                    store: store,
                    target: target,
                    globalWritingMode: globalWritingMode,
                    globalAddSpaceAfterPaste: globalAddSpaceAfterPaste
                )
                .id(target.recipeBundleIdentifier)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Per-app recipe")
                        .font(Beers.ui(13, .bold))
                        .foregroundStyle(Beers.ink)
                    Text("Start a pour in another app, then return here to save its writing style. Beers itself is never a recipe target.")
                        .font(Beers.ui(11.5, .medium))
                        .foregroundStyle(Beers.ink.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }
}
