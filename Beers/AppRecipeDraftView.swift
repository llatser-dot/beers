import SwiftUI

struct AppRecipeDraftView: View {
    @ObservedObject private var store: AppRecipeStore
    let target: ActiveAppContext
    let globalWritingMode: WritingMode
    let globalAddSpaceAfterPaste: Bool

    @State private var draftMode: WritingMode = .clean
    @State private var draftAddSpaceAfterPaste = false

    private var currentRecipe: AppRecipe? {
        store.recipe(for: target)
    }

    init(
        store: AppRecipeStore,
        target: ActiveAppContext,
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recipe for \(target.name)")
                        .font(Beers.ui(13, .bold))
                        .foregroundStyle(Beers.ink)
                    Text(target.bundleIdentifier)
                        .font(Beers.ui(11.5, .medium))
                        .foregroundStyle(Beers.ink.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
                if !store.recipes.isEmpty {
                    Text("\(store.recipes.count) saved")
                        .font(Beers.ui(11.5, .semibold))
                        .foregroundStyle(Beers.ink.opacity(0.55))
                }
            }

            HStack(spacing: 12) {
                Text("Writing style")
                    .font(Beers.ui(12.5, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.82))
                Spacer()
                Menu {
                    ForEach(AppRecipe.supportedWritingModes) { mode in
                        Button(mode.displayName) { draftMode = mode }
                    }
                } label: {
                    BeersChip(fill: Beers.cream) {
                        HStack(spacing: 7) {
                            Text(draftMode.displayName)
                                .font(Beers.ui(12, .semibold))
                            Text("▾")
                                .font(Beers.ui(11.5, .semibold))
                                .foregroundStyle(Beers.amber)
                        }
                    }
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack {
                Text("Add a space after serving")
                    .font(Beers.ui(12.5, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.82))
                Spacer()
                Toggle("Add a space after serving in \(target.name)", isOn: $draftAddSpaceAfterPaste)
                    .labelsHidden()
                    .toggleStyle(BeersToggleStyle())
            }

            HStack(spacing: 8) {
                Button(currentRecipe == nil ? "Save recipe" : "Update recipe", action: save)
                    .buttonStyle(BeersButtonStyle(kind: .amber, small: true))

                if currentRecipe != nil {
                    Button("Remove recipe", action: remove)
                        .buttonStyle(BeersButtonStyle(kind: .ghost, small: true))
                }
            }

            Text("Applied once when a pour starts in this app. The recipe stays on this Mac and contains no dictated text.")
                .font(Beers.ui(11.5, .medium))
                .foregroundStyle(Beers.ink.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .onAppear(perform: loadDraft)
    }

    private func save() {
        store.upsert(
            for: target,
            writingMode: draftMode,
            addSpaceAfterPaste: draftAddSpaceAfterPaste
        )
    }

    private func remove() {
        store.remove(for: target)
        loadDraft()
    }

    private func loadDraft() {
        if let currentRecipe {
            draftMode = currentRecipe.writingMode
            draftAddSpaceAfterPaste = currentRecipe.addSpaceAfterPaste
            return
        }

        if AppRecipe.supportedWritingModes.contains(globalWritingMode) {
            draftMode = globalWritingMode
        } else {
            draftMode = target.inferredWritingMode
        }
        draftAddSpaceAfterPaste = globalAddSpaceAfterPaste
    }
}
