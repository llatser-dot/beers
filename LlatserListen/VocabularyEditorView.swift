import SwiftUI

struct VocabularyEditorView: View {
    @EnvironmentObject var appState: AppState
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
                    .font(.system(size: 11))
                    .foregroundStyle(LlatserTheme.textTertiary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(appState.vocabularyCorrections) { correction in
                            correctionRow(correction)
                        }
                    }
                }
                .frame(maxHeight: compact ? 138 : 190)
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
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(correction.replacement)
                    .font(.system(size: 11))
                    .foregroundStyle(LlatserTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                appState.removeVocabularyCorrection(correction)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(LlatserTheme.textTertiary)
            .help("Remove correction")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LlatserTheme.hairline, lineWidth: 0.8)
        )
    }

    private func addCorrection() {
        guard canAdd else { return }
        appState.addVocabularyCorrection(heard: heard, replacement: replacement)
        heard = ""
        replacement = ""
    }
}
