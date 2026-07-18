import Foundation

/// Minimal, non-generative cleanup applied directly to Parakeet output.
/// Keep this deliberately narrow: it may remove only transcription artefacts
/// that are overwhelmingly unlikely to be intended prose.
enum TranscriptSanitizer {
    static func sanitize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        // Parakeet can emit a false-start consonant as a standalone token:
        // "Load onto my f mobile." Preserve the real one-letter words "a"
        // and "I". Attached technical tokens such as C++ and GPT-5 do not
        // match because the letter is not bounded by whitespace/punctuation.
        result = result.replacingOccurrences(
            of: #"(?i)(^|\s)[b-hj-z](?=\s|[.,!?;:]|$)"#,
            with: "$1",
            options: .regularExpression
        )

        return result
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
