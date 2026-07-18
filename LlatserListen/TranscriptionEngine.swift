import Foundation

final class TranscriptionEngine {
    // Loaded models stay cached so switching engines back and forth is instant
    // instead of re-downloading/recompiling on every switch.
    private var parakeets: [DictationEngine: ParakeetTranscriber] = [:]
    private var activeEngine: DictationEngine?
    private let lock = NSLock()

    var loadedEngine: DictationEngine? {
        lock.withLock { activeEngine }
    }

    func load(_ engine: DictationEngine, onProgress: @escaping @Sendable (Double, String) -> Void) async throws {
        if loadedEngine == engine {
            onProgress(1, "\(engine.displayName) ready")
            return
        }

        switch engine {
        case .parakeetV3, .parakeetV2:
            if lock.withLock({ parakeets[engine] }) == nil {
                let transcriber = ParakeetTranscriber(
                    version: engine == .parakeetV3 ? .v3 : .v2,
                    label: engine.displayName
                )
                try await transcriber.load { progress, message in
                    onProgress(progress, message)
                }
                try Task.checkCancellation()
                lock.withLock { parakeets[engine] = transcriber }
            }
        }

        try Task.checkCancellation()
        lock.withLock { activeEngine = engine }
        onProgress(1, "\(engine.displayName) ready")
    }

    /// Returns Parakeet's sanitised transcript without semantic normalisation.
    /// The production fast path applies only explicit vocabulary corrections
    /// after this point; legacy rules are opt-in at the caller.
    func transcribe(
        _ audio: [Float],
        languageMode: ASRLanguageMode = .automatic
    ) async throws -> String {
        guard let loadedEngine else {
            throw TranscriptionError.modelNotLoaded
        }

        let text: String
        switch loadedEngine {
        case .parakeetV3, .parakeetV2:
            guard let parakeet = lock.withLock({ parakeets[loadedEngine] }) else { throw TranscriptionError.modelNotLoaded }
            text = try await parakeet.transcribe(audio, languageMode: languageMode)
        }

        return text
    }

    /// The pre-baseline normaliser, retained only for the explicit legacy
    /// polish comparison. It must never run in the default Parakeet path.
    static func legacyNormalize(_ text: String) -> String {
        TranscriptNormalizer.normalize(text)
    }

    enum TranscriptionError: LocalizedError {
        case modelNotLoaded
        case invalidAudioBuffer

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "The selected dictation engine is not loaded."
            case .invalidAudioBuffer: return "The recorded audio could not be prepared for transcription."
            }
        }
    }
}

private enum TranscriptNormalizer {
    private static let fillerPattern = #"\b(?:um+|uh+|erm+|er+|ah+|hmm+|mmm+|oh+|o)\b[,.!?;:]*"#
    private static let numberPhrasePattern = #"\b(?:zero|oh|o|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand)(?:[\s-]+(?:and|point|zero|oh|o|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand))*\b"#

    private static let digitWords: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9
    ]

    private static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    static func normalize(_ text: String) -> String {
        let cleanText = tidy(text)
        let numberedText = replaceNumberPhrases(in: cleanText)
        let modelText = normalizeModelVersions(in: numberedText)
        let vocabularyText = VocabularyCorrections.apply(to: modelText)
        if vocabularyText != modelText {
            llog("TranscriptNormalizer: vocabulary transcription='\(vocabularyText)'")
        }
        let withoutFillers = replaceMatches(in: vocabularyText, pattern: fillerPattern, options: [.caseInsensitive]) { _ in "" }
        return tidy(withoutFillers)
    }

    private static func replaceNumberPhrases(in text: String) -> String {
        replaceMatches(in: text, pattern: numberPhrasePattern, options: [.caseInsensitive]) { phrase in
            numericReplacement(for: phrase) ?? phrase
        }
    }

    private static func normalizeModelVersions(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\bk\s+(\d+\.\d+)\b"#,
            with: "K$1",
            options: .regularExpression
        )
    }

    private static func numericReplacement(for phrase: String) -> String? {
        let words = phrase
            .lowercased()
            .split { $0 == " " || $0 == "-" }
            .map(String.init)

        guard !words.isEmpty, words.last != "and" else { return nil }

        if let pointIndex = words.firstIndex(of: "point") {
            let wholeWords = Array(words[..<pointIndex])
            let decimalWords = Array(words[words.index(after: pointIndex)...])
            guard !decimalWords.isEmpty else { return nil }

            let whole = integerValue(for: wholeWords) ?? digitString(for: wholeWords).flatMap(Int.init) ?? 0
            guard let decimal = decimalString(for: decimalWords) else { return nil }
            return "\(whole).\(decimal)"
        }

        if let digits = digitString(for: words), words.count > 1 {
            return digits
        }

        if words.count == 1 {
            return nil
        }

        guard let integer = integerValue(for: words) else { return nil }
        return "\(integer)"
    }

    private static func digitString(for words: [String]) -> String? {
        guard !words.isEmpty else { return nil }

        var digits = ""
        for word in words {
            guard let value = digitWords[word] else { return nil }
            digits += "\(value)"
        }
        return digits
    }

    private static func decimalString(for words: [String]) -> String? {
        if let digits = digitString(for: words) {
            return digits
        }

        guard let value = integerValue(for: words) else { return nil }
        return "\(value)"
    }

    private static func integerValue(for words: [String]) -> Int? {
        guard !words.isEmpty else { return nil }

        var total = 0
        var current = 0
        var sawNumericWord = false

        for word in words {
            if word == "and" {
                continue
            }

            if let value = smallNumbers[word] {
                current += value
                sawNumericWord = true
                continue
            }

            if let value = tens[word] {
                current += value
                sawNumericWord = true
                continue
            }

            switch word {
            case "hundred":
                current = max(current, 1) * 100
                sawNumericWord = true
            case "thousand":
                total += max(current, 1) * 1000
                current = 0
                sawNumericWord = true
            default:
                return nil
            }
        }

        guard sawNumericWord else { return nil }
        return total + current
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        replacement: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result = ""
        var cursor = 0

        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += source.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            result += replacement(source.substring(with: range))
            cursor = range.location + range.length
        }

        if cursor < source.length {
            result += source.substring(from: cursor)
        }

        return result
    }

    private static func tidy(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+([,.!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
