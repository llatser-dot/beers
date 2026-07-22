import Foundation

struct WritingPreferences {
    var mode: WritingMode
    var cleanSpeechScaffolding: Bool
    var collapseRepeats: Bool
    var smartCapitalization: Bool
    var normalizeLinks: Bool
    var removeTrailingFullStop: Bool
    var adaptiveTone: Bool
    var addSpaceAfterPaste: Bool

    static let defaults = WritingPreferences(
        mode: .clean,
        cleanSpeechScaffolding: false,
        collapseRepeats: false,
        smartCapitalization: true,
        normalizeLinks: true,
        removeTrailingFullStop: true,
        adaptiveTone: false,
        addSpaceAfterPaste: true
    )

    var polisherOptions: TranscriptPolisher.Options {
        TranscriptPolisher.Options(
            cleanSpeechScaffolding: cleanSpeechScaffolding,
            collapseRepeats: collapseRepeats,
            smartCapitalization: smartCapitalization,
            normalizeLinks: normalizeLinks,
            removeTrailingFullStop: removeTrailingFullStop,
            adaptiveTone: adaptiveTone,
            mode: mode
        )
    }
}
