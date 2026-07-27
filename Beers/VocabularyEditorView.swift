import SwiftUI

/// The Brewer's dictionary: teach Beers your words.
struct VocabularyEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heard = ""
    @State private var replacement = ""

    let compact: Bool
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Text("Brewer’s dictionary")
                    .font(Beers.display(14))
                    .foregroundStyle(Beers.stout)
            }

            HStack(spacing: 8) {
                beersField("Heard", text: $heard)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Beers.amber)
                beersField("Pour instead", text: $replacement)

                Button(action: addCorrection) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Beers.paper)
                        .frame(width: 34, height: 34)
                        .background(Beers.amber, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Beers.ink, lineWidth: 2)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
                .help("Add word")
            }

            if appState.vocabularyCorrections.isEmpty {
                // Only the user's own words live here now. Spoken punctuation
                // ("dot com" -> ".com") still works but is built in, so it is
                // deliberately not listed — otherwise the dictionary looks
                // pre-filled with words nobody taught it.
                Text("Nothing taught yet — add a name Beers keeps mishearing")
                    .font(Beers.ui(12, .medium))
                    .foregroundStyle(Beers.ink.opacity(0.5))
            } else if compact {
                ScrollView {
                    correctionList
                }
                .frame(maxHeight: 150)
            } else {
                correctionList
            }

            if !appState.vocabularySuggestions.isEmpty {
                suggestionsSection
            }
        }
    }

    // MARK: Suggestions mined from the user's own keyboard fixes

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DashedDivider()
                .padding(.top, 4)
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Beers.amber)
                Text("Suggestions from your fixes")
                    .font(Beers.display(12))
                    .foregroundStyle(Beers.stout)
            }
            .padding(.top, 4)
            .padding(.bottom, 2)

            ForEach(appState.vocabularySuggestions) { suggestion in
                suggestionRow(suggestion)
            }
        }
    }

    private func suggestionRow(_ suggestion: VocabularySuggestion) -> some View {
        HStack(spacing: 8) {
            Text(suggestion.heard)
                .font(Beers.ui(12, .semibold))
                .foregroundStyle(Beers.ink.opacity(0.6))
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Beers.amber)
            Text(suggestion.replacement)
                .font(Beers.ui(12, .bold))
                .foregroundStyle(Beers.ink)
                .lineLimit(1)

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : Beers.spring) {
                    appState.acceptVocabularySuggestion(suggestion)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                    Text("Add")
                        .font(Beers.ui(11, .bold))
                }
                .foregroundStyle(Beers.paper)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Beers.amber, in: Capsule())
                .overlay(Capsule().strokeBorder(Beers.ink, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("Teach this word")

            Button {
                withAnimation(reduceMotion ? nil : Beers.spring) {
                    appState.dismissVocabularySuggestion(suggestion)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Beers.ink.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Dismiss suggestion")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Beers.cream2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Beers.ink.opacity(0.9), lineWidth: 2)
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    private func beersField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Beers.ui(13, .medium))
            .foregroundStyle(Beers.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Beers.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Beers.ink, lineWidth: 2)
            )
            .onSubmit(addCorrection)
    }

    private var correctionList: some View {
        LazyVStack(spacing: 6) {
            ForEach(appState.vocabularyCorrections) { correction in
                correctionRow(correction)
            }
        }
    }

    private var canAdd: Bool {
        !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func correctionRow(_ correction: VocabularyCorrection) -> some View {
        HStack(spacing: 8) {
            Text(correction.heard)
                .font(Beers.ui(12, .semibold))
                .foregroundStyle(Beers.ink.opacity(0.6))
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Beers.amber)
            Text(correction.replacement)
                .font(Beers.ui(12, .bold))
                .foregroundStyle(Beers.ink)
                .lineLimit(1)

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : Beers.spring) {
                    appState.removeVocabularyCorrection(correction)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Beers.stout)
            }
            .buttonStyle(.plain)
            .help("Remove word")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Beers.cream, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Beers.ink.opacity(0.9), lineWidth: 2)
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    private func addCorrection() {
        guard canAdd else { return }
        withAnimation(reduceMotion ? nil : Beers.spring) {
            appState.addVocabularyCorrection(heard: heard, replacement: replacement)
        }
        heard = ""
        replacement = ""
    }
}
