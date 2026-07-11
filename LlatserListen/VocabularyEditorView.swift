import SwiftUI

struct VocabularyEditorView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heard = ""
    @State private var replacement = ""

    let compact: Bool
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            if showsTitle {
                SectionLabel(title: "Vocabulary", icon: "text.badge.checkmark")
            }

            HStack(spacing: 8) {
                TextField("Heard", text: $heard)
                    .textFieldStyle(.plain)
                    .jarvisField()
                    .onSubmit(addCorrection)

                TextField("Use", text: $replacement)
                    .textFieldStyle(.plain)
                    .jarvisField()
                    .onSubmit(addCorrection)

                Button(action: addCorrection) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(LlatserTheme.ink)
                        .frame(width: 34, height: 34)
                        .background(LlatserTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
                .opacity(canAdd ? 1 : 0.4)
                .help("Add correction")
            }

            if appState.vocabularyCorrections.isEmpty {
                Text("No custom words yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(LlatserTheme.textTertiary)
            } else if compact {
                ScrollView {
                    correctionList
                }
                .frame(maxHeight: 138)
            } else {
                correctionList
            }
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(correction.heard)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LlatserTheme.textPrimary)
                    .lineLimit(1)
                Text(correction.replacement)
                    .font(.system(size: 12))
                    .foregroundStyle(LlatserTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    appState.removeVocabularyCorrection(correction)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LlatserTheme.textTertiary)
            .help("Remove correction")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(LlatserTheme.selected, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LlatserTheme.hairline, lineWidth: 0.8)
        )
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    private func addCorrection() {
        guard canAdd else { return }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.08)) {
            appState.addVocabularyCorrection(heard: heard, replacement: replacement)
        }
        heard = ""
        replacement = ""
    }
}
